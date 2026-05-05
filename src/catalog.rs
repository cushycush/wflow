//! HTTP + DTOs + fetch helpers for the wflows.io v0 catalog. Lives at
//! crate root rather than under `bridge/explore/` because cxx-qt-build
//! can't span bridge files across directories (QTBUG-93443).

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{Context, Result};

use crate::actions::{
    fmt_duration_ms, step_value_label, Action, OnError, Step, Trigger, TriggerCondition,
    TriggerKind,
};

// HTTP plumbing

/// Shared client. Connection reuse, gzip, 7s timeout.
pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(concat!("wflow/", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(7))
        .build()
        .expect("reqwest client build")
}

/// Snapshot the auth token. In-flight fetches keep their original
/// token if the user signs out mid-call.
pub fn current_token() -> Option<String> {
    let s = crate::state::load();
    s.auth.and_then(|a| {
        if a.token.is_empty() {
            None
        } else {
            Some(a.token)
        }
    })
}

// URL helpers

/// Path-segment encode the chars that change URL semantics. Handles
/// and slugs are validated server-side; everything else passes.
pub fn urlencoded(s: &str) -> String {
    s.replace('/', "%2F").replace('?', "%3F").replace('#', "%23")
}

pub fn same_origin(u: &url::Url, origin: &str) -> bool {
    match url::Url::parse(origin) {
        Ok(o) => u.scheme() == o.scheme() && u.host_str() == o.host_str() && u.port() == o.port(),
        Err(_) => false,
    }
}

// Errors

/// 401 → auth_expired signal; everything else → last_error string.
pub enum FetchError {
    Unauthorized,
    Other(String),
}

/// Publish path. Kept distinct from FetchError so validation-error
/// formatting doesn't bleed into the read-side fetches.
pub enum PublishError {
    Unauthorized,
    Other(String),
}

// ──────────────────────────────────── DTOs ───────────────────────────────────

#[derive(serde::Deserialize)]
pub struct PublishResponse {
    #[serde(default)]
    pub handle: String,
    #[serde(default)]
    pub slug: String,
    #[serde(default)]
    pub url: String,
}

#[derive(serde::Deserialize)]
struct PublishErrorBody {
    #[serde(default)]
    error: String,
    #[serde(default)]
    message: String,
}

#[derive(serde::Deserialize)]
pub struct DetailEnvelope {
    pub data: DetailData,
}

#[derive(serde::Deserialize)]
pub struct DetailData {
    #[serde(rename = "kdlSource")]
    pub kdl_source: String,
    pub title: String,
    pub handle: String,
    pub slug: String,
    /// Optional on the wire; older workflows don't have it.
    #[serde(default)]
    pub description: Option<String>,
    // All counts optional so a sparse response still parses.
    #[serde(default, rename = "installCount")]
    pub install_count: Option<u64>,
    #[serde(default, rename = "commentCount")]
    pub comment_count: Option<u64>,
    #[serde(default, rename = "remixCount")]
    pub remix_count: Option<u64>,
    #[serde(default, rename = "publishedAt")]
    pub published_at: Option<String>,
    #[serde(default, rename = "updatedAt")]
    pub updated_at: Option<String>,
}

/// Payload for the QML deeplink confirm dialog. step_count comes
/// from the runner's decoder so the preview matches reality. chords
/// carries any triggers + a per-chord local-conflict flag.
#[derive(serde::Serialize)]
pub struct DeeplinkPreview {
    pub title: String,
    pub handle: String,
    pub slug: String,
    pub description: String,
    #[serde(rename = "stepCount")]
    pub step_count: usize,
    #[serde(rename = "sourceUrl")]
    pub source_url: String,
    pub chords: Vec<DeeplinkChord>,
}

#[derive(serde::Serialize)]
pub struct DeeplinkChord {
    pub chord: String,
    /// `when window-class=firefox` shape. Empty when the trigger
    /// has no `when`. Renders as a sub-label under the chord pill.
    #[serde(rename = "whenLabel")]
    pub when_label: String,
    /// Title of the local workflow that already binds this chord,
    /// or empty when there's no conflict.
    #[serde(rename = "conflictsWith")]
    pub conflicts_with: String,
}

/// Detail payload for the Explore drawer. Step list comes from the
/// runner's decoder; missing counts/timestamps render as zero/empty.
#[derive(serde::Serialize)]
pub struct WorkflowDetail {
    pub handle: String,
    pub slug: String,
    pub title: String,
    pub description: String,
    #[serde(rename = "installCount")]
    pub install_count: u64,
    #[serde(rename = "commentCount")]
    pub comment_count: u64,
    #[serde(rename = "remixCount")]
    pub remix_count: u64,
    #[serde(rename = "stepCount")]
    pub step_count: usize,
    #[serde(rename = "hasShell")]
    pub has_shell: bool,
    #[serde(rename = "publishedAt")]
    pub published_at: String,
    #[serde(rename = "updatedAt")]
    pub updated_at: String,
    pub steps: Vec<StepPreview>,
}

#[derive(serde::Serialize)]
pub struct StepPreview {
    /// Same vocabulary as `Action::category()`.
    pub kind: &'static str,
    /// Chord, command, window name, duration. Matches the editor's
    /// list view.
    pub value: String,
    pub note: Option<String>,
    /// Non-headline options (shell timeout/retries/capture-as, key
    /// clear-modifiers, wait-window timeout, on-error). The drawer
    /// hides these behind a "Show details" toggle.
    pub details: Vec<DetailKv>,
    /// Repeat body or Conditional's truthy branch. Indented one
    /// level in the detailed view.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub nested: Vec<StepPreview>,
    /// Conditional's else branch. Renders under an ELSE divider.
    #[serde(rename = "nestedElse", skip_serializing_if = "Vec::is_empty")]
    pub nested_else: Vec<StepPreview>,
}

#[derive(serde::Serialize)]
pub struct DetailKv {
    pub label: &'static str,
    pub value: String,
}

// Fetch helpers

pub async fn fetch_preview(url: &str) -> Result<DeeplinkPreview> {
    let body = http_client()
        .get(url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .text()
        .await
        .context("read body")?;

    // /raw returns plain KDL; the v0 detail endpoint returns JSON
    // with a kdlSource field. Fall back to KDL when JSON parse fails.
    let preview = match serde_json::from_str::<DetailEnvelope>(&body) {
        Ok(env) => {
            let wf =
                crate::kdl_format::decode(&env.data.kdl_source).context("decode kdl from wflows.io")?;
            let chords = build_chord_previews(&wf.triggers);
            DeeplinkPreview {
                title: env.data.title,
                handle: env.data.handle,
                slug: env.data.slug,
                description: env.data.description.unwrap_or_default(),
                step_count: wf.steps.len(),
                source_url: url.to_string(),
                chords,
            }
        }
        Err(_) => {
            let wf = crate::kdl_format::decode(&body).context("decode raw kdl")?;
            let chords = build_chord_previews(&wf.triggers);
            DeeplinkPreview {
                title: wf.title.clone(),
                handle: String::new(),
                slug: String::new(),
                description: wf.subtitle.clone().unwrap_or_default(),
                step_count: wf.steps.len(),
                source_url: url.to_string(),
                chords,
            }
        }
    };
    Ok(preview)
}

pub async fn fetch_and_import(url: &str) -> Result<String> {
    let body = http_client()
        .get(url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .text()
        .await
        .context("read body")?;

    // JSON-with-kdlSource first, raw KDL on parse failure.
    let (kdl_text, friendly_title): (String, Option<String>) =
        match serde_json::from_str::<DetailEnvelope>(&body) {
            Ok(env) => (env.data.kdl_source.clone(), Some(env.data.title.clone())),
            Err(_) => (body, None),
        };

    let mut wf = crate::kdl_format::decode(&kdl_text).context("decode kdl from wflows.io")?;
    // Fresh ids so re-imports don't clobber the prior copy.
    wf.id = uuid::Uuid::new_v4().to_string();
    for step in &mut wf.steps {
        step.id = uuid::Uuid::new_v4().to_string();
    }
    if let Some(t) = friendly_title {
        if !t.is_empty() {
            wf.title = t;
        }
    }
    let now = chrono::Utc::now();
    wf.created = Some(now);
    wf.modified = Some(now);
    wf.last_run = None;

    let saved = crate::store::save(wf).context("save imported workflow")?;
    Ok(saved.id)
}

pub async fn fetch_detail(url: &str) -> Result<WorkflowDetail> {
    let body = http_client()
        .get(url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .text()
        .await
        .context("read body")?;

    let env: DetailEnvelope = serde_json::from_str(&body).context("parse detail json")?;
    let wf =
        crate::kdl_format::decode(&env.data.kdl_source).context("decode kdl from wflows.io")?;

    let steps: Vec<StepPreview> = wf.steps.iter().map(step_preview).collect();
    let has_shell = wf
        .steps
        .iter()
        .any(|s| matches!(s.action, Action::Shell { .. }));

    Ok(WorkflowDetail {
        handle: env.data.handle,
        slug: env.data.slug,
        title: env.data.title,
        description: env.data.description.unwrap_or_default(),
        install_count: env.data.install_count.unwrap_or(0),
        comment_count: env.data.comment_count.unwrap_or(0),
        remix_count: env.data.remix_count.unwrap_or(0),
        step_count: wf.steps.len(),
        has_shell,
        published_at: env.data.published_at.unwrap_or_default(),
        updated_at: env.data.updated_at.unwrap_or_default(),
        steps,
    })
}

pub async fn post_publish(
    url: &str,
    token: &str,
    body: &serde_json::Value,
) -> Result<PublishResponse, PublishError> {
    let resp = http_client()
        .post(url)
        .bearer_auth(token)
        .json(body)
        .send()
        .await
        .map_err(|e| PublishError::Other(format!("{e}")))?;

    let status = resp.status();
    if status == reqwest::StatusCode::UNAUTHORIZED {
        return Err(PublishError::Unauthorized);
    }
    if status == reqwest::StatusCode::CREATED || status.is_success() {
        let body_text = resp
            .text()
            .await
            .map_err(|e| PublishError::Other(format!("read body: {e}")))?;
        return serde_json::from_str::<PublishResponse>(&body_text)
            .map_err(|e| PublishError::Other(format!("parse response: {e}")));
    }

    // Surface server's {error, message}; fall back to HTTP status.
    let body_text = resp.text().await.unwrap_or_default();
    if let Ok(eb) = serde_json::from_str::<PublishErrorBody>(&body_text) {
        let msg = if !eb.message.is_empty() {
            eb.message
        } else if !eb.error.is_empty() {
            eb.error
        } else {
            format!("HTTP {status}")
        };
        return Err(PublishError::Other(msg));
    }
    Err(PublishError::Other(format!("HTTP {status}")))
}

// Pure helpers

/// Chord → workflow-title map of the local library. Used once per
/// preview to detect chord conflicts before import.
fn local_chord_index() -> HashMap<String, String> {
    let mut idx = HashMap::new();
    let workflows = match crate::store::list() {
        Ok(w) => w,
        Err(_) => return idx,
    };
    for wf in workflows {
        for t in &wf.triggers {
            if let TriggerKind::Chord { chord } = &t.kind {
                idx.insert(chord.clone(), wf.title.clone());
            }
        }
    }
    idx
}

pub fn build_chord_previews(triggers: &[Trigger]) -> Vec<DeeplinkChord> {
    let local = local_chord_index();
    triggers
        .iter()
        .filter_map(|t| {
            let TriggerKind::Chord { chord } = &t.kind else {
                return None;
            };
            let when_label = match &t.when {
                Some(TriggerCondition::WindowClass { class }) => {
                    format!("when window-class={class}")
                }
                Some(TriggerCondition::WindowTitle { title }) => {
                    format!("when window-title={title}")
                }
                None => String::new(),
            };
            let conflicts_with = local.get(chord).cloned().unwrap_or_default();
            Some(DeeplinkChord {
                chord: chord.clone(),
                when_label,
                conflicts_with,
            })
        })
        .collect()
}

/// One-liner the drawer renders next to each step's icon. Mirrors the
/// editor list view's value column. The label content is shared with
/// the library trail via `actions::step_value_label`. `details` and
/// `nested` carry the rest of the action so the drawer can surface
/// the full picture under "Show details" without a second fetch.
pub fn step_preview(step: &Step) -> StepPreview {
    let mut details: Vec<DetailKv> = Vec::new();
    let mut nested: Vec<StepPreview> = Vec::new();
    let mut nested_else: Vec<StepPreview> = Vec::new();

    match &step.action {
        Action::WdoType { delay_ms: Some(d), .. } => {
            details.push(DetailKv { label: "Per-char delay", value: format!("{d}ms") });
        }
        Action::WdoKey { clear_modifiers: true, .. } => {
            details.push(DetailKv { label: "Clear modifiers", value: "yes".into() });
        }
        Action::WdoMouseMove { relative: true, .. } => {
            details.push(DetailKv { label: "Relative", value: "yes".into() });
        }
        Action::WdoAwaitWindow { timeout_ms, .. } => {
            details.push(DetailKv {
                label: "Timeout",
                value: fmt_duration_ms(*timeout_ms),
            });
        }
        Action::Shell { shell, capture_as, timeout_ms, retries, backoff_ms, .. } => {
            if let Some(s) = shell {
                details.push(DetailKv { label: "Shell", value: s.clone() });
            }
            if let Some(name) = capture_as {
                details.push(DetailKv {
                    label: "Capture as",
                    value: format!("{{{{{name}}}}}"),
                });
            }
            if let Some(t) = timeout_ms {
                details.push(DetailKv {
                    label: "Timeout",
                    value: fmt_duration_ms(*t),
                });
            }
            if *retries > 0 {
                details.push(DetailKv {
                    label: "Retries",
                    value: format!("{retries}"),
                });
                if let Some(b) = backoff_ms {
                    details.push(DetailKv {
                        label: "Backoff",
                        value: fmt_duration_ms(*b),
                    });
                }
            }
        }
        Action::Notify { body: Some(b), .. } if !b.is_empty() => {
            details.push(DetailKv { label: "Body", value: b.clone() });
        }
        Action::Repeat { steps, .. } => {
            nested = steps.iter().map(step_preview).collect();
        }
        Action::Conditional { steps, else_steps, .. } => {
            nested = steps.iter().map(step_preview).collect();
            nested_else = else_steps.iter().map(step_preview).collect();
        }
        _ => {}
    }

    if matches!(step.on_error, OnError::Continue) {
        details.push(DetailKv {
            label: "On error",
            value: "continue".into(),
        });
    }
    if !step.enabled {
        details.push(DetailKv {
            label: "Skip",
            value: "yes".into(),
        });
    }

    StepPreview {
        kind: step.action.category(),
        value: step_value_label(&step.action),
        note: step.note.clone(),
        details,
        nested,
        nested_else,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::{Condition, Step};

    fn step_with(action: Action) -> Step {
        Step {
            id: "t".into(),
            enabled: true,
            note: None,
            on_error: OnError::Stop,
            action,
        }
    }

    #[test]
    fn preview_surfaces_real_command_text() {
        let s = step_with(Action::Shell {
            command: "git log --oneline -20".into(),
            shell: None,
            capture_as: None,
            timeout_ms: None,
            retries: 0,
            backoff_ms: None,
        });
        let p = step_preview(&s);
        assert_eq!(p.kind, "shell");
        assert_eq!(p.value, "git log --oneline -20");
    }

    #[test]
    fn preview_chord_uses_canonical_form() {
        let s = step_with(Action::WdoKey {
            chord: "ctrl+shift+t".into(),
            clear_modifiers: false,
        });
        let p = step_preview(&s);
        assert_eq!(p.kind, "key");
        assert_eq!(p.value, "ctrl+shift+t");
    }

    #[test]
    fn preview_conditional_describes_branch() {
        let s = step_with(Action::Conditional {
            cond: Condition::Window { name: "Slack".into() },
            negate: false,
            steps: vec![],
            else_steps: vec![],
        });
        let p = step_preview(&s);
        assert_eq!(p.kind, "when");
        assert!(p.value.starts_with("when window=Slack"));
    }

    #[test]
    fn preview_carries_note_when_present() {
        let mut s = step_with(Action::Delay { ms: 500 });
        s.note = Some("wait for slack to settle".into());
        let p = step_preview(&s);
        assert_eq!(p.kind, "wait");
        assert_eq!(p.value, "500ms");
        assert_eq!(p.note.as_deref(), Some("wait for slack to settle"));
    }
}
