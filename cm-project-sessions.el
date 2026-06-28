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

(provide 'cm-project-sessions)
;;; cm-project-sessions.el ends here
