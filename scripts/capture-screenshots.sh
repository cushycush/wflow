#!/usr/bin/env bash
# Capture the full design-docs screenshot baseline in one pass.
#
# For each surface this script:
#   1. Prompts you to set up the UI state
#   2. Captures <surface>.dark.png
#   3. Flips theme to light via Ctrl+. (sent through wtype)
#   4. Captures <surface>.light.png
#   5. Flips theme back to dark
#
# Output lands in docs/design/screenshots/ matching the manifest at
# docs/design/screenshots/README.md. Skip a surface by pressing 'n'
# at the prompt; capture all of it by pressing Enter.
#
# Requires: cargo, grim, jq, wtype, and a Hyprland or Sway session.
# Explore captures are skipped when Theme.showExplore is false (the
# 0.4.0 default). Re-enable the flag in qml/Theme.qml + rebuild if
# you want them.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

BIN="$ROOT/target/debug/wflow"
LOG="/tmp/wflow-shoot.log"
DEST="$ROOT/docs/design/screenshots"
mkdir -p "$DEST"

# ---- Tool checks ----
need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: $1 not on PATH" >&2
        echo "       this script needs grim, slurp, jq, wtype" >&2
        exit 1
    fi
}
need grim
need jq
need wtype
if ! { command -v hyprctl >/dev/null || command -v swaymsg >/dev/null; }; then
    echo "error: needs Hyprland or Sway for window-by-class lookup" >&2
    exit 1
fi

# ---- Build + launch ----
if [[ ! -x "$BIN" ]]; then
    echo "→ building debug binary..."
    cargo build
fi
pkill -f "target/debug/wflow" 2>/dev/null || true
sleep 1
echo "→ launching wflow..."
"$BIN" > "$LOG" 2>&1 &
disown
sleep 3
if ! hyprctl -j clients 2>/dev/null | jq -e '.[] | select(.class == "wflow")' > /dev/null; then
    echo "error: wflow window not found. check $LOG" >&2
    exit 1
fi

# ---- Helpers ----
# Send a key combo to wflow. Focuses wflow first so the keystroke
# lands on the right window even if you alt-tabbed away during a
# user prompt.
focus_wflow() {
    local addr
    addr=$(hyprctl -j clients 2>/dev/null \
        | jq -r '.[] | select(.class == "wflow") | .address' | head -n1)
    [[ -n "$addr" ]] && hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1 || true
    sleep 0.15
}

flip_theme() {
    focus_wflow
    wtype -M ctrl -k period -m ctrl
    sleep 0.4
}

capture() {
    local name="$1"
    focus_wflow
    sleep 0.2
    "$ROOT/scripts/grab.sh" "$name" >/dev/null
    echo "  ✓ $DEST/$name.png"
}

# 5-second countdown after Enter — gives you time to move the cursor
# onto the element you want hovered before grim fires.
countdown() {
    echo "  position your cursor inside wflow now..."
    for i in 5 4 3 2 1; do
        printf "    %d...\r" "$i"
        sleep 1
    done
    printf "    capture!     \n"
}

# Capture a (dark, light) pair for one surface. Prompts the user to
# set up the state first; pressing 'n' skips both shots.
pair() {
    local base="$1"
    local prompt="$2"
    echo
    echo "── $base ──"
    echo "  $prompt"
    read -r -p "  ready? [Enter to capture, n to skip] " ans
    if [[ "$ans" == "n" ]]; then
        echo "  skipped"
        return
    fi
    countdown
    capture "${base}.dark"
    flip_theme
    countdown
    capture "${base}.light"
    flip_theme  # back to dark for the next surface
}

# Send a Ctrl+N shortcut to navigate. This lets the script bounce
# between Library / Record without needing the user to click — but
# the editor + settings still need a manual click in between.
nav_library() { focus_wflow; wtype -M ctrl -k 1 -m ctrl; sleep 0.4; }
nav_record()  { focus_wflow; wtype -M ctrl -k 2 -m ctrl; sleep 0.4; }

# ---- Walk the manifest ----

nav_library
pair "library-grid" \
    "Library page. The eight bundled templates should be visible. No menus open."

# Library empty: requires a workflow folder swap. Skip via prompt
# unless the user has already cleared the library.
pair "library-empty" \
    "(Optional) Move all .kdl files out of ~/.config/wflow/workflows/ first to see the empty state. Press n to skip if your library is full."

pair "editor-canvas" \
    "Open Morning sync. Hover the right-side tool dock and click ✦ Smart tidy. The whole flow should fit at a readable zoom."

pair "editor-inspector" \
    "Same workflow open. Click any step card so the inspector slides in from the right."

nav_record
pair "record-idle" \
    "Record page in idle state — big amber button, no events captured."

pair "record-recording" \
    "Click the big button to arm, perform a few keystrokes, leave the recorder running. Capture mid-session."

# Settings is reachable from the cog in the chrome — no shortcut.
pair "settings" \
    "Click the gear in the bottom-right of the nav pill to open Settings."

# Explore — only if the flag is on.
if grep -q 'showExplore: true' qml/Theme.qml 2>/dev/null; then
    pair "explore-grid" \
        "Explore page (Ctrl+2). Mock catalog visible."
    pair "explore-detail" \
        "Click any Explore card to slide the detail drawer in over the grid."
else
    echo
    echo "Skipping explore-grid / explore-detail — Theme.showExplore is false."
    echo "(Re-enable the flag in qml/Theme.qml + rebuild if you want them.)"
fi

echo
echo "Done. $(ls "$DEST"/*.png 2>/dev/null | wc -l) PNGs in $DEST/"
