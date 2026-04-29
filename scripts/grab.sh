#!/usr/bin/env bash
# Capture a screenshot of the focused window into the design baseline.
#
# Usage:
#   scripts/grab.sh <name>       # captures the focused window
#   scripts/grab.sh <name> -r    # falls back to a slurp region select
#
# Examples:
#   scripts/grab.sh library.dark
#   scripts/grab.sh editor-canvas.dark
#   scripts/grab.sh settings.light -r
#
# Resolves the output path under docs/design/screenshots/ relative to
# the repo root so you can run this from any subdirectory.
#
# Compositor handling: tries hyprctl, swaymsg, then falls back to
# whichever full-window tool the desktop ships (gnome-screenshot,
# spectacle). On wlroots compositors the geometry is piped into grim;
# on GNOME / KDE the native tool writes the file directly.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEST_DIR="$ROOT/docs/design/screenshots"

NAME="${1:-}"
MODE="${2:-window}"

if [[ -z "$NAME" ]]; then
    cat <<EOF
usage: $(basename "$0") <name> [-r]

Captures the focused window into:
    $DEST_DIR/<name>.png

Pass -r to fall back to slurp region selection (useful when a
modal / overlay isn't the topmost focused window).

Examples:
    $(basename "$0") library.dark
    $(basename "$0") editor-canvas.dark
    $(basename "$0") explore-detail.dark -r

The full manifest of names is in
docs/design/screenshots/README.md.
EOF
    exit 1
fi

mkdir -p "$DEST_DIR"
OUT="$DEST_DIR/${NAME}.png"

# Region-select fallback path: bypass all compositor sniffing.
if [[ "$MODE" == "-r" ]]; then
    if ! command -v slurp >/dev/null || ! command -v grim >/dev/null; then
        echo "error: slurp + grim required for -r region select" >&2
        exit 1
    fi
    grim -g "$(slurp)" "$OUT"
    echo "Saved $OUT (region)"
    exit 0
fi

# Hyprland: read the active window's geometry, hand it to grim.
if command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1; then
    GEOM=$(hyprctl -j activewindow 2>/dev/null \
        | jq -r 'select(.at) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' \
        || true)
    if [[ -n "$GEOM" ]]; then
        grim -g "$GEOM" "$OUT"
        echo "Saved $OUT (Hyprland active window)"
        exit 0
    fi
fi

# Sway / wayfire: same idea via the i3-style IPC tree.
if command -v swaymsg >/dev/null 2>&1; then
    GEOM=$(swaymsg -t get_tree 2>/dev/null \
        | jq -r 'recurse(.nodes[]?, .floating_nodes[]?) | select(.focused == true) | "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"' \
        | head -n 1 \
        || true)
    if [[ -n "$GEOM" ]]; then
        grim -g "$GEOM" "$OUT"
        echo "Saved $OUT (Sway focused window)"
        exit 0
    fi
fi

# GNOME native tool. Doesn't go through grim.
if command -v gnome-screenshot >/dev/null 2>&1; then
    gnome-screenshot --window --file="$OUT"
    echo "Saved $OUT (gnome-screenshot)"
    exit 0
fi

# KDE Plasma 6 / Spectacle. Background mode = no UI, no notification.
if command -v spectacle >/dev/null 2>&1; then
    spectacle --activewindow --background --nonotify --output="$OUT"
    echo "Saved $OUT (spectacle)"
    exit 0
fi

echo "error: no supported window-capture tool found." >&2
echo "       install one of: hyprctl + grim, swaymsg + grim," >&2
echo "       gnome-screenshot, spectacle" >&2
echo "       or pass -r to use slurp region select." >&2
exit 1
