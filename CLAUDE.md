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
- `local-settings.el` — Machine-specific overrides (git-ignored); sets `my/mouse-profile` etc.

## Architecture of init.el

The file is organized in this order:

1. **Startup/bootstrap** — timing display, straight.el bootstrap, use-package integration
2. **Core settings** — custom file, local overrides, backups, auto-revert, tabs, recentf, saveplace
3. **PATH** — adds ~/.cargo/bin, ~/.local/bin, ~/go/bin, ~/projects/Odin, ~/projects/ols to exec-path
4. **Theme and fonts** — loads dracula-pro-blade, sets TX-02/Fira Sans/JoyPixels, auto-adjusts fringe contrast
5. **Scrolling** — pixel-scroll-precision-mode with wheel/trackpad profiles driven by `my/mouse-profile`
6. **Keybindings and editing** — windmove, chunk word motion (`cm/` prefix), line movement, sexp navigation
7. **Minibuffer completion** — Vertico (+ directory, repeat, multiform extensions), Orderless, Marginalia, savehist, prescient
8. **Consult** — region-seeded and thing-at-point search wrappers (`my/` prefix), embark integration
9. **In-buffer completion** — Corfu (+ history, popupinfo), tempel, cape, kind-icon
10. **Editing packages** — multiple-cursors, expand-region, string-inflection
11. **Git** — Magit, diff-hl
12. **Popup/buffer management** — Popper with project-based grouping, helpful
13. **Dev tooling** — treesit-auto, yasnippet, eglot (20+ language hooks), eglot-booster, consult-eglot, eldoc-box, flymake, dape (DAP)
14. **Language configs** — Go (format-on-save, gotest, dape wrappers), SQL (xref helpers, completion), then all other languages

## Naming Conventions

- `my/` prefix — utility functions and variables for personal config plumbing
- `cm/` prefix — interactive commands and editing functions (word motion, line movement, dape wrappers, SQL tools)

## Themes

All themes in `themes/` follow the standard Emacs pattern: `deftheme` → color definitions → `custom-theme-set-faces` → `provide-theme`. Dracula themes use `let`-bound alists with GUI/256/TTY color entries and support `defcustom` options for heading sizes and mode-line styles. When adding faces, follow the existing `(,face ((,class (:foreground ,color ...))))` pattern within the `let` block.

## Custom LSP Servers

Non-default eglot server entries are configured for: Odin (`ols`), Zig (`zls`), Jai (`jails` — path-expanded with OS-adaptive compiler binary name), go-templ (`templ lsp`), GLSL (`glslls`), Fish (`fish-lsp`), Haskell (`haskell-language-server-wrapper`).
