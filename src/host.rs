//! Host-command helper for Flatpak-sandboxed builds.
//!
//! When wflow ships as a Flatpak (the leg-2 distribution path), the
//! engine still needs to run *host* programs: wdotool drives the host
//! display server, `notify-send` talks to the host's notification
//! daemon, `wl-copy` writes to the host clipboard, and arbitrary
//! `shell "..."` actions are by definition the user's own host
//! commands. None of those work inside the sandbox.
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
//! This module exposes one function, `host_command`, and a thin
//! `in_flatpak` predicate. Every caller in the engine that spawns a
//! host binary goes through `host_command` so the sandbox detection
//! lives in exactly one place.

use tokio::process::Command;

pub fn in_flatpak() -> bool {
    std::env::var_os("FLATPAK_ID").is_some()
}

/// `Command::new(program)` outside Flatpak, `flatpak-spawn --host --
/// program` inside. `.arg()` appends to the program's argv either way.
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

    // FLATPAK_ID is process-wide; serialise tests.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn outside_flatpak_returns_program_directly() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::remove_var("FLATPAK_ID");
        assert!(!in_flatpak());
    }

    #[test]
    fn inside_flatpak_uses_flatpak_spawn() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("FLATPAK_ID", "io.github.cushycush.wflow");
        assert!(in_flatpak());
        std::env::remove_var("FLATPAK_ID");
    }
}
