# Screenshot baseline

Visual baseline of the wflow desktop app. Used by Claude Design (and
anyone else looking at the project for the first time) to anchor
decisions to what's actually shipped.

## Manifest

The full set is 20 PNGs: 10 surfaces × 2 themes. Capture both dark
and light for each. Filenames use `<surface>.<theme>.png`.

| File                              | Surface                             | Notes                                      |
|-----------------------------------|-------------------------------------|--------------------------------------------|
| `library-grid.dark.png`           | Library, grid layout, populated     | Several workflows visible                  |
| `library-empty.dark.png`          | Library on first launch             | Empty state with the welcome card          |
| `editor-canvas.dark.png`          | Workflow editor, canvas view        | A workflow with 6+ steps + a conditional   |
| `editor-step-palette.dark.png`    | Editor palette dock expanded        | Hover over the left dock so labels slide in next to each colored chip |
| `editor-inspector.dark.png`       | Editor with a step selected         | Inspector panel slid in on the right       |
| `record-idle.dark.png`            | Record page, idle (amber)           | Big central button, no events captured     |
| `record-recording.dark.png`       | Record page, recording (red)        | A few events visible in the bottom drawer  |
| `explore-grid.dark.png`           | Explore page, grid + featured       | Hero + trending + new + browse             |
| `explore-detail.dark.png`         | Explore detail drawer open          | Slide-in over the grid                     |
| `settings.dark.png`               | Settings page                       | All sections visible                       |
| `library-grid.light.png`          | (same as above, light theme)        |                                            |
| `library-empty.light.png`         |                                     |                                            |
| `editor-canvas.light.png`         |                                     |                                            |
| `editor-step-palette.light.png`   |                                     |                                            |
| `editor-inspector.light.png`      |                                     |                                            |
| `record-idle.light.png`           |                                     |                                            |
| `record-recording.light.png`      |                                     |                                            |
| `explore-grid.light.png`          |                                     |                                            |
| `explore-detail.light.png`        |                                     |                                            |
| `settings.light.png`              |                                     |                                            |

If 18 is too many for a first pass, the priority subset is:
`library-grid.dark`, `editor-canvas.dark`, `record-idle.dark`,
`explore-grid.dark`, `settings.dark`. Five PNGs cover every page in
the app's dark theme (the default).

## How to capture

Use `scripts/grab.sh`. The default doesn't care about focus: it
queries the compositor for wflow's window by class, raises it, and
captures its geometry directly. The terminal you launched the script
from stays out of frame.

```fish
# In one terminal: build + launch the app
./scripts/capture-screenshots.sh

# In another terminal: capture the wflow window
./scripts/grab.sh library-grid.dark
# → docs/design/screenshots/library-grid.dark.png

# In the app:
#   - press Ctrl+. to flip themes
#   - ./scripts/grab.sh library-grid.light
#   - navigate to the next surface (Editor, Record, Explore, Settings)
#   - repeat
```

For modal / overlay states, `-r` falls back to slurp region select:

```fish
./scripts/grab.sh explore-detail.dark -r
```

For compositors that don't expose window-by-class lookup (vanilla
GNOME, KDE Plasma without wlroots IPC), pass `-d N`. The script
counts down for N seconds while you click on wflow, then captures
whichever window is focused via the desktop's native tool:

```fish
./scripts/grab.sh settings.light -d 3
```

Under the hood:
- **Hyprland**: `hyprctl -j clients` filter by class → focus + grim.
- **Sway / wayfire**: `swaymsg -t get_tree` filter by app_id → focus
  + grim.
- **`-d` fallback**: `gnome-screenshot --window`, `spectacle
  --activewindow`, or grim's active-window geometry, in that order.
- **`-r`**: `slurp | grim -g`.

If none of those exist, `grab.sh` tells you which to install.

Window decorations are fine to include or crop — Claude Design only
needs the app surface itself, but a little chrome doesn't hurt.

## What goes in each screenshot

Capture the **whole window** at the default size (1280×800). The
app's internal layout adapts; Claude Design wants to see the
intended composition, not a maximized one.

For state-specific captures (Record recording, Explore detail open),
get the app into the right state first, then capture. Don't include
debug panels, browser DevTools, or other windows in frame.

Avoid sensitive content: nothing that names a real coworker or
includes a real password / token in a step value. The sample
workflows in `examples/` are safe to use.

## Light theme coverage

Light is a fallback, not a priority. If any surface looks broken in
light mode (unintentional contrast issue, washed-out hover state),
flag it in the review pass rather than capturing it as a baseline.
