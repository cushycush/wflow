//! System / packaging surfaces: doctor, completions, man.

use std::path::Path;
use std::process::ExitCode;

use anyhow::{Context, Result};
use clap::CommandFactory;
use clap_complete::Shell;

use super::{check, cross, dim, plural_s, which_host, Cli};

pub(super) fn cmd_doctor() -> Result<ExitCode> {
    // Two diagnostics here:
    //
    // 1. The input/window backend wflow links from wdotool-core. We
    //    DON'T actually call `detector::build` because that would
    //    trigger an XDG portal prompt; we just print the priority
    //    order so the user knows which backend the engine will try
    //    first on this compositor.
    //
    // 2. Host binaries the engine still subprocesses for (notify-send
    //    for desktop notifications, wl-copy for clipboard). Inside a
    //    Flatpak sandbox we probe via `flatpak-spawn --host -- which`
    //    so the report reflects what the engine will actually see.
    let in_flatpak = crate::host::in_flatpak();

    // ---- Backend probe (no portal) ----
    let env = wdotool_core::backend::detector::Environment::detect();
    let order = wdotool_core::backend::detector::priority(&env);
    let labels: Vec<&str> = order.iter().map(|k| k.label()).collect();
    if let Some((preferred, fallbacks)) = labels.split_first() {
        let trail = if fallbacks.is_empty() {
            String::new()
        } else {
            format!(" {}", dim(&format!("(fallbacks: {})", fallbacks.join(", "))))
        };
        println!("  {} backend  preferred = {}{}", check(), preferred, trail);
    }

    // ---- Host-binary probes ----
    let tools: &[(&str, &str)] = &[
        ("notify-send", "desktop notifications"),
        ("wl-copy", "clipboard (Wayland)"),
    ];

    if in_flatpak {
        println!("  {}", dim("(probing host PATH via flatpak-spawn)"));
    }

    let mut all_ok = true;
    let path_w = tools.iter().map(|(n, _)| n.len()).max().unwrap_or(0).max(8);
    let missing_label = if in_flatpak { "(not on host PATH)" } else { "(not on PATH)" };
    for (bin, role) in tools {
        match which_host(bin) {
            Some(p) => println!(
                "  {} {:path_w$}  {}  {}",
                check(),
                bin,
                dim(&p.display().to_string()),
                dim(role),
                path_w = path_w
            ),
            None => {
                all_ok = false;
                println!(
                    "  {} {:path_w$}  {}  {}",
                    cross(),
                    bin,
                    dim(missing_label),
                    dim(role),
                    path_w = path_w
                );
            }
        }
    }

    // ---- Workflow directory / count summary ----
    let base = dirs::config_dir().context("no XDG config dir")?;
    let dir = base.join("wflow").join("workflows");
    let count = std::fs::read_dir(&dir)
        .map(|d| d.filter(|e| e.is_ok()).count())
        .unwrap_or(0);
    println!();
    println!(
        "  library: {} ({} file{})",
        dir.display(),
        count,
        plural_s(count)
    );

    if all_ok {
        Ok(ExitCode::SUCCESS)
    } else {
        eprintln!(
            "\n{} some tools are missing — workflows using those actions will fail",
            cross()
        );
        Ok(ExitCode::from(1))
    }
}

pub(super) fn cmd_completions(shell: Shell) -> Result<ExitCode> {
    use std::io::Write;
    let mut cmd = Cli::command();
    let bin_name = cmd.get_name().to_string();

    // Capture into a buffer so we can post-process before writing —
    // zsh's dynamic-completion path needs to swap `_default` for our
    // id completer on a few specific lines.
    let mut buf: Vec<u8> = Vec::new();
    clap_complete::generate(shell, &mut cmd, &bin_name, &mut buf);

    let mut out = std::io::stdout().lock();
    match shell {
        Shell::Fish => {
            out.write_all(&buf)?;
            out.write_all(FISH_DYNAMIC.as_bytes())?;
        }
        Shell::Bash => {
            out.write_all(&buf)?;
            out.write_all(BASH_DYNAMIC.as_bytes())?;
        }
        Shell::Zsh => {
            // Re-target the `_default` action on `target` args
            // belonging to subcommands that take a workflow id.
            // Generated lines look like
            // `':target -- Library id, ...:_default'` — exactly one
            // per affected subcommand, so a literal replace is safe.
            let s = String::from_utf8(buf).context("non-utf8 zsh completion script")?;
            let s = s.replace(
                "':target -- Library id, or path to a .kdl file:_default'",
                "':target -- Library id, or path to a .kdl file:_wflow_ids'",
            );
            let s = s.replace(
                "':target -- Library id of the workflow to remove:_default'",
                "':target -- Library id of the workflow to remove:_wflow_ids'",
            );
            out.write_all(s.as_bytes())?;
            out.write_all(ZSH_DYNAMIC.as_bytes())?;
        }
        // Elvish + PowerShell: ship the static script, no dynamic
        // hook. Users who care can wire one with `wflow ids`.
        _ => {
            out.write_all(&buf)?;
        }
    }
    Ok(ExitCode::SUCCESS)
}

pub(super) fn cmd_man(output: Option<&Path>) -> Result<ExitCode> {
    use std::io::Write;
    let cmd = Cli::command();

    match output {
        None => {
            // Top-level page only, on stdout. The common
            // `wflow man | gzip > /usr/share/man/man1/wflow.1.gz`
            // flow. EPIPE (downstream `head` / `less` closed early)
            // is normal for a shell tool — exit 0 instead of an
            // "error: Broken pipe".
            let mut out = std::io::stdout().lock();
            if let Err(e) = clap_mangen::Man::new(cmd).render(&mut out) {
                if e.kind() != std::io::ErrorKind::BrokenPipe {
                    return Err(e.into());
                }
            }
            Ok(ExitCode::SUCCESS)
        }
        Some(dir) => {
            std::fs::create_dir_all(dir)
                .with_context(|| format!("creating man output dir {}", dir.display()))?;
            // generate_to writes wflow.1 plus wflow-<sub>.1 for every
            // subcommand.
            clap_mangen::generate_to(cmd, dir)
                .with_context(|| format!("writing man pages to {}", dir.display()))?;
            // Print the list of generated files so the caller
            // (PKGBUILD, Makefile) can sanity-check what landed.
            let mut entries: Vec<_> = std::fs::read_dir(dir)
                .with_context(|| format!("reading {}", dir.display()))?
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "1"))
                .collect();
            entries.sort();
            let mut out = std::io::stdout().lock();
            for path in entries {
                writeln!(out, "{}", path.display())?;
            }
            Ok(ExitCode::SUCCESS)
        }
    }
}

// ─────────────────────── completion-script tail snippets ─────────────────────
// Subcommands that take a library id as their first positional are
// kept in sync with these snippets: run, show, validate, edit, rm.

const FISH_DYNAMIC: &str = r#"
# Dynamic library-id completion (added by `wflow completions fish`).
complete -c wflow -n "__fish_wflow_using_subcommand run show validate edit rm" -f -a "(wflow ids 2>/dev/null)"
"#;

const BASH_DYNAMIC: &str = r#"
# Dynamic library-id completion (added by `wflow completions bash`).
# Wraps the clap-generated `_wflow` so subcommands taking a workflow id
# tab-complete from `wflow ids` instead of falling through to filenames.
# Falls through to `_wflow` for flags (cur starts with `-`) and for any
# position other than the subcommand argument.
_wflow_with_ids() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if [ "${COMP_CWORD}" -eq 2 ] && [[ "${cur}" != -* ]]; then
        case "${COMP_WORDS[1]}" in
            run|show|validate|edit|rm)
                local ids
                ids=$(wflow ids 2>/dev/null | cut -f1)
                COMPREPLY=( $(compgen -W "${ids}" -- "${cur}") )
                return 0
                ;;
        esac
    fi
    _wflow "$@"
}
complete -F _wflow_with_ids -o nosort -o bashdefault -o default wflow 2>/dev/null \
    || complete -F _wflow_with_ids -o bashdefault -o default wflow
"#;

const ZSH_DYNAMIC: &str = r#"
# Dynamic library-id completion (added by `wflow completions zsh`).
# Referenced by the `:_wflow_ids` action injected on `target` arguments
# for run/show/validate/edit/rm.
_wflow_ids() {
    local -a entries
    local id title
    while IFS=$'\t' read -r id title; do
        [ -n "$id" ] && entries+=("${id}:${title}")
    done < <(wflow ids 2>/dev/null)
    _describe -t workflows 'workflow' entries
}
"#;
