# Auto-load project TAGS with a cascading xref backend — Design

**Date:** 2026-06-25
**Status:** Approved (brainstorming complete) — proceeding to implementation plan.

## Goal

When Emacs enters a project that ships a build-generated `TAGS` index at its
**root**, load that index automatically and keep it fresh as the build
regenerates it — then wire it into navigation so it sits in its rightful place
in the priority order:

1. **LSP wins** when a language server manages the buffer.
2. else, when a project `TAGS` exists, **etags is consulted first**; a TAGS hit
   navigates directly.
3. **dumb-jump is a fallback** — it runs *only when etags finds nothing.*

Driving use case: `~/projects/game-bootstrap`, a Jai project. `first.jai`
regenerates a root `TAGS` on every successful build by feeding the compiler's
typechecked messages into a vendored ctags consumer (`first.jai:314–341`,
`modules/ctags`, `output_format = .ETAGS`). The source lives under `src/`,
`modules/`, etc. — **not** at the root where `TAGS` sits. Jai has no wired LSP
(jails is deliberately unconfigured), so today `M-.` in a `.jai` buffer reaches
only dumb-jump's regex heuristics, ignoring a precise index that already exists.

## Research findings (grounded in installed sources)

- **The `TAGS` index is compiler-precise, not regex-scraped.** It is emitted
  from the Jai compiler's `.TYPECHECKED` message stream (`first.jai:314–341`).
  In the priority hierarchy it is therefore a *static snapshot of LSP-quality
  declarations*, not a weak heuristic — a TAGS hit deserves a **direct jump**,
  exactly as LSP would produce.
- **Emacs xref has no built-in "try the next backend on an empty result."**
  `xref-find-backend` is `run-hook-with-args-until-success` over
  `xref-backend-functions`: the first backend to return non-nil **owns** the
  query, empty result or not. There is no fall-through.
- **`etags--xref-backend` always claims the buffer.** It unconditionally returns
  the symbol `etags`. So plain backend ordering (etags before dumb-jump) would
  give etags-only with *no* dumb-jump fallback — failing requirement (3).
- **`xref-union` merges, it does not cascade.** It runs every included backend
  and concatenates results in backend order. That satisfies "prioritize TAGS"
  (TAGS sorts first) but **not** "dumb-jump is a fallback": dumb-jump's regex
  hits are appended on *every* lookup, turning a precise single-definition jump
  into a multi-candidate picker. This defeats the precision the build pays for.
- **The config already encodes "step aside when something better exists."**
  `cm/xref-union-disable-in-eglot-managed-buffer` (`init.el:874`) turns
  `xref-union-mode` off in eglot-managed buffers, so LSP is used alone —
  requirement (1) is already satisfied today. The new cascade is the *same
  pattern extended one rung down.*
- **`etags--xref-backend` currently excluded from union.**
  `cm/xref-union-excluded-backend-p` (`init.el:879`) drops `etags` from
  `xref-union` (avoids the "Visit tags table?" prompt when no table is loaded).
  The cascade replaces this concern: etags is reached only through the cascade
  backend, which only activates when a real project `TAGS` is loaded.
- **Sub-backend dispatch is the documented `xref-union` technique.** Methods like
  `(xref-backend-definitions 'etags id)` and
  `(xref-backend-definitions 'dumb-jump id)` dispatch on the backend symbol via
  `cl-defmethod (eql 'etags)` / `(eql 'dumb-jump)`. A custom backend can call
  them directly to compose a cascade. (`dumb-jump-xref-activate` returns the
  symbol `dumb-jump`; etags' backend is the symbol `etags`.)
- **etags reloads on modtime change for free.** `visit-tags-table-buffer` calls
  `tags-verify-table`, which reverts the in-memory table when the file's modtime
  changed; `tags-revert-without-query` non-nil makes that revert **silent**. So
  "reload when the build regenerates TAGS" needs no file-watcher — the next
  lookup after a rebuild reads the fresh table. Zero idle cost.

## Decisions

1. **Cascade, not merge** (user-selected). A small custom xref backend tries
   etags first and falls to dumb-jump **only** when etags returns nothing.
   Preserves direct jumps from the precise index; dumb-jump never clutters a
   TAGS hit.

2. **Three navigation regimes, one consistent rule.** Per buffer:

   | Condition | Backend used |
   |---|---|
   | eglot manages the buffer | LSP alone *(already true via the eglot disable)* |
   | no LSP, project root has `TAGS` | **cascade: etags → dumb-jump fallback** |
   | neither | dumb-jump via `xref-union` *(unchanged)* |

   The cascade backend returns its symbol **only** when a project `TAGS` is
   loaded *and* the buffer is not eglot-managed, so LSP and the existing
   dumb-jump path are both untouched where they already apply.

3. **Load buffer-locally, lazily, without prompting.** On entering a file, find
   the project root via `project-current`; if `TAGS` sits at that root, point
   the buffer's etags table at it **buffer-locally** (so project A's table never
   bleeds into project B), deferring the actual read to first use (no prompt).
   The exact variable (`tags-table-list` buffer-local vs. `visit-tags-table …
   LOCAL`) is pinned during implementation by empirical check; the contract is
   "buffer-local, lazy, prompt-free."

4. **Reload via `tags-revert-without-query t`** — silent re-read on the next
   lookup whenever the file's modtime changed. No file-notify watcher. (A
   watcher is explicitly rejected: tags are consumed only at lookup time, so
   eager reloading buys nothing.)

5. **Generic by activation, Jai-driven by need.** The load + cascade are not
   Jai-specific: any project whose root holds a `TAGS` gets them. In a buffer
   that *also* has an LSP (e.g. a Go project with a stray TAGS), the cascade's
   guard returns nil and LSP wins — so "generic" costs nothing. The feature
   simply *matters* most where no LSP exists, i.e. Jai.

6. **Own sibling library, like `cm-project-roots.el`.** Ship as
   `cm-project-tags.el`, loaded from `init.el` with the same
   `(load (locate-user-emacs-file "cm-project-tags") t)` pattern, keeping
   `init.el` lean and the unit independently testable (the repo's established
   convention for testable units).

## Architecture

### Components (all in `cm-project-tags.el`)

- **`cm/project-tags-file`** *(pure-ish)* — given a buffer/dir, return the
  absolute path to a readable `TAGS` at the project root, or nil. Uses
  `project-current` → `project-root`; checks only the root (per the requirement
  "TAGS file in the **root**"). The single source of truth all else reads.

- **`cm/project-tags--maybe-activate`** — a `find-file-hook` (and a
  matching `cm/project-tags-mode` buffer setup) that: resolves
  `cm/project-tags-file`; if present, sets the buffer-local etags table and a
  buffer-local flag `cm/project-tags--active`; installs the cascade backend in
  the buffer-local `xref-backend-functions` at a depth that runs **before**
  `xref-union`'s entry.

- **`cm/project-tags-xref-backend`** — the activation function added to
  `xref-backend-functions`. Returns `cm/tags-cascade` **iff**
  `cm/project-tags--active` and `(not (bound-and-true-p eglot--managed-mode))`;
  else nil (so eglot or xref-union take over).

- **Cascade methods** on `(eql 'cm/tags-cascade)`:
  - `xref-backend-identifier-at-point` → delegate to `etags`.
  - `xref-backend-identifier-completion-table` → delegate to `etags`
    (real completion over tag names; powers `C-u M-.`).
  - `xref-backend-definitions id` → `(or (etags id) (dumb-jump id))`.
  - `xref-backend-references id` → `(or (etags id) (dumb-jump id))`.
    (Both are grep-scoped for etags/dumb-jump; etags' scope is the TAGS file
    set, dumb-jump's is the project — etags-first still honors the priority.)
  - `xref-backend-apropos pat` → delegate to `etags`.

### Data flow (a Jai `M-.`)

```
open src/main.jai
  └─ find-file-hook → cm/project-tags--maybe-activate
       ├─ cm/project-tags-file → ~/projects/game-bootstrap/TAGS  (exists)
       ├─ setq-local etags table → that TAGS   (lazy; nothing read yet)
       ├─ cm/project-tags--active = t
       └─ add cm/project-tags-xref-backend to xref-backend-functions (depth first)

M-. on `draw_frame`
  └─ xref-find-backend → cm/project-tags-xref-backend returns 'cm/tags-cascade
       └─ xref-backend-definitions 'cm/tags-cascade "draw_frame"
            ├─ (xref-backend-definitions 'etags "draw_frame")
            │     └─ visit-tags-table-buffer: modtime unchanged → use cached table
            │        (or changed since last build → silent revert) → 1 precise hit
            └─ etags non-empty ⇒ dumb-jump NOT called ⇒ direct jump
```

```
M-. on `tmp_local`  (a local, not in TAGS)
  └─ cascade: (etags …) → nil  ⇒  (dumb-jump …) → regex candidates (fallback)
```

## Error handling & edge cases

- **No project / no root TAGS** → `cm/project-tags-file` returns nil, nothing is
  activated, behavior is identical to today (xref-union/dumb-jump). The feature
  is purely additive.
- **TAGS deleted or unreadable after activation** → etags' own machinery reports
  "no tags table" through the normal path; cascade's `or` still falls to
  dumb-jump for definitions/references. (Activation re-checks readability each
  `find-file`, so a fresh visit recovers.)
- **eglot attaches after the hook** (e.g. a future jails) → the cascade guard
  checks `eglot--managed-mode` at query time, so LSP transparently wins without
  re-running the hook.
- **Cross-project pollution** → prevented by buffer-local table binding; no
  global `tags-table-list` mutation.
- **Stale offsets right after a rebuild** → the modtime-revert ensures the table
  in memory matches the file the build just wrote; `tags-revert-without-query t`
  keeps it silent.
- **No double dumb-jump** → when the cascade is selected it *is* the backend;
  `xref-union`'s entry is never reached for that query, so dumb-jump runs at most
  once (inside the cascade's fallback).

## Testing

ERT suite under `tests/` (mirrors `cm-project-roots.el`'s pattern; run via
`./tests/run-tests.sh`):

- **`cm/project-tags-file`** (pure): in a throwaway `make-temp-file`-created
  temp project, returns the root `TAGS` when present, nil when absent, nil when the dir is not
  a project. No external tools needed.
- **Cascade fallback logic**: with a hand-written minimal `TAGS` in a temp dir,
  assert `xref-backend-definitions 'cm/tags-cascade` returns the etags hit for a
  symbol present in TAGS, and falls through to dumb-jump for a symbol absent from
  TAGS. dumb-jump leg guarded by `skip-unless` (rg + dumb-jump present), matching
  the existing integration-test convention.
- **Guard**: `cm/project-tags-xref-backend` returns nil when
  `cm/project-tags--active` is nil, and (simulated) nil when
  `eglot--managed-mode` is bound non-nil.

## Out of scope

- File-notify watching of `TAGS` (rejected — lazy revert suffices).
- Generating/regenerating TAGS from Emacs (the build owns generation;
  `etags-regen-mode` would *fight* the build and is explicitly **not** used).
- Wiring jails / any Jai LSP (deliberately unconfigured per project policy).
- Multi-root TAGS (searching `.project-roots` dirs for additional tables) —
  possible future extension; this design scopes to the single root `TAGS`.

## Affected files

- **New:** `cm-project-tags.el`, `tests/cm-project-tags-tests.el`.
- **Edit:** `init.el` — load the sibling; add the `find-file-hook`; set
  `tags-revert-without-query t`. The existing `cm/xref-union-excluded-backend-p`
  etags exclusion stays (etags is reached via the cascade, not via union).
- **Docs:** `CLAUDE.md` (architecture list + a short section), `README.md`
  (a navigation note) on completion.
