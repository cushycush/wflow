# wflow design brief

What we want Claude Design (or any designer) to produce. Read alongside
`design-system.md` and `component-inventory.md` so the visual language
is grounded.

## The two products

1. **wflow desktop** (this repo, Qt 6 + cxx-qt + Rust + QML). The
   design language exists here and is the authoritative source.
2. **wflows.com** (Next.js, Drizzle, Postgres, Better Auth). The
   public catalog. Currently has a lighter, more raw treatment that
   should be reworked to match the desktop's visual language.

Both share one identity. The desktop drives; the website follows.

## What we want designed, ordered by priority

### Priority 1: wflows.com landing page

The single most important surface. Today's homepage is sparse and
under-positioned. Goals:

- **Hero**: a single-sentence value statement plus one short
  paragraph plus a primary CTA. The value statement should be exactly
  what the desktop's Library page describes the product as: "wflow
  runs sequences of keystrokes, clicks, shell commands, and waits.
  Shortcuts for Linux, with a plain-text workflow file underneath."
- **Hero visual**: a faux desktop screenshot of the wflow editor with
  a simple workflow visible. Don't render an illustrated computer
  frame; just the app surface, styled per the design system.
- **Live library stats**: three numbers across (workflows, authors,
  installs this week). Clean mono numbers, small caps labels above.
  Already present in the SSR query; just needs a real visual.
- **Featured row**: the editorial picks (up to 6 cards). Match the
  desktop's `CommunityCard` treatment — same hover step, same shell
  pip, same mini-stack preview.
- **What is a workflow** explainer: 3 short rows with a category
  glyph + a phrase, all left-aligned. Not a feature grid.
- **Footer**: links, GitHub, AUR, donation. Quiet.

Theme: dark default, light fallback. Mirror the desktop's surfaces.

### Priority 2: wflows.com browse + workflow detail pages

**Browse page** is the search + filter + grid. Today's renders the
data correctly but the design is the SSR placeholder. Wants:

- A clean search field at the top that matches `ExploreSearch`.
- Filter chips (sort, tag, trigger kind) styled like `CategoryPills`.
- The grid uses cards visually identical to `CommunityCard` from the
  desktop. Same proportions, same metadata layout.
- Pagination is offset-based; show "Load more" as a quiet
  `SecondaryButton` at the bottom of the grid.

**Workflow detail page** (`/:handle/:slug`) is where someone lands
from a search or shared link. Wants:

- Title + author byline at the top, with a primary "Open in wflow"
  button (deeplink) and a secondary "Download .kdl" button.
- Trigger summary (chord / hotstring) as a colored chip.
- Step preview, parsed from the KDL: each step renders as a
  `MiniStep`-style row with category chip + value. This is the
  emotional core of the page — the user wants to see what the
  workflow does, fast.
- A "Show source" disclosure that reveals the raw KDL in a `Geist
  Mono` block.
- Comments section below (read-only for v1).
- Sidebar (or footer on narrow): author profile snippet (avatar,
  handle, bio, supporter badge if present), and "more from this
  author."

### Priority 3: wflows.com profile + publish + auth

**Profile page** (`/:handle`): avatar at top, bio, supporter badge,
grid of the author's public workflows. Quiet.

**Publish page**: a form. Title, description, KDL paste area, tag
input, visibility radio (draft / public / unlisted). Big "Publish"
primary button at the bottom. Uses the desktop's TextField visual
(framed, surface2 fill, accent border on focus).

**Sign-in page**: minimal. Magic-link via Resend, plus GitHub /
Discord OAuth buttons. One column, centered. Don't add hero copy or
feature lists; the user already knows what they're signing into.

### Priority 4: pricing page

Today there's no pricing page. The product split is:

- **Free** (always): publish, install, remix, browse, search, hotkey
  trigger sync, comments.
- **Supporter** ($19 one-time, my recommended price): cosmetic
  unlocks — cover image, profile accent, Discord linked role,
  supporter wall listing. Cosmetic only.
- **Founding Supporter** ($49 one-time, capped at first 100): all of
  Supporter, plus a "Founding" badge that's no longer purchasable
  after the cap. Scarcity does the work.
- **Pro** ($5–8/month, future): cloud sync, run-history dashboard,
  private workflows.

Page wants three columns (Supporter, Founding, Pro) with a "Free"
card that sits BEFORE the columns as a small reminder banner. No
recurring/annual toggle (we're not there yet). Honest copy: don't
oversell what's cosmetic vs functional.

### Priority 5: desktop polish

Smaller asks for the desktop, once the brand-mark direction is
locked:

- Replace the current placeholder amber-square logo (a plain `w` on
  amber) with the chosen brand mark from `docs/branding/`. Update
  it in `qml/components/chrome/ChromeFloating.qml` and the favicon.
- Light-mode pass on the editor canvas. Today the dark canvas is
  fully tuned; light-mode card colors and wire ink need a visual
  pass to match.
- Sign-in flow on the desktop side, once the website auth API
  exists. One-screen surface; "open browser to sign in" + a textbox
  to paste the token back.

## Out of scope for this round

- Marketing illustrations (Claude Design isn't great at pure art).
- The actual workflow execution UI — already shipped, don't redesign.
- Mobile / responsive web. The desktop app is desktop-only and the
  website's primary device is also desktop. Mobile-readable is fine;
  mobile-optimized is not the priority.

## Constraints to respect

- Stay inside the palette and type scale in `design-system.md`. Don't
  introduce new tokens.
- No drop shadows on cards. No gradient text. No side-stripe accent
  borders on list items. (Listed as anti-references in the design
  system.)
- Em dashes are banned in any user-facing string. Use periods or
  parentheses.
- One amber thing per page. The accent is scarce.
- Hanken Grotesk for body, Geist Mono for technical values. Banned
  fonts (the AI-design-tell list) listed in the design system.

## Output format

Per page or per surface, produce:

1. A high-fidelity mockup at desktop width (1440 wide).
2. A narrow-width mockup at 768px so we can see the responsive
   behavior. (Mobile-readable, not mobile-optimized.)
3. Component-level details if a NEW component is invented (i.e.
   something not yet in `component-inventory.md`).

Export targets: PNG mockups + Tailwind / CSS variable suggestions for
the website handoff. The Tailwind side should mirror the
`design-system.md` tokens 1:1 — same names, same values.
