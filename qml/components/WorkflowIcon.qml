import QtQuick
import Wflow

// "This is a workflow" mark, used as the leading icon on Library
// cards so workflows are recognizable at a glance without inheriting
// the visual character of whichever step happens to be first. Same
// rounded-square treatment as CategoryIcon so the two read as part
// of the same family — workflow icon is the parent label, step
// category icons are the children.
//
// Glyph: three small squares stepping diagonally down-right, an
// abstraction of "stages connected in sequence" that mirrors the
// brand mark's stepped-w. Drawn from primitives, so it stays
// pixel-clean at any size and never drifts off-center the way
// Unicode glyphs do.
Rectangle {
    id: root
    property real size: 36
    property bool hovered: false
    // The accent palette anchors this — the workflow icon is a
    // brand-color marker, not a category tint. Library cards get a
    // calmly recognizable "wflow" beat in their leading icon.
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

    // The stair-step glyph. Three cells stepping down-right,
    // tightened so the icon's visual mass matches the folder tile's
    // single-glyph icon at the same outer size. Coordinates are
    // computed from `size` so the icon scales cleanly.
    Item {
        anchors.fill: parent
        // Tuned so the trio's total span sits inside the same visual
        // envelope as the folder tile's outlined ▢ glyph at the same
        // outer 32 px size: cell ≈ 4 px and gap ≈ 1 px, giving a
        // 14 px span that reads at parity with the folder.
        readonly property int cell: Math.max(3, Math.round(root.size * 0.13))
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
            color: root._c
        }
        Rectangle {
            x: parent.startX + parent.cell + parent.gap
            y: parent.startY + parent.cell + parent.gap
            width: parent.cell
            height: parent.cell
            radius: Math.max(1, Math.round(width * 0.2))
            color: root._c
        }
        Rectangle {
            x: parent.startX + 2 * (parent.cell + parent.gap)
            y: parent.startY + 2 * (parent.cell + parent.gap)
            width: parent.cell
            height: parent.cell
            radius: Math.max(1, Math.round(width * 0.2))
            color: root._c
        }
    }
}
