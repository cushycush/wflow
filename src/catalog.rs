//! HTTP client + DTOs + async fetch helpers for the wflows.io v0
//! catalog API. Used exclusively by `bridge::explore`, but split out
//! from the bridge file to keep the cxx-qt bridge surface small and
//! to keep the pure async + serde code reviewable on its own.
//!
//! Cxx-qt's build pipeline can't span bridge files across directories
//! (Qt bug QTBUG-93443), so this module sits at crate root rather
//! than under `bridge/explore/`.

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{Context, Result};

use crate::actions::{
    fmt_duration_ms, step_value_label, Action, OnError, Step, Trigger, TriggerCondition,
    TriggerKind,
};

// ─────────────────────────────── HTTP plumbing ───────────────────────────────

/// Single shared reqwest client. Connection reuse + gzip decompressor
/// across every catalog call. ~7s timeout is generous for a JSON
/// round-trip; the desktop UI shows "loading" so a stalled network
/// reads as "still working" up to that bound.
pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(concat!("wflow/", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(7))
        .build()
        .expect("reqwest client build")
}

/// Snapshot the persisted auth token from state.toml. Cheap — TOML
/// parse on a small file. Called at the start of each authenticated
/// fetch so an in-flight task uses whatever token was current when it
/// started, even if the user signs out mid-flight.
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

// ──────────────────────────────── URL helpers ────────────────────────────────

/// Path-segment encode the small set Next.js touches client-side.
/// Handles + slugs are validated server-side, so we only need to
/// escape what would otherwise change URL semantics.
pub fn urlencoded(s: &str) -> String {
    s.replace('/', "%2F").replace('?', "%3F").replace('#', "%23")
}

pub fn same_origin(u: &url::Url, origin: &str) -> bool {
    match url::Url::parse(origin) {
        Ok(o) => u.scheme() == o.scheme() && u.host_str() == o.host_str() && u.port() == o.port(),
        Err(_) => false,
    }
}

// ─────────────────────────────────── Errors ──────────────────────────────────

/// Internal error type for authenticated fetches. Lets the queue
/// callback distinguish a 401 (which should fire auth_expired) from
/// any other failure (just sets last_error).
pub enum FetchError {
    Unauthorized,
    Other(String),
}

/// Same shape as FetchError but for the publish path. Kept separate
/// so the message-formatting logic for validation errors stays here
/// without bleeding into the read-side fetches.
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
    /// Catalog "what does this do" blurb. Optional on the wire (older
    /// workflows don't have it) so we deserialise as None when missing.
    #[serde(default)]
    pub description: Option<String>,
    /// Live catalog metrics. All optional so a sparse / staging
    /// response still parses; missing values render as zero / blank
    /// in the drawer rather than killing the whole fetch.
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

/// Preview payload sent to QML for the deeplink confirm dialog.
/// `step_count` is derived from parsing `kdl_source` through the same
/// decoder the run path uses, so it matches what the engine would
/// actually execute. `chords` carries any chord triggers declared in
/// the workflow, plus a conflict flag computed against the user's
/// existing library so the dialog can warn before the user accepts.
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
    /// Reads like `when window-class=firefox`. Empty string when the
    /// trigger has no `when` predicate. The QML dialog renders this
    /// as a secondary line under the chord pill.
    #[serde(rename = "whenLabel")]
    pub when_label: String,
    /// Title of an existing local workflow that already binds this
    /// chord, if any. Empty string when there's no conflict. The
    /// dialog uses this to warn the user that accepting the import
    /// will swap the chord onto the new workflow.
    #[serde(rename = "conflictsWith")]
    pub conflicts_with: String,
}

/// Rich detail payload sent to QML for the Explore drawer. The step
/// list parses from `kdlSource` through the runner's decoder, so what
/// the drawer renders is what would actually execute on import.
/// Counts and timestamps come from the v0 detail JSON; missing fields
/// default to zero / empty rather than failing the whole render.
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
    /// Action category — drives the icon and the QML kindSummary
    /// lookup. Same vocabulary as `Action::category()`.
    pub kind: &'static str,
    /// One-line value for the step (chord, command, window name,
    /// duration, ...). Matches what the local editor surfaces in its
    /// list view; the drawer renders it in Geist Mono so commands
    /// stay scannable.
    pub value: String,
    /// Optional handwritten note. Renders dimmer below the value.
    pub note: Option<String>,
    /// Per-step option key-values that aren't the headline value —
    /// shell timeout / retries / capture-as, key clear-modifiers,
    /// wait-window timeout, on-error policy, etc. The drawer hides
    /// these by default and reveals them under a "Show details"
    /// toggle so the trail stays compact for the casual scan and the
    /// full picture is one click away.
    pub details: Vec<DetailKv>,
    /// Nested steps for flow control: Repeat's body, Conditional's
    /// truthy branch. Empty for leaf actions. Rendered inline under
    /// the parent step in the detailed view, indented one level.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub nested: Vec<StepPreview>,
    /// Conditional's else branch. Same shape as `nested` but rendered
    /// under an "ELSE" divider so the user can see the no-branch
    /// separately from the yes-branch.
    #[serde(rename = "nestedElse", skip_serializing_if = "Vec::is_empty")]
    pub nested_else: Vec<StepPreview>,
}

#[derive(serde::Serialize)]
pub struct DetailKv {
    pub label: &'static str,
    pub value: String,
}

// ────────────────────────────── Fetch helpers ────────────────────────────────

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

    // Preview only meaningful for the v0 detail JSON shape — the /raw
    // KDL endpoint has no metadata to preview. If we got plain KDL,
    // fall back to a minimal preview using the workflow's own title
    // and a step count from the parsed tree, leaving handle / slug /
    // description blank.
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

    // The /raw endpoint returns plain KDL; the
    // /api/v0/workflow/<handle>/<slug> endpoint returns JSON with a
    // kdlSource field. Try JSON first (the v0 path is the desktop's
    // preferred entry), fall back to treating the body as raw KDL.
    let (kdl_text, friendly_title): (String, Option<String>) =
        match serde_json::from_str::<DetailEnvelope>(&body) {
            Ok(env) => (env.data.kdl_source.clone(), Some(env.data.title.clone())),
            Err(_) => (body, None),
        };

    let mut wf = crate::kdl_format::decode(&kdl_text).context("decode kdl from wflows.io")?;
    // Mint fresh ids so importing the same workflow twice produces
    // distinct local copies. The remote slug is preserved in the
    // workflow's name so the user can find it.
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

    // Non-success: surface the server's structured error message.
    // Falls back to "HTTP <status>" when the body isn't the
    // {error, message} shape.
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

// ─────────────────────────────── Pure helpers ────────────────────────────────

/// Walk the local library once and return a chord → workflow-title
/// map for conflict detection. Cheap (KDL parse on every file in
/// `~/.config/wflow/workflows/`) and only used for previews, which
/// happen once per `wflow://` click.
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
