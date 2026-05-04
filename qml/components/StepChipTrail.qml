import QtQuick
import QtQuick.Controls
import Wflow

// Two-row chip trail with a +N overflow sentinel. Cascade fires the
// chip borders in sequence on hover.
Item {
    id: root

    // [{kind, value}]; empty value uses _placeholderFor(kind).
    property var trail: []
    property bool hovered: false
    property int cascadeStep: 110
    property int holdMs: 220
    readonly property int chipHeight: 22
    readonly property int chipSpacing: 4
    property int maxChips: 12

    implicitHeight: 2 * chipHeight + chipSpacing

    readonly property var _visible: _model.visible
    readonly property int _hidden: _model.hidden
    property var _model: ({ visible: [], hidden: 0 })

    onWidthChanged: _layout()
    onTrailChanged: _layout()
    Component.onCompleted: _layout()

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
            border.color: Theme.lineSoft
            border.width: 1

            // Per-chip delay = chipIndex × cascadeStep, so chip 0 fires
            // immediately and the rest stagger ~cascadeStep apart.
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

    function _layout() {
        const w = root.width
        if (w <= 0 || !root.trail || root.trail.length === 0) {
            root._model = { visible: [], hidden: 0, plusX: 0, plusY: 0 }
            return
        }

        const sp = root.chipSpacing
        const N = Math.min(root.trail.length, root.maxChips)

        const items = []
        for (let i = 0; i < N; ++i) {
            const t = root.trail[i]
            const label = root._chipLabel(t.kind, t.value)
            items.push({ kind: t.kind, value: t.value, label: label, w: _estimateChipWidth(label) })
        }

        const positions = _pack(items, w, sp, /*reserve=*/0)
        let visible = positions.length
        let hidden = root.trail.length - visible

        // Shrink the visible set iteratively until the +N badge fits
        // at the tail without bumping anything to row 3.
        if (hidden > 0) {
            const plusW = _estimatePlusWidth(hidden)
            while (visible > 0) {
                const trimmed = items.slice(0, visible)
                const packed = _pack(trimmed, w, sp, plusW)
                if (packed.length === visible) {
                    const last = packed[packed.length - 1]
                    let plusX = last.x + last.w + sp
                    let plusY = last.y
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
            // Even the badge alone doesn't fit elegantly; show just
            // the badge so the user sees there are steps.
            root._model = {
                visible: [],
                hidden: root.trail.length,
                plusX: 0,
                plusY: 0
            }
            return
        }

        root._model = {
            visible: positions,
            hidden: 0,
            plusX: 0,
            plusY: 0
        }
    }

    // reserve = trailing width to keep free for the +N badge.
    function _pack(items, totalW, sp, reserve) {
        const out = []
        let row = 0
        let xPos = 0
        for (let i = 0; i < items.length; ++i) {
            const cw = items[i].w
            const isLast = (i === items.length - 1)
            const tailReserve = isLast ? reserve : 0
            const need = cw + tailReserve
            if (xPos > 0 && xPos + sp + need > totalW) {
                row++
                xPos = 0
                if (row >= 2) break
            }
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

    // 6.2 px/char @ mono 10px + 28px chrome (margins + dot + gap).
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
            // First two tokens, usually a verb plus a subcommand or
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
