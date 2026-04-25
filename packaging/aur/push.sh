#!/usr/bin/env bash
# Push wflow + wflow-git PKGBUILDs to the AUR.
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
ssh -T -o ConnectTimeout=10 aur@aur.archlinux.org 2>&1 | head -1 || {
    echo "AUR SSH unreachable. Try again later (https://status.archlinux.org)."
    exit 1
}

PKGVER=$(grep -m1 '^pkgver=' "$REPO_ROOT/packaging/aur/wflow/PKGBUILD" | cut -d= -f2)
echo "==> Pushing wflow $PKGVER (release variant)"
git clone "ssh://aur@aur.archlinux.org/wflow.git" "$WORK/wflow"
cp "$REPO_ROOT/packaging/aur/wflow/PKGBUILD" "$WORK/wflow/"
(
    cd "$WORK/wflow"
    updpkgsums
    makepkg --printsrcinfo > .SRCINFO
    git add PKGBUILD .SRCINFO
    if git diff --cached --quiet; then
        echo "    no changes — skipping commit"
    else
        git commit -m "wflow $PKGVER"
        git push
    fi
)

echo "==> Pushing wflow-git (VCS variant)"
git clone "ssh://aur@aur.archlinux.org/wflow-git.git" "$WORK/wflow-git"
cp "$REPO_ROOT/packaging/aur/wflow-git/PKGBUILD" "$WORK/wflow-git/"
(
    cd "$WORK/wflow-git"
    # wflow-git uses sha256sums=('SKIP') — no updpkgsums needed
    makepkg --printsrcinfo > .SRCINFO
    git add PKGBUILD .SRCINFO
    if git diff --cached --quiet; then
        echo "    no changes — skipping commit"
    else
        git commit -m "wflow-git $PKGVER snapshot"
        git push
    fi
)

echo "==> Done. View at:"
echo "      https://aur.archlinux.org/packages/wflow"
echo "      https://aur.archlinux.org/packages/wflow-git"
