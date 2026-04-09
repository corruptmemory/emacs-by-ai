# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal Emacs configuration. Requires Emacs 29+. No build system or tests — the `.el` files are loaded directly by Emacs. Test changes with:

```sh
emacs --init-directory=~/projects/emacs-again/
```

## Key Files

- `early-init.el` — GC tuning, UI suppression, native-comp settings, fringe/cursor config
- `init.el` — Package management (straight.el + use-package), all packages, keybindings, language configs
- `jai-ts-mode.el` — Jai major mode (regex font-lock + syntax table; tree-sitter intentionally not used — see below)
- `themes/` — Custom color themes (Dracula Pro Blade/Pro, Naysayer)
- `local-settings.el` — Machine-specific overrides (git-ignored); sets `cm/mouse-profile` etc.
- `scripts/emacs-send` — Shell script for sending files/commands to a running Emacs instance (self-installs via `--install`)

## Architecture of init.el

The file is organized in this order:

1. **Startup/bootstrap** — timing display, straight.el bootstrap, use-package integration
2. **Core settings** — custom file, local overrides, backups, auto-revert, delete-selection, electric-indent, electric-pair (auto-close + brace expansion on RET), tabs, performance (bidi off, skip fontification on input, 4MB process buffer), kill ring (clipboard preservation, dedup), editing niceties (auto-chmod scripts, no ffap pings, string re-builder syntax, auto-select help windows, repeat mark popping), recentf, saveplace (with recenter after restore), per-instance server (PID-named, stale socket cleanup)
3. **PATH** — adds ~/.cargo/bin, ~/.local/bin, ~/.elan/bin, ~/go/bin, ~/projects/Odin, ~/projects/ols to exec-path
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
14. **Language configs** — Go (format-on-save, gotest, dape/Delve wrappers with auto-breakpoint), SQL (xref helpers, completion), docker, pdf-tools, then all other languages
15. **AI writing assistant** — `cm/ai-*` exchange protocol for Claude Code integration (`C-c a` prefix), shared via `~/.emacs-ai/`, interactive `*ai-suggestions*` review buffer (`C-c a S`)

## Naming Conventions

- `cm/` prefix — all custom functions and variables (`cm` = corruptmemory)

## Themes

All themes in `themes/` follow the standard Emacs pattern: `deftheme` → color definitions → `custom-theme-set-faces` → `provide-theme`. Dracula themes use `let`-bound alists with GUI/256/TTY color entries and support `defcustom` options for heading sizes and mode-line styles. When adding faces, follow the existing `(,face ((,class (:foreground ,color ...))))` pattern within the `let` block.

## Custom LSP Servers

Non-default eglot server entries are configured for: Odin (`ols`), Zig (`zls`), go-templ (`templ lsp`), GLSL (`glslls`), Fish (`fish-lsp`), Haskell (`haskell-language-server-wrapper`), Harper (`harper-ls` — grammar/spell checking for org/markdown/text modes).

Jai (`jails`) is commented out — the binary must be built manually from `~/projects/Jails`. Uncomment the `eglot-server-programs` entry and add `jai-ts-mode` back to the eglot hook list once it exists.

Lean 4 uses **lsp-mode** (not eglot) via `lean4-mode` — this is the one exception to the eglot-everywhere pattern. lsp-mode is pulled in as a dependency and only activates in `.lean` buffers. The interactive Info-View (`C-c C-i` to toggle; shows proof state / goals) requires lsp-mode's extension hooks. `lsp-completion-provider` is set to `:none` so corfu handles completion via capf instead of company-mode. Requires `elan` toolchain manager (`~/.elan/bin` is on exec-path).

## Tree-Sitter and Arch Linux

Tree-sitter grammars live in `tree-sitter/` (not checked into git — rebuilt per machine). To rebuild all grammars:

```bash
rm ~/projects/emacs-again/tree-sitter/*.so
emacs --batch --init-directory=~/projects/emacs-again -l init.el --eval '
(progn (require (quote treesit-auto)) (treesit-auto-install-all))'
```

**Known incompatibility:** Emacs 30.2's `treesit.c` is incompatible with tree-sitter 0.26+ (predicate naming conflict — Emacs uses `#match`, tree-sitter 0.26 requires `#match?`, and both validate in C). As of 2026-04-09, this system runs `tree-sitter 0.25.10` + `emacs-wayland 30.2-1` with both pinned in `/etc/pacman.conf` `IgnorePkg`. If tree-sitter modes break after a system update, check `pacman -Qi tree-sitter` — if it's 0.26+, downgrade both packages and rebuild grammars. See memory file `tree-sitter-026-fix.md` for the full diagnosis and step-by-step fix.

## Jai and Tree-Sitter

`jai-ts-mode.el` deliberately does **not** use tree-sitter. Jai's bracketed/unbracketed control flow variants (every control form has both `if x { }` and `if x stmt;` styles) cause the LR automaton state count to exceed tree-sitter's hard-coded 64K limit. Multiple serious attempts to build a complete grammar failed for this reason. The best available grammar (`overlord-systems/jai-tree-sitter`) only parses variable declarations and produces ERROR nodes for nearly all real code. Syntax highlighting uses regex font-lock instead.

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
