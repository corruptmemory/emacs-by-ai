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

(provide 'cm-project-sessions)
;;; cm-project-sessions.el ends here
