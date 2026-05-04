import QtQuick
import QtQuick.Controls
import Wflow

// wflows.io-style horizontal chip trail. Shared by the library and
// explore cards so a workflow reads the same way on both surfaces.
//
// Each chip is a pill with:
//   - a colored dot in the kind's category color
//   - a short mono label (chord, command verb, duration, ...)
//   - a hairline border that lights up in the kind's color while the
//     workflow is "playing" through itself (see hovered animation)
//
// Lays out within a fixed two-row budget. Chips render until they
// would push past row 2; everything past that drops behind a +N
// sentinel. The card's height is sized to fit two rows + the rule +
// the footer, so the trail can't ever overlap the rule even when
// every label is long.
//
// `hovered` is the host card's hover state. When it flips true each
// chip's border briefly flashes to its kind's category color in
// sequence — a wave from the first chip to the last, like the engine
// invoking each step in order. Same trick wflows.io hero card runs.
Item {
    id: root

    // [{kind: String, value: String}] — kind drives the dot color and
    // the placeholder fallback; value is the live label. Empty value
    // falls back to `_placeholderFor(kind)` so mock / pre-network
    // rows still render.
    property var trail: []
    // Card-level hover state. Triggers the cascade animation.
    property bool hovered: false
    // Per-chip cascade delay in ms. 110ms × N chips reads as a
    // sequential "step ran, now the next step" without dragging.
    property int cascadeStep: 110
    // How long each chip's border holds its kind color before fading
    // back to the resting hairline.
    property int holdMs: 220
    // Chip geometry — kept here so the layout pass and the rendered
    // delegates agree on widths without one drifting from the other.
    readonly property int chipHeight: 22
    readonly property int chipSpacing: 4
    // Hard cap regardless of layout — keeps the +N from claiming a
    // huge number on workflows with thousands of steps.
    property int maxChips: 12

    // Two-row budget: 2 chips × height + 1 spacing.
    implicitHeight: 2 * chipHeight + chipSpacing

    // Layout cache. Recomputed by _layout() whenever width / trail
    // change; the Repeaters bind to these arrays so the chip + +N
    // render lockstep with the visibility decision.
    readonly property var _visible: _model.visible
    readonly property int _hidden: _model.hidden
    property var _model: ({ visible: [], hidden: 0 })

    onWidthChanged: _layout()
    onTrailChanged: _layout()
    Component.onCompleted: _layout()

    // Visible chips, with their pre-computed x/y positions baked in
    // so QML doesn't run a Flow pass and re-do the work the layout
    // already settled.
    Repeater {
        model: root._visible
        delegate: Rectangle {
            id: chip
            readonly property color dotColor: Theme.catFor(modelData.kind || "wait")
            readonly property int chipIndex: index
            x: modelData.x
            y: modelData.y
            height: root.chipHeight
            width: modelData.w
            radius: height / 2
            color: Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.7)
            // border.color is animated by `cascade` while the card is
            // hovered. The base `Theme.lineSoft` is the resting state;
            // the animation drives it through dotColor and back.
            border.color: Theme.lineSoft
            border.width: 1

            // Sequential cascade across the trail. The animation runs
            // every time `root.hovered` flips true, with a per-chip
            // delay (chipIndex × cascadeStep) so chip 0 fires
            // immediately, chip 1 fires ~110ms later, etc — like the
            // engine stepping through the workflow. Each chip's
            // border tweens to the kind's category color, holds, then
            // fades back to the resting hairline. Stops cleanly on
            // un-hover; the resting binding takes the border back to
            // lineSoft on the way out.
            SequentialAnimation {
                id: cascade
                PauseAnimation { duration: chip.chipIndex * root.cascadeStep }
                ColorAnimation {
                    target: chip
                    property: "border.color"
                    to: chip.dotColor
                    duration: Theme.dur(Theme.durFast)
                    easing.type: Easing.OutCubic
                }
                PauseAnimation { duration: root.holdMs }
                ColorAnimation {
                    target: chip
                    property: "border.color"
                    to: Theme.lineSoft
                    duration: Theme.dur(Theme.durBase)
                    easing.type: Easing.OutCubic
                }
            }

            Connections {
                target: root
                function onHoveredChanged() {
                    if (root.hovered) {
                        cascade.restart()
                    } else {
                        cascade.stop()
                        chip.border.color = Theme.lineSoft
                    }
                }
            }

            Rectangle {
                id: chipDot
                width: 6
                height: 6
                radius: 3
                color: chip.dotColor
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                anchors.left: chipDot.right
                anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: Theme.text2
                font.family: Theme.familyMono
                font.pixelSize: 10
                font.letterSpacing: 0.1
                elide: Text.ElideRight
            }
        }
    }

    // +N sentinel for chips that didn't fit in the two-row budget.
    // Position comes from the layout pass: it always lands at the
    // tail of the visible chips, on the same row whenever there's
    // room, dropping to row 2 only when the tail of row 1 was full.
    Rectangle {
        id: plusBadge
        visible: root._hidden > 0
        x: root._model.plusX || 0
        y: root._model.plusY || 0
        width: plusText.implicitWidth + 12
        height: root.chipHeight
        radius: height / 2
        color: "transparent"
        border.color: Theme.lineSoft
        border.width: 1

        Text {
            id: plusText
            anchors.centerIn: parent
            text: "+" + root._hidden
            color: Theme.text3
            font.family: Theme.familyMono
            font.pixelSize: 10
        }
    }

    // Two-row layout pass. Walks the trail estimating chip widths
    // from the label length (mono 10px ≈ 6.2px per char), packs
    // chips left-to-right, wraps once at the row boundary, and
    // stops when row 2 fills up. Reserves space for the +N sentinel
    // when there's overflow so it never gets pushed off the visible
    // area.
    function _layout() {
        const w = root.width
        if (w <= 0 || !root.trail || root.trail.length === 0) {
            root._model = { visible: [], hidden: 0, plusX: 0, plusY: 0 }
            return
        }

        const sp = root.chipSpacing
        const N = Math.min(root.trail.length, root.maxChips)

        // Pre-compute each chip's width + label up to the cap.
        const items = []
        for (let i = 0; i < N; ++i) {
            const t = root.trail[i]
            const label = root._chipLabel(t.kind, t.value)
            items.push({ kind: t.kind, value: t.value, label: label, w: _estimateChipWidth(label) })
        }

        // First pass: pack chips into 2 rows, no overflow reservation.
        const positions = _pack(items, w, sp, /*reserve=*/0)
        let visible = positions.length
        let hidden = root.trail.length - visible

        // If there's overflow, reserve space for the +N sentinel and
        // re-pack until it fits cleanly.
        if (hidden > 0) {
            const plusW = _estimatePlusWidth(hidden)
            // Iteratively shrink the visible set until the +N fits at
            // the tail without bumping anything to row 3.
            while (visible > 0) {
                const trimmed = items.slice(0, visible)
                const packed = _pack(trimmed, w, sp, plusW)
                if (packed.length === visible) {
                    // All trimmed chips fit alongside the sentinel.
                    const last = packed[packed.length - 1]
                    let plusX = last.x + last.w + sp
                    let plusY = last.y
                    // If the sentinel would overflow this row, drop
                    // it to the next row's start. _pack already
                    // ensured the row is available.
                    if (plusX + plusW > w) {
                        plusX = 0
                        plusY = root.chipHeight + sp
                    }
                    root._model = {
                        visible: packed,
                        hidden: root.trail.length - visible,
                        plusX: plusX,
                        plusY: plusY
                    }
                    return
                }
                visible--
            }
            // Couldn't fit any chip + sentinel; render just the badge
            // at the origin so the user sees there are steps even on
            // a tiny card.
            root._model = {
                visible: [],
                hidden: root.trail.length,
                plusX: 0,
                plusY: 0
            }
            return
        }

        // No overflow: emit the natural pack as-is.
        root._model = {
            visible: positions,
            hidden: 0,
            plusX: 0,
            plusY: 0
        }
    }

    // Pack chip widths into ≤ 2 rows. `reserve` is the width to keep
    // free at the end of whichever row the last chip lands on, used
    // to reserve space for the +N sentinel when needed. Returns an
    // array of {kind, value, label, x, y, w} for every chip that
    // fit; chips that didn't fit are omitted.
    function _pack(items, totalW, sp, reserve) {
        const out = []
        let row = 0
        let xPos = 0
        for (let i = 0; i < items.length; ++i) {
            const cw = items[i].w
            const isLast = (i === items.length - 1)
            const tailReserve = isLast ? reserve : 0
            const need = cw + tailReserve
            // Fits on the current row?
            if (xPos > 0 && xPos + sp + need > totalW) {
                row++
                xPos = 0
                if (row >= 2) break
            }
            // Need to fit even at start of a fresh row.
            if (xPos === 0 && need > totalW) break
            const x = xPos === 0 ? 0 : xPos + sp
            out.push({
                kind: items[i].kind,
                value: items[i].value,
                label: items[i].label,
                x: x,
                y: row * (root.chipHeight + sp),
                w: cw
            })
            xPos = x + cw
        }
        return out
    }

    // Mono 10px ≈ 6.2px per char. Add 8 (left margin) + 6 (dot) + 6
    // (gap) + 8 (right padding) ≈ 28px chrome.
    function _estimateChipWidth(label) {
        const text = (label && label.length > 0) ? label : ""
        return Math.ceil(text.length * 6.2) + 28
    }

    function _estimatePlusWidth(n) {
        const text = "+" + n
        return Math.ceil(text.length * 6.2) + 12
    }

    // Chip label resolution. Real values from the API render as-is
    // (truncated by elide on overflow). Empty values fall back to a
    // per-kind placeholder so a "shell" chip still reads as a shell
    // chip even before the live data lands.
    function _chipLabel(kind, value) {
        if (value && value.length > 0) {
            return _abbrev(kind, value)
        }
        return _placeholderFor(kind)
    }

    // The chord / type / shell chips read better with the same
    // shorthand wflows.io uses: ⌘ for super, ⌥ for alt, ⌃ for ctrl,
    // ⇧ for shift, ↵ for return. Long shell commands trim to the
    // first token so the chip reads as a verb instead of a wall.
    function _abbrev(kind, value) {
        if (kind === "key" && value.indexOf("+") >= 0) {
            return value
                .replace(/\bsuper\b/gi, "⌘")
                .replace(/\balt\b/gi, "⌥")
                .replace(/\bctrl\b/gi, "⌃")
                .replace(/\bshift\b/gi, "⇧")
                .replace(/\+/g, "")
        }
        if (kind === "key") {
            const m = ({
                "Return": "↵", "Escape": "⎋", "Tab": "⇥",
                "BackSpace": "⌫", "Delete": "⌦",
                "Up": "↑", "Down": "↓", "Left": "←", "Right": "→"
            })
            if (m[value]) return m[value]
            return value
        }
        if (kind === "shell") {
            // First two tokens — usually a verb plus a subcommand or
            // a path. Keeps the chip narrow without losing the gist.
            const words = value.trim().split(/\s+/)
            if (words.length >= 2) return words[0] + " " + words[1]
            return words[0] || value
        }
        if (kind === "wait") return "wait " + value
        if (kind === "type") {
            // Strip surrounding quotes when present so "/standup" reads
            // cleaner than "\"/standup\"".
            return value.replace(/^["']|["']$/g, "")
        }
        return value
    }

    function _placeholderFor(kind) {
        const placeholders = ({
            "key":       "key",
            "type":      "type",
            "click":     "click",
            "move":      "move",
            "scroll":    "scroll",
            "focus":     "focus",
            "wait":      "wait",
            "shell":     "shell",
            "notify":    "notify",
            "clipboard": "paste",
            "note":      "note",
            "repeat":    "repeat",
            "when":      "when",
            "unless":    "unless",
            "use":       "use"
        })
        return placeholders[kind] || kind
    }
}
