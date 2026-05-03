# Changelog

What landed in each release of wflow, what to look at first, and where
to read the full story. Highlights live in this file. Long-form prose
notes live one per release in [`docs/release-notes/`](docs/release-notes/).

Versions follow `MAJOR.MINOR.PATCH`. The 0.x line is unstable on disk
format only when a release explicitly says so; everything else is
additive. v1.0 ships when the wflows.com integration lands (Explore
re-enabled, sign-in, deeplink import, detail drawer wired to live
data). See [BACKLOG.md](BACKLOG.md) for the road there.

---

## [0.7.0] — 2026-05-03

[Full release notes](docs/release-notes/v0.7.0.md)

The daemon wakes up. Bind a keyboard chord to a workflow and the
chord fires the workflow on KDE Plasma 6, GNOME 46+, Hyprland, and
Sway.

### Added

- **Trigger daemon (`wflow daemon`).** New subcommand. Walks the
  library, registers every `trigger { chord "..." }` block against
  the right backend (GlobalShortcuts portal on Plasma 6 / GNOME 46+,
  Hyprland IPC, Sway IPC), dispatches the bound workflow on chord
  fire. AHK on Linux, more or less.
- **Hot reload.** Edit a workflow's KDL and the daemon re-binds the
  delta automatically (compositor-IPC mode; portal mode requires a
  daemon restart by xdg-desktop-portal spec).
- **Single-instance lock.** Pidfile at `$XDG_RUNTIME_DIR/wflow/daemon.pid`
  with `/proc/$pid` liveness check. A second `wflow daemon` exits
  with "already running (pid N)".
- **systemd user unit** (`packaging/systemd/wflow-daemon.service`).
  AUR, Flatpak, and tarball ship it under `/usr/lib/systemd/user/`.
  `systemctl --user enable --now wflow-daemon` and the daemon starts
  with every graphical session.

### Changed

- **wdotool-core 0.4 → 0.5.** Picks up the wlroots backend roundtrip
  fix: every input op (key, type, mouse-move, mouse-button, scroll)
  now does a `queue.roundtrip()` after sending its protocol messages,
  so a fast wflow process can't exit and destroy its virtual devices
  before the compositor finishes processing in-flight events. Caught
  silent input drops on wlroots that nobody knew were happening.
- Daemon command help text now describes what the daemon actually
  does. The v0.4.x "today is dry-run only" placeholder is gone.
- BACKLOG.md reorganised: trigger daemon ships as the AHK-launch
  keystone, trigger expansion (hotstrings, per-window predicates)
  deferred to post-launch.

---

## [0.6.0] — 2026-05-02

[Full release notes](docs/release-notes/v0.6.0.md)

Conditionals get a real false branch. `when` and `unless` now accept
an `else { ... }` block, the canvas draws the no-side as a parallel
column or row across every layout, and the inspector grew a FALSE
BRANCH section so authoring matches the engine.

### Added

- **`else { ... }` block** inside `when` and `unless` runs when the
  predicate flips the other way. KDL encoder + decoder round-trip,
  CLI explain renders both branches, parser rejects multiple `else`
  blocks and stray steps after an `else` with clear errors.
- **Inspector FALSE BRANCH section** for conditionals. Add / delete
  steps from either side; the existing INNER STEPS section renames
  to TRUE BRANCH on conditionals so the labels read symmetrically.
  Repeat keeps INNER STEPS — there's no true / false split there.
- **Canvas else-column rendering** in every layout. Vertical layout
  fans yes-cards right, no-cards left, both at the conditional's
  vertical mid. Horizontal does yes-below, no-above; conditional
  cell stays past the parent's right edge. Grid aligns all parents
  on a single row baseline so inter-cell wires don't thread through
  branch stacks. Smart Tidy splits each conditional cell with no on
  the left, yes on the right, all parents in a column at the same
  X.

### Changed

- **Wire routing** for same-row back-flow goes left-out / right-in
  instead of the old right-out / left-in lobe. Vertical-layout
  conditionals route their no-side wire as a clean horizontal
  diagonal between adjacent edges instead of dipping below the
  parent and U-turning back up.
- **Reset zoom** preserves the world point at the viewport centre
  through the zoom-to-1.0 transition. Used to pass raw contentX/Y
  across the zoom delta and shift cards off-screen.
- **First-load auto-fit** snaps the viewport to all cards regardless
  of whether the workflow has saved positions. Was gated on "no
  positions yet", which only fired for brand-new workflows; now
  triggers on every fresh workflow open via a 120ms timer that
  waits for card heights to publish.

---

## [0.5.0] — 2026-05-01

[Full release notes](docs/release-notes/v0.5.0.md)

The brand-palette release. wflow now ships two skins side by side and
you pick one on first run.

### Added

- **Two brand palettes.** Warm Paper (the wflows.com identity, cream
  surfaces with a coral accent) and Cool Slate (the original 0.4.x
  brief, slate-blue surfaces with a warm amber accent). Both carry
  full light + dark variants.
- **First-run palette pick.** The coach-mark tour opens with a "Pick
  your look" step. Two preview tiles, each rendering its own palette
  regardless of which is active. Tap one and the rest of the tour
  reskins live.
- **Settings → Palette toggle.** Two-segment switch between Warm Paper
  and Cool Slate, persists in `state.toml`.
- **Editor canvas backdrop.** The dot-grid graph-paper backdrop now
  renders behind the workflow editor. Library, Explore, Record, and
  Settings sit on a clean surface.

### Changed

- Connector ports on the canvas went flat. One coral disk with a
  hairline ring, no halo, no inner highlight.
- Wires use `Theme.lineStrong` so the marching dashes pick up either
  palette instead of fighting it as a hardcoded cool cyan.
- Step chips on the canvas render through `CategoryIcon`, so the
  chevron / timer / pilcrow / etc. match the toolbar's optical weight.
  The "shell chevron looks oversized on canvas cards" issue is gone.
- Inner step icons inside Repeat containers grew from `size: 14` to
  `size: 18` so the per-kind glyph ratios actually take effect.
- Primary and Secondary buttons are pill-shaped, matching wflows.com
  button language. Library cards picked up `radiusLg` corners and a
  `lineStrong` hover border.
- The active tab in the floating nav pill no longer paints a coral
  focus ring on click; selection reads from the accent-wash fill.
- `CategoryChip` is pill-shaped with a hairline border, quieter, in
  the same family as wflows.com `.wf-trigger`.

### Fixed

- **Selected rows in dark mode rendered with the light-mode fill.**
  An `accentWash` property added during the brand experiment collided
  with the existing `accentWash(alpha)` helper, breaking every
  selection binding (folder rows in the library sidebar, selected
  wires in the editor, menu hover items) in dark mode. Renamed the
  property to `accentDim`.
- `apply_palette` always re-notifies QML when invalid palette input
  gets coerced back to "warm", so the QML mirror can't desync from
  the persisted state.

### Reverted

- Briefly experimented with switching the font pair to Boska serif +
  Supreme sans (the wflows.com brand faces). They read poorly at the
  dense UI sizes wflow uses, so we're back on Hanken Grotesk + Geist
  Mono. `familyDisplay` stays as a separate token hook for a future
  heavier display face.

---

## [0.4.1] — 2026-04-29

The left-rail selection in the editor follows the canvas marquee in
real time as the rect moves, instead of catching up only on release.

---

## [0.4.0] — 2026-04-29

[Full release notes](docs/release-notes/v0.4.0.md)

The biggest release wflow has shipped. The editor stops being a step
list with an inspector and becomes a real node-graph workspace.

### Added

- **Free-positioning canvas.** Every step is a card; wires auto-route
  between consecutive steps; conditionals render as branch decision
  shapes; repeat is a container with an inline strip of inner steps.
- **Smart Tidy.** Sweeps column counts and picks the layout that keeps
  cards readable at the closest-to-1.0 zoom. Vertical / Horizontal /
  Grid still available for users who want a specific shape.
- **Multi-select and marquee.** Shift- or ctrl-click to add to the
  selection, lasso a region with shift- or ctrl-drag, alt-drag to draw
  a coloured group rectangle as a visual annotation.
- **Undo and redo.** Ctrl+Z / Ctrl+Shift+Z, debounced.
- **Step-by-step debugger.** ⏯ Debug pauses between every action,
  Step / Continue / Stop are the controls. Each step's status dot
  settles to green / red / grey. Repeat inner steps each get their
  own dot and pulse on every iteration.
- **Imports via `use NAME`.** Splice another workflow file into this
  one. The card carries an Open → button that loads the fragment in a
  new editor tab.
- **Refreshed first-run tour.** Covers debug, multi-select + groups,
  and imports. Tour key bumped to `intro_tour_v2`.
- **Eight bundled templates.** Morning sync joined the original seven
  and exercises every action category plus when, repeat, use, and
  groups in a single file.

### Changed

- Explore is gated off in 0.4.0 (`Theme.showExplore = false`). It
  comes back on as part of the v1.0 milestone alongside sign-in, the
  deeplink confirm dialog, and a detail drawer wired to live data.

---

## [0.3.26] — earlier

The Recorder consumes the wdotool-core 0.4 stream API instead of
maintaining its own portal + evdev pumps in the wflow tree. Same
behavior, less duplicated code.

---

## [0.3.0 — 0.3.25]

The 0.3.x line covered the engine fundamentals (every action category,
KDL on disk, the templated library, the trust prompt for unfamiliar
files, the CLI), the recorder, the GUI's first iteration of the
editor (still list-shaped at this point), and the AUR / Flathub
packaging. v0.4.0 is where the GUI grew up.

For the per-version bumps in this range, see the GitHub releases page:
<https://github.com/cushycush/wflow/releases>.
