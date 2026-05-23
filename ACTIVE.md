# active

session-handoff state. claude updates this at every smoke-test point
or anywhere we might lose the session (relogin, crash, fresh chat).
fresh claude reading this: contents below are the source of truth for
what's hot right now. pair with BACKLOG.md for longer-lived planning
and the WFLOW Jira project for issue-level status.

## last session ended

Drift palette in flight on branch `drift-palette`, one commit. Three
skins now: Warm Paper, Cool Slate, Drift. Drift is slate-900 dark /
cream-200 light surfaces with a gold-500 accent and slate/gold-
adjacent chip tints (plum / steel / sage / teal / ochre / terra).
`Theme.qml`'s `_pl` grew from 4 args to 6. Every token line now picks
via `_pl(coolDark, coolLight, warmDark, warmLight, driftDark,
driftLight)`. The Rust validator in `src/bridge/state.rs` accepts
"drift" alongside "warm" and "cool". Settings has a 3-up segmented
control; tutorial chooser has a 3-up tile row. CLAUDE.md and
.impeccable.md updated. Cargo build clean, `cargo test --bin wflow
palette` passes (drift round-trips through state.toml). Visual smoke
across all three skins x light/dark/auto is still matthew's pass
when back at the machine.

Bundled into the same commit: the deferred `.impeccable.md` sync from
the prior session (the working-tree state below called it out). The
diff is mixed but both edits are design-system docs landing on the
same paragraphs.

Before the drift work, v1.3.0 shipped end-to-end. The editable
view-source pane (WFLOW-66) landed through PR #38 along with
everything else that had accumulated since 1.2.0 (top app bar, KDL
clipboard copy/paste, drop-`.kdl`-on-canvas, explore drawer trail
preference). The release was tagged at the squash merge commit
`665c893`. README updated through PR #39 to add a real source-pane
screenshot to the editor section
(`docs/design/screenshots/editor-source-pane.dark.png`).

The view-source pane's live highlighting runs through a hand-written
C++ `QSyntaxHighlighter` in `cpp/kdl_syntax_highlighter.h`, attached
to the body TextEdit's `QTextDocument` from QML. Re-tokenizes per
keystroke via `wfCtrl.tokenize_kdl` and applies `QTextCharFormat`
ranges with `setFormat()` so the document isn't rebuilt and the
cursor stays put. cpp/ is new in the repo; `cxx-qt-build`'s
`.cpp_file()` compiles and mocs the header, and a small bridge at
`src/bridge/kdl_highlight.rs` exposes `register_kdl_qml_types()`
which `main.rs` calls before `QQmlApplicationEngine::load`.

## workflow rule going forward: no direct pushes to main

wflow is public/OSS. Every change reaches `main` through a PR, even
housekeeping, even ACTIVE.md updates, even one-line fixes. The 1.3.0
arc surfaced this. Several features (top app bar, KDL clipboard,
`.kdl` drop, explore drawer) had landed direct to main in earlier
sessions, which is why they ended up bundled into PR #38's release
notes instead of having their own PRs. Memory captures the rule at
`feedback_no_direct_push_to_main.md`; VOICE.md also has it in the
new "PR descriptions, specifically" section.

## where the work stands

WFLOW Jira board: 65 issues across 8 epics. Engine (WFLOW-1), Editor
(-2), Daemon (-3), Catalog & Explore (-4), CLI & tooling (-5), Brand
& design (-6), Commercial (-7), Drift integration (-8). Credentials
at `~/.config/jira/env` (chmod 600); drift's old
`~/.config/drift/jira.env` is a symlink to it.

Post-commit hook at `.git/hooks/post-commit` is symlinked to
`scripts/git-hooks/post-commit-jira`. Same hook installed in drift,
fixed via 84b0ac7 (`readlink -f` to resolve the symlink before
computing seed.py's path).

## strategic call open: KDL+Lua for drift

Drift was migrating to fully Lua. Claude's recommendation, in chat,
was KDL as the declarative spine plus init.lua as the escape valve
for power users, with the settings GUI only editing KDL. Pure-Lua
collapses the data/code distinction that the settings-GUI-edits-the-
same-files story depends on, and a pure-KDL approach holds back
hardcore users who want a programming model. Hybrid gives both, and
wflow speaks KDL natively so the drift.kdl `workflows {}` block
(WFLOW-43) is a one-line schema add.

This is a Drift architectural call, not a wflow call. Once matthew
decides, WFLOW-43 becomes concrete. Until then it sits as a Task in
To Do.

## up next when matthew returns

- **WFLOW-34** xdg-mime + .kdl association so `.kdl` files in a file
  manager open in wflow. Pairs with WFLOW-55 (already done) to close
  the file-manager round-trip.
- **WFLOW-58** deeplink import confirm dialog. Self-contained catalog
  work, small. Gates re-enabling the Explore tab (WFLOW-53).
- **WFLOW-43** drift.kdl `workflows {}` block schema. Blocked on the
  KDL+Lua strategic call above.

## to smoke test

Older catalog / clipboard smoke tests still outstanding from before
the 1.3.0 ship: drop a fragment-style .kdl on the canvas (coral wash
flashes, cards land at current crumb); multi-file drop loops over
urls; right-click a card and Copy as KDL, then `wl-paste` in a
terminal should print the kdl fragment; ctrl+c on a multi-selection
produces one kdl fragment with every selected top card; ctrl+v on
the canvas or right-click + Paste KDL inserts at the current crumb
with inner-cards-of-a-selected-top deduped; open a live wflows.io
card in Explore and confirm the drawer renders trail values during
the loading window before the kdlSource-parsed shape lands.

The view-source pane smoke-tested green during the 1.3.0 dogfood:
type into the KDL and the canvas updates on a 600ms debounce; tab
inserts 4 spaces; broken KDL surfaces the "unparsed" chip and the
canvas holds; existing colored tokens stay colored while typing;
new tokens highlight live; theme palette flips (warm to cool, dark
to light) re-render cleanly; cursor stays put across keystrokes.

## recently landed

- e78c15f (#39, merged) source-pane screenshot in the README editor
  section, plus a short paragraph on the two-way edit flow.
- v1.3.0 tag at `665c893` (the squash merge of #38).
- #38 (squash-merged at 665c893) ships the editable view-source
  pane end-to-end: parse-and-apply scaffolding, tab insertion,
  C++ `QSyntaxHighlighter` for live re-tokenize, defaultColor
  priming + `Binding.RestoreNone` for the two non-obvious gotchas
  that surfaced during dogfood. CHANGELOG + release note at
  `docs/release-notes/v1.3.0.md`.
- 17daaca top app bar replaces the floating navpill (WFLOW-65).
- 29d0a70 kdl syntax highlighting in the view-source pane (WFLOW-64).
- 0a8536b view-source pane: render on first open, fix Copy overlap,
  dodge the navpill (WFLOW-54).
- 44f5910 view-source pane on the canvas mirrors the live workflow
  as KDL (WFLOW-54).
- 84b0ac7 (in drift) resolve seed.py path through the symlink in
  post-commit-jira.
- d3b60d6 decode_fragment_str so a kdl snippet parses without a
  file path (WFLOW-47).
- ab9eef9 copy / paste workflow steps as kdl through the system
  clipboard (WFLOW-48).
- 5fae7ee ship-prep example (WFLOW-51).
- fc95591 drop a .kdl on the canvas to import it as steps (WFLOW-49).
- 103d1b1 explore drawer prefers the catalog trail over kindSamples
  while detail loads (WFLOW-50).

## working-tree state

`examples/dev-setup.kdl` modified locally (ghostty / /home/cush /
no notify). uncommitted on purpose; matthew to decide whether to
ship. `examples/dev-setup.kdl.bak` holds the original (kitty /
/home/you / notify intact) and is untracked, staying per the
backup-artifacts rule.

`.impeccable.md` shipped on the `drift-palette` branch alongside the
new palette. Absorbed the deferred sync (six-step radii ladder,
Theme.accentWash selection) plus a fresh "three palettes" paragraph
for Drift.

`scripts/jira/issues.csv` had WFLOW-64/65/66 rows appended over the
1.3.0 arc. WFLOW-64/65 still need to land alongside the next commit
that touches the catalog; WFLOW-66 landed as part of #38.

`target/debug/wflow` is built off the `drift-palette` branch tip and
includes the new third palette. Any running instance needs a relaunch
to pick it up (the running proc maps a deleted inode).

## environment

distro: arch (about to be drift, post-relogin). compositor: hyprland
(likely drift's hyprland fork after relogin). credentials path:
`~/.config/jira/env` (the canonical wflow one, symlinked to from
`~/.config/drift/jira.env`). jira CLI:
`python3 scripts/jira/seed.py {ping,projects,start,done,comment,
lookup,import-csv,transitions,sync}` from the wflow repo root.
