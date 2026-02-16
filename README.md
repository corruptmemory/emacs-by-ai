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

## Package management

[straight.el](https://github.com/radian-software/straight.el) with `use-package` integration. Every `use-package` declaration installs via straight automatically (`straight-use-package-by-default t`).

## Completion stack

Vertico + Orderless + Consult + Marginalia + Embark in the minibuffer; Corfu + Cape + kind-icon in-buffer.

## LSP

Eglot (built-in) with eglot-booster for performance. Hooks are wired for 20+ language modes. Custom LSP server entries for Odin (`ols`), Zig (`zls`), Jai (`jails`), go-templ, GLSL, Fish, and Haskell.

## Debugging

Dape (DAP client) with custom Go/Delve wrappers for debugging tests, main, and package tests.

## Fonts

- **Monospace:** TX-02
- **Variable-pitch:** Fira Sans
- **Emoji:** JoyPixels

Run `M-x all-the-icons-install-fonts` once after first install for icon support.

## External tool dependencies

| Tool                              | Used by                                           |
|-----------------------------------|---------------------------------------------------|
| `ripgrep` (`rg`)                  | consult-ripgrep, deadgrep, dumb-jump              |
| `emacs-lsp-booster`               | eglot-booster (`cargo install emacs-lsp-booster`) |
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
