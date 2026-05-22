# Changelog

What landed in each release of wflow, what to look at first, and where
to read the full story. Highlights live in this file. Long-form prose
notes live one per release in [`docs/release-notes/`](docs/release-notes/).

Versions follow `MAJOR.MINOR.PATCH`. v1.0 marks the wflows.io
integration landing. Releases past 1.0 follow normal semver: minor for
additive features, patch for fixes, major when something genuinely
breaks.

---

## [1.3.0] - 2026-05-22

The view-source pane lands in the workflow editor, showing the current
workflow as KDL alongside the canvas and accepting edits that round-trip
back to the canvas. Plus the flat top app bar that walked back the
floating navpill, KDL copy/paste through the system clipboard, and
drag-a-`.kdl`-on-the-canvas import.

### Added

- **View-source pane in the workflow editor.** `</> Source` in the
  editor toolbar slides a panel in from the right of the canvas
  showing the current workflow as KDL, syntax-highlighted, re-encoded
  live as you change the canvas. The pane is editable: typing parses
  on a 600ms debounce and round-trips through `apply_kdl_source`,
  which swaps the in-memory workflow on success. Existing card
  positions survive the round-trip via a `preserve_step_ids` helper
  that walks old and new step lists by `std::mem::discriminant` of
  the action variant, so adding or removing a line doesn't relayout
  the unchanged cards. Tab inserts 4 spaces. Broken KDL surfaces a
  coral "● unparsed" chip in the header (parse error in a tooltip)
  and the canvas holds at last-good state until you click out or fix
  the source. Last-edit-wins on focus-loss; a broken draft gets
  discarded. Highlighting uses a hand-written C++ `QSyntaxHighlighter`
  (`cpp/kdl_syntax_highlighter.h`) attached to the body TextEdit's
  `QTextDocument`, re-tokenizing the local buffer per keystroke
  through `wfCtrl.tokenize_kdl` and applying `QTextCharFormat` ranges
  via `setFormat`. The document itself isn't rebuilt on each
  keystroke, so the cursor stays where the user left it.
- **Flat top app bar in place of the floating navpill.** The pill that
  floated over the canvas was forcing the editor toolbar to dodge it.
  The new app bar sits flush at the top of the window; the doc-tab
  strip and editor toolbar align underneath with no orphan-tab gap.
- **Copy and paste workflow steps as KDL through the system clipboard.**
  Right-click a card and Copy as KDL writes the kdl fragment to the
  clipboard via arboard (wlr-data-control with X11 fallback); paste on
  the canvas inserts at the current crumb. Multi-selection copies all
  selected top cards as one fragment; paste dedupes inner cards of any
  selected top.
- **Drop a `.kdl` file on the canvas to import it as steps.**
  Single-file drop lands the steps at the current crumb; multi-file
  drop loops over the dropped URLs. Pairs with the deeplink import
  path so a `.kdl` file reaches the editor by any route a file
  manager gives you.

### Changed

- **Explore drawer prefers the catalog trail over `kindSamples` while
  detail loads.** The drawer used to render the `kindSamples` preview
  during the loading window, then swap to the `kdlSource`-parsed shape
  once detail arrived; the swap was visible. Trail values match the
  final shape closely enough that reading from them first keeps the
  drawer steady from open through fully-loaded.

---

## [1.2.0] - 2026-05-09

Editor hot-reload for full workflow content, an `else` branch with first-class
canvas affordances, and a walk-back of the unified-chip experiment in the editor.

### Added

- **The editor now hot-reloads when the `.kdl` changes on disk.**
  v1.1.0 wired the library's notify watcher into the GUI but the
  editor only reloaded when this workflow's chord (or its
  when-condition) changed. Hand-edits to the file body, saves from
  the Library page, and renames sat as stale state in the canvas
  until you flipped pages. `WorkflowSummary` now carries a
  `disk_mtime` field (file-system mtime, not the in-file `modified`
  timestamp, which hand-edits don't bump on their own); the editor
  diffs that against its last-seen value and reissues `wfCtrl.load`
  when the file actually changed. The first snapshot for a workflow
  is adopted without firing a reload, and FS events fired during
  mid-save states (saving / saved / dirty / error) silently update
  the cached mtime so the post-save tail event from our own write
  doesn't re-render the canvas over what you just authored.
- **Else branches show up on the canvas, not just in the inspector.**
  The data model (`else_steps`) was already there but you had to
  open the inspector to grow one. The conditional card now carries
  two side-by-side stub buttons in its body, **+ true** and
  **+ else**, each opening the same step-kind menu the inspector
  uses; wire labels read **true** / **else** instead of yes / no,
  with green for the positive branch and red for the negative; the
  inspector's section heading flips from **FALSE BRANCH** to
  **ELSE BRANCH** to match. The new `addElseStepRequested` canvas
  signal hops through the same `_addElseStep` path the inspector
  already used, so the data model touches one code path regardless
  of where the click came from.
- **Conditional steps' primary value is editable from the top bar.**
  Editing the window name (or file path, or env name) for a `when`
  block no longer requires opening the inspector's condition
  section; the primary `TextField` every other step uses now drives
  cond.name / cond.path. Mode (when vs unless), predicate kind, and
  env's `equals=` stay in the inspector's condition section. The
  redundant "1 yes / 1 else" tag that used to render in the value
  pill (and overflow it on narrow widths) is gone, since the canvas
  paints both branches as wires.

### Fixed

- **Step move works when the workflow has notes or conditionals.**
  The rail's up/down arrows and the inspector's preceded-by /
  followed-by pickers all funnel into `_moveStep`, which spliced
  into `_stepsAtCrumb` (the raw KDL list) using indices from
  `root.actions` (the shaped list with notes filtered and
  conditional inners expanded as siblings). With either present the
  shaped index could sit past the end of the raw list, the bounds
  check caught the overrun, and the function silently returned. The
  reading from the user's seat was "the buttons just don't do
  anything." `_moveStep` now translates shaped to raw through
  `_topIdx` before splicing and rejects moves whose endpoints aren't
  top-level (inner-conditional cards belong to a parent's `steps` /
  `else_steps` array, not the top-level sequence).
- **`+` glyph alignment on the new when-card buttons.** The 12px
  glyph and the 9px label hugged the top of their Row, so the `+`
  floated above the text instead of reading as one chip. Same fix
  the open-import button next to it already used: anchor each Text's
  `verticalCenter` to the Row.

### Changed

- **Walked back the unified step-chip across the editor.** v1.1.0
  routed the canvas card hero, the step list rail rows, the drag
  preview, and the left toolbar through a single `StepChip` so the
  editor and the library would read as one product. Side by side
  they did, but the editor needs the kind glyph more than the
  library does: scanning a 2D field of cards on the canvas leans on
  silhouette, and the rail and toolbar both read better with a 22px
  icon than a 12px category-color dot. Reverted the canvas card
  hero (and drag-preview ghost) to `GradientPill`, the toolbar to
  its 56px / 200px icon-and-label rows, and the rail to its 44px
  status-badge + icon + title/value layout. Library trail pills
  keep `StepChip`, the surface it was designed for. The three-
  letter codes in the toolbar (`txt`, `clk`, `fcs`, `ntf`, …) and
  the hover-latch timer that came with the chip's width-stretch
  behaviour go with the revert.

---

## [1.1.0] - 2026-05-08

GUI hot-reload, an inline unbind, and a unified chip system across the editor.

### Added

- **The library and editor stay in sync with the workflows folder.** Until
  now the daemon was the only thing that watched
  `~/.config/wflow/workflows/` for KDL changes; the GUI loaded once at
  startup and went stale. Bind a chord on the Triggers page and the
  editor's pinned trigger card kept showing "+ Bind a chord" until you
  restarted. Each `LibraryController` now starts its own `notify`
  watcher on the workflows directory and refreshes its summary on FS
  events, so chord edits, hand-edits to the KDL, and renames all
  propagate without a restart. The editor also listens for
  `LibraryController` changes and reloads the open workflow when its
  chord actually changed (only its chord, not every save in the
  library, so typing into one workflow doesn't force a rebuild of
  another tab's editor).
- **Inline unbind on the editor's pinned trigger card.** Previously the
  only way to clear an editor-bound chord was to click the card, wait
  for the chord-capture dialog, and click "Clear binding" inside it.
  There's now a small × button on the card itself, visible whenever a
  chord is bound, with a "Unbind chord" tooltip. One click clears it.
- **Shared step-chip primitive across the editor.** wflows.io's library
  cards summarise step trails using a pill with a category-color dot
  and an abbreviated label (chord glyphs ⌃⇧⌘, shell first-token, type
  with quotes stripped). The same chip now drives the canvas card's
  hero pill, the step list rail rows, the drag preview when a card is
  dropping onto the canvas, and the left toolbar items. The toolbar's
  collapsed state shows a 3-letter code (`key`, `txt`, `clk`, `mov`,
  `scr`, `fcs`, `wt`, `sh`, `ntf`, `clp`, `if`, `if!`, `rep`, `use`)
  and expands to the friendly label on hover.

### Fixed

- **Row-wrap wires now exit the bottom of the source and enter the top
  of the target.** Tidy-smart with a 2-row layout placed the rightmost
  card of row 1 to the right of, and above, the leftmost card of row
  2; the wire between them is a true diagonal (no x or y overlap). The
  axis picker fell through to its catch-all and chose horizontal,
  which routed back across the entire source row as a horizontal
  back-flow. The diagonal branch now splits by direction: target right
  (column-wrap, end of col 1 → start of col 2) keeps horizontal so
  wires arc out the side edges; target left (row-wrap, end of row 1 →
  start of row 2) takes vertical so the wire exits source-bottom and
  U-bends down into target-top.
- **Two QML "Unable to assign [undefined]" warnings.** The community
  card's star pill bound `visible: card.wf && card.wf.stars` which
  evaluates to `undefined` (not `false`) when stars is missing, and
  the canvas's wire labels bound `text: modelData.label` for a
  potentially undefined label. Wrapping the first in `!!()` and
  defaulting the second with `|| ""` keeps QML's binding engine happy.

### Changed

- **Wire dash animation pauses while the canvas is moving.** Each wire
  is a `Shape` sized to the entire world Item, and the marching-ants
  dash effect re-rasterises that whole bounding rect every animation
  tick. The animation now skips frames while `panHandler.active`,
  `flick.moving`, or `root.visible` is false; a stationary canvas (or
  one on a background tab) costs nothing.
- **Library hot-reload log demoted from info to debug.** Three
  `library hot-reload armed` lines per launch was noise at default
  log level. Visible with `RUST_LOG=debug` if you actually want it.

[Full release notes](docs/release-notes/v1.1.0.md)

---

## [1.0.3] - 2026-05-07

[Full release notes](docs/release-notes/v1.0.3.md)

Editor canvas polish.

### Fixed

- **Trigger bind moved to the top-right of the canvas.** The pinned
  chord-bind card was anchored top-left, sharing the left edge with
  the StepPalette. At short canvas heights the palette (vertically
  centered) climbed under the card, and on hover the palette
  expanded from 56 to 200 pixels wide and overlapped the card
  entirely. Anchoring the card to the top-right gives the left edge
  to the palette and the right edge to the trigger, so they never
  collide.
- **Bind-a-chord dialog centers on the window.** When the trigger
  card moved to the top-right, clicking it opened the
  `ChordCaptureDialog` roughly centered on that small card and the
  dialog spilled off the window's right edge. The dialog used
  `anchors.centerIn: parent` and inherited whichever item it was
  declared inside. Setting `parent: Overlay.overlay` on the
  component makes it center on the window's overlay layer regardless
  of where it's instantiated.
- **Tidy-smart column-wrap wires are visible again.** The wire from
  the last card of column N to the first card of column N+1 was
  being routed vertically, out the top of the source and into the
  bottom of the target. The wire ran underneath the column's other
  cards and was barely visible. The axis picker had three cases
  (same-row, different-rows, overlapping) and the "different-rows"
  branch fired for any target not in the same row, lumping diagonals
  in with same-column targets. Splitting the branch so true
  diagonals (no overlap on either axis) pick horizontal lets the
  bezier arc cleanly across the column gap.

---

## [1.0.2] - 2026-05-05

[Full release notes](docs/release-notes/v1.0.2.md)

Flatpak polish for the Flathub submission.

### Fixed

- **Record-can't-start error reads correctly inside the Flatpak
  sandbox.** The upstream wdotool-core error suggested two fixes
  when no capture backend was reachable, one of which was "add
  yourself to the `input` group" so evdev can read
  `/dev/input/event*`. That's misleading inside Flatpak: the sandbox
  blocks `/dev/input` regardless of host group membership. The
  bridge now wraps the upstream message and swaps the footer for
  sandbox-aware guidance (install/restart `xdg-desktop-portal` on
  Plasma 6 / GNOME 46+; install the AUR or tarball builds on
  Hyprland / Sway, since Hyprland's portal doesn't ship
  RemoteDesktop yet). Outside the sandbox the original text is
  unchanged.
- **ExplorePage Row layout warning.** The "See all featured →"
  lockup put a Text with `verticalCenter` and a `MouseArea` with
  `anchors.fill` directly inside a Row, both fighting Row's own
  positioning. QML emitted a warning on every launch. Restructured
  to a wrapper Item with the Row and MouseArea as siblings.

---

## [1.0.1] - 2026-05-04

[Full release notes](docs/release-notes/v1.0.1.md)

Triggers do what they say.

### Fixed

- **Trigger when-predicates now gate dispatch.** The GUI has been
  letting users author `when window-class=firefox` since 1.0, but
  the daemon ignored the field. Pressing the chord fired the
  workflow regardless of focus. Daemon binds now route through a
  new internal `wflow trigger-fire <id>` wrapper that probes the
  focused window via Hyprland (`hyprctl activewindow -j`) or Sway
  (i3 IPC tree walk) before firing. KDE / GNOME portal users fail
  open until per-DE probes land.

### Added

- **Deeplink confirm dialog surfaces chord triggers.** Every chord
  the imported workflow wants bound shows as a key-cap pill in the
  "Will bind" section, with conflict detection against the local
  library. Accepting an import that takes `super+t` from an existing
  workflow now warns before the swap rather than after.

---

## [1.0.0] - 2026-05-04

[Full release notes](docs/release-notes/v1.0.0.md)

The catalog goes live. Explore is on, the desktop signs in to
wflows.io, you can import community workflows in one click, and you
can publish your own straight from the library card.

### Added

- **Live Explore tab.** Featured rows, browse with sort / search /
  tag filters, real install and comment counts, the detail drawer
  parses inline KDL through the runner's decoder so the step preview
  is what the engine would actually run. Mock fixtures are gone.
- **One-click import via `wflow://`.** Click Open in wflow on any
  wflows.io page; the desktop catches the URL, shows a confirm
  dialog (title, author, description, step count) before writing
  anything to disk. Drive-by pages can't silently install workflows.
- **Single-instance lock.** A second `wflow` invocation forwards
  argv to the running process via a Unix socket so deeplinks fire in
  your existing window.
- **Sign-in via browser handoff.** Settings → Account opens
  wflows.io in your browser; sign-in redirects to a
  `wflow://auth?token=...` URL the desktop catches. Token persists
  in `state.toml`. Nav-bar pill shows your handle when signed in.
- **Favorites tab in Explore** populated from your wflows.io
  account; 401s on authenticated calls route through a clean
  sign-out.
- **Publish from the library.** Right-click menu item plus a visible
  Publish pill on every card in the top-right corner when signed in.
  Walks you through description, tags, visibility; reads the KDL on
  disk, encodes through the same encoder the CLI uses, posts to
  `/api/v0/workflows`.
- **Triggers tab in the GUI.** Lists every active chord binding
  across your library, lets you add / edit / remove without hand-
  editing KDL. Chord-capture dialog, manual text entry for chords
  the compositor already grabs, when-predicates (window-class /
  window-title).
- **Daemon auto-enable.** First GUI launch offers to enable the
  systemd user unit; respects your decision afterwards.

### Changed

- **Brand domain is wflows.io** across the codebase, the marketing
  site, and the site repo. `WFLOW_SITE_ORIGIN` defaults there. The
  wflows.com domain is parked.
- **Settings → About** reads `env!("CARGO_PKG_VERSION")` instead of
  a hardcoded string.
- **KDL tokenizer on the website** accepts the v2 bareword set the
  desktop emits (chord syntax with `+`, bare strings in notify
  titles), so published workflows round-trip cleanly.

### Fixed

- Pinned trigger card on the editor canvas now reads the actual
  `trigger.kind.kind` shape and renders chord values correctly.
- Workflow picker dialog no longer overlaps its own rows.
- `wflow://` scheme handler installs on first GUI run, so sign-in
  no longer hangs at "Signing in…" on installs without an existing
  desktop entry.

---

## [0.7.0] - 2026-05-03

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

## [0.6.0] - 2026-05-02

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
  Repeat keeps INNER STEPS, there's no true / false split there.
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

## [0.5.0] - 2026-05-01

[Full release notes](docs/release-notes/v0.5.0.md)

The brand-palette release. wflow now ships two skins side by side and
you pick one on first run.

### Added

- **Two brand palettes.** Warm Paper (the wflows.io identity, cream
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
- Primary and Secondary buttons are pill-shaped, matching wflows.io
  button language. Library cards picked up `radiusLg` corners and a
  `lineStrong` hover border.
- The active tab in the floating nav pill no longer paints a coral
  focus ring on click; selection reads from the accent-wash fill.
- `CategoryChip` is pill-shaped with a hairline border, quieter, in
  the same family as wflows.io `.wf-trigger`.

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
  Supreme sans (the wflows.io brand faces). They read poorly at the
  dense UI sizes wflow uses, so we're back on Hanken Grotesk + Geist
  Mono. `familyDisplay` stays as a separate token hook for a future
  heavier display face.

---

## [0.4.1] - 2026-04-29

The left-rail selection in the editor follows the canvas marquee in
real time as the rect moves, instead of catching up only on release.

---

## [0.4.0] - 2026-04-29

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

## [0.3.26], earlier

The Recorder consumes the wdotool-core 0.4 stream API instead of
maintaining its own portal + evdev pumps in the wflow tree. Same
behavior, less duplicated code.

---

## [0.3.0, 0.3.25]

The 0.3.x line covered the engine fundamentals (every action category,
KDL on disk, the templated library, the trust prompt for unfamiliar
files, the CLI), the recorder, the GUI's first iteration of the
editor (still list-shaped at this point), and the AUR / Flathub
packaging. v0.4.0 is where the GUI grew up.

For the per-version bumps in this range, see the GitHub releases page:
<https://github.com/cushycush/wflow/releases>.
