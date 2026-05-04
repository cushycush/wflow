# Screenshot baseline

Visual baseline of the wflow desktop app. Used by Claude Design (and
anyone else looking at the project for the first time) to anchor
decisions to what's actually shipped.

## Manifest

The full set is 30 PNGs: 15 surfaces × 2 themes. Capture both dark
and light for each. Filenames use `<surface>.<theme>.png`.

| File                              | Surface                             | Notes                                      |
|-----------------------------------|-------------------------------------|--------------------------------------------|
| `library-grid.dark.png`           | Library, grid layout                | Five workflow cards plus the Daily folder tile |
| `library-folder-open.dark.png`    | Library, inside a folder            | Drilled into Daily; Resume coding + Daily standup visible |
| `library-publish-pill.dark.png`   | Library, signed-in card pills       | Top-right '↑ Publish' pill on every card; only meaningful when signed in |
| `editor-canvas.dark.png`          | Workflow editor, canvas             | Resume coding, Smart-tidied; the when/else block fans into two branches |
| `editor-step-palette.dark.png`    | Editor palette dock expanded        | Hover over the left dock so labels slide in next to each chip |
| `editor-inspector.dark.png`       | Editor with a step selected         | Inspector slid in on the right             |
| `editor-trigger-card.dark.png`    | Editor pinned trigger card          | Top-left card showing the chord (super+shift+c) |
| `triggers-tab.dark.png`           | Triggers tab in chrome              | List of bound workflows with their chords  |
| `explore-grid.dark.png`           | Explore tab, live catalog           | Featured row + browse grid populated from wflows.io |
| `explore-detail.dark.png`         | Explore detail drawer open          | Slide-in over the grid                     |
| `record-idle.dark.png`            | Record tab, idle                    | Big amber button, no events captured       |
| `record-recording.dark.png`       | Record tab, mid-session             | Events streaming in below                  |
| `settings.dark.png`               | Settings page top                   | First sections visible                     |
| `settings-account.dark.png`       | Settings → Account                  | Sign-in button or @handle row depending on state |
| `settings-palette.dark.png`       | Settings → Palette                  | Warm Paper / Cool Slate switcher           |
| `publish-dialog.dark.png`         | Publish dialog mid-fill             | Description + tags entered; signed-in only |

Each row above also has a `.light.png` counterpart.

If 30 is too many for a first pass, the priority subset is:
`library-grid.dark`, `editor-canvas.dark`, `triggers-tab.dark`,
`explore-grid.dark`, `record-idle.dark`, `publish-dialog.dark`.
Six PNGs cover the v1.0 launch story in the default dark theme.

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
