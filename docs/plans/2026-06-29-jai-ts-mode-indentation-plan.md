# jai-ts-mode Indentation + Editing Robustness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `jai-ts-mode` a real indentation engine (fixing both reported bugs) and adopt the load-bearing editing-robustness pieces of upstream `jai-mode`.

**Architecture:** Drive indentation with `js-indent-line`, neutralising js-mode's C-preprocessor handling via a *dynamically scoped, locally confined* `let` (not upstream's global `defconst` clobber). Add nested block comments, here-string `syntax-propertize`, richer font-lock, and defun navigation. All changes live in one file plus one new ERT test file.

**Tech Stack:** Emacs Lisp (Emacs 29+), `js.el` (built-in, for `js-indent-line`), ERT.

## Global Constraints

- **Single source file:** all production changes go in `jai-ts-mode.el`. The only other file created is `tests/jai-ts-mode-tests.el`. No other file is touched.
- **No global mutation:** the js-mode neutering MUST be confined to Jai indentation (dynamic `let`), never global `defconst`s.
- **Mode name unchanged:** stays `jai-ts-mode`; `auto-mode-alist` entry unchanged.
- **Keep existing features:** the existing imenu generic expression and the `NOTE/TODO/FIXME/HACK/XXX` font-lock rule are retained, not replaced.
- **Naming:** all new functions/vars use the `jai-ts-mode--` private prefix (or `jai-ts-mode-` for the public `defcustom`).
- **Lifted code is GPLv3** (© Kristoffer Grönlund, Valentin Ignatev, `valignatev/jai-mode`); an attribution header is required.
- **Indentation offset default is 4.**
- **Tests auto-discover:** `tests/run-tests.sh` loads every `tests/*-tests.el`; no runner wiring needed.

**Focused test command** (used in RED/GREEN steps below; runs only this suite):

```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "SELECTOR-REGEXP")'
```

Full suite (run before each commit): `./tests/run-tests.sh`

---

## File Structure

- **`jai-ts-mode.el`** (modify) — roughly doubles in size. New: attribution header, `(require 'js)`, `defgroup`/`defcustom`, indent wrapper + special declaration, upgraded syntax table, here-string `syntax-propertize`, richer font-lock + cast matcher, defun navigation, mode-body wiring.
- **`tests/jai-ts-mode-tests.el`** (create) — the repo's first ERT suite for this mode. One shared helper section, then per-feature `ert-deftest`s.

---

### Task 1: Indentation engine + offset knob + attribution

**Files:**
- Modify: `jai-ts-mode.el` (header; add `require`, `defgroup`, `defcustom`, indent wrapper; extend mode body)
- Create: `tests/jai-ts-mode-tests.el`

**Interfaces:**
- Produces: `jai-ts-mode-indent-offset` (defcustom, integer, default 4); `jai-ts-mode--indent-line` (the `indent-line-function`); test helper `jai-ts-mode-tests--reindent` (string → re-indented string).
- Consumes: `js-indent-line`, `js-indent-level`, `js--opt-cpp-start`, `js--macro-decl-re` (from `js.el`).

- [ ] **Step 1: Write the failing tests** — create `tests/jai-ts-mode-tests.el`:

```elisp
;;; jai-ts-mode-tests.el --- Tests for jai-ts-mode  -*- lexical-binding: t; -*-

(require 'ert)
(require 'jai-ts-mode)

(defun jai-ts-mode-tests--reindent (code)
  "Return CODE re-indented from scratch in a `jai-ts-mode' buffer."
  (with-temp-buffer
    (jai-ts-mode)
    (insert code)
    (indent-region (point-min) (point-max))
    (buffer-string)))

(ert-deftest jai-ts-mode-test-indent-nested-for ()
  "The reported for-loop example: body to 8, closers to 4/0."
  (should (equal (jai-ts-mode-tests--reindent
                  "foo :: () {\nfor * wall: game.walls {\nx := 1;\n}\n}\n")
                 "foo :: () {\n    for * wall: game.walls {\n        x := 1;\n    }\n}\n")))

(ert-deftest jai-ts-mode-test-indent-if-else ()
  "Bracketed if/else indents bodies one level, closers to the opener."
  (should (equal (jai-ts-mode-tests--reindent
                  "f :: () {\nif x {\ny();\n} else {\nz();\n}\n}\n")
                 "f :: () {\n    if x {\n        y();\n    } else {\n        z();\n    }\n}\n")))

(ert-deftest jai-ts-mode-test-indent-directive-no-crash ()
  "A `#'-led directive line indents without signalling and to its brace depth."
  (should (equal (jai-ts-mode-tests--reindent
                  "#import \"Basic\";\nmain :: () {\n#if OS == .WINDOWS {\nx := 1;\n}\n}\n")
                 "#import \"Basic\";\nmain :: () {\n    #if OS == .WINDOWS {\n        x := 1;\n    }\n}\n")))

(ert-deftest jai-ts-mode-test-indent-offset-knob ()
  "`jai-ts-mode-indent-offset' drives the produced indentation."
  (let ((jai-ts-mode-indent-offset 2))
    (should (equal (jai-ts-mode-tests--reindent "f :: () {\nx := 1;\n}\n")
                   "f :: () {\n  x := 1;\n}\n"))))

(provide 'jai-ts-mode-tests)
;;; jai-ts-mode-tests.el ends here
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-indent")'
```
Expected: FAIL. The current mode has no `indent-line-function`, so `indent-region` uses `indent-relative` — `jai-ts-mode-test-indent-nested-for` produces the buggy 4/0 layout, and `jai-ts-mode-test-indent-offset-knob` fails because `jai-ts-mode-indent-offset` is void (`void-variable jai-ts-mode-indent-offset`).

- [ ] **Step 3a: Add the attribution header.** In `jai-ts-mode.el`, insert this block immediately after the first `;;; jai-ts-mode.el --- …` line and before the existing `;; Jai's syntax …` commentary:

```elisp
;; Indentation (`js-indent-line'), here-string syntax-propertization, defun
;; navigation, and several font-lock matchers are adapted from jai-mode
;; <https://github.com/valignatev/jai-mode> (© Kristoffer Grönlund and Valentin
;; Ignatev), distributed under the GNU GPL v3 or later.  Those portions inherit
;; that license.
```

- [ ] **Step 3b: Require js and declare the special variable.** In `jai-ts-mode.el`, after the commentary block and before `(defvar jai-ts-mode-syntax-table …)`, add:

```elisp
(require 'js)   ; js-indent-line / js-indent-level drive indentation (see below)

;; `js--proper-indentation' references `cpp-font-lock-keywords-source-directives',
;; which is defined nowhere in Emacs 30.2 — indenting a `#'-led line would
;; otherwise signal `void-variable'.  This bare `defvar' declares the symbol
;; special WITHOUT a value, so it clobbers no global value yet lets the dynamic
;; `let' in `jai-ts-mode--indent-line' bind it.
(defvar cpp-font-lock-keywords-source-directives)
```

- [ ] **Step 3c: Add the customization group, offset knob, and indent wrapper.** In `jai-ts-mode.el`, before the `(define-derived-mode jai-ts-mode …)` form, add:

```elisp
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
```

- [ ] **Step 3d: Wire the mode body.** In the `define-derived-mode jai-ts-mode` body, immediately after the existing `(setq-local comment-start … indent-tabs-mode nil)` form, add a new form:

```elisp
  ;; Indentation is js-indent-line (see `jai-ts-mode--indent-line'); the public
  ;; offset knob feeds js-indent-level.  `parse-sexp-ignore-comments' makes sexp
  ;; motion skip comments; js-jsx-syntax nil keeps js's JSX path from engaging.
  (setq-local indent-line-function       #'jai-ts-mode--indent-line
              js-indent-level            jai-ts-mode-indent-offset
              parse-sexp-ignore-comments t
              js-jsx-syntax              nil)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-indent")'
```
Expected: PASS (4 tests). Output must be pristine — no warnings.

- [ ] **Step 5: Run the full suite, then commit**

```bash
./tests/run-tests.sh
git add jai-ts-mode.el tests/jai-ts-mode-tests.el
git commit -m "feat(jai): real indentation via confined js-indent-line + offset knob

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Syntax-table upgrades (nested comments, operators, escape, CRLF)

**Files:**
- Modify: `jai-ts-mode.el` (`jai-ts-mode-syntax-table`)
- Modify: `tests/jai-ts-mode-tests.el` (append one test)

**Interfaces:**
- Produces: an upgraded `jai-ts-mode-syntax-table` (nested `/* */`, operator punctuation, backslash escape, CRLF comment-ender). No new public symbols.

- [ ] **Step 1: Write the failing test** — append to `tests/jai-ts-mode-tests.el` (before the `(provide …)` line):

```elisp
(ert-deftest jai-ts-mode-test-nested-block-comments ()
  "Jai's /* */ comments NEST: an inner */ does not end the outer comment."
  (with-temp-buffer
    (jai-ts-mode)
    (insert "x /* a /* b */ c */ y\n")
    (goto-char (point-min))
    (search-forward "c")
    (should (nth 4 (syntax-ppss)))        ; still inside the outer comment
    (search-forward "y")
    (should-not (nth 4 (syntax-ppss)))))  ; outside after both closers
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-nested-block-comments")'
```
Expected: FAIL. With the current `?* ". 23"` (non-nesting), the first `*/` ends the comment, so point at `c` is NOT in a comment.

- [ ] **Step 3: Implement** — replace the entire `(defvar jai-ts-mode-syntax-table …)` form in `jai-ts-mode.el` with:

```elisp
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-nested-block-comments")'
```
Expected: PASS.

- [ ] **Step 5: Run the full suite, then commit**

```bash
./tests/run-tests.sh
git add jai-ts-mode.el tests/jai-ts-mode-tests.el
git commit -m "feat(jai): nested block comments + operator/escape syntax entries

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Note: Task 1's indentation tests must still pass here (re-run by `./tests/run-tests.sh`) — the operator-as-punctuation entries do not change brace depth for those examples.

---

### Task 3: Here-string `syntax-propertize`

**Files:**
- Modify: `jai-ts-mode.el` (add `jai-ts-mode--syntax-propertize-function`; extend mode body)
- Modify: `tests/jai-ts-mode-tests.el` (append one test)

**Interfaces:**
- Produces: `jai-ts-mode--syntax-propertize-function` (a `syntax-propertize-function`). Marks `#string TAG … TAG` heredoc bodies as strings so their braces don't affect nesting depth.

- [ ] **Step 1: Write the failing test** — append to `tests/jai-ts-mode-tests.el` (before `(provide …)`):

```elisp
(ert-deftest jai-ts-mode-test-here-string-braces-ignored ()
  "Braces inside a #string heredoc don't count toward nesting depth."
  (with-temp-buffer
    (jai-ts-mode)
    (insert "s := #string DONE\n{ not a real brace }\nDONE\nafter := 1;\n")
    (syntax-ppss (point-max))             ; force propertization
    (goto-char (point-min))
    (search-forward "{ not")
    (should (nth 3 (syntax-ppss)))        ; the brace is inside a string
    (goto-char (point-min))
    (search-forward "after :=")
    (beginning-of-line)
    (should (= 0 (car (syntax-ppss))))))  ; heredoc brace ignored → depth 0
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-here-string")'
```
Expected: FAIL. Without `syntax-propertize`, the `{` is plain punctuation: it is not in a string, and depth at the `after :=` line is 1 (the unbalanced heredoc brace counts).

- [ ] **Step 3a: Add the function.** In `jai-ts-mode.el`, after the `jai-ts-mode--indent-line` definition (or anywhere before the mode), add:

```elisp
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
```

- [ ] **Step 3b: Wire the mode body.** In the `define-derived-mode jai-ts-mode` body, after the indentation `setq-local` form added in Task 1, add:

```elisp
  (setq-local syntax-propertize-function #'jai-ts-mode--syntax-propertize-function)
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-here-string")'
```
Expected: PASS.

- [ ] **Step 5: Run the full suite, then commit**

```bash
./tests/run-tests.sh
git add jai-ts-mode.el tests/jai-ts-mode-tests.el
git commit -m "feat(jai): #string here-string syntax-propertize (keeps braces out of depth)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Richer font-lock

**Files:**
- Modify: `jai-ts-mode.el` (add `jai-ts-mode--postfix-cast-syntax`; replace `jai-ts-mode--font-lock-keywords`)
- Modify: `tests/jai-ts-mode-tests.el` (append a helper + three tests)

**Interfaces:**
- Produces: `jai-ts-mode--postfix-cast-syntax` (font-lock matcher fn); an expanded `jai-ts-mode--font-lock-keywords`. The mode body's `font-lock-defaults` already references `jai-ts-mode--font-lock-keywords` — unchanged.

- [ ] **Step 1: Write the failing tests** — append to `tests/jai-ts-mode-tests.el` (before `(provide …)`):

```elisp
(defun jai-ts-mode-tests--face-at (code needle)
  "Fontify CODE in `jai-ts-mode'; return the face at the start of NEEDLE."
  (with-temp-buffer
    (jai-ts-mode)
    (insert code)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward needle)
    (let ((f (get-text-property (match-beginning 0) 'face)))
      (if (and f (listp f)) (car f) f))))

(ert-deftest jai-ts-mode-test-font-lock-number ()
  "Numeric literals get constant face."
  (should (eq 'font-lock-constant-face
              (jai-ts-mode-tests--face-at "x := 42;\n" "42"))))

(ert-deftest jai-ts-mode-test-font-lock-note ()
  "@notes get preprocessor face."
  (should (eq 'font-lock-preprocessor-face
              (jai-ts-mode-tests--face-at "foo :: () {} @MyNote\n" "@MyNote"))))

(ert-deftest jai-ts-mode-test-font-lock-keyword ()
  "Keywords get keyword face."
  (should (eq 'font-lock-keyword-face
              (jai-ts-mode-tests--face-at "f :: () { defer x(); }\n" "defer"))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-font-lock")'
```
Expected: FAIL. The current font-lock has no number rule (`number` → nil) and no `@note` rule (`@MyNote` → nil). (`defer` already passes — it is in the current keyword list — but the suite fails overall until the others pass.)

- [ ] **Step 3a: Add the cast matcher.** In `jai-ts-mode.el`, immediately before the `(defvar jai-ts-mode--font-lock-keywords …)` form, add:

```elisp
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
```

- [ ] **Step 3b: Replace the font-lock keywords.** Replace the entire `(defvar jai-ts-mode--font-lock-keywords …)` form in `jai-ts-mode.el` with:

```elisp
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-font-lock")'
```
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full suite, then commit**

```bash
./tests/run-tests.sh
git add jai-ts-mode.el tests/jai-ts-mode-tests.el
git commit -m "feat(jai): richer font-lock (casts, .{}/.[], @notes, \$T, numbers, keywords)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Defun navigation + integration smoke test

**Files:**
- Modify: `jai-ts-mode.el` (add defun-nav helpers; extend mode body)
- Modify: `tests/jai-ts-mode-tests.el` (append one test)

**Interfaces:**
- Produces: `jai-ts-mode--defun-rx`, `jai-ts-mode--line-is-defun`, `jai-ts-mode--beginning-of-defun`, `jai-ts-mode--end-of-defun`; the mode body sets `beginning-of-defun-function` / `end-of-defun-function`.

- [ ] **Step 1: Write the failing test** — append to `tests/jai-ts-mode-tests.el` (before `(provide …)`):

```elisp
(ert-deftest jai-ts-mode-test-beginning-of-defun ()
  "From inside a proc, beginning-of-defun lands on its declaration line."
  (with-temp-buffer
    (jai-ts-mode)
    (insert "foo :: () {\n    bar();\n    baz();\n}\n")
    (goto-char (point-min))
    (search-forward "baz")
    (jai-ts-mode--beginning-of-defun)
    (should (equal (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))
                   "foo :: () {"))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-beginning-of-defun")'
```
Expected: FAIL with `void-function jai-ts-mode--beginning-of-defun`.

- [ ] **Step 3a: Add the navigation functions.** In `jai-ts-mode.el`, before the `(define-derived-mode jai-ts-mode …)` form, add:

```elisp
(defconst jai-ts-mode--defun-rx "(.*).*{"
  "Heuristic: a procedure-opening line has parens then an opening brace.")

(defun jai-ts-mode--line-is-defun ()
  "Return non-nil if the current line begins a procedure.  Adapted from jai-mode."
  (save-excursion
    (beginning-of-line)
    (let (found)
      (while (and (not (eolp)) (not found))
        (if (looking-at jai-ts-mode--defun-rx)
            (setq found t)
          (forward-char 1)))
      found)))

(defun jai-ts-mode--beginning-of-defun (&optional _arg)
  "Move to the line on which the current procedure starts.  Adapted from jai-mode."
  (let ((orig-level (car (syntax-ppss))))
    (while (and (not (jai-ts-mode--line-is-defun))
                (not (bobp))
                (> orig-level 0))
      (setq orig-level (car (syntax-ppss)))
      (while (>= (car (syntax-ppss)) orig-level)
        (skip-chars-backward "^{")
        (backward-char))))
  (when (jai-ts-mode--line-is-defun)
    (beginning-of-line)))

(defun jai-ts-mode--end-of-defun ()
  "Move to the line on which the current procedure ends.  Adapted from jai-mode."
  (let ((orig-level (car (syntax-ppss))))
    (when (> orig-level 0)
      (jai-ts-mode--beginning-of-defun)
      (end-of-line)
      (setq orig-level (car (syntax-ppss)))
      (skip-chars-forward "^}")
      (while (>= (car (syntax-ppss)) orig-level)
        (skip-chars-forward "^}")
        (forward-char)))))
```

- [ ] **Step 3b: Wire the mode body.** In the `define-derived-mode jai-ts-mode` body, after the `syntax-propertize-function` `setq-local` form added in Task 3, add:

```elisp
  (setq-local beginning-of-defun-function #'jai-ts-mode--beginning-of-defun
              end-of-defun-function       #'jai-ts-mode--end-of-defun)
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -l ert -l tests/jai-ts-mode-tests.el \
  --eval '(ert-run-tests-batch-and-exit "jai-ts-mode-test-beginning-of-defun")'
```
Expected: PASS.

- [ ] **Step 5: Integration smoke test (whole file, real config path).** Confirm the file byte-compiles clean and the mode wires everything when loaded as the repo does:

```bash
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  --eval '(progn
            (require (quote jai-ts-mode))
            (with-temp-buffer
              (jai-ts-mode)
              (princ (format "indent-line-function: %s\n" indent-line-function))
              (princ (format "js-indent-level: %s\n" js-indent-level))
              (princ (format "syntax-propertize-function: %s\n" syntax-propertize-function))
              (princ (format "beginning-of-defun-function: %s\n" beginning-of-defun-function))))'
emacs -batch -Q --eval "(add-to-list 'load-path \"$(pwd)\")" \
  -f batch-byte-compile jai-ts-mode.el && rm -f jai-ts-mode.elc
```
Expected: first command prints `jai-ts-mode--indent-line`, `4`, `jai-ts-mode--syntax-propertize-function`, `jai-ts-mode--beginning-of-defun`. Second command byte-compiles with no errors (warnings about `js--*` free variables are acceptable — they are js.el internals we intentionally `let`-bind; if a warning is noisy, it may be silenced with a `(defvar js--opt-cpp-start)` / `(defvar js--macro-decl-re)` declaration, but this is optional).

- [ ] **Step 6: Run the full suite, then commit**

```bash
./tests/run-tests.sh
git add jai-ts-mode.el tests/jai-ts-mode-tests.el
git commit -m "feat(jai): beginning/end-of-defun navigation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final integration

After Task 5, the full suite is green and `jai-ts-mode.el` byte-compiles clean. Manual end-to-end check the user can run:

```sh
emacs --init-directory=~/projects/emacs-again/ some-file.jai
```
Open a `.jai` file, type `foo :: () {`, press RET inside the braces, and confirm the body indents one level deeper with the `}` pushed to the opener's column.

## Docs follow-up (separate commit, after implementation)

Update `CLAUDE.md` and `README.md`: the "Jai and Tree-Sitter" / `jai-ts-mode` sections currently say font-lock + syntax table only. Add that the mode now has js-indent-line-based indentation (with the confined-neutering rationale), nested block comments, here-string handling, defun navigation, and richer font-lock, with attribution to `valignatev/jai-mode`. This is documentation, not covered by a task gate.

## Self-Review

**Spec coverage** (design § → task):
- Indentation engine + confined neutering → Task 1 ✓
- Offset knob (`jai-ts-mode-indent-offset`, default 4) → Task 1 ✓
- Sexp/JSX hygiene → Task 1 (mode body) ✓
- Syntax-table upgrades (nested comments, operators, escape, CRLF) → Task 2 ✓
- Here-string `syntax-propertize` → Task 3 ✓
- Richer font-lock (cast, `.{}`/`.[]`, `@notes`, `$T`, numbers, char, `---`, richer keywords, precise proc/type names) + documented `x: Type` caveat → Task 4 ✓
- Defun navigation → Task 5 ✓
- Attribution header → Task 1, Step 3a ✓
- Kept: imenu, mode name, NOTE rule → unchanged in Tasks 1/4 ✓
- Tests (indent characterization, directive safety, nested comments, here-strings, offset, defun nav, font-lock spot-checks) → Tasks 1–5 ✓

**Placeholder scan:** none — every step has complete code/commands and ground-truthed expected values (verified by batch probe before writing this plan).

**Type/name consistency:** `jai-ts-mode--indent-line`, `jai-ts-mode--syntax-propertize-function`, `jai-ts-mode--postfix-cast-syntax`, `jai-ts-mode--font-lock-keywords`, `jai-ts-mode--defun-rx`, `jai-ts-mode--line-is-defun`, `jai-ts-mode--beginning-of-defun`, `jai-ts-mode--end-of-defun`, `jai-ts-mode-indent-offset`, and test helpers `jai-ts-mode-tests--reindent` / `--face-at` are each defined once and referenced consistently. Mode-body `setq-local` forms are added in distinct tasks at named insertion points (after the previous form), so they compose without collision.
