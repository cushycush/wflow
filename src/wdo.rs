//! Wayland input/window adapter. Wraps `wdotool-core`'s `Backend`
//! trait in the small surface the engine actually needs (type, key,
//! click, mouse-move, scroll, find-window, activate-window).
//!
//! Two design choices worth knowing about:
//!
//! 1. **Lazy backend.** Building a libei backend triggers an XDG
//!    portal prompt — we don't want that for a workflow that has no
//!    input actions. `LazyBackend` defers `detector::build` to the
//!    first input call and caches the result for the rest of the run.
//!
//! 2. **Failure as `None` for window queries.** When a workflow has
//!    `unless window="X"` and no backend is reachable (no Wayland
//!    session, no portal, no permissions), the right answer is "the
//!    window isn't there" — not a hard error that halts the run.
//!    `find_window_id` swallows backend errors and reports `None`.
//!    Input dispatch (type, key, click, …) does propagate errors so
//!    the user knows why the action didn't run.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use tokio::sync::OnceCell;
use wdotool_core::backend::detector::{build, Environment};
use wdotool_core::keysym::parse_chain;
use wdotool_core::{DynBackend, KeyDirection, MouseButton, WindowId};

/// Cheap-to-clone handle to a (possibly not-yet-built) wdotool backend.
/// The real `DynBackend` is constructed on first use and shared by every
/// subsequent call inside the same workflow run.
#[derive(Clone)]
pub struct LazyBackend {
    cell: Arc<OnceCell<DynBackend>>,
    env: Arc<Environment>,
}

impl LazyBackend {
    pub fn new() -> Self {
        Self {
            cell: Arc::new(OnceCell::new()),
            env: Arc::new(Environment::detect()),
        }
    }

    /// Returns the cached backend, initializing it on first call.
    /// Errors propagate from `wdotool_core::detector::build`.
    pub async fn get(&self) -> Result<&DynBackend> {
        self.cell
            .get_or_try_init(|| async { build(&self.env, None).await })
            .await
            .map_err(|e| anyhow!("wdotool backend init failed: {e}"))
    }
}

impl Default for LazyBackend {
    fn default() -> Self {
        Self::new()
    }
}

// ----------------------------- Input dispatch ------------------------------

pub async fn wdo_type(b: &LazyBackend, text: &str, delay_ms: Option<u32>) -> Result<Option<String>> {
    let backend = b.get().await?;
    let delay = Duration::from_millis(u64::from(delay_ms.unwrap_or(0)));
    backend
        .type_text(text, delay)
        .await
        .map(|_| None)
        .map_err(|e| anyhow!("type: {e}"))
}

pub async fn wdo_key(
    b: &LazyBackend,
    chord: &str,
    _clear_modifiers: bool,
) -> Result<Option<String>> {
    // `_clear_modifiers` was the xdotool `--clearmodifiers` flag in the
    // subprocess era. wdotool-core doesn't expose it on the Backend
    // trait, and Wayland doesn't let a normal client query the
    // compositor's current modifier state — so the "save + restore"
    // semantics xdotool offers can't be replicated here cleanly. Drop
    // silently; if a real workflow needs this we add an explicit
    // wflow-side fallback that releases the standard modifier set.
    let backend = b.get().await?;
    press_release_chain(backend, chord).await
}

pub async fn wdo_key_down(b: &LazyBackend, chord: &str) -> Result<Option<String>> {
    let backend = b.get().await?;
    let chain = parse_chain(chord).map_err(|e| anyhow!("parse {chord:?}: {e}"))?;
    for m in &chain.modifiers {
        backend
            .key(m, KeyDirection::Press)
            .await
            .map_err(|e| anyhow!("key down {m}: {e}"))?;
    }
    backend
        .key(&chain.key, KeyDirection::Press)
        .await
        .map_err(|e| anyhow!("key down {}: {e}", chain.key))?;
    Ok(None)
}

pub async fn wdo_key_up(b: &LazyBackend, chord: &str) -> Result<Option<String>> {
    let backend = b.get().await?;
    let chain = parse_chain(chord).map_err(|e| anyhow!("parse {chord:?}: {e}"))?;
    backend
        .key(&chain.key, KeyDirection::Release)
        .await
        .map_err(|e| anyhow!("key up {}: {e}", chain.key))?;
    for m in chain.modifiers.iter().rev() {
        backend
            .key(m, KeyDirection::Release)
            .await
            .map_err(|e| anyhow!("key up {m}: {e}"))?;
    }
    Ok(None)
}

pub async fn wdo_click(b: &LazyBackend, button: u8) -> Result<Option<String>> {
    let backend = b.get().await?;
    backend
        .mouse_button(MouseButton::from_index(u32::from(button)), KeyDirection::PressRelease)
        .await
        .map(|_| None)
        .map_err(|e| anyhow!("click {button}: {e}"))
}

pub async fn wdo_mouse_down(b: &LazyBackend, button: u8) -> Result<Option<String>> {
    let backend = b.get().await?;
    backend
        .mouse_button(MouseButton::from_index(u32::from(button)), KeyDirection::Press)
        .await
        .map(|_| None)
        .map_err(|e| anyhow!("mousedown {button}: {e}"))
}

pub async fn wdo_mouse_up(b: &LazyBackend, button: u8) -> Result<Option<String>> {
    let backend = b.get().await?;
    backend
        .mouse_button(MouseButton::from_index(u32::from(button)), KeyDirection::Release)
        .await
        .map(|_| None)
        .map_err(|e| anyhow!("mouseup {button}: {e}"))
}

pub async fn wdo_mousemove(
    b: &LazyBackend,
    x: i32,
    y: i32,
    relative: bool,
) -> Result<Option<String>> {
    let backend = b.get().await?;
    backend
        .mouse_move(x, y, !relative)
        .await
        .map(|_| None)
        .map_err(|e| anyhow!("mousemove: {e}"))
}

pub async fn wdo_scroll(b: &LazyBackend, dx: i32, dy: i32) -> Result<Option<String>> {
    let backend = b.get().await?;
    backend
        .scroll(f64::from(dx), f64::from(dy))
        .await
        .map(|_| None)
        .map_err(|e| anyhow!("scroll: {e}"))
}

// ----------------------------- Window queries ------------------------------

pub async fn wdo_activate(b: &LazyBackend, name: &str) -> Result<Option<String>> {
    let id = find_window_id(b, name)
        .await?
        .ok_or_else(|| anyhow!("no window matching {name:?}"))?;
    let backend = b.get().await?;
    backend
        .activate_window(&WindowId(id.clone()))
        .await
        .map(|_| Some(format!("activated window {id}")))
        .map_err(|e| anyhow!("activate window {id}: {e}"))
}

pub async fn wdo_await_window(
    b: &LazyBackend,
    name: &str,
    timeout_ms: u64,
) -> Result<Option<String>> {
    use std::time::Instant;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let poll_every = Duration::from_millis(100);
    loop {
        if let Some(id) = find_window_id(b, name).await? {
            return Ok(Some(format!("window `{name}` at id {id}")));
        }
        if Instant::now() >= deadline {
            return Err(anyhow!(
                "no window matching {name:?} appeared within {timeout_ms}ms"
            ));
        }
        tokio::time::sleep(poll_every).await;
    }
}

/// Title-substring search. `Ok(None)` covers both "no matching window"
/// and "couldn't reach a backend" — see the module-level note on
/// failure semantics for `unless window="X"`.
pub async fn find_window_id(b: &LazyBackend, name: &str) -> Result<Option<String>> {
    let backend = match b.get().await {
        Ok(b) => b,
        Err(_) => return Ok(None),
    };
    let windows = match backend.list_windows().await {
        Ok(w) => w,
        Err(_) => return Ok(None),
    };
    Ok(windows
        .into_iter()
        .find(|w| w.title.contains(name))
        .map(|w| w.id.0))
}

// ----------------------------- Internals -----------------------------------

/// Press all modifiers, PressRelease the leaf key, release modifiers
/// in reverse — the same dance the wdotool CLI does for `key foo+bar`.
async fn press_release_chain(backend: &DynBackend, chord: &str) -> Result<Option<String>> {
    let chain = parse_chain(chord).map_err(|e| anyhow!("parse {chord:?}: {e}"))?;
    for m in &chain.modifiers {
        backend
            .key(m, KeyDirection::Press)
            .await
            .map_err(|e| anyhow!("key {m}: {e}"))?;
    }
    let key_result = backend.key(&chain.key, KeyDirection::PressRelease).await;
    // Always release modifiers, even if the leaf key failed — the
    // user's compositor is otherwise left with stuck mod keys.
    for m in chain.modifiers.iter().rev() {
        let _ = backend.key(m, KeyDirection::Release).await;
    }
    key_result
        .map(|_| None)
        .map_err(|e| anyhow!("key {}: {e}", chain.key))
}
