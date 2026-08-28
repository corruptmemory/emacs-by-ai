;;; cm-ai-registry.el --- Per-instance Emacs registry for agent discovery  -*- lexical-binding: t; -*-
;;; Commentary:
;; Each ephemeral Emacs writes a small JSON descriptor recording its project
;; root and emacsclient server-name into `cm/ai-registry-dir', so an external
;; agent (or scripts/emacs-send) can resolve "the Emacs for project X" instead
;; of guessing the last-used one.
;; See docs/plans/2026-08-28-emacs-agents-bridge-design.md (Section A).
;;; Code:

(require 'json)
(require 'cl-lib)
(require 'server)  ; for the server-name / server-socket-dir special vars

(declare-function project-root "project")

(defgroup cm/ai-registry nil "Per-instance Emacs registry." :group 'tools)

(defcustom cm/ai-registry-dir (expand-file-name "instances/" "~/.emacs-ai/")
  "Directory holding one descriptor file per live Emacs instance."
  :type 'directory)

(defun cm/ai-registry--project-root ()
  "Best-effort project root of the launch directory, slash-terminated absolute."
  (file-name-as-directory
   (expand-file-name
    (or (and (fboundp 'project-current)
             (when-let* ((proj (project-current nil default-directory)))
               (project-root proj)))
        default-directory))))

(defun cm/ai-registry-descriptor ()
  "Build the descriptor alist for this Emacs instance."
  (list (cons 'project_root (cm/ai-registry--project-root))
        (cons 'server_name  (and (boundp 'server-name) server-name))
        (cons 'pid          (emacs-pid))
        (cons 'socket       (ignore-errors
                              (expand-file-name
                               (or (bound-and-true-p server-name) "")
                               (or (bound-and-true-p server-socket-dir)
                                   (format "/run/user/%d/emacs" (user-uid))))))
        (cons 'frame_title  (or (ignore-errors
                                  (format-mode-line frame-title-format)) ""))
        (cons 'started      (format-time-string "%FT%T%z"))))

(defun cm/ai-registry--write (descriptor dir)
  "Write DESCRIPTOR (alist) into DIR atomically; return the file path."
  (make-directory dir t)
  (let* ((server (alist-get 'server_name descriptor))
         (target (expand-file-name (format "%s.json" server) dir))
         (tmp    (make-temp-file (expand-file-name ".tmp-" dir))))
    (with-temp-file tmp (insert (json-encode descriptor)))
    (rename-file tmp target t)
    target))

(defun cm/ai-registry--read (file)
  "Read descriptor FILE into a keyword plist, or nil on error."
  (ignore-errors
    (let ((json-object-type 'plist)
          (json-key-type 'keyword)
          (json-array-type 'list))
      (json-read-from-string
       (with-temp-buffer (insert-file-contents file) (buffer-string))))))

(defun cm/ai-registry--files* (dir)
  "List descriptor files in DIR."
  (when (file-directory-p dir)
    (directory-files dir t "\\.json\\'")))

(defun cm/ai-registry--files ()
  "List descriptor files in `cm/ai-registry-dir'."
  (cm/ai-registry--files* cm/ai-registry-dir))

(defun cm/ai-registry--pid-live-p (pid)
  "Return non-nil if PID is a running process (Linux /proc)."
  (and (integerp pid) (> pid 0)
       (file-exists-p (format "/proc/%d" pid))))

(defun cm/ai-registry--sweep (dir &optional live-pred)
  "Delete descriptors in DIR whose PID is not live (LIVE-PRED, default /proc)."
  (let ((live (or live-pred #'cm/ai-registry--pid-live-p)))
    (dolist (f (cm/ai-registry--files* dir))
      (let ((d (cm/ai-registry--read f)))
        (when (and d (not (funcall live (plist-get d :pid))))
          (ignore-errors (delete-file f)))))))

(defun cm/ai-registry--file (&optional server)
  "Descriptor path for SERVER (default this instance's `server-name')."
  (expand-file-name (format "%s.json" (or server server-name))
                    cm/ai-registry-dir))

(defun cm/ai-registry-register ()
  "Write this instance's descriptor, sweep dead ones, install exit cleanup."
  (when (and (boundp 'server-name) server-name)
    (cm/ai-registry--sweep cm/ai-registry-dir)
    (cm/ai-registry--write (cm/ai-registry-descriptor) cm/ai-registry-dir)
    (add-hook 'kill-emacs-hook #'cm/ai-registry-deregister)))

(defun cm/ai-registry-deregister ()
  "Remove this instance's descriptor file."
  (when (and (boundp 'server-name) server-name)
    (let ((f (cm/ai-registry--file)))
      (when (file-exists-p f) (ignore-errors (delete-file f))))))

(defun cm/ai-registry-resolve (cwd &optional live-pred)
  "Return the server-name whose project best matches CWD, or nil.
Match = CWD is within `project_root'; rank by most-specific root, then
newest `started'.  LIVE-PRED (default /proc) filters dead instances."
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (live (or live-pred #'cm/ai-registry--pid-live-p))
         (cands (cl-loop for f in (cm/ai-registry--files)
                         for d = (cm/ai-registry--read f)
                         when (and d
                                   (stringp (plist-get d :project_root))
                                   (string-prefix-p (plist-get d :project_root) cwd)
                                   (funcall live (plist-get d :pid)))
                         collect d)))
    (when cands
      (plist-get
       (car (sort cands
                  (lambda (a b)
                    (let ((la (length (plist-get a :project_root)))
                          (lb (length (plist-get b :project_root))))
                      (if (= la lb)
                          (string> (or (plist-get a :started) "")
                                   (or (plist-get b :started) ""))
                        (> la lb))))))
       :server_name))))

(provide 'cm-ai-registry)
;;; cm-ai-registry.el ends here
