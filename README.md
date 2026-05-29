# emacs-again

Personal Emacs configuration built from scratch. Requires Emacs 29+ (uses built-in tree-sitter and eglot).

## Quick start

```sh
emacs --init-directory=~/projects/emacs-again/
```

On first launch, `straight.el` bootstraps itself and installs all packages. Tree-sitter grammars are installed on demand (you'll be prompted).

## Structure

| File                | Purpose                                                                 |
|---------------------|-------------------------------------------------------------------------|
| `early-init.el`     | GC tuning, UI suppression, native-comp settings — runs before `init.el` |
| `init.el`           | Everything else: packages, keybindings, language configs                |
| `themes/`           | Custom color themes (Dracula Pro Blade, Dracula Pro Pro, Naysayer)      |
| `snippets/`         | User-defined yasnippet/tempel snippets                                  |
| `local-settings.el` | Machine-specific overrides (git-ignored)                                |
| `custom.el`         | Emacs customize output (git-ignored)                                    |
| `scripts/emacs-send`| Send files/commands to a running Emacs (`--install` to symlink)         |

## Package management

[straight.el](https://github.com/radian-software/straight.el) with `use-package` integration. Every `use-package` declaration installs via straight automatically (`straight-use-package-by-default t`).

## Completion stack

Vertico + Orderless + Consult + Marginalia + Embark in the minibuffer; Corfu + Cape + kind-icon in-buffer. Prescient provides frequency/recency sorting for Vertico. Smartparens handles auto-pairing and structured delimiter editing.

## LSP

Eglot (built-in) with eglot-booster for performance and autoreconnect on server crashes. Hooks are wired for 20+ language modes. Custom LSP server entries for Odin (`ols`), Zig (`zls`), Jai (`jails`), go-templ, GLSL, Fish, Haskell, and Harper (grammar/spell checking for writing modes). xref-union combines Eglot's xref backend with dumb-jump as a fallback in non-LSP buffers.

## Debugging

Dape (DAP client) with custom Go/Delve wrappers that use the DAP protocol (`dlv dap`) and are package-directory-aware:
- `cm/dape-go-debug-test-at-point` (`C-c d t`) — debug test at point with auto-breakpoint on first line
- `cm/dape-go-debug-main` (`C-c d m`) — debug main with optional build tags and CLI args
- `cm/dape-go-debug-package-tests` (`C-c d p`) — debug package tests with optional filter and tags

## Navigation

- **Avy** — fast jump-to-char/word/line (`M-j`, `M-g w`, `M-g e`)
- **Ace-window** — quick window switching (`M-o`)
- **Windmove** — directional window navigation (`M-s-<arrow>`)
- **nav-flash** — briefly highlights cursor line after large jumps (xref, imenu, recenter)

## Custom editing commands

Chunk-based word motion and deletion (`cm/move-right`, `cm/move-left`, `cm/backward-delete-word`, `cm/delete-word`) bound to `C-<arrow>` and `C-<backspace>`/`C-<delete>`. Line transposition via `cm/move-line-up`/`cm/move-line-down` on `M-<up>`/`M-<down>`. Toggle window split orientation with `cm/toggle-window-split` (`C-c |`). Quick toggles under `C-c T`: word wrap (`w`), truncate lines (`t`), whitespace (`s`), flyspell (`f`), mouse profile (`m`). Multiple-cursors includes symbol-aware mark (`C-M->`, `C-M-<`), skip (`C-"`, `C-:`), and `mc/edit-lines` (`C-S-c C-S-c`).

## Function keys

| Key | Action |
|-----|--------|
| `<f2>` | `browse-url` |
| `<f3>` / `S-<f3>` / `<f4>` | Start / stop / play keyboard macro |
| `<f5>` | `project-compile` |
| `<f9>` / `<f10>` | Next / previous error |
| `<f12>` | Organize imports + format buffer (eglot) |

## SQL tooling

Custom xref-based cross-project reference search for SQL identifiers:
- `cm/sql-find-references` (`M-?`) — search all project files for SQL object references
- `cm/sql-find-references-sql-only` (`C-c ? s`) — search SQL files only
- `cm/sql-complete-object` (`C-c C-o`) — complete SQL object names from live SQLi connection
- `cm/sql-refresh-completions` (`C-c C-l r`) — rebuild completion cache

## AI writing assistant

File-based exchange protocol for side-by-side use with Claude Code (or any AI tool). Content and context are shared via `~/.emacs-ai/`.

| Key | Action |
|-----|--------|
| `C-c a s` | Share buffer, region, or org subtree (`C-u`) with AI |
| `C-c a a` | Accept/apply AI suggestion at point or region |
| `C-c a d` | Diff current text against AI suggestion |

Claude Code can also query Emacs state directly via `emacsclient -s <server> -e`:

| Function | Returns |
|----------|---------|
| `(cm/ai-current-context)` | JSON: file, mode, line, column, region, org path |
| `(cm/ai-visible-buffers)` | JSON array of all visible buffers across frames |
| `(cm/ai-get-content)` | Snapshots focused buffer to `~/.emacs-ai/`, returns context JSON |
| `(cm/ai-get-content "name")` | Snapshots a specific buffer by name |
| `(cm/ai-paragraph-at-point)` | Paragraph text at point |
| `(cm/ai-line-at-point)` | Current line text |
| `(cm/ai-region-or-paragraph)` | JSON: region if active, else paragraph at point |
| `(cm/ai-org-subtree-at-point)` | Org subtree at point (nil outside org-mode) |
| `(cm/ai-nearby-lines)` | ±5 lines around point with arrow marker |

For saved files, Claude Code can edit directly — `global-auto-revert-mode` picks up changes.

## Claude Code IDE (editor-hosted)

[`claude-code-ide.el`](https://github.com/manzaltu/claude-code-ide.el) runs the inverse of the file-exchange flow above: Emacs spawns the `claude` CLI in a vterm buffer and stands up a WebSocket MCP server that Claude connects back into, exposing Emacs to Claude (xref/eglot, `project`, tree-sitter, imenu, Flymake diagnostics, `ediff` diff review, and Elisp evaluation).

| Key | Action |
|-----|--------|
| `C-c c` | `claude-code-ide-menu` — start/toggle, send prompt, resume, list sessions |

Backend is `vterm`; `claude-code-ide-emacs-tools-setup` exposes the built-in Emacs tools and Elisp eval stays enabled. Sessions are tied to the Emacs instance (it spawns its own `claude` rather than attaching to a terminal session) — use the menu's resume/continue to reattach after a restart. Complements the file-based `cm/ai-*` flow rather than replacing it.

## Additional packages

- **vterm** — full terminal emulator inside Emacs (fish shell, 10k scrollback)
- **editorconfig** — automatically applies `.editorconfig` project settings
- **flyspell** — spell checking in text-like modes only (text, org, markdown)
- **harper** — grammar/spell checking LSP for org, markdown, and text modes via eglot
- **diff-hl flydiff** — live fringe indicators for unsaved changes (not just uncommitted)
- **docker** — manage containers, images, volumes, and networks (`C-c D`)
- **pdf-tools** — PDF viewer with annotation support (fit-page by default)

## Fonts

- **Monospace:** TX-02
- **Variable-pitch:** Fira Sans
- **Emoji:** JoyPixels

Run `M-x all-the-icons-install-fonts` once after first install for icon support.

## Naming conventions

- `cm/` prefix — all custom functions and variables (`cm` = corruptmemory)

## External tool dependencies

| Tool                              | Used by                                           |
|-----------------------------------|---------------------------------------------------|
| `ripgrep` (`rg`)                  | consult-ripgrep, deadgrep, dumb-jump              |
| `emacs-lsp-booster`              | eglot-booster (`cargo install emacs-lsp-booster`) |
| `gopls`                           | Go LSP                                            |
| `rust-analyzer`                   | Rust LSP                                          |
| `clangd`                          | C/C++ LSP                                         |
| `pyright`                         | Python LSP                                        |
| `typescript-language-server`      | JS/TS LSP                                         |
| `dlv` (Delve)                     | Go debugging via Dape                             |
| `ols`                             | Odin LSP                                          |
| `zls`                             | Zig LSP                                           |
| `jails`                           | Jai LSP (~/projects/Jails/bin/jails)              |
| `haskell-language-server-wrapper` | Haskell LSP                                       |
| `bash-language-server`            | Bash LSP                                          |
| `fish-lsp`                        | Fish LSP                                          |
| `aspell` or `hunspell`            | flyspell spell checking                           |
| `cmake`, `libtool`, C compiler    | vterm module compilation (first use)              |
| `poppler` (dev libs)              | pdf-tools `epdfinfo` build (first use)            |
| `docker`                          | docker.el container/image management              |
| `harper-ls`                       | Grammar/spell checking for writing modes (`pacman -S harper`) |
