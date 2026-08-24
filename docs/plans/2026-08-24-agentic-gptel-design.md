# Agentic gptel (`gptel-agent`) — Design

**Date:** 2026-08-24
**Status:** Approved 2026-08-24. Implementation plan pending (writing-plans).
Not yet implemented.

## Goal

Give the in-Emacs `gptel` client an **agentic mode** that operates like
`claude-code` / `codex` *without leaving Emacs*: the LLM can read/write/edit
files, run Bash, grep/search the project, evaluate Elisp, and inspect Emacs
state — iterating autonomously inside the current `project.el` project. Today
`gptel` here is chat + rewrite only; the `-t Use tools` toggle is live but
`gptel-tools` is empty, so the toggle does nothing (see "Why tools were empty"
below).

The spine is **`gptel-agent`** — the first-party "agent mode for gptel" by
karthink (gptel's own author), on MELPA. It ships the tools, the system prompts,
and a Claude-Code-shaped **sub-agent** model, and it tracks gptel's own
evolution.

## Workflow being served

Shaped by the user's actual habits, not a generic IDE model:

- **`claude-code` is already the heavy agent.** The long-lived Claude Code CLI
  session does the big autonomous work. Agentic gptel is *not* meant to replace
  it — it is the "stay inside Emacs" agent for in-editor tasks.
- **The one thing the CLI structurally cannot do:** operate on *live Emacs
  state* — unsaved buffers, buffer-local context, Emacs introspection, Elisp
  eval. That is agentic gptel's real differentiator, not raw file editing.
- **Different backends, optionally.** gptel is multi-backend; the agent can run
  on Claude / OpenAI / OpenRouter tool-capable models, not only Anthropic.
- **Full autonomy; git is the undo stack.** The user's explicit posture: no
  confirmation prompts — "going back in time is what git is for." Reversibility
  is delegated to version control (plus Emacs `undo` and `magit`).
- **Ephemeral Emacs, `project.el`-centric.** Instances come and go; project
  identity comes from `project-current`, which already anchors every `cm-project-*`
  library here.
- **Opt-in, never ambient.** Plain `C-c g` chat/rewrite stays the default;
  agent mode is entered explicitly.

## Research & validation summary

**The landscape (2026).** Four coexisting building blocks, all expressed as
gptel *presets* / tools (so they compose, they don't compete):

| Layer | What it is | Role here |
|---|---|---|
| `gptel-make-tool` (gptel core) | The primitive: `:name :function :description :args :category :confirm :include :async`. gptel runs a real multi-step tool loop (feeds results back, model keeps calling). | Foundation everything is built on. |
| **`gptel-agent`** (karthink, MELPA) — *first-party* | Ready preset: web (search/fetch), local files read/write/edit, Bash, Emacs state (docs + Elisp eval), plus `executor`/`researcher`/`introspector` sub-agents that don't share context. | **Chosen spine.** |
| `macher` (kmontag, MELPA) | Project-aware multi-file editing on gptel; edits stay in an in-memory struct and emit a **unified diff into a review buffer** — apply-before-write. Presets `@macher` / `@macher-ro`. | Deferred (additive). The "safe review-first editing" path, matching the existing `cm/ai-*` diff-accept taste. |
| `mcp.el` + `llm-tool-collection` | Bridge MCP servers (filesystem/git/shell/fetch) into gptel; curated ready-made file/buffer/shell tools. | Deferred (additive). Future **open-brain** MCP bridge lives here. |

**Why `gptel-agent` for the spine:** first-party (moves with gptel), curated and
safety-sane by default, and — decisively — its "agent = bundle of (prompt +
tools + harness)" and Markdown/Org sub-agent specs (YAML front-matter:
`name`/`description`/`tools` + system prompt) are *structurally the same* as
Claude Code's `.claude/agents/*.md`. It is the shortest path to a familiar
agent model inside Emacs.

**Honest caveat (documented, not fatal).** A real-world setup (Martin Sukaný,
2026-03) reports gptel's agent loop *"doesn't handle more than five or six tool
calls reliably yet"* on complex tasks and pivots to Aidermacs for big multi-file
changes. That was months before this writing and gptel-agent has iterated since,
so it is a **"verify live,"** not a "don't bother" — and it reinforces the
division of labor above: heavy autonomous work stays with the `claude-code` CLI.

**Source-grounded facts** (read from `gptel-agent.el` / `gptel.org` this
session), which the design relies on:

- Sessions bind `default-directory` to the project root (`gptel-agent.el:687`);
  the Bash tool executes there (`:962`). **Project scoping is ambient** — not
  something we build.
- Mutating tools (Bash, Write, …) carry `:confirm t` (`:2234`). That per-tool
  slot is the only thing gating full autonomy.
- Confirmation is a **preset key** `:confirm-tool-calls` (`:425,:538`), and
  front-matter maps 1:1 to preset keys (YAML `false` → nil). So autonomy is a
  knob, not a fork.
- Agent files are keyed by `name` with last-writer-wins across `gptel-agent-dirs`
  — but the packaged `gptel-agent.md` carries a **long** upstream system prompt,
  so copying it to flip one boolean is a **drift trap** (cf. the odin-mode
  stale-clone saga). The README points instead at the plain-gptel variable
  `gptel-confirm-tool-calls` — the drift-proof lever.

## Decisions (from brainstorming)

1. **Spine = `gptel-agent`.** `macher`, `mcp.el`/open-brain bridge, and custom
   sub-agents are **deferred** — all additive, all coexist as presets/tools, none
   blocks this pass.
2. **Full autonomy via `(setq gptel-confirm-tool-calls nil)`** — the
   README-sanctioned, drift-proof lever. We do **not** fork `gptel-agent.md`.
   *Alternative on record:* if plain-chat tool use should still confirm later,
   scope it to the agent preset instead (re-apply `gptel-make-preset 'gptel-agent`
   after `gptel-agent-update` with `:confirm-tool-calls nil`, reading the current
   packaged plist so no prompt drift). Not needed now — the posture is "full
   autonomy, period."
3. **Project scoping is ambient; git is the net.** `default-directory` = project
   root already scopes Bash and relative file ops. No out-of-project guard is
   added; escaping the repo requires an explicit absolute path, and recovery is
   git/`undo`/`magit`. Documented, not guarded.
4. **Backend/model = existing default `claude-sonnet-5`** (Anthropic, tool-
   capable), switchable per-session from the gptel menu. Perplexity's backend is
   excluded from agent use (not a tool-use backend).
5. **Opt-in only.** Chat/rewrite stays default; agent is entered via a binding or
   an `@gptel-agent` prompt token.
6. **Keybindings under the existing `cm/gptel-map` (`C-c g`):** `C-c g A` →
   `gptel-agent` (start a session in the current project); `C-c g P` → apply the
   read-only `gptel-plan` preset (planning without edits). Existing
   `g g/s/r/a/m` untouched.
7. **Prerequisite: bleeding-edge gptel.** gptel-agent's README requires a current
   gptel, "not just the latest stable release." Step zero is
   `straight-pull-package gptel` + a load sanity-check. Token cost (materially
   higher than plain gptel) is documented.

## Architecture

No new sibling library — this is **configuration**, added to the existing gptel
area of `init.el`, purely additive. Three layers:

- **gptel** *(present)* — the client, backends, `cm/gptel-map`.
- **`gptel-agent`** *(new dependency, straight/MELPA)* — the preset layer: tools,
  system prompts, sub-agents, the `gptel-agent` / `gptel-plan` presets.
- **project.el** *(built-in, already in use)* — project identity and the ambient
  `default-directory` the agent's tools operate within.

## Configuration (the `init.el` block)

Placed immediately after the existing `gptel` / `gptel-magit` blocks:

```elisp
;;;; gptel-agent — agentic mode for gptel (files/Bash/Emacs-introspection).
;; First-party (karthink).  Opt-in: plain `C-c g' chat stays the default; agent
;; mode is entered via `C-c g A' or an `@gptel-agent' prompt token.  Requires a
;; BLEEDING-EDGE gptel (README): `straight-pull-package gptel' if the agent errors.
(use-package gptel-agent
  :straight t
  :after gptel
  :init
  ;; Full autonomy: no per-call confirmation.  Reversibility is delegated to
  ;; git/undo/magit ("going back in time is what git is for").  This is the
  ;; README-sanctioned lever; we deliberately do NOT fork the packaged
  ;; gptel-agent.md to flip its `:confirm t' tools (that would drift off
  ;; upstream's system prompt).
  (setq gptel-confirm-tool-calls nil)
  :config
  (gptel-agent-update)                  ; load agent specs, register presets/tools
  (keymap-set cm/gptel-map "A" #'gptel-agent)    ; C-c g A → start an agent session
  ;; C-c g P → apply the read-only `gptel-plan' preset.  Exact target confirmed
  ;; at implementation (named command vs. a one-line preset-apply lambda):
  (keymap-set cm/gptel-map "P" #'cm/gptel-plan))
```

**Confirmation mechanism — verify at implementation.** The exact combination of
`gptel-confirm-tool-calls` (nil/t/`auto`) with a tool's `:confirm t` slot must be
read from gptel source before shipping: the intent is *nil ⇒ never confirm,
overriding per-tool `:confirm`*. If nil does **not** override per-tool `:confirm`,
fall back to the preset-scoped re-apply (Decision 2, alternative). The `C-c g P`
binding target (`gptel-plan` preset application) is likewise confirmed against
the installed API at implementation — presets are applied through gptel's menu /
`gptel--apply-preset`, so the binding may wrap a one-line lambda rather than a
named command.

## Why tools were empty (answering the screenshots)

`-t Use tools` was **on**, but `gptel-tools` was unpopulated — nothing had
*registered* any tools. Applying the `gptel-agent` preset (via `C-c g A` or
`@gptel-agent`) is the missing half: it populates the file/Bash/introspection
tools and the sub-agent `Agent` tool. The toggle was a loaded gun with no rounds
in the magazine.

## Error handling & edge cases

- **Not in a project** → `gptel-agent` falls back to `default-directory`; the
  agent still runs, just unscoped to a project root. Expected, harmless.
- **A non-tool-use backend selected** (e.g. Perplexity) → tool calls fail; keep
  the agent on Claude/OpenAI/OpenRouter. Documented in the block comment.
- **Full-autonomy blast radius** → an explicit absolute path can write outside
  the repo (git won't cover that). Accepted per the user's posture; **documented**
  (the repo's no-silent-surprise standard), not guarded.
- **Loop robustness on large tasks** → per the Sukaný caveat; heavy multi-file
  work stays with the `claude-code` CLI. Documented expectation, not a bug.
- **gptel not bleeding-edge** → agent may error on load/first use; the
  prerequisite `straight-pull-package gptel` is the fix, called out in the block.
- **Token cost** → materially higher than plain gptel; documented.

## Testing

No ERT suite: this is configuration with no pure logic of our own to test
(unlike `cm-project-*`, which shipped ERT for real functions). Verification is:

1. **Batch load** — `emacs --batch --init-directory=~/.config/emacs -l init.el`
   loads clean; `(featurep 'gptel-agent)` is non-nil; the `gptel-agent` preset is
   registered.
2. **Live smoke test** (on a real frame): `C-c g A` opens a project session and
   `gptel-tools` is now populated; a **read**, an **edit**, and a **Bash** run all
   execute **without a confirmation prompt** and act within the project root;
   `C-c g P` yields a plan without editing.

## Out of scope

- `macher` (review-before-apply multi-file editing) — deferred **until after
  Emacs 31 lands** (user decision, 2026-08-24). Rationale: macher's patch-apply
  step leans on `diff-apply-buffer`, which Emacs 30.x mishandles for patches that
  create or delete files (macher FAQ / macher#45); the fix ships in Emacs 31. So
  macher is worth adding precisely when this config moves to 31 — a natural item
  for `docs/emacs-31-migration.md`. Additive and coexists with `gptel-agent` when
  it lands (`@macher` vs `@gptel-agent`, chosen per-task).
- `mcp.el` bridging / the **open-brain** MCP tool category — deferred, additive.
- Custom sub-agents mirroring `.claude/agents` — deferred; the built-in
  `executor`/`researcher`/`introspector` are enough for v1.
- Any out-of-project write guard (git is the net, by decision).
- Changing plain-chat gptel behavior — the agent is strictly additive/opt-in.

## Affected files

- **Edit:** `init.el` — the `gptel-agent` `use-package` block + the two
  `cm/gptel-map` bindings.
- **Docs:** `CLAUDE.md` — rewrite the gptel section's "no agentic capability /
  tool-use deliberately left out" paragraph to document agent mode, the
  full-autonomy posture, `C-c g A` / `C-c g P`, and the deferred additions.
  `README.md` — a short "gptel agent mode" note if the gptel feature is surfaced
  there.
- **New:** none.
```
