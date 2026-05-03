import QtQuick
import QtQuick.Controls
import Wflow

// wflows.com-style horizontal chip trail. Shared by the library and
// explore cards so a workflow reads the same way on both surfaces.
//
// Each chip is a pill with:
//   - a colored dot in the kind's category color
//   - a short mono label (chord, command verb, duration, ...)
//   - a hairline border that lights up in the kind's color while the
//     workflow is "playing" through itself (see hovered animation)
//
// The trail wraps to a second line when the values run long, capped
// at `cap` chips with a `+N` sentinel for the overflow.
//
// `hovered` is the host card's hover state. When it flips true each
// chip's border briefly flashes to its kind's category color in
// sequence — a wave from the first chip to the last, like the engine
// invoking each step in order. Same trick wflows.com hero card runs.
Flow {
    id: root

    // [{kind: String, value: String}] — kind drives the dot color and
    // the placeholder fallback; value is the live label. Empty value
    // falls back to `_placeholderFor(kind)` so mock / pre-network
    // rows still render.
    property var trail: []
    // Max chips before the +N sentinel. The full step list is in the
    // detail drawer; the trail is a card-density preview only.
    property int cap: 6
    // Card-level hover state. Triggers the cascade animation.
    property bool hovered: false
    // Per-chip cascade delay in ms. 110ms × N chips reads as a
    // sequential "step ran, now the next step" without dragging.
    property int cascadeStep: 110
    // How long each chip's border holds its kind color before fading
    // back to the resting hairline.
    property int holdMs: 220

    spacing: 4

    readonly property int trailCount: trail.length
    readonly property int trailHidden: Math.max(0, trailCount - cap)

    Repeater {
        model: root.trail.slice(0, root.cap)
        delegate: Rectangle {
            id: chip
            readonly property color dotColor: Theme.catFor(modelData.kind || "wait")
            readonly property string chipLabel: root._chipLabel(modelData.kind, modelData.value)
            readonly property int chipIndex: index
            height: 22
            width: chipDot.width + chipText.implicitWidth + 18
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
                id: chipText
                anchors.left: chipDot.right
                anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: chip.chipLabel
                color: Theme.text2
                font.family: Theme.familyMono
                font.pixelSize: 10
                font.letterSpacing: 0.1
                elide: Text.ElideRight
            }
        }
    }

    Rectangle {
        visible: root.trailHidden > 0
        width: moreText.implicitWidth + 12
        height: 22
        radius: height / 2
        color: "transparent"
        border.color: Theme.lineSoft
        border.width: 1

        Text {
            id: moreText
            anchors.centerIn: parent
            text: "+" + root.trailHidden
            color: Theme.text3
            font.family: Theme.familyMono
            font.pixelSize: 10
        }
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
    // shorthand wflows.com uses: ⌘ for super, ⌥ for alt, ⌃ for ctrl,
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
