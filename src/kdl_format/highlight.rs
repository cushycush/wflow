//! KDL syntax-highlight tokenizer. Lives next to encode/decode so the
//! keyword set stays in lockstep with the parser. The output is a flat
//! list of `(start, len, kind)` spans; anything not covered by a span
//! is plain text on the QML side, painted in the default text color.
//!
//! The tokenizer is deliberately tolerant. It runs on whatever text is
//! sitting in the view-source pane (or an explore drawer KDL preview),
//! including malformed input mid-edit. Unrecognized bytes fall through
//! as plain.

use serde::Serialize;

#[derive(Serialize)]
pub struct Span {
    pub start: u32,
    pub len: u32,
    pub kind: &'static str,
}

/// Structural / control-flow words that get the accent treatment.
/// These all appear at node position; a bareword that matches one of
/// these but lives mid-line (as an arg) stays an `ident`.
const KEYWORDS: &[&str] = &[
    // Workflow document shape
    "workflow",
    "schema",
    "id",
    "title",
    "subtitle",
    "recipe",
    "vars",
    "imports",
    "triggers",
    "trigger",
    "groups",
    "group",
    "created",
    "modified",
    "last-run",
    // Control flow
    "when",
    "unless",
    "else",
    "repeat",
    "use",
];

/// Tokenize a KDL source string. Returns spans in document order.
pub fn tokenize(src: &str) -> Vec<Span> {
    let bytes = src.as_bytes();
    let mut out: Vec<Span> = Vec::new();
    let mut i: usize = 0;
    let len = bytes.len();
    // Tracks "next non-whitespace token starts a node". True at start
    // of input and after every newline.
    let mut at_node_position = true;

    while i < len {
        let b = bytes[i];

        // Newline -> node position resets.
        if b == b'\n' {
            i += 1;
            at_node_position = true;
            continue;
        }
        // Other whitespace skipped without changing node-position.
        if b == b' ' || b == b'\t' || b == b'\r' {
            i += 1;
            continue;
        }

        // Line comment: // ... newline
        if b == b'/' && i + 1 < len && bytes[i + 1] == b'/' {
            let start = i;
            while i < len && bytes[i] != b'\n' {
                i += 1;
            }
            out.push(Span {
                start: start as u32,
                len: (i - start) as u32,
                kind: "comment",
            });
            continue;
        }

        // Block comment: /* ... */
        if b == b'/' && i + 1 < len && bytes[i + 1] == b'*' {
            let start = i;
            i += 2;
            while i + 1 < len && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                if bytes[i] == b'\n' {
                    at_node_position = true;
                }
                i += 1;
            }
            if i + 1 < len {
                i += 2; // consume */
            } else {
                i = len;
            }
            out.push(Span {
                start: start as u32,
                len: (i - start) as u32,
                kind: "comment",
            });
            continue;
        }

        // Quoted string. Handles \" escape; the rest of the escape set
        // doesn't change the span shape.
        if b == b'"' {
            let start = i;
            i += 1;
            while i < len {
                let c = bytes[i];
                if c == b'\\' && i + 1 < len {
                    i += 2;
                    continue;
                }
                if c == b'"' {
                    i += 1;
                    break;
                }
                if c == b'\n' {
                    // Unterminated string at EOL; bail without
                    // consuming the newline so the next iteration
                    // resets node-position.
                    break;
                }
                i += 1;
            }
            out.push(Span {
                start: start as u32,
                len: (i - start) as u32,
                kind: "string",
            });
            at_node_position = false;
            continue;
        }

        // KDL keyword values: #true / #false / #null.
        if b == b'#' {
            let start = i;
            let rest = &src[i..];
            let kind = if rest.starts_with("#true") {
                i += "#true".len();
                Some("bool")
            } else if rest.starts_with("#false") {
                i += "#false".len();
                Some("bool")
            } else if rest.starts_with("#null") {
                i += "#null".len();
                Some("bool")
            } else {
                None
            };
            if let Some(kind) = kind {
                out.push(Span {
                    start: start as u32,
                    len: (i - start) as u32,
                    kind,
                });
                at_node_position = false;
                continue;
            }
            // Fallthrough: a `#` that isn't a known keyword sits in
            // the bareword scanner so things like `#standup` (a var
            // value bareword in a raw context) render as ident.
        }

        // Punctuation: braces, semicolons, equals. `=` only emits its
        // own span when it stands alone; the bareword-then-`=` case
        // is handled by the bareword scanner below so the property
        // name itself gets the prop color.
        if b == b'{' || b == b'}' || b == b';' {
            out.push(Span {
                start: i as u32,
                len: 1,
                kind: "punct",
            });
            i += 1;
            // `{` opens a child block on its own line in the encoder
            // but in pasted input it may sit at line end. Either way,
            // node position is governed by the next newline.
            at_node_position = false;
            continue;
        }

        // Number: optional sign + digits, with optional decimal +
        // optional unit suffix (the encoder emits things like
        // `250ms` / `1.5s` as quoted strings, but bare ints like
        // `repeat 3` show up unquoted).
        if b.is_ascii_digit() || (b == b'-' && i + 1 < len && bytes[i + 1].is_ascii_digit()) {
            let start = i;
            if b == b'-' {
                i += 1;
            }
            while i < len && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if i < len && bytes[i] == b'.' {
                i += 1;
                while i < len && bytes[i].is_ascii_digit() {
                    i += 1;
                }
            }
            out.push(Span {
                start: start as u32,
                len: (i - start) as u32,
                kind: "number",
            });
            at_node_position = false;
            continue;
        }

        // Bareword: letters / digits / a handful of identifier-safe
        // punctuation. KDL is more permissive than this, but the
        // encoder's output stays within a quiet ASCII range.
        if is_bareword_start(b) {
            let start = i;
            while i < len && is_bareword_continue(bytes[i]) {
                i += 1;
            }
            let word = &src[start..i];
            // Skip whitespace and peek at the next non-ws byte to
            // decide prop-vs-arg. Inline whitespace only (no
            // newlines), since a newline ends the node.
            let mut k = i;
            while k < len && (bytes[k] == b' ' || bytes[k] == b'\t') {
                k += 1;
            }
            let followed_by_eq = k < len && bytes[k] == b'=';

            let kind = if at_node_position {
                if KEYWORDS.contains(&word) {
                    "keyword"
                } else {
                    "node"
                }
            } else if followed_by_eq {
                "prop"
            } else {
                "ident"
            };
            out.push(Span {
                start: start as u32,
                len: (i - start) as u32,
                kind,
            });
            at_node_position = false;
            continue;
        }

        // `=` not consumed by a prop scan above (e.g. spaced).
        if b == b'=' {
            out.push(Span {
                start: i as u32,
                len: 1,
                kind: "punct",
            });
            i += 1;
            at_node_position = false;
            continue;
        }

        // Fallthrough: leave the byte uncolored.
        i += 1;
    }

    out
}

/// Tokenize and serialize to JSON: `[[start, len, "kind"], ...]`.
/// Returns `"[]"` if anything goes sideways so the bridge doesn't have
/// to special-case errors.
pub fn tokenize_to_json(src: &str) -> String {
    let spans = tokenize(src);
    // Compact tuple form keeps the bridge payload small for big files.
    let tuples: Vec<(u32, u32, &str)> = spans
        .into_iter()
        .map(|s| (s.start, s.len, s.kind))
        .collect();
    serde_json::to_string(&tuples).unwrap_or_else(|_| "[]".into())
}

fn is_bareword_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_' || b == b'-' || b == b'.' || b == b'#' || b == b'$'
}

fn is_bareword_continue(b: u8) -> bool {
    b.is_ascii_alphanumeric()
        || b == b'_'
        || b == b'-'
        || b == b'.'
        || b == b'/'
        || b == b'+'
        || b == b':'
        || b == b'$'
        || b == b'@'
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(src: &str) -> Vec<(&'static str, String)> {
        tokenize(src)
            .into_iter()
            .map(|s| {
                let start = s.start as usize;
                let end = start + s.len as usize;
                (s.kind, src[start..end].to_string())
            })
            .collect()
    }

    #[test]
    fn classifies_workflow_skeleton() {
        let src = r#"workflow "Hello" {
    subtitle "open slack"
    shell "echo hi" retries=3
}
"#;
        let toks = kinds(src);
        assert!(toks.contains(&("keyword", "workflow".into())));
        assert!(toks.contains(&("string", "\"Hello\"".into())));
        assert!(toks.contains(&("keyword", "subtitle".into())));
        assert!(toks.contains(&("node", "shell".into())));
        assert!(toks.contains(&("prop", "retries".into())));
        assert!(toks.contains(&("number", "3".into())));
        assert!(toks.contains(&("punct", "{".into())));
        assert!(toks.contains(&("punct", "}".into())));
    }

    #[test]
    fn keyword_only_at_node_position() {
        // `use` is a keyword at line start but a bare ident when it's
        // an argument to something else.
        let src = "use dev-setup\nshell use\n";
        let toks = kinds(src);
        assert_eq!(toks[0], ("keyword", "use".into()));
        assert_eq!(toks[1], ("ident", "dev-setup".into()));
        assert_eq!(toks[2], ("node", "shell".into()));
        assert_eq!(toks[3], ("ident", "use".into()));
    }

    #[test]
    fn comments_consumed_whole() {
        let src = "// top note\nshell \"x\" /* tail */\n";
        let toks = kinds(src);
        assert_eq!(toks[0].0, "comment");
        assert_eq!(toks[0].1, "// top note");
        assert!(toks.iter().any(|(k, t)| *k == "comment" && t == "/* tail */"));
    }

    #[test]
    fn booleans_recognized() {
        let src = "key \"Return\" disabled=#true\n";
        let toks = kinds(src);
        assert!(toks.contains(&("bool", "#true".into())));
        assert!(toks.contains(&("prop", "disabled".into())));
    }

    #[test]
    fn unterminated_string_doesnt_runaway() {
        let src = "shell \"oops\nkey \"a\"\n";
        // Just shouldn't panic; the unterminated string ends at the
        // newline so the next node still parses.
        let toks = kinds(src);
        assert!(toks.iter().any(|(k, _)| *k == "node"));
    }

    #[test]
    fn negative_number_parses() {
        let src = "move 10 -20 relative=#true\n";
        let toks = kinds(src);
        assert!(toks.iter().any(|(k, t)| *k == "number" && t == "-20"));
    }

    #[test]
    fn empty_input_is_no_spans() {
        assert!(tokenize("").is_empty());
        assert_eq!(tokenize_to_json(""), "[]");
    }
}
