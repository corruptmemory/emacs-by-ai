# Emacs↔Agents Bridge — Phase 2 (Packages Protocol + Write Path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the whole Emacs↔agent channel speak a typed elisp "packages" protocol (reads and errors), and add a review-gated buffer write path so an agent can propose edits (e.g. "add `ctx context.Context` to every method targeting `Cache`") that land via `replace-buffer-contents`.

**Architecture:** A new sibling library `cm-ai-bridge.el` holds package primitives, a buffer-target resolver, the shared exchange helpers (moved out of `init.el`), the 8 remote read functions migrated to return packages, and the write path (`cm/ai-apply-edit` + a DWIM auto/review gate). The interactive `C-c a` commands and the `*ai-suggestions*` buffer stay in `init.el` and `(load)` the new library first.

**Tech Stack:** Emacs Lisp (built-in `json`, `cl-lib`, `subr-x`, `diff`/`diff-mode`, `server`, `project`), external `diff` (universally present), ERT.

**Spec:** `docs/plans/2026-08-28-emacs-agents-bridge-design.md` — Section C (packages protocol) and its C-write subsection (edit/apply path). This plan concretizes the decisions taken in the Phase-2 brainstorm (whole-channel migration, buffer addressing = name-or-path, async `:pending` review contract, DWIM diff via `diff -u`, the `cm-ai-bridge.el` boundary).

## Global Constraints

- Emacs **31.1**; every new `.el` starts with a `-*- lexical-binding: t; -*-` cookie on line 1.
- `cm/` prefix for all functions/vars.
- **Package envelope (exact shape):** `(:v 1 :type TYPE :payload PAYLOAD :meta META-PLIST)`. `TYPE` ∈ `elisp | text | markdown | json | error | ref`. `error` payload is `(:code SYM :message STR …)`. `ref` payload is `(:path STR :bytes N :of text)`.
- **Buffer addressing:** a `TARGET` is a buffer-name string, a file-path string (resolved to its visiting buffer), or nil = the focused window's buffer. Reads default to focused; the write verb requires a real target. Unknown target → `error` package `(:code unknown-target)`.
- **Base-tick concurrency:** every read package's `:meta` carries `:tick (buffer-chars-modified-tick)` for its buffer; `cm/ai-apply-edit` takes that tick back and refuses on mismatch with `(:code stale-buffer)`.
- **Apply is always `replace-buffer-contents`** from the proposed full text (preserves point/markers/undo). The diff is display/decision-only.
- **DWIM thresholds (defcustoms):** `cm/ai-apply-auto-max-hunks` = 1, `cm/ai-apply-auto-max-lines` = 8. Auto iff both satisfied and not read-only and `REVIEW` not `force`; `REVIEW` overrides are `force | skip | auto` (default auto); read-only buffer always reviews.
- **Only the remote/query surface changes shape.** The interactive `C-c a` commands (`cm/ai-share/accept/diff`) and the `*ai-suggestions*` buffer are untouched in behavior; they only move to depend on `cm-ai-bridge.el` for the shared helpers.
- Per-task focused test command: `emacs -batch -Q -L . -l ert -l tests/cm-ai-bridge-tests.el -f ert-run-tests-batch-and-exit`. Full suite: `./tests/run-tests.sh`. Test output must be pristine (byte-compile clean too).

## File Structure

- **Create** `cm-ai-bridge.el` — the non-interactive core: package primitives, buffer resolver, moved exchange helpers + `cm/ai-exchange-dir`, the 8 migrated reads, the write path. `(provide 'cm-ai-bridge)`.
- **Create** `tests/cm-ai-bridge-tests.el` — ERT suite.
- **Modify** `init.el` — remove the moved defs (`cm/ai-exchange-dir`, `cm/ai--ensure-dir`, `cm/ai--org-heading-path`, `cm/ai--server-name`, and the 8 remote functions at ~2172-2333); add `(load (locate-user-emacs-file "cm-ai-bridge") t)` at the top of the AI section; update the AI-section cheat-sheet comment.
- **Modify** `CLAUDE.md` — the agent-side packages + write-path contract.

---

### Task 1: Package primitives + buffer resolver

**Files:**
- Create: `cm-ai-bridge.el`
- Test: `tests/cm-ai-bridge-tests.el`

**Interfaces:**
- Produces: `cm/ai-package-version` (defconst 1), `cm/ai-pkg (type payload &rest meta) -> plist`, `cm/ai-with-package` (macro), `cm/ai--resolve-buffer (target) -> buffer|nil`.

- [ ] **Step 1: Write the failing test**

Create `tests/cm-ai-bridge-tests.el`:

```elisp
;;; cm-ai-bridge-tests.el --- Tests for cm-ai-bridge  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-ai-bridge)

(ert-deftest cm/ai-pkg-shape ()
  (let ((p (cm/ai-pkg 'text "hi" :tick 7)))
    (should (equal (plist-get p :v) 1))
    (should (eq (plist-get p :type) 'text))
    (should (equal (plist-get p :payload) "hi"))
    (should (equal (plist-get p :meta) '(:tick 7)))))

(ert-deftest cm/ai-with-package-catches-signal ()
  (let ((p (cm/ai-with-package (error "boom"))))
    (should (eq (plist-get p :type) 'error))
    (should (eq (plist-get (plist-get p :payload) :code) 'error))
    (should (string-match-p "boom" (plist-get (plist-get p :payload) :message)))))

(ert-deftest cm/ai-with-package-passes-value ()
  (let ((p (cm/ai-with-package (cm/ai-pkg 'elisp '(:ok t)))))
    (should (eq (plist-get p :type) 'elisp))
    (should (equal (plist-get p :payload) '(:ok t)))))

(ert-deftest cm/ai-resolve-buffer-by-name-path-and-nil ()
  (let* ((buf (generate-new-buffer "cm-ai-t-buf")))
    (unwind-protect
        (progn
          (should (eq (cm/ai--resolve-buffer "cm-ai-t-buf") buf))
          (should (null (cm/ai--resolve-buffer "no-such-buffer-xyz")))
          (with-current-buffer buf
            ;; nil target = current/focused; in batch, selected-window's buffer
            (should (bufferp (cm/ai--resolve-buffer nil)))))
      (kill-buffer buf))))

(provide 'cm-ai-bridge-tests)
;;; cm-ai-bridge-tests.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-bridge-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: cm-ai-bridge`.

- [ ] **Step 3: Write minimal implementation**

Create `cm-ai-bridge.el`:

```elisp
;;; cm-ai-bridge.el --- Typed packages + write path for the Emacs<->agent bridge  -*- lexical-binding: t; -*-
;;; Commentary:
;; The non-interactive core of the AI writing-assistant bridge: a typed elisp
;; "packages" reply protocol, the shared file-exchange helpers, the remote read
;; functions (returning packages), and a review-gated buffer write path.
;; The interactive C-c a commands and the *ai-suggestions* buffer live in init.el
;; and load this file first.
;; See docs/plans/2026-08-28-emacs-agents-bridge-design.md (Section C / C-write).
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

(defconst cm/ai-package-version 1
  "Envelope version for `cm/ai-pkg' responses.")

(defun cm/ai-pkg (type payload &rest meta)
  "Build a self-describing response package.
TYPE is a symbol (elisp/text/markdown/json/error/ref); PAYLOAD is the value;
META is a plist of extra fields (e.g. :tick)."
  (list :v cm/ai-package-version :type type :payload payload :meta meta))

(defmacro cm/ai-with-package (&rest body)
  "Evaluate BODY (which should yield a package) and return it.
Any signal is converted to an `error' package instead of propagating."
  (declare (indent 0) (debug t))
  `(condition-case err
       (progn ,@body)
     (error (cm/ai-pkg 'error (list :code (car err)
                                    :message (error-message-string err))))))

(defun cm/ai--resolve-buffer (target)
  "Resolve TARGET to a live buffer, or nil.
TARGET is a buffer name, a file path (its visiting buffer), or nil for the
focused window's buffer."
  (cond
   ((null target) (window-buffer (selected-window)))
   ((get-buffer target))
   ((and (stringp target) (find-buffer-visiting target)))
   (t nil)))

(provide 'cm-ai-bridge)
;;; cm-ai-bridge.el ends here
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-bridge-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add cm-ai-bridge.el tests/cm-ai-bridge-tests.el
git commit -m "cm-ai-bridge: package primitives (cm/ai-pkg, with-package) + buffer resolver"
```

---

### Task 2: Move shared exchange helpers out of init.el

**Files:**
- Modify: `cm-ai-bridge.el`
- Modify: `init.el` (remove `cm/ai-exchange-dir`, `cm/ai--ensure-dir`, `cm/ai--org-heading-path`, `cm/ai--server-name` at lines ~2172-2195; add the load form)
- Test: `tests/cm-ai-bridge-tests.el`

**Interfaces:**
- Consumes: Task 1.
- Produces (now in cm-ai-bridge.el): `cm/ai-exchange-dir`, `cm/ai--ensure-dir`, `cm/ai--org-heading-path`, `cm/ai--server-name`, and a new `cm/ai--pkg-ref (content &rest meta) -> ref package`.

- [ ] **Step 1: Write the failing test**

Append to `tests/cm-ai-bridge-tests.el` (before `provide`):

```elisp
(ert-deftest cm/ai-pkg-ref-writes-file ()
  (let* ((cm/ai-exchange-dir (file-name-as-directory (make-temp-file "cmaix" t)))
         (p (cm/ai--pkg-ref "hello world" :buffer "x")))
    (should (eq (plist-get p :type) 'ref))
    (let ((pl (plist-get p :payload)))
      (should (eq (plist-get pl :of) 'text))
      (should (= (plist-get pl :bytes) (string-bytes "hello world")))
      (should (file-exists-p (plist-get pl :path)))
      (should (equal (with-temp-buffer (insert-file-contents (plist-get pl :path))
                       (buffer-string))
                     "hello world")))
    (should (equal (plist-get p :meta) '(:buffer "x")))))

(ert-deftest cm/ai-server-name-helper ()
  (let ((server-name "emacs-777"))
    (should (equal (cm/ai--server-name) "emacs-777"))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-bridge-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `void-function cm/ai--pkg-ref`.

- [ ] **Step 3: Move the helpers and add the ref helper**

Insert into `cm-ai-bridge.el` (after the requires, before `cm/ai-pkg`) the four items moved verbatim from `init.el:2172-2195`:

```elisp
(defvar cm/ai-exchange-dir (expand-file-name "~/.emacs-ai/")
  "Directory for AI <-> Emacs file exchange.")

(defun cm/ai--ensure-dir ()
  "Create exchange directory if needed."
  (make-directory cm/ai-exchange-dir t))

(defun cm/ai--org-heading-path ()
  "Return breadcrumb list of org headings from root to point."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (let (path)
        (condition-case nil
            (while t
              (org-back-to-heading t)
              (push (substring-no-properties (org-get-heading t t t t)) path)
              (unless (org-up-heading-safe)
                (signal 'error nil)))
          (error nil))
        path))))

(defun cm/ai--server-name ()
  "Return the current Emacs server name, or nil."
  (and (boundp 'server-name) server-name))
```

Add `(require 'server)` to the requires block (for the `server-name` special var, matching cm-ai-registry.el's idiom), and `(declare-function org-back-to-heading "org")` / `(declare-function org-up-heading-safe "org")` / `(declare-function org-get-heading "org")` near the top to keep byte-compile clean.

Add the ref helper (after `cm/ai-pkg`):

```elisp
(defun cm/ai--pkg-ref (content &rest meta)
  "Write CONTENT to the exchange content.txt and return a `ref' package.
META is extra envelope metadata (e.g. :buffer / :tick)."
  (cm/ai--ensure-dir)
  (let ((path (expand-file-name "content.txt" cm/ai-exchange-dir)))
    (with-temp-file path (insert content))
    (apply #'cm/ai-pkg 'ref
           (list :path path :bytes (string-bytes content) :of 'text)
           meta)))
```

In `init.el`: delete the four moved definitions (`cm/ai-exchange-dir`, `cm/ai--ensure-dir`, `cm/ai--org-heading-path`, `cm/ai--server-name`, lines ~2172-2195) and insert, right after the AI-section header comment (line ~2171, before the first remaining def), the load form:

```elisp
;; Non-interactive core (packages protocol, shared helpers, remote reads, write
;; path) lives in cm-ai-bridge.el; the interactive commands below load it first.
(load (locate-user-emacs-file "cm-ai-bridge") t)
```

- [ ] **Step 4: Run tests + verify init.el still balances**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-bridge-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (6 tests).
Run: `emacs -batch -Q -L . --eval '(with-temp-buffer (insert-file-contents "init.el") (emacs-lisp-mode) (check-parens) (message "OK"))'`
Expected: `OK`.
Run: `emacs -batch -Q -L . -f batch-byte-compile cm-ai-bridge.el` — no warnings; delete the `.elc`.

- [ ] **Step 5: Commit**

```bash
git add cm-ai-bridge.el init.el tests/cm-ai-bridge-tests.el
git commit -m "cm-ai-bridge: move shared exchange helpers out of init.el; add ref helper"
```

---

### Task 3: Migrate the 8 remote reads to packages

**Files:**
- Modify: `cm-ai-bridge.el`
- Modify: `init.el` (remove the 8 remote functions at ~2200-2333; update the cheat-sheet comment at ~2154-2164)
- Test: `tests/cm-ai-bridge-tests.el`

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces (packages, in cm-ai-bridge.el; each takes optional `TARGET` and keyword `:as`): `cm/ai-current-context`, `cm/ai-visible-buffers`, `cm/ai-get-content`, `cm/ai-paragraph-at-point`, `cm/ai-line-at-point`, `cm/ai-region-or-paragraph`, `cm/ai-org-subtree-at-point`, `cm/ai-nearby-lines`.

- [ ] **Step 1: Write the failing test**

Append to `tests/cm-ai-bridge-tests.el`:

```elisp
(ert-deftest cm/ai-current-context-package ()
  (with-temp-buffer
    (insert "line one\nline two\n") (goto-char (point-min))
    (rename-buffer "cm-ai-ctx" t)
    (let* ((p (cm/ai-current-context (buffer-name)))
           (pl (plist-get p :payload)))
      (should (eq (plist-get p :type) 'elisp))
      (should (equal (plist-get pl :buffer) "cm-ai-ctx"))
      (should (equal (plist-get pl :line) 1))
      ;; base-tick is exposed in meta for the write path
      (should (integerp (plist-get (plist-get p :meta) :tick))))))

(ert-deftest cm/ai-line-at-point-text-package ()
  (with-temp-buffer
    (insert "alpha\nbeta\n") (goto-char (point-min)) (rename-buffer "cm-ai-line" t)
    (let ((p (cm/ai-line-at-point (buffer-name))))
      (should (eq (plist-get p :type) 'text))
      (should (equal (plist-get p :payload) "alpha")))))

(ert-deftest cm/ai-org-subtree-not-org-is-error ()
  (with-temp-buffer
    (fundamental-mode) (rename-buffer "cm-ai-noorg" t)
    (let ((p (cm/ai-org-subtree-at-point (buffer-name))))
      (should (eq (plist-get p :type) 'error))
      (should (eq (plist-get (plist-get p :payload) :code) 'not-org-mode)))))

(ert-deftest cm/ai-get-content-is-ref ()
  (let ((cm/ai-exchange-dir (file-name-as-directory (make-temp-file "cmaix" t))))
    (with-temp-buffer
      (insert "body text") (rename-buffer "cm-ai-gc" t)
      (let* ((p (cm/ai-get-content (buffer-name)))
             (pl (plist-get p :payload)))
        (should (eq (plist-get p :type) 'ref))
        (should (file-exists-p (plist-get pl :path)))
        (should (equal (plist-get (plist-get p :meta) :buffer) "cm-ai-gc"))))))

(ert-deftest cm/ai-unknown-target-is-error ()
  (let ((p (cm/ai-current-context "no-such-buffer-xyz")))
    (should (eq (plist-get p :type) 'error))
    (should (eq (plist-get (plist-get p :payload) :code) 'unknown-target))))

(ert-deftest cm/ai-json-rendering-on-request ()
  (with-temp-buffer
    (insert "x") (rename-buffer "cm-ai-json" t)
    (let ((p (cm/ai-current-context (buffer-name) :as 'json)))
      (should (eq (plist-get p :type) 'json))
      (should (stringp (plist-get p :payload)))
      (should (string-match-p "cm-ai-json" (plist-get p :payload))))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-bridge-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `void-function cm/ai-current-context`.

- [ ] **Step 3: Add the migrated reads**

Insert into `cm-ai-bridge.el` (before `provide`). Note the shared helpers: a `TARGET`→buffer wrapper that returns an `unknown-target` error package, and an `:as` renderer that converts an elisp payload to a `json` package on request.

```elisp
(defun cm/ai--render (pkg as)
  "If AS is `json', re-render PKG's payload as a `json' package; else PKG."
  (if (eq as 'json)
      (cm/ai-pkg 'json (json-encode (plist-get pkg :payload))
                 (plist-get pkg :meta))  ; NOTE: meta is a plist; splice below
    pkg))

(defmacro cm/ai--on-target (target &rest body)
  "Resolve TARGET to a buffer, run BODY there, or return an unknown-target error."
  (declare (indent 1) (debug t))
  `(let ((buf (cm/ai--resolve-buffer ,target)))
     (if (not buf)
         (cm/ai-pkg 'error (list :code 'unknown-target
                                 :message (format "No live buffer for %S" ,target)))
       (with-current-buffer buf ,@body))))

(defun cm/ai--meta ()
  "Standard :meta plist for the current buffer (carries the base tick)."
  (list :buffer (buffer-name)
        :tick (buffer-chars-modified-tick)
        :server (cm/ai--server-name)))

(cl-defun cm/ai-current-context (&optional target &key as)
  "Return an elisp package describing TARGET's editing context."
  (cm/ai-with-package
    (cm/ai--on-target target
      (let* ((region-p (use-region-p))
             (payload (list :file (or (buffer-file-name) "")
                            :buffer (buffer-name)
                            :mode (symbol-name major-mode)
                            :line (line-number-at-pos)
                            :column (current-column)
                            :org-path (cm/ai--org-heading-path)
                            :modified (buffer-modified-p)
                            :region (when region-p
                                      (list :start-line (line-number-at-pos (region-beginning))
                                            :end-line (line-number-at-pos (region-end))
                                            :chars (- (region-end) (region-beginning)))))))
        (cm/ai--render (apply #'cm/ai-pkg 'elisp payload (cm/ai--meta)) as)))))

(cl-defun cm/ai-visible-buffers (&key as)
  "Return an elisp package of all visible buffers across frames."
  (cm/ai-with-package
    (let (result)
      (walk-windows
       (lambda (win)
         (let ((b (window-buffer win)))
           (push (list :file (or (buffer-file-name b) "")
                       :buffer (buffer-name b)
                       :mode (symbol-name (buffer-local-value 'major-mode b))
                       :selected (eq win (selected-window)))
                 result)))
       nil t)
      (cm/ai--render (cm/ai-pkg 'elisp (nreverse result)) as))))

(cl-defun cm/ai-get-content (&optional target &key as)
  "Snapshot TARGET's content (or active region) to content.txt; return a ref package."
  (ignore as)
  (cm/ai-with-package
    (cm/ai--on-target target
      (let* ((region-p (use-region-p))
             (content (if region-p
                          (buffer-substring-no-properties (region-beginning) (region-end))
                        (buffer-substring-no-properties (point-min) (point-max)))))
        (apply #'cm/ai--pkg-ref content
               (append (cm/ai--meta)
                       (list :scope (if region-p 'region 'buffer)
                             :mode (symbol-name major-mode)
                             :file (or (buffer-file-name) ""))))))))

(cl-defun cm/ai-paragraph-at-point (&optional target &key as)
  "Return a text package with the paragraph at point in TARGET."
  (cm/ai-with-package
    (cm/ai--on-target target
      (save-excursion
        (let ((beg (progn (backward-paragraph) (skip-chars-forward "\n") (point)))
              (end (progn (forward-paragraph) (skip-chars-backward "\n") (point))))
          (cm/ai--render (apply #'cm/ai-pkg 'text
                                (buffer-substring-no-properties beg end)
                                (cm/ai--meta))
                         as))))))

(cl-defun cm/ai-line-at-point (&optional target &key as)
  "Return a text package with the current line in TARGET."
  (cm/ai-with-package
    (cm/ai--on-target target
      (cm/ai--render (apply #'cm/ai-pkg 'text
                            (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))
                            (cm/ai--meta))
                     as))))

(cl-defun cm/ai-region-or-paragraph (&optional target &key as)
  "Return an elisp package: region text if active, else the paragraph at point."
  (cm/ai-with-package
    (cm/ai--on-target target
      (let* ((region-p (use-region-p))
             (text (if region-p
                       (buffer-substring-no-properties (region-beginning) (region-end))
                     (save-excursion
                       (let ((beg (progn (backward-paragraph) (skip-chars-forward "\n") (point)))
                             (end (progn (forward-paragraph) (skip-chars-backward "\n") (point))))
                         (buffer-substring-no-properties beg end))))))
        (cm/ai--render (apply #'cm/ai-pkg 'elisp
                              (list :scope (if region-p 'region 'paragraph)
                                    :text text :chars (length text))
                              (cm/ai--meta))
                       as)))))

(cl-defun cm/ai-org-subtree-at-point (&optional target &key as)
  "Return a text package with the org subtree at point, or a not-org-mode error."
  (cm/ai-with-package
    (cm/ai--on-target target
      (if (not (derived-mode-p 'org-mode))
          (cm/ai-pkg 'error (list :code 'not-org-mode
                                  :message "Target buffer is not in org-mode"))
        (save-excursion
          (org-back-to-heading t)
          (let ((beg (point)))
            (org-end-of-subtree t t)
            (cm/ai--render (apply #'cm/ai-pkg 'text
                                  (buffer-substring-no-properties beg (point))
                                  (cm/ai--meta))
                           as)))))))

(cl-defun cm/ai-nearby-lines (&optional target n &key as)
  "Return a text package: N lines (default 5) around point in TARGET, with a marker."
  (cm/ai-with-package
    (cm/ai--on-target target
      (let* ((n (or n 5))
             (cur (line-number-at-pos))
             (beg (save-excursion (forward-line (- n)) (point)))
             (end (save-excursion (forward-line (1+ n)) (point)))
             (lines (split-string (buffer-substring-no-properties beg end) "\n"))
             (start-line (- cur n))
             (out '()))
        (dotimes (i (length lines))
          (let* ((lnum (+ start-line i))
                 (prefix (if (= lnum cur) "→" " ")))
            (push (format "%s %4d: %s" prefix lnum (nth i lines)) out)))
        (cm/ai--render (apply #'cm/ai-pkg 'text
                              (mapconcat #'identity (nreverse out) "\n")
                              (cm/ai--meta))
                       as)))))

(declare-function org-end-of-subtree "org")
```

**Note on `cm/ai--render` + meta:** `cm/ai-pkg`'s `meta` is `&rest`, so the package's `:meta` is a *plist*. When re-rendering to json, pass the existing meta plist back through by splatting: change `cm/ai--render` to `(apply #'cm/ai-pkg 'json (json-encode (plist-get pkg :payload)) (plist-get pkg :meta))`. Use that form (it preserves `:tick` etc. in the json package's meta).

In `init.el`: delete the 8 remote function definitions (lines ~2200-2333) and update the AI-section cheat-sheet comment (~2154-2164) to describe package returns, e.g. replace the JSON descriptions with: "→ elisp/text/ref/error package (see cm-ai-bridge.el)".

- [ ] **Step 4: Run tests + byte-compile + init.el balance**

Run the focused suite (expect all new read tests passing), then `./tests/run-tests.sh` (no regressions), `batch-byte-compile cm-ai-bridge.el` (clean, delete .elc), and the init.el `check-parens` command from Task 2 Step 4.

- [ ] **Step 5: Commit**

```bash
git add cm-ai-bridge.el init.el tests/cm-ai-bridge-tests.el
git commit -m "cm-ai-bridge: migrate the 8 remote reads to typed packages"
```

---

### Task 4: Write path — diff stats, DWIM decision, auto-apply

**Files:**
- Modify: `cm-ai-bridge.el`
- Test: `tests/cm-ai-bridge-tests.el`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: `cm/ai-apply-auto-max-hunks`/`-lines` (defcustoms), `cm/ai--unified-diff (old new) -> string`, `cm/ai--diff-stats (old new) -> (:hunks H :lines L)`, `cm/ai--apply-decision (stats review read-only) -> 'auto|'review`, `cm/ai--replace-contents (buf text)`, `cm/ai-apply-edit (target base-tick edit-spec &optional review) -> package` (auto path + error paths; review path stubbed to `error :code review-not-wired` until Task 5).

- [ ] **Step 1: Write the failing test**

Append to `tests/cm-ai-bridge-tests.el`:

```elisp
(ert-deftest cm/ai-diff-stats-counts ()
  (let ((s (cm/ai--diff-stats "a\nb\nc\n" "a\nB\nc\n")))
    (should (= (plist-get s :hunks) 1))
    (should (>= (plist-get s :lines) 2))))  ; -b +B

(ert-deftest cm/ai-apply-decision-thresholds ()
  (let ((cm/ai-apply-auto-max-hunks 1) (cm/ai-apply-auto-max-lines 8))
    (should (eq (cm/ai--apply-decision '(:hunks 1 :lines 2) 'auto nil) 'auto))
    (should (eq (cm/ai--apply-decision '(:hunks 3 :lines 2) 'auto nil) 'review))
    (should (eq (cm/ai--apply-decision '(:hunks 1 :lines 40) 'auto nil) 'review))
    (should (eq (cm/ai--apply-decision '(:hunks 1 :lines 2) 'force nil) 'review))
    (should (eq (cm/ai--apply-decision '(:hunks 9 :lines 9) 'skip nil) 'auto))
    (should (eq (cm/ai--apply-decision '(:hunks 1 :lines 1) 'auto t) 'review))))  ; read-only

(ert-deftest cm/ai-apply-edit-auto-applies ()
  (with-temp-buffer
    (insert "one\ntwo\nthree\n") (rename-buffer "cm-ai-apply" t)
    (let* ((tick (buffer-chars-modified-tick))
           (p (cm/ai-apply-edit (buffer-name) tick
                                '(:kind full :text "one\nTWO\nthree\n") 'auto)))
      (should (eq (plist-get p :type) 'elisp))
      (should (eq (plist-get (plist-get p :payload) :status) 'applied))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     "one\nTWO\nthree\n")))))

(ert-deftest cm/ai-apply-edit-stale-tick-errors ()
  (with-temp-buffer
    (insert "x\n") (rename-buffer "cm-ai-stale" t)
    (let ((p (cm/ai-apply-edit (buffer-name) 999999
                               '(:kind full :text "y\n") 'auto)))
      (should (eq (plist-get p :type) 'error))
      (should (eq (plist-get (plist-get p :payload) :code) 'stale-buffer)))))

(ert-deftest cm/ai-apply-edit-unknown-target-errors ()
  (let ((p (cm/ai-apply-edit "no-such-buf" 1 '(:kind full :text "z") 'auto)))
    (should (eq (plist-get p :type) 'error))
    (should (eq (plist-get (plist-get p :payload) :code) 'unknown-target))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-bridge-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `void-function cm/ai--diff-stats`.

- [ ] **Step 3: Write the write-path core**

Insert into `cm-ai-bridge.el` (before `provide`):

```elisp
(defcustom cm/ai-apply-auto-max-hunks 1
  "Auto-apply an AI edit only if it touches at most this many diff hunks."
  :type 'integer :group 'tools)

(defcustom cm/ai-apply-auto-max-lines 8
  "Auto-apply an AI edit only if it changes at most this many lines."
  :type 'integer :group 'tools)

(defun cm/ai--unified-diff (old new)
  "Return the unified diff string from OLD text to NEW text."
  (let ((fa (make-temp-file "ai-diff-a")) (fb (make-temp-file "ai-diff-b")))
    (unwind-protect
        (progn
          (with-temp-file fa (insert old))
          (with-temp-file fb (insert new))
          (with-temp-buffer
            (call-process "diff" nil t nil "-u" fa fb)
            (buffer-string)))
      (ignore-errors (delete-file fa))
      (ignore-errors (delete-file fb)))))

(defun cm/ai--diff-stats (old new)
  "Return (:hunks H :lines L) between OLD and NEW text."
  (let ((hunks 0) (lines 0))
    (dolist (ln (split-string (cm/ai--unified-diff old new) "\n"))
      (cond
       ((string-prefix-p "@@" ln) (setq hunks (1+ hunks)))
       ((and (> (length ln) 0)
             (memq (aref ln 0) '(?+ ?-))
             (not (string-prefix-p "+++" ln))
             (not (string-prefix-p "---" ln)))
        (setq lines (1+ lines)))))
    (list :hunks hunks :lines lines)))

(defun cm/ai--apply-decision (stats review read-only)
  "Return `auto' or `review' for STATS, honoring REVIEW override + READ-ONLY."
  (cond
   ((eq review 'force) 'review)
   ((eq review 'skip) 'auto)
   (read-only 'review)
   ((and (<= (plist-get stats :hunks) cm/ai-apply-auto-max-hunks)
         (<= (plist-get stats :lines) cm/ai-apply-auto-max-lines))
    'auto)
   (t 'review)))

(defun cm/ai--replace-contents (buf text)
  "Minimally replace BUF's contents with TEXT (preserves point/markers/undo)."
  (with-current-buffer buf
    (let ((src (generate-new-buffer " *cm/ai-apply-src*")))
      (unwind-protect
          (progn (with-current-buffer src (insert text))
                 (replace-buffer-contents src))
        (kill-buffer src)))))

(defun cm/ai-apply-edit (target base-tick edit-spec &optional review)
  "Apply EDIT-SPEC to TARGET buffer under optimistic concurrency (BASE-TICK).
EDIT-SPEC is (:kind full :text NEW-TEXT).  Returns a package: an `applied'
elisp package (auto path), a `pending' elisp package (review path), or an
`error' package (unknown-target / stale-buffer / unsupported-kind)."
  (cm/ai-with-package
    (let ((buf (cm/ai--resolve-buffer target)))
      (cond
       ((not buf)
        (cm/ai-pkg 'error (list :code 'unknown-target
                                :message (format "No live buffer for %S" target))))
       ((not (eq (plist-get edit-spec :kind) 'full))
        (cm/ai-pkg 'error (list :code 'unsupported-kind
                                :message (format "Unsupported edit kind: %S"
                                                 (plist-get edit-spec :kind)))))
       (t
        (with-current-buffer buf
          (if (/= (buffer-chars-modified-tick) base-tick)
              (cm/ai-pkg 'error (list :code 'stale-buffer
                                      :message "Buffer changed since read; re-read and retry"
                                      :expected base-tick
                                      :actual (buffer-chars-modified-tick)))
            (let* ((proposed (plist-get edit-spec :text))
                   (current (buffer-substring-no-properties (point-min) (point-max)))
                   (stats (cm/ai--diff-stats current proposed))
                   (decision (cm/ai--apply-decision stats review buffer-read-only)))
              (if (eq decision 'auto)
                  (progn
                    (cm/ai--replace-contents buf proposed)
                    (cm/ai-pkg 'elisp (list :status 'applied
                                            :hunks (plist-get stats :hunks)
                                            :lines (plist-get stats :lines))))
                ;; Review path is wired in Task 5.
                (cm/ai-pkg 'error (list :code 'review-not-wired
                                        :message "Review gate not yet implemented")))))))))))
```

- [ ] **Step 4: Run tests + byte-compile**

Run the focused suite (all write-core tests pass; the review path returns the temporary `review-not-wired` error, which no Task-4 test exercises — the DWIM tests use `'auto`/`'skip`/thresholds landing on auto). Then `batch-byte-compile cm-ai-bridge.el` clean (delete .elc) and `./tests/run-tests.sh`.

- [ ] **Step 5: Commit**

```bash
git add cm-ai-bridge.el tests/cm-ai-bridge-tests.el
git commit -m "cm-ai-bridge: write path core (diff stats, DWIM decision, auto-apply, base-tick guard)"
```

---

### Task 5: Review gate — async :pending + apply/reject

**Files:**
- Modify: `cm-ai-bridge.el` (replace the `review-not-wired` stub)
- Test: `tests/cm-ai-bridge-tests.el`

**Interfaces:**
- Consumes: Task 4.
- Produces: `cm/ai--make-review-buffer (buf proposed base-tick current) -> buffer`, `cm/ai-edit-apply` / `cm/ai-edit-reject` (interactive), and the review branch of `cm/ai-apply-edit` returning `(:status pending :review-buffer NAME)`.

- [ ] **Step 1: Write the failing test**

Append to `tests/cm-ai-bridge-tests.el`:

```elisp
(ert-deftest cm/ai-apply-edit-review-returns-pending ()
  (with-temp-buffer
    (insert "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n") (rename-buffer "cm-ai-rev" t)
    (let* ((tick (buffer-chars-modified-tick))
           ;; force review regardless of size
           (p (cm/ai-apply-edit (buffer-name) tick
                                '(:kind full :text "A\nB\nc\nd\ne\nf\ng\nh\ni\nj\n") 'force))
           (pl (plist-get p :payload)))
      (should (eq (plist-get p :type) 'elisp))
      (should (eq (plist-get pl :status) 'pending))
      (let ((rbuf (get-buffer (plist-get pl :review-buffer))))
        (should (buffer-live-p rbuf))
        ;; buffer still unchanged until the human applies
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"))
        ;; apply it and confirm the target changes
        (with-current-buffer rbuf (cm/ai-edit-apply))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "A\nB\nc\nd\ne\nf\ng\nh\ni\nj\n"))))))

(ert-deftest cm/ai-edit-apply-refuses-stale ()
  (with-temp-buffer
    (insert "orig\n") (rename-buffer "cm-ai-rev2" t)
    (let* ((tick (buffer-chars-modified-tick))
           (p (cm/ai-apply-edit (buffer-name) tick '(:kind full :text "new\n") 'force))
           (rbuf (get-buffer (plist-get (plist-get p :payload) :review-buffer))))
      ;; mutate the target after the review was created -> apply must refuse
      (insert "sneaky\n")
      (with-current-buffer rbuf
        (should-error (cm/ai-edit-apply) :type 'user-error))
      ;; target keeps its (mutated) content, edit not applied
      (should (string-match-p "sneaky" (buffer-string))))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-ai-bridge-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — pending status not returned (stub still errors `review-not-wired`).

- [ ] **Step 3: Implement the review gate**

Add to `cm-ai-bridge.el` (before `provide`; also `(require 'diff-mode)` in the requires):

```elisp
(defvar-local cm/ai-edit--target nil "Target buffer for a pending AI edit.")
(defvar-local cm/ai-edit--proposed nil "Proposed full text for a pending AI edit.")
(defvar-local cm/ai-edit--base-tick nil "Buffer tick captured when the edit was proposed.")

(defvar cm/ai-edit-review-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m diff-mode-map)
    (define-key m (kbd "C-c C-c") #'cm/ai-edit-apply)
    (define-key m (kbd "C-c C-k") #'cm/ai-edit-reject)
    m)
  "Keymap for the AI edit review buffer.")

(defun cm/ai--make-review-buffer (buf proposed base-tick current)
  "Create and display a review buffer diffing CURRENT vs PROPOSED for BUF.
Returns the review buffer."
  (let* ((name (format "*ai-edit:%s*" (buffer-name buf)))
         (rbuf (get-buffer-create name)))
    (with-current-buffer rbuf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (cm/ai--unified-diff current proposed)))
      (goto-char (point-min))
      (diff-mode)
      (use-local-map cm/ai-edit-review-mode-map)
      (setq buffer-read-only t
            cm/ai-edit--target buf
            cm/ai-edit--proposed proposed
            cm/ai-edit--base-tick base-tick)
      (setq header-line-format
            (substitute-command-keys
             "AI edit — \\[cm/ai-edit-apply] apply · \\[cm/ai-edit-reject] reject")))
    (display-buffer rbuf)
    rbuf))

(defun cm/ai-edit-apply ()
  "Apply the pending AI edit shown in this review buffer to its target."
  (interactive)
  (let ((buf cm/ai-edit--target)
        (proposed cm/ai-edit--proposed)
        (base-tick cm/ai-edit--base-tick))
    (unless (buffer-live-p buf) (user-error "Target buffer is gone"))
    (with-current-buffer buf
      (when (/= (buffer-chars-modified-tick) base-tick)
        (user-error "Target changed since the edit was proposed; not applying")))
    (cm/ai--replace-contents buf proposed)
    (let ((n (buffer-name buf)))
      (kill-buffer (current-buffer))
      (message "AI edit applied to %s" n))))

(defun cm/ai-edit-reject ()
  "Discard the pending AI edit shown in this review buffer."
  (interactive)
  (let ((n (and (buffer-live-p cm/ai-edit--target) (buffer-name cm/ai-edit--target))))
    (kill-buffer (current-buffer))
    (message "AI edit rejected%s" (if n (format " for %s" n) ""))))
```

Then replace the Task-4 review stub in `cm/ai-apply-edit` — change

```elisp
                (cm/ai-pkg 'error (list :code 'review-not-wired
                                        :message "Review gate not yet implemented"))
```

to

```elisp
                (let ((rbuf (cm/ai--make-review-buffer buf proposed base-tick current)))
                  (cm/ai-pkg 'elisp (list :status 'pending
                                          :review-buffer (buffer-name rbuf)
                                          :hunks (plist-get stats :hunks)
                                          :lines (plist-get stats :lines))))
```

- [ ] **Step 4: Run tests + byte-compile + full suite**

Run the focused suite (review tests pass), `batch-byte-compile cm-ai-bridge.el` (clean, delete .elc), and `./tests/run-tests.sh` (no regressions).

- [ ] **Step 5: Commit**

```bash
git add cm-ai-bridge.el tests/cm-ai-bridge-tests.el
git commit -m "cm-ai-bridge: review gate (async pending, diff-mode review buffer, apply/reject)"
```

---

### Task 6: Document the packages + write-path contract

**Files:**
- Modify: `CLAUDE.md` (AI Writing Assistant section)

**Interfaces:**
- Consumes: all prior tasks. No code.

- [ ] **Step 1: Add the contract subsection**

Under the "AI Writing Assistant" section of `CLAUDE.md`, add:

```markdown
### Packages protocol + write path (cm-ai-bridge.el)

The remote query surface now speaks a typed **packages** protocol and gains a
review-gated **write path**. All remote (`emacsclient -e` / `emacs-send -e`)
calls return a self-describing elisp package:

    (:v 1 :type TYPE :payload PAYLOAD :meta (:buffer B :tick N :server S …))

- `TYPE` ∈ `elisp` (structured plist) · `text` (string) · `markdown` · `json`
  (only with `:as 'json`) · `ref` (`:payload (:path … :bytes N :of text)` — read
  the file for the content) · `error` (`:payload (:code SYM :message STR …)`).
- Agent-side handling: read the outer plist, dispatch on `:type`; `error` →
  surface the `:code`/`:message`; `ref` → read `:path`; keep `:meta`'s `:tick`
  for the write path. Migrated reads: `cm/ai-current-context`,
  `cm/ai-visible-buffers`, `cm/ai-get-content` (ref), `cm/ai-paragraph-at-point`,
  `cm/ai-line-at-point`, `cm/ai-region-or-paragraph`, `cm/ai-org-subtree-at-point`
  (`not-org-mode` error outside org), `cm/ai-nearby-lines`. Each takes an optional
  TARGET (buffer name or file path; default focused) and `:as 'json`.

**Writing a buffer** (dirty/unsaved buffers, or when you want a review gate; for
a saved-clean file just edit the file directly and auto-revert picks it up):

    (cm/ai-apply-edit TARGET BASE-TICK '(:kind full :text "NEW WHOLE-BUFFER TEXT") REVIEW)

- You emit the *full* new buffer text; Emacs applies it minimally via
  `replace-buffer-contents` (point/undo preserved). `BASE-TICK` is the `:tick`
  from your read — a mismatch returns `(:code stale-buffer)`, so re-read and retry.
- **DWIM gate:** small edits (≤ `cm/ai-apply-auto-max-hunks`=1 hunk and
  ≤ `cm/ai-apply-auto-max-lines`=8 lines) auto-apply and return
  `(:status applied …)`. Larger/scattered edits (or a read-only buffer, or
  `REVIEW` = `force`) pop a diff review buffer and return `(:status pending
  :review-buffer NAME)` — Jim applies with `C-c C-c` / rejects with `C-c C-k`;
  the edit is NOT applied until then (re-read the buffer to confirm). `REVIEW`
  overrides: `force | skip | auto` (default `auto`).

Design: `docs/plans/2026-08-28-emacs-agents-bridge-{design,phase2-plan}.md`.
```

- [ ] **Step 2: Verify**

Run: `grep -n "Packages protocol" CLAUDE.md` → the heading is present.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the packages protocol + review-gated write path"
```

---

## Self-Review

**Spec coverage (Section C / C-write):**
- Envelope `(:v 1 :type … :payload … :meta …)` → Task 1 (`cm/ai-pkg`).
- Types elisp/text/markdown/json/error/ref → Tasks 1 (error via `with-package`), 2 (ref helper), 3 (per-read type choice incl. `not-org-mode` error, `:as 'json`).
- `error` first-class / no silent failures → Task 1 `cm/ai-with-package` + typed error packages in Tasks 3-5.
- `ref` reuses `~/.emacs-ai/content.txt` → Task 2 (`cm/ai--pkg-ref`) + Task 3 (`cm/ai-get-content`).
- Whole-channel migration + `cm-ai-bridge.el` extraction → Tasks 2-3; interactive commands stay in init.el.
- Buffer addressing = name-or-path, focused default, unknown → error → Tasks 1 (`--resolve-buffer`) + 3 (`--on-target`).
- Base-tick concurrency in `:meta` + apply guard → Tasks 3 (`--meta`) + 4 (`stale-buffer`).
- Write path: full text → `replace-buffer-contents`; DWIM (hunks/lines, review override, read-only) → Task 4; async `:pending` review gate → Task 5.
- CLAUDE.md contract → Task 6.

**Placeholder scan:** none — every step has concrete code or an exact command. (Task 4 ships a deliberate, labeled `review-not-wired` stub that Task 5 replaces; it is real code, not a placeholder, and no test depends on the stub.)

**Type consistency:** package accessors `(plist-get p :type/:payload/:meta)` used uniformly; `cm/ai-pkg (type payload &rest meta)`, `cm/ai--pkg-ref (content &rest meta)`, `cm/ai--resolve-buffer (target)`, `cm/ai--on-target (target &rest body)`, `cm/ai--meta ()`, `cm/ai--diff-stats (old new)`, `cm/ai--apply-decision (stats review read-only)`, `cm/ai--replace-contents (buf text)`, `cm/ai-apply-edit (target base-tick edit-spec &optional review)`, `cm/ai--make-review-buffer (buf proposed base-tick current)` — signatures match across defs, tests, and call sites. Edit status symbols (`applied`/`pending`) and error codes (`unknown-target`/`stale-buffer`/`unsupported-kind`/`not-org-mode`) are consistent between producers and their asserting tests.
