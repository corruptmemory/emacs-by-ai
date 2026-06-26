# Project TAGS auto-loading — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Emacs enters a project whose root holds a build-generated `TAGS`
index, auto-load it buffer-locally and prefer it for xref navigation (LSP wins
where managed; else precise etags; else dumb-jump fallback), staying fresh as
the build regenerates it.

**Architecture:** A new sibling library `cm-project-tags.el` (loaded from
`init.el` like `cm-project-roots.el`) detects a root `TAGS` on `find-file`,
points the buffer's etags table at it buffer-locally, and installs a custom
cascading xref backend (`cm/tags-cascade`) at the highest hook priority so it
preempts `xref-union`. The backend tries `etags` first and falls to `dumb-jump`
only on a miss; it yields to Eglot in LSP-managed buffers. Reload-on-regenerate
is `tags-revert-without-query`'s silent modtime re-read — no file-watcher.

**Tech Stack:** Emacs Lisp (Emacs 30.2), built-in `xref` / `etags` / `project`,
`dumb-jump` (already a dependency), ERT for tests.

## Global Constraints

- `cm/` prefix for all custom functions and variables (`cm` = corruptmemory).
- The xref backend symbol is `cm/tags-cascade` (dispatched as the **unquoted**
  `(eql cm/tags-cascade)` specializer — verified to work in this Emacs; matches
  how `dumb-jump` defines its own backend).
- Buffer-local table variable is `tags-table-list` (set with `setq-local`) —
  NOT `tags-file-name`, NOT a global `visit-tags-table` (avoids cross-project
  pollution and the "Visit tags table?" prompt).
- The cascade backend hook is added at depth `-100` (highest priority;
  `xref-union-hook-depth` is `-95`).
- `etags` `definitions` returns nil on a miss (cascade relies on this); `etags`
  has no `references` method (references delegate to `dumb-jump`, preserving
  today's non-LSP behavior).
- Do NOT touch the existing `cm/xref-union-excluded-backend-p` etags exclusion
  (init.el:879) — etags is reached only through the cascade, never the union.
- The feature is generic (any project with a root `TAGS`), not Jai-specific.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Commit directly to `master`; do NOT push (the user pushes explicitly).

---

### Task 1: Detection helper + library skeleton + test harness

**Files:**
- Create: `cm-project-tags.el`
- Create: `tests/cm-project-tags-tests.el`
- Modify: `tests/run-tests.sh` (load every `tests/*-tests.el`, not just one)

**Interfaces:**
- Produces: `cm/project-tags-file (&optional DIR) → string|nil` — absolute path of
  a readable `TAGS` at the current project root (via `project-current` →
  `project-root`), or nil when absent / not in a project. Checks only the root.

- [ ] **Step 1: Create the library skeleton with the detection helper**

Create `cm-project-tags.el`:

```elisp
;;; cm-project-tags.el --- Auto-load a build-generated project TAGS index  -*- lexical-binding: t; -*-
;;; Commentary:
;; When a project root holds a build-generated `TAGS' file (e.g. a Jai build
;; emitting a compiler-precise ETAGS index), load it buffer-locally for code
;; buffers and prefer it for xref navigation.  Priority: LSP wins where a server
;; manages the buffer; else a precise etags lookup; else dumb-jump as a fallback.
;; The build owns generation; `tags-revert-without-query' (set in init.el) makes
;; the in-memory table silently re-read whenever the file is regenerated.
;; See docs/plans/2026-06-25-project-tags-design.md.
;;; Code:

(require 'project)
(require 'xref)
(require 'etags)
(require 'cl-lib)

;; --- Detection ---------------------------------------------------------------

(defun cm/project-tags-file (&optional dir)
  "Return the absolute path of a readable TAGS at the current project root, or nil.
DIR defaults to `default-directory'.  Only the project root is checked, never
subdirectories, matching build tools that emit a single root-level index."
  (when-let* ((proj (project-current nil (or dir default-directory)))
              (root (project-root proj))
              (tags (expand-file-name "TAGS" root)))
    (and (file-readable-p tags) tags)))

(provide 'cm-project-tags)
;;; cm-project-tags.el ends here
```

- [ ] **Step 2: Generalize the test harness to run all suites**

Replace the contents of `tests/run-tests.sh` with:

```bash
#!/usr/bin/env bash
# Run every ERT suite under tests/ in batch.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec emacs -batch -Q \
  --eval "(progn
            (add-to-list 'load-path \"$REPO\")
            (let ((b \"$REPO/straight/build\"))
              (when (file-directory-p b)
                (dolist (d (directory-files b t \"^[^.]\"))
                  (when (file-directory-p d) (add-to-list 'load-path d))))))" \
  -l ert \
  --eval "(dolist (f (directory-files \"$REPO/tests\" t \"-tests\\\\.el\\\\'\"))
            (load f nil t))" \
  -f ert-run-tests-batch-and-exit
```

- [ ] **Step 3: Write the failing tests for detection**

Create `tests/cm-project-tags-tests.el`:

```elisp
;;; cm-project-tags-tests.el --- Tests for cm-project-tags  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'cm-project-tags)

(ert-deftest cm/project-tags-file--finds-root-tags ()
  "Returns the root TAGS path when one exists."
  (let* ((root (file-name-as-directory (make-temp-file "cmpt" t)))
         (tags (expand-file-name "TAGS" root)))
    (with-temp-file tags (insert "\n"))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'fake root)))
              ((symbol-function 'project-root) (lambda (_) root)))
      (should (equal (cm/project-tags-file root) tags)))))

(ert-deftest cm/project-tags-file--nil-when-absent ()
  "Returns nil when the project root has no TAGS."
  (let* ((root (file-name-as-directory (make-temp-file "cmpt" t))))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'fake root)))
              ((symbol-function 'project-root) (lambda (_) root)))
      (should (null (cm/project-tags-file root))))))

(ert-deftest cm/project-tags-file--nil-when-no-project ()
  "Returns nil when not inside a project."
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (should (null (cm/project-tags-file temporary-file-directory)))))

(provide 'cm-project-tags-tests)
;;; cm-project-tags-tests.el ends here
```

- [ ] **Step 4: Run the suite**

Run: `./tests/run-tests.sh`
Expected: both suites load; all tests pass — final line `Ran <N> tests, <N>
results as expected` (the `cm/project-roots-*` tests plus the three new
`cm/project-tags-file--*` tests). Zero unexpected.

- [ ] **Step 5: Commit**

```bash
git add cm-project-tags.el tests/cm-project-tags-tests.el tests/run-tests.sh
git commit -m "$(cat <<'EOF'
Add cm-project-tags: detect a root TAGS file

Library skeleton + cm/project-tags-file (project-root TAGS detection),
and generalize tests/run-tests.sh to run every tests/*-tests.el suite.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Cascading xref backend (`cm/tags-cascade`) + activation guard

**Files:**
- Modify: `cm-project-tags.el` (insert before the `(provide ...)` line)
- Modify: `tests/cm-project-tags-tests.el` (insert before its `(provide ...)`)

**Interfaces:**
- Consumes: `cm/project-tags-file` (Task 1) is unused here; this task is the
  backend definition.
- Produces:
  - `cm/project-tags--active` — buffer-local boolean flag.
  - xref methods on `(eql cm/tags-cascade)`: `identifier-at-point`,
    `identifier-completion-table`, `definitions` (etags→dumb-jump),
    `references` (→dumb-jump), `apropos` (→etags).
  - `cm/project-tags-xref-backend () → 'cm/tags-cascade | nil` — returns the
    backend symbol iff `cm/project-tags--active` and not eglot-managed.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/cm-project-tags-tests.el`, immediately before
`(provide 'cm-project-tags-tests)`:

```elisp
;; --- cascade backend + guard ------------------------------------------------

(defun cm/test-tags--project (index-files)
  "Make a temp project; etags-index INDEX-FILES (relative); return (ROOT . TAGS).
Writes `in.el' (in-tags-fn), `only.el' (only-grep-fn), `use.el', and a
`.dumbjump' marker.  Only INDEX-FILES are written into TAGS."
  (let* ((root (file-name-as-directory (make-temp-file "cmpt-proj" t)))
         (tags (expand-file-name "TAGS" root)))
    (make-directory (expand-file-name "src" root))
    (with-temp-file (expand-file-name "src/in.el" root)
      (insert "(defun in-tags-fn () 'a)\n"))
    (with-temp-file (expand-file-name "src/only.el" root)
      (insert "(defun only-grep-fn () 'b)\n"))
    (with-temp-file (expand-file-name "src/use.el" root)
      (insert "(in-tags-fn) (only-grep-fn)\n"))
    (with-temp-file (expand-file-name ".dumbjump" root) (insert ""))
    (let ((default-directory root))
      (apply #'call-process "etags" nil nil nil "-o" tags index-files))
    (cons root tags)))

(ert-deftest cm/project-tags-xref-backend--inactive-returns-nil ()
  (with-temp-buffer
    (should (null (cm/project-tags-xref-backend)))))

(ert-deftest cm/project-tags-xref-backend--active-returns-symbol ()
  (with-temp-buffer
    (setq-local cm/project-tags--active t)
    (should (eq 'cm/tags-cascade (cm/project-tags-xref-backend)))))

(ert-deftest cm/project-tags-xref-backend--yields-to-eglot ()
  (with-temp-buffer
    (setq-local cm/project-tags--active t)
    (setq-local eglot--managed-mode t)
    (should (null (cm/project-tags-xref-backend)))))

(ert-deftest cm/project-tags-cascade--etags-hit-is-direct ()
  (skip-unless (executable-find "etags"))
  (let* ((p (cm/test-tags--project '("src/in.el")))
         (root (car p)) (tags (cdr p)))
    (with-current-buffer (find-file-noselect (expand-file-name "src/use.el" root))
      (emacs-lisp-mode)
      (setq-local tags-table-list (list tags))
      (let ((defs (xref-backend-definitions 'cm/tags-cascade "in-tags-fn")))
        (should (= 1 (length defs)))))))

(ert-deftest cm/project-tags-cascade--miss-falls-through-to-dumb-jump ()
  (skip-unless (and (executable-find "etags")
                    (executable-find "rg")
                    (require 'dumb-jump nil t)))
  ;; TAGS indexes only in.el, so `only-grep-fn' is absent and must come from
  ;; dumb-jump's grep of the .dumbjump project.
  (let* ((p (cm/test-tags--project '("src/in.el")))
         (root (car p)) (tags (cdr p)))
    (with-current-buffer (find-file-noselect (expand-file-name "src/use.el" root))
      (emacs-lisp-mode)
      (setq-local tags-table-list (list tags))
      (let ((defs (xref-backend-definitions 'cm/tags-cascade "only-grep-fn")))
        (should (>= (length defs) 1))))))

(ert-deftest cm/project-tags-cascade--completion-from-etags ()
  (skip-unless (executable-find "etags"))
  (let* ((p (cm/test-tags--project '("src/in.el")))
         (root (car p)) (tags (cdr p)))
    (with-current-buffer (find-file-noselect (expand-file-name "src/use.el" root))
      (emacs-lisp-mode)
      (setq-local tags-table-list (list tags))
      (let ((tbl (xref-backend-identifier-completion-table 'cm/tags-cascade)))
        (should (member "in-tags-fn" (all-completions "in-" tbl)))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-tests.sh`
Expected: FAIL — the guard tests error with `void-function
cm/project-tags-xref-backend`, and the cascade tests error with
`cl-no-applicable-method` for `xref-backend-definitions` on `cm/tags-cascade`.

- [ ] **Step 3: Implement the cascade backend and guard**

Insert into `cm-project-tags.el`, immediately before `(provide 'cm-project-tags)`:

```elisp
;; --- Cascading xref backend: etags first, dumb-jump fallback -----------------
;; LSP is handled elsewhere (eglot's own xref backend); this backend only ever
;; claims a buffer when no server manages it (see `cm/project-tags-xref-backend').

(declare-function dumb-jump-xref-activate "dumb-jump")

(defvar-local cm/project-tags--active nil
  "Non-nil when this buffer has a project TAGS loaded and the cascade installed.")

(cl-defmethod xref-backend-identifier-at-point ((_ (eql cm/tags-cascade)))
  (xref-backend-identifier-at-point 'etags))

(cl-defmethod xref-backend-identifier-completion-table ((_ (eql cm/tags-cascade)))
  (xref-backend-identifier-completion-table 'etags))

(cl-defmethod xref-backend-definitions ((_ (eql cm/tags-cascade)) identifier)
  "Prefer the precise TAGS index; fall back to dumb-jump only on a miss.
`etags' returns nil (not an error) when a symbol is absent, so the `or'
short-circuits to a direct jump on a hit and to dumb-jump otherwise."
  (or (xref-backend-definitions 'etags identifier)
      (progn (require 'dumb-jump)
             (xref-backend-definitions 'dumb-jump identifier))))

(cl-defmethod xref-backend-references ((_ (eql cm/tags-cascade)) identifier)
  "Delegate references to dumb-jump.
etags has no references method of its own, so this preserves the exact behavior
a non-LSP buffer already has today."
  (require 'dumb-jump)
  (xref-backend-references 'dumb-jump identifier))

(cl-defmethod xref-backend-apropos ((_ (eql cm/tags-cascade)) pattern)
  (xref-backend-apropos 'etags pattern))

(defun cm/project-tags-xref-backend ()
  "Return the cascade backend when a project TAGS is active and no LSP applies.
Yields to Eglot (LSP wins) by returning nil in eglot-managed buffers."
  (and cm/project-tags--active
       (not (bound-and-true-p eglot--managed-mode))
       'cm/tags-cascade))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-tests.sh`
Expected: all pass. The three guard tests run unconditionally; the three cascade
tests run when `etags`/`rg`/`dumb-jump` are present (else `skip-unless` skips
them). Final line `Ran <N> tests, <N> results as expected`, zero unexpected.

- [ ] **Step 5: Commit**

```bash
git add cm-project-tags.el tests/cm-project-tags-tests.el
git commit -m "$(cat <<'EOF'
Add cm/tags-cascade xref backend (etags -> dumb-jump)

Custom xref backend that prefers the precise TAGS index and falls back
to dumb-jump only on a miss; references delegate to dumb-jump (etags has
none). cm/project-tags-xref-backend yields to Eglot so LSP still wins.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Activation hook + `init.el` wiring

**Files:**
- Modify: `cm-project-tags.el` (insert before the `(provide ...)` line)
- Modify: `tests/cm-project-tags-tests.el` (insert before its `(provide ...)`)
- Modify: `init.el` (after the `cm-project-roots` load block at lines 975–979)

**Interfaces:**
- Consumes: `cm/project-tags-file` (Task 1), `cm/project-tags-xref-backend` and
  `cm/project-tags--active` (Task 2).
- Produces: `cm/project-tags-maybe-activate ()` — a `find-file-hook` function
  that, for a prog-mode buffer whose project root holds a `TAGS`, sets
  buffer-local `tags-table-list`, sets `cm/project-tags--active`, and adds
  `cm/project-tags-xref-backend` to buffer-local `xref-backend-functions` at
  depth `-100`.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/cm-project-tags-tests.el`, immediately before
`(provide 'cm-project-tags-tests)`:

```elisp
;; --- activation -------------------------------------------------------------

(ert-deftest cm/project-tags-maybe-activate--installs-cascade ()
  (skip-unless (executable-find "etags"))
  (let* ((p (cm/test-tags--project '("src/in.el")))
         (root (car p)) (tags (cdr p))
         (src (expand-file-name "src/in.el" root)))
    (with-current-buffer (find-file-noselect src)
      (emacs-lisp-mode)
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'fake root)))
                ((symbol-function 'project-root) (lambda (_) root)))
        (cm/project-tags-maybe-activate))
      (should cm/project-tags--active)
      (should (equal tags-table-list (list tags)))
      (should (memq #'cm/project-tags-xref-backend xref-backend-functions)))))

(ert-deftest cm/project-tags-maybe-activate--noop-without-tags ()
  (with-temp-buffer
    (prog-mode)
    (cl-letf (((symbol-function 'cm/project-tags-file) (lambda (&rest _) nil)))
      (cm/project-tags-maybe-activate))
    (should (null cm/project-tags--active))
    (should-not (memq #'cm/project-tags-xref-backend xref-backend-functions))))

(ert-deftest cm/project-tags-maybe-activate--noop-in-non-prog-buffer ()
  (with-temp-buffer
    (fundamental-mode)
    (cl-letf (((symbol-function 'cm/project-tags-file)
               (lambda (&rest _) (error "should not be called in non-prog buffer"))))
      (cm/project-tags-maybe-activate))
    (should (null cm/project-tags--active))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-tests.sh`
Expected: FAIL — `void-function cm/project-tags-maybe-activate`.

- [ ] **Step 3: Implement the activation function**

Insert into `cm-project-tags.el`, immediately before `(provide 'cm-project-tags)`:

```elisp
;; --- Activation (intended for `find-file-hook') ------------------------------

(defun cm/project-tags-maybe-activate ()
  "Load a root project TAGS for this code buffer and install the cascade backend.
No-op unless the buffer derives from `prog-mode' and its project root holds a
readable TAGS file.  The backend is installed at the highest hook priority so it
preempts `xref-union' (which would otherwise merge dumb-jump's hits in)."
  (when (derived-mode-p 'prog-mode)
    (when-let* ((tags (cm/project-tags-file)))
      (setq-local tags-table-list (list tags))
      (setq-local cm/project-tags--active t)
      (add-hook 'xref-backend-functions #'cm/project-tags-xref-backend -100 t))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-tests.sh`
Expected: all pass, zero unexpected.

- [ ] **Step 5: Wire it into `init.el`**

In `init.el`, immediately after the `cm-project-roots` load block (the
`(when (load (locate-user-emacs-file "cm-project-roots") t) ...)` form ending at
line 979), insert:

```elisp
;;;; Project TAGS — auto-load a build-generated root TAGS index — see cm-project-tags.el.
;; If a project root holds a TAGS file (e.g. emitted by a Jai build's metaprogram),
;; load it buffer-locally for code buffers and prefer it for navigation: LSP wins
;; where a server manages the buffer, else the precise etags index, else dumb-jump.
;; `tags-revert-without-query' makes the in-memory table silently re-read after the
;; build regenerates TAGS — no file-watcher, the next lookup picks up the fresh one.
(setq tags-revert-without-query t)
(when (load (locate-user-emacs-file "cm-project-tags") t)
  (add-hook 'find-file-hook #'cm/project-tags-maybe-activate))
```

- [ ] **Step 6: Verify init.el loads clean**

Run:
```bash
emacs --batch --init-directory=/home/jim/projects/emacs-again \
  --eval '(message "init loaded OK")' 2>&1 | tail -5
```
Expected: ends with `init loaded OK`, no errors/backtraces referencing
`cm-project-tags`, `cm/project-tags-maybe-activate`, or `tags-revert-without-query`.

- [ ] **Step 7: Commit**

```bash
git add cm-project-tags.el tests/cm-project-tags-tests.el init.el
git commit -m "$(cat <<'EOF'
Wire project-TAGS auto-load into find-file-hook

cm/project-tags-maybe-activate loads a root TAGS buffer-locally for code
buffers and installs the cascade at top xref priority. init.el adds the
hook and sets tags-revert-without-query for silent reload after rebuilds.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Documentation

**Files:**
- Modify: `CLAUDE.md` (architecture list item + a new section)
- Modify: `README.md` (a navigation note)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `CLAUDE.md` architecture list**

In `CLAUDE.md`, in the "Architecture of init.el" numbered list, find item 16
(the "Multi-root project search" entry, which begins
"**Multi-root project search** — `cm-project-roots.el`…"). Immediately after
that list item, add a new item 17:

```markdown
17. **Project TAGS auto-loading** — `cm-project-tags.el` (loaded after the
    multi-root block): on `find-file`, if the project root holds a `TAGS` file,
    load it buffer-locally and install the `cm/tags-cascade` xref backend
    (etags → dumb-jump fallback; yields to Eglot). See below.
```

- [ ] **Step 2: Add a `CLAUDE.md` section**

In `CLAUDE.md`, immediately before the `## Markdown preview` section, insert:

```markdown
## Project TAGS auto-loading

`cm-project-tags.el` (a sibling library loaded from `init.el`, like
`cm-project-roots.el`) auto-loads a build-generated `TAGS` index and wires it
into navigation. On `find-file`, in any `prog-mode` buffer, `cm/project-tags-file`
checks the project root (via `project-current`) for a `TAGS`; if present it is
bound buffer-locally (`setq-local tags-table-list` — never a global
`visit-tags-table`, so projects don't pollute each other) and a custom xref
backend is installed.

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

**The driving case is Jai** (`~/projects/game-bootstrap`), whose `first.jai`
emits a compiler-precise ETAGS index every successful build and which has no
wired LSP — but the feature is generic: a `TAGS` file at a project root is taken
as the signal that good tooling produced it. Where an LSP exists, the cascade
yields and LSP wins, so "generic" costs nothing. Tests: ERT suite under `tests/`
(`./tests/run-tests.sh`). Design + plan:
`docs/plans/2026-06-25-project-tags-design.md` and `…-plan.md`.
```

- [ ] **Step 3: Update `README.md`**

In `README.md`, immediately after the `## Compilation` section (which ends with
the line about the stock `gnu` matcher) and before `## SQL tooling`, insert:

```markdown
## Project TAGS

If a project root holds a build-generated `TAGS` index, it is loaded
automatically (buffer-locally) for code buffers, and navigation prefers it:
`M-.` uses LSP where a server manages the buffer, otherwise the precise `TAGS`
index (a direct jump), falling back to dumb-jump only when `TAGS` has no match.
The table silently reloads after each rebuild (`tags-revert-without-query`), so a
build that regenerates `TAGS` is picked up on the next lookup. Generic across
projects; implemented in `cm-project-tags.el` (ERT tests under `tests/`). The
driving case is Jai, whose build emits a compiler-precise index and which has no
stable LSP.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "$(cat <<'EOF'
Document project-TAGS auto-loading

CLAUDE.md architecture item + section, and a README navigation note,
covering the cm/tags-cascade priority, the depth -100 union preemption,
and silent reload via tags-revert-without-query.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage** (each design section → task):
- Goal / priority (LSP > etags > dumb-jump) → Task 2 backend + guard.
- Decision 1 (cascade not merge) → Task 2 `definitions` `or`.
- Decision 2 (three regimes) → Task 2 guard (eglot yield) + Task 3 activation
  (only when TAGS present) + untouched union for the third regime.
- Decision 3 (load buffer-locally, lazily, no prompt) → Task 3 `setq-local
  tags-table-list`; verified prompt-free.
- Decision 4 (reload via `tags-revert-without-query t`) → Task 3 init.el.
- Decision 5 (generic) → `cm/project-tags-file`/activation gate only on
  prog-mode + TAGS presence, no language check.
- Decision 6 (sibling library) → Task 1 `cm-project-tags.el` + init.el load.
- Architecture components (`cm/project-tags-file`,
  `cm/project-tags--maybe-activate`, `cm/project-tags-xref-backend`, cascade
  methods) → Tasks 1–3, all present.
- Error handling (no project / no TAGS / eglot-after-hook / cross-project /
  no double dumb-jump) → guard returns nil paths + buffer-local table +
  until-success short-circuit; covered by guard/activation tests.
- Testing section → Tasks 1–3 ERT tests (pure detection + guard + cascade
  integration with `skip-unless`).
- Out-of-scope items (file-notify, TAGS generation, jails, multi-root TAGS) →
  not implemented. ✓

**Placeholder scan:** none — every step has complete code or an exact command
with expected output.

**Type/name consistency:** backend symbol `cm/tags-cascade` and the
`(eql cm/tags-cascade)` specializer are used identically in Task 2 (definition)
and Tasks 2–3 tests (dispatch). `cm/project-tags-file`,
`cm/project-tags--active`, `cm/project-tags-xref-backend`, and
`cm/project-tags-maybe-activate` names match across library, init.el wiring, and
tests. `tags-table-list` (not `tags-file-name`) used consistently.
