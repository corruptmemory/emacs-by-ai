;;; cm-project-sessions.el --- Per-project session persistence  -*- lexical-binding: t; -*-
;;; Commentary:
;; Sessions-as-projects on `easysession': `C-x p p' saves the current project's
;; session, tears the workspace down, and restores (or creates) the target's.
;; Two scratch tiers: per-project scratch buffers (*scratch:PROJ:N*) ride each
;; session; a global stash (*stash:NAME* and the lone *scratch*) is always
;; present.  Restore-by-launch-directory at startup.
;; Purely additive; existing single-project commands are untouched.
;; See docs/plans/2026-06-28-project-sessions-design.md.
;;; Code:

(require 'project)
(require 'cl-lib)
(require 'seq)
;; Soft require: the pure helpers work without easysession; the flip needs it.
(require 'easysession nil t)

(defgroup cm/project-sessions nil
  "Per-project session persistence layered over easysession."
  :group 'convenience
  :prefix "cm/")

;; Declare special variables from easysession (not defined when easysession is not available)
(defvar easysession-directory nil)
(defvar easysession-switch-to-save-session nil)

(defcustom cm/scratch-default-mode 'text-mode
  "Major mode applied to newly created scratch and stash buffers."
  :type 'function)

(defcustom cm/session-save-interval 60
  "Seconds between background session auto-saves (see `easysession-save-mode')."
  :type 'integer)

(defcustom cm/stash-file (locate-user-emacs-file "project-stash.el")
  "File holding the always-present global stash buffers (and the lone *scratch*)."
  :type 'file)

;; --- Project <-> session name ----------------------------------------------

(defun cm/session-name-for-project (root)
  "Return a stable, filesystem-safe session name for project ROOT."
  (let ((abbrev (abbreviate-file-name
                 (directory-file-name (expand-file-name root)))))
    (replace-regexp-in-string "[^A-Za-z0-9._-]" "-" abbrev)))

(defun cm/session--root-of (dir)
  "Return the project root containing DIR, or nil when DIR is not in a project."
  (when-let* ((proj (project-current nil dir)))
    (project-root proj)))

;; --- Scratch tiers ---------------------------------------------------------

(defun cm/scratch--project-buffer-p (buf)
  "Non-nil when BUF is a per-project scratch buffer (*scratch:PROJ:N*)."
  (string-prefix-p "*scratch:" (buffer-name buf)))

(defun cm/scratch--stash-buffer-p (buf)
  "Non-nil when BUF is a global stash buffer (*stash:NAME* or the lone *scratch*)."
  (let ((name (buffer-name buf)))
    (or (string-prefix-p "*stash:" name)
        (string= name "*scratch*"))))

(defun cm/scratch--project-tag ()
  "Short tag for the current project (its directory basename), or \"none\"."
  (let ((root (cm/session--root-of default-directory)))
    (if root
        (file-name-nondirectory (directory-file-name root))
      "none")))

(defun cm/scratch--next-project-index (tag)
  "Return the smallest N >= 1 for which *scratch:TAG:N* is not a live buffer."
  (let ((n 1))
    (while (get-buffer (format "*scratch:%s:%d*" tag n))
      (setq n (1+ n)))
    n))

(defun cm/scratch-new (&optional global)
  "Create a fresh scratch buffer, switch to it, and return it.
Without a prefix: an instant project-tier buffer *scratch:PROJECT:N* (no prompt).
With prefix GLOBAL (\\[universal-argument]): prompt for NAME and create or visit
the global stash buffer *stash:NAME*."
  (interactive "P")
  (let ((buf (if global
                 (get-buffer-create
                  (format "*stash:%s*" (read-string "Stash name: ")))
               (let ((tag (cm/scratch--project-tag)))
                 (get-buffer-create
                  (format "*scratch:%s:%d*" tag
                          (cm/scratch--next-project-index tag)))))))
    (with-current-buffer buf
      (unless (eq major-mode cm/scratch-default-mode)
        (funcall cm/scratch-default-mode)))
    (switch-to-buffer buf)
    buf))

;; --- Per-project scratch handler (registered with easysession in setup) -----
;; Plain functions (no easysession macros) so they round-trip independently.

(defun cm/scratch--save-handler (buffers)
  "easysession SAVE handler: serialize the project scratch buffers in BUFFERS.
Returns an alist ((NAME . ((buffer-string . TEXT))) …)."
  (delq nil
        (mapcar
         (lambda (buf)
           (when (and (buffer-live-p buf) (cm/scratch--project-buffer-p buf))
             (with-current-buffer buf
               (cons (buffer-name buf)
                     (list (cons 'buffer-string
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))))))
         buffers)))

(defun cm/scratch--load-handler (session-data)
  "easysession LOAD handler: recreate project scratch buffers from SESSION-DATA."
  (dolist (item session-data)
    (let* ((name (car item))
           (text (alist-get 'buffer-string (cdr item))))
      (with-current-buffer (get-buffer-create name)
        (funcall cm/scratch-default-mode)
        (erase-buffer)
        (when text (insert text))))))

;; --- Global stash (always-present; persisted outside any session blob) ------

(defun cm/stash--buffers ()
  "Return the live global stash buffers (and the lone *scratch*)."
  (seq-filter #'cm/scratch--stash-buffer-p (buffer-list)))

(defun cm/stash-save ()
  "Write the global stash buffers to `cm/stash-file'."
  (let ((data (mapcar (lambda (buf)
                        (with-current-buffer buf
                          (list (buffer-name)
                                (buffer-substring-no-properties
                                 (point-min) (point-max)))))
                      (cm/stash--buffers))))
    (with-temp-file cm/stash-file
      (let ((print-length nil) (print-level nil))
        (prin1 data (current-buffer))))))

(defun cm/stash-load ()
  "Recreate the global stash buffers from `cm/stash-file'."
  (when (file-readable-p cm/stash-file)
    (let ((data (with-temp-buffer
                  (insert-file-contents cm/stash-file)
                  (goto-char (point-min))
                  (ignore-errors (read (current-buffer))))))
      (dolist (item data)
        (let ((name (car item)) (text (cadr item)))
          (with-current-buffer (get-buffer-create name)
            (unless (string= name "*scratch*")
              (funcall cm/scratch-default-mode))
            (erase-buffer)
            (when text (insert text))))))))

;; --- The flip (driven by C-x p p via advice in setup) ----------------------

(defun cm/session-switch-to-project (dir)
  "Save the current project session, tear it down, and switch to the project at DIR.
Returns `not-a-project', `noop', `restored', or `created'.
The current session is saved only when one is loaded (`easysession-save' errors
otherwise).  Project-scratch buffers are killed explicitly because
`easysession-kill-all-buffers' spares special buffers; they are restored from
the target session's blob.  The global stash is saved before teardown and
reloaded after, so it survives the kill."
  (let* ((root (cm/session--root-of dir))
         (target (and root (cm/session-name-for-project root)))
         (current (easysession-get-session-name)))
    (cond
     ((null target)
      (message "[cm/session] %s is not a project" dir)
      'not-a-project)
     ((equal target current)
      (message "[cm/session] already in %s" target)
      'noop)
     (t
      (let ((existing (file-exists-p (expand-file-name target easysession-directory))))
        (save-some-buffers nil (lambda () (and buffer-file-name (buffer-modified-p))))
        (cm/stash-save)
        (when current (easysession-save))
        (dolist (buf (seq-filter #'cm/scratch--project-buffer-p (buffer-list)))
          (kill-buffer buf))
        (easysession-kill-all-buffers)
        (let ((easysession-switch-to-save-session nil))
          (easysession-switch-to target))
        (cm/stash-load)
        (message "[cm/session] switched to %s" target)
        (if existing 'restored 'created))))))

;; --- Handler registration --------------------------------------------------

(defun cm/session--install-handlers ()
  "Register cm-project-scratch save/load handlers with easysession.
Uses `easysession-define-generic-save-handler' to return the structured
\(key value remaining-buffers) alist that `easysession-save' expects.
`easysession-define-save-handler' expects the user function to return
\((buffers . DATA) (remaining-buffers . REST)) — our standalone serializer
returns a plain data alist, not that structured form — so this wrapper builds
the full alist directly while keeping `cm/scratch--save-handler' testable as a
pure serialization function."
  (easysession-define-load-handler "cm-project-scratch"
    #'cm/scratch--load-handler)
  (easysession-define-generic-save-handler "cm-project-scratch"
    (let ((data (cm/scratch--save-handler buffers)))
      (when data
        (let ((remaining (seq-remove #'cm/scratch--project-buffer-p buffers)))
          (list (cons 'key "cm-project-scratch")
                (cons 'value data)
                (cons 'remaining-buffers remaining)))))))

;; --- C-x p p advice, startup restore, setup --------------------------------

(defun cm/session--project-switch-advice (_orig &optional dir &rest _)
  "Route `project-switch-project' through the session flip.
DIR is the chosen project directory (read interactively when nil).  A brand-new
project (no saved session) lands blank, so kick off `project-find-file' to help
the user start; an existing project is fully restored and needs nothing more."
  (let ((dir (or dir (project-prompt-project-dir))))
    (when (eq 'created (cm/session-switch-to-project dir))
      (let ((default-directory dir))
        (project-find-file)))))

(defun cm/session-startup ()
  "Load the global stash, then restore the launch directory's project session.
Restores only when a saved session exists for the launch project; otherwise
leaves Emacs blank (a fresh project is created on the first `C-x p p')."
  (cm/stash-load)
  (when-let* ((root (cm/session--root-of default-directory))
              (name (cm/session-name-for-project root)))
    (when (file-exists-p (expand-file-name name easysession-directory))
      (let ((easysession-switch-to-save-session nil))
        (easysession-switch-to name)))))

(defun cm/project-sessions-setup ()
  "Enable per-project session persistence.  Call after `easysession' is loaded."
  (require 'easysession)
  ;; Let saveplace restore point during session restore (easysession suppresses
  ;; it by default to own point via window-state, which is unreliable headless).
  (setq easysession-exclude-from-find-file-hook
        (delq 'save-place-find-file-hook easysession-exclude-from-find-file-hook))
  (setq easysession-save-interval cm/session-save-interval)
  ;; Never prompt to confirm creating a project's session on first switch —
  ;; zero-ceremony flipping is the whole point (C-x p p into a new project
  ;; should create its session silently).
  (setq easysession-confirm-new-session nil)
  (easysession-save-mode 1)
  (cm/session--install-handlers)
  (advice-add 'project-switch-project :around #'cm/session--project-switch-advice)
  (add-hook 'emacs-startup-hook #'cm/session-startup)
  (add-hook 'kill-emacs-hook #'cm/stash-save))

(provide 'cm-project-sessions)
;;; cm-project-sessions.el ends here
