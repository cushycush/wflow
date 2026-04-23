# wflow pricing

Working strategy doc. Phased rollout. Trust before revenue.

## Guiding principles

1. **Local is always free.** Running your own workflows, offline editing,
   file access, `.kdl` export never cost money.
2. **`.kdl` stays open and portable forever.** Write this into the README
   and hold the line.
3. **Browsing + importing community workflows never requires an account.**
   That is the value magnet. Gate only the *writing* side (submit, rate,
   comment, follow) behind auth.
4. **Revenue secondary at launch.** First objective is install base and
   contribution flywheel. Revenue layers on afterward.

## Phase 1 — launch → ~6 months

### Free forever

- Local creation / editing / running
- Record Mode
- Browsing + importing community workflows (Explore tab)
- Submitting / rating / discussing on the web

### wflow Supporter — $49 one-time

- No features gated
- Cosmetic "early supporter" badge on the web
- Signal: pay to fund development, not to unlock the product
- Reference: iA Writer, Sublime Text, old-school 1Password

**Goal for Phase 1:** maximize install base and contributions. Revenue is
secondary; community trust is the asset we're building.

## Phase 2 — ~6-12 months: wflow Cloud

### wflow Cloud — $4 / month, or $40 / year

- End-to-end encrypted library sync across devices
- Secrets vault (API keys, paths, tokens) encrypted at rest
- Activity history

Benchmark: Obsidian Sync is $5/mo for a comparable audience.

## Phase 3 — 12-24 months: Pro & Teams

### wflow Pro — $9 / month, or $90 / year (includes Cloud)

- Scheduled workflows (cron-style triggers)
- Webhook triggers (incoming HTTP starts a workflow)
- Conditional logic / branches
- Loop / iteration actions
- AI: "describe what you want, get a draft workflow" (likely BYOK)

### wflow Teams — $7 / user / month

- Shared team library
- Approval + audit log
- SSO (later)

Benchmarks: Raycast Pro $8/mo; Linear Standard $8/user/mo.

## Trust anchors — never touch

- Running your own workflows
- Offline editing and local file access
- `.kdl` file format open and portable, forever
- Explore browsing and 1-click import
- No workflow count / storage limits on the user's own machine

## Anti-patterns to avoid

- Storage or workflow-count quotas on local files
- "Trial expired → read-only" lockouts
- Marketplace take-rate as primary revenue (invites gaming and moderation debt)
- Auth wall on Explore or Import
- Sponsored / promoted workflows injected into the user's Library

## Strategic lever: open-source the engine

The crate split (`wflow-engine` UI-agnostic, bridge layer separate) already
sets this up.

- Release `wflow-engine` under MIT or GPL
- Keep the paid Cloud service proprietary
- Competitors can't out-flank with an "ours is open" pitch
- The hacker audience trusts it; nobody expects free cloud hosting

Reference: Sentry, Supabase, Obsidian.

## Contribution-for-credit lever

Tie the social flywheel to the paid tier without cash changing hands:

> Your community workflow hit 100 imports → 1 month of Cloud on us.

Rewards the power contributors who are driving the flywheel, and makes for
a great launch narrative.

## Open questions

- **AI inference cost (Phase 3).** Either eat the cost and price for it,
  or BYOK (bring your own API key). BYOK is significantly more trusted by
  this audience. Raycast moved to BYOK for their Pro AI. Lean BYOK.
- **Annual vs monthly default.** Default to annual with "2 months free"
  framing. Standard SaaS pattern.
- **Student / FOSS-dev discount.** Costs nothing in goodwill, pays back in
  advocacy. Recommended once there's any paid tier.
- **Lifetime license.** Good launch buzz (Supporter is close to this), but
  hurts margins long term. Keep Supporter one-time-no-feature-gates rather
  than promising perpetual feature access.
