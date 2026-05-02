# wflow backlog

As of 0.4.0 (2026-04-29), the editor redesign has shipped: free-position
canvas, branch shapes, repeat containers, multi-select + marquee, undo /
redo, group rectangles, the step-by-step debugger, run-feedback dots, and
imports / fragments. What's left is mostly wflows.com integration (the
target for v1.0) and the v0.5 daemon work.

# v1.0 = wflows.com integration

The Explore tab is hidden in 0.4.0 (`Theme.showExplore = false`). It
flips back on once the items in this section are done, at which point
we cut v1.0. Everything below this header is part of that release.

## Re-enable Explore

Flip `Theme.showExplore` back on. Don't ship until: the catalog is real
data (not the mock fixture), the deeplink confirm dialog exists, and
the detail drawer renders real fields + parsed steps. Without those
three, Explore is install-without-warning + fake metadata; with them,
it's a real catalog.

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

## Sign-in + favorites tab

Better Auth's session machinery on wflows.com would let the desktop
authenticate and show a "My favorites" tab populated from the user's
account. Same path enables posting comments and (eventually)
publishing. The gate is the auth flow itself: Better Auth is browser-
oriented, so the desktop probably wants a one-time "sign in via
browser, paste token back" handoff rather than embedding a webview.

# Other deferred work

## OS hotkey trigger sync

Workflows on wflows.com carry trigger metadata. When a user installs
one, we know they want it bound to "Super+Shift+P" or whatever; right
now they have to wire that up by hand. Once the v0.4 daemon ships
(see docs/designs/v0.4-leg1-trigger-daemon.md), the install path
should write the trigger into `~/.config/wflow/triggers.kdl` and ask
the daemon to pick it up. This depends on the daemon, so it lives
behind that work.

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

## Theme switcher with first-run picker

The `experiment/wflows-com-skin` branch has the desktop running on the
wflows.com warm-coral palette: cream paper / warm ink surfaces, coral
accent, muted category tints, and the new hero-card library layout.
The original amber-on-steel-blue feels distinct and confident for a
tool; the coral version unifies the brand with the website. Rather
than picking one, ship both and let the user choose.

Two parts. The settings page gets a palette picker that's orthogonal
to the existing light / dark / auto mode, persisted via
StateController the same way `theme_mode` is today. Theme.qml's color
tokens switch on the new state in addition to the existing isDark
check, so both palettes carry full light + dark coverage.

A one-time "pick a look" splash sits in front of the existing
blank-workflow TutorialOverlay on first run, previewing both palettes
side by side. Default to amber on skip so 0.4.x users don't get
surprised on upgrade.

Pre-req: land the full coral sweep first (canvas, inspector, settings,
chrome) so "amber / coral" is a real brand-wide swap and not just half
the surfaces.

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
