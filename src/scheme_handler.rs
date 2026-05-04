//! Drops a per-user `.desktop` for the `wflow://` scheme. AUR /
//! Flatpak / tarball builds get one through their packaging; this
//! handles `cargo build` developers. Re-runs on binary path changes.

use std::path::{Path, PathBuf};

const DESKTOP_FILE_NAME: &str = "io.github.cushycush.wflow.desktop";

pub fn ensure_installed() {
    if std::env::var("FLATPAK_ID").is_ok() {
        // The Flatpak manifest exports its own .desktop file.
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
                "scheme-handler: no XDG_DATA_HOME / HOME, can't locate user applications dir"
            );
            return;
        }
    };
    let target = target_dir.join(DESKTOP_FILE_NAME);

    let mut state = crate::state::load();

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

    // Pick up without requiring a re-login. Best-effort.
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
            // Exec line is `<binary> %u`; strip the %u for comparison.
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
