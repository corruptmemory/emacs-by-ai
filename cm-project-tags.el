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

(provide 'cm-project-tags)
;;; cm-project-tags.el ends here
