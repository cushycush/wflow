# wflow

**Shortcuts for Linux — GUI + KDL workflow files.**

wflow records, edits, and replays sequences of keystrokes, clicks, shell
commands, delays, and notifications on Wayland. There's a Qt Quick GUI
for visual editing and a CLI for cron / keybind / scripting. Both run
the same engine.

Workflows are plain text in [KDL](https://kdl.dev) format — diffable in
git, hand-authorable in `$EDITOR`, includable into other workflows,
shareable as a single file. Think macOS Shortcuts, but the workflow file
*is* the artifact: no proprietary container, no binary blob.

Built on [wdotool](https://github.com/cushycush/wdotool) for input
injection.

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

## Examples

[`examples/`](examples/) has seven hand-authored workflows that cover every
feature of the language — `dev-setup`, `screenshot-and-share`, `daily-standup`,
`loop-tab-thru`, `if-vpn-then`, `flaky-deploy-trigger`, `record-replay-export`.
Read a file, copy it, edit the paths to match your system, then run.

```sh
wflow show examples/dev-setup.kdl       # read it
wflow run --explain examples/dev-setup.kdl  # see what it'd run, no execute
wflow run examples/dev-setup.kdl        # run it (you'll be prompted the first time)
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
- **v0.2.0** — full KDL language; GUI editor with value, title, and option
  editing plus add / delete / reorder / library delete + duplicate; real
  ashpd + libei Record backend (simulated fallback when the portal is
  unavailable); man pages, AUR PKGBUILDs, dual MIT/Apache-2.0 license.
- **v0.3.0 (shipping)** — first public release. Welcome card + New-workflow
  dialog with seven hand-authored example templates; first-run trust prompt
  for unfamiliar workflow files (CLI + GUI, see [`REVIEW.md`](REVIEW.md));
  Flatpak manifest with host-spawn redirect; GitHub Actions CI + draft-
  release-on-tag; AUR `wflow` + `wflow-git` packages live.
- **next** — Record-mode event coalescing (collapse Move floods, merge
  text events into Type, build chords from modifier+key); flow-control
  editing in the GUI (currently `wflow edit` only); cross-platform CI
  matrix (macOS, Windows, aarch64); Flathub submission once host-machine
  verification is green.

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
