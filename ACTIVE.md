# active

session-handoff state. claude updates this at every smoke-test point
or anywhere we might lose the session (relogin, crash, fresh chat).
fresh claude reading this: contents below are the source of truth for
what's hot right now. pair with BACKLOG.md for longer-lived planning
and the WFLOW Jira project for issue-level status.

## last session ended

matthew was about to relogin to update to a new drift binary, so this
file is the handoff. project tracking infra for WFLOW landed; the
strategic question on KDL+Lua for drift sits open pending matthew's
call; matthew's smoke-test punch list below is from sessions before
the relogin and is still outstanding.

## where the work stands

Jira scaffolding for WFLOW is live on cushycush.atlassian.net. 63
issues across 8 epics: Engine (WFLOW-1), Editor (-2), Daemon (-3),
Catalog & Explore (-4), CLI & tooling (-5), Brand & design (-6),
Commercial (-7), Drift integration (-8). Recently-shipped sub-tasks
(WFLOW-47 through WFLOW-52) sit in Done so the board reflects
reality on day one. Credentials live at the canonical
`~/.config/jira/env` (chmod 600); drift's old `~/.config/drift/jira.env`
is a symlink to it.

Post-commit hook at `.git/hooks/post-commit` is symlinked to
`scripts/git-hooks/post-commit-jira`. On every commit, the hook reads
`Refs: WFLOW-XX` and `Closes: WFLOW-XX` trailers (and `DRIFT-XX` too,
for cross-project refs from drift-integration commits), posts the
commit subject as a comment on each referenced ticket, and
transitions `Closes:` tickets to Done. WFLOW-8 has two comments
from the scaffolding commits proving the hook fires.

KDL-as-first-class-citizen thread up through 103d1b1 (copy/paste,
drag-drop import, explore drawer trail preview) all stand recorded
as Done sub-tasks (WFLOW-47, 48, 49, 50, 51).

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

## to smoke test (matthew, when you're back)

WFLOW board first: open
https://cushycush.atlassian.net/jira/software/projects/WFLOW and
confirm the eight epics plus child tasks render, and the five Done
sub-tasks under Editor / Catalog show up where expected.

Post-commit hook: write any commit with `Refs: WFLOW-XX` as a
trailer; within roughly a second the ticket should get a comment
with the subject line.

Older smoke tests still pending from before the relogin: drop a
fragment-style .kdl on the canvas (coral wash flashes, cards land
at current crumb); multi-file drop loops over urls; right-click a
card and Copy as KDL, then `wl-paste` in a terminal should print
the kdl fragment; ctrl+c on a multi-selection produces one kdl
fragment with every selected top card; ctrl+v on the canvas or
right-click + Paste KDL inserts at the current crumb with inner-
cards-of-a-selected-top deduped; open a live wflows.io card in
Explore and confirm the drawer renders trail values during the
loading window before the kdlSource-parsed shape lands.

## latent bug to flag

`drift/scripts/git-hooks/post-commit-jira` has the same readlink
bug claude caught and fixed in wflow's copy.
`hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` resolves
to `.git/hooks/` because BASH_SOURCE points at the symlink path,
so `$hook_dir/../jira/seed.py` lands at `.git/jira/seed.py` which
doesn't exist. Every dispatch call has `|| true`, so the hook
silently no-ops. Drift commits since the hook was installed have
probably been failing to post to their tickets. The fix is one
line:

```
hook_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
```

Apply via a one-line edit in drift's repo plus a small commit.
Worth doing in a future session, not urgent.

## up next (matthew picks)

WDOTOOL Jira setup is the closest follow-on: mirror what we did
for WFLOW, lift the seeder, draft a CSV that fits wdotool's
BACKLOG.md and CLAUDE.md, run the same import-csv + transitions
flow. Roughly half an hour.

The drift hook fix above is a tiny one-line edit plus a small
commit, maybe five minutes, drop-in any session.

For the KDL-first-class thread on wflow itself, three queued
sub-tasks: WFLOW-54 view-source toggle on the canvas (a read-only
KDL pane mirroring the live workflow; bigger commitment, but
where KDL stops being just the export format and becomes co-equal
with the canvas), WFLOW-55 wflow run /path/to/file.kdl (small
CLI entry), and WFLOW-34 xdg-mime + .kdl association (pairs with
-55 so a .kdl in a file manager opens in wflow).

Drafting the drift.kdl `workflows {}` block schema (WFLOW-43)
gives Drift's config work a concrete wflow surface to plug into.
Useful even before the KDL+Lua call lands, since it sharpens the
case.

WFLOW-58 deeplink import confirm dialog gates re-enabling the
Explore tab (WFLOW-53). Self-contained piece of catalog work,
small.

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
- 10e2b22 track ACTIVE.md as the session-handoff doc (WFLOW-8)
- 022dbcb jira scaffolding for the WFLOW project (WFLOW-8)

## working-tree state

examples/dev-setup.kdl is modified locally (ghostty / /home/cush /
no notify). uncommitted on purpose; matthew to decide whether to
ship. examples/dev-setup.kdl.bak holds the original (kitty /
/home/you / notify intact) and is untracked, staying per the
backup-artifacts rule.

The wflow editor binary at `target/debug/wflow` includes the
copy/paste plus drag-drop work. If a binary stale-check is needed
on the new drift session, rebuild with `cargo build` from the
wflow repo root.

## environment

distro: arch (about to be drift, post-relogin). compositor:
hyprland (likely drift's hyprland fork after relogin). credentials
path: `~/.config/jira/env` (the canonical wflow one, symlinked
to from `~/.config/drift/jira.env`). jira CLI:
`python3 scripts/jira/seed.py {ping,projects,start,done,comment,
lookup,import-csv,transitions,sync}` from the wflow repo root.
