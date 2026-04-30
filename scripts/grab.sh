#!/usr/bin/env bash
# Capture a screenshot of the wflow window into the design baseline.
#
# Usage:
#   scripts/grab.sh <name>          # find wflow's window, capture it
#   scripts/grab.sh <name> -w N     # wait N seconds before capturing
#   scripts/grab.sh <name> -d N     # delay N seconds, capture focused
#   scripts/grab.sh <name> -r       # slurp region select
#
# Examples:
#   scripts/grab.sh library.dark
#   scripts/grab.sh editor-palette.dark -w 3
#   scripts/grab.sh editor-canvas.dark
#   scripts/grab.sh explore-detail.dark -r
#
# The default path doesn't care about focus. It queries Hyprland or
# Sway for wflow's window, raises it (in case another window is on
# top), and grim captures that geometry directly. The terminal you
# launched the script from stays out of frame.
#
# Use -w N to add a pre-capture wait so you can position the cursor
# (hover the step palette, open a menu, etc.) before grim fires.
#
# If the compositor doesn't expose a way to find a window by class
# (e.g. plain GNOME / KDE without wlroots IPC), pass -d N: the script
# waits N seconds while you click on wflow, then captures whichever
# window is focused via the desktop's native tool.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEST_DIR="$ROOT/docs/design/screenshots"

NAME="${1:-}"
shift || true

DELAY=3000
MODE="auto"
WAIT=0

while (( $# )); do
    case "$1" in
        -r|--region)
            MODE="region"
            ;;
        -d|--delay)
            DELAY="${2:-0}"
            MODE="delay"
            shift
            ;;
        -w|--wait)
            WAIT="${2:-0}"
            shift
            ;;
        *)
            echo "unknown flag: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [[ -z "$NAME" ]]; then
    cat <<EOF
usage: $(basename "$0") <name> [-d N | -r]

Captures the wflow window into:
    $DEST_DIR/<name>.png

Default (no flag): finds wflow's window via the compositor (Hyprland
or Sway), raises it, and captures its geometry directly. Works while
the terminal stays focused.

  -w N   Wait N seconds BEFORE capturing. Lets you position the
         cursor inside wflow (hover the step palette, open a menu,
         etc.) so the captured frame includes the hover state.

  -d N   Delay N seconds, then capture whichever window is focused.
         Useful on GNOME / KDE where window-by-class lookup isn't
         exposed cleanly. Click on wflow within N seconds.

  -r     Region select via slurp. Useful when capturing a modal /
         overlay that isn't tracked as a top-level window.

Examples:
    $(basename "$0") library.dark
    $(basename "$0") editor-canvas.dark
    $(basename "$0") editor-palette.dark -w 3
    $(basename "$0") settings.light -d 3
    $(basename "$0") explore-detail.dark -r

The full manifest of names is in
docs/design/screenshots/README.md.
EOF
    exit 1
fi

mkdir -p "$DEST_DIR"
OUT="$DEST_DIR/${NAME}.png"

# Pre-capture wait. Runs before any capture path so it composes with
# auto / region / delay equally well. Exists for the "I want a hover
# state in the frame" case: hit Enter on the script, then move the
# cursor inside wflow before the timer expires.
if (( WAIT > 0 )); then
    echo "Position the cursor inside wflow. Capturing in $WAIT seconds..."
    for ((i=WAIT; i>0; i--)); do
        printf "  %d...\r" "$i"
        sleep 1
    done
    echo
fi

# Region select: bypass all the find-wflow logic.
if [[ "$MODE" == "region" ]]; then
    if ! command -v slurp >/dev/null || ! command -v grim >/dev/null; then
        echo "error: slurp + grim required for -r region select" >&2
        exit 1
    fi
    grim -g "$(slurp)" "$OUT"
    echo "Saved $OUT (region)"
    exit 0
fi

# Delay-then-capture-focused path. Works anywhere a "capture focused"
# tool exists; the user supplies the focus by clicking on wflow.
delay_capture() {
    local n="$1"
    if (( n <= 0 )); then n=3; fi
    echo "Click on the wflow window. Capturing in $n seconds..."
    for ((i=n; i>0; i--)); do
        printf "  %d...\r" "$i"
        sleep 1
    done
    echo

    if command -v gnome-screenshot >/dev/null 2>&1; then
        gnome-screenshot --window --file="$OUT"
        echo "Saved $OUT (gnome-screenshot)"
        return 0
    fi
    if command -v spectacle >/dev/null 2>&1; then
        spectacle --activewindow --background --nonotify --output="$OUT"
        echo "Saved $OUT (spectacle)"
        return 0
    fi
    # wlroots fallback: capture currently-focused via hyprctl/swaymsg.
    if command -v hyprctl >/dev/null 2>&1 && command -v grim >/dev/null 2>&1; then
        local geom
        geom=$(hyprctl -j activewindow 2>/dev/null \
            | jq -r 'select(.at) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' \
            || true)
        if [[ -n "$geom" ]]; then
            grim -g "$geom" "$OUT"
            echo "Saved $OUT (Hyprland active window after delay)"
            return 0
        fi
    fi
    if command -v swaymsg >/dev/null 2>&1 && command -v grim >/dev/null 2>&1; then
        local geom
        geom=$(swaymsg -t get_tree 2>/dev/null \
            | jq -r 'recurse(.nodes[]?, .floating_nodes[]?) | select(.focused == true) | "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"' \
            | head -n 1 \
            || true)
        if [[ -n "$geom" ]]; then
            grim -g "$geom" "$OUT"
            echo "Saved $OUT (Sway focused window after delay)"
            return 0
        fi
    fi
    return 1
}

if [[ "$MODE" == "delay" ]]; then
    if delay_capture "$DELAY"; then exit 0; fi
    echo "error: no focused-window capture tool available" >&2
    exit 1
fi

# ===== Auto: find wflow's window by class and capture it directly. =====

# Hyprland: list clients, filter by class. wflow's app_id under Qt 6
# Wayland comes through as the executable basename ("wflow") on most
# setups; we also accept the reverse-DNS form just in case.
if command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1; then
    if ! command -v grim >/dev/null 2>&1; then
        echo "error: grim required for Hyprland window capture" >&2
        exit 1
    fi
    WFLOW=$(hyprctl -j clients 2>/dev/null \
        | jq -c '.[] | select(.class == "wflow" or .class == "Wflow" or .class == "io.github.cushycush.wflow")' \
        | head -n 1 \
        || true)
    if [[ -n "$WFLOW" ]]; then
        ADDR=$(echo "$WFLOW" | jq -r '.address')
        GEOM=$(echo "$WFLOW" | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')
        # Raise wflow so any overlapping window above it gets out of
        # the way before we capture. Brief sleep lets the compositor
        # finish reordering before grim reads pixels.
        hyprctl dispatch focuswindow "address:$ADDR" >/dev/null
        sleep 0.25
        grim -g "$GEOM" "$OUT"
        echo "Saved $OUT (Hyprland: wflow window)"
        exit 0
    fi
    echo "error: wflow not found in Hyprland's client list. Is the app running?" >&2
    echo "       try: cargo run  &  ; ./scripts/grab.sh $NAME" >&2
    exit 1
fi

# Sway / wayfire: same idea via the i3-style tree.
if command -v swaymsg >/dev/null 2>&1; then
    if ! command -v grim >/dev/null 2>&1; then
        echo "error: grim required for Sway window capture" >&2
        exit 1
    fi
    WFLOW=$(swaymsg -t get_tree 2>/dev/null \
        | jq -c '.. | objects | select((.app_id? // "") == "wflow" or (.app_id? // "") == "io.github.cushycush.wflow" or (.window_properties?.class? // "") == "wflow")' \
        | head -n 1 \
        || true)
    if [[ -n "$WFLOW" ]]; then
        CON_ID=$(echo "$WFLOW" | jq -r '.id')
        GEOM=$(echo "$WFLOW" | jq -r '"\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"')
        swaymsg "[con_id=$CON_ID] focus" >/dev/null
        sleep 0.25
        grim -g "$GEOM" "$OUT"
        echo "Saved $OUT (Sway: wflow window)"
        exit 0
    fi
    echo "error: wflow not found in Sway's tree. Is the app running?" >&2
    exit 1
fi

# No wlroots IPC available. Hand off to delay path.
echo "Compositor doesn't expose a window-by-class lookup."
echo "Falling back to delay-then-focused mode (3s)."
echo
if delay_capture 3; then exit 0; fi
echo "error: no focused-window capture tool available." >&2
echo "       install one of: hyprctl + grim, swaymsg + grim," >&2
echo "       gnome-screenshot, spectacle" >&2
exit 1
