//! Engine-side wrapper for `wdotool-core`'s Backend trait.
//! Lazy-builds the backend so workflows without input actions skip
//! the libei portal prompt. Window lookups soft-fail to `None` so
//! `unless window="X"` works on machines with no portal at all.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use tokio::sync::OnceCell;
use wdotool_core::backend::detector::{build, Environment};
use wdotool_core::keysym::parse_chain;
use wdotool_core::{DynBackend, KeyDirection, MouseButton, WindowId};

/// `DynBackend` is constructed on first use and shared per-run.
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

// Input dispatch.

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
    // `_clear_modifiers` was an xdotool flag; Wayland can't query
    // the compositor's modifier state, so we drop it silently.
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

// Window queries.

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

// Internals.

/// Mirrors the wdotool CLI's `key foo+bar` sequence: press modifiers,
/// PressRelease the leaf, release modifiers in reverse.
async fn press_release_chain(backend: &DynBackend, chord: &str) -> Result<Option<String>> {
    let chain = parse_chain(chord).map_err(|e| anyhow!("parse {chord:?}: {e}"))?;
    for m in &chain.modifiers {
        backend
            .key(m, KeyDirection::Press)
            .await
            .map_err(|e| anyhow!("key {m}: {e}"))?;
    }
    let key_result = backend.key(&chain.key, KeyDirection::PressRelease).await;
    // Release modifiers even if the leaf failed; otherwise stuck mods.
    for m in chain.modifiers.iter().rev() {
        let _ = backend.key(m, KeyDirection::Release).await;
    }
    key_result
        .map(|_| None)
        .map_err(|e| anyhow!("key {}: {e}", chain.key))
}
