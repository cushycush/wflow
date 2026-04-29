# wflow backlog

Follow-ups stacked behind the current redesign + wflows.com integration
work. Roughly ordered by what feels closest to ready.

## Deeplink import: confirm dialog

The `wflow://import?source=...` path runs the import the moment the
GUI lays out. A malicious page that opens such a URL in the user's
browser could quietly install a workflow they didn't intend to keep.
Add a small confirm dialog that shows the workflow's title, author,
description, step count, and a "from wflows.com" pill before we write
to disk. The detail JSON is already fetched; this is just a render
step plus a yes/no handoff.

## Detail drawer with live data

The Explore detail drawer still renders mock fields (imports, forks,
category) when a live row is selected. The mapper preserves the real
values, but the render paths haven't been re-pointed and the step
preview is fabricated from kinds rather than parsed from the KDL.

Two follow-ups in one sweep:
1. Show real installCount, commentCount, publishedAt, updatedAt from
   the v0 detail response.
2. Parse the inline `kdlSource` through the existing decoder and
   render the actual step list (not the synthetic preview). This also
   lets the drawer show the real values for shell commands, key
   chords, and so on, which is what users will actually want to read
   before installing.

## OS hotkey trigger sync

Workflows on wflows.com carry trigger metadata. When a user installs
one, we know they want it bound to "Super+Shift+P" or whatever; right
now they have to wire that up by hand. Once the v0.4 daemon ships
(see docs/designs/v0.4-leg1-trigger-daemon.md), the install path
should write the trigger into `~/.config/wflow/triggers.kdl` and ask
the daemon to pick it up. This depends on the daemon, so it lives
behind that work.

## Sign-in + favorites tab

Better Auth's session machinery on wflows.com would let the desktop
authenticate and show a "My favorites" tab populated from the user's
account. Same path enables posting comments and (eventually)
publishing. The gate is the auth flow itself: Better Auth is browser-
oriented, so the desktop probably wants a one-time "sign in via
browser, paste token back" handoff rather than embedding a webview.

## Run-history telemetry (paid)

A small daemon-side recorder that posts run outcomes (workflow id,
step count, ms elapsed, ok/error) to `/api/v1/runs`. The dashboard
lives on wflows.com under the user's profile. This is the natural
flagship of a Pro tier: people running workflows want to know which
ones break and how often. Needs the Pro tier, opt-in at install, and
a clear "delete my history" path.

## Cloud sync (paid)

The other half of Pro. Workflows + folder structure sync to the
account; a second machine signs in and pulls the same library. The
schema's `private` visibility is the wedge. Conflict resolution can be
last-write-wins for v1 with a nightly backup; per-step diff is way
more complexity than the audience needs at the start.

## Auto-update notifier

`workflow_versions` and `remixedFromId` are already in the wflows.com
schema. When a workflow you installed publishes a new version, the
desktop should ping the user with a "this got an update" toast and
let them apply or dismiss. Free feature, low cost, high stickiness.

## Group rectangles on the canvas

Lets the user drop a colored background rectangle behind a group of
steps with an editable comment label, so they can visually group
"this section is the build half" / "this section is the deploy
half" without touching the actual step structure. Requested
alongside multi-select and the debug stepper (both shipped); the
group rectangles want their own focused round because they touch
more layers than the other two combined.

What it'll need:

- A new `Group` shape in the workflow data model (alongside `Step`
  and `Action`) — fields: id, x / y / width / height in canvas
  coordinates, color, comment text. Serialised in the KDL format
  as a separate `groups { ... }` block; the engine ignores them
  (groups don't run, they annotate).
- KDL encode + decode pass plus round-trip tests.
- Bridge: extend the workflow JSON the editor consumes so the
  canvas sees groups alongside actions.
- Canvas rendering: a layer below the step cards that draws each
  group as a tinted rounded rectangle with its comment label in
  the upper-left. Resize handles on the four corners; drag-the-
  body to move; right-click for color picker + delete.
- UI: a "Group selection" affordance — when steps are multi-
  selected, an action button creates a group whose rect is the
  bounding box of those steps. Plus a "Frame" or "+ Group" entry
  in the tool dock for drawing one freehand on empty canvas.

Notes on integration:

- Z-order: groups always render below step cards and wires.
- Drag interaction: clicking inside a group selects the group, not
  the cards beneath it. Cards above the group keep their own
  click handlers — Qt's z-ordering handles this naturally as long
  as the group items render with a lower z than card items.
- Color palette: reuse the category tints (catKey through
  catRepeat) plus a small set of muted accents. No free-form
  color picker for v1; predefined swatches keep groups from
  fighting the rest of the UI.

## Smaller polish

- Settings page: an "Advanced" disclosure for motion durations
  (durFast/durBase/durSlow) and the WFLOW_SITE_ORIGIN override, so
  power users don't have to go through env vars or Theme.qml.
- ExploreController.fetch_browse triggers on every page open. Cache
  the last response in memory so back-and-forth navigation feels
  instant.
- Show an offline indicator when the catalog fetch fails, instead of
  silently rendering the mock list. A small "offline. showing cached
  results" pill at the top of Explore.
- The detail drawer's "Dry run" today opens the wflows.com page. A
  real desktop dry-run that walks the parsed steps without firing
  side effects would be more useful, and the engine already supports
  --dry-run from the CLI.
