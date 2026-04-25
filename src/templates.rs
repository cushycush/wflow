//! Discovery for the example workflow templates shown in the GUI's
//! `+ New workflow → From Template` tab.
//!
//! Lookup order:
//!
//!   1. Each `$XDG_DATA_DIRS/wflow/examples/*.kdl` (the path AUR and
//!      Flathub install into). Distros can ship updated examples
//!      without a binary rebuild.
//!   2. The seven bundled-via-`include_str!` examples baked into the
//!      binary at compile time. Last-resort fallback so `cargo install`
//!      users always have working templates.
//!
//! Bad files in the XDG path are skipped with a warn; missing or empty
//! XDG path falls through to bundled. A misparseable bundled example
//! is a packaging bug and panics on first call (we tolerate user data
//! corruption, not our own).

use std::path::PathBuf;

use kdl::KdlDocument;

#[derive(Debug, Clone)]
pub struct Template {
    /// Filename stem.
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub kdl: String,
}

/// Order = UI order.
const BUNDLED: &[(&str, &str)] = &[
    ("dev-setup", include_str!("../examples/dev-setup.kdl")),
    (
        "screenshot-and-share",
        include_str!("../examples/screenshot-and-share.kdl"),
    ),
    ("daily-standup", include_str!("../examples/daily-standup.kdl")),
    ("loop-tab-thru", include_str!("../examples/loop-tab-thru.kdl")),
    ("if-vpn-then", include_str!("../examples/if-vpn-then.kdl")),
    (
        "flaky-deploy-trigger",
        include_str!("../examples/flaky-deploy-trigger.kdl"),
    ),
    (
        "record-replay-export",
        include_str!("../examples/record-replay-export.kdl"),
    ),
];

pub fn discover() -> Vec<Template> {
    if let Some(from_xdg) = discover_xdg() {
        if !from_xdg.is_empty() {
            return from_xdg;
        }
    }
    bundled()
}

fn discover_xdg() -> Option<Vec<Template>> {
    let dirs = xdg_data_dirs();
    let mut out: Vec<Template> = Vec::new();
    let mut seen_ids = std::collections::HashSet::new();
    for base in dirs {
        let dir = base.join("wflow").join("examples");
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("kdl") {
                continue;
            }
            let id = match path.file_stem().and_then(|s| s.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            if !seen_ids.insert(id.clone()) {
                // First XDG_DATA_DIR wins.
                continue;
            }
            let kdl = match std::fs::read_to_string(&path) {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!("skipping {}: {e}", path.display());
                    continue;
                }
            };
            match parse_template(&id, &kdl) {
                Ok(t) => out.push(t),
                Err(e) => {
                    tracing::warn!("skipping {}: {e}", path.display());
                }
            }
        }
    }
    if out.is_empty() {
        None
    } else {
        out.sort_by(|a, b| a.id.cmp(&b.id));
        Some(out)
    }
}

fn bundled() -> Vec<Template> {
    BUNDLED
        .iter()
        .map(|(id, kdl)| {
            // Bundled = packaging bug if parse fails.
            parse_template(id, kdl).unwrap_or_else(|e| {
                panic!("bundled template `{id}` failed to parse: {e}")
            })
        })
        .collect()
}

fn parse_template(id: &str, kdl_text: &str) -> Result<Template, String> {
    let doc: KdlDocument = kdl_text
        .parse()
        .map_err(|e: kdl::KdlError| format!("kdl parse: {e}"))?;

    // New: title on `workflow "..."`, subtitle inside the block.
    // Legacy: both are top-level nodes.
    let (title, subtitle) =
        if let Some(wf_node) = doc.nodes().iter().find(|n| n.name().value() == "workflow") {
            let title = wf_node
                .entries()
                .first()
                .and_then(|e| e.value().as_string())
                .map(String::from)
                .unwrap_or_else(|| id.to_string());
            let subtitle = wf_node
                .children()
                .and_then(|d| read_top_string(d, "subtitle"))
                .unwrap_or_default();
            (title, subtitle)
        } else {
            let title = read_top_string(&doc, "title").unwrap_or_else(|| id.to_string());
            let subtitle = read_top_string(&doc, "subtitle").unwrap_or_default();
            (title, subtitle)
        };

    Ok(Template {
        id: id.to_string(),
        title,
        subtitle,
        kdl: kdl_text.to_string(),
    })
}

fn read_top_string(doc: &KdlDocument, name: &str) -> Option<String> {
    for node in doc.nodes() {
        if node.name().value() == name {
            if let Some(entry) = node.entries().first() {
                if let Some(s) = entry.value().as_string() {
                    return Some(s.to_string());
                }
            }
        }
    }
    None
}

fn xdg_data_dirs() -> Vec<PathBuf> {
    // $XDG_DATA_HOME, then $XDG_DATA_DIRS, then spec defaults.
    let mut out: Vec<PathBuf> = Vec::new();
    if let Ok(home) = std::env::var("XDG_DATA_HOME") {
        if !home.is_empty() {
            out.push(PathBuf::from(home));
        }
    } else if let Some(home) = dirs::home_dir() {
        out.push(home.join(".local").join("share"));
    }
    if let Ok(dirs) = std::env::var("XDG_DATA_DIRS") {
        if !dirs.is_empty() {
            for d in dirs.split(':').filter(|s| !s.is_empty()) {
                out.push(PathBuf::from(d));
            }
        }
    } else {
        out.push(PathBuf::from("/usr/local/share"));
        out.push(PathBuf::from("/usr/share"));
    }
    if let Ok(p) = std::env::var("WFLOW_TEMPLATES_DIR_OVERRIDE") {
        out.clear();
        if !p.is_empty() {
            out.push(PathBuf::from(p));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // WFLOW_TEMPLATES_DIR_OVERRIDE is process-wide; serialise tests.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn bundled_returns_seven_templates() {
        let t = bundled();
        assert_eq!(t.len(), 7);
        let ids: Vec<&str> = t.iter().map(|t| t.id.as_str()).collect();
        assert!(ids.contains(&"dev-setup"));
        assert!(ids.contains(&"loop-tab-thru"));
    }

    #[test]
    fn bundled_titles_pulled_from_kdl_title_field() {
        let t = bundled();
        let dev = t.iter().find(|t| t.id == "dev-setup").unwrap();
        assert_eq!(dev.title, "Open dev setup");
        assert!(!dev.subtitle.is_empty());
        // The full kdl source rides through unchanged.
        assert!(dev.kdl.contains("workflow \"Open dev setup\""));
    }

    #[test]
    fn discover_falls_back_to_bundled_when_no_xdg() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("WFLOW_TEMPLATES_DIR_OVERRIDE", "/nonexistent/xyz/wflow");
        let t = discover();
        assert_eq!(t.len(), 7);
        std::env::remove_var("WFLOW_TEMPLATES_DIR_OVERRIDE");
    }

    #[test]
    fn discover_uses_xdg_when_present() {
        let _g = ENV_LOCK.lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let examples = dir.path().join("wflow").join("examples");
        std::fs::create_dir_all(&examples).unwrap();
        std::fs::write(
            examples.join("custom.kdl"),
            "schema 1\nid \"custom\"\ntitle \"Custom\"\nsubtitle \"hand-rolled\"\nrecipe { note \"hi\" }\n",
        )
        .unwrap();

        std::env::set_var("WFLOW_TEMPLATES_DIR_OVERRIDE", dir.path());
        let t = discover();
        assert_eq!(t.len(), 1, "should pick up only the XDG file");
        assert_eq!(t[0].id, "custom");
        assert_eq!(t[0].title, "Custom");
        assert_eq!(t[0].subtitle, "hand-rolled");
        std::env::remove_var("WFLOW_TEMPLATES_DIR_OVERRIDE");
    }

    #[test]
    fn bad_xdg_files_are_skipped_not_errored() {
        let _g = ENV_LOCK.lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let examples = dir.path().join("wflow").join("examples");
        std::fs::create_dir_all(&examples).unwrap();
        std::fs::write(examples.join("bad.kdl"), "this { is not parseable {{").unwrap();
        std::fs::write(
            examples.join("good.kdl"),
            "schema 1\nid \"good\"\ntitle \"Good\"\nrecipe { note \"hi\" }\n",
        )
        .unwrap();

        std::env::set_var("WFLOW_TEMPLATES_DIR_OVERRIDE", dir.path());
        let t = discover();
        assert_eq!(t.len(), 1, "bad file skipped, good file kept");
        assert_eq!(t[0].id, "good");
        std::env::remove_var("WFLOW_TEMPLATES_DIR_OVERRIDE");
    }
}
