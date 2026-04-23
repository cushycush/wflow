import QtQuick
import QtQuick.Controls
import Wflow

// Horizontal pill row for category filtering. The active one gets accent tint;
// the rest sit quietly. "All" is always first.
Row {
    id: root
    property var categories: ["All", "Dev", "System", "Focus", "Meetings", "Media", "Writing", "Data", "Misc"]
    property string selected: "All"
    signal selectionChanged(string category)

    spacing: 8

    Repeater {
        model: root.categories
        delegate: Rectangle {
            readonly property bool active: modelData === root.selected
            width: lbl.implicitWidth + 22
            height: 30
            radius: 15
            color: active
                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                : (pillArea.containsMouse ? Theme.surface3 : Theme.surface2)
            border.color: active ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55) : Theme.line
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.durFast } }

            Text {
                id: lbl
                anchors.centerIn: parent
                text: modelData
                color: active ? Theme.accent : Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                font.weight: active ? Font.DemiBold : Font.Medium
            }

            MouseArea {
                id: pillArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectionChanged(modelData)
            }
        }
    }
}
