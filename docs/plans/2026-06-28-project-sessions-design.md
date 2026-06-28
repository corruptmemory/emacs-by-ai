# Per-project session persistence (`cm-project-sessions.el`) — Design

**Date:** 2026-06-28
**Status:** Approved (brainstorming complete) — proceeding to implementation plan.

## Goal

Bring Sublime Text's project-workspace experience to an ephemeral Emacs: opening
a project restores exactly the files, the window/split layout, the cursor
position in each file, and the unsaved scratch buffers that were there last time;
switching projects with the keystroke already in muscle memory (`C-x p p`) tears
the current workspace down cleanly and restores another's full state — without
starting a second Emacs.

Three target features (from the originating request):

1. **Per-project restore** — open files + window/split layout + per-file point.
2. **Unsaved scratch buffers persist** — created freely, survive restarts *and*
   project switches.
3. **One-keystroke project switching** — tear down current, restore target.

## Workflow being served

The design is shaped by the user's actual habits (not a generic IDE model):

- **Ephemeral Emacs** — instances come and go; restarts are frequent. Persistence
  fidelity across restart matters more than anything.
- **One project per instance** — a session is started, *one* project is opened
  (`C-x p p`), and worked for a long time.
- **Multiple projects → multiple Emacs instances** — the user does *not* juggle
  several projects inside one Emacs. So simultaneous-live multi-project isolation
  (perspective's one advantage) is worth nothing here.
- **"Sorta done, flip cleanly"** — occasionally the user wants to reconfigure the
  *current* Emacs for a different project rather than launch a new instance.
- **Not a tabs user** — the Emacs tab-bar is not part of the mental model.
- **Ephemeral process-backed buffers (REPLs, terminals, LSP) just restart** — the
  user explicitly does *not* want these restored; a fresh shell beats a stale one.

## Research & validation summary

**Approach: easysession "sessions-as-projects."** Chosen over `perspective.el`
and `tabspaces` after a full comparison this session:

- `perspective.el` rejected: it stores workspace state in *frame parameters* that
  `frameset`/`desktop.el` (and therefore easysession) do not serialize, so it does
  not compose with easysession; and its own `persp-state-save` explicitly does
  **not** persist non-file buffers (shell/REPL/compilation — and scratch), missing
  feature 2. Its sole advantage (many projects live in one frame, instant filter
  flip) is irrelevant to a one-project-per-instance user.
- `tabspaces` rejected: its isolation substrate *is* the tab-bar — a "tabspace" is
  literally a tab-bar tab. The user is not a tabs user.
- **easysession** chosen: a single named session per project. `C-x p p` →
  `easysession-switch-to` saves the current session, tears the workspace down, and
  restores (or creates) the target. It is the most actively maintained option
  (installed build dated **2026-06-27**), persists file buffers + window/split
  layout + tab-bar (if used) + frames + narrowing natively, and persists arbitrary
  non-file buffers via custom handlers. "Switch = teardown + restore" is a faithful
  match for both Sublime's model and the user's one-at-a-time flow.

**Spike (validated, not assumed).** A throwaway `--init-directory` sandbox, two
*separate* Emacs processes (a real restart), headless batch:

| Behavior | Result |
|---|---|
| `easysession-save` incl. frameset, headless | ok (no frameset breakage) |
| Window split layout (3 windows) restored across restart | **PASS** |
| Single `*scratch*` content (bundled `easysession-scratch`) | **PASS** |
| Multiple custom scratch buffers via a ~12-line `easysession-define-handler` | **PASS** |
| File buffer reopened | **PASS** |
| Cursor point restored | **PASS** — *after* removing `save-place-find-file-hook` from `easysession-exclude-from-find-file-hook` |

Key spike findings baked into this design:
- `easysession-scratch` (bundled) persists only the lone `*scratch*`; a *family*
  of freely-created scratch buffers needs a custom handler keyed on a name prefix.
- easysession deliberately strips `save-place-find-file-hook` during restore to own
  point via window-state, which lands on a real frame but not headless; letting the
  user's existing `saveplace` run (un-exclude the hook) restores point reliably.

## Decisions (from brainstorming)

1. **Scratch = two tiers.** Per-project scratch buffers ride each project's
   session; a small set of **global stash** buffers (for reusable snippets/test
   data) is always present, independent of project.
2. **Scratch creation UX.** `C-c n` instantly opens a fresh project-tier scratch
   buffer (`*scratch:<proj>:N*`, auto-named, no prompt). `C-u C-c n` prompts for a
   name and creates/visits a global stash buffer (`*stash:<name>*`).
3. **Unsaved files on switch.** Before teardown, run the standard
   `save-some-buffers` prompt for modified *file* buffers (appears only when such
   buffers exist). Scratch buffers are unsaved by nature and excluded — they
   persist automatically.
4. **Startup = restore-by-launch-directory.** On `emacs-startup-hook`, if
   `project-current` resolves the launch directory to a project, load that
   project's session; otherwise stay blank (just `*scratch*` + stash). Handles the
   multi-instance habit correctly (each instance restores its own project) and the
   ephemeral relaunch (same dir → same project).
5. **Auto-save = switch + exit + periodic.** `easysession-save-mode` saves on exit
   and every `cm/session-save-interval` seconds (default 60); the switch flow saves
   explicitly. Bounds crash/kill loss to ~60s.
6. **Defaults.** Scratch default major mode `cm/scratch-default-mode` = `text-mode`
   (user-tweakable per buffer). Keybinding `C-c n` (verified free in `init.el`).

## Architecture

A sibling library **`cm-project-sessions.el`**, loaded from `init.el` with the
established `(load (locate-user-emacs-file "cm-project-sessions") t)` pattern (like
`cm-project-roots.el` / `cm-project-tags.el`). **Purely additive** — no existing
behavior changes. Three layers:

- **easysession** *(new dependency)* — persistence engine: file buffers,
  window/split layout, frames, narrowing, and (via handlers) scratch buffers.
- **project.el** *(built-in, already in use)* — project identity; `project-root`
  is the session key.
- **`cm-project-sessions.el`** *(glue)* — project↔session mapping, the `C-x p p`
  flip, the two scratch tiers, restore-by-launch-directory.

## Components (all in `cm-project-sessions.el`)

- **`cm/session-name-for-project (root)`** — stable, filesystem-safe session name
  from a project root. Single source of truth for the project↔session mapping.
- **`cm/session-switch-to-project (dir)`** — the core flip (see Data flow). No-op
  when `dir` is the already-current project.
- **`cm/session--project-switch-advice`** — `:around` advice on
  `project-switch-project` routing `C-x p p` through the flip.
- **`cm/scratch-new (&optional global)`** → `C-c n`. No prefix: instant
  project-tier scratch `*scratch:<proj>:N*` in `cm/scratch-default-mode`, no prompt.
  `C-u`: prompt for a stash name → `*stash:<name>*` in the global tier.
- **Project-scratch handler** — an `easysession-define-handler` (key
  `cm-project-scratch`) that saves/restores buffers named `*scratch:<proj>:*` inside
  the project session blob.
- **`cm/stash-save` / `cm/stash-load`** — standalone persistence for `*stash:*`
  buffers (and the lone `*scratch*`) to `cm/stash-file`, *independent* of any
  session. Loaded at startup, saved on the same cadence, and round-tripped across
  every teardown.
- **`cm/session-startup`** (on `emacs-startup-hook`) — load the stash, then
  restore-by-launch-directory.

## Data flow — `C-x p p`

```
C-x p p → (advice) → cm/session-switch-to-project(dir)
   ├─ dir == current project?  ──► no-op (no teardown)
   ├─ save-some-buffers           (modified FILE buffers only; standard prompt)
   ├─ cm/stash-save               → *stash:* (+ *scratch*) → cm/stash-file
   ├─ easysession-save            → current project blob (files, layout, *scratch:proj:*)
   ├─ easysession-kill-all-buffers   (clean teardown)
   ├─ easysession-switch-to <target> (load existing, or create fresh)
   └─ cm/stash-load               → *stash:* (+ *scratch*) reappear
```

The save-stash-before / reload-stash-after-teardown bracket means the stash
round-trips through its file on every flip. In practice `easysession-kill-all-buffers`
spares asterisk-named special buffers, so the live stash buffers survive the kill;
the explicit `cm/stash-load` after teardown is belt-and-suspenders that restores
them from `cm/stash-file` regardless.

## The two scratch tiers

| | Project tier | Global stash |
|---|---|---|
| Name | `*scratch:<proj>:N*` | `*stash:<name>*` (+ the lone `*scratch*`) |
| Created by | `C-c n` (instant, no prompt) | `C-u C-c n` (named) |
| Persisted in | the project's easysession blob | its own `cm/stash-file` |
| On project flip | swaps out with the project | **always present** |
| Default major mode | `cm/scratch-default-mode` (`text-mode`) | same |

Rationale for keeping the stash outside session blobs: inside a session it would
be N competing copies; as one independent file loaded at startup and reloaded after
every teardown, there is exactly one stash, always present — i.e. "follows you
everywhere."

## Configuration (applied in the `init.el` block)

- `(easysession-save-mode 1)` + `cm/session-save-interval` (default 60) — decision 5.
- `easysession-directory` under `user-emacs-directory`, **git-ignored** — consistent
  with how `recentf`/`saveplace`/`projects` state already lives there.
- **Remove `save-place-find-file-hook` from `easysession-exclude-from-find-file-hook`**
  — the spike-proven one-line fix that lets the user's existing `saveplace` restore
  point.

The lone `*scratch*` is persisted by the **global stash mechanism** (`cm/stash-save`
/ `cm/stash-load`), *not* by the bundled `easysession-scratch-mode`. The bundled mode
saves `*scratch*` into the per-project session blob, which would make it
project-local — the opposite of the intended always-present behavior. So
`easysession-scratch-mode` is deliberately **not** used; `cm/stash` owns `*scratch*`
alongside the `*stash:*` buffers.

## Error handling & edge cases

- **No project at launch** → blank; feature dormant. Purely additive; existing
  single-project commands untouched.
- **Same-project `C-x p p`** → no teardown (guarded in `cm/session-switch-to-project`).
- **Modified files at switch** → prompt-saved *before* `kill-all-buffers`, so the
  teardown's "spare modified buffers" behavior never strands anything.
- **Two concurrent instances on the same project** → they share one session name;
  periodic auto-save is last-writer-wins. Acceptable given one-instance-per-project
  usage, but **documented** (no silent surprise — the repo's no-silent-failures
  standard).
- **Ungraceful exit** → periodic auto-save bounds loss to ~`cm/session-save-interval`.
- **Process-backed buffers (REPL/terminal/LSP)** → intentionally *not* restored;
  they re-spawn on demand. This is a feature, not a gap (per the user).

## Testing

ERT suite `tests/cm-project-sessions-tests.el` (repo convention; run via
`./tests/run-tests.sh`):

- `cm/session-name-for-project` — stable, filesystem-safe mapping (pure).
- scratch tier classification by buffer name (pure).
- project-scratch handler save/load round-trip (batch — feasible, per spike).
- `cm/stash-save` / `cm/stash-load` round-trip (batch).
- switch logic: leaving saves, entering loads, same-project no-op (easysession
  calls stubbed/recorded).
- startup restore-by-launch-directory: project dir → switch invoked; non-project
  dir → not.
- Integration tests `skip-unless` easysession is installed (mirrors the existing
  rg/dumb-jump integration-test convention).

## Out of scope

- Restoring process/terminal/REPL/LSP state (re-spawn on demand, by decision).
- Per-pane file tabs (Sublime's tab-within-pane metaphor; not the Emacs model).
- Multi-frame session orchestration (one instance, typically one frame).
- Replacing `desktop.el` globally or touching the existing single-project commands.

## Affected files

- **New:** `cm-project-sessions.el`, `tests/cm-project-sessions-tests.el`.
- **Edit:** `init.el` — `use-package easysession` (+ `easysession-scratch`); load the
  sibling; bind `C-c n`; apply the configuration above. `.gitignore` — the sessions
  directory + stash file.
- **Docs:** `CLAUDE.md` (architecture-list item + a section), `README.md` (a
  "Project sessions" section).
