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

**Modern dark product UI.** Three words: **calm, confident, contemporary.**

Lives alongside Linear / Arc / Raycast / macOS Shortcuts (dark mode) / modern
API clients. Thoughtful spacing, flat surfaces, subtle elevation by darkness
step, functional color on category chips, clean sans typography.

Emotional goal: **this recedes behind the task.**

### Aesthetic Direction

References: macOS Shortcuts dark, Linear, Raycast, Requestly, Arc settings.
Anti-references: editorial layouts, modular synth / rack, glassmorphism,
neon-on-dark, purple-blue gradients, skeuomorphic hardware, dense SaaS
dashboard templates, bouncy animation.

### Palette — cool dark with a single warm accent

```
bg          oklch(0.17 0.010 260)
surface     oklch(0.20 0.010 260)
surface-2   oklch(0.24 0.012 260)
surface-3   oklch(0.28 0.012 260)
line        oklch(0.30 0.010 260)
line-soft   oklch(0.25 0.010 260)

text        oklch(0.95 0.004 260)
text-2      oklch(0.72 0.008 260)
text-3      oklch(0.54 0.010 260)

accent      oklch(0.74 0.15 60)    /* warm amber */
accent-hi   oklch(0.82 0.14 65)
accent-lo   oklch(0.62 0.17 55)
accent-dim  oklch(0.34 0.08 58)

ok          oklch(0.72 0.16 150)
warn        oklch(0.80 0.15 85)
err         oklch(0.68 0.19 28)

/* Category chip tints (HTTP-method-style) */
cat-key       oklch(0.72 0.16 285)
cat-type      oklch(0.72 0.16 240)
cat-click     oklch(0.72 0.16 150)
cat-move      oklch(0.72 0.14 200)
cat-scroll    oklch(0.72 0.14 215)
cat-focus     oklch(0.75 0.14 75)
cat-wait      oklch(0.58 0.02 260)
cat-shell     oklch(0.72 0.16 40)
cat-notify    oklch(0.72 0.16 340)
cat-clip      oklch(0.72 0.14 210)
cat-note      oklch(0.54 0.01 260)
```

Accent discipline: amber is used for ONE thing at a time on a page —
the primary affordance (Run, Record arm, Save) or the selected sidebar row.
Category tints only on action-card chips.

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
2. **Rounded, consistent.** 8px containers, 6px buttons. Don't vary.
3. **Flat, not skeuomorphic.** No gradients on surfaces, no embossed edges,
   no drop shadows except for a true overlay (dialog backdrop).
4. **Category color is functional.** Tint only on the chip; accent amber is
   orthogonal and signals active/selected.
5. **Type hierarchy > visual weight.** Titles 20px/600, body 14px/400,
   values Geist Mono 13px. These three do most of the work.
6. **Hover subtle, selection clear.** Hover raises one surface step, no
   animation. Selected uses a 2px accent bar on the left — this is the
   right tool for a persistent indicator on a source list (macOS / VS Code
   pattern), and 2px satisfies the skill's anti-stripe rule.

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
