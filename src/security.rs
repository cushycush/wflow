//! Trust check for `wflow run`.
//!
//! A workflow is plain text that runs arbitrary shell. Strangers share
//! `.kdl` files. To keep `wflow run other.kdl` from being a drive-by
//! RCE, the first time a workflow file we didn't author here is run we
//! require explicit confirmation.
//!
//! Trust store: `~/.config/wflow/trusted_workflows`. Each line is
//! `<sha256-hex>  <absolute-path>`, mirroring `sha256sum`'s output
//! format so it's both human-readable and trivially parseable.
//!
//! Trust is keyed by (path, hash). Editing the file re-prompts (the
//! hash changed). Moving the file re-prompts (the path changed). Both
//! are intentional: a workflow is the file at this path with this
//! content; either changing means the user should re-confirm.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};

/// How the caller wants `check_trust` to behave on untrusted input.
///
/// `check_trust` itself never prompts — it tells the caller what state
/// the file is in. CLI prompts via stdin. GUI emits a Qt signal. Yes
/// short-circuits both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustMode {
    /// CLI caller will prompt the user on stdin.
    Cli,
    /// GUI caller will route the prompt through Qt. Wired in a follow-up
    /// pass; allowed-dead until WorkflowController emits the signal.
    #[allow(dead_code)]
    Gui,
    /// Skip the check entirely (--yes / cron / explain / dry-run).
    Yes,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrustDecision {
    /// File matches an existing entry (path + hash). Run away.
    Trusted,
    /// File does not match. Caller decides what to do (prompt / error /
    /// signal). The (canonical_path, hash) pair is included so callers
    /// can `mark_trusted` after confirmation without re-hashing.
    Untrusted {
        canonical_path: PathBuf,
        hash: String,
    },
}

/// Check whether `path` is trusted to run on this machine.
///
/// Returns `Trusted` if mode is `Yes`, or if the trust store contains
/// an entry whose absolute path and content hash both match. Otherwise
/// returns `Untrusted` carrying the canonical path and hash for the
/// caller to use after confirmation.
pub fn check_trust(path: &Path, mode: TrustMode) -> Result<TrustDecision> {
    if mode == TrustMode::Yes {
        return Ok(TrustDecision::Trusted);
    }
    let abs = path
        .canonicalize()
        .with_context(|| format!("canonicalize {}", path.display()))?;
    let hash = hash_file(&abs)?;
    if is_trusted(&abs, &hash)? {
        Ok(TrustDecision::Trusted)
    } else {
        Ok(TrustDecision::Untrusted {
            canonical_path: abs,
            hash,
        })
    }
}

/// SHA-256 of the file's content, hex-encoded.
pub fn hash_file(path: &Path) -> Result<String> {
    let bytes =
        fs::read(path).with_context(|| format!("read {} for hashing", path.display()))?;
    let mut h = Sha256::new();
    h.update(&bytes);
    Ok(hex(&h.finalize()))
}

/// Append `(path, hash)` to the trust store. Replaces any prior entry
/// for the same absolute path. Atomic write via tempfile + rename.
pub fn mark_trusted(canonical_path: &Path, hash: &str) -> Result<()> {
    let store = trust_store_path()?;
    if let Some(parent) = store.parent() {
        fs::create_dir_all(parent)?;
    }

    let path_str = canonical_path.to_string_lossy().to_string();
    let mut lines: Vec<String> = if store.exists() {
        let f = fs::File::open(&store)
            .with_context(|| format!("open {}", store.display()))?;
        BufReader::new(f)
            .lines()
            .map_while(|l| l.ok())
            .filter(|line| match parse_line(line) {
                Some((_h, p)) => p != path_str,
                None => true, // keep blank lines and comments untouched
            })
            .collect()
    } else {
        Vec::new()
    };
    lines.push(format!("{hash}  {path_str}"));

    let tmp = store.with_extension("trusted.tmp");
    {
        let mut f = fs::File::create(&tmp)
            .with_context(|| format!("create {}", tmp.display()))?;
        for line in &lines {
            writeln!(f, "{line}")?;
        }
        f.sync_all().ok();
    }
    fs::rename(&tmp, &store)
        .with_context(|| format!("rename {} -> {}", tmp.display(), store.display()))?;
    Ok(())
}

/// Convenience: hash + mark trusted in one shot. Used by `store::save`
/// to auto-trust workflows wflow itself authored. Errors are ignored —
/// failing to mark trusted means an extra prompt next run, not a crash.
pub fn mark_trusted_from_disk(path: &Path) {
    if let Ok(abs) = path.canonicalize() {
        if let Ok(hash) = hash_file(&abs) {
            let _ = mark_trusted(&abs, &hash);
        }
    }
}

fn is_trusted(abs: &Path, hash: &str) -> Result<bool> {
    let store = trust_store_path()?;
    if !store.exists() {
        return Ok(false);
    }
    let path_str = abs.to_string_lossy().to_string();
    let f = fs::File::open(&store).with_context(|| format!("open {}", store.display()))?;
    for line in BufReader::new(f).lines() {
        let line = line?;
        if let Some((stored_hash, stored_path)) = parse_line(&line) {
            if stored_path == path_str && stored_hash == hash {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

fn parse_line(line: &str) -> Option<(&str, &str)> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let mut parts = line.splitn(2, "  ");
    let hash = parts.next()?;
    let path = parts.next()?;
    if hash.len() != 64 || !hash.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some((hash, path))
}

fn trust_store_path() -> Result<PathBuf> {
    // Tests override this so they don't touch the real config.
    if let Ok(p) = std::env::var("WFLOW_TRUSTED_PATH") {
        return Ok(PathBuf::from(p));
    }
    let dir = dirs::config_dir()
        .context("no XDG_CONFIG_HOME or HOME")?
        .join("wflow");
    Ok(dir.join("trusted_workflows"))
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        use std::fmt::Write;
        write!(s, "{b:02x}").unwrap();
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    // The trust store path is read from a process-wide env var, so the
    // tests can't run in parallel without trampling each other. A mutex
    // keeps them serial within this module.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        _lock: std::sync::MutexGuard<'static, ()>,
        _tmp: TempDir,
    }

    fn setup() -> EnvGuard {
        let lock = ENV_LOCK.lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        std::env::set_var("WFLOW_TRUSTED_PATH", tmp.path().join("trusted_workflows"));
        EnvGuard { _lock: lock, _tmp: tmp }
    }

    fn write_temp_workflow(content: &str) -> (TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wf.kdl");
        fs::write(&path, content).unwrap();
        (dir, path)
    }

    #[test]
    fn yes_short_circuits_to_trusted() {
        let _g = setup();
        let (_d, path) = write_temp_workflow("schema 1");
        let decision = check_trust(&path, TrustMode::Yes).unwrap();
        assert!(matches!(decision, TrustDecision::Trusted));
    }

    #[test]
    fn fresh_file_is_untrusted() {
        let _g = setup();
        let (_d, path) = write_temp_workflow("schema 1");
        let decision = check_trust(&path, TrustMode::Cli).unwrap();
        match decision {
            TrustDecision::Untrusted { hash, .. } => assert_eq!(hash.len(), 64),
            other => panic!("expected Untrusted, got {other:?}"),
        }
    }

    #[test]
    fn marked_file_is_trusted_on_next_check() {
        let _g = setup();
        let (_d, path) = write_temp_workflow("schema 1\nrecipe { note \"hi\" }");
        let abs = path.canonicalize().unwrap();
        let hash = hash_file(&abs).unwrap();
        mark_trusted(&abs, &hash).unwrap();

        let decision = check_trust(&path, TrustMode::Cli).unwrap();
        assert!(matches!(decision, TrustDecision::Trusted));
    }

    #[test]
    fn editing_file_invalidates_trust() {
        let _g = setup();
        let (_d, path) = write_temp_workflow("schema 1");
        mark_trusted_from_disk(&path);
        // Same path, different content → re-prompt expected.
        fs::write(&path, "schema 1\nrecipe { shell \"rm -rf evil\" }").unwrap();
        let decision = check_trust(&path, TrustMode::Cli).unwrap();
        assert!(matches!(decision, TrustDecision::Untrusted { .. }));
    }

    #[test]
    fn moving_file_re_prompts() {
        let _g = setup();
        let (d, path) = write_temp_workflow("schema 1");
        mark_trusted_from_disk(&path);
        let moved = d.path().join("wf-renamed.kdl");
        fs::rename(&path, &moved).unwrap();
        let decision = check_trust(&moved, TrustMode::Cli).unwrap();
        assert!(matches!(decision, TrustDecision::Untrusted { .. }));
    }

    #[test]
    fn re_marking_replaces_old_entry_for_same_path() {
        let _g = setup();
        let (_d, path) = write_temp_workflow("schema 1");
        let abs = path.canonicalize().unwrap();
        mark_trusted(&abs, &"a".repeat(64)).unwrap();
        mark_trusted(&abs, &"b".repeat(64)).unwrap();
        // Trust store should contain exactly one entry for this path.
        let store = trust_store_path().unwrap();
        let body = fs::read_to_string(&store).unwrap();
        let count = body
            .lines()
            .filter(|l| parse_line(l).map_or(false, |(_h, p)| p == abs.to_string_lossy()))
            .count();
        assert_eq!(count, 1, "duplicate entries: {body}");
    }

    #[test]
    fn missing_trust_store_means_untrusted_not_error() {
        let _g = setup();
        let (_d, path) = write_temp_workflow("schema 1");
        // No mark_trusted call — trust store doesn't exist yet.
        let decision = check_trust(&path, TrustMode::Cli).unwrap();
        assert!(matches!(decision, TrustDecision::Untrusted { .. }));
    }

    #[test]
    fn parse_line_rejects_garbage() {
        assert_eq!(parse_line(""), None);
        assert_eq!(parse_line("   "), None);
        assert_eq!(parse_line("# comment"), None);
        assert_eq!(parse_line("notahash  /path"), None);
        // 63 hex chars + path → rejected (wrong length).
        assert_eq!(parse_line(&format!("{}  /p", "a".repeat(63))), None);
        // 64 hex + double-space + path → accepted.
        assert!(parse_line(&format!("{}  /p", "a".repeat(64))).is_some());
    }

    #[test]
    fn corrupt_lines_in_trust_store_dont_crash() {
        let _g = setup();
        let store = trust_store_path().unwrap();
        fs::create_dir_all(store.parent().unwrap()).unwrap();
        fs::write(
            &store,
            "garbage line\n\
             # a comment\n\
             notahash  /some/path\n",
        )
        .unwrap();

        let (_d, path) = write_temp_workflow("schema 1");
        // Should not crash, should return Untrusted.
        let decision = check_trust(&path, TrustMode::Cli).unwrap();
        assert!(matches!(decision, TrustDecision::Untrusted { .. }));
    }
}
