//! First-run auto-enable for the trigger daemon's systemd user unit.
//!
//! UX problem this solves: a fresh wflow install ships the
//! `wflow-daemon.service` user unit at
//! `/usr/lib/systemd/user/` (or `~/.config/systemd/user/` for source
//! installs), but it isn't enabled by default. The user has to know
//! about systemd, find the README install snippet, and run
//! `systemctl --user enable --now wflow-daemon`. If they don't, any
//! `trigger { chord "..." }` block they author silently doesn't fire.
//!
//! The fix: on the first GUI launch, run the enable command once.
//! Mark it attempted in `state.toml` so:
//!   - we never retry (a user who later disabled the unit deliberately
//!     doesn't get it re-enabled)
//!   - we don't spam systemctl on every launch
//!
//! Failures are logged at info level and treated as fine. Distros
//! without systemd, Flatpak sandboxes, source installs that haven't
//! copied the unit yet — all return non-zero from systemctl, and we
//! mark the attempt regardless. The user can still run the daemon
//! manually via `wflow daemon`; this is a polish, not a hard
//! requirement.

use std::process::Command;

/// Try to enable + start the systemd user unit for the trigger
/// daemon. Idempotent across launches via the
/// `daemon_autostart_attempted` flag in `state.toml`. Returns
/// quickly — no blocking, no error bubbling — so callers can fire
/// it on GUI startup without worrying about latency.
pub fn ensure_enabled() {
    // Flatpak sandboxes: systemctl --user from inside the sandbox
    // doesn't reach the host's systemd by default. Skip rather than
    // fail noisily on every Flatpak launch. (A future Flatpak-side
    // background portal could fix this; for now Flatpak users would
    // need to run the daemon manually outside the sandbox or wait
    // for that integration.)
    if std::env::var("FLATPAK_ID").is_ok() {
        tracing::debug!(
            "daemon-autostart: running in Flatpak sandbox, skipping systemctl integration"
        );
        return;
    }

    let mut state = crate::state::load();
    if state.daemon_autostart_attempted {
        tracing::debug!("daemon-autostart: already attempted on a previous launch, skipping");
        return;
    }

    let result = Command::new("systemctl")
        .args(["--user", "enable", "--now", "wflow-daemon.service"])
        .output();

    match result {
        Ok(out) if out.status.success() => {
            tracing::info!(
                "daemon-autostart: enabled wflow-daemon.service for the user session"
            );
        }
        Ok(out) => {
            // Most common reason for non-zero exit: the unit file
            // isn't installed (source build without
            // `install -Dm644 packaging/systemd/wflow-daemon.service`).
            // Surface the stderr at info so users debugging can see
            // why it didn't take, but don't treat it as an error.
            let stderr = String::from_utf8_lossy(&out.stderr);
            tracing::info!(
                status = ?out.status,
                stderr = %stderr.trim(),
                "daemon-autostart: systemctl returned non-zero. \
                 The user can still run `wflow daemon` manually."
            );
        }
        Err(e) => {
            // No systemctl on PATH at all — non-systemd distro, or
            // a stripped-down container. Same disposition as above:
            // log and move on.
            tracing::info!(
                error = %e,
                "daemon-autostart: systemctl not available. \
                 The user can still run `wflow daemon` manually."
            );
        }
    }

    // Mark the attempt regardless of outcome. We don't retry —
    // either the user has the unit installed and it worked, or they
    // don't, and we don't want to keep firing systemctl on every
    // launch.
    state.daemon_autostart_attempted = true;
    crate::state::save(&state);
}
