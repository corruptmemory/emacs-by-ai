# Real indentation + editing robustness for `jai-ts-mode` — Design

**Date:** 2026-06-29
**Status:** Approved (brainstorming complete) — proceeding to implementation plan.

## Goal

`jai-ts-mode` currently has **no indentation engine at all**, and that single
gap is the root cause of both reported problems:

1. **Wrong default indent width.** There is no `jai-ts-mode-indent-offset` knob
   because there is no indenter to read one; auto-indent falls through to
   `tab-to-tab-stop` and lands on 8-column stops instead of 4.
2. **Broken "electric" block expansion.** Pressing RET inside `for … {|}` should
   open the body one level deeper and push the `}` to its own line at the
   opener's column. Instead the new line aligns to the *previous line's first
   field* and the braces stack at column 0.

Both are the same defect: the mode body (`jai-ts-mode.el`) sets a syntax table,
comment vars, font-lock, and imenu but **never sets `indent-line-function`**, so
Jai buffers inherit Emacs' global default `indent-relative` — a
"align-to-a-field-of-the-previous-line" heuristic with no concept of brace
nesting. `indent-relative`'s fall-through to the next tab stop is the phantom
"8"; its field-alignment is the wrong RET behavior.

The goal is to install a real indenter and, while we are in the file, adopt the
load-bearing editing-robustness pieces of the mature upstream `jai-mode` —
nested block comments, here-strings, defun navigation, and richer font-lock —
so the mode is a genuinely good Jai editing experience, not just correctly
indented.

## Scope

All changes live in **`jai-ts-mode.el`** plus one new test file
**`tests/jai-ts-mode-tests.el`** (auto-discovered by `tests/run-tests.sh`). No
other file is touched. The mode keeps its name (`jai-ts-mode` — the "ts" is a
historical misnomer documented in CLAUDE.md; renaming would churn
`auto-mode-alist` and `init.el` for no benefit) and keeps our own imenu.

## Research summary — why these choices

The originating prompt was a small two-item indentation fix. A diversion to
**Tsoding's daily-driver Jai mode** (`valignatev/jai-mode`, formerly
`rexim`/Grönlund) reshaped the design: that mode is battle-tested by a working
Jai programmer, and mining it surfaced both a better indentation strategy and
several real correctness fixes our mode was missing.

### Indentation engine: `js-indent-line` over a hand-rolled depth counter

Two candidates were weighed:

- **Hand-rolled depth indenter** (initial recommendation): ~40 lines computing
  `depth × offset` from `syntax-ppss`, dedenting closer-led lines. Fully owned,
  predictable, no foreign coupling — but *dumb*: block-style continuations only,
  no aligned `(`-continuations, no `case`/multi-line smarts.
- **`js-indent-line`** (chosen): upstream `jai-mode` borrows JavaScript's
  C-style indenter. `js--proper-indentation` aligns continuation lines to the
  open paren, handles multi-line expressions, and reads `js-indent-level`
  (default 4) as its offset. Richer behavior "for free," proven in real use.

`js-indent-line` was chosen for the richer behavior. Its cost is a coupling to
js-mode internals (below), which we **confine** rather than inflict globally.

### The js-mode neutering problem, and our cleaner fix

`js--proper-indentation` and its callees misfire on Jai's `#`-led directives
(`#import`, `#run`, `#if`) because they treat `#` lines as C preprocessor
macros. Three js internals drive that path:

| Variable | Kind | Reached during indent via |
|---|---|---|
| `js--opt-cpp-start` | `defconst` (special) | `js--beginning-of-macro` (pervasive in indent path) |
| `js--macro-decl-re` | `defconst` (special) | `js--ensure-cache` (parse cache) |
| `cpp-font-lock-keywords-source-directives` | **undefined in Emacs 30.2** | `js--proper-indentation`, on any `#`-led line |

Upstream neutralizes all three with **top-level `defconst`s** set to an
impossible regex (`"\\_<\\_>"` — a word-start immediately followed by a
word-end, which can never match). That works but **globally clobbers js-mode**
for the whole session — unacceptable here, where other languages (including the
occasional `.js`) are edited in the same Emacs. It also masks a real latent js
bug: `cpp-font-lock-keywords-source-directives` is referenced by
`js--proper-indentation` but **defined nowhere** in Emacs 30.2, so indenting any
`#`-led Jai line would otherwise throw `void-variable`.

Our fix confines the neutralization to Jai indentation:

```elisp
(require 'js)
(defvar cpp-font-lock-keywords-source-directives)   ; declare special, NO value

(defun jai-ts-mode--indent-line ()
  "Indent the current line via `js-indent-line', with js-mode's C-preprocessor
handling neutralised so Jai's `#'-directives neither crash nor mis-indent.

`js--proper-indentation' references `cpp-font-lock-keywords-source-directives',
which is unbound in Emacs 30.2, and runs `js--beginning-of-macro' (driven by
`js--opt-cpp-start' / `js--macro-decl-re') on `#'-led lines.  Binding all three
to an impossible regex makes those branches inert.  The binding is dynamic and
scoped to this call, so js-mode buffers elsewhere keep their normal behaviour —
unlike upstream `jai-mode', which clobbers these globally with top-level
`defconst's."
  (let ((js--opt-cpp-start "\\_<\\_>")
        (js--macro-decl-re "\\_<\\_>")
        (cpp-font-lock-keywords-source-directives "\\_<\\_>"))
    (js-indent-line)))
```

The key subtlety: in a `lexical-binding` file a plain `let` on an *undeclared*
symbol creates a lexical binding that js.el's runtime reference would not see.
The bare `(defvar cpp-font-lock-keywords-source-directives)` form is a
*declaration* that marks the symbol special **without assigning a value** — so
it clobbers no existing global value (if cc-mode later defines one, that stands)
yet enables the dynamic `let`-binding js.el needs. The two `defconst`s are
already special, so they `let`-bind directly.

This is strictly better than upstream: no global js-mode mutation, and it fixes
the upstream-masked `void-variable` crash by construction. It is consistent with
this repo's documented aversion to global side effects (cf. the slang-lsp/eglot
`delq`-it-back note in CLAUDE.md).

## Components

### 1. Offset knob — `jai-ts-mode-indent-offset`

```elisp
(defgroup jai-ts-mode nil "Editing Jai source." :group 'languages)

(defcustom jai-ts-mode-indent-offset 4
  "Number of spaces per nesting level in `jai-ts-mode'."
  :type 'natnum :safe #'natnump :group 'jai-ts-mode)
```

Mode body: `(setq-local js-indent-level jai-ts-mode-indent-offset)`. The public
knob is Jai-named and `:safe` (a `.dir-locals.el` can set it without a prompt);
the `js-indent-level` plumbing is an implementation detail. Default 4 answers
issue #1 directly.

### 2. Indentation — `jai-ts-mode--indent-line`

As above. Mode body: `(setq-local indent-line-function #'jai-ts-mode--indent-line)`.
Your RET-in-`{}` case is then handled by the existing global
`electric-indent-mode`, which calls `indent-according-to-mode` on the new and
pushed-down lines.

**Hand-trace of the reported `for` example** (offset 4): the new body line sits
at brace-depth 2 → **8**; the `}` closing `for` is a closer-led line js dedents
to **4**; the `}` closing `foo` → **0**. Exactly the desired layout.

### 3. Syntax-table upgrades

Merge into `jai-ts-mode-syntax-table` (keeping the existing `_`-as-word and
`"`-as-string entries):

- **Nested block comments:** `?* ". 23n"` (the `n` flag) + `?/ ". 124b"`. Jai's
  `/* */` comments *nest*, unlike C — our current `". 23"` gets this wrong, and a
  `/* { */` could desync the brace counting that now drives indentation.
- **CRLF comment-ender:** `?\^m "> b"` (parity for CRLF files).
- **Backslash escape:** `?\\ "\\"` (correct string-escape parsing).
- **Operator punctuation:** `' : + - % & | ^ ! = < > ?` → `"."`. Prevents a
  stray operator/quote char from fooling `syntax-ppss`, which now feeds the
  indenter.

### 4. Sexp / JSX hygiene (mode body)

- `(setq-local parse-sexp-ignore-comments t)` — sexp navigation skips comments.
- `(setq-local js-jsx-syntax nil)` — defensively ensure js's JSX indentation
  branch never engages on Jai content.

### 5. Here-strings — `jai-ts-mode--syntax-propertize-function`

Lift upstream's `#string TAG … TAG` heredoc handler (adapted to our namespace)
and wire it via `(setq-local syntax-propertize-function …)`. It applies generic
string-fence syntax (`|`) to heredoc bodies. This is an **indentation-correctness
fix**, not cosmetics: an unbalanced `{` inside a here-string would otherwise be
counted as real nesting and throw off the indentation of everything after it.
Because our `font-lock-defaults` enables syntactic fontification, heredoc bodies
also render with string face for free.

### 6. Richer font-lock (merge, not replace)

Keep our existing wins — the `NOTE/TODO/FIXME/HACK/XXX` warning-face rule and
`#directive` highlighting — and our keyword/type lists. **Union** the keyword
list with upstream's richer set (`ifx then switch remove code_of initializer_of
size_of type_of type_info context operator is_constant enum_flags interface …`)
and add upstream's matchers:

- `foo.(Type)` postfix casts (the `jai-ts-mode--postfix-cast-syntax` matcher),
- `Foo.{}` / `bar.[]` literal-type names,
- `@notes`,
- `$T` polymorph type names,
- numeric literals, `'x` char literals, `---`.

A precise proc-name rule (`name :: [inline|#type] (`) and a
`struct|enum|union`-name rule **replace** our over-broad `name ::` →
function-name rule (which currently paints every `::` constant as a function).

**Documented caveat (carried in-code, matching our imenu caveat style):**
upstream's general `x: Type` variable-type matcher has a known false positive on
`for it_index, it: foo` (Emacs regex lacks negative lookahead). We carry the
rule with a caveat comment rather than drop the useful highlighting.

### 7. Defun navigation

Lift `jai-ts-mode--beginning-of-defun` / `--end-of-defun` (and the
`--defun-rx` / `--line-is-defun` helpers) and set `beginning-of-defun-function`
/ `end-of-defun-function`. Gives correct `C-M-a`, `C-M-e`, and `narrow-to-defun`.

### 8. Kept as-is

Our detailed, mutually-exclusive **imenu generic expression** (strictly better
than upstream's 3-line version), the `jai-ts-mode` mode name, and the
`auto-mode-alist` entry.

### 9. Attribution

Upstream `jai-mode` is GPLv3 (© Kristoffer Grönlund, Valentin Ignatev). We are
lifting substantial code (here-string `syntax-propertize`, defun navigation,
several font-lock matchers), so an attribution/provenance comment crediting
`valignatev/jai-mode` and noting the GPLv3 origin will be added to the file
header.

## Testing — `tests/jai-ts-mode-tests.el`

ERT, auto-discovered by `tests/run-tests.sh` (matches `*-tests.el`). Each test
sets up a temp buffer in `jai-ts-mode` and asserts behavior:

- **Indentation (characterization):** the reported `for` example indents to
  8 / 4 / 0; a nested two-brace body; a closer-led `}` dedents.
- **Directive safety:** indenting a `#`-led line (`#import`, indented `#if`)
  runs without error and produces a sane column (regression guard for the
  `void-variable` crash the confined neutering prevents).
- **Nested comments:** a point inside `/* outer /* inner */ still outer */` is
  in-comment (`nth 4` of `syntax-ppss`).
- **Here-strings:** a `{` inside a `#string TAG … TAG` body is inside a string
  (`nth 3`), and code after the heredoc indents as if the heredoc braces did not
  exist.
- **Offset knob:** setting `jai-ts-mode-indent-offset` propagates to
  `js-indent-level` and changes the produced indent.
- **Defun nav:** `jai-ts-mode--beginning-of-defun` from inside a proc lands on
  the proc's declaration line.
- **Font-lock spot-checks (light):** a numeric literal and an `@note` carry the
  expected face after `font-lock-ensure`.

## Non-goals / honest limits

- **js-indent-line is tuned for JS/C++, not Jai.** It will occasionally indent a
  Jai-only form (an unusual `::` construct, a trailing `---`) in a JS-flavored
  way, and there is no Jai-specific knob to correct it — you would be tuning
  js.el internals. This is the accepted cost of adopting a mature foreign engine
  over a fully-owned dumb one; upstream's daily use says it is a good trade.
- **No tree-sitter, no jails LSP.** Unchanged and intentional (CLAUDE.md).
- **The font-lock `x: Type` false positive** (above) is accepted and documented,
  not fixed — fixing it needs negative lookahead Emacs regex lacks.

## Affected files

- `jai-ts-mode.el` — roughly doubles: new `defgroup`/`defcustom`, indent wrapper
  + special declaration, syntax-table merge, here-string `syntax-propertize`,
  richer font-lock, defun navigation, attribution header, mode-body wiring.
- `tests/jai-ts-mode-tests.el` — new ERT suite (the repo's first tests for this
  mode).
