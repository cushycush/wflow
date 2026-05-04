//! `systemctl --user enable --now wflow-daemon` on first GUI launch
//! so chord triggers fire without the user knowing about systemd.
//! One-shot, never retries, treats any failure as fine.

use std::process::Command;

pub fn ensure_enabled() {
    // sandbox systemctl doesn't reach the host's systemd.
    if std::env::var("FLATPAK_ID").is_ok() {
        return;
    }

    let mut state = crate::state::load();
    if state.daemon_autostart_attempted {
        return;
    }

    let result = Command::new("systemctl")
        .args(["--user", "enable", "--now", "wflow-daemon.service"])
        .output();

    match result {
        Ok(out) if out.status.success() => {
            tracing::info!("daemon-autostart: enabled wflow-daemon.service");
        }
        Ok(out) => {
            // Usual cause: unit file not installed by the packaging.
            let stderr = String::from_utf8_lossy(&out.stderr);
            tracing::info!(
                status = ?out.status,
                stderr = %stderr.trim(),
                "daemon-autostart: systemctl non-zero, user can run `wflow daemon` manually"
            );
        }
        Err(e) => {
            tracing::info!(
                error = %e,
                "daemon-autostart: systemctl unavailable, user can run `wflow daemon` manually"
            );
        }
    }

    state.daemon_autostart_attempted = true;
    crate::state::save(&state);
}
