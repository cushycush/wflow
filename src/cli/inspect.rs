//! Read-only library inspection: list, show, validate, ids, path.

use std::process::ExitCode;

use anyhow::{Context, Result};

use crate::store;

use super::{bold, dim, humanize, run::load_target, truncate};

pub(super) fn cmd_path() -> Result<ExitCode> {
    // Match store::workflows_dir; we don't expose that publicly yet.
    let base = dirs::config_dir().context("no XDG config dir")?;
    let dir = base.join("wflow").join("workflows");
    println!("{}", dir.display());
    Ok(ExitCode::SUCCESS)
}

pub(super) fn cmd_ids() -> Result<ExitCode> {
    // Stable, parseable contract: `id\ttitle\n`. Tabs in titles are
    // replaced with spaces to keep the format unambiguous; titles
    // otherwise pass through unchanged. Used by shell completions and
    // anything else that wants to enumerate the library by id.
    let workflows = store::list().context("reading library")?;
    for wf in workflows {
        let title = wf.title.replace('\t', " ");
        println!("{}\t{}", wf.id, title);
    }
    Ok(ExitCode::SUCCESS)
}

pub(super) fn cmd_list(as_json: bool) -> Result<ExitCode> {
    let workflows = store::list().context("reading library")?;

    if as_json {
        #[derive(serde::Serialize)]
        struct Row<'a> {
            id: &'a str,
            title: &'a str,
            subtitle: Option<&'a str>,
            steps: usize,
            last_run: Option<String>,
            modified: Option<String>,
        }
        let rows: Vec<Row> = workflows
            .iter()
            .map(|wf| Row {
                id: &wf.id,
                title: &wf.title,
                subtitle: wf.subtitle.as_deref(),
                steps: wf.steps.len(),
                last_run: wf.last_run.map(|t| t.to_rfc3339()),
                modified: wf.modified.map(|t| t.to_rfc3339()),
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&rows)?);
        return Ok(ExitCode::SUCCESS);
    }

    if workflows.is_empty() {
        println!("no workflows — create one with `wflow run <file.kdl>` or launch the GUI");
        return Ok(ExitCode::SUCCESS);
    }

    // Column widths. Cap id at 36 (UUID len) so long titles still have room.
    let id_w = workflows
        .iter()
        .map(|wf| wf.id.len().min(36))
        .max()
        .unwrap_or(2)
        .max(2);
    let title_w = workflows
        .iter()
        .map(|wf| wf.title.chars().count().min(40))
        .max()
        .unwrap_or(5)
        .max(5);

    println!(
        "{:id_w$}  {:title_w$}  {:>5}  {}",
        "ID",
        "TITLE",
        "STEPS",
        "LAST RUN",
        id_w = id_w,
        title_w = title_w
    );
    for wf in &workflows {
        let title: String = wf.title.chars().take(40).collect();
        let last = wf
            .last_run
            .map(|t| humanize(chrono::Utc::now() - t))
            .unwrap_or_else(|| "never".into());
        println!(
            "{:id_w$}  {:title_w$}  {:>5}  {}",
            truncate(&wf.id, 36),
            title,
            wf.steps.len(),
            last,
            id_w = id_w,
            title_w = title_w
        );
    }
    Ok(ExitCode::SUCCESS)
}

pub(super) fn cmd_validate(target: &str) -> Result<ExitCode> {
    let wf = load_target(target)?;
    let steps = wf.steps.len();
    let steps_word = if steps == 1 { "step" } else { "steps" };
    println!(
        "{} ok — {} {} (schema 1)",
        wf.title, steps, steps_word
    );
    Ok(ExitCode::SUCCESS)
}

pub(super) fn cmd_show(target: &str) -> Result<ExitCode> {
    let wf = load_target(target)?;
    println!("{}", bold(&wf.title));
    if let Some(sub) = &wf.subtitle {
        if !sub.is_empty() {
            println!("  {}", dim(sub));
        }
    }
    if wf.steps.is_empty() {
        println!("  (no steps)");
        return Ok(ExitCode::SUCCESS);
    }
    let w = (wf.steps.len().ilog10() as usize) + 1;
    for (i, step) in wf.steps.iter().enumerate() {
        let marker = if step.enabled { " " } else { "·" };
        let kind = step.action.category();
        println!(
            "  {:>w$}{} {:<9} {}",
            i + 1,
            marker,
            kind,
            step.action.describe(),
            w = w
        );
        if let Some(note) = &step.note {
            if !note.is_empty() {
                println!("     {:w$}   ↳ {}", "", dim(note), w = w);
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}
