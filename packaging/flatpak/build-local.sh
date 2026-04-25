#!/usr/bin/env bash
# Build the wflow Flatpak from a local checkout for testing.
#
# Prerequisites (install once):
#   sudo pacman -S flatpak flatpak-builder       # Arch
#   sudo apt install flatpak flatpak-builder     # Debian/Ubuntu
#   sudo dnf install flatpak flatpak-builder     # Fedora
#
#   flatpak remote-add --if-not-exists --user flathub \
#       https://flathub.org/repo/flathub.flatpakrepo
#   flatpak install --user flathub \
#       org.kde.Platform//6.9 org.kde.Sdk//6.9 \
#       org.freedesktop.Sdk.Extension.rust-stable//25.08
#
# Then from the repo root:
#   ./packaging/flatpak/build-local.sh
#   flatpak run io.github.cushycush.wflow

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PACK_DIR="$REPO_ROOT/packaging/flatpak"
MANIFEST="$PACK_DIR/io.github.cushycush.wflow.yaml"
BUILD_DIR="$REPO_ROOT/target/flatpak-build"
STATE_DIR="$REPO_ROOT/target/flatpak-state"

# Step 1: regenerate cargo-sources.json from the current Cargo.lock.
# flatpak-cargo-generator lives in the flatpak-builder-tools repo as a
# single Python file. It needs aiohttp + toml at runtime, so we keep a
# self-contained venv under target/ to avoid system pip / sudo /
# --break-system-packages contortions.
GEN_SCRIPT="$PACK_DIR/flatpak-cargo-generator.py"
GEN_VENV="$REPO_ROOT/target/cargo-gen-venv"

if [ ! -f "$GEN_SCRIPT" ]; then
    echo "==> Fetching flatpak-cargo-generator.py"
    curl -fsSL -o "$GEN_SCRIPT" \
        https://raw.githubusercontent.com/flatpak/flatpak-builder-tools/master/cargo/flatpak-cargo-generator.py
fi

if [ ! -x "$GEN_VENV/bin/python" ]; then
    echo "==> Creating venv for flatpak-cargo-generator dependencies"
    python3 -m venv "$GEN_VENV"
    "$GEN_VENV/bin/pip" install --quiet aiohttp tomlkit
fi

echo "==> Generating cargo-sources.json from Cargo.lock"
"$GEN_VENV/bin/python" "$GEN_SCRIPT" Cargo.lock -o "$PACK_DIR/cargo-sources.json"

# Step 2: run flatpak-builder. --user installs into the per-user
# repo without needing sudo. --install builds and installs in one
# step so `flatpak run` immediately works.
echo "==> Building Flatpak"
flatpak-builder \
    --user \
    --force-clean \
    --state-dir="$STATE_DIR" \
    --install \
    --install-deps-from=flathub \
    "$BUILD_DIR" \
    "$MANIFEST"

echo "==> Done. Run with:"
echo "      flatpak run io.github.cushycush.wflow"
echo
echo "==> Verify host-spawn works (workflows actually run on host):"
echo "      flatpak run io.github.cushycush.wflow run examples/loop-tab-thru.kdl --explain"
