# Multi-root project search ("Add Folder to Project") — Design

**Date:** 2026-06-06
**Status:** Approved (brainstorming complete) — proceeding to implementation plan.

## Goal

Bring something like Sublime Text / Zed's *Add Folder to Project* to this Emacs
config: let project-aware search and navigation run across multiple top-level
directories that are designated part of one logical project, even when those
directories live **outside** the primary project root.

Initial use case: editing a Jai project (e.g. `~/projects/game-bootstrap`) and
wanting "search the project for …" and "jump to definition" to also reach
designated sibling/external dirs (Jai stdlib, shared engine, module roots).

## Research findings (grounded in installed sources)

- **`consult-ripgrep` accepts a *list* of directories for its `DIR` argument**
  (`straight/repos/consult/consult.el:835` — "If DIR is a list of strings, the
  list is returned as search paths"). So `(consult-ripgrep (list r1 r2 r3) pat)`
  searches all three in one live buffer, natively. (Note: the general web answer
  says this is unsupported; the *installed* version supports it.)
- **`dumb-jump-fetch-results` is parameterized by `proj-root`**
  (`straight/repos/dumb-jump/dumb-jump.el:4065`:
  `(dumb-jump-fetch-results cur-file proj-root lang config &optional entered-name)`).
  `dumb-jump-fetch-file-results` computes `cur-file`/`lang`/`config` from the
  current buffer once, then calls it with a single root. Multi-root jump =
  compute those once, loop the root list through `dumb-jump-fetch-results`,
  `append` the `:results`. No advice, no reimplementing dumb-jump's regexes.
- **LSP has a first-class capability for only two of the four operations:**
  `:definitionProvider` and `:referencesProvider`. There is no LSP primitive for
  "grep arbitrary text" or "find file by name" (the nearest, workspace/symbol, is
  a different operation already bound to `consult-eglot-symbols` / `C-c e s`).
- **No turnkey package** implements multi-root for `project.el`; the blessed
  pattern is a custom `project-find-functions` backend — but that is **not needed**
  for an opt-in command model (see Decisions).
- Eglot predicates confirmed available in this build: `eglot-managed-p`,
  `eglot-server-capable`, `eglot-current-server`. The config already prefers LSP
  in eglot-managed buffers (`init.el:869`).

## Decisions

1. **Storage:** a `.project-roots` file at the primary project root lists the
   extra directories. Survives this user's ephemeral-Emacs workflow (state on
   disk, travels with the project), matches the "explicit > implicit" aesthetic.
2. **Interaction model:** **opt-in separate commands.** Existing commands
   (`consult-ripgrep` wrappers, `xref`/`dumb-jump`, `M-.`) are **untouched**;
   multi-root is reached via new `cm/` commands under a `C-c w` prefix.
3. **LSP-first where LSP applies:** jump-to-def and find-references prefer Eglot
   when the buffer is managed and the server is capable, falling back to the
   multi-root grep/dumb-jump path only when Eglot is unavailable or returns
   nothing. `C-u` forces the fallback path. Search and find-file are
   unconditionally rg-based (LSP has no equivalent).
4. **No custom `project.el` backend.** The opt-in model needs only a helper that
   reads `.project-roots`; `game-bootstrap` stays a normal VC/git project
   (magit, eglot, existing `M-.` all unchanged). A custom backend is held in
   reserve for a future "transparent widening" mode, explicitly out of scope now.
5. **Testability by construction:** each command is split into a pure-ish
   **compute core** (returns data: dirs, pattern, candidate list, merged results)
   and a **thin interactive shell** (hands data to consult/xref). Establishes the
   repo's first automated test suite.

## Architecture

No package; plain `cm/` defuns in a new `init.el` section placed **after** the
dumb-jump / xref-union / consult-eglot block (~line 973) so those symbols exist.

### `.project-roots` format

```
# Comments (#) and blank lines ignored. One directory per line.
# The primary root (this file's directory) is IMPLICIT — never list it.
~/projects/jai-stdlib       # ~ expands
../shared-engine            # relative → resolved against the primary root
/opt/jai/modules            # absolute used as-is
```

### `cm/project-roots` / `cm/project-roots--parse`

- `cm/project-roots--parse (text base-dir)` → **pure**: lines → absolute dir
  list (strip comments/blanks, expand `~`, resolve relative against `base-dir`).
- `cm/project-roots ()` → primary root via
  `(locate-dominating-file default-directory ".project-roots")`; if found, return
  `(cons primary parsed)` with non-existent dirs skipped (with a `message`
  warning) and the list deduped. If not found, degrade to
  `(list (project-root (project-current)))`, or `(list default-directory)`.
  Re-read every call (cheap; lets edits take effect immediately).

### `cm/eglot--prefer` (shared LSP gate)

```elisp
(defun cm/eglot--prefer (capability thunk fallback)
  "Run THUNK if Eglot manages the buffer and the server has CAPABILITY,
falling back to FALLBACK when Eglot finds nothing.  Prefix arg forces FALLBACK."
  (if (and (not current-prefix-arg) (eglot-managed-p) (eglot-server-capable capability))
      (condition-case nil (funcall thunk)          ; xref signals user-error on none
        (user-error (funcall fallback)))
    (funcall fallback)))
```

### The four commands (compute core + thin shell)

| Command | LSP path | Fallback / core |
|---|---|---|
| `cm/project-search-all-roots` | — | `(consult-ripgrep (cm/project-roots) (cm/consult-region-seed))` |
| `cm/project-refs-all-roots` | `:referencesProvider` → `xref-find-references` | `(consult-ripgrep (cm/project-roots) "\\bSYMBOL\\b")` |
| `cm/project-find-file-all-roots` | — | candidates via `rg --files` over roots → `consult--read` → `find-file` |
| `cm/project-jump-def-all-roots` | `:definitionProvider` → `xref-find-definitions` | loop `dumb-jump-fetch-results` per root, merge/dedupe `:results`, push xref marker, jump (or `completing-read` if many) |

Cores to extract for testing: `cm/project-find-file--candidates (roots)`,
`cm/project-jump-def--fallback-results (roots)` (merge), the
`(roots . pattern)` builder for search/refs, and `cm/eglot--prefer`.

### "Add Folder" interactive layer

- `cm/project-add-root (dir)` — `read-directory-name`, append to `.project-roots`
  at the primary root, **creating the file if absent** (bootstraps from a plain
  project), stored `~`-abbreviated, deduped (no-op if present).
- `cm/project-edit-roots ()` — open `.project-roots` for hand-editing (removal =
  delete a line; no separate remove command — YAGNI).

### Keybindings — `C-c w` prefix (`w` = workspace; confirmed free)

| Key | Command |
|---|---|
| `C-c w s` | `cm/project-search-all-roots` |
| `C-c w r` | `cm/project-refs-all-roots` |
| `C-c w f` | `cm/project-find-file-all-roots` |
| `C-c w j` | `cm/project-jump-def-all-roots` |
| `C-c w a` | `cm/project-add-root` |
| `C-c w e` | `cm/project-edit-roots` |

A named prefix keymap so which-key / `C-h` lists it.

## Edge cases

- **Symbol seeding** (jump/refs): thing-at-point symbol → active region →
  minibuffer prompt (mirrors dumb-jump's precedence).
- **No `.project-roots`**: in a project → single primary root (commands behave
  like their single-root cousins); no project → `default-directory`.
- **Stale entries**: skipped with a `message` warning. Empty/all-comment file →
  primary root only.
- **Overlapping/nested roots**: exact duplicates deduped; nested roots may
  double-report — left un-deduped (YAGNI), noted in a comment.
- **Lazy load**: jump fallback `(require 'dumb-jump)` on demand.

## Testing (repo's first automated suite)

New `tests/` dir + ERT, run via
`emacs -batch -l ert -l tests/cm-project-roots-tests.el -f ert-run-tests-batch-and-exit`
(the pattern consult/dumb-jump use). `skip-unless` guards skip integration tests
when `rg`/`dumb-jump` are unavailable.

- **Pure unit:** `cm/project-roots--parse` (comments, blanks, `~`, relative,
  absolute, dedupe).
- **Filesystem fixture:** `cm/project-roots` (temp dir + `.project-roots`;
  implicit primary, stale-skip, no-file fallback).
- **Integration (real `rg`):** `cm/project-find-file--candidates` returns the
  union of files across a two-root fixture.
- **Integration (real `rg`+`dumb-jump`):** `cm/project-jump-def--fallback-results`
  finds a definition placed in root B while "in" root A — proves cross-root jump.
- **Stub-based (`cl-letf`):** `cm/eglot--prefer` chooses thunk when capable,
  fallback otherwise, `C-u` forces fallback, `user-error` → fallback.
- **Interaction (stub `consult-ripgrep`):** search/refs invoke it with the right
  roots and the word-bounded pattern.

## Out of scope (YAGNI)

Transparent widening of built-in `project-*` commands; a custom `project.el`
backend; nested-root match dedup; a dedicated remove-folder command;
multi-root for languages with no rg/dumb-jump support.
