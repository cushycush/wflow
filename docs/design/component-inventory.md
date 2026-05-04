# Component inventory

Every reusable visual component in the desktop app, with its role, key
visual attributes, and where it appears. Organized by sub-directory in
`qml/components/`. Read this alongside `design-system.md`.

When designing new components for either platform (desktop or
website), match the visual treatments here so the language stays
unified.

## Glossary — surfaces and regions

Canonical names for the windows, panels, and regions you'll point at
in conversation or in screenshot filenames. Use these terms exactly:
they're how the codebase names things and how this doc + the design
brief refer back to them.

### App-shell chrome

| Term                    | What it is                                                                            | Anchor                                              |
|-------------------------|---------------------------------------------------------------------------------------|-----------------------------------------------------|
| **Floating nav pill**   | Top-center capsule with Library / Explore / Editor / Record + a gear for Settings.    | `qml/components/chrome/ChromeFloating.qml`          |
| **Tab strip**           | IDE-style row of open editor docs above the workflow body.                            | `tabBar` in `ChromeFloating.qml`                    |
| **Top bar**             | Page-level header — title, subtitle, action buttons on the right.                     | `qml/components/TopBar.qml`                         |
| **Dot grid**            | Subtle dotted backdrop behind every page.                                             | `qml/components/DotGrid.qml`                        |

### Pages (the top-level destinations)

| Term         | Surface                                              | File                              |
|--------------|------------------------------------------------------|-----------------------------------|
| **Library**  | Workflow grid + folder rail.                         | `qml/pages/LibraryPage.qml`       |
| **Explore**  | Community catalog (talks to wflows.io).             | `qml/pages/ExplorePage.qml`       |
| **Editor**   | Workflow authoring surface.                          | `qml/pages/WorkflowPage.qml`      |
| **Record**   | Capture mode with the ambient red wash.              | `qml/pages/RecordPage.qml`        |
| **Settings** | Preferences page.                                    | `qml/pages/SettingsPage.qml`      |

### Editor surfaces

The surface most people will need to refer to. Quick spatial map:

```
┌──────────────────────────────────────────────────────────┐
│  top bar (title, subtitle, Delete / Imports / Run …)     │
├────────────┬─────────────────────────────┬───────────────┤
│            │                             │               │
│  step list │                             │               │
│   ("rail") │     canvas                  │   inspector   │
│            │                             │   (slides in  │
│            │  ┌─palette─┐    ┌─tooldock─┐│   on select)  │
│            │  │ icons   │    │ tidy/wire││               │
│            │  │ (drag)  │    │ /zoom    ││               │
│            │  └─────────┘    └──────────┘│               │
│            │                             │               │
└────────────┴─────────────────────────────┴───────────────┘
```

| Term                    | What it is                                                                            | Anchor                                              |
|-------------------------|---------------------------------------------------------------------------------------|-----------------------------------------------------|
| **Canvas**              | Free-form 2D workspace where step cards and wires live.                               | `qml/components/workflow/WorkflowCanvas.qml`        |
| **Step palette**        | Vertical icon dock on the **left edge of the canvas** — drag to drop a new step.      | `qml/components/workflow/StepPalette.qml`           |
| **Tool dock**           | Vertical icon dock on the **right edge of the canvas** (Tidy / Wires / Zoom).         | `toolDock` in `WorkflowCanvas.qml`                  |
| **Inspector**           | Right-side panel that slides in when a step is selected. Edits the step's properties. | `qml/components/workflow/StepInspectorPanel.qml`    |
| **Step list** / **rail**| Numbered list of steps on the **left side** of the editor body.                       | `qml/components/workflow/StepListRail.qml`          |
| **Crumb** / breadcrumb  | Navigation chip showing where you are when drilled into a container's inner steps.    | inline in `WorkflowPage.qml`                        |
| **Step card**           | A single step rendered on the canvas.                                                 | `Repeater` delegate in `WorkflowCanvas.qml`         |
| **Wire**                | Line connecting two step cards.                                                       | `_wirePairs` in `WorkflowCanvas.qml`                |
| **Port dot**            | Small circle at a card's edge where a wire attaches.                                  | inline in `WorkflowCanvas.qml`                      |
| **Drag preview** / ghost| Card-shaped placeholder following the cursor during a palette drag.                   | inline in `WorkflowCanvas.qml`                      |
| **Gradient pill**       | Colorful labeled chip inside a step card showing the action's value.                  | `qml/components/GradientPill.qml`                   |

The "slide-in menu on the right" is the **inspector**.

### Library surfaces

| Term                  | What it is                                                                  | Anchor                                          |
|-----------------------|-----------------------------------------------------------------------------|-------------------------------------------------|
| **Library grid**      | Card grid of workflows.                                                     | `qml/components/library/LibraryGrid.qml`        |
| **Library list**      | Compact row layout (alternative to the grid).                               | `qml/components/library/LibraryList.qml`        |
| **Layout switcher**   | Small segmented control to flip between grid and list.                      | `qml/components/library/LibraryLayoutSwitcher.qml` |
| **Folder rail**       | Folder tree sidebar.                                                        | `folderRail` in `LibraryPage.qml`               |
| **Workflow card**     | One workflow entry in the grid.                                             | inline in `LibraryGrid.qml`                     |

### Explore surfaces

| Term                  | What it is                                                                  | Anchor                                          |
|-----------------------|-----------------------------------------------------------------------------|-------------------------------------------------|
| **Hero**              | Featured workflow card at the top.                                          | `qml/components/explore/ExploreHero.qml`        |
| **Category pills**    | Horizontal capsule filters.                                                 | `qml/components/explore/CategoryPills.qml`      |
| **Community card**    | One workflow card in the grid.                                              | `qml/components/explore/CommunityCard.qml`      |
| **Detail drawer**     | Right-side slide-in shown when you click a workflow card.                   | `qml/components/explore/ExploreDetail.qml`      |
| **Mini step**         | Compact step preview row used inside hero / card / drawer.                  | `qml/components/MiniStep.qml`                   |

### Record surfaces

| Term                  | What it is                                                                  | Anchor                                          |
|-----------------------|-----------------------------------------------------------------------------|-------------------------------------------------|
| **Ambient layout**    | Breathing radial-gradient backdrop that shifts color by state.              | `qml/components/record/AmbientRec.qml`          |
| **Record button**     | Big central capture-toggle.                                                 | inside `AmbientRec.qml`                         |
| **Event drawer**      | Bottom rectangle listing captured events.                                   | inside `AmbientRec.qml`                         |

### Modals + overlays

| Term                  | What it is                                                                  | Anchor                                          |
|-----------------------|-----------------------------------------------------------------------------|-------------------------------------------------|
| **Confirm dialog**    | Generic yes/no with a destructive variant.                                  | `qml/components/WfConfirmDialog.qml`            |
| **Menu**              | Right-click + dropdown menus.                                               | `qml/components/WfMenu.qml`, `WfMenuItem.qml`   |
| **Tutorial overlay**  | Inline arrow tooltip pointing at a UI affordance.                           | `qml/components/TutorialOverlay.qml`            |
| **Intro tutorial**    | Four-step first-launch modal.                                               | `qml/components/IntroTutorial.qml`              |
| **New workflow dialog** | Modal for creating a workflow (blank or from template).                   | `qml/components/workflow/NewWorkflowDialog.qml` |
| **Folder dialog**     | Native Qt `FolderDialog` for picking the workflows folder.                  | inline in `SettingsPage.qml`                    |

### Screenshot naming convention

Using these names, the manifest reads cleanly:

```
library.dark.png             ← Library page, grid layout
library-empty.dark.png       ← Library on first launch
editor-canvas.dark.png       ← Editor with canvas in focus
editor-inspector.dark.png    ← Editor with the inspector slid in
editor-palette.dark.png      ← Editor with the step palette expanded
record-idle.dark.png         ← Record page, idle (amber)
record-recording.dark.png    ← Record page, capturing (red)
explore-grid.dark.png        ← Explore page, hero + grid
explore-detail.dark.png      ← Explore detail drawer open
settings.dark.png            ← Settings page
```

## Buttons + form controls

### `PrimaryButton`

The dominant action button. Filled with `accent`, text in `accentText`.
6px radius, 14px padding horizontal, 8px padding vertical. Hover
swaps fill to `accentHi`. One per page max.

Used: header CTAs (Save, + New workflow, Run, Install workflow), modal
confirms.

### `SecondaryButton`

Quiet button on a `surface2` fill with a `line` hairline. Same shape
as `PrimaryButton` but no accent. Used for everything that isn't the
primary action: Cancel, Close, Browse, Reveal, Reset to default,
Share, Record (in the library header), Fork, Star.

### `IconButton`

Icon-only square button, ~24-28px. Hover lifts to `surface2`. Always
ships with a `ToolTip`. Used in close affordances (×), back arrow,
sidebar toggles.

### `SegmentedControl`

A compact pill of mutually-exclusive choices. Used in Settings (theme
mode, library sort), and historically in page headers for view
toggles. Active cell is `accentDim` wash, `accent` text, weight 600.
Inactive cells: `text2`, weight 500.

### `WfConfirmDialog`

Custom modal confirm. Surface fill, 8px radius, 24px padding.
Destructive variant uses `err` accent on the confirm button. Used for
delete + bulk delete + dangerous edits.

### `WfMenu` / `WfMenuItem`

Right-click + dropdown menus. Surface fill, hairline border, 6px
radius, 4px row gap. Hover: `surface2`. Destructive items render
text in `err`.

## Layout primitives

### `TopBar`

Page header. Title + subtitle on the left, action row on the right.
Sits flush with the top of each page. Used in Library, Explore,
Record, and Workflow editor.

### `Sidebar`

Left rail. Used by the editor (step rail, eventually) and by Library
(folder tree). 280-320px wide. `surface` fill, `lineSoft` rules.

### `SidebarWorkflow`

Source-list row in the editor's step rail. Selected uses the **2px
accent bar on the left** pattern (macOS Finder / VS Code). Hover
raises one surface step.

### `EmptyState`

Centered illustration + heading + body + primary action. Used when
the Library / a folder / the Record stop-state has nothing to show.
The action label is the next concrete thing the user should do, never
generic.

### `DotGrid`

Subtle dotted background pattern. Used as the page-level backdrop
behind Library, Explore, and the editor canvas. Dot color: a low-
opacity `text3`.

### `FocusRing`

The 2px-accent + 2px-offset focus ring used by every interactive
element with `activeFocusOnTab`. Implemented once, attached via
`FocusRing { }` inside any focusable Rectangle.

## Action representations

### `CategoryChip`

A pill labeled with an action kind, tinted by that kind's category
color. Used in step cards, the action row, the inspector. Reads "this
is a `key` step" at a glance.

### `CategoryIcon`

Round icon, color = category color, glyph = kind glyph (`⌘`, `T`,
`▷_`). 16-32px depending on context. Used inside chips, in the
StepPalette, and as the leading visual on every step card.

### `GradientPill`

The signature affordance: a horizontally-gradient pill with a leading
icon chip and a value text. Reads "this command is `kitty -e nvim`."
Used inside step cards and inside the Explore detail drawer. Gradient
colors come from `Theme.gradFor(kind)`. **No drop shadow** (banned).

### `MiniStep`

A compact step card for previews. ~32px tall. Used in `ExploreHero`
(workflow preview) and `CommunityCard` (mini stack of 2-3 steps). 8px
radius. Single line of value text.

### `ActionRow`

Full step row in non-canvas contexts (the linear inspector list).
Step number + category chip + value text + drag handle. Hover raises
one surface step.

## Editor surfaces (workflow page)

### `WorkflowCanvas`

Free-form 2D canvas where workflows are visually authored. Cards
positioned by drag, wires drawn between them. Conditionals branch to
the right. Notes render as soft secondary cards.

### `StepPalette`

The icon dock on the left edge of the canvas (Adobe / Figma style).
Vertical column of category icons, hover-expands to show labels. Drag
from the dock to drop a new step on the canvas.

### `StepListRail`

The sidebar column listing every step in a workflow as text. Click to
select, drag to reorder. Selected uses the 2px-accent-bar pattern.

### `StepInspectorPanel` / `SplitInspector`

Right-hand inspector for the selected step. Shows the action's
properties as form fields with inline help. Renders a different
schema per kind (a `key` step has a chord field; a `shell` step has a
command field plus warning about side effects).

### `OptionNumberRow`

A spinner row for numeric options (delays, repeats, retries). Up/
down arrows + a typed input. Used in the inspector.

### `NewWorkflowDialog`

Modal that asks for a name and either starts blank or seeds from a
template. Templates render as a vertical list of cards inside the
dialog body.

## Record surfaces

### `AmbientRec`

The Record page's ambient layout. Big breathing radial gradient
behind everything. Color shifts: amber when idle, dim red when armed,
full red while recording. Central "go" button is large and quiet
(let the mood do the talking). Pulse animation gates on
`!Theme.reduceMotion`.

## Library surfaces

### `LibraryGrid`

Cards in a responsive grid. Each card shows the workflow title,
subtitle, step count, last-run timestamp, and a small icon row of the
first 6 step kinds (with a `+N` overflow pill). Hover raises to
`surface2`.

### `LibraryList`

Compact list view. Same data as the grid, denser layout. One row per
workflow.

### `LibraryLayoutSwitcher`

A small segmented icon button to switch between Grid and List
layouts. Lives in the page header.

## Explore surfaces (talks to wflows.io)

### `ExploreSearch`

The search field at the top of the Explore page. Surface2 fill, 6px
radius, leading magnifier glyph.

### `CategoryPills`

A horizontal row of capsule pills for filtering. Active pill: amber
wash + amber text. Inactive: `surface2` + `text2`.

### `ExploreHero`

The featured workflow card at the top of Explore. Editor's-pick label
+ title + subtitle + author + horizontal mini-step preview. Amber-
washed bezel. Big primary "Import" button on the right.

### `CommunityCard`

The standard community workflow card used in the trending row, the
new row, and the browse grid. Avatar byline, mini-stack preview of
the first 2-3 step kinds, stats footer (imports + forks + steps),
shell-warning pip if the workflow contains shell commands.

### `ExploreDetail`

Right-side slide-in drawer when a workflow is selected. Steps render
as mini cards; shell actions get a warning banner; Import + Dry run +
Open in browser buttons at the bottom.

## Chrome

### `ChromeFloating`

The single-source app-shell. Floating top-center nav pill (Library /
Explore / Editor / Record + a gear for Settings). The pill itself is
8px radius, 6px tab radius. Active tab fills with accent wash.

## Tutorial / onboarding

### `IntroTutorial`

Four-step intro shown once on first launch. One column per step:
title, headline, body. Marked seen via state.toml so it doesn't
re-show.

### `TutorialOverlay`

Inline tooltip with an arrow used to point at specific UI affordances
(currently the "+ Add step" button in the editor). 8px radius, accent
border, accent-tinted background fill.

## Brand mark

Three logo concepts in `docs/branding/` (icon + wordmark variants).
Concept A (stepped valleys) is currently the recommended primary mark.
Wordmark = icon + lowercase "flow" set in Hanken Grotesk 700.
