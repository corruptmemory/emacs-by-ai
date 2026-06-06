;;; cm-project-roots.el --- Multi-root project search ("Add Folder to Project")  -*- lexical-binding: t; -*-
;;; Commentary:
;; Opt-in commands that run search / references / find-file / jump-to-definition
;; across directories listed in a `.project-roots' file at the primary project
;; root.  LSP-first for jump/refs; rg-based for search/find-file.
;; See docs/plans/2026-06-06-multi-root-project-design.md.
;;; Code:

(require 'project)
(require 'xref)
(require 'subr-x)
(require 'cl-lib)

(declare-function consult-ripgrep "consult")
(declare-function consult--read "consult")
(declare-function dumb-jump-fetch-results "dumb-jump")
(declare-function dumb-jump-get-language "dumb-jump")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-server-capable "eglot")

(defconst cm/project-roots-file ".project-roots"
  "Name of the file (at the primary project root) listing extra roots.")

(provide 'cm-project-roots)
;;; cm-project-roots.el ends here
