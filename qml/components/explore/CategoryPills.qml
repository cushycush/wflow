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
            id: pill
            readonly property bool active: modelData === root.selected
            width: lbl.implicitWidth + 22
            height: 30
            // Pill: half-height keeps the capsule shape without the
            // arbitrary "15" that drifted off the 6/8 radius grid.
            radius: height / 2
            color: active
                ? Theme.accentWash(0.18)
                : (pillArea.containsMouse ? Theme.surface3 : Theme.surface2)
            border.color: active ? Theme.accentWash(0.55) : Theme.line
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

            activeFocusOnTab: true
            Keys.onReturnPressed: root.selectionChanged(modelData)
            Keys.onEnterPressed:  root.selectionChanged(modelData)
            Keys.onSpacePressed:  root.selectionChanged(modelData)
            FocusRing { }

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
                onClicked: {
                    pill.forceActiveFocus()
                    root.selectionChanged(modelData)
                }
            }
        }
    }
}
