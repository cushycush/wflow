import QtQuick
import Wflow

// Single library-style step chip: pill, category-color dot at left,
// mono label using the same abbreviation rules StepChipTrail (and the
// wflows.io site) use for trails — chord glyphs, shell first-token,
// type with quotes stripped. Pulled out so the editor's palette and
// canvas can share the look with the library cards.
Rectangle {
    id: root

    property string kind: "key"
    property string value: ""
    // Skip _abbrev / _placeholderFor and render this verbatim.
    property string overrideLabel: ""
    // Idle palette items render flat; active states bring the surface fill.
    property bool flat: false
    // Bigger numbers turn the chip into a hero; canvas cards use 12 to
    // read as the card's primary content, palette + library trail use 10.
    property int fontSize: 10

    readonly property string label:
        overrideLabel.length > 0 ? overrideLabel : _chipLabel(kind, value)
    readonly property color catColor: Theme.catFor(kind)

    implicitHeight: 22
    implicitWidth: chipText.implicitWidth + 32  // 8 left + 6 dot + 6 gap + 12 right
    radius: height / 2
    color: flat
        ? "transparent"
        : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.7)
    border.color: Theme.lineSoft
    border.width: 1

    Rectangle {
        id: chipDot
        width: 6
        height: 6
        radius: 3
        color: root.catColor
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
    }

    Text {
        id: chipText
        anchors.left: chipDot.right
        anchors.leftMargin: 6
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.text2
        font.family: Theme.familyMono
        font.pixelSize: root.fontSize
        font.letterSpacing: 0.1
        elide: Text.ElideRight
    }

    function _chipLabel(kind, value) {
        if (value && value.length > 0) {
            return _abbrev(kind, value)
        }
        return _placeholderFor(kind)
    }

    // Mirrors StepChipTrail._abbrev. Kept duplicated so StepChip stays
    // self-contained; if the experiment lands, fold StepChipTrail's
    // chip rendering through this primitive and drop the copy.
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
            const words = value.trim().split(/\s+/)
            if (words.length >= 2) return words[0] + " " + words[1]
            return words[0] || value
        }
        if (kind === "wait") return "wait " + value
        if (kind === "type") {
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
