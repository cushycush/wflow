# The wflow KDL format

A wflow workflow is a [KDL](https://kdl.dev) document. KDL is whitespace-
sensitive, bracket-free for the most part, and reads like a configuration
file. One workflow per file. The whole file is one `workflow "Title" { ... }`
block; everything else (steps, `vars`, `imports`, `subtitle`) goes inside it.

## Starting from a scaffold

`wflow new <title>` writes a fresh KDL file and prints its path. The
scaffold's steps are all `disabled=#true` so running it straight away
is a safe no-op:

```kdl
// A wflow workflow. See `docs/KDL.md` for the full action vocabulary.
workflow "My workflow" {
    // Starter steps. `disabled=#true` keeps them inert so a fresh
    // `wflow run` is a no-op. Flip the flag off (or delete the line)
    // when you want a step to actually fire.
    notify "hello from wflow" disabled=#true
    shell "echo 'wflow ran at ' \"$(date)\"" disabled=#true
    wait-window "Firefox" timeout="5s" disabled=#true
    key "ctrl+l" disabled=#true
}
```

Flip `disabled=#true` off on the steps you want, or delete the whole
block and write your own. `wflow new "<title>" --stdout` prints the
template without persisting, so you can pipe it somewhere else if you
want to name the file yourself.

## Quick example

```kdl
workflow "Morning standup" {
    subtitle "open slack, zoom, and the notes doc"

    shell "hyprctl dispatch exec 'slack'"
    wait-window "Slack" timeout="10s"

    shell "hyprctl dispatch exec 'zoom'"
    wait-window "Zoom" timeout="15s"

    shell "hyprctl dispatch exec 'obsidian ~/notes/standup.md'"
    wait-window "Obsidian" timeout="10s"

    notify "ready" body="all three apps are up"
}
```

Run with `wflow run morning-standup` (the file's basename is the id) or
`wflow run ./path/to/file.kdl` if it's not in your library.

## Document structure

Every workflow file has the same shape:

```kdl
workflow "Human title" {        // required; positional arg is the title
    subtitle "one line"         // optional; shown in list and editor
    vars { ... }                // optional; workflow-level variables
    imports { ... }             // optional; named fragment files
    trigger { ... }             // optional; binds a hotkey or hotstring (v0.4+)
    // steps here, one per line, top-to-bottom execution
}
```

### trigger

A `trigger { }` block binds the workflow to an external event. The
runner ignores triggers; the wflow daemon (v0.4+) is what actually
subscribes to them and dispatches the workflow on activation. A
workflow can have multiple `trigger { }` blocks if you want more
than one binding.

```kdl
workflow "dev setup" {
    trigger { chord "super+alt+d" }   // global hotkey, AHK-style
    shell "kitty -e nvim"
}

workflow "btw expand" {
    trigger { hotstring "btw" }       // text expansion (v0.5+)
    type "by the way"
}

workflow "firefox copy url" {
    trigger {
        chord "ctrl+shift+u"
        when window-class="firefox"   // only fires when Firefox is focused
    }
    key "ctrl+l"
    key "ctrl+c"
    key "Escape"
}
```

Each trigger needs exactly one of `chord` (a wdotool-style key chord)
or `hotstring` (a plain text expansion trigger). The optional
`when window-class="..."` or `when window-title="..."` gates
activation on the focused window.

`trigger` blocks parse and round-trip through KDL today; the runner
ignores them in v0.3.x and the daemon picks them up in v0.4. Files
authored against v0.3.x with triggers are forward-compatible.

The id is the filename without `.kdl`. `wflow new` generates a UUID
filename; you can rename the file to anything path-safe and the new
basename becomes the id.

`created`, `modified`, and `last-run` timestamps live in
`~/.config/wflow/workflows.toml` (a sidecar TOML), not in the workflow
file itself, so editing the file in git doesn't churn on every run.

### Migrating from older files

Files written before v0.4 used a different shape:

```kdl
schema 1
id "morning-standup"
title "Morning standup"

recipe {
    ...
}
```

The decoder still reads those, so legacy files keep working. Run
`wflow migrate` to convert them in place. Lazy migration also kicks
in on the next save (via the GUI editor, `wflow run` writing
`last-run`, or any other path that calls `store::save`).

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

Every line inside the `workflow { ... }` block (other than `subtitle`,
`vars`, and `imports`) is one step. The first word picks the action;
positional arguments come next; properties (`key=value`) come last in
any order.

| Kind | Syntax | Runs |
|---|---|---|
| [`type`](#type) | `type "text" delay-ms=30` | `wdotool type --delay 30 -- "text"` |
| [`key`](#key) | `key "ctrl+l" clear-modifiers=#true` | `wdotool key [--clearmodifiers] ctrl+l` |
| [`key-down`](#key-down--key-up) | `key-down "ctrl"` | `wdotool keydown ctrl` |
| [`key-up`](#key-down--key-up) | `key-up "ctrl"` | `wdotool keyup ctrl` |
| [`click`](#click) | `click 1` | `wdotool click 1` |
| [`mouse-down`](#mouse-down--mouse-up) | `mouse-down 1` | `wdotool mousedown 1` |
| [`mouse-up`](#mouse-down--mouse-up) | `mouse-up 1` | `wdotool mouseup 1` |
| [`move`](#move) | `move 120 80 relative=#true` | `wdotool mousemove [--relative] 120 80` |
| [`scroll`](#scroll) | `scroll 0 3` | `wdotool scroll 0 3` |
| [`focus`](#focus) | `focus "Firefox"` | `wdotool search --limit 1 --name Firefox` + `windowactivate <id>` |
| [`wait-window`](#wait-window) | `wait-window "Firefox" timeout="5s"` | poll `wdotool search` until match or timeout |
| [`wait`](#wait) | `wait "1.5s"` | `tokio::time::sleep` (no subprocess) |
| [`shell`](#shell) | `shell "notify-send done"` | `$SHELL -c "notify-send done"` |
| [`notify`](#notify) | `notify "title" body="body"` | `notify-send "title" "body"` |
| [`clipboard`](#clipboard) | `clipboard "text to copy"` | `wl-copy` (pipes stdin) |
| [`note`](#note) | `note "reminder to self"` | nothing — a comment; always skipped |
| [`repeat`](#repeat) | `repeat 3 { key "Tab" }` | flattened into 3× `key "Tab"` at run time |
| [`when`](#when--unless) | `when window="Firefox" { ... }` | runs the block only if the condition holds |
| [`unless`](#when--unless) | `unless file="/tmp/lock" { ... }` | runs the block only if the condition fails |
| [`use`](#imports--use) | `use dev-setup` | splices a fragment named in the top-level `imports { ... }` block |

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
- **Modifiers are lower-case.** `super`, `ctrl`, `shift`, `alt`.
- **Special keys are Title-cased X11 keysyms.** `Return`, `Escape`,
  `BackSpace`, `Tab`, `space`, `Home`, `End`, `Page_Up`, `Page_Down`,
  `Left`, `Right`, `Up`, `Down`, `F1`–`F12`, `Caps_Lock`, `Insert`,
  `Delete`.
- **Plus joins the chord.** `key "ctrl+shift+t"`.

**You can hand-author friendly names.** wflow normalizes common
aliases at decode time, so the file you write and the file you round-
trip both show the canonical name:

| You write | wflow stores |
|---|---|
| `Enter` | `Return` |
| `Esc` | `Escape` |
| `Del` / `Delete` | `Delete` |
| `PgUp` / `PageUp` | `Page_Up` |
| `PgDn` / `PageDown` | `Page_Down` |
| `Caps` / `CapsLock` | `Caps_Lock` |
| `Backspace` | `BackSpace` |
| `cmd` / `command` / `win` / `meta` | `super` |
| `option` / `opt` | `alt` |
| `Ctrl` / `CONTROL` | `ctrl` |

So `key "Cmd+Shift+Enter"` in your source ends up saved and run as
`key "super+shift+Return"` — no surprises at wdotool dispatch time.

Everything not in the alias table passes through unchanged, so the
X11 keysym name is always the safe choice.

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

### key-down / key-up

Press a key or chord without releasing it, and release it separately.
Pair the two around other steps to hold a modifier while something
else happens, or to build a long-press.

```kdl
// Chord assembly: hold Ctrl while clicking at two points.
key-down "ctrl"
move 100 100
click 1
move 400 100
click 1
key-up "ctrl"

// Long-press shift for half a second.
key-down "shift"
wait 500
key-up "shift"
```

If the workflow errors or is killed mid-run, the OS will naturally
release held keys as the wdotool subprocess exits; still, pair every
`key-down` with a matching `key-up` for clean shutdown.

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

### mouse-down / mouse-up

Press / release a mouse button without an implicit click. The drag
primitive — combine with `move` steps to reshape a selection, drag
a window, or draw.

```kdl
move 200 200
mouse-down 1
move 600 400 relative=#false
mouse-up 1
```

Buttons follow the same numbering as `click`. A stuck button from a
half-failed workflow is a common bug; default to a paired form unless
you're sure you want to leave one pressed across a long sequence.

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

**Timeout.** Cap a shell step's wall-clock time. On elapse, wflow
sends SIGKILL to the child and the step errors. Pair with
`on-error="continue"` if you want the workflow to keep going after a
hung command:

```kdl
shell "ping -c 3 api.example.com" timeout="10s"
shell "some-flaky-probe"           timeout="2s" on-error="continue"
```

Both `timeout-ms=30000` and `timeout="30s"` are accepted. Specifying
both at once is a hard error.

**Retries.** Re-run a failed command up to `retries` extra times,
sleeping `backoff` between attempts. `retries=3` means up to 4 total
attempts (one initial + three retries). `backoff` defaults to 500ms
when retries is set and backoff is omitted.

```kdl
shell "curl -fsS https://api.example.com/status" \
    retries=3 backoff="500ms" timeout="5s"
```

On final failure, the step's `on-error` policy applies — a retry
step that exhausts all attempts under `on-error="stop"` halts the
workflow; under `continue`, the workflow moves on to the next step.
The final error message reads "gave up after N attempts: ...".

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
UI and in `wflow show`. Useful for annotating stretches of a workflow.

```kdl
note "the next two steps unlock the keychain"
key "super+space"
type "password"
```

### when / unless

Gate a block of steps on live system state. Exactly one of
`window=` / `file=` / `env=` is required. `unless` is literally
`when` with the condition negated.

```kdl
// Only touch the URL bar if Firefox is actually up.
when window="Firefox" {
    focus "Firefox"
    key "ctrl+l"
    type "hyprland wiki"
    key "Return"
}

// Skip the long-running backup if a lock file is already there.
unless file="/tmp/wflow-backup.lock" {
    shell "touch /tmp/wflow-backup.lock"
    shell "rsync -a ~/projects /mnt/backup/"
    shell "rm /tmp/wflow-backup.lock"
}

// Turn on verbose logging only when DEBUG=1 in the caller's env.
when env="DEBUG" equals="1" {
    notify "debug mode" body="workflow is running with DEBUG=1"
}
```

Condition types:

- **`window="name"`** — a window whose title contains `name` is
  currently present. Evaluated via the same `wdotool search` path
  used by `wait-window`.
- **`file="path"`** — filesystem path exists (file, dir, or symlink
  to either). Leading `~/` is expanded against $HOME. Does not
  interpolate — use `{{var}}` substitution if you need dynamic paths.
- **`env="NAME"`** — environment variable is set and non-empty.
  Add `equals="value"` to also require an exact match.

The condition is evaluated **each time** the block is reached, not at
workflow start. A `when file="/tmp/marker"` guarding the second half
of a workflow will pick up a marker file created by the first half.

#### Else branch

`when` and `unless` accept an optional `else { ... }` block. Steps
inside `else` run when the predicate flips the other way: the false
side of `when`, the true side of `unless`. Without `else`, a failing
predicate skips silently.

```kdl
// Run the IDE setup if Slack's already up; otherwise launch Slack first.
when window="Slack" {
    focus "Slack"
    key "ctrl+k"
    type "{{channel}}"
    else {
        shell "slack"
        wait-window "Slack" timeout="20s"
        focus "Slack"
        key "ctrl+k"
        type "{{channel}}"
    }
}
```

The `else` block must come last inside the parent `when` / `unless`;
steps after it are rejected at parse time. Only one `else` per
conditional. Inside `else { ... }` you can use anything you'd use at
the top of a workflow — including nested `when` / `unless` /
`repeat` if you need a richer dispatch tree.

### imports + use

To share the same opening-the-IDE / entering-the-password / whatever
preamble across multiple workflows, factor it into a **fragment file**
— a separate `.kdl` file whose contents are a bare list of step nodes
(no `workflow` wrapper, no `schema` line). Declare the fragment in the
workflow's top-level `imports { ... }` block and reference it by name
with `use NAME`:

```kdl
// ~/.config/wflow/lib/open-dev.kdl (fragment file)
shell "hyprctl dispatch exec 'kitty'"
wait-window "kitty" timeout="5s"
key "ctrl+shift+t"
```

```kdl
workflow "Morning routine" {
    imports {
        dev-setup "~/.config/wflow/lib/open-dev.kdl"
        standup   "~/.config/wflow/lib/standup.kdl"
        cleanup   "~/.config/wflow/lib/close-day.kdl"
    }

    use dev-setup
    shell "cd ~/projects && ls"
    use standup
    // … some work later …
    use cleanup
}
```

**`imports { name "path" ... }`** maps short names to fragment file
paths. Duplicate names error at decode. The block is evaluated once
and erased — re-encoding the workflow produces the inlined form.

**`use name`** (unquoted) is a step verb. At decode time it looks up
`name` in the imports table and splices the target fragment in place.
Path resolution:

- **Absolute** paths are used as-is.
- **Relative** paths resolve against the directory containing the
  workflow file (not the current working directory).
- **`~/`** expands against `$HOME`.

Imports can nest (a fragment file can `use` other names from the
parent's imports map) and `use` works inside `repeat` / `when` /
`unless` blocks. Cycles (`a → b → a`) are detected and rejected with
an "import cycle detected" error.

Unknown names get a helpful error:

```
error: unknown import `dev-setpu`. known: dev-setup, standup. did you mean `dev-setup`?
```

Either form — `use dev-setup` (bareword) or `use "dev-setup"` (quoted)
— works; the bareword is the canonical form.

`use` is expanded at **decode time**, not dispatch time — by the time
the engine sees the workflow, the imported steps have been spliced in
place. As a consequence: encoding a workflow that was loaded with
imports produces the inlined form. If you re-save such a workflow
(via `wflow edit` + save, or the GUI), the `use` lines become concrete
steps. Don't hand-round-trip files with imports through the encoder if
you want to keep the source shape.

### repeat

Run a nested sequence of steps `N` times. Flattened into the
iteration-step stream at run time, so the engine reports each
iteration's steps individually (`01 key Tab`, `02 key Tab`, …).

```kdl
focus "vim"
repeat 5 {
    key "Tab"
    wait 50
}
```

Nesting works:

```kdl
repeat 3 {
    repeat 2 {
        key "Down"
    }
    key "Return"
}
```

Variables captured from `shell ... as="name"` inside a repeat iteration
are visible to later iterations — so you can, for example, number
iterations yourself by capturing a counter through an external
command.

`count` must be a non-negative integer. `repeat 0 { ... }` is a valid
no-op. `disabled=#true` on the repeat node skips the whole block.

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
workflow "Create today's note" {
    vars {
        notes-dir "~/notes/daily"
        template "daily.md.tmpl"
    }

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
workflow "Scratch from clipboard" {
    subtitle "open today's note in nvim, drop a timestamped clip block at the end"

    vars {
        notes-dir "/home/cush/notes"
    }

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
| `workflow { ... }` (no title) | ``\`workflow "..."\` needs a title in quotes`` |
| `workflow "X" { id "y" }` | ``\`id\` doesn't belong inside a \`workflow\` block — the filename is the id in the new format`` |
| Two `workflow` blocks in one file | ``file has 2 \`workflow\` blocks. Multiple workflows per file is reserved for a future release; for now, one workflow per file`` |
| Mixed legacy + new shapes | ``file mixes the legacy top-level layout … with a \`workflow {}\` block. Pick one format. Run \`wflow migrate\` to convert legacy files in place.`` |
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

## Format version

The current format is the `workflow "Title" { ... }` shape. Files
written before v0.4 used a flat layout with `schema 1`, top-level
`id`/`title`/`subtitle` fields, and a `recipe { ... }` block; the
decoder still reads those, and `wflow migrate` converts a whole
library in place.

If a future release breaks the document shape in a way the decoder
can't bridge, a new top-level marker (or a multi-workflow file rule
when that lands) signals the change.

## Round-trip stability

wflow re-serializes workflows whenever they're saved through the GUI
or `wflow new`. The on-disk format is canonical (sorted props,
consistent spacing), so version-controlling your workflow files and
diffing them works well.

Hand-written files that use the equivalent-but-different syntaxes
(`wait 500` vs `wait "500ms"` vs `wait ms=500`) are decoded the same
way and will round-trip through the canonical form the next time
they're saved.
