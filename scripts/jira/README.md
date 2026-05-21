# wflow Jira

Project tracking for wflow lives in Jira (WFLOW project at
cushycush.atlassian.net), alongside the DRIFT project. Shared
credentials file, same three-tier model, lifted from drift's
tooling at `~/projects/drift/scripts/jira/`.

## The model

Three tiers (drift uses the same shape):

- **Epic** is a long-running area of work. Eight of them today:
  Engine, Editor, Daemon, Catalog & Explore, CLI & tooling,
  Brand & design, Commercial, Drift integration.
- **Task** (umbrella) groups related leaves under an epic. The
  Engine epic has Actions, Engine runner, KDL serialization,
  Recorder, Trust & sandbox. Most day-to-day comments and status
  changes land on these.
- **Subtask** is a leaf parented to a Task. "Drop a .kdl on the
  canvas" is a Subtask under "KDL clipboard". This is where
  individual commits and PRs link.

Note: drift's project uses "Story" for the middle tier; WFLOW
uses "Task" because its template ships Task / Subtask, not Story
/ Sub-task. The seeder reads the Issue Type column from the CSV
and respects whichever name is there.

## Credentials

One file shared with drift, at `~/.config/jira/env` (chmod 600):

```
JIRA_DOMAIN=cushycush.atlassian.net
JIRA_EMAIL=cushing.matt@gmail.com
JIRA_TOKEN=<api-token-from-id.atlassian.com>
```

Drift's old path (`~/.config/drift/jira.env`) is a symlink to the
canonical file, so drift's tooling keeps working. The wflow
seeder also falls back to drift's path if the canonical one is
missing, so a machine without the symlink still works.

## Day-to-day commands

```
scripts/jira/seed.py ping                       verify the token reaches Jira
scripts/jira/seed.py projects                   list visible projects (sanity: WFLOW + DRIFT)
scripts/jira/seed.py lookup <path>              path to WFLOW-XX via area-map.json
scripts/jira/seed.py start WFLOW-XX --comment "..."   transition to In Progress
scripts/jira/seed.py done  WFLOW-XX --comment "..."   transition to Done
scripts/jira/seed.py move  WFLOW-XX --to "In Review"  any other status
scripts/jira/seed.py comment WFLOW-XX "..."     post a comment
scripts/jira/seed.py import-csv --project WFLOW idempotent bulk-create from issues.csv
scripts/jira/seed.py transitions --project WFLOW push the CSV's Status column
scripts/jira/seed.py sync --project WFLOW       push description / priority / labels updates
```

## The agent-facing loop

The same loop drift uses, restated for wflow:

1. **Find the ticket before you start.** `scripts/jira/seed.py
   lookup <path>` against the file you're about to touch. First
   match in `scripts/jira/area-map.json` wins; if multiple match,
   pick the most specific.
2. **Transition to In Progress when work starts.** `seed.py start
   WFLOW-XX --comment "what you're about to do"`.
3. **Comment as you go.** When something ships, when scope
   changes, when a follow-up surfaces, post a note via `seed.py
   comment WFLOW-XX "..."`.
4. **Transition to Done when the leaf is finished.** `seed.py
   done WFLOW-XX --comment "shipped in <commit>"`. Don't move
   umbrella Tasks to Done until every Subtask under them closes.
5. **Commit trailers carry the key.** `Refs: WFLOW-XX` or
   `Closes: WFLOW-XX` as a trailer on each commit. The hook at
   `scripts/git-hooks/post-commit-jira` posts the commit subject
   as a comment on the referenced ticket on commit, and
   transitions `Closes:` tickets to Done. Cross-project trailers
   (`Refs: DRIFT-72`) also land on the right ticket without
   needing two lines.

## One-time setup on a new machine

```
mkdir -p ~/.config/jira && chmod 700 ~/.config/jira
# paste the three KEY=VALUE lines into ~/.config/jira/env with your editor
chmod 600 ~/.config/jira/env

cd ~/projects/wflow && bash scripts/git-hooks/install.sh
```

## Labels

Labels carry metadata that doesn't fit a standard Jira field:

- `area:engine`, `area:editor`, `area:daemon`, `area:catalog`,
  `area:cli`, `area:brand`, `area:commercial`, `area:drift`.
- `tier:free`, `tier:plus`, `tier:infra` matching the v1.0 vs Pro
  vs foundation split.
- `effort:S`, `effort:M`, `effort:L`, `effort:XL` on sub-tasks.
- `status:shipped`, `status:scoped`, `status:idea`, `status:blocked`,
  `status:deferred` carry the finer-grained roadmap state on top
  of Jira's three-state workflow (To Do / In Progress / Done).

## The CSV

`issues.csv` is the source of truth for the initial seed. Format:

```
Work item ID,Issue Type,Summary,Parent,Priority,Status,Labels,Description
```

`Work item ID` is a stable id within the file, used by `Parent`
to resolve hierarchy in one pass. Re-running `import-csv` is
idempotent on Summary; re-running `transitions` is idempotent on
target status; re-running `sync` only pushes changed fields.

After the seed lands, individual tickets can be added either via
the Jira UI or by appending new rows and re-running `import-csv`
(rows whose Summary already exists in Jira get skipped).
