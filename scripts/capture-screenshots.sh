#!/usr/bin/env bash
# Capture the full design-docs / Claude Design screenshot baseline
# in one pass.
#
# For each surface this script:
#   1. Prompts you to set up the UI state
#   2. Captures <surface>.dark.png
#   3. Flips theme to light via Ctrl+. (sent through wtype)
#   4. Captures <surface>.light.png
#   5. Flips theme back to dark
#
# Output lands in docs/design/screenshots/claude-design/, isolated
# from the README v0.4 captures (which live in the screenshots root
# named <surface>.04.dark / .light). Upload the contents of the
# claude-design subdir verbatim. Skip a surface by pressing 'n' at
# the prompt; capture all of it by pressing Enter.
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
# Claude Design / design-docs baseline shots land in their own subdir
# so they don't get mixed up with the README v0.4 captures (named
# <surface>.04.dark / .light) sitting in the screenshots root. Upload
# the contents of this subdir verbatim to Claude Design.
DEST="$ROOT/docs/design/screenshots/claude-design"
GRAB_DEST="$ROOT/docs/design/screenshots"
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
    sleep 0.3
}

# State.toml is the source of truth for the theme. apply_theme_mode
# saves to disk synchronously (see src/bridge/state.rs), so reading
# it after a keystroke tells us whether the flip actually committed.
STATE_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/wflow/state.toml"
read_theme() {
    grep -m1 '^theme_mode' "$STATE_TOML" 2>/dev/null \
        | sed 's/.*= *//; s/"//g' \
        | tr -d '\n'
}

# Press Ctrl+. once and poll state.toml until theme_mode changes.
# Returns 0 if the keystroke landed, 1 if it didn't reach wflow
# (terminal probably stole focus).
press_cycle() {
    local before; before=$(read_theme)
    focus_wflow
    wtype -M ctrl -k period -m ctrl
    local i
    for i in $(seq 1 30); do
        sleep 0.1
        local now; now=$(read_theme)
        if [[ -n "$now" && "$now" != "$before" ]]; then
            sleep 0.3   # let the QML ColorAnimation settle
            return 0
        fi
    done
    return 1
}

# Cycle Ctrl+. until theme_mode == $1. The theme cycles
# dark → auto → light → dark — so going dark→light needs TWO
# presses, light→dark needs one. ensure_theme handles either.
# Falls back to asking the user to flip manually if four cycles
# don't get there.
ensure_theme() {
    local target="$1"
    local cur; cur=$(read_theme)
    local tries=0
    while [[ "$cur" != "$target" ]] && (( tries < 4 )); do
        if ! press_cycle; then
            echo "  ⚠ Ctrl+. didn't register (terminal probably had focus). Retrying..."
            sleep 0.5
        fi
        cur=$(read_theme)
        # `tries=$((tries+1))` instead of `((tries++))` — the latter
        # returns the pre-increment value, which is 0 on the first
        # iteration; under `set -e` that kills the script.
        tries=$((tries + 1))
    done
    if [[ "$cur" != "$target" ]]; then
        echo "  ✗ couldn't reach theme=$target (currently $cur)."
        read -r -p "    set the theme manually then press Enter to continue " _
    fi
}

capture() {
    local name="$1"
    # Re-focus + a generous settle before grim fires, so any pending
    # theme transition or repaint has finished by the time we sample
    # pixels. Then move from grab.sh's default path into the
    # claude-design subdir.
    focus_wflow
    sleep 0.5
    "$ROOT/scripts/grab.sh" "$name" >/dev/null
    if [[ -f "$GRAB_DEST/$name.png" ]]; then
        mv "$GRAB_DEST/$name.png" "$DEST/$name.png"
    fi
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
    ensure_theme dark
    countdown
    capture "${base}.dark"
    ensure_theme light
    countdown
    capture "${base}.light"
    ensure_theme dark   # leave on dark for the next surface
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

pair "editor-step-palette" \
    "Same workflow open. Hover over the LEFT dock during the countdown so the palette expands and the labels slide in next to each coloured chip — that's the shot."

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
