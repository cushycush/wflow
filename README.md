# wflow

A workflow engine for Wayland automation.

wflow executes KDL workflow files — declarative sequences of keystrokes,
clicks, shell commands, delays, notifications, and window-focus events —
on top of [wdotool](https://github.com/cushycush/wdotool). Think `make`
for your desktop.

There's also a Qt Quick GUI (Library / Editor / Record), but the CLI is
the first-class surface and ships first.

## Install

```sh
cargo build --release
install -Dm755 target/release/wflow ~/.local/bin/wflow
```

You'll also want [wdotool](https://github.com/cushycush/wdotool) on `PATH`
for any workflow that types, clicks, or focuses windows. Run
`wflow doctor` to check.

## Quickstart

```sh
# Scaffold a new workflow in your library.
wflow new "Morning standup"
#=> /home/you/.config/wflow/workflows/<uuid>.kdl

# Edit the file — it starts with every step `disabled=#true` so it's
# a safe no-op. Remove that flag on the steps you want to run.
$EDITOR ~/.config/wflow/workflows/<uuid>.kdl

# See what it'll do.
wflow show <uuid>
wflow run <uuid> --dry-run

# Run it.
wflow run <uuid>
```

You can also run a KDL file directly without putting it in the library:

```sh
wflow run ./some-workflow.kdl
```

## Commands

| Command | What it does |
|---|---|
| `wflow` | Launch the GUI |
| `wflow run <id-or-path> [--dry-run]` | Execute a workflow |
| `wflow list [--json]` | List workflows in the library |
| `wflow show <id-or-path>` | Pretty-print the steps |
| `wflow validate <id-or-path>` | Parse + report without executing |
| `wflow new <title> [--stdout]` | Scaffold a new workflow |
| `wflow path` | Print the library directory |
| `wflow doctor` | Check required binaries are on PATH |

Exit codes: `0` success, `1` parse or load error, `2` a step failed at
runtime.

## The KDL format

The workflow format is KDL. A minimal file:

```kdl
schema 1
id "dev-setup"
title "Open dev setup"

recipe {
    shell "hyprctl dispatch exec 'kitty'"
    await-window "Alacritty" timeout="5s"
    key "ctrl+shift+t"
    type "cd ~/projects && ls"
    key "Return"
}
```

The full vocabulary — every action, every property, and how each one
translates to a wdotool / shell invocation — is in
[`docs/KDL.md`](docs/KDL.md).

## Where workflows live

```
$XDG_CONFIG_HOME/wflow/workflows/
```

Usually `~/.config/wflow/workflows/`. One `.kdl` file per workflow.
Filenames are derived from the workflow's `id`. Put the directory under
git if you want version-controlled automation.

## Status

- **v0.1 (shipping)** — CLI runner, KDL format, GUI as a viewer /
  single-workflow launcher. Record mode is a simulated placeholder.
- **v0.2** — Full GUI step editing.
- **v0.3** — Real input capture via libei receiver through the
  xdg-desktop-portal RemoteDesktop interface.

See `CLAUDE.md` for architecture notes and design decisions.
