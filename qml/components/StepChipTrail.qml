import QtQuick
import QtQuick.Controls
import Wflow

// wflows.com-style horizontal chip trail. Shared by the library and
// explore cards so a workflow reads the same way on both surfaces.
//
// Each chip is a pill with:
//   - a colored dot in the kind's category color
//   - a short mono label (chord, command verb, duration, ...)
//   - a hairline border that lifts on hover
//
// The trail wraps to a second line when the values run long, capped
// at `cap` chips with a `+N` sentinel for the overflow.
//
// `hovered` is the host card's hover state. When it flips true each
// chip animates from a faded resting state up to full opacity with a
// staggered delay (32ms × index), matching the wflows.com "the trail
// lights up as you scan it" feel.
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
    // Card-level hover state. Drives the stagger entrance.
    property bool hovered: false
    // Per-chip stagger in ms. 32ms × N chips reads as "rolling in"
    // without dragging the eye through a slow reveal.
    property int staggerStep: 32
    // How far each chip lifts during the staggered entrance.
    property int liftPx: 4
    // Resting opacity when the card isn't hovered. Lower than 1.0 so
    // the entrance feels like a reveal rather than a polish.
    property real restOpacity: 0.65

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
            color: chipArea.containsMouse
                ? Theme.surface3
                : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.7)
            border.color: chipArea.containsMouse ? Theme.line : Theme.lineSoft
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

            // Stagger entrance on hover. Resting opacity 0.65;
            // hovered each chip animates up to 1.0 with a per-index
            // delay (32ms × index) so the trail "lights up" left to
            // right. Un-hover collapses everything back at once with
            // no stagger, so the card releases cleanly. Reduce-motion
            // zeroes durations via Theme.dur the same as everywhere
            // else.
            opacity: root.hovered ? 1.0 : root.restOpacity
            Behavior on opacity {
                SequentialAnimation {
                    PauseAnimation { duration: root.hovered ? chip.chipIndex * root.staggerStep : 0 }
                    NumberAnimation {
                        duration: Theme.dur(Theme.durBase)
                        easing.type: Easing.OutCubic
                    }
                }
            }

            // Subtle scale-in matching the opacity reveal. Resting
            // chips sit a hair smaller (0.96), hovered scale to 1.0
            // following the same staggered timeline. Together with
            // the opacity stagger this reads as the chip "popping
            // in" rather than just brightening.
            scale: root.hovered ? 1.0 : 0.96
            transformOrigin: Item.Center
            Behavior on scale {
                SequentialAnimation {
                    PauseAnimation { duration: root.hovered ? chip.chipIndex * root.staggerStep : 0 }
                    NumberAnimation {
                        duration: Theme.dur(Theme.durBase)
                        easing.type: Easing.OutCubic
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

            MouseArea {
                id: chipArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
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
