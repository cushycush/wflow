# wflow

A macOS Shortcuts-style GUI and workflow engine for Wayland, built on
[wdotool](https://github.com/cushycush/wdotool). Composes input automation +
shell + delays + notifications into shareable `.kdl` workflow files.

## Stack

- **Qt 6.11 + Qt Quick (QML)**, UI
- **Rust**, engine (actions, runner, store, recorder, KDL serde)
- **cxx-qt 0.8**, Rust ↔ Qt bridge (Rust types become QObjects)
- **CMake**, build driver

One binary. No webview, no IPC daemon yet. Engine crate is UI-agnostic
enough that a future `wflow-engine` daemon could reuse it behind a D-Bus
interface.

## Project layout

```
/               # top-level
  Cargo.toml    # Rust static library crate (cxx-qt)
  CMakeLists.txt# Builds Qt app + links Rust lib
  build.rs      # cxx-qt codegen
  src/          # Rust
    lib.rs           # cxx-qt bridge root (pub use bridge::*)
    actions.rs       # UI-agnostic action/workflow types
    engine.rs        # sequential step runner
    store.rs         # .kdl persistence at $XDG_CONFIG_HOME/wflow/workflows
    recorder.rs      # Record Mode (simulated today; libei receiver TODO)
    kdl_format.rs    # hand-written KDL encoder/decoder
    bridge/
      mod.rs         # re-exports
      library.rs     # LibraryModel (QAbstractListModel-shaped)
      patch.rs       # PatchController
      recorder.rs    # RecorderController
  cpp/
    main.cpp         # QGuiApplication + QQmlApplicationEngine
  qml/
    Main.qml         # root ApplicationWindow
    Theme.qml        # design tokens singleton
    pages/           # Library, Patch, Record
    components/      # ActionRow, Sidebar, IconButton, etc.
```

Workflows persist as `.kdl` at `$XDG_CONFIG_HOME/wflow/workflows/*.kdl`
(legacy `.json` read-only, re-saved as KDL on next write).

## Architecture invariants

- **Action dispatch goes through one enum** in `src/actions.rs`. Adding a
  new action kind = a new variant + a match arm in `engine::run_action` + a
  QML editor delegate. Nothing else should branch on kind.
- **wdotool is a subprocess**, not linked. Keeps wflow compatible with any
  wdotool install (AUR, cargo, nix) and future `--backend` flags.
- **The engine is step-iterative**, not a graph. Actions run top to bottom.
- **No action silently succeeds.** Every step produces a StepOutcome (ok |
  skipped | error + message) streamed to QML via Qt signals.
- **QML never knows about cargo**. cxx-qt exposes bridge QObjects under the
  `Wflow` QML module; QML imports `import Wflow 1.0` and that's the whole
  surface.

## Running locally

```sh
cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build
./build/wflow
```

## Commit attribution

Plain commit messages, no `Co-Authored-By: Claude` trailers (global pref).

## Jira is the live planning layer

Project tracking lives in Jira (WFLOW project at cushycush.atlassian.net),
alongside Drift's DRIFT project on the same site. `BACKLOG.md` and
`README.md`'s roadmap section are the design-doc layer; Jira holds the
live status. Three tiers: Epic > Task (umbrella) > Subtask.

The agent loop:

1. Run `python3 scripts/jira/seed.py lookup <path>` before starting work
   on a file. First matching glob in `scripts/jira/area-map.json` is the
   canonical ticket.
2. Transition to In Progress when work starts: `seed.py start WFLOW-XX
   --comment "what you're about to do"`.
3. Comment as you go via `seed.py comment WFLOW-XX "..."` when scope
   changes or follow-ups surface.
4. Transition to Done when the leaf is finished: `seed.py done WFLOW-XX
   --comment "shipped in <commit>"`.
5. Carry the key on each commit as a `Refs: WFLOW-XX` or `Closes:
   WFLOW-XX` trailer. The post-commit hook posts the commit subject as
   a comment and transitions `Closes:` tickets to Done. Cross-project
   refs (`Refs: DRIFT-72`) also land on the right ticket.

Full reference at `scripts/jira/README.md`. Credentials live at
`~/.config/jira/env` (chmod 600), shared with drift's tooling.

## Active session state

`ACTIVE.md` at the repo root is the session-handoff doc, updated at every
smoke-test point or anywhere we might lose the session. Pair it with
`BACKLOG.md` for longer-lived planning. Fresh sessions should read it
before doing anything that might step on in-flight work.

## Design Context

### Users

General Wayland users, GNOME / KDE / Hyprland, who want a friendly GUI
alternative to shell scripts. Keyboard-first power users who still expect a
product that feels at home alongside modern desktop apps.

Primary job-to-be-done: _"I keep doing this sequence of things by hand.
let me record it once, name it, and replay it."_

### Brand Personality

**Modern product UI with two skins.** Three words: **calm, confident, contemporary.**

Lives alongside Linear / Arc / Raycast / macOS Shortcuts / modern API
clients. Thoughtful spacing, flat surfaces, subtle elevation by step,
functional color on category chips, clean sans typography.

Emotional goal: **this recedes behind the task.**

### Aesthetic Direction

References: macOS Shortcuts dark, Linear, Raycast, Requestly, Arc settings,
wflows.io (the marketing site). Anti-references: editorial layouts, modular
synth / rack, glassmorphism, neon-on-dark, purple-blue gradients,
skeuomorphic hardware, dense SaaS dashboard templates, bouncy animation.

### Palettes, three brand skins, one source of truth

wflow ships three brand palettes. The active one is set on first run
via the tutorial and persists in `state.toml`; users can flip any time
from Settings. All three support light + dark.

**Warm Paper** (default, mirrors wflows.io): warm-cream surfaces (hue
55-60, near-white at L≈0.97 light / warm near-black at L≈0.16 dark)
with a coral accent (hue 25-32). This is the published marketing-site
identity.

**Cool Slate** (the original brief): slate-blue surfaces (hue 260, low
chroma) with a warm amber accent (hue 60).

**Drift** (the third skin): slate-900 / cream-200 surfaces with a
gold-500 accent (hue 40-45), reading as architectural parchment on
dark and warm vellum on light. Chip tints come from a slate/gold-
adjacent brand-tier set (plum, steel, sage, teal, ochre, terra) so
categories stay in the slate-gold register.

`qml/Theme.qml` is the canonical token registry. Every color resolves
through `_pl(coolDark, coolLight, warmDark, warmLight, driftDark,
driftLight)`, which reads both `palette` and `isDark` and returns the
matching string. When you need a token's value, read Theme.qml, don't
copy hex into a component.

Cat-tint chips also branch by palette so the saturated original set
rides with cool slate, the muted ink-* register (mirrored from
wflows.io tokens.css) rides with warm paper, and the slate/gold-
adjacent brand-tier set rides with drift. Either way, the rule
holds: tint only on the chip, accent only on the primary affordance.

### Typography

- **Hanken Grotesk**, body, UI, headings (400 / 500 / 600 / 700)
- **Geist Mono**, all technical values, commands, key chords, paths

Banned: Inter, Fraunces, Newsreader, Lora, Crimson*, Playfair, Cormorant,
Syne, IBM Plex*, Space Mono/Grotesk, DM*, Outfit, Plus Jakarta, Instrument*.

Scale: 11 / 13 / 14 / 16 / 20 / 28 px.

### Design Principles

1. **Surfaces step by lightness.** `bg → surface → surface-2` is brightness
   only. 1px `line` hairlines are the strongest divider we draw; beyond
   that, change the fill.
2. **Rounded, consistent.** Pick from the radii ladder, `radiusXs` (4,
   tags), `radiusSm` (6, compact buttons / inputs), `radiusMd` (10, cards
   and dialogs), `radiusLg` (16, hero / big cards), `radiusXl` (22, large
   panels), `radiusPill` (999, primary / secondary buttons, triggers).
   Mirrors wflows.io's full ladder. Don't free-hand corner radii.
3. **Flat, not skeuomorphic.** No gradients on surfaces, no embossed edges,
   no drop shadows except for a true overlay (dialog backdrop).
4. **Category color is functional.** Tint only on the chip; accent amber is
   orthogonal and signals active/selected.
5. **Type hierarchy > visual weight.** Titles 20px/600, body 14px/400,
   values Geist Mono 13px. These three do most of the work.
6. **Hover subtle, selection clear.** Hover raises one surface step
   (cards may swap from `line` to `lineStrong` on the border) and is
   instant. Selection uses a coral-washed background plus an `accent`
   border, sourced through `Theme.accentWash(alpha)` so it tracks the
   active palette. Never hardcode a selection color; an old static
   `accentWash` *property* once collided with the helper of the same
   name and silently desaturated every selected row in dark mode.

### Motion

Qt Quick native animations:
- StackView transitions: 160ms OutCubic
- Row expand / collapse: 180ms OutCubic via height `Behavior`
- Hover: no animation; instant fill swap
- REC armed: opacity pulse 1.0 ↔ 0.7 at 1.1s
- A `reduceMotion` setting zeroes all durations

### Accessibility

- AA contrast minimum on every text/surface pair
- Full keyboard nav, visible focus ring (2px accent with 2px offset)
- Qt font rendering handles subpixel/hinting natively
