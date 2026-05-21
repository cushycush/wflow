# active

session-handoff state. claude updates this on every smoke-test point
or anywhere we might lose the session (relogin, crash, fresh chat).
if you're a fresh claude reading this, the contents below are the
source of truth for what's hot right now; pair with BACKLOG.md for
longer-lived planning and the WFLOW Jira project for issue-level
status.

## right now

Jira scaffolding landed: WFLOW project on cushycush.atlassian.net
exists with 63 seeded tickets across 8 epics (Engine, Editor,
Daemon, Catalog & Explore, CLI & tooling, Brand & design,
Commercial, Drift integration). Recent shipped work is recorded
as Done sub-tasks under their umbrellas. Credentials live at the
canonical `~/.config/jira/env`; drift's old path is a symlink.
Post-commit hook installed; commits carrying `Refs: WFLOW-XX` or
`Closes: WFLOW-XX` trailers now post comments on the ticket and
move it to Done where applicable.

KDL-as-first-class thread up through 103d1b1 (copy/paste, drag-
drop import, explore drawer trail) all stand recorded as Done
sub-tasks (WFLOW-47 through WFLOW-51).

## to smoke test (matthew, when you get to it)

- WFLOW project on cushycush.atlassian.net: confirm the board
  renders the eight epics + their child tasks correctly, and that
  the five Done sub-tasks under Editor / Catalog show up where
  expected.
- post-commit hook: any commit on main with `Refs: WFLOW-XX`
  should post a comment on that ticket within a second or two.
  Verify on the next real commit; the jira-scaffolding commit
  itself carries `Refs: WFLOW-8`.
- (still pending from earlier) drop a .kdl on the canvas, copy/
  paste via ctrl+c/v, multi-select copy, explore drawer trail
  preview on a live wflows.io card.

## up next

KDL+Lua decision for Drift sits as a separate architectural call
(my recommendation is hybrid: KDL spine + Lua escape valve). Once
that lands or is rejected, the drift.kdl workflows-block work
(WFLOW-43) becomes concrete.

Closer to home, queued WFLOW sub-tasks:
- WFLOW-54 view-source toggle on the canvas (next on the kdl-
  first-class thread; bigger commitment)
- WFLOW-55 wflow run /path/to/file.kdl (small)
- WFLOW-34 + WFLOW-55 together get .kdl files openable from the
  file manager (xdg-mime registration)
- WFLOW-58 deeplink import confirm dialog (gates re-enabling
  Explore on WFLOW-53)

Drift integration epic (WFLOW-8) holds the OS-side stories that
land once the Drift compositor + launcher are ready to receive:
launcher integration (41), IPC triggers (42), drift.kdl block
(43), settings tab (44), first-boot starter workflows (45), ISO
bundling (46). These wait on Drift-side hooks.

For WDOTOOL: same scaffolding, not yet seeded. Lift this same
scripts/jira/ setup once and seed from wdotool's own backlog when
we're ready.

## recently landed (since 9dffb8e)

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

## working-tree state

- examples/dev-setup.kdl modified locally (ghostty / /home/cush /
  no notify). uncommitted on purpose; decide whether to ship.
- examples/dev-setup.kdl.bak: backup of the original (kitty /
  /home/you / notify intact). untracked. staying per backup-
  artifacts rule.
