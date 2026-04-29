# wflow design system

Single canonical reference for the wflow desktop app's visual identity,
intended to seed Claude Design's onboarding. Numbers come from
`qml/Theme.qml`; prose comes from the project's design context.

## Product context

**wflow** is a Wayland workflow automation tool, GUI + CLI, built on
the same crate as wdotool. Think macOS Shortcuts for Linux. Users
record or hand-author sequences of keystrokes, clicks, shell commands,
and waits, then replay them. Workflows persist as plain `.kdl` files
under `~/.config/wflow/workflows/`.

Companion to **wflows.com**, the public catalog where the same users
share their workflows with each other. The desktop and the website
share one visual language; the desktop is authoritative.

## Audience

General Wayland users (GNOME, KDE, Hyprland) who want a friendly GUI
alternative to shell scripts. Keyboard-first power users who still
expect a product that feels at home alongside modern desktop apps.

Primary job to be done: *"I keep doing this sequence of things by hand.
Let me record it once, name it, and replay it."*

## Brand personality

Three words: **calm, confident, contemporary.**

Lives alongside Linear, Arc, Raycast, macOS Shortcuts (dark mode),
modern API clients. Thoughtful spacing, flat surfaces, subtle elevation
by darkness step, functional color on category chips, clean sans
typography.

Emotional goal: **this recedes behind the task.**

## References and anti-references

**References (yes, this energy):**
Linear · Arc browser · Raycast · macOS Shortcuts dark · Requestly ·
Arc settings · Notion's surfaces · Cron / Notion Calendar.

**Anti-references (never this):**
Editorial layouts · modular synth or rack interfaces · glassmorphism ·
neon-on-dark · purple-blue gradients · skeuomorphic hardware · dense
SaaS dashboard templates · bouncy animation · 2024-era AI design slop
(rounded gradient cards in equal-sized grids, big icons over every
heading, gradient text for emphasis, side-stripe accent borders on
list items).

## Color palette

OKLCH was used to design these. Hex listed for portability. Two themes
(dark default, light fallback). Both meet AA contrast on every
text-over-surface pair we ship.

### Surfaces

| Token       | Dark       | Light      | Use                                                  |
|-------------|------------|------------|------------------------------------------------------|
| `bg`        | `#07090e`  | `#f6f6f8`  | Window background, behind everything                 |
| `surface`   | `#15181f`  | `#ffffff`  | Card / dialog body, the canonical "raised" tone      |
| `surface2`  | `#1d2028`  | `#eeeef1`  | Hover step on a card; slightly raised group bg       |
| `surface3`  | `#262a33`  | `#e2e3e8`  | Active / pressed state; or a deeper nested group     |
| `line`      | `#2c2f37`  | `#d4d5dc`  | 1px hairline, the strongest divider we draw          |
| `lineSoft`  | `#1a1d25`  | `#e2e3e8`  | Subtler hairline (between siblings, around chips)    |

Surfaces step by lightness only. Going `bg → surface → surface2 →
surface3` is brightness only, not hue shift. The 1px `line` hairline
is the strongest divider we draw; beyond that, change the fill, not
the border.

### Text

| Token   | Dark       | Light      | Use                              |
|---------|------------|------------|----------------------------------|
| `text`  | `#edeef1`  | `#1c1d22`  | Primary text, titles, body       |
| `text2` | `#a9acb4`  | `#55585f`  | Secondary text, subtitles, meta  |
| `text3` | `#6f727a`  | `#82858c`  | Tertiary text, hints, labels     |

### Accent

Warm amber. **Reserved.** Used for ONE thing at a time on a page: the
primary affordance (Run, Record arm, Save), or the selected sidebar
row. Never sprinkled.

| Token        | Dark       | Light      | Use                                 |
|--------------|------------|------------|-------------------------------------|
| `accent`     | `#e29846`  | `#b8742a`  | Primary fill                        |
| `accentHi`   | `#f1a95a`  | `#c78232`  | Hover on filled accent              |
| `accentLo`   | `#c7833a`  | `#9a5f1f`  | Pressed                             |
| `accentDim`  | `#5a4025`  | `#f1dcbe`  | Muted accent (selected-row tint)    |
| `accentText` | `#1a1208`  | `#1a1208`  | Text on top of a filled accent fill |

### Semantic

| Token   | Dark       | Light      | Use                              |
|---------|------------|------------|----------------------------------|
| `ok`    | `#64c28a`  | `#1e8a52`  | Step succeeded / install success |
| `warn`  | `#d8b24e`  | `#8a6512`  | Caution (shell pip, undo toast)  |
| `err`   | `#dd6b55`  | `#b0392b`  | Step failed; Record (red)        |

### Category tints

Category chips (HTTP-method-style) per action kind. Tint **only on
the chip**, never elsewhere. Accent amber stays orthogonal: it signals
active/selected, not category.

| Kind        | Dark       | Light      |
|-------------|------------|------------|
| key         | `#a184ea`  | `#6a4ed0`  |
| type        | `#7393e6`  | `#3b5fc2`  |
| click       | `#64c28a`  | `#1e8a52`  |
| move        | `#5fb3b9`  | `#297d83`  |
| scroll      | `#5fb0cb`  | `#246d8a`  |
| focus       | `#d8a74e`  | `#8a6512`  |
| wait        | `#878a94`  | `#6c7079`  |
| shell       | `#e09066`  | `#a0532e`  |
| notify      | `#da77a8`  | `#b0427a`  |
| clipboard   | `#62b2c7`  | `#2a7f94`  |
| note        | `#707278`  | `#5a5d62`  |
| when        | `#df88d6`  | `#a056a0`  |
| unless      | `#ee8896`  | `#c45670`  |
| repeat      | `#cae870`  | `#7da030`  |
| use         | `#a08ed0`  | `#5a4090`  |

## Typography

Body family: **Hanken Grotesk**. Weights 400 / 500 / 600 / 700.
Mono family: **Geist Mono**. Used for technical values: commands, key
chords, paths, IDs, byte counts, durations.

**Banned families** (these are the AI design tells in 2024–2026):
Inter, Fraunces, Newsreader, Lora, Crimson*, Playfair, Cormorant,
Syne, IBM Plex*, Space Mono, Space Grotesk, DM Sans, DM Serif, Outfit,
Plus Jakarta, Instrument Sans, Instrument Serif.

### Scale (px)

| Token      | Size | Use                                |
|------------|------|------------------------------------|
| `fontXs`   | 11   | Eyebrows, footnotes, small labels  |
| `fontSm`   | 13   | Subtitles, secondary UI            |
| `fontBase` | 14   | Body text, primary UI default      |
| `fontMd`   | 16   | Section headings inside a panel    |
| `fontLg`   | 20   | Page titles, modal titles          |
| `fontXl`   | 28   | Hero headings, splash titles       |

5-step scale, ~1.25 ratio. Use fewer sizes with more contrast; don't
add intermediate steps.

### Weight rules

- Page title: 600 (DemiBold).
- Section heading: 600.
- Body: 400.
- UI label / chip / button: 500 (Medium).
- Active/selected: 600.
- Code / mono: 400. Never bold mono — looks goofy.

## Spacing

4pt scale. Use semantic names, not pixel literals.

| Token | px | Use                                        |
|-------|----|--------------------------------------------|
| `s1`  | 4  | Tight (icon + label, chip internals)       |
| `s2`  | 8  | Default sibling gap                        |
| `s3`  | 12 | Comfortable padding inside small surfaces  |
| `s4`  | 16 | Section padding inside a card              |
| `s5`  | 24 | Between cards / form sections              |
| `s6`  | 32 | Section break inside a page                |
| `s7`  | 48 | Between major sections                     |
| `s8`  | 64 | Page-level breathing room                  |

## Radii

Two values cover everything. Don't introduce new radii.

| Token       | px | Use                                                |
|-------------|----|----------------------------------------------------|
| `radiusSm`  | 6  | Buttons, chips, icon boxes, small fills            |
| `radiusMd`  | 8  | Cards, dialogs, container surfaces                 |
| `radiusLg`  | 12 | Reserved for the rare large overlay (drawer body)  |

For pill / capsule shapes, use `height / 2`. Never magic numbers like
999, 15, or 24.

## Motion

Three tokens cover almost every animation. Use `Theme.dur(ms)` so
reduce-motion zeroes them.

| Token     | Duration | Use                                          |
|-----------|----------|----------------------------------------------|
| `durFast` | 120ms    | Hover color swap, focus ring                 |
| `durBase` | 160ms    | Page nav, tab switch, dialog open            |
| `durSlow` | 220ms    | Drawer slide-in, sheet open                  |

Easing: `Easing.OutCubic` for everything that decelerates into place.
No bounce, no elastic.

Infinite animations (pulse, shimmer) gate on `!Theme.reduceMotion`.

## Pattern principles

These are the rules we hold across the app. A design that breaks one
of these is wrong, not creative.

1. **Surfaces step by lightness, not hue.** Each step (`bg → surface
   → surface2 → surface3`) is brightness only. The 1px hairline
   (`line`) is the strongest divider; beyond that, change the fill.

2. **Rounded, consistent.** 8px containers, 6px buttons. Don't vary.

3. **Flat, not skeuomorphic.** No gradients on surfaces, no embossed
   edges, no drop shadows except for a true overlay (modal backdrop).
   The amber accent itself is a flat fill.

4. **Category color is functional.** Tint the chip. Accent amber is
   orthogonal — it means "active / selected," not "this kind."

5. **Type hierarchy beats visual weight.** Title 20/600, body 14/400,
   mono values 13. These three sizes do most of the work.

6. **Hover is subtle, selection is clear.** Hover raises one surface
   step (`surface → surface2`), no animation, instant. Selection uses
   a 2px accent bar on the left side of source-list rows (the macOS
   Finder / VS Code source-list pattern). Selection on a free-standing
   card uses a 2px accent border + a soft accent wash fill.

7. **Focus rings are 2px accent + 2px offset.** Always visible, never
   removed. Implemented via `FocusRing.qml`.

8. **No drop shadows on canvas cards.** The flow canvas is flat. The
   only shadow allowed is on a true modal backdrop.

9. **Em dashes are banned in user-facing strings.** Use periods or
   parentheses. (`. ` and `( )` not `— `.)

10. **One amber thing per page.** The accent is a scarce resource. If
    you find two competing primaries, one of them must demote.

11. **Empty states teach the interface.** Don't say "nothing here."
    Show what to do next, with the affordance to do it.

12. **Tooltips on every icon-only button.** No exceptions.

## Accessibility

- AA contrast on every text/surface pair. Confirmed across both
  themes for `text`, `text2`, `text3` over `bg`, `surface`,
  `surface2`, `surface3`.
- Full keyboard navigation. Every interactive element is tab-
  reachable, with the focus ring visible.
- Reduce-motion is a real setting (`Theme.reduceMotion`). Every
  duration runs through `Theme.dur()`; infinite animations gate on
  `!Theme.reduceMotion`.
- Qt's font rendering covers subpixel and hinting natively.

## Brand mark

Three concept SVGs live at `docs/branding/`:

- `concept-a-stepped-icon.svg` — straight strokes with descending
  valleys. Currently the recommended primary mark.
- `concept-b-nodes-icon.svg` — step cards connected by wires
  (most literal workflow metaphor).
- `concept-c-flowing-icon.svg` — single curved stroke with a
  direction chevron.

Wordmark variants in the same directory append a "flow" sans-serif
text after the icon, so the whole logo reads "wflow."

Mark color: `accent` (`#e29846`) on a `radiusMd` rounded square,
foreground `accentText` (`#1a1208`).

## Where this lives in the code

Authoritative tokens: `qml/Theme.qml`. Read it directly if there's
ever a question about a number.

Components: `qml/components/`. Each sub-directory groups by surface
(`workflow/`, `library/`, `record/`, `explore/`, `chrome/`).

Pages: `qml/pages/`. One file per top-level destination
(`LibraryPage.qml`, `ExplorePage.qml`, `WorkflowPage.qml`,
`RecordPage.qml`, `SettingsPage.qml`).

App-shell chrome: `qml/components/chrome/ChromeFloating.qml` (the
floating top-center nav pill).
