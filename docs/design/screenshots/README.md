# Screenshot baseline

Visual baseline of the wflow desktop app. Used by Claude Design (and
anyone else looking at the project for the first time) to anchor
decisions to what's actually shipped.

## Manifest

The full set is 18 PNGs: 9 surfaces × 2 themes. Capture both dark and
light for each. Filenames use `<surface>.<theme>.png`.

| File                              | Surface                             | Notes                                      |
|-----------------------------------|-------------------------------------|--------------------------------------------|
| `library-grid.dark.png`           | Library, grid layout, populated     | Several workflows visible                  |
| `library-empty.dark.png`          | Library on first launch             | Empty state with the welcome card          |
| `editor-canvas.dark.png`          | Workflow editor, canvas view        | A workflow with 6+ steps + a conditional   |
| `editor-detail.dark.png`          | Editor with a step selected         | Inspector panel slid in on the right       |
| `record-idle.dark.png`            | Record page, idle (amber)           | Big central button, no events captured     |
| `record-recording.dark.png`       | Record page, recording (red)        | A few events visible in the bottom drawer  |
| `explore-grid.dark.png`           | Explore page, grid + featured       | Hero + trending + new + browse             |
| `explore-detail.dark.png`         | Explore detail drawer open          | Slide-in over the grid                     |
| `settings.dark.png`               | Settings page                       | All sections visible                       |
| `library-grid.light.png`          | (same as above, light theme)        |                                            |
| `library-empty.light.png`         |                                     |                                            |
| `editor-canvas.light.png`         |                                     |                                            |
| `editor-detail.light.png`         |                                     |                                            |
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

Use `scripts/grab.sh`, which handles two annoyances at once: it
resolves output paths under `docs/design/screenshots/` regardless
of where you run it from, and it picks the right window-capture tool
for whichever compositor is up (Hyprland, Sway, GNOME, KDE Plasma).

```fish
# In one terminal: build + launch the app
./scripts/capture-screenshots.sh

# In another terminal: capture the focused window
./scripts/grab.sh library-grid.dark
# → docs/design/screenshots/library-grid.dark.png

# Then in the app:
#   - press Ctrl+. to flip to light theme
#   - ./scripts/grab.sh library-grid.light
#   - navigate to the next surface (Editor, Record, Explore, Settings)
#   - repeat
```

If a modal / overlay isn't the topmost focused window (e.g. you want
to capture the Explore detail drawer mid-animation, or a context
menu), pass `-r` to fall back to a slurp region select:

```fish
./scripts/grab.sh explore-detail.dark -r
```

Under the hood:
- **Hyprland**: `hyprctl -j activewindow` → geometry → `grim -g`.
- **Sway / wayfire**: `swaymsg -t get_tree` → focused node geometry
  → `grim -g`.
- **GNOME**: native `gnome-screenshot --window --file=…`.
- **KDE Plasma 6**: `spectacle --activewindow --background --nonotify`.

If none of those exist, `grab.sh` tells you to install one — or to
pass `-r` for a manual region select via slurp.

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
