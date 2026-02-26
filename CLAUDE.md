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
- `themes/` — Custom color themes (Dracula Pro Blade/Pro, Naysayer)
- `local-settings.el` — Machine-specific overrides (git-ignored); sets `cm/mouse-profile` etc.
- `scripts/emacs-send` — Shell script for sending files/commands to a running Emacs instance (self-installs via `--install`)

## Architecture of init.el

The file is organized in this order:

1. **Startup/bootstrap** — timing display, straight.el bootstrap, use-package integration
2. **Core settings** — custom file, local overrides, backups, auto-revert, delete-selection, electric-indent, tabs, recentf, saveplace, per-instance server
3. **PATH** — adds ~/.cargo/bin, ~/.local/bin, ~/go/bin, ~/projects/Odin, ~/projects/ols to exec-path
4. **Theme and fonts** — loads dracula-pro-blade, sets TX-02/Fira Sans/JoyPixels, auto-adjusts fringe contrast
5. **Scrolling** — pixel-scroll-precision-mode with wheel/trackpad profiles driven by `cm/mouse-profile`; trackpad flips horizontal scroll and disables interpolated page scroll for instant PgUp/PgDn
6. **Keybindings and editing** — windmove, quick toggles (`C-c T` prefix), chunk word motion (`cm/` prefix), line movement, sexp navigation
7. **Minibuffer completion** — Vertico (+ directory, repeat, multiform extensions), Orderless, Marginalia, savehist, prescient
8. **Consult** — region-seeded and thing-at-point search wrappers (`cm/` prefix), embark integration
9. **In-buffer completion** — Corfu (+ history, popupinfo), tempel, cape, kind-icon
10. **Editing packages** — multiple-cursors (with symbol-aware mark/skip bindings), expand-region, string-inflection, smartparens, flyspell (text-like modes only: text, org, markdown)
11. **Git** — Magit, diff-hl (with flydiff for unsaved-change indicators)
12. **Popup/buffer management** — Popper with project-based grouping, helpful, vterm
13. **Dev tooling** — treesit-auto, yasnippet, eglot (20+ language hooks, autoreconnect), eglot-booster, consult-eglot, eldoc-box, flymake, dape (DAP)
14. **Language configs** — Go (format-on-save, gotest, dape/Delve wrappers with auto-breakpoint), SQL (xref helpers, completion), docker, pdf-tools, then all other languages

## Naming Conventions

- `cm/` prefix — all custom functions and variables (`cm` = corruptmemory)

## Themes

All themes in `themes/` follow the standard Emacs pattern: `deftheme` → color definitions → `custom-theme-set-faces` → `provide-theme`. Dracula themes use `let`-bound alists with GUI/256/TTY color entries and support `defcustom` options for heading sizes and mode-line styles. When adding faces, follow the existing `(,face ((,class (:foreground ,color ...))))` pattern within the `let` block.

## Custom LSP Servers

Non-default eglot server entries are configured for: Odin (`ols`), Zig (`zls`), Jai (`jails` — path-expanded with OS-adaptive compiler binary name), go-templ (`templ lsp`), GLSL (`glslls`), Fish (`fish-lsp`), Haskell (`haskell-language-server-wrapper`).
