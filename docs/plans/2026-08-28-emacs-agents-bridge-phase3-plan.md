# Emacs↔Agents Bridge — Phase 3 (herdr Bind/Push) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `M-x cm/ai-bind-agent` — pick a running herdr-managed agent from `herdr agent list` and push this Emacs's socket handshake into it, so that agent gains a direct line back to *this* Emacs (explicit, cross-project binding on top of Phase 1's automatic same-project registry).

**Architecture:** A new sibling library `cm-herdr.el` shells out to the `herdr` CLI (0.8.2): `herdr agent list` (JSON → agent plists) to choose a target, then `herdr agent prompt <pane_id> '[emacs-bridge] connect {…}'` to deliver this Emacs's `{server_name, socket, project_root}` (sourced from Phase 1's `cm/ai-registry-descriptor`). The agent-side `[emacs-bridge]` contract lives in CLAUDE.md. Degrades gracefully when `herdr` is absent.

**Tech Stack:** Emacs Lisp (built-in `json`, `cl-lib`, `subr-x`), the `herdr` CLI, ERT.

**Spec:** `docs/plans/2026-08-28-emacs-agents-bridge-design.md` — Section B (herdr bind/push layer).

## Global Constraints

- Emacs **31.1**; every new `.el` starts with a `-*- lexical-binding: t; -*-` cookie on line 1.
- `cm/` prefix for all functions/vars.
- **Spike result (verified 2026-08-28, herdr 0.8.2):** a context-less client can drive `herdr agent list` with just `herdr` on PATH + `HOME` set — no herdr pane context or `HERDR_ENV` needed. The `agent prompt` call still sets `HERDR_ENV=1` in `process-environment` as cheap insurance (not verified context-less live, since it injects into a real session).
- **`herdr agent list` JSON shape:** `{"result":{"agents":[{"agent":"claude","agent_status":"working","cwd":"/…","pane_id":"wH:p1","workspace_id":"wH","terminal_title_stripped":"…","focused":true}, …],"type":"agent_list"}}`. `agent_status` is a STRING (`"working"`/`"idle"`/`"blocked"`/`"done"`/`"unknown"`); `pane_id` is a STRING. Pane IDs are ephemeral — never hardcode; always read live.
- **Handshake payload (exact):** `[emacs-bridge] connect {json}` where json has keys `server_name`, `socket`, `project_root`, `protocol` (=1).
- **This Emacs's descriptor** comes from Phase 1: `(cm/ai-registry-descriptor)` in `cm-ai-registry.el` (alist with `server_name`/`socket`/`project_root`). `cm-herdr.el` `(require 'cm-ai-registry)`.
- **`herdr agent prompt` is rejected (`agent_blocked`) if the target is `blocked`** — the bind command checks status and confirms before pushing to a blocked agent.
- Per-task test command: `emacs -batch -Q -L . -l ert -l tests/cm-herdr-tests.el -f ert-run-tests-batch-and-exit`. Full suite: `./tests/run-tests.sh`. Pristine output + byte-compile clean.

## File Structure

- **Create** `cm-herdr.el` — herdr discovery, `agent list` parse, handshake construction, `agent prompt` push, and the `cm/ai-bind-agent` command. `(provide 'cm-herdr)`.
- **Create** `tests/cm-herdr-tests.el` — ERT (pure parse/handshake/sort/label from fixtures; the interactive command via `cl-letf` mocking the shell helpers + `completing-read`; a `skip-unless` live `agent list` parse).
- **Modify** `init.el` — `(load (locate-user-emacs-file "cm-herdr") t)` near the AI section; bind `C-c a b` to `cm/ai-bind-agent`; add a cheat-sheet line.
- **Modify** `CLAUDE.md` — the agent-side `[emacs-bridge]` contract.

---

### Task 1: cm-herdr.el pure core — discovery, parse, handshake, label, sort

**Files:**
- Create: `cm-herdr.el`
- Test: `tests/cm-herdr-tests.el`

**Interfaces:**
- Produces: `cm/ai-herdr--available-p ()`, `cm/ai-herdr--parse-agent-list (json-string) -> list<plist>`, `cm/ai-herdr--this-emacs-descriptor () -> alist`, `cm/ai-herdr--handshake-payload (descriptor) -> string`, `cm/ai-herdr--candidate-label (agent-plist) -> string`, `cm/ai-herdr--sort-agents (agents this-root) -> list<plist>`.

- [ ] **Step 1: Write the failing test**

Create `tests/cm-herdr-tests.el`:

```elisp
;;; cm-herdr-tests.el --- Tests for cm-herdr  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-herdr)
(require 'json)

(defconst cm/herdr-test--fixture
  (concat "{\"id\":\"cli:agent:list\",\"result\":{\"type\":\"agent_list\",\"agents\":["
          "{\"agent\":\"claude\",\"agent_status\":\"idle\",\"cwd\":\"/home/jim/projects/other\",\"pane_id\":\"wF:p1\",\"workspace_id\":\"wF\"},"
          "{\"agent\":\"claude\",\"agent_status\":\"working\",\"cwd\":\"/home/jim/projects/emacs-again\",\"pane_id\":\"wH:p1\",\"workspace_id\":\"wH\"}"
          "]}}"))

(ert-deftest cm/herdr-parse-agent-list ()
  (let ((agents (cm/ai-herdr--parse-agent-list cm/herdr-test--fixture)))
    (should (= (length agents) 2))
    (should (equal (plist-get (car agents) :agent) "claude"))
    (should (equal (plist-get (nth 1 agents) :pane_id) "wH:p1"))
    (should (equal (plist-get (nth 1 agents) :agent_status) "working"))))

(ert-deftest cm/herdr-candidate-label ()
  (let ((a '(:agent "claude" :agent_status "idle" :cwd "/home/jim/projects/other" :pane_id "wF:p1")))
    (should (equal (cm/ai-herdr--candidate-label a) "claude · other · idle · wF:p1"))))

(ert-deftest cm/herdr-sort-floats-cwd-match ()
  (let* ((agents (cm/ai-herdr--parse-agent-list cm/herdr-test--fixture))
         (sorted (cm/ai-herdr--sort-agents agents "/home/jim/projects/emacs-again/")))
    ;; the emacs-again agent (wH:p1) floats to the top
    (should (equal (plist-get (car sorted) :pane_id) "wH:p1"))))

(ert-deftest cm/herdr-handshake-payload ()
  (let* ((desc '((server_name . "emacs-4242")
                 (socket . "/run/user/1000/emacs/emacs-4242")
                 (project_root . "/home/jim/projects/emacs-again/")))
         (s (cm/ai-herdr--handshake-payload desc)))
    (should (string-prefix-p "[emacs-bridge] connect " s))
    (let* ((json (substring s (length "[emacs-bridge] connect ")))
           (json-object-type 'plist) (json-key-type 'keyword)
           (p (json-read-from-string json)))
      (should (equal (plist-get p :server_name) "emacs-4242"))
      (should (equal (plist-get p :socket) "/run/user/1000/emacs/emacs-4242"))
      (should (equal (plist-get p :project_root) "/home/jim/projects/emacs-again/"))
      (should (equal (plist-get p :protocol) 1)))))

(provide 'cm-herdr-tests)
;;; cm-herdr-tests.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-herdr-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: cm-herdr`.

- [ ] **Step 3: Write minimal implementation**

Create `cm-herdr.el`:

```elisp
;;; cm-herdr.el --- herdr bind/push layer for the Emacs<->agent bridge  -*- lexical-binding: t; -*-
;;; Commentary:
;; `cm/ai-bind-agent' lists running herdr-managed agents (`herdr agent list'),
;; lets you pick one, and pushes this Emacs's socket handshake into it
;; (`herdr agent prompt <pane> "[emacs-bridge] connect {…}"'), so the chosen
;; agent gains a direct line back to THIS Emacs.  Explicit / cross-project
;; binding on top of Phase 1's automatic same-project registry.
;; See docs/plans/2026-08-28-emacs-agents-bridge-design.md (Section B).
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'cm-ai-registry)  ; for cm/ai-registry-descriptor (this Emacs's socket/project)

(defcustom cm/ai-herdr-executable "herdr"
  "Name or path of the herdr CLI."
  :type 'string :group 'tools)

(defun cm/ai-herdr--available-p ()
  "Return non-nil if the herdr CLI is on PATH."
  (and (executable-find cm/ai-herdr-executable) t))

(defun cm/ai-herdr--parse-agent-list (json-string)
  "Parse `herdr agent list' JSON-STRING into a list of agent plists."
  (let* ((json-object-type 'plist) (json-key-type 'keyword) (json-array-type 'list)
         (data (json-read-from-string json-string)))
    (plist-get (plist-get data :result) :agents)))

(defun cm/ai-herdr--this-emacs-descriptor ()
  "Return this Emacs's registry descriptor alist (server_name/socket/project_root)."
  (cm/ai-registry-descriptor))

(defun cm/ai-herdr--this-project-root ()
  "Return this Emacs's project root (slash-terminated), from the registry descriptor."
  (alist-get 'project_root (cm/ai-herdr--this-emacs-descriptor)))

(defun cm/ai-herdr--handshake-payload (descriptor)
  "Build the `[emacs-bridge] connect' handshake string from DESCRIPTOR (alist)."
  (format "[emacs-bridge] connect %s"
          (json-encode
           (list (cons 'server_name (alist-get 'server_name descriptor))
                 (cons 'socket (alist-get 'socket descriptor))
                 (cons 'project_root (alist-get 'project_root descriptor))
                 (cons 'protocol 1)))))

(defun cm/ai-herdr--candidate-label (agent)
  "A `completing-read' label for AGENT plist: agent · cwd-base · status · pane."
  (format "%s · %s · %s · %s"
          (plist-get agent :agent)
          (file-name-nondirectory
           (directory-file-name (or (plist-get agent :cwd) "")))
          (plist-get agent :agent_status)
          (plist-get agent :pane_id)))

(defun cm/ai-herdr--sort-agents (agents this-root)
  "Return AGENTS with any whose :cwd is within THIS-ROOT floated to the front."
  (let ((root (and this-root (file-name-as-directory (expand-file-name this-root)))))
    (cl-stable-sort
     (copy-sequence agents)
     (lambda (a _b)
       (and root
            (let ((cwd (plist-get a :cwd)))
              (and cwd (string-prefix-p root (file-name-as-directory
                                              (expand-file-name cwd))))))))))

(provide 'cm-herdr)
;;; cm-herdr.el ends here
```

Note: `cl-stable-sort` with a predicate that is true only for cwd-matches sorts matches before non-matches while preserving order otherwise (a match "precedes" a non-match; ties keep input order).

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-herdr-tests.el -f ert-run-tests-batch-and-exit`
Expected: PASS (4 tests). Then `emacs -batch -Q -L . -f batch-byte-compile cm-herdr.el` → no warnings; delete the `.elc`.

- [ ] **Step 5: Commit**

```bash
git add cm-herdr.el tests/cm-herdr-tests.el
git commit -m "cm-herdr: pure core (agent-list parse, handshake, label, cwd-sort)"
```

---

### Task 2: Live shell + the cm/ai-bind-agent command

**Files:**
- Modify: `cm-herdr.el`
- Test: `tests/cm-herdr-tests.el`

**Interfaces:**
- Consumes: Task 1.
- Produces: `cm/ai-herdr--agent-list () -> list<plist>|nil`, `cm/ai-herdr--push (pane text) -> plist(:exit :output)`, `cm/ai-herdr--push-ok-p (result) -> bool`, `cm/ai-bind-agent ()` (interactive).

- [ ] **Step 1: Write the failing test**

Append to `tests/cm-herdr-tests.el` (before `provide`):

```elisp
(ert-deftest cm/herdr-push-ok-p ()
  (should (cm/ai-herdr--push-ok-p '(:exit 0 :output "{\"type\":\"agent_prompted\"}")))
  (should-not (cm/ai-herdr--push-ok-p '(:exit 0 :output "{\"error\":\"agent_blocked\"}")))
  (should-not (cm/ai-herdr--push-ok-p '(:exit 1 :output ""))))

(ert-deftest cm/herdr-bind-agent-pushes-handshake ()
  ;; Stub the shell + UI: agent list from fixture, pick the working one, capture the push.
  (let (captured)
    (cl-letf (((symbol-function 'cm/ai-herdr--available-p) (lambda () t))
              ((symbol-function 'cm/ai-herdr--agent-list)
               (lambda () (cm/ai-herdr--parse-agent-list cm/herdr-test--fixture)))
              ((symbol-function 'cm/ai-herdr--this-emacs-descriptor)
               (lambda () '((server_name . "emacs-4242")
                            (socket . "/run/user/1000/emacs/emacs-4242")
                            (project_root . "/home/jim/projects/emacs-again/"))))
              ((symbol-function 'completing-read)
               (lambda (_p _c &rest _) "claude · emacs-again · working · wH:p1"))
              ((symbol-function 'cm/ai-herdr--push)
               (lambda (pane text) (setq captured (list pane text))
                 '(:exit 0 :output "{\"type\":\"agent_prompted\"}"))))
      (cm/ai-bind-agent)
      (should (equal (car captured) "wH:p1"))
      (should (string-prefix-p "[emacs-bridge] connect " (cadr captured)))
      (should (string-match-p "emacs-4242" (cadr captured))))))

(ert-deftest cm/herdr-bind-agent-blocked-confirm-declined ()
  ;; A blocked target with the user declining the y-or-n-p must NOT push.
  (let ((pushed nil)
        (blocked-fixture
         (concat "{\"result\":{\"agents\":[{\"agent\":\"claude\",\"agent_status\":\"blocked\","
                 "\"cwd\":\"/x\",\"pane_id\":\"wZ:p1\"}]}}")))
    (cl-letf (((symbol-function 'cm/ai-herdr--available-p) (lambda () t))
              ((symbol-function 'cm/ai-herdr--agent-list)
               (lambda () (cm/ai-herdr--parse-agent-list blocked-fixture)))
              ((symbol-function 'cm/ai-herdr--this-emacs-descriptor)
               (lambda () '((server_name . "e") (socket . "s") (project_root . "/x/"))))
              ((symbol-function 'completing-read) (lambda (&rest _) "claude · x · blocked · wZ:p1"))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function 'cm/ai-herdr--push) (lambda (&rest _) (setq pushed t) '(:exit 0 :output ""))))
      (should-error (cm/ai-bind-agent) :type 'user-error)
      (should-not pushed))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -batch -Q -L . -l ert -l tests/cm-herdr-tests.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `void-function cm/ai-herdr--push-ok-p` / `cm/ai-bind-agent`.

- [ ] **Step 3: Write the shell + command**

Insert into `cm-herdr.el` (before `provide`):

```elisp
(defun cm/ai-herdr--run (&rest args)
  "Run the herdr CLI with ARGS; return (:exit N :output STR).
Sets HERDR_ENV=1 as insurance (the 0.8.2 server accepts a context-less client)."
  (with-temp-buffer
    (let* ((process-environment (cons "HERDR_ENV=1" process-environment))
           (exit (apply #'call-process cm/ai-herdr-executable nil t nil args)))
      (list :exit exit :output (buffer-string)))))

(defun cm/ai-herdr--agent-list ()
  "Return the live herdr agent list as plists, or nil on failure."
  (when (cm/ai-herdr--available-p)
    (let ((res (cm/ai-herdr--run "agent" "list")))
      (when (= 0 (plist-get res :exit))
        (ignore-errors (cm/ai-herdr--parse-agent-list (plist-get res :output)))))))

(defun cm/ai-herdr--push (pane text)
  "Push TEXT to the herdr agent at PANE via `agent prompt'; return (:exit :output)."
  (cm/ai-herdr--run "agent" "prompt" pane text))

(defun cm/ai-herdr--push-ok-p (result)
  "Non-nil if a `cm/ai-herdr--push' RESULT indicates success."
  (and (= 0 (plist-get result :exit))
       (string-match-p "agent_prompted" (or (plist-get result :output) ""))))

;;;###autoload
(defun cm/ai-bind-agent ()
  "Pick a running herdr agent and push this Emacs's socket handshake to it."
  (interactive)
  (unless (cm/ai-herdr--available-p)
    (user-error "herdr not found on PATH"))
  (let ((agents (cm/ai-herdr--agent-list)))
    (unless agents (user-error "No herdr agents found"))
    (let* ((sorted (cm/ai-herdr--sort-agents agents (cm/ai-herdr--this-project-root)))
           (cands (mapcar (lambda (a) (cons (cm/ai-herdr--candidate-label a) a)) sorted))
           (choice (completing-read "Bind agent: " (mapcar #'car cands) nil t))
           (agent (cdr (assoc choice cands)))
           (pane (plist-get agent :pane_id))
           (status (plist-get agent :agent_status)))
      (when (and (equal status "blocked")
                 (not (y-or-n-p
                       (format "Agent %s is blocked; `agent prompt' may be rejected. Push anyway? "
                               pane))))
        (user-error "Aborted"))
      (let* ((payload (cm/ai-herdr--handshake-payload (cm/ai-herdr--this-emacs-descriptor)))
             (result (cm/ai-herdr--push pane payload)))
        (if (cm/ai-herdr--push-ok-p result)
            (message "cm/ai-bind-agent: pushed emacs-bridge handshake to %s" pane)
          (message "cm/ai-bind-agent: push to %s failed (%S)" pane result))))))
```

- [ ] **Step 4: Run tests + byte-compile + optional live check**

Run the focused suite (all pass; the bind tests use mocks — no real shelling). Then `batch-byte-compile cm-herdr.el` clean (delete .elc) and `./tests/run-tests.sh`.
Optional manual (only where a herdr server is up): `emacs -batch -Q -L . -l cm-herdr --eval '(princ (length (cm/ai-herdr--agent-list)))'` prints the live agent count — do NOT script any `cm/ai-herdr--push`, which injects into a real session.

- [ ] **Step 5: Commit**

```bash
git add cm-herdr.el tests/cm-herdr-tests.el
git commit -m "cm-herdr: live agent-list/push shell + cm/ai-bind-agent command"
```

---

### Task 3: Wire into init.el + the CLAUDE.md agent contract

**Files:**
- Modify: `init.el` (load form + `C-c a b` binding + cheat-sheet line)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `cm/ai-bind-agent` (Task 2). No new code contracts.

- [ ] **Step 1: Wire init.el**

In `init.el`, near where the other AI-bridge siblings load (the AI Writing Assistant section — after `cm-ai-bridge` is loaded, or beside the `cm-ai-registry` load), add:

```elisp
;; herdr bind/push layer — M-x cm/ai-bind-agent (see cm-herdr.el).
(when (load (locate-user-emacs-file "cm-herdr") t)
  (define-key cm/ai-map (kbd "b") #'cm/ai-bind-agent))  ; C-c a b
```

Note: bind on `cm/ai-map` (the `C-c a` prefix keymap defined in the AI section — confirm its exact variable name in init.el; it's the keymap `C-c a` is bound to). If the prefix map has a different variable name, use that; if bindings there use `(define-key MAP (kbd "…") …)`, match that form. Place this AFTER the prefix map is defined.

- [ ] **Step 2: Verify init.el**

Run: `emacs -batch -Q -L . --eval '(with-temp-buffer (insert-file-contents "init.el") (emacs-lisp-mode) (check-parens) (message "OK"))'` → `OK`.
Run: `emacs -batch -Q -L . -l cm-herdr --eval '(princ (if (commandp (quote cm/ai-bind-agent)) "ok" "missing"))'` → `ok`.

- [ ] **Step 3: Document the [emacs-bridge] contract in CLAUDE.md**

Under the AI Writing Assistant section of `CLAUDE.md`, add:

```markdown
### herdr bind/push — cm/ai-bind-agent + the [emacs-bridge] contract (cm-herdr.el)

`M-x cm/ai-bind-agent` (`C-c a b`) lists the running herdr-managed agents
(`herdr agent list`), lets Jim pick one (cwd-matching agent floated to the top),
and pushes this Emacs's socket handshake into that agent's input via
`herdr agent prompt <pane> …`. It is the explicit / cross-project complement to
Phase 1's automatic same-project registry. Degrades to a `user-error` if `herdr`
isn't on PATH; a `blocked` target prompts for confirmation (a blocked agent
rejects `agent prompt`).

**Agent-side contract (honor this in any Claude session):** when your input
contains a line

    [emacs-bridge] connect {"server_name":"emacs-<PID>","socket":"…","project_root":"…","protocol":1}

it means an Emacs is granting you a direct line back to it. Record the
`server_name`, and thereafter talk to THAT specific Emacs with
`emacsclient -s <server_name> -e '(…)'` (or `emacs-send --server <server_name> -e
'(…)'`) — using the packages protocol / write path from cm-ai-bridge.el. This is
how a cross-project bind reaches the right Emacs when the project registry alone
wouldn't resolve it.

Design + plan: `docs/plans/2026-08-28-emacs-agents-bridge-{design,phase3-plan}.md`.
```

Also add a cheat-sheet line in init.el's AI-section comment: `;;   C-c a b  cm/ai-bind-agent (pick a herdr agent, push this Emacs's socket to it)`.

- [ ] **Step 4: Verify**

Run: `grep -n "emacs-bridge" CLAUDE.md` → the contract present.
Run: `grep -n "cm/ai-bind-agent" init.el` → the binding + cheat-sheet line present.

- [ ] **Step 5: Commit**

```bash
git add init.el CLAUDE.md
git commit -m "init/docs: wire cm/ai-bind-agent (C-c a b) + the [emacs-bridge] agent contract"
```

---

## Self-Review

**Spec coverage (Section B):**
- `M-x cm/ai-bind-agent`: `herdr agent list` → completing-read (cwd-sorted) → `herdr agent prompt` push → Tasks 1-2.
- Handshake `[emacs-bridge] connect {server_name,socket,project_root,protocol}` sourced from `cm/ai-registry-descriptor` → Task 1 (`--handshake-payload`, `--this-emacs-descriptor`).
- Blocked-agent confirmation → Task 2 (`cm/ai-bind-agent`).
- `executable-find` graceful degrade → Tasks 1-2 (`--available-p`).
- HERDR_ENV insurance on the CLI call → Task 2 (`--run`).
- Agent-side `[emacs-bridge]` behavioral contract → Task 3 (CLAUDE.md).
- Keybinding `C-c a b` → Task 3.

**Placeholder scan:** none — every step has concrete code or an exact command. (Task 3 Step 1 asks the implementer to confirm the exact `C-c a` prefix-map variable name in init.el rather than hardcoding a possibly-wrong name — a deliberate locate-by-fact instruction, not a placeholder.)

**Type consistency:** agent plists use `:agent`/`:agent_status`/`:cwd`/`:pane_id` (keyword keys from `json-read-from-string` with `:key-type keyword`) consistently across parse, label, sort, and the command. `--push` returns `(:exit N :output STR)` consumed by `--push-ok-p` and the command. `--handshake-payload` consumes the `cm/ai-registry-descriptor` alist (symbol keys `server_name`/`socket`/`project_root`) — matches Phase 1's descriptor exactly.
