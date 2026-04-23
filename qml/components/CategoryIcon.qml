import QtQuick
import Wflow

// A compact circular icon for an action category.
// Foreground glyph + colored background. Used on the left of action rows
// in Cinematic+; replaces/complements the chip.
Rectangle {
    id: root
    property string kind: "wait"
    property real size: 36
    property bool hovered: false

    readonly property var _colors: ({
        "key": Theme.catKey,
        "type": Theme.catType,
        "click": Theme.catClick,
        "move": Theme.catMove,
        "scroll": Theme.catScroll,
        "focus": Theme.catFocus,
        "wait": Theme.catWait,
        "shell": Theme.catShell,
        "notify": Theme.catNotify,
        "clipboard": Theme.catClip,
        "note": Theme.catNote
    })
    // Per-kind glyph (unicode). Cheap + free + readable at 16-20px.
    readonly property var _glyphs: ({
        "key":       "⌘",
        "type":      "T",
        "click":     "◉",
        "move":      "↔",
        "scroll":    "⇅",
        "focus":     "⊡",
        "wait":      "⏱",
        "shell":     "›",
        "notify":    "◐",
        "clipboard": "⎘",
        "note":      "¶"
    })
    readonly property color _c: _colors[kind] || Theme.catWait
    readonly property string _g: _glyphs[kind] || "•"

    width: size
    height: size
    radius: size / 2
    color: Qt.rgba(_c.r, _c.g, _c.b, root.hovered ? 0.24 : 0.16)

    // Subtle outline ring that strengthens on hover.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.color: Qt.rgba(root._c.r, root._c.g, root._c.b, root.hovered ? 0.6 : 0.35)
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: 160 } }
    }

    Text {
        anchors.centerIn: parent
        text: root._g
        color: root._c
        font.family: Theme.familyBody
        font.pixelSize: Math.round(root.size * 0.50)
        font.weight: Font.Bold

        // Maximalist — slight spin on hover
        rotation: (VisualStyle.iconHoverSpin && root.hovered) ? 8 : 0
        scale: (VisualStyle.iconHoverSpin && root.hovered) ? 1.08 : 1.0
        Behavior on rotation { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
    }
}
