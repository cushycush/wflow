//! `flatpak-spawn --host` wrapper for shell and wl-copy on the
//! Flatpak path. Input goes through wdotool-core in-process and
//! notifications through the portal, so neither comes through here.

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
