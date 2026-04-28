#!/usr/bin/env bash
# Push wflow + wflow-bin + wflow-git PKGBUILDs to the AUR.
#
# Normally this runs automatically via .github/workflows/aur-publish.yml
# on every published GitHub release. Use this script for manual
# republishes when the workflow is unavailable.
#
# Run from the repo root. Requires:
#   - AUR account + SSH key registered at aur.archlinux.org
#   - ~/.ssh/config Host aur.archlinux.org with IdentityFile pointing at it
#   - makepkg, pacman-contrib (for updpkgsums), git
#
# AUR was DDoS'd at the time this was written (2026-04-25). Run this when
# `ssh -T aur@aur.archlinux.org` succeeds.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORK="$(mktemp -d -t wflow-aur-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Verifying AUR connectivity"
# AUR refuses interactive shells, so `ssh -T` always exits 1 even on
# successful auth. The reliable signal is the "Welcome to AUR" banner.
# Capture the output (with `|| true` to defang ssh's nonzero exit
# inside `set -euo pipefail`) and pattern-match — no pipeline involved,
# so pipefail doesn't fire on the ssh side.
ssh_output=$(ssh -T -o ConnectTimeout=10 aur@aur.archlinux.org 2>&1 || true)
case "$ssh_output" in
    *"Welcome to AUR"*)
        echo "    AUR auth ok."
        ;;
    *)
        echo "AUR SSH unreachable or auth failed. Try again later (https://status.archlinux.org)."
        echo "ssh output was:"
        printf '%s\n' "$ssh_output" | sed 's/^/    /'
        exit 1
        ;;
esac

PKGVER=$(grep -m1 '^pkgver=' "$REPO_ROOT/packaging/aur/wflow/PKGBUILD" | cut -d= -f2)
echo "==> Pushing wflow $PKGVER (release variant)"
git clone "ssh://aur@aur.archlinux.org/wflow.git" "$WORK/wflow"
cp "$REPO_ROOT/packaging/aur/wflow/PKGBUILD" "$WORK/wflow/"
(
    cd "$WORK/wflow"
    # AUR's update hook rejects every branch except master. Recent
    # git defaults to `main` (or whatever init.defaultBranch is set
    # to), so force master before any commit happens.
    git symbolic-ref HEAD refs/heads/master
    updpkgsums
    makepkg --printsrcinfo > .SRCINFO
    git add PKGBUILD .SRCINFO
    if git diff --cached --quiet; then
        echo "    no changes — skipping commit"
    else
        git commit -m "wflow $PKGVER"
        git push origin master
    fi
)

echo "==> Pushing wflow-bin $PKGVER (prebuilt-binary variant)"
git clone "ssh://aur@aur.archlinux.org/wflow-bin.git" "$WORK/wflow-bin"
cp "$REPO_ROOT/packaging/aur/wflow-bin/PKGBUILD" "$WORK/wflow-bin/"
(
    cd "$WORK/wflow-bin"
    git symbolic-ref HEAD refs/heads/master
    # wflow-bin uses sha256sums=('SKIP') for the binary tarball
    # since GitHub releases are HTTPS-trusted; updpkgsums would
    # try to compute hashes for sources we deliberately skip.
    makepkg --printsrcinfo > .SRCINFO
    git add PKGBUILD .SRCINFO
    if git diff --cached --quiet; then
        echo "    no changes — skipping commit"
    else
        git commit -m "wflow-bin $PKGVER"
        git push origin master
    fi
)

echo "==> Pushing wflow-git (VCS variant)"
git clone "ssh://aur@aur.archlinux.org/wflow-git.git" "$WORK/wflow-git"
cp "$REPO_ROOT/packaging/aur/wflow-git/PKGBUILD" "$WORK/wflow-git/"
(
    cd "$WORK/wflow-git"
    # See note above — force master.
    git symbolic-ref HEAD refs/heads/master
    # wflow-git uses sha256sums=('SKIP') — no updpkgsums needed.
    makepkg --printsrcinfo > .SRCINFO
    git add PKGBUILD .SRCINFO
    if git diff --cached --quiet; then
        echo "    no changes — skipping commit"
    else
        git commit -m "wflow-git $PKGVER snapshot"
        git push origin master
    fi
)

echo "==> Done. View at:"
echo "      https://aur.archlinux.org/packages/wflow"
echo "      https://aur.archlinux.org/packages/wflow-bin"
echo "      https://aur.archlinux.org/packages/wflow-git"
