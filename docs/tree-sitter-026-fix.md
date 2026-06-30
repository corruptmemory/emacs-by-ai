---
name: tree-sitter-026-incompatibility
description: Emacs 30.2 vs tree-sitter 0.26 ABI incompatibility — predicate naming catch-22, diagnosis, fix, and grammar rebuild procedure
type: project
originSessionId: 60b1edb1-49f2-400b-b26c-0b08b6249242
---
## Problem: tree-sitter 0.26 breaks ALL tree-sitter modes in Emacs 30.2

On 2026-04-09, Arch Linux upgraded `tree-sitter` from 0.25.10 to 0.26.8. The Arch
maintainer then rebuilt `emacs-wayland` (30.2-2.1) against 0.26. This silently broke
syntax highlighting in **every** tree-sitter mode (Go, C, C++, Rust, Python, TypeScript,
Java, Lua, Ruby, etc.).

### Root cause: predicate naming catch-22

Tree-sitter font-lock queries use predicates like `#match` to filter syntax nodes by
regex. The issue is a naming convention conflict between two C libraries:

- **tree-sitter 0.26** requires predicates to end with `?` suffix: `#match?`, `#equal?`
- **Emacs 30.2's treesit.c** only recognizes predicates WITHOUT `?`: `#match`, `#equal`, `#pred`

Both libraries validate predicate names, and they disagree:

| Predicate | tree-sitter 0.26 | Emacs 30.2 treesit.c |
|-----------|------------------|----------------------|
| `#match`  | REJECTS ("Syntax error") | Accepts |
| `#match?` | Accepts | REJECTS ("only supports equal, match, and pred") |

This is unfixable from elisp — both checks happen in C code.

### How the query gets built

1. Emacs modes use `:match` in sexp-form queries (e.g., `go-ts-mode.el` line 145)
2. `treesit-query-expand` converts `:match` to `#match` in the string form
3. `treesit-query-compile` compiles the string to a C query struct
4. At compilation, tree-sitter 0.26's C library rejects `#match` (wants `#match?`)
5. Even if you hack it to `#match?`, Emacs's C code rejects it on execution

### The regex style is also wrong (secondary issue)

`go-ts-mode` uses `rx-to-string` to generate the regex, which produces Emacs-style
`\(?:...\)` non-capturing groups. Tree-sitter uses Rust's regex crate which expects
PCRE-style `(?:...)`. In tree-sitter 0.25 this was translated; in 0.26 it may not be.
This is a secondary issue — the predicate naming is the primary blocker.

### Which modes are affected

Every built-in `-ts-mode` that uses `:match` predicates (checked via
`zgrep -c ':match' /usr/share/emacs/30.2/lisp/progmodes/*-ts-mode.el.gz`):

- c-ts-mode (4 uses)
- cmake-ts-mode (6)
- elixir-ts-mode (17)
- go-ts-mode (1)
- java-ts-mode (1)
- lua-ts-mode (1)
- php-ts-mode (5)
- ruby-ts-mode (9)
- rust-ts-mode (8)
- typescript-ts-mode (2)

Modes without `:match` (python-ts-mode, etc.) may still break due to other predicate
changes in 0.26.

### Symptom

All text in tree-sitter buffers appears as a single color (no syntax highlighting).
The error is visible in `*Messages*` or `--batch` mode:

```
Query pattern is malformed: "Syntax error at", 73, "(call_expression function:
((identifier) @font-lock-builtin-face (#match \"...\" @font-lock-builtin-face)))"
```

Modes using regex font-lock (e.g., `jai-mode`) are unaffected since they don't use
tree-sitter at all.

## Fix applied (2026-04-09)

### Step 1: Remove neovim (it pulled in tree-sitter 0.26)

```bash
sudo pacman -Rns neovim --noconfirm
```

This also removed 13 dependencies including `tree-sitter-c`, `tree-sitter-lua`,
`tree-sitter-vim`, etc. (neovim-specific grammar packages, not the grammars in
our `tree-sitter/` directory).

### Step 2: Downgrade tree-sitter and emacs-wayland together

The old packages were in the pacman cache:

```bash
sudo pacman -U /var/cache/pacman/pkg/tree-sitter-0.25.10-3-x86_64.pkg.tar.zst \
               /var/cache/pacman/pkg/emacs-wayland-30.2-1-x86_64.pkg.tar.zst --noconfirm
```

Key detail: `emacs-wayland 30.2-1` was linked against `libtree-sitter.so=0.25`
(verified via `bsdtar -xf ... --to-stdout .PKGINFO | grep tree`). The rebuilt
`30.2-2.1` was linked against `libtree-sitter.so=0.26`. You MUST downgrade both
together — Emacs won't start if the .so version doesn't match.

### Step 3: Reinstall libvterm

Removing neovim also removed `libvterm`, which vterm-mode needs:

```bash
sudo pacman -S libvterm --noconfirm
```

### Step 4: Recompile ALL tree-sitter grammars

The grammar `.so` files in `tree-sitter/` were compiled against the 0.26 ABI.
They must be rebuilt for 0.25.

```bash
# Delete all existing grammars
rm ~/.config/emacs/tree-sitter/*.so

# Rebuild via treesit-auto
emacs --batch --init-directory=~/.config/emacs -l init.el --eval '
(progn
  (require (quote treesit-auto))
  (treesit-auto-install-all)
  (print "done"))'
```

This clones each grammar repo, compiles the C source against the system's
`libtree-sitter.so`, and installs the `.so` into `tree-sitter/`. Takes a few
minutes for ~60 grammars.

**Important:** The grammars are NOT checked into git (the `tree-sitter/` directory
is gitignored or untracked). They must be rebuilt on each machine.

### Step 5: Pin packages to prevent re-upgrade

Edit `/etc/pacman.conf`:

```
IgnorePkg = tree-sitter emacs-wayland
```

This prevents `pacman -Syu` from upgrading either package back to the broken
versions. Remove this line once Emacs 30.3+ or 31.x ships with tree-sitter 0.26
compatibility.

### Step 6: Verify

```bash
emacs --batch --init-directory=~/.config/emacs -l init.el --eval '
(progn
  (dolist (test (quote (("Go" go-ts-mode "package main\nfunc main() { make([]int, 0) }\n")
                        ("C" c-ts-mode "#include <stdio.h>\nint main() { return 0; }\n")
                        ("Rust" rust-ts-mode "fn main() { println!(\"hello\"); }\n")
                        ("Python" python-ts-mode "def main():\n    print(\"hello\")\n"))))
    (let ((name (nth 0 test))
          (mode (nth 1 test))
          (code (nth 2 test)))
      (with-temp-buffer
        (insert code)
        (funcall mode)
        (condition-case err
            (progn (font-lock-ensure)
                   (print (format "%s: OK (face=%S)" name (get-text-property 1 (quote face)))))
          (error (print (format "%s: BROKEN" name))))))))'
```

Expected: all modes report `OK` with a face like `font-lock-keyword-face`.

## Debugging breadcrumbs

How we diagnosed this (useful if it recurs):

1. Initially appeared as "no syntax highlighting in Go" after adding unrelated
   config changes (performance tweaks from an Emacs Redux article)
2. Suspected `redisplay-skip-fontification-on-input` — removed it, still broken
3. `git stash` + test with old config → same error. **Pre-existing, not caused by our changes.**
4. `emacs --batch` with `font-lock-ensure` revealed the actual error in stderr
5. Checked `go-ts-mode.el.gz` source → found `:match` on line 145
6. Tested `#match` vs `#match?` in isolation → discovered the catch-22
7. Checked `emacs-wayland` PKGINFO → confirmed `libtree-sitter.so=0.26` dependency
8. Checked old package PKGINFO → confirmed `libtree-sitter.so=0.25` dependency
9. Confirmed old packages existed in `/var/cache/pacman/pkg/`

**Why:** Arch is a rolling release. neovim 0.12 required tree-sitter 0.26, which
triggered a rebuild of emacs-wayland against the new version. Emacs 30.2's C code
was never updated for 0.26's stricter validation.

**How to apply:** If tree-sitter modes break after a system update, check
`pacman -Qi tree-sitter` for the version. If it's 0.26+, this incompatibility
is likely the cause. The fix is the same: downgrade both packages and rebuild
grammars.
