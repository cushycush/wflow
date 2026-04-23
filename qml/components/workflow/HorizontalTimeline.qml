import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Wflow

// Variant 1 — TIMELINE (snaking, no horizontal scroll).
//
// Nodes lay out left-to-right; when the row fills up the connector line
// makes a rounded 90° turn down, a short vertical drop, and a rounded 90°
// turn back to horizontal running the opposite direction. Subsequent nodes
// trail along the new line. The line itself is a single continuous path
// drawn with QtQuick.Shapes so the progress overlay is the same geometry
// truncated at the active step.
Item {
    id: root
    property var actions: []
    property int activeStepIndex: -1
    property bool running: false

    readonly property int sidePadding: 48
    readonly property int nodeSpacing: 140
    readonly property int rowHeight: 180
    readonly property int cornerRadius: 24
    readonly property int topPadding: 36
    readonly property int bottomPadding: 36

    readonly property real availableWidth: Math.max(nodeSpacing * 2, root.width - 2 * sidePadding)
    readonly property int nodesPerRow: Math.max(2, Math.floor(availableWidth / nodeSpacing) + 1)
    readonly property real actualSpacing: nodesPerRow > 1 ? availableWidth / (nodesPerRow - 1) : availableWidth
    readonly property int rowCount: Math.max(1, Math.ceil(actions.length / nodesPerRow))

    implicitHeight: rowCount * rowHeight + topPadding + bottomPadding

    // Per-node geometry — used by both the line path and node layout.
    function nodePos(index) {
        const row = Math.floor(index / nodesPerRow)
        const col = index % nodesPerRow
        const ltr = (row % 2 === 0)
        const x = ltr
            ? sidePadding + col * actualSpacing
            : sidePadding + (nodesPerRow - 1 - col) * actualSpacing
        const y = topPadding + rowHeight / 2 + row * rowHeight
        return { x: x, y: y, row: row, col: col, ltr: ltr }
    }

    // Build the SVG path traced through nodes 0..upTo.
    // upTo === -1 means full path (for the base line).
    function buildSnakePath(upTo) {
        const end = upTo < 0 ? actions.length - 1 : upTo
        if (end < 0 || actions.length === 0) return ""

        const R = cornerRadius
        let d = ""

        for (let i = 0; i <= end; i++) {
            const p = nodePos(i)
            if (i === 0) {
                d += "M " + p.x + " " + p.y + " "
                continue
            }
            const prev = nodePos(i - 1)
            if (prev.row === p.row) {
                d += "L " + p.x + " " + p.y + " "
            } else if (prev.ltr) {
                // Was moving right; turn down on the right side, then left.
                // Two 90° arcs joined by an optional vertical segment.
                const ax = prev.x + R
                const ay = prev.y + R
                const by = p.y - R
                d += "A " + R + " " + R + " 0 0 1 " + ax + " " + ay + " "
                if (by > ay) d += "L " + ax + " " + by + " "
                d += "A " + R + " " + R + " 0 0 1 " + p.x + " " + p.y + " "
            } else {
                // Was moving left; turn down on the left side, then right.
                const ax = prev.x - R
                const ay = prev.y + R
                const by = p.y - R
                d += "A " + R + " " + R + " 0 0 0 " + ax + " " + ay + " "
                if (by > ay) d += "L " + ax + " " + by + " "
                d += "A " + R + " " + R + " 0 0 0 " + p.x + " " + p.y + " "
            }
        }
        return d
    }

    readonly property string fullLinePath: buildSnakePath(-1)
    readonly property string progressPath: buildSnakePath(activeStepIndex)

    // The snake line + progress overlay.
    Shape {
        anchors.fill: parent
        smooth: true
        antialiasing: true

        ShapePath {
            strokeWidth: 2
            strokeColor: Theme.lineSoft
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.fullLinePath }
        }

        ShapePath {
            strokeWidth: 2
            strokeColor: Theme.accent
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.progressPath }
        }
    }

    // Nodes (each one: label above, circle icon, value chip below).
    Repeater {
        model: root.actions
        delegate: Item {
            id: nodeItem
            readonly property var pos: root.nodePos(index)
            readonly property bool isActive: index === root.activeStepIndex
            readonly property bool isPast: index < root.activeStepIndex
            readonly property color catColor: {
                const t = ({
                    "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                    "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                    "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                    "clipboard": Theme.catClip, "note": Theme.catNote
                })
                return t[modelData.kind] || Theme.catWait
            }

            x: pos.x - width / 2
            y: pos.y - height / 2
            width: 44
            height: 44

            // Step number + summary above
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: icon.top
                anchors.bottomMargin: 14
                spacing: 2
                width: 140
                Text {
                    text: String(index + 1).padStart(2, "0")
                    color: nodeItem.isActive ? nodeItem.catColor : Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    horizontalAlignment: Text.AlignHCenter
                    width: parent.width
                }
                Text {
                    text: modelData.summary
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            // Node circle
            Rectangle {
                id: icon
                anchors.centerIn: parent
                width: nodeItem.isActive ? 48 : 36
                height: width
                radius: width / 2
                color: nodeItem.isActive
                    ? nodeItem.catColor
                    : Qt.rgba(nodeItem.catColor.r, nodeItem.catColor.g, nodeItem.catColor.b, nodeItem.isPast ? 0.55 : 0.18)
                border.color: Qt.rgba(nodeItem.catColor.r, nodeItem.catColor.g, nodeItem.catColor.b, nodeItem.isActive ? 1.0 : 0.5)
                border.width: nodeItem.isActive ? 2 : 1
                Behavior on width { NumberAnimation { duration: Theme.durBase; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: Theme.durBase } }

                Text {
                    anchors.centerIn: parent
                    text: {
                        const g = ({
                            "key": "⌘", "type": "T", "click": "◉", "move": "↔", "scroll": "⇅",
                            "focus": "⊡", "wait": "⏱", "shell": "›", "notify": "◐",
                            "clipboard": "⎘", "note": "¶"
                        })
                        return g[modelData.kind] || "•"
                    }
                    color: nodeItem.isActive ? Theme.accentText : nodeItem.catColor
                    font.family: Theme.familyBody
                    font.pixelSize: nodeItem.isActive ? 20 : 16
                    font.weight: Font.Bold
                }

                // Pulse when active
                Rectangle {
                    visible: nodeItem.isActive
                    anchors.centerIn: parent
                    width: parent.width + 16
                    height: parent.height + 16
                    radius: width / 2
                    color: "transparent"
                    border.color: nodeItem.catColor
                    border.width: 2
                    opacity: 0.6
                    SequentialAnimation on opacity {
                        running: nodeItem.isActive
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.15; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 0.6;  duration: 900; easing.type: Easing.InOutSine }
                    }
                }
            }

            // Value chip below
            Rectangle {
                visible: modelData.value && modelData.value.length > 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: icon.bottom
                anchors.topMargin: 14
                width: Math.min(130, valText.implicitWidth + 16)
                height: 22
                radius: 11
                color: Qt.rgba(nodeItem.catColor.r, nodeItem.catColor.g, nodeItem.catColor.b, 0.12)
                border.color: Qt.rgba(nodeItem.catColor.r, nodeItem.catColor.g, nodeItem.catColor.b, 0.3)
                border.width: 1

                Text {
                    id: valText
                    anchors.centerIn: parent
                    text: modelData.value
                    color: nodeItem.catColor
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    width: parent.width - 12
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }
}
