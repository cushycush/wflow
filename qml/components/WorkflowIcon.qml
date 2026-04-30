import QtQuick
import Wflow

// Stair-step glyph from primitives, accent-tinted. Library cards use
// it as a brand-mark beat instead of inheriting whichever step kind
// happens to be first.
Rectangle {
    id: root
    property real size: 36
    property bool hovered: false
    readonly property color _c: Theme.accent

    width: size
    height: size
    radius: Math.min(Theme.radiusMd, Math.max(3, Math.round(size * 0.22)))
    color: Theme.wash(_c, root.hovered ? 0.24 : 0.16)

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.color: Theme.wash(root._c, root.hovered ? 0.6 : 0.35)
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: Theme.dur(160) } }
    }

    Item {
        anchors.fill: parent
        // Outlined cells read lighter than solid; 0.16 keeps perceived
        // mass at the same level as a single-glyph icon.
        readonly property int cell: Math.max(4, Math.round(root.size * 0.16))
        readonly property int gap:  Math.max(1, Math.round(root.size * 0.04))
        readonly property int span: 3 * cell + 2 * gap
        readonly property real startX: (root.size - span) / 2
        readonly property real startY: startX

        Rectangle {
            x: parent.startX
            y: parent.startY
            width: parent.cell
            height: parent.cell
            radius: Math.max(1, Math.round(width * 0.2))
            color: "transparent"
            border.color: root._c
            border.width: 1
        }
        Rectangle {
            x: parent.startX + parent.cell + parent.gap
            y: parent.startY + parent.cell + parent.gap
            width: parent.cell
            height: parent.cell
            radius: Math.max(1, Math.round(width * 0.2))
            color: "transparent"
            border.color: root._c
            border.width: 1
        }
        Rectangle {
            x: parent.startX + 2 * (parent.cell + parent.gap)
            y: parent.startY + 2 * (parent.cell + parent.gap)
            width: parent.cell
            height: parent.cell
            radius: Math.max(1, Math.round(width * 0.2))
            color: "transparent"
            border.color: root._c
            border.width: 1
        }
    }
}
