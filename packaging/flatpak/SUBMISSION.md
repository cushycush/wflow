# Flathub submission

Step-by-step for getting wflow on Flathub. Written for someone
running through this on a host with Flatpak installed.

## Before you start

You need:

- A Flatpak-capable host (any Linux desktop with `flatpak` and
  `flatpak-builder` installed). Hyprland counts.
- A GitHub account (for the fork + PR).
- The Flathub runtimes installed on the host:
  ```sh
  flatpak remote-add --if-not-exists --user flathub \
      https://flathub.org/repo/flathub.flatpakrepo
  flatpak install --user flathub \
      org.kde.Platform//6.9 org.kde.Sdk//6.9 \
      org.freedesktop.Sdk.Extension.rust-stable//25.08
  ```

## Step 1: build the Flathub manifest locally

The repo ships two manifest variants. `io.github.cushycush.wflow.yaml`
is the local-dev one (sources from a `dir` pointing at the working
tree). `io.github.cushycush.wflow.flathub.yaml` is the submission
one (sources from a `git` tag, with a pinned commit SHA).

Build the Flathub variant first to make sure it works the same way
Flathub's CI will see it:

```sh
./packaging/flatpak/build-local.sh --flathub
```

This regenerates `cargo-sources.json` against the current
`Cargo.lock`, then drives flatpak-builder against the Flathub
manifest. The build clones the wflow repo at the pinned tag, so
make sure the tag exists on `origin/main` (it does after `./packaging/aur/push.sh`
ran for that release).

After it finishes:

```sh
flatpak run io.github.cushycush.wflow
```

Should bring up the GUI. Run a workflow with the `shell` action to
confirm host-spawn still works inside the sandbox. Click ● Record
to confirm the portal handshake actually fires (or, on
Hyprland/Sway, that the "Record can't start" error message renders
gracefully. That's the expected behavior since the compositor's
portal doesn't ship RemoteDesktop).

## Step 2: prepare the Flathub PR branch

Fork `github.com/flathub/flathub` to your account. Then locally:

```sh
git clone https://github.com/<you>/flathub.git
cd flathub
git checkout -b io.github.cushycush.wflow
```

Copy the manifest and cargo-sources.json into the branch root,
renaming the manifest:

```sh
cp /path/to/wflow/packaging/flatpak/io.github.cushycush.wflow.flathub.yaml \
   ./io.github.cushycush.wflow.yaml
cp /path/to/wflow/packaging/flatpak/cargo-sources.json ./
```

Commit and push to your fork:

```sh
git add io.github.cushycush.wflow.yaml cargo-sources.json
git commit -m "Add io.github.cushycush.wflow"
git push -u origin io.github.cushycush.wflow
```

## Step 3: open the PR

Open a PR from your `io.github.cushycush.wflow` branch against the
`new-pr` branch on `flathub/flathub` (NOT `master`). PR title should
be the app id.

PR description should cover:

- One-line product pitch ("Shortcuts for Linux: GUI + KDL workflow files").
- Why the app needs `--talk-name=org.freedesktop.Flatpak`. Workflows ARE
  host commands; an automation tool that can't drive the user's
  session is a viewer, not a runner. Notify and input go through
  proper portals (Notification, RemoteDesktop). Only Shell and
  Clipboard host-spawn. REVIEW.md at
  https://github.com/cushycush/wflow/blob/main/REVIEW.md has the
  threat model.
- Precedents that ship the same permission: VS Code
  (`com.visualstudio.code`), GNOME Builder (`org.gnome.Builder`),
  GNOME Boxes (`org.gnome.Boxes`).

## Step 4: respond to the bot

Flathub-bot validates the manifest, runs flatpak-builder in CI,
launches the app inside a virtual display, and posts the build log
as a comment. If anything fails:

- AppStream validation: usually a missing screenshot URL or a
  category typo. Edit the metainfo file in the wflow repo, push a
  fix release, bump the manifest's `tag:` and `commit:`.
- Cargo offline build: `cargo-sources.json` is out of sync with
  `Cargo.lock`. Re-run `./packaging/flatpak/build-local.sh --flathub`
  in the wflow repo, copy the regenerated `cargo-sources.json`
  into the Flathub PR branch, force-push.
- Runtime crash: usually a missing finish-arg. Add to the manifest,
  push.

Iterate until the bot is green.

## Step 5: respond to the reviewer

A human reviewer will go through a checklist. Common questions for
host-spawn apps:

- "Why do you need this permission?" Point at the PR description
  and REVIEW.md. Cite the precedents.
- "Can you narrow the surface?" We already did: notifications go
  through the Notification portal, input goes through the libei
  RemoteDesktop portal, only shell + clipboard host-spawn. The
  remaining surface IS the user-facing feature.
- "Why isn't `--filesystem=home` enough?" `--talk-name=org.freedesktop.Flatpak`
  is for executing host commands, not reading files. Different
  capability.

Be patient. Review takes weeks not days for apps with this
permission set. The first response from a reviewer is often 2-3
weeks after PR open.

## Step 6: after merge

Flathub creates `github.com/flathub/io.github.cushycush.wflow`
automatically and gives you push access. From then on, every
release is a PR there:

1. Tag the wflow release (e.g., `v0.4.0`).
2. Bump the manifest's `tag:` and `commit:` in
   `io.github.cushycush.wflow.flathub.yaml` in this repo.
3. Bump `<release>` in `metainfo.xml`.
4. Run `./packaging/flatpak/build-local.sh --flathub` to regenerate
   `cargo-sources.json`.
5. Copy the manifest + cargo-sources.json into your local clone of
   `flathub/io.github.cushycush.wflow`.
6. Open a PR there. Bot builds, reviewer (often a different one)
   approves quickly since the app is already trusted.

This should be a 10-minute exercise per release.

## Common gotchas

- The `cargo-sources.json` MUST be regenerated for every release.
  Stale sources fail the offline build with cryptic "checksum
  mismatch" errors.
- `commit:` must point at a real SHA on the tagged commit. If you
  bump the tag but forget the SHA, the build is technically
  unreproducible and reviewers will catch it.
- The Flathub PR branch name must match the app id exactly
  (`io.github.cushycush.wflow`).
- PR target is `new-pr` branch, NOT `master`. Forgetting this is
  the most common first-time mistake.
