# Example workflows

Hand-authored `.kdl` files that demonstrate every feature of the wflow
language. Use these as starting points: read a file, copy it, edit the
paths and program names to match your system, then run.

| File | What it does | Showcases |
|---|---|---|
| [`dev-setup.kdl`](dev-setup.kdl) | Opens a project's terminal + editor + browser side by side | `vars`, `shell`, `wait-window`, `focus`, `key`, `notify` |
| [`screenshot-and-share.kdl`](screenshot-and-share.kdl) | grim+slurp region capture → wl-copy the path → notify | shell capture (`as=`), `{{var}}` substitution, `clipboard` |
| [`daily-standup.kdl`](daily-standup.kdl) | Open Slack, focus the channel, paste a templated message | `imports` + `use` (fragment splicing), `vars` |
| [`loop-tab-thru.kdl`](loop-tab-thru.kdl) | Cycle 5 browser tabs with a pause between each | `repeat` block |
| [`if-vpn-then.kdl`](if-vpn-then.kdl) | Mount the corp share + open the wiki only when VPN is up | `when env=`, `unless file=`, `unless env=` |
| [`flaky-deploy-trigger.kdl`](flaky-deploy-trigger.kdl) | Trigger a deploy with retries, backoff, timeout, and continue-on-fail | shell `retries=` / `backoff=` / `timeout=` / `on-error="continue"` |
| [`record-replay-export.kdl`](record-replay-export.kdl) | A representative output of Record Mode — drag-select + paste | `key-down` / `key-up` / `mouse-down` / `mouse-up` / `move` |

The fragment imported by `daily-standup.kdl` lives at
[`lib/standup-message.kdl`](lib/standup-message.kdl). Fragments are
separate `.kdl` files holding a bare list of step nodes (no
`workflow` wrapper) — see [`docs/KDL.md`](../docs/KDL.md#imports--use)
for the spec.

## Try one

```sh
# Read it first.
wflow show examples/dev-setup.kdl

# See exactly what it would run, without running anything.
wflow run --explain examples/dev-setup.kdl

# Run it. wflow will prompt the first time, since it isn't yours yet.
# (See REVIEW.md for the trust model.)
wflow run examples/dev-setup.kdl
```

## Adapting to your system

The hardcoded paths (`/home/you/projects/wflow`, etc.) are deliberately
fake. Swap them for your real values, or — better — define them once in
each file's `vars { }` block and reference via `{{name}}`. That way the
rest of the workflow stays portable.

Programs called by `shell "..."` assume Hyprland (`hyprctl dispatch
exec`), Firefox, kitty, and Slack. If your stack differs, swap those
strings and the workflows still work.

## CI validation

Every commit runs `wflow validate examples/*.kdl` — every example here
is shipped as a parsable, schema-correct workflow. If your edits break
parsing (typo in a property name, missing required field, etc.), CI
catches it before merge.
