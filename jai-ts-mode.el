;;; jai-ts-mode.el --- Major mode for Jai  -*- lexical-binding: t; -*-

;; Jai's syntax (bracketed/unbracketed variants of every control form) causes
;; tree-sitter's LR state count to exceed the hard-coded 64K limit.  Multiple
;; serious attempts to build a complete grammar failed for this reason.  The
;; available grammar (overlord-systems/jai-tree-sitter) only covers a tiny
;; subset of real code and produces ERROR nodes for almost everything else,
;; making tree-sitter parsing actively harmful.
;;
;; This mode therefore does NOT activate tree-sitter.  It is a clean
;; prog-mode derivative with a proper syntax table and comment variables.
;; The real IDE value comes from eglot + jails LSP.

(defvar jai-ts-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?/ ". 124b" table)   ; C-style // and /* */ comments
    (modify-syntax-entry ?* ". 23"   table)
    (modify-syntax-entry ?\n "> b"   table)
    (modify-syntax-entry ?_ "w"      table)   ; underscores are word chars
    (modify-syntax-entry ?\" "\""    table)
    table)
  "Syntax table for `jai-ts-mode'.")

(defvar jai-ts-mode--imenu-generic-expression
  '(("Procedures"
     "^\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*::[ \t]*\\(?:inline[ \t]+\\)?(" 1)
    ("Operators"
     "^\\(operator[ \t]*[^ \t:]+\\)[ \t]*::[ \t]*(" 1)
    ("Structs"
     "^\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*::[ \t]*struct\\b" 1)
    ("Enums"
     "^\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*::[ \t]*enum\\(?:_flags\\)?\\b" 1)
    ("Unions"
     "^\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*::[ \t]*union\\b" 1)
    ("Constants"
     "^\\([A-Z][A-Z0-9_]*\\)[ \t]*::[ \t]*[^( \t\n]" 1))
  "Imenu patterns for Jai top-level (column-0) `::' declarations.

Routing is by the token after `::'.  Categories stay mutually exclusive in
idiomatic Jai because of naming conventions: procedures are snake_case,
types are Title_Case, constants are SCREAMING_SNAKE_CASE (so the all-caps
Constants pattern can never consume a Title_Case type name up to `::').

Caveat: an all-caps *type* (e.g. a C-binding `LARGE_INTEGER :: union') will
appear under both its type group and Constants.  Emacs regex lacks negative
lookahead, and excluding it via the RHS would also drop legitimate
lowercase-RHS constants such as `COLOR_SCHEMES :: float.[...]'.  Idiomatic
Jai uses Title_Case type names, so this does not trigger in practice.")

;;;###autoload
(define-derived-mode jai-ts-mode prog-mode "Jai"
  "Major mode for editing Jai source.

Tree-sitter is intentionally not used: Jai's bracketed/unbracketed control
flow variants cause the LR state count to exceed tree-sitter's 64K limit,
and the best available grammar produces ERROR nodes for nearly all real code.
Syntax highlighting is handled by font-lock patterns; IDE features come from
eglot and the jails language server."
  :syntax-table jai-ts-mode-syntax-table
  (setq-local comment-start       "// "
              comment-end         ""
              comment-start-skip  "//+\\s-*"
              indent-tabs-mode    nil)
  ;; Basic regex font-lock — good enough given tree-sitter can't help here.
  (setq-local font-lock-defaults
              '((jai-ts-mode--font-lock-keywords) nil nil nil nil))
  ;; Regex-based imenu (M-g i / consult-imenu).  Tree-sitter can't index Jai
  ;; (see header), so symbols come from column-0 `::' declarations.  Jai is
  ;; case-sensitive, so case folding is disabled here — that is what keeps
  ;; SCREAMING_CASE constants distinct from Title_Case type names.
  (setq-local imenu-generic-expression jai-ts-mode--imenu-generic-expression
              imenu-case-fold-search    nil))

(defvar jai-ts-mode--font-lock-keywords
  (let ((keywords  '("if" "else" "while" "for" "return" "break" "continue"
                     "case" "defer" "inline" "no_inline" "push_context"
                     "using" "cast" "xx" "struct" "enum" "union"
                     "null" "true" "false" "it" "it_index"))
        (types     '("int" "float" "float32" "float64" "bool" "string" "void"
                     "s8" "s16" "s32" "s64" "u8" "u16" "u32" "u64"
                     "Any" "Type" "Code")))
    `(;; Compiler directives: #import, #run, #load, #if, #through, etc.
      (,(rx "#" (+ (any alpha "_"))) . font-lock-preprocessor-face)
      ;; Procedure/constant declarations:  name :: () { ... }  /  name :: value
      (,(rx (group (+ (any alnum "_"))) (+ space) "::") 1 font-lock-function-name-face)
      ;; Keywords.
      (,(regexp-opt keywords 'words) . font-lock-keyword-face)
      ;; Types.
      (,(regexp-opt types 'words) . font-lock-type-face)
      ;; Note-style comments: // NOTE: ...
      (,(rx "//" (* space) (group (or "NOTE" "TODO" "FIXME" "HACK" "XXX") ":"))
       1 font-lock-warning-face t)))
  "Font-lock keywords for `jai-ts-mode'.")

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.jai\\'" . jai-ts-mode))

(provide 'jai-ts-mode)
;;; jai-ts-mode.el ends here
