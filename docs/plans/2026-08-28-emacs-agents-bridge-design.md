# Emacs ↔ Agents Bridge — Design

**Date:** 2026-08-28
**Status:** Design — approved section-by-section in brainstorming (2026-08-28).
Pending spec review, then an implementation plan (writing-plans). No code yet.

## Problem

Jim runs **ephemeral, GUI Emacs instances** — typically one per project, no
daemon. Each already runs a **per-instance, PID-named emacsclient server**
(`emacs-<PID>`), and the `cm/ai-*` bridge drives it via `scripts/emacs-send -e
'(expr)'`. Two gaps:

1. **"Which Emacs?"** With several instances alive, `emacs-send` resolves the
   target via `~/.emacs-last-used` — a last-used *guess*. An agent working in
   project X has no reliable way to reach *X's* Emacs.
2. **Only a read/query channel.** The remote `cm/ai-*` functions return data;
   there is no first-class, typed way for an agent to (a) get structured replies
   it can rely on, or (b) *modify* buffer contents under review.

The enabling realization from this session: **herdr** (the Rust terminal
multiplexer Jim runs agents inside — see the `herdr-agent-orchestration` memo)
exposes a socket/CLI API that can act as a live **directory of running agents**
and a **delivery bus** into a specific agent's input. That lets Emacs discover
agents and hand a chosen one a direct line back to *this* Emacs.

This is the first concrete build in the "emacs+agents" direction: **compose with
an external harness and expose Emacs's internals to it**, rather than driving a
model from inside Emacs (the rejected gptel approach).

## Decisions locked in brainstorming

| Question | Decision |
|---|---|
| Transport | **Keep** the existing per-instance emacsclient server. "No emacs server" meant *no more last-used roulette*, not a new transport. All of `cm/ai-*` (`emacsclient -e`) is reused. |
| Where Emacs runs | **GUI Emacs, outside herdr** (a WM window, not a herdr pane). herdr can't see it → the two directions need different mechanisms. |
| Scope shape | **Composed, phased**: a herdr-free project registry as the substrate, a herdr selection/push layer on top, sharing one `{project-identity + socket}` record. |
| Agent target | **Claude only, for now.** Lets the reply protocol prefer native elisp over a lowest-common-denominator format. Multi-harness (JSON envelope) is a deferred YAGNI. |
| Write-path apply ceremony | **DWIM by scope** — auto-apply small edits, review-gate large/scattered ones. |

## Architecture

Two layers that must stay distinct:

- **Rendezvous / directory** — solves *identity* ("which Emacs / which agent").
  Split by direction because herdr can't see a GUI Emacs:
  - *Agent → finds the right Emacs*: a **project-keyed registry** (herdr-free).
  - *Emacs → binds/grants an agent*: **herdr** (`agent list` to pick, `agent
    prompt` to push this Emacs's socket to the chosen agent).
- **Transport** — the existing per-instance **emacsclient server**. Once the
  right socket is known, everything (queries + edits) rides `emacsclient -s
  <socket> -e '(expr)'`. herdr adds a *selector*, never a new pipe.

Over that transport rides a **typed "packages" reply protocol** (both read and
write), designed independently of discovery.

```
 ┌─────────────┐   herdr agent list / prompt   ┌──────────────┐
 │  GUI Emacs  │ ─────────────  (Phase 3) ────▶ │   Agent      │
 │ (project X) │                                │ (Claude Code)│
 │             │ ◀── registry lookup (Phase 1) ─│  in cwd X    │
 │  emacsclient│                                │              │
 │  server     │ ◀═══ emacsclient -s <sock> -e ═│  packages    │
 └─────────────┘        (Phase 2 channel)        └──────────────┘
```

---

## Section A — Registry substrate (Phase 1: the "which Emacs" solver)

Herdr-free. Makes same-project attach automatic.

**Registry:** a directory beside the existing exchange dir, **one descriptor per
live Emacs**, keyed by the already-unique PID server-name (*not* by project, so
two Emacs on one project don't collide):

```
~/.emacs-ai/instances/emacs-12345.json
{
  "project_root": "/home/jim/projects/emacs-again",
  "server_name":  "emacs-12345",
  "socket":       "/run/user/1000/emacs/emacs-12345",   // emacsclient -s target
  "pid":          12345,
  "frame_title":  "emacs-again — init.el",
  "started":      "2026-08-28T20:14:03Z"
}
```

**Register / deregister** (`cm-ai-registry.el`, hooked from `init.el` after
`server-start`):
- On startup, `cm/ai-registry-register` writes the descriptor with an **atomic
  temp+rename**. Project root captured once at launch: `(or (car (project-roots
  (project-current))) default-directory)` — valid because Emacs is launched *in*
  the project dir.
- `kill-emacs-hook` deletes it. On register, sweep the dir and drop descriptors
  whose PID is dead — same self-healing as today's stale-socket cleanup.

**Resolve** (agent side, extend `scripts/emacs-send`): given the agent's cwd,
match live descriptors whose `project_root` is an **ancestor-or-equal** of cwd,
then pick **most-specific root → newest**. So `emacs-send -e '(…)'` run anywhere
under `~/projects/emacs-again` targets that project's Emacs with no flags. Escape
hatches: `--project <root>`, `--server <name>`, `--list`. On no match, fall back
to today's `~/.emacs-last-used` (back-compat) with a warning.

**Concurrency:** one file per instance + atomic writes ⇒ no locking; a reader
hitting a half-written or stale file just skips it.

*Rationale:* keying by server-name with `project_root` *inside* the record makes
resolution a pure scan-and-filter — it handles zero, one, or several Emacs per
project, and "pick newest" falls out for free. A project-keyed filename would
force a last-writer-wins collision exactly where two Emacs are open on one repo.

---

## Section B — herdr bind/push layer (Phase 3: explicit, cross-project binding)

With Phase 1, same-project attach is automatic, so Phase 3 exists mainly for the
case the registry *can't* cover: binding a specific agent not in your cwd, or
choosing among several. It only has to *deliver the socket path*; everything
downstream is the shared channel.

**`M-x cm/ai-bind-agent`** (`cm-herdr.el`, `executable-find`'d — degrades
politely if herdr is absent):
1. Shell `env HERDR_ENV=1 herdr agent list`, parse JSON, `completing-read` with
   rich annotations (`claude · emacs-again · working · w3:p1`), sorted so the
   cwd-matching agent floats to the top.
2. On pick, push the handshake into that agent's input:
   ```
   herdr agent prompt <pane_id> \
     '[emacs-bridge] connect {"socket":"/run/user/1000/emacs/emacs-12345",
      "server_name":"emacs-12345","project_root":"/home/jim/projects/emacs-again",
      "protocol":1}'
   ```
3. The agent sees the `[emacs-bridge]` sentinel next turn, records the socket,
   and thereafter uses `emacsclient -s <socket> -e …` — the same channel as
   Phase 1.

**Constraints handled:**
- **Agent behavioral contract.** The agent must recognize the `[emacs-bridge]`
  sentinel and act on it — a **CLAUDE.md** stanza (and optionally a small skill)
  so any Claude session honors it. This is the one place the layer reaches into
  agent behavior.
- **`agent prompt` consumes a turn** (it submits, interrupting the agent) and is
  **rejected with `agent_blocked` if the target is `blocked`**. The command
  checks status, prefers an `idle` target, warns on `blocked`. Binds are
  deliberate and rare, so a spent turn is acceptable.
- **Confirmation deferred** for v1: the agent's first `emacsclient` call *is* the
  confirmation; no ack protocol yet.

**Implementation spike (blocking for Phase 3):** confirm a GUI-external Emacs
(env-injected `HERDR_ENV=1`, no herdr caller-context) can actually drive `agent
list` and `agent prompt <pane>`. The CLI guard is env-only, but the *server's*
acceptance of a context-less client must be proven before we lean on it.

---

## Section C — typed-reply "packages" protocol

`emacsclient -e '(expr)'` **already returns elisp** (the result's `prin1` form).
Today's `cm/ai-*` build JSON *strings*, so the agent gets JSON double-wrapped in
an elisp string. Lean into the grain instead.

**Envelope** — a versioned elisp plist, zero-cost to produce, round-trippable:

```elisp
(:v 1 :type TYPE :payload PAYLOAD :meta (...))
```

**Types:**

| `:type` | `:payload` | when |
|---|---|---|
| `elisp` | a readable sexp | the answer *is* structure (context, buffer list, org element) — Claude reads it directly |
| `text` | a plain string | buffer / paragraph / line contents |
| `markdown` | a string | content known to be markdown |
| `json` | a JSON string | only when interop genuinely wants JSON |
| `error` | `(:code SYM :message STR :details …)` | **any failure — first-class, never silent** |
| `ref` | `(:path "~/.emacs-ai/content.txt" :bytes N :of text)` | **large** payloads: reference a file instead of inlining |

**What this buys:**
- **`error` as a package = no silent failures.** A `cm/ai-with-package` wrapper
  runs each handler, catches any signal, and converts it to an `error` package.
  Applies Jim's `log_error`/no-silent-failure discipline to the bridge.
- **`ref` folds in the existing `~/.emacs-ai/` file-exchange.** Small/interactive
  replies inline over the socket; whole buffers / `suggestions.json` keep flowing
  through files, referenced by a `ref` package — the "bulk" tier. Nothing about
  the current `cm/ai-share` flow is discarded.
- **Claude-only ⇒ prefer native `elisp` payloads**, deleting most manual
  JSON-building from `cm/ai-*`. `json` stays available on request
  (`(cm/ai-current-context :as 'json)`), defaulting to elisp.

**Blast radius:** only the *remote* (emacsclient-invoked) functions change return
shape. Interactive `C-c a` commands and the `*ai-suggestions*` buffer are
Emacs-internal and untouched. The agent-side parsing convention lives in
CLAUDE.md.

### Section C-write — edit / apply path

The write path is a couple of verbs on the same channel, not a new subsystem.

**Common case needs no protocol:** for a **saved, clean** buffer, the agent edits
the **file** with its native tools and `global-auto-revert-mode` picks it up. The
buffer-patch path below is specifically for **dirty buffers, non-file buffers, or
when an in-Emacs review gate is wanted.**

**Representation: agent returns the full modified buffer text; Emacs applies it
via `replace-buffer-contents`.** The agent does what it is best at (emit code),
not what it is worst at (byte-exact patch against possibly-stale context).
`replace-buffer-contents` does an internal minimal diff — editing only what
changed, **preserving point, markers, and undo** — so there are no context-drift
apply failures. Large buffers ride the `ref` package.

*(Compared with an agent-supplied unified diff, full-text is the more robust
"patch format" here: the fragile step in any LLM edit is matching stale context,
and this moves the diffing to Emacs, which holds the ground-truth buffer. This
also recovers macher's review-before-apply UX in the composition paradigm — the
one macher idea worth keeping — without driving the model from inside Emacs.)*

**Verb:** `(cm/ai-apply-edit BUFFER BASE-TICK EDIT-SPEC &optional REVIEW)` where
`EDIT-SPEC` is `(:kind full :text "…")` (v1) — `(:kind diff :patch "…")` reserved
for later. Returns a package: ok (with applied change stats) or an `error`
package.

**Correctness guard (no silent failures):** `BASE-TICK` carries the buffer's
`buffer-chars-modified-tick` (or a content hash) at read time. If the buffer
changed between read and apply, Emacs refuses and returns an `error` package —
optimistic concurrency.

**DWIM ceremony (decided in Emacs; the agent stays dumb):**
- Emacs computes a **dry-run diff** (current vs proposed) before touching the
  buffer.
- **Auto-apply iff** `hunks ≤ cm/ai-apply-auto-max-hunks` (default **1**) **and**
  `changed-lines ≤ cm/ai-apply-auto-max-lines` (default **8**); otherwise pop the
  **review gate** (`diff-mode`, apply with a keystroke).
- `REVIEW` overrides: `force | skip | auto` (default `auto`). A **read-only
  buffer always reviews** (never a silent auto-apply).
- **Apply is always `replace-buffer-contents` from the proposed full text** — in
  both the auto and post-confirm review paths. The shown diff is display-only, so
  review and apply are computed from the same text and cannot disagree.

Worked example — *"add `ctx context.Context` as the first arg to every method
targeting `Cache`"*: scattered signature edits → many hunks → review gate; Jim
eyeballs the diff and applies with one keystroke.

---

## Phasing

Each phase is independently shippable.

1. **Registry** — `cm-ai-registry.el` (+ ERT) and `scripts/emacs-send`
   project-resolution. Kills the "which Emacs" pain. No dependencies.
2. **Packages protocol + write path** — the envelope, the `error`/`ref` types,
   and `cm/ai-apply-edit` with the DWIM gate. Where the `ctx`-refactor use case
   lives. Depends only on being able to target the right Emacs (Phase 1).
3. **herdr bind/push** — `cm-herdr.el` (+ ERT), the `[emacs-bridge]` CLAUDE.md
   contract, and the HERDR_ENV context-less-client spike. Explicit /
   cross-project selection on top of the automatic substrate.

## File layout

- New siblings `cm-ai-registry.el`, `cm-herdr.el` (matches the `cm-project-*.el`
  + ERT pattern).
- **Extract the *remote* `cm/ai-*` functions from `init.el` into
  `cm-ai-bridge.el`** — they are about to grow (packages, apply-edit) and become
  genuinely unit-testable. The interactive `C-c a` commands stay in `init.el`.
  *(Approved as D's default; still flippable during spec review — if vetoed, the
  functions stay in `init.el`.)*
- `scripts/emacs-send`: add project-based resolution + `--project` / `--server` /
  `--list`.
- `CLAUDE.md`: the agent-side contract (parsing packages, the `[emacs-bridge]`
  sentinel, driving the write path).

## Testing (ERT throughout — `./tests/run-tests.sh`)

- **Registry:** register/deregister, ancestor-match resolution, multiple-per-
  project (newest wins), most-specific-root wins, dead-PID sweep, half-written
  descriptor skipped.
- **Packages:** constructor, the `cm/ai-with-package` error-wrapper (a signaling
  body yields an `error` package), `ref` threshold (payload over N bytes → file
  + ref).
- **Write path:** DWIM decision from a computed diff (hunks/lines thresholds),
  `replace-buffer-contents` apply preserving point, base-tick mismatch → `error`
  package, read-only buffer forces review.
- **herdr:** `agent list` JSON parse from a fixture; live commands `skip-unless`
  the `herdr` binary is present.

## Back-compat

Interactive `C-c a` untouched. Only the remote query functions change return
shape (update CLAUDE.md call sites). `emacs-send` keeps `~/.emacs-last-used` as
the fallback when no registry match exists.

## Non-goals / deferred (YAGNI)

- **Multi-harness** (codex/gemini/…): would switch the envelope to JSON and
  generalize the `[emacs-bridge]` contract. Deferred while "claude only."
- **Handshake ack protocol** for Phase 3 (fire-and-forget for now).
- **Live agent-state surfaced in Emacs** (a modeline/dashboard of herdr agent
  statuses) — possible later on the Phase 3 base, not in scope now.
- **Agent-supplied unified diffs** (`:kind diff`) — reserved; full-text +
  `replace-buffer-contents` is the v1 representation.

## Open risks

- **HERDR_ENV context-less client** (Phase 3 spike above) — must prove the herdr
  *server* accepts a GUI-external client before Phase 3 leans on it.
- **DWIM thresholds** will need real-use tuning; exposed as defcustoms so that is
  a config change, not a code change.
