# Submission: io.github.cushycush.wflow

wflow is a Shortcuts-style GUI and CLI for Wayland desktop
automation. Workflows are KDL files: sequences of keystrokes,
clicks, shell commands, delays, and notifications. The user records
or hand-authors them, the GUI shows them as cards, hitting Run
plays the sequence. macOS has Shortcuts; Windows has AutoHotkey;
this is the Linux version of that experience.

Source: https://github.com/cushycush/wflow. License: MIT OR
Apache-2.0. Already shipping on AUR as `wflow` and `wflow-git`.

## The permission question

This manifest grants `--talk-name=org.freedesktop.Flatpak`, which I
expect will be the central question of this review. The honest
answer: yes, wflow needs it, and the surface has been narrowed as
far as it can go while still being a workflow runner.

What still uses host-spawn:

- The user's `shell "..."` action. Users write things like
  `hyprctl dispatch exec firefox` or `kitty -e nvim` and expect
  those commands to run on their host session. There is no portal
  that does "run an arbitrary user-supplied command on the host,"
  and adding one would defeat the sandboxing model.
- The `clipboard` action (`wl-copy`). Could move to
  `org.freedesktop.portal.Clipboard` in a later release, but that
  portal needs an active RemoteDesktop session which we don't
  always have, so today it stays on host-spawn.

What used to host-spawn and no longer does:

- Input and window actions (key, type, click, focus, wait-window).
  These go through `wdotool-core` linked into the binary, which
  talks to `org.freedesktop.portal.RemoteDesktop` and the libei
  receiver directly.
- Notifications. These go through
  `org.freedesktop.portal.Notification`.

Precedents that ship with the same permission for the same reason
(tools that legitimately need to drive the user's host session):

- `com.visualstudio.code`
- `org.gnome.Builder`
- `org.gnome.Boxes`

## Threat model

Workflows are user-authored or user-recorded. wflow ships a
first-run trust prompt for any workflow file it didn't author here,
keyed by (path, sha256). The CLI prompts on TTY and refuses
non-TTY without `--yes`. The GUI shows a modal dialog with a
categorized step summary. Editing a trusted file invalidates the
trust (sha changes); moving it invalidates trust (path changes).
Full threat model and six concrete attack patterns are documented
in [REVIEW.md](https://github.com/cushycush/wflow/blob/main/REVIEW.md).

## Build

`flatpak-builder` runs offline against `cargo-sources.json` in this
PR (regenerated from `Cargo.lock` for each release). KDE Platform
6.9 base, rust-stable SDK extension 25.08 for Rust 1.95+ (some
transitive deps pull edition2024). Verified end-to-end on Arch +
Hyprland. Record Mode reports a clear error on compositors whose
portal doesn't expose RemoteDesktop, which is the expected
behavior on Hyprland and Sway today (Plasma 6 and GNOME 46+ ship
the interface and Record works there).

## Per-release upkeep

Each new wflow release is a tag in the upstream repo, a `<release>`
entry in `metainfo.xml`, and a regenerated `cargo-sources.json`.
Once this app's per-app repo exists I'll open release PRs there
following the standard pattern.
