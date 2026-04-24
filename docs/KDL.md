# The wflow KDL format

A wflow workflow is a [KDL](https://kdl.dev) document. KDL is whitespace-
sensitive, bracket-free for the most part, and reads like a configuration
file. One workflow per file. One `recipe { ... }` block holds the steps.

## Starting from a scaffold

`wflow new <title>` writes a fresh KDL file and prints its path. The
scaffold's steps are all `disabled=#true` so running it straight away
is a safe no-op:

```kdl
// A wflow workflow. See `docs/KDL.md` for the full action vocabulary.
schema 1
id "a1b2c3d4-..."
title "My workflow"
created "..."
modified "..."

recipe {
    // Starter steps — marked `disabled=#true` so `wflow run` is a no-op
    // until you turn them on. Delete these lines and write your own.
    notify "hello from wflow" disabled=#true
    shell "echo 'wflow ran at ' \"$(date)\"" disabled=#true
    wait-window "Firefox" timeout="5s" disabled=#true
    key "ctrl+l" disabled=#true
}
```

Flip `disabled=#true` off on the steps you want, or delete the whole
block and write your own. `wflow new "<title>" --stdout` prints the
template without persisting — pipe it somewhere else if you'd rather
name the file yourself.

## Quick example

```kdl
schema 1
id "morning-standup"
title "Morning standup"
subtitle "open slack, zoom, and the notes doc"

recipe {
    shell "hyprctl dispatch exec 'slack'"
    wait-window "Slack" timeout="10s"

    shell "hyprctl dispatch exec 'zoom'"
    wait-window "Zoom" timeout="15s"

    shell "hyprctl dispatch exec 'obsidian ~/notes/standup.md'"
    wait-window "Obsidian" timeout="10s"

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

### A note on booleans: `#true` and `#false`

Properties that take a boolean use the KDL v2 syntax `#true` / `#false`,
not bare `true` / `false`. Bare `true` decodes as a *string*, which
either errors out (type mismatch) or — worse — silently becomes a
falsy value for a bool. If something isn't taking effect and the prop
is a bool, double-check you used the `#` prefix.

```kdl
key "Return" clear-modifiers=#true    // right
key "Return" clear-modifiers=true     // wrong — decodes as the string "true"
```

## Actions

Every line inside `recipe { ... }` is one step. The first word picks the
action; positional arguments come next; properties (`key=value`) come
last in any order.

| Kind | Syntax | Runs |
|---|---|---|
| [`type`](#type) | `type "text" delay-ms=30` | `wdotool type --delay 30 -- "text"` |
| [`key`](#key) | `key "ctrl+l" clear-modifiers=#true` | `wdotool key [--clearmodifiers] ctrl+l` |
| [`click`](#click) | `click 1` | `wdotool click 1` |
| [`move`](#move) | `move 120 80 relative=#true` | `wdotool mousemove [--relative] 120 80` |
| [`scroll`](#scroll) | `scroll 0 3` | `wdotool scroll 0 3` |
| [`focus`](#focus) | `focus "Firefox"` | `wdotool search --limit 1 --name Firefox` + `windowactivate <id>` |
| [`wait-window`](#wait-window) | `wait-window "Firefox" timeout="5s"` | poll `wdotool search` until match or timeout |
| [`wait`](#wait) | `wait "1.5s"` | `tokio::time::sleep` (no subprocess) |
| [`shell`](#shell) | `shell "notify-send done"` | `$SHELL -c "notify-send done"` |
| [`notify`](#notify) | `notify "title" body="body"` | `notify-send "title" "body"` |
| [`clipboard`](#clipboard) | `clipboard "text to copy"` | `wl-copy` (pipes stdin) |
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

Sends a key or chord via wdotool. Common convention:

- **Letters are lower-case.** `key "a"` types `a`. For uppercase you
  need the `shift` modifier: `key "shift+a"` types `A`.
- **Modifiers are lower-case.** `super`, `ctrl`, `shift`, `alt`, `meta`.
- **Special keys are Title-cased X11 keysyms.** `Return` (not `Enter`),
  `Escape` (not `Esc`), `BackSpace`, `Tab`, `space`, `Home`, `End`,
  `Page_Up`, `Page_Down`, `Left`, `Right`, `Up`, `Down`, `F1`–`F12`,
  `Caps_Lock`, `Insert`, `Delete`.
- **Plus joins the chord.** `key "ctrl+shift+t"`, not `key "ctrl-shift-t"`.

If you're unsure what wdotool will accept, try the command directly:

```sh
wdotool key Return        # works
wdotool key Enter         # "no such key" — you want Return
```

Examples:

```kdl
key "Return"
key "ctrl+l"
key "ctrl+shift+t"
key "super+1" clear-modifiers=#true
key "shift+g"             // vim's end-of-file
```

`clear-modifiers=#true` releases any held modifier keys before sending
the chord. Useful when you don't trust the prior state (e.g. right
after a `shell` that might have been fired by a Super-keybinding).

### click

Mouse button press-release at the current cursor position. Buttons
follow X11 convention: `1`=left, `2`=middle, `3`=right, `8`=back,
`9`=forward. Defaults to left-click if omitted.

```kdl
click 1
click 3
```

The older prop form `click button=1` still decodes for backwards
compatibility.

### move

Move the cursor. Two positional ints = x, y. `relative=#false`
(default) treats them as absolute screen coordinates. `relative=#true`
makes them a delta from the current position.

```kdl
move 640 480
move 100 0 relative=#true
```

Older prop form `move x=640 y=480` still decodes. You can't mix
forms — `move 640 480 x=100` is an error.

### scroll

Scroll by wheel clicks. Two positional ints = dx, dy. `dy` positive
= down, `dx` positive = right.

```kdl
scroll 0 3
scroll 0 -5
```

Older prop form `scroll dx=0 dy=3` still decodes.

### focus

Activate the first window whose title contains the positional argument.
Errors immediately if no matching window exists — pair with
`wait-window` if the window might not be up yet.

```kdl
focus "Firefox"
```

Older prop form `focus window="Firefox"` still decodes.

### wait-window

Block until a window matching the positional argument exists, or the
timeout elapses. This is the primitive that turns a racy workflow
into a reliable one.

Timeout can be either `timeout-ms=5000` or `timeout="5s"`. Defaults
to 5 seconds if omitted. Specifying both forms is a hard error.

```kdl
shell "firefox"
wait-window "Firefox" timeout="10s"
focus "Firefox"
key "ctrl+l"
type "hyprland wiki"
key "Return"
```

If the window never appears, the step errors and the workflow halts.

Older verb `await-window` still decodes; the encoder emits
`wait-window` so it pairs lexically with `wait`.

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

Override the interpreter with `with="/bin/bash"` if `$SHELL` isn't
what you want:

```kdl
shell "echo $0" with="/bin/bash"
```

Older prop name `shell="/bin/bash"` still decodes for backwards
compatibility, but `with=` avoids the awkward `shell shell=` reading.

### notify

Convenience wrapper over `notify-send`. Equivalent to
`shell "notify-send 'title' 'body'"` but declarative.

```kdl
notify "done"
notify "build failed" body="see ~/tmp/build.log"
```

### clipboard

Copy text to the Wayland clipboard via `wl-copy`.

```kdl
clipboard "git@github.com:cushycush/wflow.git"
```

Older verb `clip` still decodes.

### note

A step that does nothing at runtime — a comment that shows up in the
UI and in `wflow show`. Useful for annotating stretches of a recipe.

```kdl
note "the next two steps unlock the keychain"
key "super+space"
type "password"
```

## Variables and substitution

Any string argument in a step can contain `{{name}}` tokens, expanded
at run time. Three sources:

1. **Workflow-level `vars { ... }` block.** Hand-authored bindings at
   the top of the file.
2. **Captured shell output.** `shell "cmd" as="name"` stores the
   command's stdout (stripped of trailing whitespace) under `name`.
   Later steps can reference it.
3. **Process environment.** `{{env.NAME}}` reads `$NAME` from the
   process environment.

```kdl
schema 1
id "daily-note"
title "Create today's note"

vars {
    notes-dir "~/notes/daily"
    template "daily.md.tmpl"
}

recipe {
    shell "date +%F"                        as="today"
    shell "cp {{notes-dir}}/{{template}} {{notes-dir}}/{{today}}.md"
    shell "hyprctl dispatch exec 'nvim {{notes-dir}}/{{today}}.md'"
    wait-window "nvim"
    notify "note ready" body="{{today}}.md opened in nvim by {{env.USER}}"
}
```

Rules:

- Unknown `{{name}}` → the step errors with a list of known names. No
  silent empties.
- Capture-and-use sequencing matters: a step can only reference vars
  that were bound by an earlier step or the file's `vars` block.
- `vars` values are strings only. Integer / boolean fields (`click 2`,
  `move 10 20`, `relative=#true`) don't take templates today.
- Shell stdout capture trims trailing whitespace, so `shell "date +%F"
  as="today"` gives `2026-04-24` without a trailing newline.
- To keep a literal `{{...}}` in a string without substitution, escape
  with a backslash: `\{{not a var}}`.
- `env.*` is a reserved namespace — `vars { env.HOME "..." }` errors.

## Step-level properties

Every action accepts these in addition to its own:

- `disabled=#true` — skip at runtime. The step stays in the file and
  keeps its position. Engine emits a "skipped" outcome.
- `comment="..."` — a handwritten-style note. Shown in the editor's
  margin and under the step in `wflow show`.

```kdl
shell "rm -rf /tmp/scratch" disabled=#true comment="only enable if you really mean it"
```

## A realistic example

Putting variables, window-waits, shell capture, and categorized steps
together — a workflow that opens today's daily note, with a scratchpad
ready for the clipboard contents:

```kdl
schema 1
id "scratch-from-clip"
title "Scratch from clipboard"
subtitle "open today's note in nvim, drop a timestamped clip block at the end"

vars {
    notes-dir "/home/cush/notes"
}

recipe {
    // Grab the clipboard into a variable so we can reference it by
    // name in later steps rather than relying on paste state.
    shell "wl-paste --no-newline" as="clip"
    shell "date +%F"              as="today"
    shell "date +%H:%M"           as="now"

    // Guarantee the notes file exists before the editor opens it.
    shell "mkdir -p {{notes-dir}}"
    shell "touch {{notes-dir}}/{{today}}.md"

    // Append a timestamped block with the clipboard contents.
    shell "printf '\\n## %s\\n\\n%s\\n' '{{now}}' '{{clip}}' >> {{notes-dir}}/{{today}}.md"

    // Launch the editor and make sure it's the focused window before
    // we touch the keyboard.
    shell "hyprctl dispatch exec 'kitty nvim {{notes-dir}}/{{today}}.md'"
    wait-window "kitty" timeout="8s"

    // Jump to end-of-file so the cursor lands at the clip we just
    // appended. Vim's `G` is shift+g.
    key "Escape"
    key "shift+g"

    notify "note ready" body="{{today}}.md updated with {{now}} clip"
}
```

Run with `wflow run scratch-from-clip`. Copy something, run it again,
see a timestamped block appended to today's daily note.

## When things go wrong

Sample error messages you'll see from `wflow run` / `wflow validate`:

| What you wrote | What you get |
|---|---|
| `wiat 500` | ``unknown step kind `wiat` `` |
| `key chord="Return"` | ``unknown property `chord` on `key`. valid: clear-modifiers, disabled, comment`` (key takes the chord positionally: `key "Return"`) |
| `click buton=1` | ``unknown property `buton` on `click`. valid: button, disabled, comment. did you mean `button`?`` |
| `wait "forever"` | ``unknown duration unit `forever` in `forever` (use ms, s, m, or h)`` |
| `shell "cmd" retries=3` | ``unknown property `retries` on `shell`. valid: shell, with, as, disabled, comment`` |
| `schema 2` | `schema 2 is not supported (this wflow reads schema 1). upgrade wflow or convert the file` |
| missing `title` | ``missing required `title "..."` at the top of the file`` |
| `recipie { ... }` | ``unknown top-level node `recipie`. valid: schema, id, title, subtitle, created, modified, last-run, vars, recipe. did you mean `recipe`?`` |
| `{{nope}}` in a string | `unknown variable `{{nope}}`. known: name, fruit` |
| `move 640 480 x=0 y=0` | ``move: specify coordinates as `move 640 480` OR `move x=640 y=480`, not both`` |
| `await-window "X" timeout-ms=5000 timeout="10s"` | ``wait-window: specify the timeout once ... — not both`` |
| wdotool not installed | `missing required tools: wdotool — run \`wflow doctor\` for details` |

All parse errors surface with exit code 1. Runtime step failures surface
with exit code 2 and halt the workflow. `wflow validate <file>` parses
without running — use it in CI to check a file before you commit it.

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
