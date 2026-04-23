# The wflow KDL format

A wflow workflow is a [KDL](https://kdl.dev) document. KDL is whitespace-
sensitive, bracket-free for the most part, and reads like a configuration
file. One workflow per file. One `recipe { ... }` block holds the steps.

## Quick example

```kdl
schema 1
id "morning-standup"
title "Morning standup"
subtitle "open slack, zoom, and the notes doc"

recipe {
    shell "hyprctl dispatch exec 'slack'"
    await-window "Slack" timeout="10s"

    shell "hyprctl dispatch exec 'zoom'"
    await-window "Zoom" timeout="15s"

    shell "hyprctl dispatch exec 'obsidian ~/notes/standup.md'"
    await-window "Obsidian" timeout="10s"

    notify "ready" body="all three apps are up"
}
```

Run with `wflow run morning-standup` or `wflow run ./path/to/file.kdl`.

## Document structure

Every workflow file has the same shape:

```kdl
schema 1               // required; only value 1 today
id "some-stable-id"    // required; filename is derived from it
title "Human title"    // required
subtitle "one line"    // optional; shown in list and editor

recipe {
    // steps here, one per line, top-to-bottom execution
}
```

The file can also carry `created`, `modified`, and `last-run` timestamps
(RFC 3339). `wflow run` writes `last-run` back after a successful run;
you generally don't hand-write these.

## Actions

Every line inside `recipe { ... }` is one step. The first word picks the
action; positional arguments come next; properties (`key=value`) come
last in any order.

| Kind | Syntax | Runs |
|---|---|---|
| [`type`](#type) | `type "text" delay-ms=30` | `wdotool type --delay 30 -- "text"` |
| [`key`](#key) | `key "ctrl+l" clear-modifiers=#true` | `wdotool key [--clearmodifiers] ctrl+l` |
| [`click`](#click) | `click button=1` | `wdotool click 1` |
| [`move`](#move) | `move x=120 y=80 relative=#false` | `wdotool mousemove [--relative] 120 80` |
| [`scroll`](#scroll) | `scroll dx=0 dy=3` | `wdotool scroll 0 3` |
| [`focus`](#focus) | `focus window="Firefox"` | `wdotool search --limit 1 --name Firefox` + `windowactivate <id>` |
| [`await-window`](#await-window) | `await-window "Firefox" timeout="5s"` | poll `wdotool search` until match or timeout |
| [`wait`](#wait) | `wait "1.5s"` | `tokio::time::sleep` (no subprocess) |
| [`shell`](#shell) | `shell "notify-send done"` | `$SHELL -c "notify-send done"` |
| [`notify`](#notify) | `notify "title" body="body"` | `notify-send "title" "body"` |
| [`clip`](#clip) | `clip "text to copy"` | `wl-copy` (pipes stdin) |
| [`note`](#note) | `note "reminder to self"` | nothing — a comment; always skipped |

Every action accepts the common step properties:

- `disabled=#true` — keep the step in the file but skip it at runtime.
- `comment="..."` — free-form note the UI shows in the margin.

### type

Types a unicode string via wdotool. `delay-ms` puts a per-character
pause between keystrokes — useful for apps that drop fast input.

```kdl
type "hello, world"
type "password" delay-ms=50
```

### key

Sends a key or chord. Chords use wdotool's naming: `super`, `ctrl`,
`shift`, `alt`; letter keys lower-case; special keys Title-cased
(`Return`, `Tab`, `Escape`, `BackSpace`, `Left`, `Right`, `Up`,
`Down`, `F1`–`F12`).

```kdl
key "Return"
key "ctrl+l"
key "ctrl+shift+t"
key "super+1" clear-modifiers=#true
```

`clear-modifiers=#true` releases any held modifier keys before sending
the chord. Useful when you don't trust the prior state.

### click

Mouse button press-release at the current cursor position. Buttons
follow X11 convention: `1`=left, `2`=middle, `3`=right, `8`=back,
`9`=forward.

```kdl
click button=1
```

### move

Move the cursor. `relative=#false` (default) treats `x,y` as absolute
screen coordinates. `relative=#true` makes them a delta from the
current position.

```kdl
move x=640 y=480
move x=100 y=0 relative=#true
```

### scroll

Scroll by wheel clicks. `dy` positive = down, `dx` positive = right.

```kdl
scroll dx=0 dy=3
scroll dx=0 dy=-5
```

### focus

Activate the first window whose title contains `window=`. Errors
immediately if no matching window exists — pair with `await-window`
if the window might not be up yet.

```kdl
focus window="Firefox"
```

### await-window

Block until a window matching the positional argument exists, or the
timeout elapses. This is the primitive that turns a racy workflow
into a reliable one.

Timeout can be either `timeout-ms=5000` or `timeout="5s"`. Defaults
to 5 seconds if omitted.

```kdl
shell "firefox"
await-window "Firefox" timeout="10s"
focus "Firefox"
key "ctrl+l"
type "hyprland wiki"
key "Return"
```

If the window never appears, the step errors and the workflow halts.

### wait

Fixed-duration sleep. No subprocess, so cheap. Accepts four input
shapes:

```kdl
wait 500             // bare integer, milliseconds
wait ms=500          // explicit prop form
wait "1.5s"          // duration string (s | ms | m | h)
wait "250ms"
wait "2m"
```

Prefer `await-window` over `wait` whenever you're waiting for
something specific to appear — `wait` is for deliberate pacing
(e.g. letting an animation finish).

### shell

Runs a string through `$SHELL -c`. The step's `output` in the run
report is stdout + stderr combined. Nonzero exit status fails the
step and halts the workflow.

```kdl
shell "hyprctl dispatch exec 'firefox'"
shell "git -C ~/projects/wflow status --short"
shell "notify-send 'ok' 'step 3 done'"
```

Override the shell with `shell="/bin/bash"` if `$SHELL` isn't what
you want:

```kdl
shell "echo $0" shell="/bin/bash"
```

### notify

Convenience wrapper over `notify-send`. Equivalent to
`shell "notify-send 'title' 'body'"` but declarative.

```kdl
notify "done"
notify "build failed" body="see ~/tmp/build.log"
```

### clip

Copy text to the Wayland clipboard via `wl-copy`.

```kdl
clip "git@github.com:cushycush/wflow.git"
```

### note

A step that does nothing at runtime — a comment that shows up in the
UI and in `wflow show`. Useful for annotating stretches of a recipe.

```kdl
note "the next two steps unlock the keychain"
key "super+space"
type "password"
```

## Step-level properties

Every action accepts these in addition to its own:

- `disabled=#true` — skip at runtime. The step stays in the file and
  keeps its position. Engine emits a "skipped" outcome.
- `comment="..."` — a handwritten-style note. Shown in the editor's
  margin and under the step in `wflow show`.

```kdl
shell "rm -rf /tmp/scratch" disabled=#true comment="only enable if you really mean it"
```

## How wflow actually runs each action

wflow calls three external binaries plus the user's shell:

| Binary | Used by | Fallback if missing |
|---|---|---|
| `wdotool` | `type` / `key` / `click` / `move` / `scroll` / `focus` / `await-window` | step fails |
| `notify-send` | `notify` | step fails |
| `wl-copy` | `clip` | step fails |
| `$SHELL` (or `/bin/sh`) | `shell` | `/bin/sh` |

Use `wflow doctor` to check which of these are on PATH on the current
machine.

wflow does not link wdotool in-process — it spawns it as a subprocess
per step. This keeps wflow compatible with any wdotool install
(AUR, cargo, nix). If you want a different input backend later,
replacing the spawn path is the extension point.

## Error handling

Steps run sequentially. On a step error, the workflow halts and `wflow
run` exits with code 2. A `disabled` step or a `note` is reported as
`skipped` and does not halt.

Run-level error handling (retry, continue-on-error, branching) is not
yet expressible in the format — it lives in the roadmap.

## Schema version

`schema 1` is the only supported version today. If a future release
changes the document shape in a way that breaks existing files, the
schema number bumps and the decoder learns to read both.

## Round-trip stability

wflow re-serializes workflows whenever they're saved through the GUI
or `wflow new`. The on-disk format is canonical (sorted props,
consistent spacing), so version-controlling your workflow files and
diffing them works well.

Hand-written files that use the equivalent-but-different syntaxes
(`wait 500` vs `wait "500ms"` vs `wait ms=500`) are decoded the same
way and will round-trip through the canonical form the next time
they're saved.
