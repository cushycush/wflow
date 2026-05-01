# wflow launch drafts (AHK + Shortcuts framing)

Drafted 2026-05-01. Hold for the v0.4 trigger-daemon ship + AHK-positioned
launch (gated on `docs/designs/v0.4-leg1-trigger-daemon.md` landing). Once
the daemon lands and `triggers.kdl` works end-to-end, edit these to
reflect what actually shipped, then post.

The "AHK + macOS Shortcuts for Linux" framing is the headline hook. AHK
brings the power-user / scripting / Windows-expat audience; Shortcuts
brings the friendly visual-editor audience. Both communities are large
and currently underserved on Linux.

## Posting plan

Stagger over 3-5 days. Reddit's spam filters and the karma-graph both
punish coordinated cross-posting. Customize each post per sub.

**Day 1:** r/linux + Hacker News + fosstodon. Email blog tips same day.
**Day 2:** r/wayland + r/Hyprland.
**Day 3:** r/rust + r/AutoHotkey.
**Day 4-5:** r/kde + r/gnome + r/shortcuts (light edits of Draft 1).

HN timing matters: Tue-Thu, 8-10am Pacific is empirically the Show HN
sweet spot. r/linux: pick "Development" or "Open Source" flair. Be at
the keyboard the first hour after posting; that's when the algorithm
decides if your post lives or dies.

Before pulling the trigger on r/AutoHotkey, search the sub for past
"Linux equivalent" posts. If those got warm receptions, ship it. If they
got dogpiled for missing the hotkey-daemon point, the "what's not there
yet" caveat in Draft 9 is the shield. Once the daemon lands the caveat
gets shorter, which is the whole reason we're holding these.

## Venue ranking

Best bets:
1. r/linux (biggest reach, allergic to marketing-speak)
2. Hacker News Show HN (Rust + Qt + Wayland angle)
3. r/AutoHotkey (huge audience; careful framing)
4. r/wayland (small but on-target)
5. r/Hyprland (power users, evdev fallback story)

Worth doing, lower stakes:
6. r/rust (cxx-qt + Qt Quick angle)
7. Lobsters (invite required)
8. r/kde + r/gnome (portal Record story)

Skip:
- r/programming (too broad to land)
- r/opensource (low engagement)
- r/selfhosted (wrong fit)
- r/unixporn (only if doing a tiled-WM showcase)

Blogs to email a tip to (one short pitch covers all): It's FOSS
(`hello@itsfoss.com`), 9to5Linux (`alex.linux@9to5linux.com`), LinuxIac,
OMG! Linux, This Week in Linux. Phoronix tips go through
`michael@phoronix.com`; Larabel covers what catches his eye, no
guarantees.

---

## Draft 1 - r/linux

**Title:** I built wflow: AutoHotkey + macOS Shortcuts for Linux, Wayland-native

If you've ever wanted AutoHotkey on Linux or missed Shortcuts after switching from a Mac, this is roughly the thing. wflow is a Qt Quick desktop app for building, recording, and replaying workflows on Wayland. Pick a template or start blank, drag step chips onto a free-positioning canvas, hit Run, watch each step report back inline (✓ ok, · skipped, ✗ error). Conditionals render as branch shapes with explicit yes/no outputs; loops are container cards. There's a step-by-step debugger that pauses between actions and pulses the active card so you can watch a repeat count up instead of guessing.

I built it because I'd been writing one-off shell scripts to chain "open this app, focus that window, type the thing, send a notification" for about a year, and every script was 20 lines of glue around different binaries with different conventions.

The choice I'd make again: workflows are plain KDL files on disk, one per file, in `~/.config/wflow/workflows/`. The GUI is a view onto a text file, the way an `.ahk` file is. `git diff` works. `$EDITOR` works. Sharing a workflow is sharing a single `.kdl`. The CLI runs the same files, so `wflow run morning-standup` from cron or a keybind hits the same engine the GUI does.

[ONCE DAEMON SHIPS, REPLACE THE PARAGRAPH BELOW WITH AN HONEST UPDATED VERSION]

Honest about scope: wflow isn't a 1:1 AHK replacement. There's no global hotkey daemon. You wire workflows to your compositor's keybinds (Hyprland `bind`, KDE Custom Shortcuts, GNOME Custom Shortcuts) and they trigger the same way `wflow run X` does from a terminal. For most AHK use cases I had, that's fine. Hotstrings and per-app conditional hotkeys aren't there yet.

[POST-DAEMON VERSION DRAFT]

Hotkey triggers ship in v0.4. `wflow daemon` registers chords through the GlobalShortcuts portal on Plasma 6 / GNOME 46+ and falls back to compositor IPC on Sway and Hyprland. Bindings live in a plain `triggers.kdl` you can hand-edit or manage from a Triggers tab in the GUI. Hotstrings and per-window conditional hotkeys aren't there yet, so it's not a 1:1 AHK replacement, but `chord -> workflow` is the headline experience and it works.

[END BRANCH]

Record mode uses `org.freedesktop.portal.RemoteDesktop` on Plasma 6 and GNOME 46+. On Hyprland and wlroots compositors that don't ship the portal yet, it falls back to reading `/dev/input/event*` via evdev (you'll need to be in the `input` group; wflow tells you so). Input replay goes through wdotool-core linked in-process, no separate binary, no root.

v0.4.x shipped today. Arch: `paru -S wflow-bin`. Tarball + Flatpak manifest in the release; Flathub submission is in flight.

Repo and screenshots: https://github.com/cushycush/wflow

Happy to take roasts of my KDL indentation in the comments.

---

## Draft 2 - Hacker News (Show HN)

**Title:** Show HN: Wflow – AutoHotkey + Shortcuts for Linux on Wayland

Hi HN. wflow is a Qt Quick desktop app for building and replaying automation workflows on Wayland. Mental model is "AutoHotkey + macOS Shortcuts": list of steps (key, type, click, focus, shell, notify, conditional, repeat, fragment-import), GUI editor on a free-positioning canvas for the Shortcuts side, plain KDL files on disk + a CLI runner + a hotkey daemon for the AHK side. The GUI and CLI are views onto the same file; both round-trip cleanly.

A few decisions I'd flag:

- The on-disk format is KDL, one file per workflow in `~/.config/wflow/workflows/`. No proprietary container, no SQLite. `git diff` is the change log. `$EDITOR` is a first-class authoring path; the GUI is the other.
- Input replay goes through `wdotool-core` (libei + Wayland virtual-input fallbacks) linked in-process, not a subprocess. No `wdotool` or `ydotool` binary, no root, no `uinput` group setup.
- Hotkey triggers go through `org.freedesktop.portal.GlobalShortcuts` (Plasma 6, GNOME 46+) with a wlroots-IPC fallback. Bindings live in a plain `triggers.kdl` hand-editable in the same spirit as the workflow files. The daemon hot-reloads on file change.
- Record mode prefers `org.freedesktop.portal.RemoteDesktop` (Plasma 6, GNOME 46+) and falls back to evdev on compositors that don't ship the portal yet.
- The engine is Rust, the GUI is Qt Quick / QML, glued with cxx-qt 0.8. Engine is async (tokio) because conditionals + repeat got cleaner once I stopped pretending it was a flat loop.

Scope vs AHK: the headline experience (chord fires a script) works. Hotstrings (text expansion) and per-window conditional hotkeys aren't there yet; AHK fans should know that going in. The thing wflow does that AHK doesn't is the Shortcuts-style visual canvas with a step debugger.

v0.4 ("the editor grows up + the daemon wakes up") just shipped. The editor became a node-graph workspace last week (multi-select, marquee, undo/redo, group annotation rectangles, fragment imports, smart auto-layout); the daemon ships now.

Repo: https://github.com/cushycush/wflow
Examples directory shows the full KDL vocabulary.

Roast it. Happy to answer questions about the cxx-qt build, the portal-vs-IPC split, or why KDL over YAML/TOML/JSON.

---

## Draft 3 - r/wayland

**Title:** wflow: GUI desktop automation on Wayland (portal triggers + Record, plain KDL files)

Input automation on Wayland is famously a pain in the ass. Every compositor has different gaps in the portal interfaces, ydotool wants root, libei is fresh, and you end up writing shell glue that's compositor-specific anyway. I wanted a GUI that hides that mess.

wflow is a Qt Quick app I've been building; v0.4 just shipped with the trigger daemon. Model is macOS Shortcuts: list of steps (key, type, click, focus, shell, notify, conditional, repeat), drag chips onto a canvas, hit Run, get per-step outcomes inline. Plus AHK-style hotkey triggers now: `triggers.kdl` maps a chord to a workflow id, the daemon registers it through the GlobalShortcuts portal.

The Wayland-relevant bits, since this is the place to talk about them:

Input replay goes through wdotool-core (libei first, virtual-keyboard / virtual-pointer protocol fallbacks) linked in-process. No `wdotool` or `ydotool` binary required, no root, no `uinput` group. Tested on KDE Plasma 6, GNOME 46, Hyprland, Sway, niri.

Hotkey triggers prefer `org.freedesktop.portal.GlobalShortcuts` (KDE 6, GNOME 46+, with the consent dialog). On wlroots compositors where the portal isn't shipped yet, it falls back to compositor IPC: `hyprctl keyword bind ...` on Hyprland, `swaymsg bindsym ...` on Sway, both pointing back at `wflow run <id> --yes`. Slower (subprocess per fire) but reachable.

Record mode uses `org.freedesktop.portal.RemoteDesktop` where it exists, falls back to reading `/dev/input/event*` via evdev where it doesn't. wflow checks both paths at startup and surfaces a setup error if neither is available, instead of "recording" zero events.

Window focus uses `wlr-foreign-toplevel` on wlroots, KWin's window-management protocol on Plasma, GNOME shell hooks on GNOME. Workflows declare what they want (`focus "Slack"`, `wait-window "Slack" timeout="20s"`); failing matches surface as `✗ error: no window matched "Slack"`, not a silent no-op.

Workflows are plain KDL files (one per file in `~/.config/wflow/workflows/`). GUI and CLI are views onto the same file. Shareable as a single text file, diffable in git.

Repo: https://github.com/cushycush/wflow

Curious what edge cases I'm missing on niri / Cosmic / less-common compositors. Drop them in the comments.

---

## Draft 4 - r/Hyprland (template, edit lightly for r/kde / r/gnome / r/swaywm)

**Title:** wflow on Hyprland: AutoHotkey-style hotkeys + Shortcuts-style GUI, evdev fallback for Record

Built a Qt Quick app for the "record this sequence, name it, replay it" workflow. AHK + macOS Shortcuts vibe: visual editor for the Shortcuts side, plain KDL files + CLI + a hotkey daemon for the AHK side. v0.4 shipped today.

Hyprland-specific notes since I run it on this setup:

Input replay goes through wdotool-core (linked in-process, no binary). Works through the virtual-keyboard / virtual-pointer protocols Hyprland already supports, no root, no `uinput`.

Hotkey triggers: Hyprland doesn't ship `org.freedesktop.portal.GlobalShortcuts` yet, so the daemon falls back to writing `bind` directives via `hyprctl keyword bind ...` that point back at `wflow run <id> --yes`. Slightly slower than a portal-bound shortcut (subprocess fork per fire) but transparent and reloadable. You edit `~/.config/wflow/triggers.kdl`; the daemon picks the change up via inotify.

Record mode: Hyprland doesn't ship `org.freedesktop.portal.RemoteDesktop` yet either, so wflow falls back to reading `/dev/input/event*` via evdev. You'll need to be in the `input` group (`sudo usermod -aG input $USER`, then log out and back in). If you're not, wflow tells you exactly that, doesn't silently capture nothing. When xdph lands the portal it'll switch automatically.

Window focus uses `wlr-foreign-toplevel`, so `focus "Firefox"` and `wait-window "Firefox" timeout="20s"` work.

Workflows are plain `.kdl` files in `~/.config/wflow/workflows/`. GUI and CLI run the same file. So you wire any workflow into a Hyprland keybind directly if you'd rather skip the daemon:

```
bind = SUPER, F1, exec, wflow run morning-standup
```

Install: `paru -S wflow-bin` for the prebuilt, or `wflow` / `wflow-git` from source.

Repo: https://github.com/cushycush/wflow

Tested on Hyprland 0.45. Let me know what breaks on yours.

---

## Draft 5 - r/rust

**Title:** wflow: a Wayland desktop automation GUI written in Rust + Qt Quick (cxx-qt)

Shipped v0.4 of wflow today, a desktop-automation app for Wayland (think macOS Shortcuts + AutoHotkey). Posting here because the architecture is the part Rust folks might find interesting: the entire engine is Rust, exposed to QML through cxx-qt 0.8.

Quick sketch:

The bridge exposes a handful of QObjects to QML: a `LibraryModel` (`QAbstractListModel`-shaped, wrapping the on-disk workflow store), a `PatchController` for the editor session, a `RecorderController` for the record-mode lifecycle, a `TriggersController` for the v0.4 hotkey daemon. QML imports `Wflow 1.0` and that's the entire surface; QML never sees Rust types directly, never knows about cargo.

The engine is async (tokio multi-thread) because flow-control got cleaner once I stopped pretending conditionals + repeat were a flat loop. Steps go through one big `Action` enum in `actions.rs`; adding a new action kind is a new variant, a new arm in `engine::run_action`, and a QML editor delegate. Nothing else branches on kind.

The bridge format is JSON strings (serde_json), even though both sides are typed. Sounds gross, but: the cost of adding a new field is "string in two places, no codegen edits," which has been worth it. The on-disk format is KDL (the `kdl` crate, hand-written encoder), and that's the authoritative store; JSON is just transit between Rust and QML.

Per-step progress streams to QML through Qt's signal/slot system. Engine emits `stepProgress(stepId, outcome, message)` from the worker thread; bridge bounces it through `cxx_qt::CxxQtThread::queue` to the GUI thread; QML binds it to update the row inline. No IPC, no polling.

For v0.4 there's a new `wflow daemon` subcommand that registers global hotkeys via `ashpd::desktop::global_shortcuts`, with a wlroots-IPC fallback for Sway and Hyprland. Single-instance lock via abstract Unix socket. D-Bus interface at `org.cushycush.wflow.Daemon`. The daemon shares the in-process libei backend with the GUI, so no double-init.

A few things worth knowing if you're considering cxx-qt for your own thing:

- `#[qinvokable]` on `&mut self` methods is the cleanest part. QML calls `library.runWorkflow(id)` and it Just Works.
- You'll feel the Qt build complexity. Cargo isn't enough; you need Qt 6 dev headers on the system. Arch: `qt6-base` + `qt6-declarative`. Debian: the `-dev` packages.
- Async + Qt event loop coexist fine if you're disciplined about thread hops.

Repo: https://github.com/cushycush/wflow
The cxx-qt bridge is in `src/bridge/`; engine is in `src/engine.rs`; daemon is in `src/daemon/`.

Roast it. Especially curious if the JSON-string bridge thing horrifies anyone, because every time I describe it I expect someone to tell me I'm holding cxx-qt wrong.

---

## Draft 6 - Lobsters

**Title:** wflow: AutoHotkey + macOS Shortcuts for Linux on Wayland

**Tags:** `release` `linux` `rust`

GUI editor + CLI runner + hotkey daemon for desktop workflows, written in Rust + Qt Quick via cxx-qt. AHK + Shortcuts mental model: visual canvas with a step debugger for the Shortcuts side, plain KDL files in `~/.config/wflow/workflows/` + CLI + chord-to-workflow daemon for the AHK side. All views onto the same files. Input replay is in-process through wdotool-core (libei, virtual-input fallbacks). Hotkey triggers go through the GlobalShortcuts portal on Plasma 6 / GNOME 46+ with a wlroots-IPC fallback; Record uses RemoteDesktop portal with an evdev fallback.

Hotstrings and per-window conditional hotkeys aren't there yet; that's the v0.5 trigger-expansion release.

v0.4: https://github.com/cushycush/wflow

---

## Draft 7 - Blog tip email (covers It's FOSS, 9to5Linux, OMG Linux, LinuxIac, etc.)

**Subject:** wflow 0.4: AutoHotkey + Shortcuts-style automation for Linux Wayland

Hi,

Quick tip if it's a fit. I'm the author of wflow, a GUI app for building and replaying desktop automation workflows on Wayland. Mental model is AutoHotkey + macOS Shortcuts: visual editor for the Shortcuts crowd, plain text files + a CLI + a hotkey daemon for the AHK crowd. Linux's never really had either.

v0.4 shipped today. The editor became a node-graph workspace last week (free-positioning canvas, multi-select, undo/redo, group annotations, step-by-step debugger), and v0.4 ships the AHK-shaped piece: a `wflow daemon` that registers global hotkeys via the portal (or compositor IPC where the portal isn't shipped) and runs the bound workflow when the chord fires.

Hooks your readers might care about:
- Wayland-native. Input replay through libei (no root, no separate binary).
- Hotkey triggers via `org.freedesktop.portal.GlobalShortcuts` on Plasma 6 / GNOME 46+; compositor IPC fallback on Sway and Hyprland. Bindings live in a plain `triggers.kdl`.
- Record uses RemoteDesktop portal on Plasma 6 / GNOME 46+; evdev fallback on Hyprland and other compositors that don't ship the portal yet.
- Workflows are plain KDL files in `~/.config/wflow/workflows/`. Editable in `$EDITOR`, runnable from the CLI, diffable in git.
- Built in Rust + Qt Quick (cxx-qt). Dual MIT / Apache-2.0.
- Arch: `paru -S wflow-bin` (~5 second prebuilt install). Flatpak manifest in repo, Flathub submission in flight.

Repo + screenshots: https://github.com/cushycush/wflow
Release notes: https://github.com/cushycush/wflow/releases/latest

Happy to answer questions or get on a call. No pressure if it's not a fit.

Cheers,
Matt

---

## Draft 8 - Mastodon / fosstodon (under 500 chars)

shipped wflow 0.4: AutoHotkey + macOS Shortcuts for Linux on Wayland. visual editor + step debugger for the Shortcuts side, plain KDL files + a hotkey daemon for the AHK side. portal triggers on Plasma 6 / GNOME 46+, compositor IPC fallback elsewhere. Rust + Qt Quick via cxx-qt, dual MIT/Apache.

`paru -S wflow-bin` on Arch.

https://github.com/cushycush/wflow

---

## Draft 9 - r/AutoHotkey

This crowd is loyal and not going anywhere. Frame: "I built the thing I missed when I went to Linux," not "ditch AHK." Most readers stay on Windows; some have Linux dual-boots or work machines and will care.

**Title:** Built the thing I missed when I went to Linux: wflow, an AHK-flavored automation app for Wayland

Posting here because a chunk of you probably also have a Linux machine somewhere (work, dual-boot, side rig) and have noticed the AHK-shaped hole. I'd been switching between Windows and Linux for a while and got tired of it, so I built a thing.

wflow is a desktop automation app for Linux on Wayland. Plain text files for the script side (KDL, one file per workflow, lives in `~/.config/wflow/workflows/`), a Qt visual editor for when you want a canvas instead of a text file, a CLI runner so cron and scripts work, and as of v0.4 a hotkey daemon that registers chords through the GlobalShortcuts portal (or compositor IPC where the portal isn't shipped yet). The shape of an `.ahk` file mostly carries over: list of steps, conditionals, loops, shell-out, key/mouse send, window-wait predicates, fragment imports for shared code.

What carries over from AHK:
- Plain text scripts you can hand-edit, version-control, and share as one file.
- Send-key, send-text, mouse click/move, focus-window, wait-window, run-shell, sleep.
- Conditionals (`when`/`unless`) and loops (`repeat`).
- A CLI: `wflow run my-script` is the equivalent of double-clicking the `.ahk`.
- Hotkey-fires-script: `triggers.kdl` maps `ctrl+alt+t` to a workflow id; the daemon runs it.

What's not there yet:
- **No hotstrings (text expansion).** This is the gap I miss most personally. Needs a global keyboard *monitor*, not just a binder. On the v0.5 list.
- **No per-window conditional hotkey rules.** Same release.

Honest about scope: AHK is mature, this is v0.4. I'm not coming in hot. But if you've ever wanted "AHK on Linux" and bounced off `xdotool` + bash because Wayland makes input automation a pain, this is what I had to build to be productive on Linux.

Repo + screenshots: https://github.com/cushycush/wflow

Curious which AHK patterns you'd want to see ported over first. The migration page in the docs has a side-by-side for the obvious ones, but I'd rather hear what you actually use day to day.

---

## Notes for the future-me who edits these

- Verify versions before posting. The drafts say "v0.4" generically; substitute the exact version that lands.
- The bracketed `[ONCE DAEMON SHIPS, REPLACE...]` block in Draft 1 is the only place that has a pre/post-daemon branch. Pick one and delete the other.
- The Hyprland post mentions `hyprctl keyword bind` as the IPC-fallback target. If the daemon ends up using a different mechanism (e.g. spawning a `bind = ...` line into a managed file), update the wording so it matches reality.
- The HN body is short on purpose. The first comment after submission should be a longer "story" of why I built this; that's where the AHK-on-Linux gap lands. Don't put the story in the post body.
- Verify `src/daemon/` is the actual path before naming it in the r/rust draft.
- The fosstodon post has a screenshot quota of 4. Pick: library grid, editor canvas, debugger mid-run, triggers tab.
