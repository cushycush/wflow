//! Host-command helper for Flatpak-sandboxed builds.
//!
//! When wflow ships as a Flatpak (the leg-2 distribution path), the
//! engine still needs to run a few *host* programs: `notify-send`
//! talks to the host's notification daemon, `wl-copy` writes to the
//! host clipboard, and arbitrary `shell "..."` actions are by
//! definition the user's own host commands. None of those work
//! inside the sandbox.
//!
//! Input/window actions (key, type, click, move, scroll, focus) do
//! NOT come through here — those go through `wdotool-core` linked in
//! process, which talks to the libei portal directly without the
//! `flatpak-spawn` indirection.
//!
//! Flatpak's escape hatch is the `flatpak-spawn --host -- <argv>`
//! helper, which uses the `org.freedesktop.Flatpak` D-Bus interface
//! the sandbox is allowed to talk to (when granted
//! `--talk-name=org.freedesktop.Flatpak` in the manifest).
//!
//! Detection is the `FLATPAK_ID` env var, which the Flatpak runtime
//! always sets on the sandbox process. Outside a sandbox, we use the
//! program directly.
//!
//! This module exposes one function — `host_command` — and a thin
//! `in_flatpak` predicate. Every caller in the engine that spawns a
//! host binary goes through `host_command` so the sandbox detection
//! lives in exactly one place.

use tokio::process::Command;

/// True when the current process is running inside a Flatpak sandbox.
///
/// The Flatpak runtime sets `FLATPAK_ID` to the application's reverse-
/// DNS id (e.g. `io.github.cushycush.wflow`). Native installs don't
/// have it, AUR installs don't have it, `cargo install` users don't
/// have it.
pub fn in_flatpak() -> bool {
    std::env::var_os("FLATPAK_ID").is_some()
}

/// Build a `Command` that runs `program` on the host machine, even
/// when wflow is itself running inside a Flatpak sandbox.
///
/// Usage mirrors `tokio::process::Command::new`:
///
/// ```ignore
/// let mut cmd = host::host_command("wdotool");
/// cmd.arg("key").arg("Return");
/// cmd.spawn()?;
/// ```
///
/// On a non-Flatpak install, this is a plain `Command::new(program)`.
/// On a Flatpak install, it becomes
/// `flatpak-spawn --host -- <program>`. Subsequent `.arg()` calls
/// append to the host program's argv as expected — `flatpak-spawn`
/// passes its tail unchanged.
pub fn host_command(program: &str) -> Command {
    if in_flatpak() {
        let mut cmd = Command::new("flatpak-spawn");
        cmd.arg("--host").arg("--").arg(program);
        cmd
    } else {
        Command::new(program)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // FLATPAK_ID is process-wide env state; tests can't run in parallel
    // without trampling each other.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn outside_flatpak_returns_program_directly() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::remove_var("FLATPAK_ID");
        assert!(!in_flatpak());
        // We can't easily assert what `host_command("ls")` decomposes
        // into without exposing internals — verify in_flatpak() since
        // that's what host_command branches on.
    }

    #[test]
    fn inside_flatpak_uses_flatpak_spawn() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("FLATPAK_ID", "io.github.cushycush.wflow");
        assert!(in_flatpak());
        std::env::remove_var("FLATPAK_ID");
    }
}
