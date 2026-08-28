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

(defvar server-name nil)

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

(provide 'cm-ai-registry)
;;; cm-ai-registry.el ends here
