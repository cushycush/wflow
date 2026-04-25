# wflow

A workflow engine for Wayland automation.

wflow executes KDL workflow files — declarative sequences of keystrokes,
clicks, shell commands, delays, notifications, and window-focus events —
on top of [wdotool](https://github.com/cushycush/wdotool). Think `make`
for your desktop.

There's also a Qt Quick GUI (Library / Editor / Record), but the CLI is
the first-class surface and ships first.

## Install

### Arch Linux

PKGBUILDs in [`packaging/aur/`](packaging/aur/). Local install:

```sh
cd packaging/aur/wflow-git && makepkg -si
```

(Or pull `wflow` / `wflow-git` from the AUR once published.)

### From source

Requires Rust ≥ 1.77 and Qt 6 development headers (`qt6-base`,
`qt6-declarative` on Arch; `qt6-base-dev`, `qt6-declarative-dev` on
Debian/Ubuntu).

```sh
cargo install --path . --locked
```

This drops `wflow` in `~/.cargo/bin/`. Make sure that's on your `PATH`.

You'll also want [wdotool](https://github.com/cushycush/wdotool) on
`PATH` for any workflow that types, clicks, or focuses windows. Run
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
    wait-window "kitty" timeout="5s"
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

- **v0.1.0** — CLI runner, KDL format, GUI as a viewer / single-workflow
  launcher, simulated Record Mode placeholder.
- **v0.2.0 (shipping)** — full KDL language (vars / flow control /
  includes / imports / retries / timeouts); GUI editor with value, title,
  and option editing plus add / delete / reorder / library delete +
  duplicate; Record Mode backed by a real ashpd portal + libei receiver
  (with a simulated fallback when the portal is unavailable); man pages,
  AUR PKGBUILDs, dual MIT/Apache-2.0 license.
- **next** — Record-mode event coalescing (collapse Move floods, merge
  text events into Type, build chords from modifier+key); flow-control
  editing in the GUI (currently `wflow edit` only).

See `CLAUDE.md` for architecture notes and design decisions.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
  <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT License ([LICENSE-MIT](LICENSE-MIT) or
  <https://opensource.org/licenses/MIT>)

at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this project, as defined in the Apache 2.0
license, shall be dual-licensed as above, without any additional terms
or conditions.
