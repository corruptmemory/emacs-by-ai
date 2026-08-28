# Emacs↔Agents Bridge — Phase 1 (Instance Registry) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire `~/.emacs-last-used` guessing by having each ephemeral Emacs register `{project-root, server-name}` on startup, so `scripts/emacs-send` (and an agent) resolves *the Emacs for the current project* automatically.

**Architecture:** A new sibling library `cm-ai-registry.el` writes one JSON descriptor per live Emacs into `~/.emacs-ai/instances/`, keyed by the unique PID server-name with `project_root` inside. `init.el` calls it right after `server-start`. `scripts/emacs-send` gains project-based resolution (ancestor-match → most-specific → newest → live) that runs before the existing last-used/rofi fallback.

**Tech Stack:** Emacs Lisp (built-in `json`, `cl-lib`, `server`, `project`), Bash (`scripts/emacs-send`, optional `jq`), ERT.

**Spec:** `docs/plans/2026-08-28-emacs-agents-bridge-design.md` (Section A). Executors should read that Section A alongside this plan.

## Global Constraints

- Emacs **31.1**; `lexical-binding: t` cookie required on every new `.el` (Emacs 31 warns without it).
- `cm/` prefix for all custom functions/vars (`cm` = corruptmemory).
- Descriptor location: `~/.emacs-ai/instances/`, one file `emacs-<PID>.json` per instance.
- Descriptor JSON fields (exact names): `project_root` (slash-terminated absolute), `server_name`, `pid`, `socket`, `frame_title`, `started` (ISO-8601).
- Server-name format is already `emacs-<PID>` (`init.el:213`); do not change it.
- `emacs-send` must degrade gracefully: no `jq` → skip project resolution, fall back to the existing last-used/rofi logic. Never regress the current behavior.
- Per-task test command (fast, focused):
  `emacs -batch -Q -L . -l ert -l tests/cm-ai-registry-tests.el -f ert-run-tests-batch-and-exit`
  Full suite: `./tests/run-tests.sh`.

## File Structure

- **Create** `cm-ai-registry.el` (repo root) — descriptor build/write/read, sweep, register/deregister, resolve. One responsibility: instance discovery.
- **Create** `tests/cm-ai-registry-tests.el` — ERT suite (pure functions, temp dirs, injectable liveness).
- **Modify** `init.el:190-222` (the `server` `use-package` block) — load the library and call `cm/ai-registry-register` after `server-start`.
- **Modify** `scripts/emacs-send` — add `--server`/`--project`/`--list`/`--dry-run`, a `resolve_by_project` function, and slot project-resolution ahead of the last-used branch.
- **Modify** `CLAUDE.md` — document the registry + `emacs-send` resolution under the AI-assistant section.

---

### Task 1: Library scaffold — descriptor build + write/read round-trip

**Files:**
- Create: `cm-ai-registry.el`
- Test: `tests/cm-ai-registry-tests.el`

**Interfaces:**
- Produces: `cm/ai-registry-dir` (defcustom, directory), `cm/ai-registry--project-root () -> string`, `cm/ai-registry-descriptor () -> alist`, `cm/ai-registry--write (descriptor dir) -> path`, `cm/ai-registry--read (file) -> plist|nil`, `cm/ai-registry--files () -> list<path>`.

- [ ] **Step 1: Write the failing test**

Create `tests/cm-ai-registry-tests.el`:

```elisp
;;; cm-ai-registry-tests.el --- Tests for cm-ai-registry  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-ai-registry)

(ert-deftest cm/ai-registry-descriptor-has-core-fields ()
  (let* ((server-name "emacs-4242")
         (default-directory temporary-file-directory)
         (d (cm/ai-registry-descriptor)))
    (should (equal (alist-get 'server_name d) "emacs-4242"))
    (should (equal (alist-get 'pid d) (emacs-pid)))
    (should (stringp (alist-get 'project_root d)))
    (should (string-suffix-p "/" (alist-get 'project_root d)))))

(ert-deftest cm/ai-registry-write-read-roundtrip ()
  (let* ((dir (file-name-as-directory (make-temp-file "cmair" t)))
         (desc '((project_root . "/home/jim/projects/emacs-again/")
                 (server_name . "emacs-4242") (pid . 4242)
                 (socket . "/run/user/1000/emacs/emacs-4242")
                 (frame_title . "x") (started . "2026-08-28T20:00:00+0000")))
         (file (cm/ai-registry--write desc dir))
         (got (cm/ai-registry--read file)))
    (should (equal file (expand-file-name "emacs-4242.json" dir)))
    (should (equal (plist-get got :project_root) "/home/jim/projects/emacs-again/"))
    (should (equal (plist-get got :pid) 4242))
    (should (member file (cm/ai-registry--files*)))))

(provide 'cm-ai-registry-tests)
;;; cm-ai-registry-tests.el ends here
```

Note: the round-trip test lists files via a dir-parameterized helper `cm/ai-registry--files*` so it need not touch the real `cm/ai-registry-dir`.

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-registry-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: cm-ai-registry`.

- [ ] **Step 3: Write minimal implementation**

Create `cm-ai-registry.el`:

```elisp
;;; cm-ai-registry.el --- Per-instance Emacs registry for agent discovery  -*- lexical-binding: t; -*-
;;; Commentary:
;; Each ephemeral Emacs writes a small JSON descriptor recording its project
;; root and emacsclient server-name into `cm/ai-registry-dir', so an external
;; agent (or scripts/emacs-send) can resolve "the Emacs for project X" instead
;; of guessing the last-used one.
;; See docs/plans/2026-08-28-emacs-agents-bridge-design.md (Section A).
;;; Code:

(require 'json)
(require 'cl-lib)

(defgroup cm/ai-registry nil "Per-instance Emacs registry." :group 'tools)

(defcustom cm/ai-registry-dir (expand-file-name "instances/" "~/.emacs-ai/")
  "Directory holding one descriptor file per live Emacs instance."
  :type 'directory)

(defun cm/ai-registry--project-root ()
  "Best-effort project root of the launch directory, slash-terminated absolute."
  (file-name-as-directory
   (expand-file-name
    (or (and (fboundp 'project-current)
             (when-let* ((proj (project-current nil default-directory)))
               (project-root proj)))
        default-directory))))

(defun cm/ai-registry-descriptor ()
  "Build the descriptor alist for this Emacs instance."
  (list (cons 'project_root (cm/ai-registry--project-root))
        (cons 'server_name  (and (boundp 'server-name) server-name))
        (cons 'pid          (emacs-pid))
        (cons 'socket       (ignore-errors
                              (expand-file-name
                               (or (bound-and-true-p server-name) "")
                               (or (bound-and-true-p server-socket-dir)
                                   (format "/run/user/%d/emacs" (user-uid))))))
        (cons 'frame_title  (or (ignore-errors
                                  (format-mode-line frame-title-format)) ""))
        (cons 'started      (format-time-string "%FT%T%z"))))

(defun cm/ai-registry--write (descriptor dir)
  "Write DESCRIPTOR (alist) into DIR atomically; return the file path."
  (make-directory dir t)
  (let* ((server (alist-get 'server_name descriptor))
         (target (expand-file-name (format "%s.json" server) dir))
         (tmp    (make-temp-file (expand-file-name ".tmp-" dir))))
    (with-temp-file tmp (insert (json-encode descriptor)))
    (rename-file tmp target t)
    target))

(defun cm/ai-registry--read (file)
  "Read descriptor FILE into a keyword plist, or nil on error."
  (ignore-errors
    (let ((json-object-type 'plist)
          (json-key-type 'keyword)
          (json-array-type 'list))
      (json-read-from-string
       (with-temp-buffer (insert-file-contents file) (buffer-string))))))

(defun cm/ai-registry--files* (dir)
  "List descriptor files in DIR."
  (when (file-directory-p dir)
    (directory-files dir t "\\.json\\'")))

(defun cm/ai-registry--files ()
  "List descriptor files in `cm/ai-registry-dir'."
  (cm/ai-registry--files* cm/ai-registry-dir))

(provide 'cm-ai-registry)
;;; cm-ai-registry.el ends here
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-registry-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add cm-ai-registry.el tests/cm-ai-registry-tests.el
git commit -m "cm-ai-registry: descriptor build + atomic write/read round-trip"
```

---

### Task 2: Sweep dead instances + register/deregister

**Files:**
- Modify: `cm-ai-registry.el`
- Test: `tests/cm-ai-registry-tests.el`

**Interfaces:**
- Consumes: everything from Task 1.
- Produces: `cm/ai-registry--pid-live-p (pid) -> bool`, `cm/ai-registry--sweep (dir &optional live-pred)`, `cm/ai-registry--file (&optional server) -> path`, `cm/ai-registry-register ()`, `cm/ai-registry-deregister ()`.

- [ ] **Step 1: Write the failing test**

Append to `tests/cm-ai-registry-tests.el` (before the `provide`):

```elisp
(ert-deftest cm/ai-registry-sweep-drops-dead-keeps-live ()
  (let* ((dir (file-name-as-directory (make-temp-file "cmair" t)))
         (live-pred (lambda (pid) (= pid 1)))) ; only pid 1 is "live"
    (cm/ai-registry--write '((server_name . "emacs-1") (pid . 1)
                             (project_root . "/a/")) dir)
    (cm/ai-registry--write '((server_name . "emacs-2") (pid . 2)
                             (project_root . "/b/")) dir)
    (cm/ai-registry--sweep dir live-pred)
    (should (file-exists-p (expand-file-name "emacs-1.json" dir)))
    (should-not (file-exists-p (expand-file-name "emacs-2.json" dir)))))

(ert-deftest cm/ai-registry-register-and-deregister ()
  (let* ((dir (file-name-as-directory (make-temp-file "cmair" t)))
         (cm/ai-registry-dir dir)
         (server-name (format "emacs-%d" (emacs-pid)))
         (default-directory temporary-file-directory)
         (kill-emacs-hook nil))
    (cm/ai-registry-register)
    (should (file-exists-p (cm/ai-registry--file)))
    (should (memq #'cm/ai-registry-deregister kill-emacs-hook))
    (cm/ai-registry-deregister)
    (should-not (file-exists-p (cm/ai-registry--file)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-registry-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `void-function cm/ai-registry--sweep`.

- [ ] **Step 3: Write minimal implementation**

Insert into `cm-ai-registry.el` before the `provide`:

```elisp
(defun cm/ai-registry--pid-live-p (pid)
  "Return non-nil if PID is a running process (Linux /proc)."
  (and (integerp pid) (> pid 0)
       (file-exists-p (format "/proc/%d" pid))))

(defun cm/ai-registry--sweep (dir &optional live-pred)
  "Delete descriptors in DIR whose PID is not live (LIVE-PRED, default /proc)."
  (let ((live (or live-pred #'cm/ai-registry--pid-live-p)))
    (dolist (f (cm/ai-registry--files* dir))
      (let ((d (cm/ai-registry--read f)))
        (when (and d (not (funcall live (plist-get d :pid))))
          (ignore-errors (delete-file f)))))))

(defun cm/ai-registry--file (&optional server)
  "Descriptor path for SERVER (default this instance's `server-name')."
  (expand-file-name (format "%s.json" (or server server-name))
                    cm/ai-registry-dir))

(defun cm/ai-registry-register ()
  "Write this instance's descriptor, sweep dead ones, install exit cleanup."
  (when (and (boundp 'server-name) server-name)
    (cm/ai-registry--sweep cm/ai-registry-dir)
    (cm/ai-registry--write (cm/ai-registry-descriptor) cm/ai-registry-dir)
    (add-hook 'kill-emacs-hook #'cm/ai-registry-deregister)))

(defun cm/ai-registry-deregister ()
  "Remove this instance's descriptor file."
  (when (and (boundp 'server-name) server-name)
    (let ((f (cm/ai-registry--file)))
      (when (file-exists-p f) (ignore-errors (delete-file f))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-registry-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add cm-ai-registry.el tests/cm-ai-registry-tests.el
git commit -m "cm-ai-registry: sweep dead instances + register/deregister"
```

---

### Task 3: Resolve — ancestor match, most-specific, newest, live

**Files:**
- Modify: `cm-ai-registry.el`
- Test: `tests/cm-ai-registry-tests.el`

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces: `cm/ai-registry-resolve (cwd &optional live-pred) -> server-name|nil`. This is the canonical algorithm mirrored by `scripts/emacs-send` in Task 5.

- [ ] **Step 1: Write the failing test**

Append to `tests/cm-ai-registry-tests.el` (before `provide`):

```elisp
(ert-deftest cm/ai-registry-resolve-most-specific-then-newest ()
  (let* ((dir (file-name-as-directory (make-temp-file "cmair" t)))
         (cm/ai-registry-dir dir)
         (all-live (lambda (_pid) t)))
    ;; broad root, older
    (cm/ai-registry--write '((server_name . "emacs-10") (pid . 10)
                             (project_root . "/home/jim/projects/")
                             (started . "2026-08-28T10:00:00+0000")) dir)
    ;; specific root, older
    (cm/ai-registry--write '((server_name . "emacs-11") (pid . 11)
                             (project_root . "/home/jim/projects/app/")
                             (started . "2026-08-28T10:00:00+0000")) dir)
    ;; specific root, newer -> should win on tie of specificity
    (cm/ai-registry--write '((server_name . "emacs-12") (pid . 12)
                             (project_root . "/home/jim/projects/app/")
                             (started . "2026-08-28T20:00:00+0000")) dir)
    (should (equal (cm/ai-registry-resolve "/home/jim/projects/app/sub/deep" all-live)
                   "emacs-12"))
    ;; a cwd only the broad root covers
    (should (equal (cm/ai-registry-resolve "/home/jim/projects/other/x" all-live)
                   "emacs-10"))))

(ert-deftest cm/ai-registry-resolve-filters-dead-and-nonmatching ()
  (let* ((dir (file-name-as-directory (make-temp-file "cmair" t)))
         (cm/ai-registry-dir dir)
         (only-13-live (lambda (pid) (= pid 13))))
    (cm/ai-registry--write '((server_name . "emacs-13") (pid . 13)
                             (project_root . "/home/jim/projects/app/")
                             (started . "2026-08-28T10:00:00+0000")) dir)
    (cm/ai-registry--write '((server_name . "emacs-14") (pid . 14)
                             (project_root . "/home/jim/projects/app/")
                             (started . "2026-08-28T20:00:00+0000")) dir)
    ;; newer 14 is dead -> live 13 wins despite older
    (should (equal (cm/ai-registry-resolve "/home/jim/projects/app/x" only-13-live)
                   "emacs-13"))
    ;; cwd outside every project_root -> nil
    (should-not (cm/ai-registry-resolve "/tmp/unrelated" only-13-live))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-registry-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `void-function cm/ai-registry-resolve`.

- [ ] **Step 3: Write minimal implementation**

Insert into `cm-ai-registry.el` before the `provide`:

```elisp
(defun cm/ai-registry-resolve (cwd &optional live-pred)
  "Return the server-name whose project best matches CWD, or nil.
Match = CWD is within `project_root'; rank by most-specific root, then
newest `started'.  LIVE-PRED (default /proc) filters dead instances."
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (live (or live-pred #'cm/ai-registry--pid-live-p))
         (cands (cl-loop for f in (cm/ai-registry--files)
                         for d = (cm/ai-registry--read f)
                         when (and d
                                   (stringp (plist-get d :project_root))
                                   (string-prefix-p (plist-get d :project_root) cwd)
                                   (funcall live (plist-get d :pid)))
                         collect d)))
    (when cands
      (plist-get
       (car (sort cands
                  (lambda (a b)
                    (let ((la (length (plist-get a :project_root)))
                          (lb (length (plist-get b :project_root))))
                      (if (= la lb)
                          (string> (or (plist-get a :started) "")
                                   (or (plist-get b :started) ""))
                        (> la lb))))))
       :server_name))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-registry-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (6 tests). Also run the full suite `./tests/run-tests.sh` — expect no regressions.

- [ ] **Step 5: Commit**

```bash
git add cm-ai-registry.el tests/cm-ai-registry-tests.el
git commit -m "cm-ai-registry: resolve by ancestor-match, most-specific, newest, live"
```

---

### Task 4: Wire registration into init.el

**Files:**
- Modify: `init.el` (the `server` `use-package` block, currently lines 190-222)

**Interfaces:**
- Consumes: `cm/ai-registry-register` (Task 2).
- Produces: on every Emacs launch, `~/.emacs-ai/instances/emacs-<PID>.json` exists while the instance lives and is removed on exit.

- [ ] **Step 1: Add the load+register call**

In `init.el`, inside the `server` `use-package :config`, immediately after the `(unless (server-running-p) (server-start))` form (currently line 214-215) and before the `cm/last-used-file` defvar (line 216), insert:

```elisp
  ;; Register this instance (project-root -> server-name) so agents and
  ;; scripts/emacs-send resolve the right Emacs by project instead of guessing
  ;; last-used.  See cm-ai-registry.el and
  ;; docs/plans/2026-08-28-emacs-agents-bridge-design.md (Section A).
  (when (load (locate-user-emacs-file "cm-ai-registry") t)
    (cm/ai-registry-register))
```

- [ ] **Step 2: Verify it loads clean (batch)**

Run: `emacs -batch -Q -L . --eval '(check-parens)' init.el 2>&1 || true` then load-check the library:
Run: `emacs -batch -Q -L . -l cm-ai-registry --eval '(princ (if (fboundp (quote cm/ai-registry-register)) "ok" "missing"))'`
Expected: prints `ok`.

- [ ] **Step 3: Manual acceptance (real Emacs)**

Launch a real Emacs in a project dir and confirm the descriptor appears, then that it is removed on exit:

```bash
cd ~/projects/emacs-again
emacs --init-directory=~/.config/emacs/ & sleep 4
ls ~/.emacs-ai/instances/                       # expect emacs-<PID>.json
cat ~/.emacs-ai/instances/emacs-*.json          # project_root == this repo, slash-terminated
```
Then quit that Emacs (`C-x C-c`) and confirm its descriptor is gone:
```bash
ls ~/.emacs-ai/instances/                        # its file removed
```

- [ ] **Step 4: Commit**

```bash
git add init.el
git commit -m "init: register each Emacs instance for project-based agent resolution"
```

---

### Task 5: Project-based resolution in scripts/emacs-send

**Files:**
- Modify: `scripts/emacs-send`

**Interfaces:**
- Consumes: descriptor files written by `cm/ai-registry-register` (`~/.emacs-ai/instances/*.json`).
- Produces: `emacs-send` resolves target by `$PWD`'s project before falling back to last-used; new flags `--server NAME`, `--project DIR`, `--list`, `--dry-run`. Mirrors `cm/ai-registry-resolve`.

- [ ] **Step 1: Add the registry constant and resolver**

After the existing `LAST_USED_FILE="$HOME/.emacs-last-used"` line (currently line 24), add:

```bash
REGISTRY_DIR="$HOME/.emacs-ai/instances"
```

Add this function alongside the other helpers (e.g. after `live_servers()`):

```bash
# Resolve target server-name by matching a directory against registered
# project roots: ancestor match, most-specific root, then newest.  Mirrors
# cm/ai-registry-resolve.  Requires jq; prints nothing if unavailable/no match.
resolve_by_project() {
    local base="${1:-$PWD}"
    command -v jq >/dev/null 2>&1 || return 0
    [[ -d "$REGISTRY_DIR" ]] || return 0
    base="${base%/}/"
    local best_name="" best_len=-1 best_started=""
    for f in "$REGISTRY_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        local root name pid started len
        root=$(jq -r '.project_root // empty' "$f" 2>/dev/null) || continue
        name=$(jq -r '.server_name // empty' "$f" 2>/dev/null)
        pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
        started=$(jq -r '.started // empty' "$f" 2>/dev/null)
        [[ -n "$root" && -n "$name" && -n "$pid" ]] || continue
        kill -0 "$pid" 2>/dev/null || continue          # live only
        [[ "$base" == "$root"* ]] || continue           # ancestor match
        len=${#root}
        if (( len > best_len )) || { (( len == best_len )) && [[ "$started" > "$best_started" ]]; }; then
            best_name="$name"; best_len="$len"; best_started="$started"
        fi
    done
    [[ -n "$best_name" ]] && printf '%s\n' "$best_name"
}

# Print live registered instances (project_root, server, buffer).
list_instances() {
    command -v jq >/dev/null 2>&1 || die "--list requires jq"
    [[ -d "$REGISTRY_DIR" ]] || { echo "(no instances registered)"; return; }
    for f in "$REGISTRY_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        local root name pid
        root=$(jq -r '.project_root // "?"' "$f" 2>/dev/null)
        name=$(jq -r '.server_name // "?"' "$f" 2>/dev/null)
        pid=$(jq -r '.pid // 0' "$f" 2>/dev/null)
        kill -0 "$pid" 2>/dev/null || continue
        printf '%-28s %-14s %s\n' "$name" "(PID $pid)" "$root"
    done
}
```

- [ ] **Step 2: Add the new flags and the resolution branch**

In the argument-parsing block (currently lines 160-173), add the init vars beside the existing ones and the new cases:

```bash
SERVER_OVERRIDE=""
PROJECT_OVERRIDE=""
LIST_MODE=false
DRY_RUN=false
```

```bash
        --server)  SERVER_OVERRIDE="$2"; shift 2 ;;
        --project) PROJECT_OVERRIDE="$2"; shift 2 ;;
        --list)    LIST_MODE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
```

Right after the parse loop (before the `if ! $EVAL_MODE && ...` guard at line 175), handle `--list`:

```bash
if $LIST_MODE; then
    list_instances
    exit 0
fi
```

Then replace the resolution block (currently lines 189-212, the `elif $USE_ROFI` … `else … rofi` chain) so project resolution runs first:

```bash
elif [[ -n "$SERVER_OVERRIDE" ]]; then
    target=""
    for srv in "${servers[@]}"; do
        [[ "$srv" == "$SERVER_OVERRIDE" ]] && target="$srv"
    done
    [[ -n "$target" ]] || die "--server '$SERVER_OVERRIDE' is not a live instance"
elif $USE_ROFI; then
    command -v rofi >/dev/null 2>&1 || die "rofi is not installed"
    target=$(rofi_pick "${servers[@]}")
else
    # Project-based resolution first (mirrors cm/ai-registry-resolve).
    target=$(resolve_by_project "${PROJECT_OVERRIDE:-$PWD}")
    if [[ -z "$target" ]]; then
        if [[ ${#servers[@]} -eq 1 ]]; then
            target="${servers[0]}"
        elif [[ -f "$LAST_USED_FILE" ]]; then
            candidate=$(cat "$LAST_USED_FILE")
            target=""
            for srv in "${servers[@]}"; do
                [[ "$srv" == "$candidate" ]] && target="$srv"
            done
            if [[ -z "$target" ]]; then
                command -v rofi >/dev/null 2>&1 || die "multiple instances and last-used is stale; install rofi or use -m/--server"
                target=$(rofi_pick "${servers[@]}")
            fi
        else
            command -v rofi >/dev/null 2>&1 || die "multiple instances running; install rofi or use -m/--server"
            target=$(rofi_pick "${servers[@]}")
        fi
    fi
fi
```

Add a dry-run short-circuit just after `[[ -n "$target" ]] || die "no target selected"` (line 214):

```bash
if $DRY_RUN; then echo "$target"; exit 0; fi
```

Update the usage heredoc to mention `--server`, `--project`, `--list`, `--dry-run` and that resolution is now project-first.

- [ ] **Step 3: Verify — resolution picks the project match (no live Emacs needed)**

This scenario fakes two descriptors owned by the current shell's PID (which is live), then checks `--dry-run` resolution and `--list`:

```bash
# Make the shell's own live sockets so live_servers() sees the fake names too.
SOCKDIR="$(ls -d /run/user/$(id -u)/emacs 2>/dev/null || echo /tmp/emacs$(id -u))"
mkdir -p "$SOCKDIR" ~/.emacs-ai/instances
MYPID=$$
# Two instances: broad + specific, both "live" (this shell).
printf '{"project_root":"/tmp/proj/","server_name":"emacs-%s","pid":%s,"started":"2026-08-28T10:00:00+0000"}\n' "$MYPID" "$MYPID" > ~/.emacs-ai/instances/emacs-$MYPID.json
: > "$SOCKDIR/emacs-$MYPID"    # a socket-named file so live_servers lists it
mkdir -p /tmp/proj/sub
( cd /tmp/proj/sub && ~/projects/emacs-again/scripts/emacs-send --dry-run -e '(ignore)' )
# Expected: prints  emacs-<MYPID>
~/projects/emacs-again/scripts/emacs-send --list
# Expected: a row: emacs-<MYPID>  (PID <MYPID>)  /tmp/proj/
# Cleanup:
rm -f ~/.emacs-ai/instances/emacs-$MYPID.json "$SOCKDIR/emacs-$MYPID"
```

Expected: `--dry-run` prints `emacs-<MYPID>`; `--list` shows the instance. (`emacs-send` still needs no running server because `--dry-run` exits before contacting one.)

- [ ] **Step 4: Verify — no regression when registry is empty**

```bash
# With no descriptors, behavior falls back to the old logic unchanged.
ls ~/.emacs-ai/instances/*.json 2>/dev/null && echo "clean these first" || true
~/projects/emacs-again/scripts/emacs-send --help | grep -q -- '--server' && echo "usage updated"
```
Expected: prints `usage updated`; with an empty registry, resolution falls through to the single-instance / last-used / rofi path (manually confirm against a real running Emacs if desired).

- [ ] **Step 5: Commit**

```bash
git add scripts/emacs-send
git commit -m "emacs-send: resolve target by project registry (--server/--project/--list/--dry-run)"
```

---

### Task 6: Document the registry in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (AI Writing Assistant section, near the `emacs-send` / remote-query notes)

**Interfaces:**
- Consumes: everything above. No code.

- [ ] **Step 1: Add a subsection**

Under the "AI Writing Assistant" section of `CLAUDE.md`, add:

```markdown
### Instance registry — resolving "which Emacs"

Each ephemeral Emacs registers `{project_root, server_name, pid, socket,
started}` in `~/.emacs-ai/instances/emacs-<PID>.json` on startup
(`cm-ai-registry.el`, called from the `server` block after `server-start`;
removed on `kill-emacs`). This retires `~/.emacs-last-used` guessing:

- `emacs-send -e '(expr)'` now resolves the target by the **current project**
  — the live instance whose `project_root` is an ancestor of `$PWD`
  (most-specific root, then newest). So a command run anywhere under a repo
  reaches *that* repo's Emacs with no flags.
- Escape hatches: `--server <name>` (force one), `--project <dir>` (resolve as
  if `$PWD` were `<dir>`), `--list` (show live instances), `--dry-run` (print
  the resolved server-name and exit). Fallback order when no project match:
  single instance → `~/.emacs-last-used` → rofi.
- The canonical resolver is `cm/ai-registry-resolve` (elisp, ERT-tested);
  `scripts/emacs-send` mirrors it in bash (needs `jq`; degrades to the old
  behavior without it).

Design + plan: `docs/plans/2026-08-28-emacs-agents-bridge-{design,phase1-plan}.md`.
```

- [ ] **Step 2: Verify**

Run: `grep -n "Instance registry" CLAUDE.md`
Expected: the new heading is present.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the per-instance registry + emacs-send project resolution"
```

---

## Self-Review

**Spec coverage (Section A of the design):**
- One descriptor per instance keyed by server-name, `project_root` inside → Task 1 (`descriptor`, `--write`).
- Atomic temp+rename write → Task 1 (`cm/ai-registry--write`).
- Register after `server-start`; deregister on `kill-emacs-hook`; dead-PID sweep → Tasks 2, 4.
- Resolve: ancestor-match → most-specific → newest, live-filtered → Task 3.
- `emacs-send` project resolution + `--project`/`--server`/`--list` + last-used fallback → Task 5.
- Concurrency (one file per instance, atomic writes, readers skip bad files) → Task 1 (`--read` wrapped in `ignore-errors`).
- Docs → Task 6.
All Section-A requirements map to a task. (Phases 2-3 — packages protocol, write path, herdr — are out of scope for this plan by design.)

**Placeholder scan:** none — every step has concrete code or an exact command.

**Type consistency:** `cm/ai-registry--write (descriptor dir)`, `--read (file)`, `--files* (dir)`, `--files ()`, `--sweep (dir &optional live-pred)`, `--file (&optional server)`, `-register ()`, `-deregister ()`, `-resolve (cwd &optional live-pred)` — used consistently across tasks and tests. JSON field names (`project_root`, `server_name`, `pid`, `socket`, `frame_title`, `started`) match between the elisp writer, the elisp reader (keyword plist), and the bash `jq` reader.
