# active

session-handoff state. claude updates this at every smoke-test point
or anywhere we might lose the session (relogin, crash, fresh chat).
fresh claude reading this: contents below are the source of truth for
what's hot right now. pair with BACKLOG.md for longer-lived planning
and the WFLOW Jira project for issue-level status.

## last session ended

KDL-first-class thread moved forward in two big steps before
matthew relogged. (1) The flat top app bar shipped + pushed at
17daaca, replacing the floating navpill that was forcing the
editor's toolbar to dodge it; doc-tab strip and toolbar now sit
flush under the app bar with no orphan-tab gap. (2) WFLOW-64 (kdl
syntax highlighting in the view-source pane) turned out to be
already committed at 29d0a70 from a prior session, pushed it in
the same run. (3) Editable view-source pane (WFLOW-66) is partway
in, committed but not pushed; details below.

## WFLOW-66 in-flight: editable view-source pane

State: scaffolding is in, structural plumbing works, the live
highlighting story isn't holding together yet.

What's built:
- `WorkflowController::apply_kdl_source(current_workflow_json, kdl)`
  in `src/bridge/workflow.rs`. Parses KDL, swaps the in-memory
  workflow on success, returns "" on success or the parse error
  message on failure. Preserves the workflow id from
  current_workflow_json. Includes a `preserve_step_ids` helper that
  walks old + new step lists in order, copies old.id onto new.id
  when the action variant matches (via `std::mem::discriminant` so
  new action kinds need no edit here), recurses into repeat /
  conditional inner steps. Without that, every step looks new
  on re-parse and the canvas re-layouts the whole graph.
- `qml/components/workflow/ViewSourcePane.qml`: `editable`,
  `workflowController`, `parseError` props, `applyRequested` signal,
  upstream-rebind gated on `_editing` (flips true on first printable
  key, false on focus-loss), 600ms `applyTimer` for parse-and-apply,
  150ms `rehighlightTimer` for live re-tokenize, "● unparsed" chip in
  the header on parse failure, Tab-to-4-spaces intercept,
  `tabStopDistance` set to 4 space widths.
- `qml/pages/WorkflowPage.qml`: passes `editable: !fragmentMode`,
  `workflowController: wfCtrl`, `parseError: root.sourceParseError`;
  `onApplyRequested` calls apply_kdl_source, schedules a save on
  success, clears parseError when sourceKdl moves, and
  `Qt.callLater(canvasView._zoomToFit)` after a successful apply so
  the camera frames the new layout.

What works:
- Edit a string value, ~600ms later the canvas updates and saveState
  flips dirty, saving, saved.
- Type broken KDL, coral "● unparsed" chip appears in the header,
  canvas stays at last-good state, parse error in the tooltip.
- Click a canvas step while broken-KDL is in the pane, last-edit-wins,
  pane snaps back to canonical, broken draft discarded.
- Add or remove a step line, existing cards keep their positions
  (preserve_step_ids), new card lands at the canvas default spot,
  camera zooms to fit the union. Matthew confirmed this reads right.

What's broken (next session):
- **Live highlighting goes wonky during edit.** Once you start typing,
  the colors don't track new text correctly and stay wonky until you
  close + reopen the source pane (which forces the binding to re-fire
  from canonical). Current code re-tokenizes locally + rebuilds HTML +
  saves/restores `body.cursorPosition` on a 150ms debounce. The
  underlying issue is fighting Qt's RichText TextEdit cursor +
  document model on every rebuild. Two reasonable next moves:
  (a) drop syntax highlighting entirely while `_editing` is true
  (switch to PlainText for the duration, snap back to RichText on
  focus-loss), or (b) bite off the proper Qt fix and ship a
  Rust-side `QSyntaxHighlighter` subclass exposed via cxx-qt
  attached to `body`'s `QQuickTextDocument`. (a) is the v1 fallback;
  (b) is the right long-term answer.
- **Tab key doesn't insert anything.** The `Keys.onPressed` handler
  is at default priority (`Keys.AfterItem`), so Qt's default Tab
  focus-traversal runs first and our handler never gets to call
  `body.insert`. Fix: add `Keys.priority: Keys.BeforeItem` to the
  TextEdit so the handler fires before the focus chain. Untested
  on disk; apply + dogfood next session.

Plus a small bookkeeping item: `scripts/jira/issues.csv` has WFLOW-66
appended; the row is already on the Jira side (created via
`seed.py import-csv` then `start WFLOW-66`). The CSV mod just needs
to land with the next commit that touches the catalog so the two
sources of truth match.

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

- (this commit, unpushed) editable view-source pane scaffolding,
  WIP (WFLOW-66). Working: parse + apply, position preservation,
  zoom-to-fit. Broken: live highlighting, Tab insertion. See the
  WFLOW-66 in-flight section above.
- 17daaca top app bar replaces the floating navpill; drop the
  topMargin workarounds in WorkflowPage / SettingsPage (WFLOW-65)
- 29d0a70 kdl syntax highlighting in the view-source pane (WFLOW-64)
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

`target/debug/wflow` is freshly built off the WFLOW-66 WIP commit
and includes the new top app bar + the view-source pane + the
editable pane scaffolding. Any running instance needs a relaunch
to pick it up (the running proc maps a deleted inode).

`.impeccable.md` is modified locally (synced to the current CLAUDE.md
Design Context: two palettes, six-step radii ladder, Theme.accentWash
selection). uncommitted; ship when convenient, separate concern from
the editable-pane work.

`scripts/jira/issues.csv` has WFLOW-66 appended (Editable view-source
pane, parent 14). Already on the Jira side via `seed.py import-csv`;
the CSV row is part of the WIP commit.

## environment

distro: arch (about to be drift, post-relogin). compositor:
hyprland (likely drift's hyprland fork after relogin). credentials
path: `~/.config/jira/env` (the canonical wflow one, symlinked
to from `~/.config/drift/jira.env`). jira CLI:
`python3 scripts/jira/seed.py {ping,projects,start,done,comment,
lookup,import-csv,transitions,sync}` from the wflow repo root.
