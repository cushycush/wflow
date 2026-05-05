//! Library lifecycle: new, edit, rm, migrate.

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{Context, Result};

use crate::actions::Workflow;
use crate::store;

use super::{arrow, check, cross, dim};

pub(super) fn cmd_new(title: &str, to_stdout: bool) -> Result<ExitCode> {
    // Hand-written scaffold so we can mix freeform comments in with
    // the canonical KDL. The steps below are `disabled=#true` so
    // running the fresh workflow is a no-op until the user turns them
    // on. Timestamps live in workflows.toml; the file stays pure spec.
    let wf = Workflow::new(title);
    let template = format!(
        "// A wflow workflow. See `docs/KDL.md` for the full action vocabulary.\n\
         workflow \"{title}\" {{\n    \
             // Starter steps. `disabled=#true` keeps them inert so a fresh\n    \
             // `wflow run` is a no-op. Flip the flag off (or delete the line)\n    \
             // when you want a step to actually fire.\n    \
             notify \"hello from wflow\" disabled=#true\n    \
             shell \"echo 'wflow ran at ' \\\"$(date)\\\"\" disabled=#true\n    \
             wait-window \"Firefox\" timeout=\"5s\" disabled=#true\n    \
             key \"ctrl+l\" disabled=#true\n\
         }}\n",
        title = title.replace('"', "\\\""),
    );
    if to_stdout {
        print!("{template}");
        return Ok(ExitCode::SUCCESS);
    }
    // Persist to the library directory. We need to route through
    // store::save so the file lands with the canonical safe_id-based
    // filename, but save() does not accept a comment template.
    // Shortcut: save the plain workflow, then overwrite the file with
    // the template body in-place so the comments survive.
    let saved = store::save(wf).context("saving workflow")?;
    let base = dirs::config_dir().context("no XDG config dir")?;
    let file = base
        .join("wflow")
        .join("workflows")
        .join(format!("{}.kdl", saved.id.replace(['/', '\\', '.'], "_")));
    std::fs::write(&file, &template).with_context(|| format!("write {}", file.display()))?;
    println!("{}", file.display());
    eprintln!(
        "{} created `{}` — edit the file, then run `wflow run {}`",
        check(),
        title,
        saved.id
    );
    Ok(ExitCode::SUCCESS)
}

pub(super) fn cmd_edit(target: &str) -> Result<ExitCode> {
    // Resolve to an on-disk path. If TARGET points at a real file,
    // just open that — handy for editing a workflow that isn't in the
    // library yet. Otherwise look it up by id.
    let as_path = PathBuf::from(target);
    let path = if as_path.exists() && (target.contains('/') || target.ends_with(".kdl")) {
        as_path
    } else {
        store::path_of(target).with_context(|| {
            format!("no workflow with id `{target}` in library; try `wflow list`")
        })?
    };

    // Defer to the shell so $EDITOR strings like "nvim --noplugin" or
    // "code --wait" word-split correctly. Empty $VISUAL/$EDITOR ⇒
    // xdg-open as a last resort.
    let editor = std::env::var("VISUAL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var("EDITOR").ok().filter(|s| !s.trim().is_empty()))
        .unwrap_or_else(|| "xdg-open".into());

    let status = std::process::Command::new("sh")
        .arg("-c")
        .arg(r#"exec $WFLOW_EDITOR "$@""#)
        .arg("wflow-edit")
        .arg(&path)
        .env("WFLOW_EDITOR", &editor)
        .status()
        .with_context(|| format!("failed to spawn editor `{editor}`"))?;

    if !status.success() {
        anyhow::bail!("editor `{editor}` exited {status}");
    }
    Ok(ExitCode::SUCCESS)
}

pub(super) fn cmd_rm(target: &str, force: bool) -> Result<ExitCode> {
    // Resolve via load() so we get the real id + a friendly title for
    // the confirmation prompt, and so a typoed id errors out before
    // we touch the filesystem.
    let wf = store::load(target).with_context(|| {
        format!("no workflow with id `{target}` in library; try `wflow list`")
    })?;

    if !force {
        use std::io::{IsTerminal, Write};
        if !std::io::stdin().is_terminal() {
            anyhow::bail!("refusing to delete without a TTY; pass --force to override");
        }
        eprint!("delete `{}` ({})? [y/N] ", wf.title, wf.id);
        std::io::stderr().flush().ok();
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        let yes = matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes");
        if !yes {
            eprintln!("{} cancelled", dim("—"));
            return Ok(ExitCode::SUCCESS);
        }
    }

    store::delete(&wf.id).context("removing workflow")?;
    eprintln!("{} deleted `{}` ({})", check(), wf.title, wf.id);
    Ok(ExitCode::SUCCESS)
}

pub(super) fn cmd_migrate(dry_run: bool) -> Result<ExitCode> {
    let workflows = store::list().context("listing workflows")?;
    if workflows.is_empty() {
        println!("library is empty — nothing to migrate");
        return Ok(ExitCode::SUCCESS);
    }

    let mut to_migrate: Vec<(String, String)> = Vec::new(); // (id, current_path)
    let mut already_new: Vec<String> = Vec::new();

    for wf in &workflows {
        let path = match store::path_of(&wf.id) {
            Ok(p) => p,
            Err(_) => continue,
        };
        // Detect by reading the raw text for the legacy shape —
        // `recipe {` or top-level `id "..."` / `schema 1` / etc. The
        // decoder also works as an oracle but reading the bytes is
        // faster and lets us print the path without re-decoding.
        let body = std::fs::read_to_string(&path).unwrap_or_default();
        let is_legacy = body.contains("\nrecipe ")
            || body.starts_with("recipe ")
            || body.contains("\nschema ")
            || body.starts_with("schema ");
        if is_legacy {
            to_migrate.push((wf.id.clone(), path.display().to_string()));
        } else {
            already_new.push(wf.id.clone());
        }
    }

    println!(
        "{} {} workflows total — {} legacy, {} already in the new format",
        arrow(),
        workflows.len(),
        to_migrate.len(),
        already_new.len()
    );

    if to_migrate.is_empty() {
        println!("{} nothing to do", check());
        return Ok(ExitCode::SUCCESS);
    }

    for (id, path) in &to_migrate {
        println!("  {} {} ({})", dim("→"), id, path);
    }

    if dry_run {
        println!();
        println!("{} dry run — pass without --dry-run to actually convert", arrow());
        return Ok(ExitCode::SUCCESS);
    }

    let mut converted = 0usize;
    let mut errors: Vec<(String, String)> = Vec::new();
    for (id, _path) in &to_migrate {
        match store::load(id) {
            Ok(wf) => match store::save(wf) {
                Ok(_) => converted += 1,
                Err(e) => errors.push((id.clone(), format!("{e:#}"))),
            },
            Err(e) => errors.push((id.clone(), format!("{e:#}"))),
        }
    }

    println!();
    println!("{} converted {}/{}", check(), converted, to_migrate.len());
    if !errors.is_empty() {
        println!("{} {} failures:", cross(), errors.len());
        for (id, msg) in &errors {
            println!("  {} {} — {}", cross(), id, msg);
        }
        return Ok(ExitCode::from(1));
    }
    Ok(ExitCode::SUCCESS)
}
