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

    readonly property color _c: Theme.catFor(kind)
    readonly property string _g: Theme.catGlyph(kind)

    width: size
    height: size
    radius: size / 2
    color: Theme.wash(_c, root.hovered ? 0.24 : 0.16)

    // Subtle outline ring that strengthens on hover.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.color: Theme.wash(root._c, root.hovered ? 0.6 : 0.35)
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: Theme.dur(160) } }
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
        Behavior on rotation { NumberAnimation { duration: Theme.dur(240); easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: Theme.dur(240); easing.type: Easing.OutCubic } }
    }
}
