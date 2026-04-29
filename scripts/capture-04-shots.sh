#!/usr/bin/env bash
# One-shot capture recipe for the v0.4.0 screenshot set.
#
# Run this from the repo root with the screen unlocked. It builds the
# debug binary if needed, launches it, and walks you through each
# capture. Each step prints what to do (e.g. "open Morning standup,
# multi-select three cards") and then counts down before grim fires.
# Press Ctrl+C at any time to bail; partial captures stay in
# docs/design/screenshots/.
#
# Output (all under docs/design/screenshots/):
#   library.04.dark.png        — library, four-tab nav pill
#   editor-canvas.04.dark.png  — populated editor with wires + branch
#   editor-multiselect.04.dark — three cards lasso'd
#   editor-debug.04.dark       — paused mid-run, active card pulsing
#   editor-groups.04.dark      — group rectangle behind a few cards
#
# After the run, copy the ones you want into assets/screenshots/ and
# update README.md to reference them.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

BIN="$ROOT/target/debug/wflow"
LOG="/tmp/wflow-shoot.log"

if [[ ! -x "$BIN" ]]; then
    echo "→ building debug binary..."
    cargo build
fi

# Clean any stale instance, launch ours, give the window manager a
# moment to map it.
pkill -f "target/debug/wflow" 2>/dev/null || true
sleep 1
echo "→ launching wflow..."
"$BIN" > "$LOG" 2>&1 &
disown
sleep 3

# Make sure Hyprland sees the window before we start asking grab.sh
# to find it by class.
if ! hyprctl -j clients 2>/dev/null | jq -e '.[] | select(.class == "wflow")' > /dev/null; then
    echo "error: wflow window not found in hyprctl client list" >&2
    echo "       check $LOG and try again" >&2
    exit 1
fi

shoot() {
    local name="$1"
    local prompt="$2"
    local wait="${3:-6}"
    echo
    echo "── $name ──"
    echo "  $prompt"
    echo "  capturing in $wait seconds..."
    for ((i=wait; i>0; i--)); do
        printf "    %d...\r" "$i"
        sleep 1
    done
    echo
    ./scripts/grab.sh "$name" >/dev/null
    echo "  ✓ saved docs/design/screenshots/$name.png"
}

shoot "library.04.dark" \
    "Make sure you're on the Library page (Ctrl+1). Cards visible, no menus open."

shoot "editor-canvas.04.dark" \
    "Open Morning standup (or any workflow with a conditional). Let the canvas auto-fit. Don't select anything."

shoot "editor-multiselect.04.dark" \
    "Shift- or ctrl-drag a marquee around 2–4 cards so they're highlighted in cyan."

shoot "editor-debug.04.dark" \
    "Click ⏯ Debug, then watch one step start to fire. Capture while one card is pulsing."

shoot "editor-groups.04.dark" \
    "Alt-drag empty canvas to draw a group rectangle behind a few cards. Right-click → pick a tint. Double-click → type a comment."

echo
echo "All saved to docs/design/screenshots/. Copy into assets/screenshots/"
echo "and update README.md when you're happy with them."
