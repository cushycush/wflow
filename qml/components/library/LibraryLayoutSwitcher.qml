import QtQuick
import QtQuick.Controls
import Wflow

// Segmented control for the library's layout preference. Lives in the
// library page header. Ctrl+, cycles.
Rectangle {
    id: root
    width: seg.implicitWidth + 4
    height: 30
    radius: Theme.radiusSm
    color: Theme.surface2
    border.color: Theme.line
    border.width: 1

    Row {
        id: seg
        anchors.centerIn: parent
        spacing: 0

        Repeater {
            model: LibraryLayout.labels
            delegate: Rectangle {
                readonly property bool active: index === LibraryLayout.variant
                width: cellLbl.implicitWidth + 18
                height: 24
                radius: 4
                color: active
                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                    : (cellArea.containsMouse ? Theme.surface3 : "transparent")
                anchors.verticalCenter: parent.verticalCenter

                Behavior on color { ColorAnimation { duration: Theme.durFast } }

                Text {
                    id: cellLbl
                    anchors.centerIn: parent
                    text: modelData
                    color: active ? Theme.accent : Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: active ? Font.DemiBold : Font.Medium
                }

                ToolTip.visible: cellArea.containsMouse
                ToolTip.delay: 600
                ToolTip.text: LibraryLayout.hints[index] + "  ·  Ctrl+,"

                MouseArea {
                    id: cellArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: LibraryLayout.set(index)
                }
            }
        }
    }
}
