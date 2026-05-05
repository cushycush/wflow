//! KDL encoder / decoder for `Workflow`.
//!
//! Public surface: parse a `.kdl` file or string into a `Workflow`,
//! emit a `Workflow` back out. Cross-file imports (`imports { ... }`
//! plus `use NAME`) resolve at decode time. Duration shorthands
//! ("250ms", "1.5s", "2m") parse via `parse_duration_ms`.
//!
//! The format. New (v0.4+):
//!
//! ```kdl
//! workflow "Open my dev setup" {
//!     subtitle "launch editor, terminal, focus browser"
//!     vars { repo "~/projects/wflow" }
//!     trigger { chord "super+shift+c" }
//!
//!     shell "hyprctl dispatch exec ghostty"
//!     wait-window "Ghostty" timeout="4s"
//!     key "Return"
//! }
//! ```
//!
//! Legacy (pre-v0.4) `recipe { ... }` files keep parsing forever; the
//! encoder emits the new shape so legacy files round-trip on the
//! next save. `wflow migrate` does the conversion explicitly.
//!
//! Step-level metadata (`disabled=`, `comment=`, `_id=`, `on-error=`)
//! may appear on any action node. Integer values are accepted as both
//! bare positional args and named props (`wait 500` or `wait ms=500`)
//! where sensible.

use anyhow::{bail, Context, Result};

// Re-export actions types so `#[cfg(test)] mod tests { use super::*; }`
// reaches them — and so future module-level helpers don't have to
// reach into `crate::actions` themselves.
#[cfg(test)]
#[allow(unused_imports)]
use crate::actions::{
    Action, Condition, OnError, Step, Trigger, TriggerCondition, TriggerKind, Workflow,
};

mod decode;
mod encode;
mod imports;

pub use decode::decode;
pub use encode::{encode, encode_fragment};
pub use imports::{
    decode_fragment_file, decode_from_file, decode_from_file_authored, expand_imports_in_place,
    resolve_import_path,
};

/// Parse a short human duration like "250ms", "1.5s", "2m", or "1h".
/// No unit suffix defaults to milliseconds so bare numbers still work.
pub fn parse_duration_ms(s: &str) -> Result<u64> {
    let t = s.trim();
    if t.is_empty() {
        bail!("empty duration");
    }
    // Split the trailing unit letters off the numeric part.
    let (num, unit): (&str, &str) = {
        let split = t
            .char_indices()
            .find(|(_, c)| c.is_ascii_alphabetic())
            .map(|(i, _)| i)
            .unwrap_or(t.len());
        (t[..split].trim(), t[split..].trim())
    };

    let value: f64 = num
        .parse()
        .with_context(|| format!("can't parse `{num}` as a number in duration `{s}`"))?;

    let mult_ms: f64 = match unit.to_ascii_lowercase().as_str() {
        "" | "ms" => 1.0,
        "s" | "sec" | "secs" => 1_000.0,
        "m" | "min" | "mins" => 60_000.0,
        "h" | "hr" | "hrs" => 3_600_000.0,
        other => bail!("unknown duration unit `{other}` in `{s}` (use ms, s, m, or h)"),
    };

    if !value.is_finite() || value < 0.0 {
        bail!("duration must be a non-negative number: `{s}`");
    }
    Ok((value * mult_ms).round() as u64)
}
// ---------------------------------------------------------- Tests -----------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::{Action, Step};

    fn wrap(step: &str) -> String {
        format!("schema 1\nid \"t\"\ntitle \"t\"\nrecipe {{\n{step}\n}}\n")
    }

    #[test]
    fn trigger_block_round_trips() {
        use crate::actions::{Trigger, TriggerCondition, TriggerKind};
        let src = "workflow \"t\" {\n    \
            trigger {\n        chord \"super+alt+d\"\n    }\n    \
            trigger {\n        hotstring \"btw\"\n    }\n    \
            trigger {\n        chord \"ctrl+l\"\n        when window-class=\"firefox\"\n    }\n    \
            shell \"kitty\"\n}\n";
        let wf = decode(src).unwrap();
        assert_eq!(wf.triggers.len(), 3);
        assert!(matches!(
            &wf.triggers[0].kind,
            TriggerKind::Chord { chord } if chord == "super+alt+d"
        ));
        assert!(matches!(
            &wf.triggers[1].kind,
            TriggerKind::Hotstring { text } if text == "btw"
        ));
        assert!(matches!(
            &wf.triggers[2].kind,
            TriggerKind::Chord { chord } if chord == "ctrl+l"
        ));
        assert!(matches!(
            &wf.triggers[2].when,
            Some(TriggerCondition::WindowClass { class }) if class == "firefox"
        ));

        // Re-encode and parse again; trigger count + content stable.
        let again = decode(&encode(&wf)).unwrap();
        assert_eq!(again.triggers.len(), 3);
    }

    #[test]
    fn trigger_rejects_two_kinds() {
        let src = "workflow \"t\" {\n    \
            trigger {\n        chord \"ctrl+l\"\n        hotstring \"btw\"\n    }\n}\n";
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("only declare one of"),
            "expected one-kind error, got: {err}"
        );
    }

    #[test]
    fn trigger_rejects_empty_block() {
        let src = "workflow \"t\" {\n    trigger { }\n}\n";
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("at least") || err.contains("chord") || err.contains("hotstring"),
            "expected missing-kind error, got: {err}"
        );
    }

    #[test]
    fn key_names_are_normalized_at_decode() {
        // Hand-authored aliases get canonicalized so `show` and the
        // round-trip reflect what wdotool will actually execute.
        let src = wrap(
            "key \"Enter\"\n\
             key \"Esc\"\n\
             key \"Cmd+Shift+T\"\n\
             key-down \"Option\"\n\
             key-up \"PageDown\"",
        );
        let wf = decode(&src).unwrap();
        let chords: Vec<String> = wf
            .steps
            .iter()
            .map(|s| match &s.action {
                Action::WdoKey { chord, .. } => chord.clone(),
                Action::WdoKeyDown { chord } => chord.clone(),
                Action::WdoKeyUp { chord } => chord.clone(),
                _ => unreachable!(),
            })
            .collect();
        assert_eq!(
            chords,
            vec!["Return", "Escape", "super+shift+T", "alt", "Page_Down"]
        );
    }

    #[test]
    fn imports_and_use_splice_fragments() {
        let dir = tempfile::tempdir().unwrap();
        let dev = dir.path().join("dev.kdl");
        std::fs::write(&dev, "shell \"dev-step\"\nkey \"ctrl+l\"").unwrap();
        let standup = dir.path().join("standup.kdl");
        std::fs::write(&standup, "shell \"standup-step\"").unwrap();

        let main = dir.path().join("main.kdl");
        // Note: unquoted form `use dev-setup` — verifies bare-ident
        // parsing, mirrors the syntax users will write.
        std::fs::write(
            &main,
            r#"schema 1
id "m"
title "M"

imports {
    dev-setup "dev.kdl"
    standup   "standup.kdl"
}

recipe {
    use dev-setup
    shell "mid"
    use dev-setup
    use standup
}"#,
        )
        .unwrap();

        let wf = decode_from_file(&main).unwrap();
        // dev.kdl (2) + mid (1) + dev.kdl (2) + standup.kdl (1) = 6
        assert_eq!(wf.steps.len(), 6);
        assert!(wf.imports.is_empty(), "imports should be cleared after expand");

        // Unknown import → helpful error with a did-you-mean hint.
        let bad = dir.path().join("bad.kdl");
        std::fs::write(
            &bad,
            r#"schema 1
id "b"
title "B"
imports { dev-setup "dev.kdl" }
recipe { use dev-setpu }"#,
        )
        .unwrap();
        let err = decode_from_file(&bad).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("unknown import `dev-setpu`"), "got: {msg}");
        assert!(msg.contains("did you mean `dev-setup`"), "got: {msg}");

        // No imports at all but `use X` → helpful error.
        let empty = dir.path().join("empty.kdl");
        std::fs::write(
            &empty,
            "schema 1\nid \"e\"\ntitle \"E\"\nrecipe { use something }\n",
        )
        .unwrap();
        let err = decode_from_file(&empty).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("no imports declared"),
            "got: {msg}"
        );

        // Duplicate import name → error.
        let dup = dir.path().join("dup.kdl");
        std::fs::write(
            &dup,
            r#"schema 1
id "d"
title "D"
imports {
    dev-setup "dev.kdl"
    dev-setup "standup.kdl"
}
recipe { }"#,
        )
        .unwrap();
        let err = decode_from_file(&dup).unwrap_err();
        assert!(format!("{err:#}").contains("duplicate import"));
    }

    #[test]
    fn use_expands_inside_repeat_and_when() {
        let dir = tempfile::tempdir().unwrap();
        let frag = dir.path().join("frag.kdl");
        std::fs::write(&frag, r#"key "inner""#).unwrap();
        let main = dir.path().join("main.kdl");
        std::fs::write(
            &main,
            r#"schema 1
id "m"
title "M"
imports { frag "frag.kdl" }
recipe {
    repeat 2 {
        use frag
    }
    when env="HOME" {
        use frag
    }
}"#,
        )
        .unwrap();
        let wf = decode_from_file(&main).unwrap();
        match &wf.steps[0].action {
            Action::Repeat { steps, .. } => assert_eq!(steps.len(), 1),
            _ => panic!("expected repeat"),
        }
        match &wf.steps[1].action {
            Action::Conditional { steps, .. } => assert_eq!(steps.len(), 1),
            _ => panic!("expected when"),
        }
    }

    #[test]
    fn use_cycle_is_detected() {
        // A fragment that `use`s a name resolving back to itself (the
        // parent's imports map is inherited into nested splices) should
        // produce a cycle error instead of recursing forever.
        let dir = tempfile::tempdir().unwrap();
        let frag = dir.path().join("frag.kdl");
        std::fs::write(&frag, "use frag").unwrap();
        let main = dir.path().join("main.kdl");
        std::fs::write(
            &main,
            r#"schema 1
id "m"
title "M"
imports { frag "frag.kdl" }
recipe { use frag }"#,
        )
        .unwrap();
        let err = decode_from_file(&main).unwrap_err();
        assert!(
            format!("{err:#}").contains("cycle"),
            "expected cycle error, got: {err:#}"
        );
    }

    #[test]
    fn same_import_in_sibling_branches_is_fine() {
        // Visited is reset per sibling branch, so the same fragment used
        // twice at the top level is not a cycle.
        let dir = tempfile::tempdir().unwrap();
        let frag = dir.path().join("frag.kdl");
        std::fs::write(&frag, r#"key "f""#).unwrap();
        let main = dir.path().join("main.kdl");
        std::fs::write(
            &main,
            r#"schema 1
id "m"
title "M"
imports { frag "frag.kdl" }
recipe {
    use frag
    use frag
}"#,
        )
        .unwrap();
        let wf = decode_from_file(&main).unwrap();
        assert_eq!(wf.steps.len(), 2);
    }

    #[test]
    fn when_unless_round_trip() {
        let src = wrap(
            "when window=\"Firefox\" {\n\
             \t\tkey \"ctrl+l\"\n\
             \t}\n\
             \tunless file=\"/tmp/marker\" {\n\
             \t\tshell \"echo gate\"\n\
             \t}\n\
             \twhen env=\"DEBUG\" equals=\"1\" {\n\
             \t\tnote \"debug on\"\n\
             \t}",
        );
        let wf = decode(&src).unwrap();
        assert_eq!(wf.steps.len(), 3);

        match &wf.steps[0].action {
            Action::Conditional { cond: Condition::Window { name }, negate: false, steps, .. } => {
                assert_eq!(name, "Firefox");
                assert_eq!(steps.len(), 1);
            }
            _ => panic!("expected when window=..."),
        }
        match &wf.steps[1].action {
            Action::Conditional { cond: Condition::File { path }, negate: true, .. } => {
                assert_eq!(path, "/tmp/marker");
            }
            _ => panic!("expected unless file=..."),
        }
        match &wf.steps[2].action {
            Action::Conditional { cond: Condition::Env { name, equals }, negate: false, .. } => {
                assert_eq!(name, "DEBUG");
                assert_eq!(equals.as_deref(), Some("1"));
            }
            _ => panic!("expected when env=..."),
        }

        // Round-trip preserves verb and condition shape.
        let text = encode(&wf);
        assert!(text.contains("when "), "got:\n{text}");
        assert!(text.contains("unless "), "got:\n{text}");
        let back = decode(&text).unwrap();
        assert_eq!(back.steps.len(), 3);
    }

    #[test]
    fn when_else_round_trips() {
        let src = wrap(
            "when window=\"Slack\" {\n\
             \t\tkey \"ctrl+k\"\n\
             \t\telse {\n\
             \t\t\tnotify \"slack closed\"\n\
             \t\t}\n\
             \t}",
        );
        let wf = decode(&src).unwrap();
        match &wf.steps[0].action {
            Action::Conditional { steps, else_steps, negate: false, .. } => {
                assert_eq!(steps.len(), 1);
                assert_eq!(else_steps.len(), 1);
            }
            _ => panic!("expected Conditional with else branch"),
        }
        let text = encode(&wf);
        assert!(text.contains("else "), "encoder should emit `else {{ ... }}`:\n{text}");
        // Round-trip stays stable.
        let back = decode(&text).unwrap();
        match &back.steps[0].action {
            Action::Conditional { steps, else_steps, .. } => {
                assert_eq!(steps.len(), 1);
                assert_eq!(else_steps.len(), 1);
            }
            _ => panic!("round-trip lost the else branch"),
        }
    }

    #[test]
    fn when_else_only_allowed_once() {
        let src = wrap(
            "when window=\"Slack\" {\n\
             \t\tkey \"a\"\n\
             \t\telse { notify \"first\" }\n\
             \t\telse { notify \"second\" }\n\
             \t}",
        );
        let err = format!("{:#}", decode(&src).unwrap_err());
        assert!(err.contains("only have one `else`"), "got: {err}");
    }

    #[test]
    fn when_steps_after_else_rejected() {
        let src = wrap(
            "when window=\"Slack\" {\n\
             \t\tkey \"a\"\n\
             \t\telse { notify \"x\" }\n\
             \t\tkey \"b\"\n\
             \t}",
        );
        let err = format!("{:#}", decode(&src).unwrap_err());
        assert!(err.contains("after `else"), "got: {err}");
    }

    #[test]
    fn when_requires_exactly_one_condition() {
        let err = format!("{:#}", decode(&wrap("when { }")).unwrap_err());
        assert!(err.contains("exactly one condition"), "got: {err}");

        let err = format!("{:#}", decode(&wrap("when window=\"X\" file=\"/p\" { }")).unwrap_err());
        assert!(err.contains("exactly one"), "got: {err}");

        // equals only makes sense with env
        let err = format!(
            "{:#}",
            decode(&wrap("when window=\"X\" equals=\"v\" { }")).unwrap_err()
        );
        assert!(err.contains("doesn't take `equals="), "got: {err}");
    }

    #[test]
    fn repeat_block_round_trips() {
        let src = wrap(
            "repeat 3 {\n\
             \t\tkey \"Tab\"\n\
             \t\twait 50\n\
             \t}",
        );
        let wf = decode(&src).unwrap();
        assert_eq!(wf.steps.len(), 1);
        match &wf.steps[0].action {
            Action::Repeat { count, steps } => {
                assert_eq!(*count, 3);
                assert_eq!(steps.len(), 2);
                assert!(matches!(steps[0].action, Action::WdoKey { .. }));
                assert!(matches!(steps[1].action, Action::Delay { ms: 50 }));
            }
            _ => panic!("expected Repeat"),
        }
        let text = encode(&wf);
        assert!(text.contains("repeat 3"), "got:\n{text}");
        let again = decode(&text).unwrap();
        match &again.steps[0].action {
            Action::Repeat { count, steps } => {
                assert_eq!(*count, 3);
                assert_eq!(steps.len(), 2);
            }
            _ => panic!("expected Repeat"),
        }
    }

    #[test]
    fn repeat_requires_a_block_and_nonnegative_count() {
        let err = format!("{:#}", decode(&wrap("repeat")).unwrap_err());
        assert!(err.contains("needs a positive integer count"), "got: {err}");
        let err = format!("{:#}", decode(&wrap("repeat -3 { }")).unwrap_err());
        assert!(err.contains("count must be >= 0"), "got: {err}");
        let err = format!("{:#}", decode(&wrap("repeat 5")).unwrap_err());
        assert!(err.contains("must have a block"), "got: {err}");
    }

    #[test]
    fn repeat_nested_round_trips() {
        let src = wrap(
            "repeat 2 {\n\
             \t\trepeat 3 {\n\
             \t\t\tkey \"Tab\"\n\
             \t\t}\n\
             \t}",
        );
        let wf = decode(&src).unwrap();
        match &wf.steps[0].action {
            Action::Repeat { count: 2, steps: outer } => match &outer[0].action {
                Action::Repeat { count: 3, steps: inner } => {
                    assert_eq!(inner.len(), 1);
                }
                _ => panic!("expected inner Repeat"),
            },
            _ => panic!("expected outer Repeat"),
        }
    }

    #[test]
    fn shell_retries_round_trip() {
        let src = wrap(
            "shell \"flaky\" retries=3 backoff=\"250ms\"\n\
             shell \"once\"",
        );
        let wf = decode(&src).unwrap();
        match &wf.steps[0].action {
            Action::Shell { retries, backoff_ms, .. } => {
                assert_eq!(*retries, 3);
                assert_eq!(*backoff_ms, Some(250));
            }
            _ => panic!("expected shell"),
        }
        match &wf.steps[1].action {
            Action::Shell { retries, backoff_ms, .. } => {
                assert_eq!(*retries, 0);
                assert_eq!(*backoff_ms, None);
            }
            _ => panic!("expected shell"),
        }

        // Encode + re-decode.
        let text = encode(&wf);
        assert!(text.contains("retries=3"), "got:\n{text}");
        let back = decode(&text).unwrap();
        match &back.steps[0].action {
            Action::Shell { retries, backoff_ms, .. } => {
                assert_eq!(*retries, 3);
                assert_eq!(*backoff_ms, Some(250));
            }
            _ => panic!(),
        }

        // Both backoff forms at once → error
        let err = decode(&wrap(
            r#"shell "x" retries=1 backoff-ms=500 backoff="500ms""#,
        ))
        .unwrap_err();
        assert!(format!("{err:#}").contains("not both"), "got: {err:#}");

        // Negative retries → error
        let err = decode(&wrap(r#"shell "x" retries=-1"#)).unwrap_err();
        assert!(format!("{err:#}").contains("must be >= 0"), "got: {err:#}");
    }

    #[test]
    fn shell_timeout_accepts_both_forms() {
        // Bare-int ms, string form, and no-timeout all decode.
        let src = wrap(
            "shell \"a\" timeout-ms=5000\n\
             shell \"b\" timeout=\"10s\"\n\
             shell \"c\"",
        );
        let wf = decode(&src).unwrap();
        let timeouts: Vec<Option<u64>> = wf
            .steps
            .iter()
            .map(|s| match &s.action {
                Action::Shell { timeout_ms, .. } => *timeout_ms,
                _ => None,
            })
            .collect();
        assert_eq!(timeouts, vec![Some(5_000), Some(10_000), None]);

        // Both forms at once is a user mistake.
        let err = decode(&wrap(
            r#"shell "x" timeout-ms=5000 timeout="10s""#,
        ))
        .unwrap_err();
        assert!(format!("{err:#}").contains("not both"), "got: {err:#}");
    }

    #[test]
    fn on_error_round_trips_and_defaults_stop() {
        // Default = stop → not serialized.
        let mut wf = Workflow::new("t");
        wf.steps.push(Step::new(Action::Note { text: "a".into() }));
        wf.steps.push({
            let mut s = Step::new(Action::Shell {
                command: "false".into(),
                shell: None,
                capture_as: None,
                timeout_ms: None,
                retries: 0,
                backoff_ms: None,
            });
            s.on_error = OnError::Continue;
            s
        });
        let text = encode(&wf);
        // Only the Continue step should mention on-error.
        let occurrences = text.matches("on-error").count();
        assert_eq!(occurrences, 1, "got:\n{text}");
        assert!(text.contains("on-error=continue"), "got:\n{text}");

        // Round trips.
        let back = decode(&text).unwrap();
        assert_eq!(back.steps[0].on_error, OnError::Stop);
        assert_eq!(back.steps[1].on_error, OnError::Continue);
    }

    #[test]
    fn on_error_accepts_stop_and_continue_only() {
        // "stop" and "continue" both parse.
        let src = wrap(
            "shell \"false\" on-error=\"continue\"\n\
             shell \"false\" on-error=\"stop\"",
        );
        let wf = decode(&src).unwrap();
        assert_eq!(wf.steps[0].on_error, OnError::Continue);
        assert_eq!(wf.steps[1].on_error, OnError::Stop);

        // Garbage value errors.
        let err = decode(&wrap(r#"shell "false" on-error="lol""#)).unwrap_err();
        assert!(format!("{err:#}").contains("must be"), "got: {err:#}");
    }

    #[test]
    fn vars_block_round_trips() {
        let src = r#"schema 1
            id "t"
            title "t"
            vars {
                username "matt"
                project "wflow"
            }
            recipe {
                type "{{username}} / {{project}}"
            }"#;
        let wf = decode(src).unwrap();
        assert_eq!(wf.vars.get("username").map(String::as_str), Some("matt"));
        assert_eq!(wf.vars.get("project").map(String::as_str), Some("wflow"));
        let text = encode(&wf);
        assert!(text.contains("vars "), "got:\n{text}");
        let again = decode(&text).unwrap();
        assert_eq!(again.vars, wf.vars);
    }

    #[test]
    fn vars_cannot_shadow_env_namespace() {
        let src = r#"schema 1 id "t" title "t"
            vars {
                env.PATH "nope"
            }
            recipe { }"#;
        let err = decode(src).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("env.*"), "got: {msg}");
        assert!(msg.contains("reserved"), "got: {msg}");
    }

    #[test]
    fn shell_as_captures_into_var() {
        let src = wrap(r#"shell "date +%F" as="today""#);
        let wf = decode(&src).unwrap();
        match &wf.steps[0].action {
            Action::Shell { capture_as, .. } => {
                assert_eq!(capture_as.as_deref(), Some("today"));
            }
            _ => panic!("expected shell"),
        }
    }

    #[test]
    fn substitute_resolves_known_vars_and_errors_on_unknown() {
        use crate::actions::substitute;
        let mut vars = crate::actions::VarMap::new();
        vars.insert("who".into(), "matt".into());

        assert_eq!(substitute("hello {{who}}", &vars).unwrap(), "hello matt");
        assert_eq!(substitute("{{who}}+{{who}}", &vars).unwrap(), "matt+matt");
        // Backslash-escape keeps the literal.
        assert_eq!(substitute(r"literal \{{who}}", &vars).unwrap(), "literal {{who}}");
        // Unknown → error with a hint.
        let err = substitute("hi {{nope}}", &vars).unwrap_err();
        assert!(format!("{err:#}").contains("unknown variable"));
        assert!(format!("{err:#}").contains("known: who"));
        // Unclosed.
        assert!(substitute("{{who", &vars).is_err());
    }

    #[test]
    fn substitute_reads_env_prefix() {
        use crate::actions::substitute;
        std::env::set_var("WFLOW_TEST_VAR_XY", "yep");
        let vars = crate::actions::VarMap::new();
        assert_eq!(substitute("x={{env.WFLOW_TEST_VAR_XY}}", &vars).unwrap(), "x=yep");
        std::env::remove_var("WFLOW_TEST_VAR_XY");
        assert!(substitute("{{env.WFLOW_TEST_VAR_XY}}", &vars).is_err());
    }

    #[test]
    fn old_verb_names_still_decode() {
        // `clip` → `clipboard`, `await-window` → `wait-window`. Old files
        // keep working; only the encoder switches to the new names.
        let src = wrap(
            "clip \"copied\"\n\
             await-window \"Firefox\" timeout=\"5s\"",
        );
        let wf = decode(&src).unwrap();
        let actions: Vec<_> = wf.steps.iter().map(|s| s.action.category()).collect();
        assert_eq!(actions, vec!["clipboard", "wait"]);
    }

    #[test]
    fn shell_prop_accepts_old_and_new_names() {
        // `shell="..."` (old) and `with="..."` (new) both work.
        let a = decode(&wrap(r#"shell "echo hi" with="/bin/bash""#)).unwrap();
        let b = decode(&wrap(r#"shell "echo hi" shell="/bin/bash""#)).unwrap();
        let ja = serde_json::to_value(&a.steps[0].action).unwrap();
        let jb = serde_json::to_value(&b.steps[0].action).unwrap();
        assert_eq!(ja, jb);

        // Both at once is a user mistake.
        let err = decode(&wrap(r#"shell "echo hi" with="/bin/bash" shell="/bin/bash""#))
            .unwrap_err();
        assert!(format!("{err:#}").contains("drop the older `shell=` alias"));
    }

    #[test]
    fn encoder_emits_canonical_names() {
        let mut wf = Workflow::new("t");
        wf.steps.push(Step::new(Action::Clipboard { text: "copied".into() }));
        wf.steps.push(Step::new(Action::WdoAwaitWindow {
            name: "Firefox".into(),
            timeout_ms: 5_000,
        }));
        wf.steps.push(Step::new(Action::Shell {
            command: "echo hi".into(),
            shell: Some("/bin/bash".into()),
            capture_as: None,
            timeout_ms: None,
            retries: 0,
            backoff_ms: None,
        }));
        let text = encode(&wf);
        // KDL autoformat drops quotes when strings are bareword-safe, so
        // match the verb + content on a word boundary instead.
        assert!(text.contains("clipboard copied") || text.contains("clipboard \"copied\""), "got:\n{text}");
        assert!(text.contains("wait-window Firefox") || text.contains("wait-window \"Firefox\""), "got:\n{text}");
        assert!(text.contains("with=\"/bin/bash\"") || text.contains("with=/bin/bash"), "got:\n{text}");
        // No lingering old names on canonical output.
        for line in text.lines() {
            let trimmed = line.trim_start();
            assert!(
                !trimmed.starts_with("clip ") && !trimmed.starts_with("clip\""),
                "line leaks old `clip` verb: {line}"
            );
            assert!(
                !trimmed.starts_with("await-window"),
                "line leaks old `await-window` verb: {line}"
            );
        }
    }

    #[test]
    fn positional_and_prop_forms_both_decode() {
        // Both syntaxes for focus / click / move / scroll parse to the
        // same Action.
        let new_form = wrap(
            "focus \"Firefox\"\n\
             click 2\n\
             move 640 480 relative=#true\n\
             scroll 0 3",
        );
        let old_form = wrap(
            "focus window=\"Firefox\"\n\
             click button=2\n\
             move x=640 y=480 relative=#true\n\
             scroll dx=0 dy=3",
        );
        let a = decode(&new_form).unwrap().steps;
        let b = decode(&old_form).unwrap().steps;
        assert_eq!(a.len(), 4);
        for (sa, sb) in a.iter().zip(b.iter()) {
            let ja = serde_json::to_value(&sa.action).unwrap();
            let jb = serde_json::to_value(&sb.action).unwrap();
            assert_eq!(ja, jb);
        }
    }

    #[test]
    fn positional_and_prop_conflict_rejected() {
        let cases: &[(&str, &str)] = &[
            (r#"focus "X" window="Y""#, "not both"),
            (r#"click 1 button=2"#, "not both"),
            (r#"move 1 2 x=3 y=4"#, "not both"),
            (r#"scroll 0 3 dx=0 dy=3"#, "not both"),
            (r#"await-window "X" timeout-ms=5000 timeout="10s""#, "not both"),
            (r#"wait 500 ms=300"#, "specify the duration once"),
            (r#"wait "1.5s" ms=500"#, "specify the duration once"),
        ];
        for (step, expected) in cases {
            let msg = format!("{:#}", decode(&wrap(step)).unwrap_err());
            assert!(msg.contains(expected), "step `{step}`, got: {msg}");
        }
    }

    #[test]
    fn move_and_scroll_require_both_coords() {
        let msg = format!("{:#}", decode(&wrap("move x=10")).unwrap_err());
        assert!(msg.contains("`move` needs two integer coordinates"), "got: {msg}");

        let msg = format!("{:#}", decode(&wrap("scroll 0")).unwrap_err());
        assert!(msg.contains("`scroll` needs two integer deltas"), "got: {msg}");
    }

    #[test]
    fn missing_required_fields_are_rejected() {
        // Missing id
        let src = r#"schema 1
            title "t"
            recipe { }"#;
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("missing required `id"), "got: {msg}");

        // Missing title
        let src = r#"schema 1
            id "t"
            recipe { }"#;
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("missing required `title"), "got: {msg}");

        // Missing recipe
        let src = r#"schema 1
            id "t"
            title "t""#;
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("missing required `recipe"), "got: {msg}");
    }

    #[test]
    fn unknown_schema_version_is_rejected() {
        let src = r#"schema 42
            id "t"
            title "t"
            recipe { }"#;
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("schema 42 is not supported"), "got: {msg}");
    }

    #[test]
    fn unknown_top_level_node_is_rejected_with_hint() {
        let src = r#"schema 1
            id "t"
            title "t"
            recipie { }"#; // typo
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("unknown top-level node `recipie`"), "got: {msg}");
        assert!(msg.contains("did you mean `recipe`"), "got: {msg}");
    }

    #[test]
    fn unknown_props_are_rejected_with_suggestion() {
        // Typo close enough to be a "did you mean" hit.
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe { click buton=1 }
        "#;
        let err = decode(src).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("unknown property `buton`"), "got: {msg}");
        assert!(msg.contains("did you mean `button`"), "got: {msg}");

        // Totally foreign prop → listed options, no hint.
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe { shell "cmd" gizmo=3 }
        "#;
        let err = decode(src).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("unknown property `gizmo`"), "got: {msg}");
        assert!(
            msg.contains("shell, with, as, timeout, timeout-ms, retries, backoff, backoff-ms, disabled, comment"),
            "got: {msg}"
        );
    }

    #[test]
    fn common_props_still_work() {
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe {
                key "Return" disabled=#true comment="temp"
            }
        "#;
        let wf = decode(src).expect("disabled + comment must remain valid");
        assert_eq!(wf.steps.len(), 1);
        assert!(!wf.steps[0].enabled);
        assert_eq!(wf.steps[0].note.as_deref(), Some("temp"));
    }

    #[test]
    fn note_rejects_foreign_prop() {
        // `note` takes no properties. A property here is clearly a mistake.
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe { note "hi" important=#true }
        "#;
        let err = decode(src).unwrap_err();
        assert!(format!("{err:#}").contains("unknown property `important`"));
    }

    #[test]
    fn duration_parser_handles_common_shapes() {
        assert_eq!(parse_duration_ms("500").unwrap(), 500);
        assert_eq!(parse_duration_ms("500ms").unwrap(), 500);
        assert_eq!(parse_duration_ms("1.5s").unwrap(), 1500);
        assert_eq!(parse_duration_ms("2s").unwrap(), 2000);
        assert_eq!(parse_duration_ms("2m").unwrap(), 120_000);
        assert_eq!(parse_duration_ms("1h").unwrap(), 3_600_000);
        assert_eq!(parse_duration_ms(" 250 ms ").unwrap(), 250);
        // Errors
        assert!(parse_duration_ms("").is_err());
        assert!(parse_duration_ms("abc").is_err());
        assert!(parse_duration_ms("-5s").is_err());
        assert!(parse_duration_ms("5y").is_err());
    }

    #[test]
    fn wait_accepts_bare_int_prop_and_string() {
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe {
                wait 500
                wait ms=250
                wait "1.5s"
                wait "2m"
            }
        "#;
        let wf = decode(src).unwrap();
        let ms: Vec<u64> = wf
            .steps
            .iter()
            .filter_map(|s| match &s.action {
                Action::Delay { ms } => Some(*ms),
                _ => None,
            })
            .collect();
        assert_eq!(ms, vec![500, 250, 1500, 120_000]);
    }

    #[test]
    fn round_trip_preserves_every_action() {
        let mut wf = Workflow::new("test");
        wf.subtitle = Some("end-to-end".into());

        let mut s1 = Step::new(Action::WdoType {
            text: "hello \"world\"".into(),
            delay_ms: Some(30),
        });
        s1.note = Some("greet first".into());

        let mut s2 = Step::new(Action::WdoKey {
            chord: "ctrl+shift+p".into(),
            clear_modifiers: true,
        });
        s2.enabled = false;

        wf.steps = vec![
            s1,
            s2,
            Step::new(Action::WdoKeyDown { chord: "shift".into() }),
            Step::new(Action::WdoKeyUp { chord: "shift".into() }),
            Step::new(Action::WdoMouseDown { button: 1 }),
            Step::new(Action::WdoMouseUp { button: 1 }),
            Step::new(Action::WdoClick { button: 1 }),
            Step::new(Action::WdoMouseMove { x: 10, y: -5, relative: true }),
            Step::new(Action::WdoScroll { dx: 0, dy: 3 }),
            Step::new(Action::WdoActivateWindow { name: "Firefox".into() }),
            Step::new(Action::WdoAwaitWindow { name: "Firefox".into(), timeout_ms: 7500 }),
            Step::new(Action::Delay { ms: 500 }),
            Step::new(Action::Shell { command: "echo hi".into(), shell: None, capture_as: None, timeout_ms: None, retries: 0, backoff_ms: None }),
            Step::new(Action::Shell { command: "date +%F".into(), shell: None, capture_as: Some("today".into()), timeout_ms: Some(30_000), retries: 3, backoff_ms: Some(250) }),
            Step::new(Action::Notify { title: "done".into(), body: Some("all good".into()) }),
            Step::new(Action::Clipboard { text: "copied".into() }),
            Step::new(Action::Note { text: "remember to disable VPN".into() }),
        ];
        wf.vars.insert("username".into(), "matt".into());
        wf.vars.insert("app".into(), "firefox".into());

        let text = encode(&wf);
        let back = decode(&text).expect("decode should succeed");

        assert_eq!(back.title, wf.title);
        assert_eq!(back.subtitle, wf.subtitle);
        assert_eq!(back.steps.len(), wf.steps.len());
        assert_eq!(back.vars, wf.vars);

        // Compare actions pairwise via serde_json (easy structural compare).
        for (a, b) in wf.steps.iter().zip(back.steps.iter()) {
            let ja = serde_json::to_value(&a.action).unwrap();
            let jb = serde_json::to_value(&b.action).unwrap();
            assert_eq!(ja, jb, "action changed through round trip");
            assert_eq!(a.enabled, b.enabled, "enabled flag changed");
            assert_eq!(a.note, b.note, "note changed");
        }
    }

    // ---------- New (v0.4) workflow-block format -------------------

    #[test]
    fn new_format_minimal_decodes() {
        let src = r#"workflow "Hello" {
            note "first step"
            shell "echo hi"
        }
        "#;
        let wf = decode(src).expect("minimal new-format file should decode");
        assert_eq!(wf.title, "Hello");
        assert_eq!(wf.id, ""); // caller fills from filename
        assert_eq!(wf.subtitle, None);
        assert_eq!(wf.steps.len(), 2);
    }

    #[test]
    fn new_format_subtitle_as_child_node() {
        let src = r#"workflow "Morning standup" {
            subtitle "open slack, paste the standard message"
            note "step a"
        }
        "#;
        let wf = decode(src).unwrap();
        assert_eq!(wf.title, "Morning standup");
        assert_eq!(
            wf.subtitle.as_deref(),
            Some("open slack, paste the standard message")
        );
        assert_eq!(wf.steps.len(), 1);
    }

    #[test]
    fn new_format_with_vars_and_imports() {
        // The `#` in `#standup` would close an r#"..."# raw string
        // early, so use r##"..."## to give the delimiter more padding.
        let src = r##"workflow "Daily standup" {
            subtitle "templated message"
            vars {
                channel "#standup"
                ticket "DUR-1"
            }
            imports {
                template "./template.kdl"
            }
            type "{{channel}}"
        }
        "##;
        let wf = decode(src).unwrap();
        assert_eq!(wf.vars.get("channel").map(String::as_str), Some("#standup"));
        assert_eq!(
            wf.imports.get("template").map(String::as_str),
            Some("./template.kdl")
        );
        assert_eq!(wf.steps.len(), 1);
    }

    #[test]
    fn new_format_rejects_legacy_id_inside_workflow() {
        let src = r#"workflow "X" {
            id "should-not-be-here"
            note "x"
        }
        "#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("filename is the id"),
            "expected friendly id-doesn't-belong message, got: {err}"
        );
    }

    #[test]
    fn new_format_rejects_legacy_recipe_wrapper() {
        let src = r#"workflow "X" {
            recipe {
                note "x"
            }
        }
        "#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("recipe"),
            "expected recipe-wrapper rejection, got: {err}"
        );
    }

    #[test]
    fn new_format_rejects_mixed_with_legacy_top_level() {
        let src = r#"schema 1
id "x"
workflow "X" {
    note "x"
}
"#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("mixes the legacy top-level layout"),
            "expected mixed-format rejection, got: {err}"
        );
    }

    #[test]
    fn new_format_rejects_multiple_workflow_blocks_with_future_hint() {
        let src = r#"workflow "A" { note "a" }
workflow "B" { note "b" }
"#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("future release"),
            "expected future-feature rejection, got: {err}"
        );
    }

    #[test]
    fn new_format_missing_title_errors_helpfully() {
        let src = r#"workflow {
            note "x"
        }
        "#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("title"),
            "expected title-required message, got: {err}"
        );
    }

    #[test]
    fn legacy_format_still_decodes() {
        // Sanity: old files keep working alongside the new path.
        let src = r#"schema 1
id "legacy-1"
title "Legacy Workflow"
subtitle "from before v0.4"
recipe {
    note "still works"
}
"#;
        let wf = decode(src).expect("legacy file should still decode");
        assert_eq!(wf.id, "legacy-1");
        assert_eq!(wf.title, "Legacy Workflow");
        assert_eq!(wf.subtitle.as_deref(), Some("from before v0.4"));
        assert_eq!(wf.steps.len(), 1);
    }
}

#[cfg(test)]
mod fragment_roundtrip {
    use super::*;

    #[test]
    fn fragment_encode_then_decode_preserves_steps() {
        // Build a fragment-shaped step list — the "use NAME" import
        // target form: bare nodes, no workflow wrapper.
        let dir = tempfile::tempdir().unwrap();
        let frag_path = dir.path().join("frag.kdl");
        let original = r#"note "Loaded from preamble."
shell "echo hi"
key "ctrl+l"
when window="Firefox" {
    note "Inside the conditional."
}
"#;
        std::fs::write(&frag_path, original).unwrap();

        // Decode it as a fragment.
        let steps = decode_fragment_file(&frag_path).unwrap();
        assert_eq!(steps.len(), 4);

        // Re-encode and round-trip.
        let re_encoded = encode_fragment(&steps);
        let frag_path_2 = dir.path().join("frag2.kdl");
        std::fs::write(&frag_path_2, re_encoded.as_bytes()).unwrap();
        let steps2 = decode_fragment_file(&frag_path_2).unwrap();
        assert_eq!(steps2.len(), 4);

        // Spot-check: the conditional's inner step survived nesting.
        match &steps2[3].action {
            Action::Conditional { steps: inner, .. } => {
                assert_eq!(inner.len(), 1);
            }
            _ => panic!("expected Conditional at index 3"),
        }
    }

    #[test]
    fn fragment_encode_omits_workflow_wrapper() {
        // No "workflow" / "schema" / "imports" / "title" tokens in
        // the fragment output — it must be a bare list of step
        // nodes, otherwise the fragment file becomes a malformed
        // workflow file that wouldn't decode as a fragment again.
        let mut wf = Workflow::new("title-not-emitted");
        wf.steps.push(Step::new(Action::Note { text: "hi".into() }));
        let body = encode_fragment(&wf.steps);
        assert!(!body.contains("workflow"));
        assert!(!body.contains("schema"));
        assert!(!body.contains("imports"));
        assert!(!body.contains("title-not-emitted"));
        // And the step itself IS in the output.
        assert!(body.contains("note"));
        assert!(body.contains("hi"));
    }
}
