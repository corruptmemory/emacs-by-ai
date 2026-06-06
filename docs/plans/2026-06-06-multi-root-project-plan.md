# Multi-root Project Search ("Add Folder to Project") Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add opt-in commands that run search / references / find-file / jump-to-definition across directories listed in a `.project-roots` file at the primary project root.

**Architecture:** A self-contained, batch-loadable library `cm-project-roots.el` (sibling to `jai-ts-mode.el`, loaded from `init.el` the same way) holding pure cores + thin interactive shells. LSP-first for jump/refs (`cm/eglot--prefer`), rg-based for search/find-file. No custom `project.el` backend. First automated ERT suite for the repo under `tests/`.

**Tech Stack:** Emacs 29+ Elisp, ERT, `consult-ripgrep` (list-DIR), `dumb-jump` (`dumb-jump-fetch-results` per root), Eglot, ripgrep.

**Design doc:** `docs/plans/2026-06-06-multi-root-project-design.md`

**Conventions:** All new symbols use the `cm/` prefix. Each task is TDD: write the failing test, watch it fail, implement minimally, watch it pass, commit. Run tests with `./tests/run-tests.sh`.

---

## Task 1: Test harness + library skeleton

**Files:**
- Create: `cm-project-roots.el`
- Create: `tests/cm-project-roots-tests.el`
- Create: `tests/run-tests.sh`

**Step 1: Create the library skeleton**

`cm-project-roots.el`:
```elisp
;;; cm-project-roots.el --- Multi-root project search ("Add Folder to Project")  -*- lexical-binding: t; -*-
;;; Commentary:
;; Opt-in commands that run search / references / find-file / jump-to-definition
;; across directories listed in a `.project-roots' file at the primary project
;; root.  LSP-first for jump/refs; rg-based for search/find-file.
;; See docs/plans/2026-06-06-multi-root-project-design.md.
;;; Code:

(require 'project)
(require 'xref)
(require 'subr-x)
(require 'cl-lib)

(declare-function consult-ripgrep "consult")
(declare-function consult--read "consult")
(declare-function dumb-jump-fetch-results "dumb-jump")
(declare-function dumb-jump-get-language "dumb-jump")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-server-capable "eglot")

(defconst cm/project-roots-file ".project-roots"
  "Name of the file (at the primary project root) listing extra roots.")

(provide 'cm-project-roots)
;;; cm-project-roots.el ends here
```

**Step 2: Create the test runner**

`tests/run-tests.sh`:
```bash
#!/usr/bin/env bash
# Run the cm-project-roots ERT suite in batch.
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
  -l "$REPO/tests/cm-project-roots-tests.el" \
  -f ert-run-tests-batch-and-exit
```
Then: `chmod +x tests/run-tests.sh`

**Step 3: Create the test file with a harness smoke test**

`tests/cm-project-roots-tests.el`:
```elisp
;;; cm-project-roots-tests.el --- Tests for cm-project-roots  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-project-roots)

(ert-deftest cm/project-roots-harness-loads ()
  "The library loads and the marker constant is defined."
  (should (equal cm/project-roots-file ".project-roots")))

(provide 'cm-project-roots-tests)
;;; cm-project-roots-tests.el ends here
```

**Step 4: Run to verify the harness works**

Run: `./tests/run-tests.sh`
Expected: `Ran 1 test ... 1 passed`.

**Step 5: Commit**
```bash
git add cm-project-roots.el tests/cm-project-roots-tests.el tests/run-tests.sh
git commit -m "Add test harness + cm-project-roots skeleton"
```

---

## Task 2: `cm/project-roots--parse` (pure)

**Files:** Modify `cm-project-roots.el`; Test `tests/cm-project-roots-tests.el`

**Step 1: Write the failing test** (add before `(provide ...)`)
```elisp
(ert-deftest cm/project-roots--parse-handles-comments-blanks-paths ()
  (should (equal
           (cm/project-roots--parse
            "# full comment\n\n/abs/dir\nrel/dir\n~/home-dir  # trailing\n" "/base")
           (list "/abs/dir" "/base/rel/dir" (expand-file-name "~/home-dir")))))
```

**Step 2: Run to verify it fails**

Run: `./tests/run-tests.sh`
Expected: FAIL — `cm/project-roots--parse` void-function.

**Step 3: Implement** (add to `cm-project-roots.el` before `provide`)
```elisp
(defun cm/project-roots--parse (text base-dir)
  "Parse TEXT (a `.project-roots' file body) into a list of absolute dirs.
Lines beginning with or containing `#' are comment-stripped; blank lines
are dropped; `~' expands; relative entries resolve against BASE-DIR.
Pure: performs no filesystem access."
  (let (dirs)
    (dolist (line (split-string text "\n"))
      (let ((s (string-trim (replace-regexp-in-string "#.*\\'" "" line))))
        (unless (string-empty-p s)
          (push (expand-file-name s base-dir) dirs))))
    (nreverse dirs)))
```

**Step 4: Run to verify it passes**

Run: `./tests/run-tests.sh`
Expected: PASS (2 tests).

**Step 5: Commit**
```bash
git add cm-project-roots.el tests/cm-project-roots-tests.el
git commit -m "Add cm/project-roots--parse with tests"
```

---

## Task 3: `cm/project-roots--from-file` + `cm/project-roots` (filesystem fixture)

**Files:** Modify `cm-project-roots.el`; Test `tests/cm-project-roots-tests.el`

**Step 1: Write the failing tests**
```elisp
(defun cm/test--make-tree ()
  "Create a temp project tree; return its root dir (absolute, slash-terminated)."
  (let* ((root (file-name-as-directory (make-temp-file "cmpr" t))))
    (make-directory (expand-file-name "extra" root))
    (with-temp-file (expand-file-name ".project-roots" root)
      (insert "extra\nnonexistent-dir\n"))
    root))

(ert-deftest cm/project-roots--from-file-skips-missing ()
  (let* ((root (cm/test--make-tree))
         (got (cm/project-roots--from-file (expand-file-name ".project-roots" root))))
    (should (member (file-name-as-directory root) got))
    (should (member (file-name-as-directory (expand-file-name "extra" root)) got))
    (should-not (member (file-name-as-directory (expand-file-name "nonexistent-dir" root)) got))))

(ert-deftest cm/project-roots-falls-back-without-file ()
  (let ((default-directory temporary-file-directory))
    ;; No .project-roots above temp dir → returns a single root, never errors.
    (should (= 1 (length (cm/project-roots))))))
```

**Step 2: Run to verify it fails**

Run: `./tests/run-tests.sh`
Expected: FAIL — `cm/project-roots--from-file` void.

**Step 3: Implement**
```elisp
(defun cm/project-roots--from-file (file)
  "Return the primary root (FILE's directory) plus existing declared roots.
Nonexistent declared dirs are skipped with a `message' warning."
  (let* ((base (file-name-as-directory (file-name-directory (expand-file-name file))))
         (declared (cm/project-roots--parse
                    (with-temp-buffer (insert-file-contents file) (buffer-string))
                    base))
         (roots (list base)))
    (dolist (d declared)
      (if (file-directory-p d)
          (push (file-name-as-directory d) roots)
        (message "cm/project-roots: skipping missing dir %s" d)))
    (delete-dups (nreverse roots))))

(defun cm/project-roots ()
  "Return the list of root directories for the current multi-root project.
If a `.project-roots' file dominates `default-directory', return its
primary root plus the existing declared roots.  Otherwise degrade to the
current project root, or `default-directory'."
  (if-let* ((dir (locate-dominating-file default-directory cm/project-roots-file)))
      (cm/project-roots--from-file (expand-file-name cm/project-roots-file dir))
    (list (file-name-as-directory
           (expand-file-name
            (if-let* ((proj (project-current))) (project-root proj)
              default-directory))))))
```

**Step 4: Run to verify it passes** — `./tests/run-tests.sh` → PASS (4 tests).

**Step 5: Commit**
```bash
git add cm-project-roots.el tests/cm-project-roots-tests.el
git commit -m "Add cm/project-roots + from-file with fixture tests"
```

---

## Task 4: `cm/project-add-root--append` + add/edit shells

**Files:** Modify `cm-project-roots.el`; Test `tests/cm-project-roots-tests.el`

**Step 1: Write the failing tests**
```elisp
(ert-deftest cm/project-add-root--append-dedups ()
  (let* ((file (make-temp-file "cmpr-roots"))
         (dir  (file-name-as-directory (make-temp-file "cmpr-d" t)))
         (abbr (abbreviate-file-name dir)))
    (cm/project-add-root--append file dir)
    (cm/project-add-root--append file dir) ; second add must be a no-op
    (let ((lines (with-temp-buffer (insert-file-contents file)
                   (split-string (buffer-string) "\n" t))))
      (should (equal (cl-count abbr lines :test #'equal) 1)))))
```

**Step 2: Run** → FAIL (`cm/project-add-root--append` void).

**Step 3: Implement**
```elisp
(defun cm/project-add-root--append (file dir)
  "Append DIR (abbreviated, slash-terminated) to FILE; create FILE if absent.
No-op when DIR is already listed."
  (let* ((abbr (abbreviate-file-name (file-name-as-directory (expand-file-name dir))))
         (lines (and (file-exists-p file)
                     (with-temp-buffer (insert-file-contents file)
                       (mapcar #'string-trim
                               (split-string (buffer-string) "\n" t))))))
    (unless (member abbr lines)
      (with-temp-buffer
        (when (file-exists-p file) (insert-file-contents file))
        (goto-char (point-max))
        (unless (or (bobp) (bolp)) (insert "\n"))
        (insert abbr "\n")
        (write-region (point-min) (point-max) file)))))

(defun cm/project--primary-root ()
  "Return the directory that should hold this project's `.project-roots'."
  (file-name-as-directory
   (expand-file-name
    (or (locate-dominating-file default-directory cm/project-roots-file)
        (when-let* ((proj (project-current))) (project-root proj))
        default-directory))))

(defun cm/project-add-root (dir)
  "Add DIR to this project's `.project-roots' (\"Add Folder to Project\")."
  (interactive "DAdd folder to project: ")
  (cm/project-add-root--append
   (expand-file-name cm/project-roots-file (cm/project--primary-root)) dir)
  (message "Added %s to project roots" (abbreviate-file-name dir)))

(defun cm/project-edit-roots ()
  "Open this project's `.project-roots' file for editing."
  (interactive)
  (find-file (expand-file-name cm/project-roots-file (cm/project--primary-root))))
```

**Step 4: Run** → PASS (5 tests).

**Step 5: Commit**
```bash
git add cm-project-roots.el tests/cm-project-roots-tests.el
git commit -m "Add cm/project-add-root append/edit with dedupe test"
```

---

## Task 5: `cm/eglot--prefer` gate (stubbed)

**Files:** Modify `cm-project-roots.el`; Test `tests/cm-project-roots-tests.el`

**Step 1: Write the failing tests**
```elisp
(ert-deftest cm/eglot--prefer-lsp-when-capable ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
            ((symbol-function 'eglot-server-capable) (lambda (&rest _) t)))
    (let ((current-prefix-arg nil))
      (should (eq 'lsp (cm/eglot--prefer :x (lambda () 'lsp) (lambda () 'fb)))))))

(ert-deftest cm/eglot--prefer-fallback-when-unmanaged ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () nil)))
    (should (eq 'fb (cm/eglot--prefer :x (lambda () 'lsp) (lambda () 'fb))))))

(ert-deftest cm/eglot--prefer-prefix-forces-fallback ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
            ((symbol-function 'eglot-server-capable) (lambda (&rest _) t)))
    (let ((current-prefix-arg '(4)))
      (should (eq 'fb (cm/eglot--prefer :x (lambda () 'lsp) (lambda () 'fb)))))))

(ert-deftest cm/eglot--prefer-user-error-falls-back ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
            ((symbol-function 'eglot-server-capable) (lambda (&rest _) t)))
    (should (eq 'fb (cm/eglot--prefer :x (lambda () (user-error "none")) (lambda () 'fb))))))
```

**Step 2: Run** → FAIL (`cm/eglot--prefer` void).

**Step 3: Implement**
```elisp
(defun cm/eglot--prefer (capability thunk fallback)
  "Run THUNK if Eglot manages the buffer and the server has CAPABILITY,
falling back to FALLBACK when THUNK finds nothing (signals `user-error').
A prefix argument forces FALLBACK."
  (if (and (not current-prefix-arg)
           (fboundp 'eglot-managed-p) (eglot-managed-p)
           (eglot-server-capable capability))
      (condition-case nil (funcall thunk)
        (user-error (funcall fallback)))
    (funcall fallback)))
```

**Step 4: Run** → PASS (9 tests).

**Step 5: Commit**
```bash
git add cm-project-roots.el tests/cm-project-roots-tests.el
git commit -m "Add cm/eglot--prefer LSP gate with stubbed tests"
```

---

## Task 6: `cm/project-find-file--candidates` (real rg) + find-file shell

**Files:** Modify `cm-project-roots.el`; Test `tests/cm-project-roots-tests.el`

**Step 1: Write the failing test**
```elisp
(ert-deftest cm/project-find-file--candidates-spans-roots ()
  (skip-unless (executable-find "rg"))
  (let* ((a (file-name-as-directory (make-temp-file "cmpr-a" t)))
         (b (file-name-as-directory (make-temp-file "cmpr-b" t))))
    (with-temp-file (expand-file-name "alpha.txt" a) (insert "x"))
    (with-temp-file (expand-file-name "beta.txt" b) (insert "y"))
    (let ((files (cm/project-find-file--candidates (list a b))))
      (should (cl-some (lambda (f) (string-suffix-p "alpha.txt" f)) files))
      (should (cl-some (lambda (f) (string-suffix-p "beta.txt" f)) files)))))
```

**Step 2: Run** → FAIL (`cm/project-find-file--candidates` void).

**Step 3: Implement**
```elisp
(defun cm/project-find-file--candidates (roots)
  "Return absolute file paths under ROOTS via `rg --files' (respects .gitignore)."
  (when roots
    (apply #'process-lines-ignore-status
           "rg" "--files" "--color=never"
           (mapcar #'expand-file-name roots))))

(defun cm/project-find-file-all-roots ()
  "Find a file by name across all project roots."
  (interactive)
  (let ((files (cm/project-find-file--candidates (cm/project-roots))))
    (unless files (user-error "No files found across project roots"))
    (find-file (consult--read files :prompt "Find file (all roots): "
                              :category 'file :require-match t :sort nil))))
```

**Step 4: Run** → PASS (10 tests; skips if no rg).

**Step 5: Commit**
```bash
git add cm-project-roots.el tests/cm-project-roots-tests.el
git commit -m "Add multi-root find-file with rg integration test"
```

---

## Task 7: search + references commands (refs fallback pattern stubbed)

**Files:** Modify `cm-project-roots.el`; Test `tests/cm-project-roots-tests.el`

**Step 1: Write the failing test**
```elisp
(ert-deftest cm/project-refs--fallback-word-bounded-pattern ()
  (let (captured)
    (cl-letf (((symbol-function 'eglot-managed-p) (lambda () nil))
              ((symbol-function 'consult-ripgrep)
               (lambda (&rest args) (setq captured args)))
              ((symbol-function 'cm/project-roots) (lambda () '("/r1" "/r2")))
              ((symbol-function 'cm/project--symbol) (lambda () "foo")))
      (cm/project-refs-all-roots)
      (should (equal captured '(("/r1" "/r2") "\\bfoo\\b"))))))
```

**Step 2: Run** → FAIL (`cm/project-refs-all-roots` void).

**Step 3: Implement**
```elisp
(defun cm/project--symbol ()
  "Return the active region, the symbol at point, or a prompted string."
  (or (and (use-region-p)
           (buffer-substring-no-properties (region-beginning) (region-end)))
      (thing-at-point 'symbol t)
      (read-string "Symbol: ")))

(defun cm/project-search-all-roots ()
  "Grep a pattern across all project roots (one live `consult-ripgrep')."
  (interactive)
  (consult-ripgrep (cm/project-roots)))

(defun cm/project-refs-all-roots ()
  "Find references to the symbol at point across roots; LSP-first."
  (interactive)
  (cm/eglot--prefer
   :referencesProvider
   (lambda () (call-interactively #'xref-find-references))
   (lambda () (consult-ripgrep (cm/project-roots)
                               (concat "\\b" (regexp-quote (cm/project--symbol)) "\\b")))))
```

**Step 4: Run** → PASS (11 tests).

**Step 5: Commit**
```bash
git add cm-project-roots.el tests/cm-project-roots-tests.el
git commit -m "Add multi-root search + references (LSP-first) commands"
```

---

## Task 8: `cm/project-jump-def--fallback-results` (real dumb-jump+rg) + jump shells

**Files:** Modify `cm-project-roots.el`; Test `tests/cm-project-roots-tests.el`

**Step 1: Write the failing test** (the crown jewel — proves cross-root jump)
```elisp
(ert-deftest cm/project-jump-def--fallback-finds-def-in-other-root ()
  (skip-unless (and (executable-find "rg") (require 'dumb-jump nil t)))
  (let* ((a (file-name-as-directory (make-temp-file "cmpr-ja" t)))
         (b (file-name-as-directory (make-temp-file "cmpr-jb" t)))
         (a-file (expand-file-name "use.el" a)))
    (with-temp-file a-file (insert "(cm-xroot-demo-fn)\n"))
    (with-temp-file (expand-file-name "def.el" b)
      (insert "(defun cm-xroot-demo-fn () 'ok)\n"))
    (with-current-buffer (find-file-noselect a-file)
      (emacs-lisp-mode)
      (let ((results (cm/project-jump-def--fallback-results
                      (list a b) "cm-xroot-demo-fn")))
        (should (cl-some (lambda (r) (string-suffix-p "def.el" (plist-get r :path)))
                         results))))))
```

**Step 2: Run** → FAIL (`cm/project-jump-def--fallback-results` void).

**Step 3: Implement**
```elisp
(defun cm/project-jump-def--fallback-results (roots &optional symbol)
  "Merge dumb-jump definition results for SYMBOL across ROOTS.
Dedupes on (:path . :line).  SYMBOL defaults to the symbol at point."
  (require 'dumb-jump)
  (let* ((cur-file (or buffer-file-name (buffer-name)))
         (lang (dumb-jump-get-language cur-file))
         (sym (or symbol (thing-at-point 'symbol t)))
         results)
    (dolist (root roots)
      (setq results
            (append results
                    (plist-get (dumb-jump-fetch-results cur-file root lang nil sym)
                               :results))))
    (cl-delete-duplicates
     results
     :test (lambda (x y) (and (equal (plist-get x :path) (plist-get y :path))
                              (equal (plist-get x :line) (plist-get y :line)))))))

(defun cm/project-jump-def--goto (result)
  "Jump to dumb-jump RESULT, pushing the xref marker stack first."
  (xref-push-marker-stack)
  (find-file (plist-get result :path))
  (goto-char (point-min))
  (forward-line (1- (plist-get result :line))))

(defun cm/project-jump-def--present ()
  "Run the multi-root dumb-jump fallback and jump."
  (let ((results (cm/project-jump-def--fallback-results (cm/project-roots))))
    (pcase (length results)
      (0 (user-error "No definitions found across project roots"))
      (1 (cm/project-jump-def--goto (car results)))
      (_ (cm/project-jump-def--goto
          (let* ((fmt (lambda (r) (format "%s:%d: %s" (plist-get r :path)
                                          (plist-get r :line)
                                          (string-trim (or (plist-get r :context) "")))))
                 (alist (mapcar (lambda (r) (cons (funcall fmt r) r)) results))
                 (choice (completing-read "Definition: " alist nil t)))
            (cdr (assoc choice alist))))))))

(defun cm/project-jump-def-all-roots ()
  "Jump to the definition of the symbol at point across roots; LSP-first."
  (interactive)
  (cm/eglot--prefer
   :definitionProvider
   (lambda () (call-interactively #'xref-find-definitions))
   #'cm/project-jump-def--present))
```

**Step 4: Run** → PASS (12 tests; skips if no rg/dumb-jump).

**Step 5: Commit**
```bash
git add cm-project-roots.el tests/cm-project-roots-tests.el
git commit -m "Add multi-root jump-to-definition (dumb-jump per root)"
```

---

## Task 9: Keymap + init.el wiring + parse-check + smoke

**Files:** Modify `cm-project-roots.el`; Modify `init.el` (after the consult-eglot block, ~line 973)

**Step 1: Add the prefix keymap** to `cm-project-roots.el` (before `provide`)
```elisp
(defvar-keymap cm/project-roots-prefix-map
  :doc "Multi-root project (\"add folder to project\") commands."
  "s" #'cm/project-search-all-roots
  "r" #'cm/project-refs-all-roots
  "f" #'cm/project-find-file-all-roots
  "j" #'cm/project-jump-def-all-roots
  "a" #'cm/project-add-root
  "e" #'cm/project-edit-roots)
```

**Step 2: Wire into `init.el`** — add after the `consult-eglot` use-package block:
```elisp
;;;; Multi-root project ("add folder to project") — see cm-project-roots.el.
;; Opt-in commands that span directories listed in a .project-roots file at the
;; primary project root.  LSP-first for jump/refs; rg-based for search/find-file.
(when (load (locate-user-emacs-file "cm-project-roots") t)
  (global-set-key (kbd "C-c w") cm/project-roots-prefix-map))
```

**Step 3: Parse-check both files**

Run:
```bash
emacs --batch --eval '(dolist (f (list "/home/jim/projects/emacs-again/cm-project-roots.el" "/home/jim/projects/emacs-again/init.el")) (with-temp-buffer (insert-file-contents f) (goto-char (point-min)) (condition-case e (while t (read (current-buffer))) (end-of-file (princ (format "%s: OK\n" f))) (error (princ (format "%s: ERROR %S\n" f e))))))'
```
Expected: both `OK`.

**Step 4: Full test run + byte-compile clean**

Run: `./tests/run-tests.sh` → all pass.
Run: `emacs -batch -Q --eval "(add-to-list 'load-path \".\")" -f batch-byte-compile cm-project-roots.el` then `rm -f cm-project-roots.elc` — expect no errors (warnings about consult/dumb-jump/eglot are acceptable since they're `declare-function`'d).

**Step 5: Interactive smoke (live Emacs, via `emacs-send -e` or manually)**

In a scratch project: create `/tmp/cmpr-demo/.project-roots` pointing at two real dirs, open a file under it, and exercise `C-c w s`, `C-c w f`, `C-c w r`, `C-c w j`, `C-c w a`, `C-c w e`. Confirm scope spans both roots.

**Step 6: Commit**
```bash
git add cm-project-roots.el init.el
git commit -m "Wire cm-project-roots into init.el under C-c w"
```

---

## Task 10: Docs + final verification

**Files:** Modify `README.md`, `CLAUDE.md`, `init.el` (cheat-sheet block ~line 2043)

**Step 1: README.md** — add a "## Multi-root project (Add Folder to Project)" section with the `C-c w` key table and a `.project-roots` example.

**Step 2: CLAUDE.md** — add an architecture-list item and a short "## Multi-root project search" section describing `.project-roots`, the opt-in commands, LSP-first behavior, and the `tests/` suite (`./tests/run-tests.sh`).

**Step 3: init.el cheat sheet** — add under the keybinding cheat sheet:
```
;; Multi-root project ("add folder to project"):
;;   C-c w s/r/f/j  search / refs / find-file / jump-to-def across roots
;;   C-c w a/e      add folder / edit .project-roots
```

**Step 4: Final full verification**

Run: `./tests/run-tests.sh` → all pass.
Run the parse-check from Task 9 Step 3 → both OK.

**Step 5: Commit**
```bash
git add README.md CLAUDE.md init.el
git commit -m "Document multi-root project search"
```

---

## Done criteria

- `./tests/run-tests.sh` green (12+ tests; integration tests skip cleanly without rg/dumb-jump).
- `C-c w s/r/f/j/a/e` work in a live Emacs over a `.project-roots` fixture.
- Existing commands (`M-.`, `C-c s`, etc.) unchanged.
- README, CLAUDE.md, and the init.el cheat sheet updated.
