//! First-run user-level install of the `wflow://` URL scheme handler.
//!
//! Why this exists: source / cargo installs of wflow don't drop a
//! `.desktop` file anywhere xdg-open can find it. The packaging
//! tracks (AUR, Flatpak, tarball) install one to /usr/share or the
//! Flatpak export, but a developer running `cargo build && ./target/
//! debug/wflow` has no scheme handler at all. The browser's redirect
//! to `wflow://auth/callback?...` after sign-in goes nowhere — the
//! sign-in flow looks broken.
//!
//! On the first GUI launch this routine writes a per-user .desktop
//! entry to `~/.local/share/applications/` with `Exec=` pointing at
//! the actual wflow binary path (so a future `cargo build` that
//! moves the binary still resolves correctly), runs
//! `update-desktop-database` so xdg-open picks it up immediately,
//! and marks state.toml so we don't redo the work every launch.
//!
//! Re-installs whenever the binary path changes (read the Exec= line
//! from any existing file, compare to current_exe). That covers the
//! `target/debug` → `target/release` transition + the migration from
//! cargo to a system install.
//!
//! Skips on Flatpak — the manifest exports its own .desktop file.
//! Failures are logged at info and treated as fine; the user can
//! still type `xdg-mime default ... x-scheme-handler/wflow` by hand.

use std::path::{Path, PathBuf};

const DESKTOP_FILE_NAME: &str = "io.github.cushycush.wflow.desktop";

/// Install (or refresh) the wflow:// scheme handler on first run.
/// Idempotent across launches via the `scheme_handler_installed` flag
/// in `state.toml`; re-runs when the binary path changes so a fresh
/// build doesn't leave a stale Exec= line behind.
pub fn ensure_installed() {
    if std::env::var("FLATPAK_ID").is_ok() {
        tracing::debug!(
            "scheme-handler: running in Flatpak sandbox; the manifest's exported \
             .desktop file handles the wflow:// scheme"
        );
        return;
    }

    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            tracing::info!("scheme-handler: current_exe() failed: {e}; skipping install");
            return;
        }
    };

    let target_dir = match user_apps_dir() {
        Some(d) => d,
        None => {
            tracing::info!(
                "scheme-handler: no XDG_DATA_HOME / HOME — can't locate user applications dir"
            );
            return;
        }
    };
    let target = target_dir.join(DESKTOP_FILE_NAME);

    let mut state = crate::state::load();

    // If we've installed before AND the existing file's Exec= still
    // points at our binary, there's nothing to do.
    if state.scheme_handler_installed
        && existing_exec_matches(&target, &exe).unwrap_or(false)
    {
        tracing::debug!("scheme-handler: already installed at {}", target.display());
        return;
    }

    if let Err(e) = std::fs::create_dir_all(&target_dir) {
        tracing::info!(
            "scheme-handler: could not create {}: {e}; skipping install",
            target_dir.display()
        );
        return;
    }

    let body = render_desktop_file(&exe);
    if let Err(e) = std::fs::write(&target, body.as_bytes()) {
        tracing::info!(
            "scheme-handler: could not write {}: {e}; skipping install",
            target.display()
        );
        return;
    }
    tracing::info!(
        "scheme-handler: wrote {} (Exec={})",
        target.display(),
        exe.display()
    );

    // Refresh xdg-mime / xdg-open so the new handler is picked up
    // without a logout. Best-effort — distros without
    // update-desktop-database still work, the file just takes
    // effect on next session start.
    let _ = std::process::Command::new("update-desktop-database")
        .arg("--quiet")
        .arg(&target_dir)
        .output();
    let _ = std::process::Command::new("xdg-mime")
        .args(["default", DESKTOP_FILE_NAME, "x-scheme-handler/wflow"])
        .output();

    state.scheme_handler_installed = true;
    crate::state::save(&state);
}

fn user_apps_dir() -> Option<PathBuf> {
    if let Ok(d) = std::env::var("XDG_DATA_HOME") {
        if !d.is_empty() {
            return Some(PathBuf::from(d).join("applications"));
        }
    }
    dirs::home_dir().map(|h| h.join(".local").join("share").join("applications"))
}

fn existing_exec_matches(target: &Path, exe: &Path) -> Option<bool> {
    let body = std::fs::read_to_string(target).ok()?;
    for line in body.lines() {
        if let Some(rest) = line.strip_prefix("Exec=") {
            // Exec line is `<binary> %u` — split off the %u so the
            // comparison is binary-vs-binary.
            let bin = rest.split_whitespace().next().unwrap_or("");
            return Some(bin == exe.to_string_lossy());
        }
    }
    None
}

fn render_desktop_file(exe: &Path) -> String {
    format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=wflow\n\
         GenericName=Workflow Editor\n\
         Comment=Shortcuts for Linux. GUI + KDL workflow files.\n\
         Icon=io.github.cushycush.wflow\n\
         Exec={} %u\n\
         Categories=Utility;Qt;\n\
         Keywords=automation;workflow;shortcuts;wayland;macro;\n\
         StartupNotify=true\n\
         StartupWMClass=wflow\n\
         MimeType=x-scheme-handler/wflow;\n",
        exe.display()
    )
}
