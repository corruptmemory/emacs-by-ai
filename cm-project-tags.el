;;; cm-project-tags.el --- Auto-load a build-generated project TAGS index  -*- lexical-binding: t; -*-
;;; Commentary:
;; When a project root holds a build-generated `TAGS' file (e.g. a Jai build
;; emitting a compiler-precise ETAGS index), load it buffer-locally for code
;; buffers and prefer it for xref navigation.  Priority: LSP wins where a server
;; manages the buffer; else a precise etags lookup; else dumb-jump as a fallback.
;; The build owns generation; `tags-revert-without-query' (set in init.el) makes
;; the in-memory table silently re-read whenever the file is regenerated.
;; See docs/plans/2026-06-25-project-tags-design.md.
;;; Code:

(require 'project)
(require 'xref)
(require 'etags)
(require 'cl-lib)

;; --- Detection ---------------------------------------------------------------

(defun cm/project-tags-file (&optional dir)
  "Return the absolute path of a readable TAGS at the current project root, or nil.
DIR defaults to `default-directory'.  Only the project root is checked, never
subdirectories, matching build tools that emit a single root-level index."
  (when-let* ((proj (project-current nil (or dir default-directory)))
              (root (project-root proj))
              (tags (expand-file-name "TAGS" root)))
    (and (file-readable-p tags) tags)))

;; --- Cascading xref backend: etags first, dumb-jump fallback -----------------
;; LSP is handled elsewhere (eglot's own xref backend); this backend only ever
;; claims a buffer when no server manages it (see `cm/project-tags-xref-backend').

(defvar-local cm/project-tags--active nil
  "Non-nil when this buffer has a project TAGS loaded and the cascade installed.")

(cl-defmethod xref-backend-identifier-at-point ((_ (eql cm/tags-cascade)))
  (xref-backend-identifier-at-point 'etags))

(cl-defmethod xref-backend-identifier-completion-table ((_ (eql cm/tags-cascade)))
  (xref-backend-identifier-completion-table 'etags))

(cl-defmethod xref-backend-definitions ((_ (eql cm/tags-cascade)) identifier)
  "Prefer the precise TAGS index; fall back to dumb-jump only on a miss.
`etags' returns nil (not an error) when a symbol is absent, so the `or'
short-circuits to a direct jump on a hit and to dumb-jump otherwise."
  (or (xref-backend-definitions 'etags identifier)
      (progn (require 'dumb-jump)
             (xref-backend-definitions 'dumb-jump identifier))))

(cl-defmethod xref-backend-references ((_ (eql cm/tags-cascade)) identifier)
  "Delegate references to dumb-jump.
etags has no references method of its own, so this preserves the exact behavior
a non-LSP buffer already has today."
  (require 'dumb-jump)
  (xref-backend-references 'dumb-jump identifier))

(cl-defmethod xref-backend-apropos ((_ (eql cm/tags-cascade)) pattern)
  (xref-backend-apropos 'etags pattern))

(defun cm/project-tags-xref-backend ()
  "Return the cascade backend when a project TAGS is active and no LSP applies.
Yields to Eglot (LSP wins) by returning nil in eglot-managed buffers."
  (and cm/project-tags--active
       (not (bound-and-true-p eglot--managed-mode))
       'cm/tags-cascade))

;; --- Activation (intended for `find-file-hook') ------------------------------

(defun cm/project-tags-maybe-activate ()
  "Load a root project TAGS for this code buffer and install the cascade backend.
No-op unless the buffer derives from `prog-mode' and its project root holds a
readable TAGS file.  The backend is installed at the highest hook priority so it
preempts `xref-union' (which would otherwise merge dumb-jump's hits in)."
  (when (derived-mode-p 'prog-mode)
    (when-let* ((tags (cm/project-tags-file)))
      ;; Bind BOTH buffer-locally: tags-table-list alone conflicts with the
      ;; global tags-file-name a previously-visited project left behind (etags
      ;; then prompts "Keep current list of tags tables also?" or misses the
      ;; lookup).  Pinning tags-file-name to the same file keeps them in sync.
      (setq-local tags-table-list (list tags)
                  tags-file-name tags)
      (setq-local cm/project-tags--active t)
      (add-hook 'xref-backend-functions #'cm/project-tags-xref-backend -100 t))))

(provide 'cm-project-tags)
;;; cm-project-tags.el ends here
