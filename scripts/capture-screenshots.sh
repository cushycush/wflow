#!/usr/bin/env bash
# Capture the v1.0 screenshot baseline in one pass — the catalog,
# sign-in, publish, triggers, and the editor surfaces that the
# README and design docs reference.
#
# For each surface this script:
#   1. Prompts you to set up the UI state
#   2. Captures <surface>.dark.png
#   3. Flips theme to light via Ctrl+. (sent through wtype)
#   4. Captures <surface>.light.png
#   5. Flips theme back to dark
#
# Output lands in docs/design/screenshots/claude-design/. Skip a
# surface by pressing 'n' at the prompt.
#
# Requires: cargo, grim, jq, wtype, and a Hyprland or Sway session.
# A signed-in wflow account is needed for the account-signed-in,
# publish-dialog, and publish-card-pill shots. Skip those with 'n'
# if you're capturing on a fresh / signed-out install.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

BIN="$ROOT/target/debug/wflow"
LOG="/tmp/wflow-shoot.log"
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
focus_wflow() {
    local addr
    addr=$(hyprctl -j clients 2>/dev/null \
        | jq -r '.[] | select(.class == "wflow") | .address' | head -n1)
    [[ -n "$addr" ]] && hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1 || true
    sleep 0.3
}

STATE_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/wflow/state.toml"
read_theme() {
    grep -m1 '^theme_mode' "$STATE_TOML" 2>/dev/null \
        | sed 's/.*= *//; s/"//g' \
        | tr -d '\n'
}

press_cycle() {
    local before; before=$(read_theme)
    focus_wflow
    wtype -M ctrl -k period -m ctrl
    local i
    for i in $(seq 1 30); do
        sleep 0.1
        local now; now=$(read_theme)
        if [[ -n "$now" && "$now" != "$before" ]]; then
            sleep 0.3
            return 0
        fi
    done
    return 1
}

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
        tries=$((tries + 1))
    done
    if [[ "$cur" != "$target" ]]; then
        echo "  ✗ couldn't reach theme=$target (currently $cur)."
        read -r -p "    set the theme manually then press Enter to continue " _
    fi
}

capture() {
    local name="$1"
    focus_wflow
    sleep 0.5
    "$ROOT/scripts/grab.sh" "$name" >/dev/null
    if [[ -f "$GRAB_DEST/$name.png" ]]; then
        mv "$GRAB_DEST/$name.png" "$DEST/$name.png"
    fi
    echo "  ✓ $DEST/$name.png"
}

countdown() {
    echo "  position your cursor inside wflow now..."
    for i in 5 4 3 2 1; do
        printf "    %d...\r" "$i"
        sleep 1
    done
    printf "    capture!     \n"
}

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
    ensure_theme dark
}

# ---- Nav helpers ----
# Ctrl+N follows the chrome pill order with Theme.showExplore on:
#   Ctrl+1 = Library, Ctrl+2 = Explore, Ctrl+3 = Record.
# Triggers, Favorites, Settings have no shortcuts — click in chrome.
nav_library() { focus_wflow; wtype -M ctrl -k 1 -m ctrl; sleep 0.4; }
nav_explore() { focus_wflow; wtype -M ctrl -k 2 -m ctrl; sleep 0.4; }
nav_record()  { focus_wflow; wtype -M ctrl -k 3 -m ctrl; sleep 0.4; }

# ---- Walk the manifest ----

# Library — the Daily folder + 5 top-level cards layout.
nav_library
pair "library-grid" \
    "Library tab. Five workflow cards plus the 'Daily' folder tile, no menus open."

pair "library-folder-open" \
    "Click the 'Daily' folder tile to drill in. Two cards visible: Morning sync + Daily standup."

pair "library-publish-pill" \
    "Library tab, signed in to wflows.io. Each card should show the '↑ Publish' pill in the top-right corner. Skip if signed out."

# Editor — Morning sync is the demo workflow (rich chip trail, chord
# trigger, vars, repeat block, conditional). Make sure it has saved
# card positions before running this script — open it once and let
# Smart Tidy do its thing.
nav_library
pair "editor-canvas" \
    "From Library, open Morning sync. Hover the right tool dock and click ✦ Smart tidy. Whole flow at a readable zoom."

pair "editor-step-palette" \
    "Same workflow open. Hover over the LEFT dock during the countdown so the palette expands and the labels slide in next to each chip."

pair "editor-inspector" \
    "Same workflow open. Click any step card so the inspector slides in from the right."

pair "editor-trigger-card" \
    "Same workflow open. The pinned trigger card at the top-left of the canvas should read the chord (super+m) and any when-predicate."

# Triggers tab — chrome pill, fourth slot. Three workflows have
# chord bindings (morning-sync, screenshot-and-share, loop-tab-thru).
nav_library
pair "triggers-tab" \
    "Click the 'Triggers' tab in the chrome pill. List shows the three bound workflows with their chords."

# Explore tab — Ctrl+2 navigates here when showExplore is on.
nav_explore
pair "explore-grid" \
    "Explore tab. Featured row + browse grid populated from wflows.io. No drawer open."

pair "explore-detail" \
    "Click any Explore card to slide the detail drawer in over the grid."

# Record tab.
nav_record
pair "record-idle" \
    "Record tab in idle state — big amber button, no events captured."

pair "record-recording" \
    "Click the big button to arm, perform a few keystrokes, leave the recorder running. Capture mid-session."

# Settings — gear icon in the bottom-right of the nav pill.
pair "settings" \
    "Click the gear in the bottom-right of the nav pill to open Settings. Capture the top of the page."

pair "settings-account" \
    "Settings open. Scroll to the Account section. Signed out shows the Sign in button; signed in shows @handle and a Sign out button. Capture whichever state is real."

pair "settings-palette" \
    "Settings open. Scroll to the Palette section showing the Warm Paper / Cool Slate switcher."

# Publish flow — only meaningful when signed in. Skip otherwise.
nav_library
pair "publish-dialog" \
    "Library tab. Right-click any workflow → 'Publish to wflows.io', or click the publish pill on a card. Fill in description + a few tags so the form has content. Skip if signed out."

echo
echo "Done. $(ls "$DEST"/*.png 2>/dev/null | wc -l) PNGs in $DEST/"
