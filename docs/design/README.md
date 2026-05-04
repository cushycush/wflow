# wflow — design context for Claude Design

This directory is the canonical context bundle for any tool that needs
to understand wflow's visual identity — Claude Design, a designer
new to the project, or future-me six months from now. It exists
because Claude Design's onboarding step is only as good as the inputs
it sees, and the design language is otherwise scattered across QML
files, code comments, and the project root's `CLAUDE.md`.

## What's here

```
docs/design/
├── README.md                  ← you are here
├── design-system.md           ← the canonical system: tokens, principles, motion
├── component-inventory.md     ← every component, where it's used, how it looks
├── design-brief.md            ← what we want designed (desktop polish + website)
└── screenshots/
    ├── README.md              ← capture instructions + manifest
    └── *.png                  ← committed visual baseline
```

Plus two siblings that this package references:

- `docs/branding/` — logo concepts (three SVGs + preview.html).
- `qml/Theme.qml` — the runtime source of truth for tokens. The
  numbers in `design-system.md` are kept in sync with this file.

## Recommended order to feed Claude Design

1. **Onboard the design system** by pointing Claude Design at this
   repo. It will read `qml/Theme.qml` for tokens and the
   `docs/design/*.md` files for the prose.
2. **Upload the screenshots** under `docs/design/screenshots/` so the
   tool has a visual baseline of what's already shipped.
3. **Upload the logo concepts** under `docs/branding/` so brand-mark
   choices are anchored.
4. **Paste the relevant section of `design-brief.md`** for whatever
   you're working on (e.g. the wflows.io landing page section).
5. **Iterate** with inline comments / direct edits / sliders rather
   than starting fresh each turn.

## Authoritative sources, in priority order

When something disagrees, the one higher up wins:

1. `qml/Theme.qml` — runtime tokens. If the doc disagrees with this,
   the doc is wrong.
2. `docs/design/design-system.md` — the principles, anti-references,
   audience. The "why" behind the tokens.
3. The deployed app and `docs/design/screenshots/` — what users
   actually see.
4. Code comments in `qml/components/`. Useful for the local
   reasoning behind a specific pattern.
5. `CLAUDE.md` at the repo root. Slimmer than `design-system.md`
   but more current as a quick orientation.

## Updating

When tokens change:
1. Edit `qml/Theme.qml` first.
2. Update the matching table in `design-system.md`.
3. If a component changes shape, update its row in
   `component-inventory.md`.
4. Re-capture the relevant screenshot.

The design system is small. It's worth keeping these four things
in lockstep instead of letting them drift.
