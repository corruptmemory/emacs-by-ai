# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal Emacs configuration. Requires Emacs 29+. No build system. Most `.el` files are loaded directly by Emacs; `cm-project-roots.el` has an ERT suite under `tests/` (run `./tests/run-tests.sh`). Test changes with:

```sh
emacs --init-directory=~/projects/emacs-again/
```

## Key Files

- `early-init.el` — GC tuning, UI suppression, native-comp settings, fringe/cursor config
- `init.el` — Package management (straight.el + use-package), all packages, keybindings, language configs
- `jai-ts-mode.el` — Jai major mode (`js-indent-line` indentation, regex font-lock, nested-comment/here-string syntax, defun navigation; tree-sitter intentionally not used — see below)
- `themes/` — Custom color themes (Dracula Pro Blade/Pro, Naysayer)
- `vendor/` — Upstream assets vendored as plain text, refreshed on demand (currently: `github-markdown.css` for the markdown preview)
- `local-settings.el` — Machine-specific overrides (git-ignored); sets `cm/mouse-profile` etc.
- `scripts/emacs-send` — Shell script for sending files/commands to a running Emacs instance (self-installs via `--install`)

## Architecture of init.el

The file is organized in this order:

1. **Startup/bootstrap** — timing display, straight.el bootstrap, use-package integration
2. **Core settings** — custom file, local overrides, backups, auto-revert, delete-selection, electric-indent, electric-pair (auto-close + brace expansion on RET), tabs, performance (bidi off, skip fontification on input, 4MB process buffer), kill ring (clipboard preservation, dedup), editing niceties (auto-chmod scripts, no ffap pings, string re-builder syntax, auto-select help windows, repeat mark popping), recentf, saveplace (with recenter after restore), per-instance server (PID-named, stale socket cleanup)
3. **PATH** — adds ~/.cargo/bin, ~/.local/bin, ~/go/bin, ~/projects/Odin, ~/projects/ols to exec-path
4. **Theme and fonts** — loads dracula-pro-blade, sets TX-02/Fira Sans/JoyPixels, auto-adjusts fringe contrast
5. **Scrolling** — pixel-scroll-precision-mode with wheel/trackpad profiles driven by `cm/mouse-profile`; trackpad flips horizontal scroll and disables interpolated page scroll for instant PgUp/PgDn
6. **Keybindings and editing** — winner-mode (layout undo/redo, reversible `C-x 1`), proportional window resizing, windmove, quick toggles (`C-c T` prefix), chunk word motion (`cm/` prefix), line movement, sexp navigation
7. **Minibuffer completion** — Vertico (+ directory, repeat, multiform extensions), Orderless, Marginalia, savehist, prescient
8. **Consult** — region-seeded and thing-at-point search wrappers (`cm/` prefix), embark integration
9. **In-buffer completion** — Corfu (+ history, popupinfo), tempel, cape, kind-icon
10. **Editing packages** — multiple-cursors (with symbol-aware mark/skip bindings), expand-region, string-inflection, smartparens, flyspell (text-like modes only: text, org, markdown)
11. **Git** — Magit, diff-hl (with flydiff for unsaved-change indicators)
12. **Popup/buffer management** — Popper with project-based grouping, helpful, vterm
13. **Dev tooling** — treesit-auto, yasnippet, eglot (20+ language hooks, autoreconnect, harper-ls for writing modes), eglot-booster, consult-eglot, eldoc-box, flymake, dape (DAP)
14. **Language configs** — Go (format-on-save, gotest, dape/Delve wrappers with auto-breakpoint), SQL (xref helpers, completion), docker, pdf-tools, compile-mode tweaks (ANSI color + Jai `line,column` error navigation — see below), then all other languages
15. **AI writing assistant** — `cm/ai-*` exchange protocol for Claude Code integration (`C-c a` prefix), shared via `~/.emacs-ai/`, interactive `*ai-suggestions*` review buffer (`C-c a S`)
16. **Multi-root project search** — `cm-project-roots.el` (loaded after the consult-eglot block): opt-in `C-c w` commands spanning dirs listed in a `.project-roots` file; LSP-first jump/refs, rg-based search/find-file; see below
17. **Project TAGS auto-loading** — `cm-project-tags.el` (loaded after the multi-root block): on `find-file`, if the project root holds a `TAGS` file, load it buffer-locally and install the `cm/tags-cascade` xref backend (etags → dumb-jump fallback; yields to Eglot). See below.
18. **Per-project session persistence** — `cm-project-sessions.el` (loaded after
    the project-TAGS block): `C-x p p` saves the current project's easysession
    session, tears the workspace down, and restores (or creates) the target's —
    files, window/split layout, per-file point (via `saveplace`), and unsaved
    scratch buffers. Two scratch tiers (per-project + global stash). See below.

## Naming Conventions

- `cm/` prefix — all custom functions and variables (`cm` = corruptmemory)

## Themes

All themes in `themes/` follow the standard Emacs pattern: `deftheme` → color definitions → `custom-theme-set-faces` → `provide-theme`. Dracula themes use `let`-bound alists with GUI/256/TTY color entries and support `defcustom` options for heading sizes and mode-line styles. When adding faces, follow the existing `(,face ((,class (:foreground ,color ...))))` pattern within the `let` block.

## Custom LSP Servers

Non-default eglot server entries are configured for: Odin (`ols`), Zig (`zls`), go-templ (`templ lsp`), GLSL (`glslls`), Fish (`fish-lsp`), Haskell (`haskell-language-server-wrapper`), Harper (`harper-ls` — grammar/spell checking for org/markdown/text modes).

Jai (`jails`) is **intentionally left unwired**, even though the `jails` binary is now installed (`~/.local/bin/jails`) and a `jails.json` exists in `~/projects/game-bootstrap`. jails is flakey and slow and tends to drop code navigation entirely when it breaks; the preferred setup is graceful degradation over an unreliable LSP — `jai-ts-mode` regex font-lock + `dumb-jump` + the `C-c w` multi-root grep commands (see "Multi-root project search" below), which lands in the "good enough" zone. Do **not** uncomment the `eglot-server-programs` entry or add `jai-ts-mode` to the eglot hook list.

Slang (`slangd`, shader-slang.org) uses [`K1ngst0m/slang-mode`](https://github.com/K1ngst0m/slang-mode) — a purpose-built major mode (regex font-lock + indent + imenu) plus its `slang-lsp.el`, which auto-registers `slangd` with eglot **only when it is found on `PATH`** (install via AUR `shader-slang-bin`, symlinked into `~/.local/bin`). Two gotchas are baked into the `init.el` block: (1) `slang-lsp-initialize` mutates eglot *globally* — it adds `flymake` to `eglot-stay-out-of` (which would suppress eglot's flymake diagnostics in **every** language), so the config `delq`s it back out; (2) hover needs a recent eglot — `emacs-straight/eglot` 1.23 at commit `3371f2b` shipped a `gfm-extract` markup-render bug (`invalid-function #'gfm-extract`), fixed by `straight-pull-package eglot` (≥ `3c64b09`). The mode's floor works with no LSP; `C-c w r` multi-root grep covers references (which `slangd` can't do yet).

## Tree-Sitter and Arch Linux

Tree-sitter grammars live in `tree-sitter/` (not checked into git — rebuilt per machine). To rebuild all grammars:

```bash
rm ~/projects/emacs-again/tree-sitter/*.so
emacs --batch --init-directory=~/projects/emacs-again -l init.el --eval '
(progn (require (quote treesit-auto)) (treesit-auto-install-all))'
```

**Known incompatibility:** Emacs 30.2's `treesit.c` is incompatible with tree-sitter 0.26+ (predicate naming conflict — Emacs uses `#match`, tree-sitter 0.26 requires `#match?`, and both validate in C). As of 2026-04-09, this system runs `tree-sitter 0.25.10` + `emacs-wayland 30.2-1` with both pinned in `/etc/pacman.conf` `IgnorePkg`. If tree-sitter modes break after a system update, check `pacman -Qi tree-sitter` — if it's 0.26+, downgrade both packages and rebuild grammars. See `docs/tree-sitter-026-fix.md` for the full diagnosis and step-by-step fix.

## Jai and Tree-Sitter

`jai-ts-mode.el` deliberately does **not** use tree-sitter. Jai's bracketed/unbracketed control flow variants (every control form has both `if x { }` and `if x stmt;` styles) cause the LR automaton state count to exceed tree-sitter's hard-coded 64K limit. Multiple serious attempts to build a complete grammar failed for this reason. The best available grammar (`overlord-systems/jai-tree-sitter`) only parses variable declarations and produces ERROR nodes for nearly all real code. Indentation, font-lock, and navigation are therefore hand-rolled (see next section).

## Jai editing (`jai-ts-mode`)

Beyond regex font-lock, `jai-ts-mode` provides a real editing experience without
tree-sitter or an LSP. Indentation, here-string handling, defun navigation, and
several font-lock matchers are adapted from the mature upstream
[`valignatev/jai-mode`](https://github.com/valignatev/jai-mode) (GPLv3; an
attribution header in the file records this — lifting that code makes the file
effectively GPLv3 if the repo is ever published).

- **Indentation** is `js-indent-line` (js-mode's C-style engine — Jai is
  brace-structured, so it indents bodies, dedents closers, and aligns
  `(`-continuations). The offset is `jai-ts-mode-indent-offset` (a `defcustom`,
  default 4, `:safe`), read into `js-indent-level` at mode activation. **Key
  gotcha:** js-mode's `js--proper-indentation` treats `#`-led lines as C
  preprocessor macros and references `cpp-font-lock-keywords-source-directives`,
  which is *unbound* in Emacs 30.2 — so a naive `js-indent-line` signals
  `void-variable` on any Jai `#import`/`#run`/`#if`. `jai-ts-mode--indent-line`
  fixes this by **dynamically `let`-binding** the three js internals
  (`js--opt-cpp-start`, `js--macro-decl-re`,
  `cpp-font-lock-keywords-source-directives`) to an impossible regex
  (`"\\_<\\_>"`) for the extent of the call. A bare `(defvar
  cpp-font-lock-keywords-source-directives)` (declaration, **no value**) makes
  the third symbol special so the `let` actually binds it in this
  lexical-binding file. Upstream clobbers these with global `defconst`s; we
  confine the neutering to Jai indentation so js-mode buffers elsewhere are
  untouched.
- **Syntax table:** Jai's `/* */` block comments **nest** (`?* ". 23n"`), unlike
  C; operator/quote chars are punctuation so a stray one can't fool
  `syntax-ppss` (which drives indentation).
- **Here-strings:** `jai-ts-mode--syntax-propertize-function` marks `#string TAG
  … TAG` heredoc bodies as strings, so braces inside them don't corrupt nesting
  depth (an indentation-correctness fix, not just cosmetics).
- **Font-lock** covers postfix casts `foo.(Type)`, `.{}`/`.[]` literal types,
  `@notes`, `$T` polymorphs, numbers, char literals, `---`, and a rich keyword
  set, alongside the kept `NOTE/TODO/FIXME/HACK/XXX` rule and the precise
  proc/`struct`/`enum`/`union` name rules. The general `x: Type` rule carries a
  documented false-positive caveat (it mis-highlights `for it_index, it: foo` —
  Emacs regex has no negative lookahead).
- **Navigation:** `beginning/end-of-defun` (`C-M-a`/`C-M-e`/`narrow-to-defun`),
  robust against malformed/mid-edit buffers (BOB-guarded backward scan;
  `forward-sexp` wrapped in `ignore-errors`). Note the `end-of-defun-function`
  contract: the `end-of-defun` command pre-positions point at the defun's
  *beginning* (depth 0) and only then calls the function, so `--end-of-defun`
  walks from the opening line via `forward-sexp` — it does **not** assume point
  is inside the body (the bug that made `C-M-e` jump backward; commit `c35221f`).
  Test the editor *commands*, not the hook functions, on nested-`.{}` procs.
- **Not changed:** the detailed imenu generic expression, the `jai-ts-mode` name,
  and the deliberate no-`jails`/no-tree-sitter stance.

Design + plan: `docs/plans/2026-06-29-jai-ts-mode-indentation-{design,plan}.md`.
ERT suite: `tests/jai-ts-mode-tests.el` (`./tests/run-tests.sh`).

## Compilation buffers

Two `compile`-mode tweaks live just before the Jai block in `init.el`:

- **Jai error navigation.** Jai writes diagnostics as `file:line,column:` — a **comma** between line and column. Emacs' built-in `gnu` pattern in `compilation-error-regexp-alist` only accepts `:` or `.` there, so without help `next-error` can't see Jai errors at all. A custom `jai` entry is registered (inside `with-eval-after-load 'compile`); a `Warning`/`Info` keyword sets the face, anything else (incl. `Error`) is an error, and the pattern is anchored to `.jai` so it can't misfire on Go/Rust/etc. builds.
- **ANSI color.** `ansi-color-compilation-filter` is added to `compilation-filter-hook` (not enabled by default in Emacs 30.2) so compile buffers render SGR escapes as faces instead of leaving raw `^[[…m` codes in the buffer.

**Why color appears at all:** Emacs runs `compile` on a PTY (`isatty` is true), and tools like the Jai compiler only colorize when the output terminal supports color — so a raw shell pipe (non-TTY) already suppresses it, but the Emacs buffer does not. For Jai specifically, `-no_color` is implemented by the **Default Metaprogram**, so a project with its own `first.jai` build metaprogram must propagate `use_ansi_color` to its target workspace (`copy_commonly_propagated_fields(get_build_options(), *opts)`) for `-no_color` to reach the real build. The `ansi-color` filter is the belt-and-suspenders that keeps the buffer clean either way.

## AI Writing Assistant (Claude Code Integration)

File-based exchange protocol at `~/.emacs-ai/` for interactive writing feedback:
- `cm/ai-share` (`C-c a s`) — snapshots buffer, region, or org subtree (C-u) to `content.txt` + `context.json`
- `cm/ai-accept` (`C-c a a`) — applies suggestion from `suggestion.txt` at point or replacing region
- `cm/ai-diff` (`C-c a d`) — diffs current text against suggestion
- `cm/ai-show-suggestions` (`C-c a S`) — opens `*ai-suggestions*` review buffer (see below)
- For saved files, Claude Code can edit directly — `global-auto-revert-mode` picks up changes

Remote query functions — **always use `emacs-send -e` instead of raw `emacsclient`** (it resolves the correct PID-based server, cleans stale sockets, and never spawns rogue instances):
- `(cm/ai-current-context)` — JSON with file, mode, line, column, region bounds, org heading path
- `(cm/ai-visible-buffers)` — JSON array of all visible buffers across frames
- `(cm/ai-get-content)` — snapshots focused buffer to exchange dir, returns context JSON
- `(cm/ai-get-content "buffer-name")` — snapshots a specific buffer by name
- `(cm/ai-paragraph-at-point)` — returns paragraph text at point (no side effects)
- `(cm/ai-line-at-point)` — returns current line text
- `(cm/ai-region-or-paragraph)` — JSON with region text if active, else paragraph at point
- `(cm/ai-org-subtree-at-point)` — returns org subtree at point (nil outside org-mode)
- `(cm/ai-nearby-lines)` / `(cm/ai-nearby-lines N)` — context lines around point with arrow marker
- `(cm/ai-show-suggestions)` — display `*ai-suggestions*` buffer from `suggestions.json`

### Multi-Suggestion Review (`*ai-suggestions*` buffer)

For presenting multiple rewrite options, Claude Code writes `~/.emacs-ai/suggestions.json` then calls `(cm/ai-show-suggestions)` via emacsclient. The buffer shows original text and suggestions side-by-side with single-key navigation:
- `n`/`p` — next/previous section
- `a` or `RET` — apply suggestion at point to source buffer
- `d` — diff suggestion vs original
- `q` — dismiss

**`suggestions.json` format:**
```json
{
  "original": "the original text",
  "suggestions": [
    { "label": "More concise", "text": "rewritten version 1" },
    { "label": "Formal tone", "text": "rewritten version 2" }
  ],
  "source": {
    "file": "/path/to/file",
    "buffer": "buffer-name",
    "scope": "region|buffer|paragraph|subtree",
    "start-line": 9,
    "end-line": 9
  }
}
```

## Multi-root project search ("Add Folder to Project")

`cm-project-roots.el` (a sibling library loaded from `init.el`, like `jai-ts-mode.el`) adds opt-in commands that run search/navigation across directories listed in a `.project-roots` file at the primary project root. The primary root is implicit; extra dirs are one-per-line (`#` comments, `~`/relative allowed, missing dirs skipped with a warning). `cm/project-roots` is the single source of truth all commands read.

- `C-c w s` / `r` / `f` / `j` — search / references / find-file / jump-to-definition across all roots.
- `C-c w a` / `e` — add a folder (`cm/project-add-root`) / edit `.project-roots`.
- **LSP-first**: jump (`:definitionProvider`) and references (`:referencesProvider`) prefer Eglot when the buffer is managed and the server is capable, falling back to multi-root dumb-jump / ripgrep otherwise. `C-u` forces the fallback. Search and find-file are always ripgrep-based (LSP has no equivalent).
- Existing single-root commands are untouched (the feature is purely additive).

Tests: ERT suite under `tests/`, run with `./tests/run-tests.sh` (integration tests `skip-unless` `rg`/`dumb-jump` are present). Design + plan: `docs/plans/2026-06-06-multi-root-project-design.md` and `…-plan.md`.

## Project TAGS auto-loading

`cm-project-tags.el` (a sibling library loaded from `init.el`, like
`cm-project-roots.el`) auto-loads a build-generated `TAGS` index and wires it
into navigation. On `find-file`, in any `prog-mode` buffer, `cm/project-tags-file`
checks the project root (via `project-current`) for a `TAGS`; if present it is
bound buffer-locally (`setq-local` of both `tags-table-list` and
`tags-file-name` — never a global `visit-tags-table`, so projects don't pollute
each other) and a custom xref backend is installed. Binding both is required:
with only `tags-table-list`, etags conflicts with the global `tags-file-name` a
previously-visited project left behind and prompts "Keep current list of tags
tables also?" (or misses the lookup).

**Navigation priority** (`cm/tags-cascade`, a `cl-defmethod` xref backend):

| In a buffer where… | Backend used |
|---|---|
| Eglot manages it | LSP alone (the cascade returns nil) |
| no LSP, project root has `TAGS` | **etags → dumb-jump fallback** |
| neither | dumb-jump via `xref-union` (unchanged) |

The cascade is added to `xref-backend-functions` at depth `-100` (above
`xref-union-hook-depth`'s `-95`), so `run-hook-with-args-until-success` selects
it first and `xref-union` never absorbs it. `definitions` tries `etags` (which
returns nil — not an error — on a miss) and only then `dumb-jump`, so a TAGS hit
is a **direct jump** while misses still fall back. `references` delegates
straight to `dumb-jump` (etags has no references method), preserving the exact
non-LSP `M-?` behavior. `identifier-at-point`, completion, and `apropos`
delegate to `etags`.

**Reload on regenerate:** `tags-revert-without-query` is `t` (set in `init.el`),
so etags silently re-reads the table whenever its on-disk modtime changes — the
next `M-.` after a rebuild uses the fresh index. No file-watcher.

**Index-quality caveat (a property of the generator, not the cascade).** `M-.`
precision depends on the `TAGS` generator emitting standard etags *def-text* —
the source line's leading text, **indentation included** — as the relocation
pattern. etags goes to the recorded line and re-searches for that pattern
anchored at `^`; a generator that records only the bare identifier (no
indentation) relocates column-0 symbols (top-level procs/structs/globals) but
fails on every *indented* symbol (struct fields, nested decls) with `Rerun
etags: '^NAME' not found`, because `^NAME` can't match `    NAME`. The cascade
still did its job (it consulted the precise index); the fix belongs in the
generator. (The byte-offset field is irrelevant once the pattern matches.) This
bit `game-bootstrap`'s `modules/ctags` until it was taught to emit the indented
line prefix.

**The driving case is Jai** (`~/projects/game-bootstrap`), whose `first.jai`
emits a compiler-precise ETAGS index every successful build and which has no
wired LSP — but the feature is generic: a `TAGS` file at a project root is taken
as the signal that good tooling produced it. Where an LSP exists, the cascade
yields and LSP wins, so "generic" costs nothing. Tests: ERT suite under `tests/`
(`./tests/run-tests.sh`). Design + plan:
`docs/plans/2026-06-25-project-tags-design.md` and `…-plan.md`.

## Per-project session persistence

`cm-project-sessions.el` (a sibling library, like `cm-project-tags.el`) layers
over the `easysession` package to give an ephemeral Emacs Sublime-style project
workspaces. Model: **sessions-as-projects** — one easysession session per project,
keyed by project root.

- **`C-x p p`** is advised (`:around`) to *flip*: prompt-save modified files →
  save the global stash → `easysession-save` the current project → kill the
  current project's scratch buffers and `easysession-kill-all-buffers` (teardown)
  → `easysession-switch-to` the target (load existing, or create blank) → reload
  the stash. A brand-new project lands blank and opens `project-find-file`.
  Note: the advice replaces the default `project-switch-project` dispatch menu
  entirely — `C-x p p` does the session flip directly; the individual
  `project-*` commands (e.g. `project-find-file`) are untouched.
- **Two scratch tiers.** `C-c n` instantly makes a per-project scratch buffer
  `*scratch:<proj>:N*` (rides that project's session). `C-u C-c n` prompts for a
  name and makes a global stash buffer `*stash:<name>*` (always present, persisted
  in `cm/stash-file`, independent of any session). The lone `*scratch*` is part of
  the global tier. Default major mode: `cm/scratch-default-mode` (`text-mode`).
- **Startup = restore-by-launch-directory.** If the launch dir is a known project
  with a saved session, it is restored; otherwise Emacs stays blank until `C-x p p`.
  This makes the multi-instance habit (one project per Emacs) restore correctly.
- **Auto-save** (`easysession-save-mode`): on flip, on exit, and every
  `cm/session-save-interval` seconds (default 60).
- **Point restoration** relies on `saveplace`; the setup removes
  `save-place-find-file-hook` from `easysession-exclude-from-find-file-hook`
  (easysession suppresses it by default).
- **Not restored by design:** process-backed buffers (REPLs, terminals, LSP) —
  they re-spawn on demand.
- **Caveat:** two concurrent instances on the *same* project share one session
  name; periodic auto-save is last-writer-wins. The expected usage is one instance
  per project, so this is documented rather than guarded.

Design + plan: `docs/plans/2026-06-28-project-sessions-{design,plan}.md`. ERT
suite under `tests/`.

**Implementation gotchas (easysession integration):**

- The per-project scratch handler is registered with **`easysession-define-generic-save-handler`**, not `easysession-define-save-handler`. The latter expects the user save function to return `((buffers . DATA) (remaining-buffers . REST))`; our `cm/scratch--save-handler` is a *pure* serializer returning a plain `((NAME . ((buffer-string . TEXT))) …)` alist (so it stays unit-testable without easysession). `cm/session--install-handlers` bridges the two — it builds the structured `(key value remaining-buffers)` result and lets the built-in file/dired handlers consume the `remaining-buffers`. Registering the plain serializer directly via `easysession-define-save-handler` silently stores `nil` (the scratch buffers vanish).
- `cm/project-sessions-setup` sets **`easysession-confirm-new-session` to nil** so the first `C-x p p` into a project creates its session silently — easysession otherwise prompts "create new session?", which would defeat the zero-ceremony flip.

## Markdown preview

`C-c C-c p` in a `.md` buffer renders via `cmark-gfm` (GFM extensions: tables, strikethrough, autolinks, tasklists) and opens the HTML in the browser. Output is wrapped in `<article class="markdown-body">…</article>` — that wrapper is the load-bearing contract that connects [sindresorhus/github-markdown-css](https://github.com/sindresorhus/github-markdown-css) (every rule scoped to `.markdown-body`) to the rendered HTML. Without it, the linked stylesheet matches nothing. The CSS is vendored at `vendor/github-markdown.css` and its `file://` URL is computed from `user-emacs-directory` inside the `markdown-mode` `:custom` block, so a fresh clone needs no install step. Refresh from upstream:

```sh
curl -fsSL https://raw.githubusercontent.com/sindresorhus/github-markdown-css/main/github-markdown.css \
  -o vendor/github-markdown.css
```

### Nested fences

CommonMark closes an N-backtick fence on the next line of M ≥ N matching backticks (with up to 3 spaces of leading indent allowed on the closer). A markdown document that contains *another* markdown sample with its own ``` fences inside therefore cannot use a 3-backtick outer — the first inner closer will end the outer block prematurely. Two workarounds, both supported by `cmark-gfm` and `markdown-mode`:

- **4-backtick outer fence** (e.g. ` ````markdown … ```` `) — visually consistent with the surrounding 3-backtick fences.
- **Tilde outer fence** (`~~~markdown … ~~~`) — distinct fence character, never interacts with backtick content regardless of count. Useful when you want a visible distinction between "container" and "contained" rather than a different number of the same character.

Inner content with `~~~` lines would similarly break a tilde outer; the escalation pattern generalizes — use N+1 of whichever character your inner content doesn't already use.
