# gptel presets — research notes (not yet implemented)

**Source:** [karthink](https://www.youtube.com/watch?v=xHEnWvKmSKM) (gptel's
author), "stdin | LLM | stdout", published 2026-08-19, watched 2026-08-21.
These are my own notes/synthesis, not a transcript.

**Status:** research only. The current gptel setup (see `CLAUDE.md` § gptel)
uses none of this — four static backends and five static `C-c g` keybindings.
Presets are a separate, additive layer that doesn't require redoing that
setup.

## The core idea

gptel models an LLM call as a pipeline: **source** (context/prompt) → **LLM**
(provider, model, tools, system prompt, temperature — a large option
cluster) → **destination** (what happens to the response: inserted as text,
fed back as a chat turn, or something else entirely). A **preset** is a named
elisp plist bundling settings across all three stages — stored as data, not
an imperative function, so scope (global / buffer-local / next-request-only)
is controlled independently of the bundle's content.

Presets apply two ways: via the transient menu (`gptel-menu`, i.e. `C-c g m`
in this config), or by dropping an `@preset-name` token directly in the
prompt text — scoped to just that one request. The `@name` syntax is meant to
evoke slash-commands/`@file` mentions in coding-agent UIs.

## Preset examples worth considering (in rough order of value/risk)

**No tool-granting required — lowest risk, highest immediate value:**
- **`rewrite`-style presets** — response replaces the selected region as a
  diff/ediff preview (accept/tweak/reject), instead of dumping text below the
  prompt. Demoed on cleaning up a malformed table and deduplicating a package
  list. This is the most directly useful thing here for this config, given
  how much text/config editing already happens here.
- **`annotate`-style presets** — response becomes **Flymake diagnostics**
  attached to the buffer instead of chat text. Demoed for prose critique and,
  more compellingly, for explaining a Nix/Postfix config with per-option
  Flymake annotations informed by a long prior conversation's context. Given
  this config's existing Flymake/eglot investment, this is a very natural fit
  — output shape that's already native here.
- **Task-shaped presets** (e.g. a `tutor` preset: system prompt tuned to hint
  rather than answer, plus a smaller/faster model, plus UI tweaks like
  enabling LaTeX preview) — just a named bundle of otherwise-static settings.
  Easy to hand-write, no elisp beyond a plist.
- **`@json`-style presets** — force a JSON-schema-shaped response inline via
  prompt syntax, for when the response needs to be machine-consumable
  downstream rather than read by a human.
- **Notification-on-response presets** — trivial, but the point is it's an
  easy per-request toggle rather than a global hook.

**Source-side dynamism — still no tool-granting, more elisp:**
- **`expand`-style presets** — interpolate shell command or elisp expression
  results into the prompt text before sending (e.g. `$(shell cmd)` syntax,
  arbitrary/preset-defined). Handy for injecting live system state.
- **`visible-text`-style presets** — auto-include everything currently
  visible on the Emacs frame (including images from other visible buffers)
  as context, so the LLM has situational awareness of what's on screen.
- **`include`-style presets** — attach specific files/buffers to context,
  combinable with a model-switch preset (e.g. a `lite` preset for a
  smaller/faster model on simple lookups).

**Tool-granting — reopens the MCP/tool-use scope this config's gptel setup
deliberately deferred:**
- **`introspect`-style presets** — give the LLM read-only tools to inspect
  Emacs's own live state/docs, so Emacs questions get answered from ground
  truth instead of (possibly stale) training data. Strong, fairly contained
  use of tool-calling — the tools are read-only introspection, not
  file/shell access.
- **Presets as small agents** — tools + dynamic system prompt + some failure
  handling, wired to a destination preset (e.g. extending `annotate`'s own
  Flymake UI). Demoed working end-to-end in-session. Neat proof of concept,
  but this is genuinely agentic (file edits) and needs the same scrutiny any
  tool-granting setup would.

## Caveats to weigh before implementing anything here

- **The `@preset` prompt-token mechanism can execute code before the LLM
  sees anything.** If a preset name happens to appear in included file/web
  content (accidentally or adversarially), gptel can invoke it — the video's
  own framing is "worse than prompt injection" for this reason. Mitigation:
  namespace preset names so they can't collide with ordinary prose (e.g. a
  prefix unlikely to appear in real text).
- **KV/prompt-cache invalidation.** Leaving an `@preset` token in prior
  conversation turns invalidates the API's prompt cache on subsequent
  requests in the same conversation — real latency/cost impact. Described as
  fixable but not yet fixed upstream as of the source video.
- **Dynamic presets (function-valued plist keys) need real elisp to author.**
  Static presets (plain data, no functions) are easy to hand-write; anything
  reactive to buffer/request state is a small programming task, not config.

## If this gets picked up later

Start with a hand-written `gptel-rewrite`-backed preset and a hand-written
`annotate`-backed preset — highest value-to-risk slice, no tool-granting, no
reopening of the deferred MCP/tool-use scope decision from the original gptel
setup. Treat `introspect`-style and agent-style presets as their own,
separate brainstorm — they carry the same "what access does an LLM get"
questions that were deliberately punted on originally.
