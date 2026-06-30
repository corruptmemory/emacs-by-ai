;;; jai-ts-mode.el --- Major mode for Jai  -*- lexical-binding: t; -*-

;; Indentation (`js-indent-line'), here-string syntax-propertization, defun
;; navigation, and several font-lock matchers are adapted from jai-mode
;; <https://github.com/valignatev/jai-mode> (© Kristoffer Grönlund and Valentin
;; Ignatev), distributed under the GNU GPL v3 or later.  Those portions inherit
;; that license.

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

(require 'js)   ; js-indent-line / js-indent-level drive indentation (see below)

;; `js--proper-indentation' references `cpp-font-lock-keywords-source-directives',
;; which is defined nowhere in Emacs 30.2 — indenting a `#'-led line would
;; otherwise signal `void-variable'.  This bare `defvar' declares the symbol
;; special WITHOUT a value, so it clobbers no global value yet lets the dynamic
;; `let' in `jai-ts-mode--indent-line' bind it.
(defvar cpp-font-lock-keywords-source-directives)

(defvar jai-ts-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?/ ". 124b" table)   ; C-style // and /* */ comments
    (modify-syntax-entry ?* ". 23n"  table)   ; `n' = Jai block comments NEST
    (modify-syntax-entry ?\n "> b"   table)
    (modify-syntax-entry ?\^m "> b"  table)   ; end comments on CRLF too
    (modify-syntax-entry ?_ "w"      table)   ; underscores are word chars
    (modify-syntax-entry ?\" "\""    table)
    (modify-syntax-entry ?\\ "\\"    table)   ; backslash escapes in strings
    ;; Operators/quote as punctuation, so a stray one can't fool `syntax-ppss'
    ;; (which now drives indentation).
    (dolist (c '(?' ?: ?+ ?- ?% ?& ?| ?^ ?! ?= ?< ?> ??))
      (modify-syntax-entry c "." table))
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

(defgroup jai-ts-mode nil
  "Major mode for editing Jai source."
  :group 'languages)

(defcustom jai-ts-mode-indent-offset 4
  "Number of spaces per nesting level in `jai-ts-mode'."
  :type 'natnum
  :safe #'natnump
  :group 'jai-ts-mode)

;; `js-indent-line' provides Jai's C-style indentation (upstream jai-mode's
;; approach).  js-mode's internals treat `#'-led lines as C preprocessor macros
;; — wrong for Jai's `#import'/`#run'/`#if'.  Three js variables drive that
;; path; binding each to an impossible regex (`\\_<\\_>' — a word-start
;; immediately followed by a word-end, which never matches) makes the cpp/macro
;; branches inert.  We bind them DYNAMICALLY and locally, not with global
;; `defconst's like upstream, so js-mode buffers elsewhere are unaffected.
(defun jai-ts-mode--indent-line ()
  "Indent the current line via `js-indent-line', with js-mode's C-preprocessor
handling neutralised so Jai `#'-directives neither crash nor mis-indent."
  (let ((js--opt-cpp-start "\\_<\\_>")
        (js--macro-decl-re "\\_<\\_>")
        (cpp-font-lock-keywords-source-directives "\\_<\\_>"))
    (js-indent-line)))

(defun jai-ts-mode--syntax-propertize-function (start end)
  "Mark Jai `#string TAG … TAG' here-strings as strings between START and END.
Adapted from jai-mode.  Applying string-fence syntax to heredoc bodies keeps
their contents (including stray braces) out of `syntax-ppss' nesting, so they
cannot corrupt indentation."
  (goto-char start)
  ;; If START is already inside a here-string, close that one first.
  (when-let* ((ppss (syntax-ppss))
              (inside (eq t (nth 3 ppss)))
              (start-pos (nth 8 ppss))
              (tag (get-text-property start-pos 'here-string-marker)))
    (when (re-search-forward (concat "^[[:space:]]*" (regexp-quote tag) ";?$") end 'move)
      (let ((end (match-end 0)))
        (put-text-property (1- end) end 'syntax-table (string-to-syntax "|")))))
  (while (re-search-forward "#string +\\([a-zA-Z_][a-zA-Z0-9_]+\\)" end 'move)
    (unless (nth 4 (syntax-ppss))
      (let ((tag (match-string 1))
            (beg (match-beginning 1)))
        (unless (string= tag "CODE")
          (put-text-property beg (1+ beg) 'here-string-marker tag)
          (put-text-property beg (1+ beg) 'syntax-table (string-to-syntax "|"))
          (when (re-search-forward
                 (concat "^[[:space:]]*" "\\(" (regexp-quote tag) "\\)"
                         "\\([[:space:]]*[[:punct:]]*;?$\\)")
                 end 'move)
            (let ((end (match-end 1)))
              (put-text-property (1- end) end 'syntax-table (string-to-syntax "|")))))))))

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
  ;; Indentation is js-indent-line (see `jai-ts-mode--indent-line'); the public
  ;; offset knob feeds js-indent-level.  `parse-sexp-ignore-comments' makes sexp
  ;; motion skip comments; js-jsx-syntax nil keeps js's JSX path from engaging.
  (setq-local indent-line-function       #'jai-ts-mode--indent-line
              js-indent-level            jai-ts-mode-indent-offset
              parse-sexp-ignore-comments t
              js-jsx-syntax              nil)
  (setq-local syntax-propertize-function #'jai-ts-mode--syntax-propertize-function)
  ;; Basic regex font-lock — good enough given tree-sitter can't help here.
  (setq-local font-lock-defaults
              '((jai-ts-mode--font-lock-keywords) nil nil nil nil))
  ;; Regex-based imenu (M-g i / consult-imenu).  Tree-sitter can't index Jai
  ;; (see header), so symbols come from column-0 `::' declarations.  Jai is
  ;; case-sensitive, so case folding is disabled here — that is what keeps
  ;; SCREAMING_CASE constants distinct from Title_Case type names.
  (setq-local imenu-generic-expression jai-ts-mode--imenu-generic-expression
              imenu-case-fold-search    nil))

(defun jai-ts-mode--postfix-cast-syntax (limit)
  "Font-lock matcher for Jai postfix cast `foo.(Type)'.  Adapted from jai-mode.
Sets match groups 1 = `.(', 2 = `)', 3 = the type name (last word inside)."
  (let ((found nil))
    (while (and (not found) (re-search-forward "\\.(" limit t))
      (let ((open-paren-pos (1- (point)))
            (cast-start (match-beginning 0)))
        (save-excursion
          (goto-char open-paren-pos)
          (condition-case nil
              (progn
                (forward-sexp 1)
                (let ((close-paren-pos (point))
                      (inner-start (1+ open-paren-pos))
                      (inner-end (1- (point)))
                      (type-start nil)
                      (type-end nil))
                  (goto-char inner-start)
                  (while (re-search-forward "\\([[:word:]]+\\)" inner-end t)
                    (setq type-start (match-beginning 1))
                    (setq type-end (match-end 1)))
                  (set-match-data (list cast-start close-paren-pos
                                        cast-start (+ cast-start 2)
                                        (1- close-paren-pos) close-paren-pos
                                        type-start type-end))
                  (setq found t)))
            (error nil)))))
    found))

(defvar jai-ts-mode--font-lock-keywords
  (let ((keywords '("if" "ifx" "else" "then" "while" "for" "switch" "case"
                    "struct" "enum" "union" "enum_flags" "interface"
                    "return" "remove" "continue" "break" "defer" "inline"
                    "no_inline" "using" "code_of" "initializer_of" "size_of"
                    "type_of" "type_info" "cast" "xx" "context" "operator"
                    "push_context" "is_constant" "null" "true" "false"))
        (builtins '("it" "it_index"))
        (types    '("int" "float" "float32" "float64" "bool" "string" "void"
                    "s8" "s16" "s32" "s64" "u8" "u16" "u32" "u64"
                    "Any" "Type" "Code")))
    `(;; Postfix cast `foo.(Type)' — first, so it wins priority.
      (jai-ts-mode--postfix-cast-syntax
       (1 font-lock-keyword-face)
       (2 font-lock-keyword-face)
       (3 font-lock-type-face))
      ;; Compiler directives: #import #run #load #if #through …
      (,(rx "#" (+ (any alpha "_"))) . font-lock-preprocessor-face)
      ;; Notes: @note
      (,(rx "@" (+ word)) . font-lock-preprocessor-face)
      ;; Procedure declarations:  name :: (…)  /  name :: inline (…) / #type (…)
      ("\\([[:word:]]+\\)[[:space:]]*:[[:space:]]*:?[[:space:]]*\\(inline\\|#type\\)?[[:space:]]*("
       1 font-lock-function-name-face)
      ;; Type declarations:  name :: struct|enum|union|#type,
      ("\\([[:word:]]+\\)[[:space:]]*:[[:space:]]*:[[:space:]]*\\(struct\\|enum\\|union\\|#type,\\)"
       1 font-lock-type-face)
      ;; Literal-type names:  Foo.{…}  bar.[…]
      ("\\([[:word:]]+\\)\\.\\({\\|\\[\\)" 1 font-lock-type-face)
      ;; Keywords / builtins / named types.
      (,(regexp-opt keywords 'words) . font-lock-keyword-face)
      (,(regexp-opt builtins 'words) . font-lock-variable-name-face)
      (,(regexp-opt types 'words) . font-lock-type-face)
      ;; Polymorph type names:  $T  $$
      (,(rx (group "$" (or (1+ word) (opt "$")))) 1 font-lock-type-face)
      ;; Character literals:  'a'
      ("\\('[[:word:]]\\)\\>" 1 font-lock-constant-face)
      ;; Numeric literals.
      (,(rx symbol-start
            (or (and (+ digit) (opt (and (any "eE") (opt (any "-+")) (+ digit))))
                (and "0" (any "xX") (+ hex-digit)))
            (opt (and (any "_" "A-Z" "a-z") (* (any "_" "A-Z" "a-z" "0-9"))))
            symbol-end)
       . font-lock-constant-face)
      ;; Uninitialized value:  ---
      ("---" . font-lock-constant-face)
      ;; General variable type annotation:  name : Type
      ;; CAVEAT: false-positives on `for it_index, it: foo' (foo read as a type).
      ;; Emacs regex has no negative lookahead, so this is accepted (documented),
      ;; not fixed — mirrors the imenu Constants caveat in this file.
      ("[[:word:]]+[[:space:]]*:[[:space:]]*\\**\\(\\[[[:word:]]*\\]\\|\\[\\.\\.\\]\\)?*[[:space:]]*\\**[[:space:]]*\\([[:word:]]+\\)"
       2 font-lock-type-face)
      ;; Note-style comments: // NOTE: …  (kept from the original mode).
      (,(rx "//" (* space) (group (or "NOTE" "TODO" "FIXME" "HACK" "XXX") ":"))
       1 font-lock-warning-face t)))
  "Font-lock keywords for `jai-ts-mode'.")

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.jai\\'" . jai-ts-mode))

(provide 'jai-ts-mode)
;;; jai-ts-mode.el ends here
