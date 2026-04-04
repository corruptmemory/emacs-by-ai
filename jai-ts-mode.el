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
              '((jai-ts-mode--font-lock-keywords) nil nil nil nil)))

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
