# Agentic gptel (`gptel-agent`) Implementation Plan

> **⚠️ ABANDONED (2026-08-28).** The whole in-Emacs LLM line — `gptel`,
> `gptel-agent`, `gptel-magit`, and `macher` — was **removed from the config** on
> 2026-08-28. This plan is retained only as a record of a tried-and-rejected
> experiment; it no longer describes anything in the config.
>
> **Why (a shift in direction, not a rejection of the idea):** driving the models
> from *inside* Emacs doesn't replace the stronger external agent harnesses
> (Claude Code, Codex, …). The direction for "emacs+agents" is to **compose with
> those external harnesses** while **exposing Emacs's internal tooling to them** —
> the inverse of gptel's drive-the-model-from-Emacs model. The kept `cm/ai-*`
> Claude-Code bridge is the seed of that approach.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in agentic mode to the in-Emacs `gptel` client via karthink's first-party `gptel-agent`, with full in-project autonomy (git as the undo net).

**Architecture:** Pure configuration in `init.el` — a `use-package gptel-agent` block after the existing `gptel`/`gptel-magit` blocks, one small `cm/gptel-plan` command, two `cm/gptel-map` bindings, and doc updates. `gptel-agent` supplies the tools/prompts/sub-agents as a gptel *preset*; nothing about plain gptel chat changes. Full autonomy is the plain-gptel variable `gptel-confirm-tool-calls` set to nil.

**Tech Stack:** Emacs 30.2, straight.el + use-package, gptel, gptel-agent (new dep, MELPA), project.el.

**Spec:** `docs/plans/2026-08-24-agentic-gptel-design.md`

## Global Constraints

- **`cm/` prefix** for all custom functions/vars (`cm` = corruptmemory).
- **Keybindings use `(define-key cm/gptel-map (kbd "X") #'cmd)`** — the existing idiom in this file, not `keymap-set`.
- **Backend stays tool-capable** (Claude/OpenAI/OpenRouter); the Perplexity backend has no tool use.
- **No push** — commit directly to `master`; push only when the user asks.
- **Verification is batch-load assertions, not ERT.** This is configuration with no pure logic of our own; the design doc's Testing section establishes batch-load + a (manual) live smoke test as the verification, mirroring how the rest of `init.el` config is checked. Each task's "test" is an `emacs --batch … -l init.el` assertion run.
- **gptel prerequisite:** gptel-agent needs a current gptel. Install against the current one first; only if it errors on a missing function, run `M-x straight-pull-package RET gptel` and re-verify.

**Batch-verify harness** (used in every task, adjust the `--eval`):

```bash
emacs --batch --init-directory=/home/jim/.config/emacs -l init.el \
  --eval '(princ "…assertions…")' 2>&1 | tail -30
```

---

### Task 1: `gptel-agent` block — install, full autonomy, `C-c g A`

**Files:**
- Modify: `init.el` — insert a new block after the `gptel-magit` block (currently ends at line 2581, before the blank line preceding the cheat sheet at 2583).
- Modify: `init.el:2513-2519` — the gptel header comment's "no agentic capability" claim.
- Modify: `init.el:2610-2616` — the keybinding cheat sheet (add the `C-c g A` line).

**Interfaces:**
- Consumes: `cm/gptel-map` (defined `init.el:2567`), `gptel` (loaded above).
- Produces: package `gptel-agent` installed; command `gptel-agent` bound to `C-c g A`; `gptel-confirm-tool-calls` set to nil; the `gptel-agent`/`gptel-plan` presets registered in `gptel--known-presets`.

- [ ] **Step 1: Insert the `gptel-agent` use-package block** after the `gptel-magit` block (after `init.el:2581`):

```elisp

;;;; gptel-agent — agentic mode for gptel (files/Bash/Emacs-introspection).
;; First-party (karthink).  Opt-in: plain `C-c g' chat stays the default; agent
;; mode is entered via `C-c g A' (or an `@gptel-agent' prompt token).  Full
;; autonomy: `gptel-confirm-tool-calls' nil makes tool calls run WITHOUT
;; per-call confirmation, overriding even the packaged agent's `:confirm t'
;; tools (the confirm `cond' in gptel-request.el short-circuits when the var is
;; nil) — reversibility is delegated to git/undo/magit ("going back in time is
;; what git is for").  We set the plain-gptel variable rather than forking the
;; packaged gptel-agent.md, whose long upstream system prompt we don't want to
;; drift from.  Requires a current gptel (README): if the agent errors on a
;; missing function, `M-x straight-pull-package RET gptel'.  Keep the backend on
;; a tool-capable model (Claude/OpenAI/OpenRouter) — Perplexity has no tool use.
;; Note: agent mode is materially more token-hungry than plain gptel.
(use-package gptel-agent
  :straight t
  :after gptel
  :init
  (setq gptel-confirm-tool-calls nil)   ; full autonomy; git is the undo net
  :config
  (gptel-agent-update)                  ; load agent specs, register presets/tools
  (define-key cm/gptel-map (kbd "A") #'gptel-agent))  ; C-c g A → agent session
```

- [ ] **Step 2: Fix the header comment** — replace `init.el:2516-2519` text:

Old:
```
;; plain multi-backend chat client for quick in-buffer Q&A/rewrites and an
;; Org-mode research notebook — no agentic/file-editing capability, no
;; overlap in job. Tool-use/MCP integration deliberately deferred; this is
;; chat + rewrite + context-add only.
```
New:
```
;; plain multi-backend chat client for quick in-buffer Q&A/rewrites and an
;; Org-mode research notebook. The plain client is chat + rewrite +
;; context-add only; agentic capability (file/Bash/Emacs-introspection) lives
;; in the separate gptel-agent block below, opt-in via C-c g A. MCP wiring is
;; still deferred (see that block and CLAUDE.md).
```

- [ ] **Step 3: Add the cheat-sheet line** — after `init.el` cheat-sheet line `;;   C-c g m  gptel-menu …` (2615), insert:

```
;;   C-c g A  gptel-agent (start an agentic session in this project)
```

- [ ] **Step 4: Batch-verify** the block loads, installs the package, sets autonomy, registers the preset, and binds `A`:

Run:
```bash
emacs --batch --init-directory=/home/jim/.config/emacs -l init.el \
  --eval '(princ (format "FEATUREP=%s CONFIRM=%s ABIND=%s PRESET=%s"
                   (featurep (quote gptel-agent))
                   gptel-confirm-tool-calls
                   (lookup-key cm/gptel-map (kbd "A"))
                   (and (assq (quote gptel-agent) gptel--known-presets) t)))' 2>&1 | tail -20
```
Expected: `FEATUREP=t CONFIRM=nil ABIND=gptel-agent PRESET=t`.
If instead an error mentions a missing/void gptel function → run `emacs --batch --init-directory=/home/jim/.config/emacs --eval '(progn (require (quote straight)) (straight-pull-package "gptel"))'`, then re-run the verify.

- [ ] **Step 5: Commit**

```bash
git add init.el
git commit -m "gptel-agent: agentic mode for gptel (full-auto, C-c g A)"
```

---

### Task 2: `C-c g P` — read-only planning session (`cm/gptel-plan`)

**Files:**
- Modify: `init.el` — add a `cm/gptel-plan` defun + its binding immediately after the `gptel-agent` block from Task 1.
- Modify: `init.el` cheat sheet — add the `C-c g P` line.

**Interfaces:**
- Consumes: `gptel-agent` (command from the installed package; accepts `(gptel-agent PROJECT-DIR AGENT-PRESET)` — `gptel-agent.el:665`), `project-current`/`project-root`, `cm/gptel-map`.
- Produces: command `cm/gptel-plan` bound to `C-c g P`.

- [ ] **Step 1: Add the command + binding** after the `gptel-agent` block's closing paren:

```elisp

(defun cm/gptel-plan ()
  "Start a read-only `gptel-plan' planning session in the current project.
Like `gptel-agent' (\\[gptel-agent], C-c g A) but loads the read-only planning
preset: read-only filesystem tools, instructed to produce a systematic plan of
action rather than edit.  Switch to the full agent mid-session with the
[Plan]/[Agent] button in the header line."
  (interactive)
  (gptel-agent (if-let* ((proj (project-current)))
                   (project-root proj)
                 default-directory)
               'gptel-plan))
(define-key cm/gptel-map (kbd "P") #'cm/gptel-plan)  ; C-c g P → planning session
```

- [ ] **Step 2: Add the cheat-sheet line** — after the `C-c g A` line inserted in Task 1:

```
;;   C-c g P  cm/gptel-plan (read-only planning session; toggle to agent in header)
```

- [ ] **Step 3: Batch-verify** the command exists and is bound:

Run:
```bash
emacs --batch --init-directory=/home/jim/.config/emacs -l init.el \
  --eval '(princ (format "PLANFN=%s PBIND=%s"
                   (fboundp (quote cm/gptel-plan))
                   (lookup-key cm/gptel-map (kbd "P"))))' 2>&1 | tail -20
```
Expected: `PLANFN=t PBIND=cm/gptel-plan`.

- [ ] **Step 4: Commit**

```bash
git add init.el
git commit -m "gptel-agent: C-c g P read-only planning session (cm/gptel-plan)"
```

---

### Task 3: Documentation — CLAUDE.md + README

**Files:**
- Modify: `CLAUDE.md` — the `## gptel (general LLM chat client)` section.
- Modify: `README.md` — the gptel note, if one exists (grep first; if none, skip and record that in the commit body).

**Interfaces:** none (docs only).

- [ ] **Step 1: CLAUDE.md — rewrite the opening framing.** In the `## gptel` section, the intro says gptel "has no agentic/file-editing capability" and "Tool-use/MCP integration was deliberately left out." Replace those two claims with: gptel's *plain* client is chat/rewrite/notebook, and **agentic capability now lives in the separate `gptel-agent` layer** (opt-in), while MCP/tool-collection bridging remains deferred. Keep the rest of the section (backends, `:key` gotcha, auth-source) intact.

- [ ] **Step 2: CLAUDE.md — add a `### Agent mode (gptel-agent)` subsection** documenting:
  - What it is: first-party agent preset — web, local files read/write/edit, Bash, Emacs state (docs + Elisp eval), and `executor`/`researcher`/`introspector` sub-agents; opt-in via `C-c g A` or `@gptel-agent`.
  - **Full-autonomy posture:** `(setq gptel-confirm-tool-calls nil)` — no per-call confirms; git/undo/magit are the safety net. Note the drift-avoidance reason for using the variable rather than forking `gptel-agent.md`.
  - Project scoping is ambient (`default-directory` = project root); backend must be tool-capable (not Perplexity); token-hungry; needs a current gptel (`straight-pull-package gptel` if it errors).
  - Bindings: `C-c g A` (agent session), `C-c g P` (`cm/gptel-plan`, read-only planning; header-line toggle to switch).
  - **Deferred (additive, coexist as presets):** `macher` — **until after Emacs 31 lands** (its `diff-apply-buffer` patch-apply mishandles new/deleted files on Emacs 30.x; fixed in 31 — cross-ref `docs/emacs-31-migration.md`); `mcp.el` bridging incl. a future open-brain MCP category; custom sub-agents mirroring `.claude/agents`.

- [ ] **Step 3: CLAUDE.md — update the keybindings list** in that section: add `C-c g A` and `C-c g P` alongside the existing `C-c g g/s/r/a/m`.

- [ ] **Step 4: CLAUDE.md — update the "Not wired up (deliberately deferred)" list**: tool-calling is now wired (via gptel-agent); keep MCP/`mcp.el` and auto-`gptel-mode` deferred; add macher (post-Emacs-31).

- [ ] **Step 5: README** — `grep -n gptel README.md`; if a gptel section exists, add a one-line "agent mode: `C-c g A` / planning `C-c g P` (gptel-agent)" note. If none, skip.

- [ ] **Step 6: Verify** the config still loads clean after doc edits (docs don't affect load, but confirm nothing was edited in the wrong file):

Run:
```bash
emacs --batch --init-directory=/home/jim/.config/emacs -l init.el \
  --eval '(princ "INIT-LOADED-OK")' 2>&1 | tail -5
```
Expected: ends with `INIT-LOADED-OK`.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document gptel-agent agentic mode (reverses the no-agentic note)"
```

---

## Self-Review

**Spec coverage** (each design decision → task):
- Spine = gptel-agent → Task 1. ✅
- Full autonomy via `gptel-confirm-tool-calls nil` → Task 1 (verified against source). ✅
- Project scoping ambient / git net → inherent (no task needed; documented Task 3). ✅
- Backend default claude-sonnet-5, Perplexity excluded → unchanged default; documented Task 1 comment + Task 3. ✅
- Opt-in only → Task 1 (separate block, no plain-chat change). ✅
- Keybindings `C-c g A`/`C-c g P` → Tasks 1 & 2. ✅
- Prerequisite bleeding-edge gptel → Task 1 conditional pull. ✅
- Why tools were empty → documented Task 3. ✅
- macher deferred until Emacs 31 → documented Task 3. ✅
- Affected files (init.el, CLAUDE.md, README) → all covered. ✅

**Placeholder scan:** none — all code blocks are concrete; the one runtime conditional (pull gptel only on error) has its exact command.

**Type/name consistency:** `cm/gptel-plan`, `cm/gptel-map`, `gptel-agent`, `gptel-plan`, `gptel-confirm-tool-calls` used identically across tasks. `gptel-agent` arity `(PROJECT-DIR AGENT-PRESET)` matches `gptel-agent.el:665`.

## Out of scope

macher, mcp.el/open-brain bridge, custom sub-agents, any out-of-project write guard — per the design doc.
