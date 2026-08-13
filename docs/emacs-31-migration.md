# Emacs 31 Migration Ledger

A living document tracking the arrival of Emacs 31 and its concrete impact on
**this** configuration. Split into: (0) release status, (1) a condensed feature
overview, (2) things this config can **drop/simplify** once on 31, (3)
behaviors that will **change or be noticed**, and (4) a pre-flight checklist.

> **How to use this:** items in Parts 2–4 carry a status box — `[ ] open`,
> `[x] done`, `[-] decided-against`. Update them as 31 is adopted. Line
> references (`init.el:NNNN`) were captured 2026-08-13 and may drift; re-grep
> before editing.

---

## 0. Release status (as of 2026-08-13)

Emacs 31 is **in pretest**, not yet released. Ground truth from the Emacs git
repo and the emacs-devel announcements:

| Signal | Value |
|---|---|
| `emacs-31` release branch | exists (cut from master) |
| master `configure.ac` version | `32.0.50` (master already moved on to 32-dev) |
| Pretest `31.0.90` | 2026-06-05, announced by Sean Whitton (release manager) |
| Pretest `31.0.91` | 2026-07-23 (second pretest) |
| `31.0.92` / `31.1` tags | do not exist yet |
| Target `31.1` date | none announced; historically pretest→final runs months. **Autumn 2026 plausible.** |

**Wildcard:** a symbol-shorthands **arbitrary-code-execution** bug (affects
28.1→present; opening a crafted file can execute elisp) had a mitigation
committed to the `emacs-31` branch on 2026-08-05, with CVEs assigned
(CVE-2026-71391…71394). A late security blocker like this can add a pretest and
push `31.1` rightward — watch for a `31.0.92`.

**Sourcing:** feature analysis below is from `etc/NEWS` on the `emacs-31` branch
(the authoritative manifest), not blog summaries. NEWS.31 is itself a *pretest*
document — entries can still be edited/dropped before `31.1` ships. (Notably,
the `markdown-ts-mode` several blogs attributed to 31 is **not** in NEWS.31 — it
appears to be a master/32 item.)

---

## 1. Feature overview (condensed)

The headline themes of 31 vs the current stable (30.x):

- **Tree-sitter "batteries-included"** — `treesit-enabled-modes` (t = remap all
  languages to `*-ts-mode`), `treesit-auto-install-grammar` (core fetches
  missing grammars on demand), `treesit-x.el` + `define-treesit-generic-mode`,
  proper `show-paren`/`hs-minor-mode` support, `list`/`comment` things,
  `treesit-explore`. **This is the theme that most overlaps our config** (see
  Part 2).
- **Terminal (TTY) leap** — child frames on TTY, `xterm-mouse-mode` on by
  default in capable terminals, TTY tooltips, 24-bit color in Windows Terminal.
- **Window/frame/layout** — transpose/rotate/flip window commands,
  `split-frame`/`merge-frames`, `split-tab`/`merge-tabs`,
  `other-window-backward` (`C-x O`), `mode-line-collapse-minor-modes`.
- **Minibuffer/completion** — `*Completions*` shows immediately + updates as you
  type, category inheritance, rewritten faster `flex` style. (Vanilla catching
  up to Vertico/Corfu; does **not** replace them.)
- **project.el** — many new commands (`project-root-find-file`,
  `project-save-some-buffers` on `C-x p C-x s`, `project-customize-dirlocals`,
  `project-prune-zombie-projects`, …).
- **VC** — one of the largest change areas: multiple working trees, async
  check-in, cherry-pick/revert/rewind, incoming/outgoing diffs.
- **package.el** — async `package-refresh-contents`, review-before-install,
  recursive-dependency checks, `package-autosuggest-mode`.
- **Emacs Lisp** — `if-let`/`when-let` **obsolete** (use `*` forms), semantic
  highlighting for elisp, new built-ins (`incf`/`decf`, `plusp`/`minusp`,
  `oddp`/`evenp`, `take-while`/`drop-while`, `cond*`), lexical-binding default
  is now settable + warns when a cookie is missing, `secure-hash` gains SHA-3.
- **Bundled** — `lua-mode` now in core; new `icalendar-mode`,
  `delete-trailing-whitespace-mode`, `mhtml-ts-mode`, `go-work-ts-mode`,
  `system-taskbar-mode`, `system-sleep`; Org bumped to **9.8**.
- **Platform** — PGTK respects system dark/light mode; **unexec dumper removed**
  (portable dumper only); old `ctags` no longer built.

---

## 2. What this config can DROP or SIMPLIFY on 31

Ranked by payoff. Confidence reflects how sure the built-in is a full
replacement.

### 2.1 `treesit-auto` → built-in tree-sitter automation `[ ] open` — **MEDIUM confidence, biggest-ticket**

- **Current:** `init.el:960–977` — `treesit-auto` with `treesit-auto-install t`,
  `treesit-auto-add-to-auto-mode-alist 'all`, `global-treesit-auto-mode`, plus
  the `cm/sanitize-auto-mode-alist` workaround (which exists **specifically
  because** treesit-auto injects invalid `auto-mode-alist` entries).
- **31 replacement:** `treesit-enabled-modes` (set to `t` → drives
  `major-mode-remap-alist` from each mode package's
  `treesit-major-mode-remap-alist`) + `treesit-auto-install-grammar` (core
  fetches missing grammars) + `treesit-language-source-alist` (now supports
  `:commit` keywords).
- **Payoff:** potentially retire the whole `treesit-auto` dependency **and** the
  `cm/sanitize-auto-mode-alist` workaround.
- **⚠ Before dropping, verify:**
  1. **Grammar-source coverage.** Confirm the built-in `treesit-language-source-alist`
     ships URLs for every language we rely on: go, rust, yaml, toml,
     typescript/tsx, json, dockerfile, cmake, lua, html, css, java, bash, scala,
     c/c++, python, js. `treesit-auto` bundles a broad curated list; the
     built-in list may be narrower — any gap must be added manually to
     `treesit-language-source-alist`.
  2. **The tree-sitter 0.25.10 pin interaction.** Auto-install *builds* grammars
     against the installed `tree-sitter`/`treesit.c`. Our machine pins
     `tree-sitter 0.25.10` to dodge the 0.26 `treesit.c` incompatibility
     (`docs/tree-sitter-026-fix.md`). Re-validate that grammars built under 31
     still load. **A new Emacs major is the single most likely place for
     `treesit.c` behavior to change** — do not assume the pin story is stable
     across the 30→31 jump.
  3. The `CMakeLists.txt` basename mapping (`init.el:1588–1590`) is **not**
     part of treesit-auto and must be **kept** regardless.

### 2.2 Built-in completion improvements — **NOT a drop** `[-] decided-against`

We run Vertico + Corfu + Orderless + Marginalia + Consult + Embark + prescient
(`init.el:547–785`). Emacs 31's `*Completions*` and `flex` improvements are the
*vanilla* stack maturing; they do **not** match our framework. No change — noted
so it isn't revisited.

### 2.3 `mode-line-collapse-minor-modes` — **N/A** `[-] decided-against`

We use `doom-modeline` (`init.el:946`), which owns minor-mode presentation. The
new built-in modeline collapsing is irrelevant while doom-modeline is in play.

### 2.4 recentf / saveplace periodic auto-save — **enhancement, not a drop** `[ ] open`

- **Current:** `recentf` (`init.el:165`) and `saveplace` (`init.el:177`) persist
  on the normal schedule.
- **31 adds:** opt-in *periodic* auto-save for both recentf and saveplace
  (crash-resilience without waiting for a clean exit). We already persist a
  session stash periodically via `cm-project-sessions`; adopting the built-in
  periodic saves for recentf/saveplace is a small robustness win, optional.

### 2.5 Window-layout commands vs `cm/toggle-window-split` — **optional** `[ ] open`

31 ships general transpose/rotate/flip window commands + `split-frame`/
`merge-frames`. Our `cm/toggle-window-split` (`init.el:407–428`, 2-window
swap on `C-c |`) is narrower and works fine; the built-ins are a superset if we
ever want richer layout manipulation. Low priority — keep unless we want more.

---

## 3. Behaviors that will CHANGE or be NOTICED (watch-list)

Ranked by likely impact on us.

### 3.1 `go-ts-mode-indent-offset` renamed → `go-ts-indent-offset` `[ ] open` — **concrete edit**

- **Hit:** `init.el:1267` — `(setq go-ts-mode-indent-offset 4)`. Go is
  explicitly in the 31 rename list (NEWS.31: the TS modes mistakenly used
  `FOO-mode-indent-offset` instead of the conventional `FOO-indent-offset`).
- **Impact:** the old name is expected to survive as an obsolete alias (works,
  emits a deprecation warning). **Action on 31:** change to
  `(setq go-ts-indent-offset 4)`. Same family, if we ever set them:
  `c-ts-indent-offset`, `cmake-ts-indent-offset`, `java-ts-indent-offset`,
  `json-ts-indent-offset`, `typescript-ts-indent-offset`, `toml-ts-indent-offset`.
- **Not affected:** our own `jai-ts-mode-indent-offset` (`jai-ts-mode.el:75`) is
  a custom `defcustom`, untouched by the core rename. It now *cosmetically*
  diverges from the renamed convention; renaming it to `jai-ts-indent-offset`
  would be consistency-only and is a public-ish option — low value, skip unless
  bored.

### 3.2 Tree-sitter grammar auto-install + the 0.25.10 pin `[ ] open` — **high attention**

Independent of whether we retire `treesit-auto` (2.1): on 31, first-visit grammar
installs and any grammar rebuild run against the installed tree-sitter. **Re-run
the grammar rebuild and re-verify `docs/tree-sitter-026-fix.md` still holds under
31 before trusting tree-sitter modes.** Treat the 30→31 jump as a checkpoint for
the whole tree-sitter pin story.

### 3.3 Bundled Org → 9.8 `[ ] open`

We use the **built-in** Org (`init.el:1801`, `:straight nil`). Upgrading to 31
bumps Org from 30.x's version to **9.8**. Our Org customizations —
`org-tempo` easy-templates, heading-scale machinery (`init.el:1848–1913`),
`org-src-lang-modes` seeding (`init.el:1831–1846`), mixed-pitch table faces —
should survive, but Org minor-version bumps routinely shift faces/defaults.
Watch heading rendering and src-block fontification after the move.

### 3.4 font-lock face **variables** obsolete — themes SAFE `[-] decided-against`

NEWS.31 obsoletes the *variables* `font-lock-string-face`,
`font-lock-keyword-face`, etc. (the same-named **faces** stay — only the
variables holding the face symbol are deprecated).

- **Our themes are safe:** `themes/*` and `custom-theme-set-faces` reference the
  **faces** (the car of each spec is a face symbol, not the variable). No change
  needed.
- **Possible noise:** third-party packages that use the unquoted variable in
  font-lock rules may emit deprecation warnings when **straight byte-compiles**
  them. Our own loaded `.el` files (`init.el` has `no-byte-compile: t`;
  `jai-ts-mode.el`/`cm-*.el` are `load`ed, not compiled) keep working at
  runtime. Cosmetic; nothing to fix on our side.

### 3.5 `global-hl-line-mode` default now excludes `*Completions*` `[-] decided-against`

We enable `global-hl-line-mode` (`init.el:100`). 31's new `global-hl-line-buffers`
defaults to "all buffers except the minibuffer and `cursor-face-highlight-mode`
buffers like `*Completions*`." Net effect: hl-line stops fighting the
`*Completions*` selection highlight — a subtle **improvement** we get for free.

### 3.6 `xterm-mouse-mode` on by default in terminals `[ ] open`

Only relevant when running `emacs -nw` (or inside `ghostel`/a TTY). Mouse
reporting turns on automatically in capable terminals — usually welcome, but
noted in case a mouse gesture behaves differently than the GUI.

### 3.7 `process-adaptive-read-buffering` now `nil` by default `[ ] open`

We set `read-process-output-max` to 4 MB for LSP throughput (`init.el:110`).
31 flips `process-adaptive-read-buffering` off by default, which changes
process-output batching. Likely neutral-to-good for LSP; watch for any change in
large-response handling (eglot) after the move.

### 3.8 `exec-path` empty-PATH default change `[-] decided-against`

NEWS.31: `exec-path` treats an unset/empty `PATH` as the system default
(`/bin:/usr/bin`). Our PATH block (`init.el:224–234`) reads and prepends to a
populated `PATH`, so this only matters if `PATH` were empty — not our case.
No action.

### 3.9 `if-let`/`when-let` obsolete — our code is already clean `[x] done`

The big elisp deprecation in 31. **Verified 2026-08-13:** all our `.el` files
(`init.el`, `jai-ts-mode.el`, `cm-project-roots.el`, `cm-project-tags.el`,
`cm-project-sessions.el`) already use the `if-let*`/`when-let*` forms — **zero**
non-starred occurrences. No action on our code. Third-party packages may warn on
straight rebuild; not ours to fix.

### 3.10 Other removals/changes — irrelevant to us `[-] decided-against`

- **Unexec dumper removed** (portable dumper only): we don't dump.
- **`ctags` no longer built**: we generate `TAGS` via project build metaprograms
  (Jai `first.jai`), not Emacs's `ctags`; `cm-project-tags.el` uses `etags`
  format, unaffected.
- `purecopy`→`identity`, `redisplay-dont-pause` removed, `binary-as-unsigned`
  removed: grepped — **not referenced** anywhere in our config.

### 3.11 project.el / easysession interaction `[ ] open`

31 adds project commands, some newly bound (e.g. `project-save-some-buffers` on
`C-x p C-x s`). Our `cm-project-sessions` `:around`-advises `C-x p p`
(`init.el:1118–1133`). Verify no new default `C-x p …` binding collides with our
session bindings or the `C-c N` scratch command after the upgrade — low risk,
quick check.

---

## 4. Pre-flight checklist (run when 31 lands)

- [ ] Install Emacs 31 (pretest tarball or `emacs-31` branch build); **keep 30.x
      available** to fall back.
- [ ] `rm ~/.config/emacs/tree-sitter/*.so` and rebuild grammars; re-verify
      `docs/tree-sitter-026-fix.md` still holds under 31 (§3.2).
- [ ] First launch: inspect `*Warnings*` for deprecation/obsolete messages;
      triage anything from our own code (expected: none — §3.9).
- [ ] Apply the `go-ts-mode-indent-offset` → `go-ts-indent-offset` edit (§3.1).
- [ ] Run `./tests/run-tests.sh` (ERT suites for `cm-project-roots`,
      `cm-project-tags`, `cm-project-sessions`, `jai-ts-mode`) under 31.
- [ ] Decide on `treesit-auto` retirement (§2.1) — only after confirming
      grammar-source coverage and the pin interaction.
- [ ] Smoke-test: eglot on a Go/Rust/Python file, magit, org (9.8) rendering,
      markdown preview, ghostel, the `C-c w`/`C-x p p` project flows.

---

*Created 2026-08-13. Feature data: `etc/NEWS` on the `emacs-31` branch
(pretest). Update as Emacs 31 progresses toward release and as items are
resolved.*
