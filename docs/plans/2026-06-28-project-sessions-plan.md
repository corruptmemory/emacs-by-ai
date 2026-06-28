# Per-project session persistence (`cm-project-sessions.el`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give an ephemeral Emacs Sublime-style project workspaces — `C-x p p` saves the current project's session, tears the workspace down cleanly, and restores (or creates) the target project's full state (files, window/split layout, per-file point, and unsaved scratch buffers).

**Architecture:** A new sibling library `cm-project-sessions.el` (loaded like `cm-project-roots.el` / `cm-project-tags.el`) layers over the `easysession` package (the persistence engine) and built-in `project.el` (project identity). It owns the project↔session mapping, the `C-x p p` flip (via `:around` advice), two scratch tiers (per-project scratch that rides each session + an always-present global stash), and restore-by-launch-directory at startup. Purely additive; no existing behavior changes.

**Tech Stack:** Emacs Lisp; `easysession` (MELPA, installed via straight.el); built-in `project.el`, `saveplace`, `cl-lib`, `seq`; ERT for tests.

## Global Constraints

- **Emacs 29+** (repo floor). `easysession` requires Emacs 26.1+, so the floor holds.
- **`cm/` prefix** for every custom function and variable (`cm` = corruptmemory). Private helpers use `cm/...--...` (double dash), matching `cm-project-tags.el`.
- **Loaded as source, never byte-compiled** — these sibling libraries are loaded via `(load (locate-user-emacs-file "...") t)`, consistent with `cm-project-tags.el`. (Relevant because `easysession-define-handler` is a macro; deferring its expansion to runtime is safe under source loading.)
- **File header form:** `;;; NAME --- DESC  -*- lexical-binding: t; -*-` … `(provide 'NAME)` … `;;; NAME ends here`.
- **Test harness:** `./tests/run-tests.sh` runs every `tests/*-tests.el` via `emacs -batch -Q` with the repo root and `straight/build/*` on `load-path`. Tests requiring `easysession` use `(skip-unless (require 'easysession nil t))`.
- **Git:** commit directly to `master`; do **not** push. Every commit message ends with the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Session/stash state files** live under `user-emacs-directory` and are **git-ignored** (consistent with `recentf`/`saveplace`/`projects`).
- **Design reference:** `docs/plans/2026-06-28-project-sessions-design.md`.

---

### Task 1: Library skeleton + project↔session naming

Creates the library file with its header, requires, customization group, custom variables, and the two pure path helpers that everything else keys off. Also creates the test file.

**Files:**
- Create: `cm-project-sessions.el`
- Test: `tests/cm-project-sessions-tests.el`

**Interfaces:**
- Produces:
  - `cm/scratch-default-mode` (defcustom, symbol; default `text-mode`)
  - `cm/session-save-interval` (defcustom, integer; default 60)
  - `cm/stash-file` (defcustom, file path; default `(locate-user-emacs-file "project-stash.el")`)
  - `cm/session-name-for-project (root)` → string: stable, filesystem-safe session name
  - `cm/session--root-of (dir)` → string|nil: project root containing DIR

- [ ] **Step 1: Write the failing test**

Create `tests/cm-project-sessions-tests.el`:

```elisp
;;; cm-project-sessions-tests.el --- Tests for cm-project-sessions  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'cm-project-sessions)

;; --- naming ----------------------------------------------------------------

(ert-deftest cm/session-name-for-project--stable-and-fs-safe ()
  "A session name is deterministic and contains only filesystem-safe chars."
  (should (equal (cm/session-name-for-project "/tmp/aa/bb") "-tmp-aa-bb"))
  ;; trailing slash is normalized to the same name
  (should (equal (cm/session-name-for-project "/tmp/aa/bb/") "-tmp-aa-bb"))
  ;; unsafe characters are replaced
  (should (string-match-p "\\`[A-Za-z0-9._-]+\\'"
                          (cm/session-name-for-project "/x/y z/@!"))))

(ert-deftest cm/session--root-of--returns-project-root ()
  "Returns the project root when DIR is inside a project, nil otherwise."
  (let ((root "/tmp/proj/"))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'fake root)))
              ((symbol-function 'project-root) (lambda (_) root)))
      (should (equal (cm/session--root-of "/tmp/proj/src") root)))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
      (should (null (cm/session--root-of "/tmp/elsewhere"))))))

(provide 'cm-project-sessions-tests)
;;; cm-project-sessions-tests.el ends here
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run-tests.sh`
Expected: FAIL — `Cannot open load file: cm-project-sessions` (library not created yet).

- [ ] **Step 3: Write the minimal library**

Create `cm-project-sessions.el`:

```elisp
;;; cm-project-sessions.el --- Per-project session persistence  -*- lexical-binding: t; -*-
;;; Commentary:
;; Sessions-as-projects on `easysession': `C-x p p' saves the current project's
;; session, tears the workspace down, and restores (or creates) the target's.
;; Two scratch tiers: per-project scratch buffers (*scratch:PROJ:N*) ride each
;; session; a global stash (*stash:NAME* and the lone *scratch*) is always
;; present.  Restore-by-launch-directory at startup.
;; Purely additive; existing single-project commands are untouched.
;; See docs/plans/2026-06-28-project-sessions-design.md.
;;; Code:

(require 'project)
(require 'cl-lib)
(require 'seq)
;; Soft require: the pure helpers work without easysession; the flip needs it.
(require 'easysession nil t)

(defgroup cm/project-sessions nil
  "Per-project session persistence layered over easysession."
  :group 'convenience
  :prefix "cm/")

(defcustom cm/scratch-default-mode 'text-mode
  "Major mode applied to newly created scratch and stash buffers."
  :type 'function)

(defcustom cm/session-save-interval 60
  "Seconds between background session auto-saves (see `easysession-save-mode')."
  :type 'integer)

(defcustom cm/stash-file (locate-user-emacs-file "project-stash.el")
  "File holding the always-present global stash buffers (and the lone *scratch*)."
  :type 'file)

;; --- Project <-> session name ----------------------------------------------

(defun cm/session-name-for-project (root)
  "Return a stable, filesystem-safe session name for project ROOT."
  (let ((abbrev (abbreviate-file-name
                 (directory-file-name (expand-file-name root)))))
    (replace-regexp-in-string "[^A-Za-z0-9._-]" "-" abbrev)))

(defun cm/session--root-of (dir)
  "Return the project root containing DIR, or nil when DIR is not in a project."
  (when-let* ((proj (project-current nil dir)))
    (project-root proj)))

(provide 'cm-project-sessions)
;;; cm-project-sessions.el ends here
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-tests.sh`
Expected: PASS — the two new tests pass; existing `cm-project-roots`/`cm-project-tags` suites still pass.

- [ ] **Step 5: Commit**

```bash
git add cm-project-sessions.el tests/cm-project-sessions-tests.el
git commit -m "feat(sessions): library skeleton + project↔session naming

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Scratch tier classification + the `cm/scratch-new` command

Adds the buffer-name predicates that distinguish the two tiers and the zero-ceremony creation command bound later to `C-c n`.

**Files:**
- Modify: `cm-project-sessions.el` (append a "Scratch tiers" section before `(provide …)`)
- Test: `tests/cm-project-sessions-tests.el`

**Interfaces:**
- Consumes: `cm/scratch-default-mode`, `cm/session--root-of` (Task 1)
- Produces:
  - `cm/scratch--project-buffer-p (buf)` → boolean (name has prefix `*scratch:`)
  - `cm/scratch--stash-buffer-p (buf)` → boolean (name has prefix `*stash:` or equals `*scratch*`)
  - `cm/scratch--project-tag ()` → string (current project basename, or "none")
  - `cm/scratch--next-project-index (tag)` → integer (smallest free N for `*scratch:TAG:N*`)
  - `cm/scratch-new (&optional global)` → buffer (interactive; `C-c n` later)

- [ ] **Step 1: Write the failing tests**

Append to `tests/cm-project-sessions-tests.el` (before the `(provide …)` line):

```elisp
;; --- scratch tiers ---------------------------------------------------------

(ert-deftest cm/scratch--classification ()
  "Project, stash, and lone-scratch buffers classify into the right tier."
  (cl-flet ((mk (n) (get-buffer-create n)))
    (unwind-protect
        (progn
          (should (cm/scratch--project-buffer-p (mk "*scratch:foo:1*")))
          (should-not (cm/scratch--project-buffer-p (mk "*stash:snip*")))
          (should-not (cm/scratch--project-buffer-p (mk "*scratch*")))
          (should (cm/scratch--stash-buffer-p (mk "*stash:snip*")))
          (should (cm/scratch--stash-buffer-p (mk "*scratch*")))
          (should-not (cm/scratch--stash-buffer-p (mk "*scratch:foo:1*"))))
      (dolist (n '("*scratch:foo:1*" "*stash:snip*"))
        (when (get-buffer n) (kill-buffer n))))))

(ert-deftest cm/scratch-new--project-tier-instant ()
  "Without a prefix, creates the next-numbered project scratch buffer."
  (cl-letf (((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/myproj/")))
    (let ((buf (cm/scratch-new nil)))
      (unwind-protect
          (progn
            (should (string-prefix-p "*scratch:myproj:" (buffer-name buf)))
            (should (eq (buffer-local-value 'major-mode buf) cm/scratch-default-mode)))
        (kill-buffer buf)))))

(ert-deftest cm/scratch-new--global-tier-prompts ()
  "With a prefix, prompts for a name and creates a *stash:NAME* buffer."
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "snippets")))
    (let ((buf (cm/scratch-new t)))
      (unwind-protect
          (should (equal (buffer-name buf) "*stash:snippets*"))
        (kill-buffer buf)))))
```

- [ ] **Step 2: Run to verify failure**

Run: `./tests/run-tests.sh`
Expected: FAIL — `cm/scratch--project-buffer-p` and friends are not defined.

- [ ] **Step 3: Implement**

Insert into `cm-project-sessions.el` immediately before `(provide 'cm-project-sessions)`:

```elisp
;; --- Scratch tiers ---------------------------------------------------------

(defun cm/scratch--project-buffer-p (buf)
  "Non-nil when BUF is a per-project scratch buffer (*scratch:PROJ:N*)."
  (string-prefix-p "*scratch:" (buffer-name buf)))

(defun cm/scratch--stash-buffer-p (buf)
  "Non-nil when BUF is a global stash buffer (*stash:NAME* or the lone *scratch*)."
  (let ((name (buffer-name buf)))
    (or (string-prefix-p "*stash:" name)
        (string= name "*scratch*"))))

(defun cm/scratch--project-tag ()
  "Short tag for the current project (its directory basename), or \"none\"."
  (let ((root (cm/session--root-of default-directory)))
    (if root
        (file-name-nondirectory (directory-file-name root))
      "none")))

(defun cm/scratch--next-project-index (tag)
  "Return the smallest N >= 1 for which *scratch:TAG:N* is not a live buffer."
  (let ((n 1))
    (while (get-buffer (format "*scratch:%s:%d*" tag n))
      (setq n (1+ n)))
    n))

(defun cm/scratch-new (&optional global)
  "Create a fresh scratch buffer, switch to it, and return it.
Without a prefix: an instant project-tier buffer *scratch:PROJECT:N* (no prompt).
With prefix GLOBAL (\\[universal-argument]): prompt for NAME and create or visit
the global stash buffer *stash:NAME*."
  (interactive "P")
  (let ((buf (if global
                 (get-buffer-create
                  (format "*stash:%s*" (read-string "Stash name: ")))
               (let ((tag (cm/scratch--project-tag)))
                 (get-buffer-create
                  (format "*scratch:%s:%d*" tag
                          (cm/scratch--next-project-index tag)))))))
    (with-current-buffer buf
      (unless (eq major-mode cm/scratch-default-mode)
        (funcall cm/scratch-default-mode)))
    (switch-to-buffer buf)
    buf))
```

- [ ] **Step 4: Run to verify pass**

Run: `./tests/run-tests.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cm-project-sessions.el tests/cm-project-sessions-tests.el
git commit -m "feat(sessions): scratch tier predicates + cm/scratch-new command

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Per-project scratch handler (save/load round-trip)

The two functions easysession calls to serialize/restore project scratch buffers into a session blob. Written as plain functions (no easysession macros) so they round-trip in a unit test with no dependency.

**Files:**
- Modify: `cm-project-sessions.el` (append "Per-project scratch handler" section)
- Test: `tests/cm-project-sessions-tests.el`

**Interfaces:**
- Consumes: `cm/scratch--project-buffer-p`, `cm/scratch-default-mode`
- Produces:
  - `cm/scratch--save-handler (buffers)` → alist `((NAME . ((buffer-string . TEXT))) …)` for the project scratch buffers in BUFFERS
  - `cm/scratch--load-handler (session-data)` → recreates each buffer from that alist

- [ ] **Step 1: Write the failing test**

Append to `tests/cm-project-sessions-tests.el` before `(provide …)`:

```elisp
;; --- per-project scratch handler -------------------------------------------

(ert-deftest cm/scratch-handler--round-trip ()
  "Save handler serializes project scratch buffers; load handler restores them."
  (let ((a (get-buffer-create "*scratch:proj:1*"))
        (b (get-buffer-create "*scratch:proj:2*"))
        (file (get-buffer-create "real.el")))   ; must be ignored
    (unwind-protect
        (progn
          (with-current-buffer a (insert "ALPHA"))
          (with-current-buffer b (insert "BETA"))
          (let ((data (cm/scratch--save-handler (list a b file))))
            (should (= 2 (length data)))
            (should (equal "ALPHA" (alist-get 'buffer-string (cdr (assoc "*scratch:proj:1*" data)))))
            ;; now kill and restore from the serialized data
            (kill-buffer a) (kill-buffer b)
            (should-not (get-buffer "*scratch:proj:1*"))
            (cm/scratch--load-handler data)
            (should (equal "ALPHA" (with-current-buffer "*scratch:proj:1*" (buffer-string))))
            (should (equal "BETA"  (with-current-buffer "*scratch:proj:2*" (buffer-string))))))
      (dolist (n '("*scratch:proj:1*" "*scratch:proj:2*" "real.el"))
        (when (get-buffer n) (kill-buffer n))))))
```

- [ ] **Step 2: Run to verify failure**

Run: `./tests/run-tests.sh`
Expected: FAIL — `cm/scratch--save-handler` undefined.

- [ ] **Step 3: Implement**

Insert before `(provide …)`:

```elisp
;; --- Per-project scratch handler (registered with easysession in setup) -----
;; Plain functions (no easysession macros) so they round-trip independently.

(defun cm/scratch--save-handler (buffers)
  "easysession SAVE handler: serialize the project scratch buffers in BUFFERS.
Returns an alist ((NAME . ((buffer-string . TEXT))) …)."
  (delq nil
        (mapcar
         (lambda (buf)
           (when (and (buffer-live-p buf) (cm/scratch--project-buffer-p buf))
             (with-current-buffer buf
               (cons (buffer-name buf)
                     (list (cons 'buffer-string
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))))))
         buffers)))

(defun cm/scratch--load-handler (session-data)
  "easysession LOAD handler: recreate project scratch buffers from SESSION-DATA."
  (dolist (item session-data)
    (let* ((name (car item))
           (text (alist-get 'buffer-string (cdr item))))
      (with-current-buffer (get-buffer-create name)
        (funcall cm/scratch-default-mode)
        (erase-buffer)
        (when text (insert text))))))
```

- [ ] **Step 4: Run to verify pass**

Run: `./tests/run-tests.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cm-project-sessions.el tests/cm-project-sessions-tests.el
git commit -m "feat(sessions): per-project scratch save/load handlers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Global stash persistence

The standalone (project-independent) persistence for the always-present stash buffers, written to a single file.

**Files:**
- Modify: `cm-project-sessions.el` (append "Global stash" section)
- Test: `tests/cm-project-sessions-tests.el`

**Interfaces:**
- Consumes: `cm/scratch--stash-buffer-p`, `cm/scratch-default-mode`, `cm/stash-file`
- Produces:
  - `cm/stash--buffers ()` → list of live stash buffers
  - `cm/stash-save ()` → writes them to `cm/stash-file`
  - `cm/stash-load ()` → recreates them from `cm/stash-file`

- [ ] **Step 1: Write the failing test**

Append before `(provide …)`:

```elisp
;; --- global stash ----------------------------------------------------------

(ert-deftest cm/stash--round-trip ()
  "Stash save writes live stash buffers; load recreates them from the file."
  (let* ((cm/stash-file (make-temp-file "cm-stash" nil ".el"))
         (s (get-buffer-create "*stash:snippets*"))
         (sc (get-buffer-create "*scratch*"))
         (proj (get-buffer-create "*scratch:proj:1*")))  ; must NOT be in the stash
    (unwind-protect
        (progn
          (with-current-buffer s (insert "REUSABLE"))
          (with-current-buffer sc (erase-buffer) (insert "LONE"))
          (cm/stash-save)
          (kill-buffer s) (kill-buffer sc)
          (should-not (get-buffer "*stash:snippets*"))
          (cm/stash-load)
          (should (equal "REUSABLE" (with-current-buffer "*stash:snippets*" (buffer-string))))
          (should (equal "LONE" (with-current-buffer "*scratch*" (buffer-string)))))
      (dolist (n '("*stash:snippets*" "*scratch:proj:1*"))
        (when (get-buffer n) (kill-buffer n)))
      (when (file-exists-p cm/stash-file) (delete-file cm/stash-file)))))
```

- [ ] **Step 2: Run to verify failure**

Run: `./tests/run-tests.sh`
Expected: FAIL — `cm/stash-save` undefined.

- [ ] **Step 3: Implement**

Insert before `(provide …)`:

```elisp
;; --- Global stash (always-present; persisted outside any session blob) ------

(defun cm/stash--buffers ()
  "Return the live global stash buffers (and the lone *scratch*)."
  (seq-filter #'cm/scratch--stash-buffer-p (buffer-list)))

(defun cm/stash-save ()
  "Write the global stash buffers to `cm/stash-file'."
  (let ((data (mapcar (lambda (buf)
                        (with-current-buffer buf
                          (list (buffer-name)
                                (buffer-substring-no-properties
                                 (point-min) (point-max)))))
                      (cm/stash--buffers))))
    (with-temp-file cm/stash-file
      (let ((print-length nil) (print-level nil))
        (prin1 data (current-buffer))))))

(defun cm/stash-load ()
  "Recreate the global stash buffers from `cm/stash-file'."
  (when (file-readable-p cm/stash-file)
    (let ((data (with-temp-buffer
                  (insert-file-contents cm/stash-file)
                  (goto-char (point-min))
                  (ignore-errors (read (current-buffer))))))
      (dolist (item data)
        (let ((name (car item)) (text (cadr item)))
          (with-current-buffer (get-buffer-create name)
            (unless (string= name "*scratch*")
              (funcall cm/scratch-default-mode))
            (erase-buffer)
            (when text (insert text))))))))
```

- [ ] **Step 4: Run to verify pass**

Run: `./tests/run-tests.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cm-project-sessions.el tests/cm-project-sessions-tests.el
git commit -m "feat(sessions): global stash persistence (cm/stash-save/-load)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: The flip — `cm/session-switch-to-project`

The orchestration that saves the current session, tears down (including explicit project-scratch kill), and switches to the target. Tested with `easysession` functions stubbed to record call order.

**Files:**
- Modify: `cm-project-sessions.el` (append "The flip" section)
- Test: `tests/cm-project-sessions-tests.el`

**Interfaces:**
- Consumes: `cm/session--root-of`, `cm/session-name-for-project`, `cm/scratch--project-buffer-p`, `cm/stash-save`, `cm/stash-load`; runtime easysession functions `easysession-get-session-name`, `easysession-save`, `easysession-kill-all-buffers`, `easysession-switch-to`, and the variable `easysession-directory`, `easysession-switch-to-save-session`.
- Produces:
  - `cm/session-switch-to-project (dir)` → symbol: `not-a-project` | `noop` | `restored` | `created`

- [ ] **Step 1: Write the failing test**

Append before `(provide …)`:

```elisp
;; --- the flip --------------------------------------------------------------

(ert-deftest cm/session-switch--not-a-project ()
  "Returns `not-a-project' and does nothing when DIR is not in a project."
  (cl-letf (((symbol-function 'cm/session--root-of) (lambda (_) nil)))
    (should (eq 'not-a-project (cm/session-switch-to-project "/tmp/x")))))

(ert-deftest cm/session-switch--noop-when-same-project ()
  "Returns `noop' when the target session equals the current one."
  (cl-letf (((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/p/"))
            ((symbol-function 'cm/session-name-for-project) (lambda (_) "P"))
            ((symbol-function 'easysession-get-session-name) (lambda () "P")))
    (should (eq 'noop (cm/session-switch-to-project "/tmp/p/")))))

(ert-deftest cm/session-switch--full-flow-order ()
  "Leaving a project: prompt-save, stash-save, session-save, teardown, switch, stash-load."
  (let ((calls '())
        (easysession-directory (make-temp-file "cm-sess" t))
        (easysession-switch-to-save-session t))
    (cl-letf (((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/b/"))
              ((symbol-function 'cm/session-name-for-project) (lambda (_) "B"))
              ((symbol-function 'easysession-get-session-name) (lambda () "A"))
              ((symbol-function 'save-some-buffers) (lambda (&rest _) (push 'prompt calls)))
              ((symbol-function 'cm/stash-save) (lambda () (push 'stash-save calls)))
              ((symbol-function 'easysession-save) (lambda (&rest _) (push 'session-save calls)))
              ((symbol-function 'easysession-kill-all-buffers) (lambda () (push 'kill calls)))
              ((symbol-function 'easysession-switch-to) (lambda (n) (push (cons 'switch n) calls)))
              ((symbol-function 'cm/stash-load) (lambda () (push 'stash-load calls))))
      ;; target "B" has no session file on disk -> `created'
      (should (eq 'created (cm/session-switch-to-project "/tmp/b/")))
      (should (equal (reverse calls)
                     '(prompt stash-save session-save kill (switch . "B") stash-load))))))
```

- [ ] **Step 2: Run to verify failure**

Run: `./tests/run-tests.sh`
Expected: FAIL — `cm/session-switch-to-project` undefined.

- [ ] **Step 3: Implement**

Insert before `(provide …)`:

```elisp
;; --- The flip (driven by C-x p p via advice in setup) ----------------------

(defun cm/session-switch-to-project (dir)
  "Save the current project session, tear it down, and switch to the project at DIR.
Returns `not-a-project', `noop', `restored', or `created'.
The current session is saved only when one is loaded (`easysession-save' errors
otherwise).  Project-scratch buffers are killed explicitly because
`easysession-kill-all-buffers' spares special buffers; they are restored from
the target session's blob.  The global stash is saved before teardown and
reloaded after, so it survives the kill."
  (let* ((root (cm/session--root-of dir))
         (target (and root (cm/session-name-for-project root)))
         (current (easysession-get-session-name)))
    (cond
     ((null target)
      (message "[cm/session] %s is not a project" dir)
      'not-a-project)
     ((equal target current)
      (message "[cm/session] already in %s" target)
      'noop)
     (t
      (let ((existing (file-exists-p (expand-file-name target easysession-directory))))
        (save-some-buffers nil (lambda () (and buffer-file-name (buffer-modified-p))))
        (cm/stash-save)
        (when current (easysession-save))
        (dolist (buf (seq-filter #'cm/scratch--project-buffer-p (buffer-list)))
          (kill-buffer buf))
        (easysession-kill-all-buffers)
        (let ((easysession-switch-to-save-session nil))
          (easysession-switch-to target))
        (cm/stash-load)
        (message "[cm/session] switched to %s" target)
        (if existing 'restored 'created))))))
```

- [ ] **Step 4: Run to verify pass**

Run: `./tests/run-tests.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cm-project-sessions.el tests/cm-project-sessions-tests.el
git commit -m "feat(sessions): cm/session-switch-to-project flip orchestration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `C-x p p` advice, startup restore, and setup entry point

Wires the flip to `project-switch-project`, restores by launch directory at startup, and provides the single setup function `init.el` will call. Includes a `skip-unless` integration test that exercises the real easysession round-trip through the registered handler (mirrors the validated spike).

**Files:**
- Modify: `cm-project-sessions.el` (append "Advice / startup / setup" section)
- Test: `tests/cm-project-sessions-tests.el`

**Interfaces:**
- Consumes: `cm/session-switch-to-project`, `cm/session--root-of`, `cm/session-name-for-project`, `cm/stash-load`, `cm/stash-save`, `cm/scratch--load-handler`, `cm/scratch--save-handler`, `cm/session-save-interval`; easysession `easysession-directory`, `easysession-switch-to`, `easysession-save-mode`, `easysession-save-interval`, `easysession-exclude-from-find-file-hook`, `easysession-define-handler`.
- Produces:
  - `cm/session--project-switch-advice (orig &optional dir &rest _)` — `:around` advice body
  - `cm/session-startup ()` — `emacs-startup-hook` function
  - `cm/project-sessions-setup ()` — the single entry point called from `init.el`

- [ ] **Step 1: Write the failing tests**

Append before `(provide …)`:

```elisp
;; --- advice / startup ------------------------------------------------------

(ert-deftest cm/session-advice--routes-to-flip ()
  "The advice calls the flip with the chosen dir; a `created' result opens a file."
  (let ((switched nil) (found nil))
    (cl-letf (((symbol-function 'cm/session-switch-to-project)
               (lambda (dir) (setq switched dir) 'created))
              ((symbol-function 'project-find-file) (lambda (&rest _) (setq found t))))
      (cm/session--project-switch-advice #'ignore "/tmp/new/")
      (should (equal switched "/tmp/new/"))
      (should found))))   ; 'created path kicks off project-find-file

(ert-deftest cm/session-startup--restores-existing-launch-project ()
  "Startup loads the stash, then restores the launch dir's session when it exists."
  (let ((loaded nil) (stash nil)
        (easysession-directory (make-temp-file "cm-sess" t)))
    ;; pretend the launch dir is project P and its session file exists
    (with-temp-file (expand-file-name "P" easysession-directory) (insert ""))
    (cl-letf (((symbol-function 'cm/stash-load) (lambda () (setq stash t)))
              ((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/p/"))
              ((symbol-function 'cm/session-name-for-project) (lambda (_) "P"))
              ((symbol-function 'easysession-switch-to) (lambda (n) (setq loaded n))))
      (cm/session-startup)
      (should stash)
      (should (equal loaded "P")))))

(ert-deftest cm/session-startup--blank-when-no-saved-session ()
  "Startup does not switch when the launch project has no saved session yet."
  (let ((loaded nil)
        (easysession-directory (make-temp-file "cm-sess" t)))
    (cl-letf (((symbol-function 'cm/stash-load) #'ignore)
              ((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/p/"))
              ((symbol-function 'cm/session-name-for-project) (lambda (_) "P"))
              ((symbol-function 'easysession-switch-to) (lambda (n) (setq loaded n))))
      (cm/session-startup)
      (should (null loaded)))))

;; --- integration: real easysession round-trip (skipped if not installed) ---

(ert-deftest cm/session-integration--scratch-handler-round-trip ()
  "With easysession present, a registered handler round-trips project scratch."
  (skip-unless (require 'easysession nil t))
  (let* ((easysession-directory (make-temp-file "cm-sess" t))
         (name "IT"))
    ;; register our handlers and create a project scratch buffer
    (easysession-define-handler "cm-project-scratch"
      #'cm/scratch--load-handler #'cm/scratch--save-handler)
    (let ((buf (get-buffer-create "*scratch:IT:1*")))
      (with-current-buffer buf (insert "INTEGRATION"))
      (let ((easysession-switch-to-save-session nil))
        (easysession-switch-to name))   ; create + set current
      (easysession-save name)
      (kill-buffer buf)
      (should-not (get-buffer "*scratch:IT:1*"))
      (easysession-load name)
      (should (equal "INTEGRATION"
                     (with-current-buffer "*scratch:IT:1*" (buffer-string))))
      (when (get-buffer "*scratch:IT:1*") (kill-buffer "*scratch:IT:1*")))))
```

- [ ] **Step 2: Run to verify failure**

Run: `./tests/run-tests.sh`
Expected: FAIL — `cm/session--project-switch-advice` / `cm/session-startup` undefined (the integration test SKIPs unless easysession is installed).

- [ ] **Step 3: Implement**

Insert before `(provide …)`:

```elisp
;; --- C-x p p advice, startup restore, setup --------------------------------

(defun cm/session--project-switch-advice (_orig &optional dir &rest _)
  "Route `project-switch-project' through the session flip.
DIR is the chosen project directory (read interactively when nil).  A brand-new
project (no saved session) lands blank, so kick off `project-find-file' to help
the user start; an existing project is fully restored and needs nothing more."
  (let ((dir (or dir (project-prompt-project-dir))))
    (when (eq 'created (cm/session-switch-to-project dir))
      (let ((default-directory dir))
        (project-find-file)))))

(defun cm/session-startup ()
  "Load the global stash, then restore the launch directory's project session.
Restores only when a saved session exists for the launch project; otherwise
leaves Emacs blank (a fresh project is created on the first `C-x p p')."
  (cm/stash-load)
  (when-let* ((root (cm/session--root-of default-directory))
              (name (cm/session-name-for-project root)))
    (when (file-exists-p (expand-file-name name easysession-directory))
      (let ((easysession-switch-to-save-session nil))
        (easysession-switch-to name)))))

(defun cm/project-sessions-setup ()
  "Enable per-project session persistence.  Call after `easysession' is loaded."
  (require 'easysession)
  ;; Let saveplace restore point during session restore (easysession suppresses
  ;; it by default to own point via window-state, which is unreliable headless).
  (setq easysession-exclude-from-find-file-hook
        (delq 'save-place-find-file-hook easysession-exclude-from-find-file-hook))
  (setq easysession-save-interval cm/session-save-interval)
  (easysession-save-mode 1)
  (easysession-define-handler "cm-project-scratch"
    #'cm/scratch--load-handler #'cm/scratch--save-handler)
  (advice-add 'project-switch-project :around #'cm/session--project-switch-advice)
  (add-hook 'emacs-startup-hook #'cm/session-startup)
  (add-hook 'kill-emacs-hook #'cm/stash-save))
```

- [ ] **Step 4: Run to verify pass**

Run: `./tests/run-tests.sh`
Expected: PASS (the advice/startup tests pass; the integration test passes if easysession is installed, otherwise SKIPs).

- [ ] **Step 5: Commit**

```bash
git add cm-project-sessions.el tests/cm-project-sessions-tests.el
git commit -m "feat(sessions): C-x p p advice, startup restore, setup entry point

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Wire into `init.el` and `.gitignore`

Install `easysession`, load the sibling, bind `C-c n`, call the setup, point `easysession-directory` at a git-ignored location, and ignore the state files.

**Files:**
- Modify: `init.el` (new `use-package easysession` block + sibling load, near the other `cm-project-*` loads around line 975-989)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `cm/project-sessions-setup`, `cm/scratch-new` (Task 6 / Task 2)

- [ ] **Step 1: Add the configuration block to `init.el`**

Insert after the Project TAGS block (the `cm-project-tags` load near line 989), following the existing sibling-load style:

```elisp
;;;; Project sessions — per-project workspace persistence — see cm-project-sessions.el.
;; Sessions-as-projects on easysession: C-x p p saves the current project's
;; session, tears down, and restores (or creates) the target's — files, window
;; layout, per-file point, and unsaved scratch buffers.  Two scratch tiers:
;; per-project (*scratch:PROJ:N*, instant via C-c n) ride each session; a global
;; stash (*stash:NAME* via C-u C-c n, and the lone *scratch*) is always present.
;; See docs/plans/2026-06-28-project-sessions-design.md.
(use-package easysession
  :init
  (setq easysession-directory (locate-user-emacs-file "sessions/"))
  :config
  (when (load (locate-user-emacs-file "cm-project-sessions") t)
    (cm/project-sessions-setup)
    (global-set-key (kbd "C-c n") #'cm/scratch-new)))
```

- [ ] **Step 2: Add ignore entries to `.gitignore`**

Under the existing `# Session state files` group, add:

```
sessions/
project-stash.el
```

- [ ] **Step 3: Verify the suite still passes and the library byte-loads cleanly**

Run: `./tests/run-tests.sh`
Expected: PASS (including the integration test once easysession is installed by the block above).

Run a load smoke-test in a real init (installs easysession via straight on first run, then confirms setup ran and the key is bound):

```bash
emacs --batch --init-directory=$HOME/projects/emacs-again -l init.el \
  --eval '(progn
            (princ (format "easysession loaded: %s\n" (featurep (quote easysession))))
            (princ (format "setup advice on project-switch-project: %s\n"
                           (advice-member-p (function cm/session--project-switch-advice)
                                            (function project-switch-project))))
            (princ (format "C-c n bound to: %s\n" (key-binding (kbd "C-c n")))))'
```
Expected output (first run may print straight.el install logs first):
```
easysession loaded: t
setup advice on project-switch-project: t
C-c n bound to: cm/scratch-new
```

- [ ] **Step 4: Commit**

```bash
git add init.el .gitignore
git commit -m "feat(sessions): wire cm-project-sessions into init.el + gitignore state

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Documentation

Add a `CLAUDE.md` architecture entry + section and a `README.md` section.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Add to `CLAUDE.md`**

In the "Architecture of init.el" numbered list, append a new item after item 17 (Project TAGS):

```markdown
18. **Per-project session persistence** — `cm-project-sessions.el` (loaded after
    the project-TAGS block): `C-x p p` saves the current project's easysession
    session, tears the workspace down, and restores (or creates) the target's —
    files, window/split layout, per-file point (via `saveplace`), and unsaved
    scratch buffers. Two scratch tiers (per-project + global stash). See below.
```

Then add a top-level section (after the "Project TAGS auto-loading" section):

```markdown
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
```

- [ ] **Step 2: Add to `README.md`**

Add a section after "Project TAGS":

```markdown
## Project sessions

Per-project workspace persistence layered over [`easysession`](https://github.com/jamescherti/easysession.el):
`C-x p p` saves the current project's session, tears the workspace down, and
restores (or creates) the target project's — open files, window/split layout,
per-file cursor position, and unsaved scratch buffers — without starting a second
Emacs. Launching Emacs inside a project restores that project's session
automatically.

Scratch buffers come in two tiers:

| Key | Action |
|-----|--------|
| `C-c n` | New per-project scratch buffer (`*scratch:<proj>:N*`), instant |
| `C-u C-c n` | New/visit a global stash buffer (`*stash:<name>*`), always present |

Implemented in `cm-project-sessions.el`; ERT tests under `tests/`. Design + plan
in `docs/plans/2026-06-28-project-sessions-{design,plan}.md`.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs(sessions): document per-project session persistence

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **`easysession-save-interval` variable name** — if `cm/project-sessions-setup`'s
  `(setq easysession-save-interval …)` raises a void-variable error at runtime,
  check the installed easysession for the exact custom name (`M-x customize-group
  RET easysession`) and adjust; the rest of the design is unaffected.
- **Integration test SKIPs** until Task 7 installs easysession (straight bootstraps
  on the first real `emacs` launch). Running `./tests/run-tests.sh` before then is
  expected to SKIP `cm/session-integration--scratch-handler-round-trip`, not fail.
- **Do not byte-compile** these siblings; they load as source (see Global Constraints).
- **Manual end-to-end check** (after Task 7), worth doing once interactively: open
  Emacs in project A, split some windows, `C-c n` a scratch buffer with text,
  `C-x p p` to project B, then `C-x p p` back to A — files, layout, and the scratch
  buffer should all return.
