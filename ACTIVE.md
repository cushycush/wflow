# active

session-handoff state. claude updates this at every smoke-test point
or anywhere we might lose the session (relogin, crash, fresh chat).
fresh claude reading this: contents below are the source of truth for
what's hot right now. pair with BACKLOG.md for longer-lived planning
and the WFLOW Jira project for issue-level status.

## last session ended

new top-nav landed. matthew and claude mocked up four directions in
/tmp/wflow-nav-mockups.html (top app bar, left-docked nav, bottom
HUD pill, spotlight palette) and matthew picked the flat top app
bar. ChromeFloating.qml now renders a 48px strip at top:0 with the
brand mark + nav docked left and @cush + cog docked right;
StackLayout anchors below it instead of behind it. WorkflowPage and
SettingsPage dropped the `topMargin: 70` / `topMargin: 80`
workarounds that existed only to dodge the old floating pill. The
editor's doc-tab strip and toolbar now sit cleanly under the app
bar with no orphan-tab gap. cargo build clean, smoke-tested in the
GUI, matthew confirmed it reads right.

WFLOW-64 (KDL syntax highlighting in the view-source pane) is also
sitting on disk uncommitted from the prior session: tokenizer in
`src/kdl_format/highlight.rs`, qinvokable `tokenize_kdl` on the
workflow controller, HTML-with-spans rendering in ViewSourcePane,
a `Theme.kdlColor(kind)` mapper so all four palette skins read
right. cargo build + 137 tests green. GUI eyeball still pending.

## where the work stands

WFLOW Jira board: 65 issues across 8 epics now. Engine (WFLOW-1),
Editor (-2), Daemon (-3), Catalog & Explore (-4), CLI & tooling (-5),
Brand & design (-6), Commercial (-7), Drift integration (-8).
Credentials at `~/.config/jira/env` (chmod 600); drift's old
`~/.config/drift/jira.env` is a symlink to it.

Post-commit hook at `.git/hooks/post-commit` is symlinked to
`scripts/git-hooks/post-commit-jira`. Same hook is now installed in
drift too, fixed via 84b0ac7 (`readlink -f` to resolve the symlink
before computing seed.py's path).

KDL-as-first-class-citizen thread keeps growing. View-source pane
shipped in 44f5910 + 0a8536b: `</> Source` toggle in the workflow
toolbar slides in a read-only KDL pane on the right, mirroring the
live workflow through the new `WorkflowController::workflow_to_kdl`
qinvokable. Copy-to-clipboard works. Two cosmetic follow-ups split
out as their own tickets, called out below.

## strategic call open: KDL+Lua for drift

Drift was migrating to fully Lua. Claude's recommendation, in chat,
was KDL as the declarative spine plus init.lua as the escape valve
for power users, with the settings GUI only editing KDL. Pure-Lua
collapses the data/code distinction that the settings-GUI-edits-
the-same-files story depends on, and a pure-KDL approach holds back
hardcore users who want a programming model. Hybrid gives both, and
wflow speaks KDL natively so the drift.kdl `workflows {}` block
(WFLOW-43) is a one-line schema add.

This is a Drift architectural call, not a wflow call. Once matthew
decides, WFLOW-43 (drift.kdl workflows block) becomes concrete.
Until then it sits as a Task in To Do.

## up next when matthew returns

- **WFLOW-34** xdg-mime + .kdl association so `.kdl` files in a
  file manager open in wflow. Pairs with WFLOW-55 (already done) to
  close the file-manager round-trip.
- **WFLOW-58** deeplink import confirm dialog. Self-contained
  catalog work, small. Gates re-enabling the Explore tab (WFLOW-53).
- **WFLOW-43** drift.kdl `workflows {}` block schema. Blocked on
  the KDL+Lua strategic call above.

## to smoke test

WFLOW-64 (just shipped): open the source pane on a workflow with a
mix of nodes / strings / props / numbers / booleans / a `//`
comment. Eyeball that keywords (workflow/vars/imports/when/repeat/
use/etc) read accent-coloured, action verbs read blue-ish, strings
green-ish, numbers olive, `#true`/`#false` purple. Flip Theme
palette (warm ↔ cool) and Theme mode (dark ↔ light) and confirm
the highlight re-renders cleanly. Copy button should still paste
plain KDL (no HTML).

The older catalog / clipboard smoke tests are still outstanding from
before the relogin: drop a fragment-style .kdl on the canvas (coral
wash flashes, cards land at current crumb); multi-file drop loops
over urls; right-click a card and Copy as KDL, then `wl-paste` in a
terminal should print the kdl fragment; ctrl+c on a multi-selection
produces one kdl fragment with every selected top card; ctrl+v on
the canvas or right-click + Paste KDL inserts at the current crumb
with inner-cards-of-a-selected-top deduped; open a live wflows.io
card in Explore and confirm the drawer renders trail values during
the loading window before the kdlSource-parsed shape lands.

The view-source pane itself was smoke-tested green at 0a8536b: pane
renders on first open, copy + close buttons no longer overlap,
toolbar buttons clear the floating navpill.

## recently landed (since 9dffb8e)

- (this commit) top app bar replaces the floating navpill; drop the
  topMargin workarounds in WorkflowPage / SettingsPage (WFLOW-65)
- (unc'd) kdl syntax highlighting in the view-source pane (WFLOW-64)
- 0a8536b view-source pane: render on first open, fix Copy overlap,
  dodge the navpill (WFLOW-54)
- 44f5910 view-source pane on the canvas mirrors the live workflow
  as KDL (WFLOW-54)
- 84b0ac7 (in drift) resolve seed.py path through the symlink in
  post-commit-jira
- d3b60d6 decode_fragment_str so a kdl snippet parses without a
  file path (WFLOW-47)
- ab9eef9 copy / paste workflow steps as kdl through the system
  clipboard (WFLOW-48)
- 5fae7ee ship-prep example (WFLOW-51)
- 69a5089 dropped a value-laden "real" from the v0.6.0 readme line
- fc95591 drop a .kdl on the canvas to import it as steps
  (WFLOW-49)
- 103d1b1 explore drawer prefers the catalog trail over kindSamples
  while detail loads (WFLOW-50)
- 10e2b22 track ACTIVE.md as the session-handoff doc (WFLOW-8)
- 022dbcb jira scaffolding for the WFLOW project (WFLOW-8)

## working-tree state

`examples/dev-setup.kdl` is modified locally (ghostty / /home/cush /
no notify). uncommitted on purpose; matthew to decide whether to
ship. `examples/dev-setup.kdl.bak` holds the original (kitty /
/home/you / notify intact) and is untracked, staying per the
backup-artifacts rule.

`scripts/jira/issues.csv` has two new rows appended (64, 65) under
the Canvas task (work item 14) for the WFLOW-64 / WFLOW-65 tickets
created above. Tracked + ready to commit alongside the next change
that touches the catalog.

`target/debug/wflow` is freshly built off this commit and includes
the new top app bar + the view-source pane. Any running instance
needs a relaunch to pick it up (the running proc maps a deleted
inode).

`.impeccable.md` is modified locally (synced to the current CLAUDE.md
Design Context: two palettes, six-step radii ladder, Theme.accentWash
selection). uncommitted; ship when convenient, separate concern from
the chrome change.

## environment

distro: arch (about to be drift, post-relogin). compositor:
hyprland (likely drift's hyprland fork after relogin). credentials
path: `~/.config/jira/env` (the canonical wflow one, symlinked
to from `~/.config/drift/jira.env`). jira CLI:
`python3 scripts/jira/seed.py {ping,projects,start,done,comment,
lookup,import-csv,transitions,sync}` from the wflow repo root.
