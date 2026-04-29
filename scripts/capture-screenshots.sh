#!/usr/bin/env bash
# Build wflow and launch it ready for the screenshot capture pass.
#
# This is a thin wrapper. The actual capture is manual via grim /
# gnome-screenshot — automating window screenshots reliably across
# every Wayland compositor isn't worth the flakiness. See
# docs/design/screenshots/README.md for the full capture loop.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building wflow (release) ..."
cargo build --release

echo
echo "wflow built. Launching ..."
echo "When the window is visible, capture with grim or gnome-screenshot:"
echo
echo "  grim -g \"\$(slurp)\" docs/design/screenshots/<name>.<theme>.png"
echo
echo "Theme cycle: Ctrl+. (auto / light / dark). The default is dark."
echo "See docs/design/screenshots/README.md for the manifest."
echo

exec "$ROOT/target/release/wflow" "$@"
