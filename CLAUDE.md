# wflow

A macOS Shortcuts-style GUI and workflow engine for Wayland, built on
[wdotool](https://github.com/cushycush/wdotool). Composes input automation +
shell + delays + notifications into shareable `.kdl` workflow files.

## Stack

- **Qt 6.11 + Qt Quick (QML)** — UI
- **Rust** — engine (actions, runner, store, recorder, KDL serde)
- **cxx-qt 0.8** — Rust ↔ Qt bridge (Rust types become QObjects)
- **CMake** — build driver

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

Plain commit messages — no `Co-Authored-By: Claude` trailers (global pref).

## Design Context

### Users

General Wayland users — GNOME / KDE / Hyprland — who want a friendly GUI
alternative to shell scripts. Keyboard-first power users who still expect a
product that feels at home alongside modern desktop apps.

Primary job-to-be-done: _"I keep doing this sequence of things by hand —
let me record it once, name it, and replay it."_

### Brand Personality

**Modern product UI with two skins.** Three words: **calm, confident, contemporary.**

Lives alongside Linear / Arc / Raycast / macOS Shortcuts / modern API
clients. Thoughtful spacing, flat surfaces, subtle elevation by step,
functional color on category chips, clean sans typography.

Emotional goal: **this recedes behind the task.**

### Aesthetic Direction

References: macOS Shortcuts dark, Linear, Raycast, Requestly, Arc settings,
wflows.com (the marketing site). Anti-references: editorial layouts, modular
synth / rack, glassmorphism, neon-on-dark, purple-blue gradients,
skeuomorphic hardware, dense SaaS dashboard templates, bouncy animation.

### Palettes — two brand skins, one source of truth

As of v0.5.0, wflow ships two brand palettes. The active one is set on
first run via the tutorial and persists in `state.toml`; users can flip
any time from Settings. Both support light + dark.

**Warm Paper** (default, mirrors wflows.com): warm-cream surfaces (hue
55-60, near-white at L≈0.97 light / warm near-black at L≈0.16 dark)
with a coral accent (hue 25-32). This is the published marketing-site
identity.

**Cool Slate** (the original brief): slate-blue surfaces (hue 260, low
chroma) with a warm amber accent (hue 60).

`qml/Theme.qml` is the canonical token registry. Every color resolves
through `_pl(coolDark, coolLight, warmDark, warmLight)`, which reads
both `palette` and `isDark` and returns the matching string. When you
need a token's value, read Theme.qml — don't copy hex into a component.

Cat-tint chips also branch by palette so the saturated original set
rides with cool slate and the muted ink-* register (mirrored from
wflows.com tokens.css) rides with warm paper. Either way, the rule
holds: tint only on the chip, accent only on the primary affordance.

### Typography

- **Hanken Grotesk** — body, UI, headings (400 / 500 / 600 / 700)
- **Geist Mono** — all technical values, commands, key chords, paths

Banned: Inter, Fraunces, Newsreader, Lora, Crimson*, Playfair, Cormorant,
Syne, IBM Plex*, Space Mono/Grotesk, DM*, Outfit, Plus Jakarta, Instrument*.

Scale: 11 / 13 / 14 / 16 / 20 / 28 px.

### Design Principles

1. **Surfaces step by lightness.** `bg → surface → surface-2` is brightness
   only. 1px `line` hairlines are the strongest divider we draw; beyond
   that, change the fill.
2. **Rounded, consistent.** Pick from the radii ladder — `radiusXs` (4,
   tags), `radiusSm` (6, compact buttons / inputs), `radiusMd` (10, cards
   and dialogs), `radiusLg` (16, hero / big cards), `radiusXl` (22, large
   panels), `radiusPill` (999, primary / secondary buttons, triggers).
   Mirrors wflows.com's full ladder. Don't free-hand corner radii.
3. **Flat, not skeuomorphic.** No gradients on surfaces, no embossed edges,
   no drop shadows except for a true overlay (dialog backdrop).
4. **Category color is functional.** Tint only on the chip; accent amber is
   orthogonal and signals active/selected.
5. **Type hierarchy > visual weight.** Titles 20px/600, body 14px/400,
   values Geist Mono 13px. These three do most of the work.
6. **Hover subtle, selection clear.** Hover raises one surface step
   (cards may swap from `line` to `lineStrong` on the border) and is
   instant. Selection uses a coral-washed background plus an `accent`
   border — sourced through `Theme.accentWash(alpha)` so it tracks the
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
