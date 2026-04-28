# Contributing to wflow

Thanks for your interest. wflow is a small project but contributions
are welcome — bug reports, fixes, and small features especially.

## Before you start

- For non-trivial work (new features, big refactors, anything that
  touches the engine), please open an issue first to discuss the
  approach. It's faster than landing a PR that needs to be redirected.
- For bug fixes and small improvements, just open the PR.

## Contributor License Agreement (CLA)

By submitting a pull request, you agree to the terms of the
[Contributor License Agreement](CLA.md).

In short: you keep ownership of your work, but you grant the project
a broad license to use it (including the right to re-license under
different terms in the future, so we can keep the project sustainable
long-term). You also confirm that you have the right to contribute the
code you're submitting.

The CLA bot will comment on your first pull request asking you to sign;
once you do, you're set for all future contributions to this project.
You only need to sign once.

## Development setup

```fish
cargo build
cargo test
./target/debug/wflow
```

The full setup notes (Qt 6 / cxx-qt requirements, QML structure, etc.)
live in `CLAUDE.md` at the repo root.

## Commit style

- Plain, present-tense messages. "fix wire routing under zoom" not
  "Fixed wire routing under zoom".
- One logical change per commit. If your PR has unrelated drive-by
  changes, split them.
- No `Co-Authored-By:` trailers, attribution footers, or AI-tool
  signatures.

## What we'll review

- Does the change fit the project's scope (Wayland workflow automation,
  Shortcuts-style GUI + KDL underneath)?
- Does it pass `cargo build` and `cargo test`?
- Does the GUI still cold-boot silent (no QML errors)?
- Is the diff focused?

If your PR meets those, we'll usually merge within a few days. Bigger
or design-led changes take longer.
