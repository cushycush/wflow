import QtQuick
import QtQuick.Controls
import Wflow

// A compact segmented pill. Give it items as `[{ label, value }, …]` and
// a `selected` value; it fires `activated(value)` when a cell is clicked
// or Enter/Space-pressed. Focus-ring-ready. (The signal isn't named
// `selectedChanged` on purpose — that collides with the QML-generated
// change handler for the `selected` property.)
Rectangle {
    id: root
    property var items: []
    property var selected
    property color accent: Theme.accent   // tint override (on-error uses cat color)
    signal activated(var value)

    implicitWidth: seg.implicitWidth + 6
    implicitHeight: 28
    radius: 4
    color: Theme.surface2
    border.color: Theme.line
    border.width: 1

    Row {
        id: seg
        anchors.centerIn: parent
        spacing: 0

        Repeater {
            model: root.items
            delegate: Rectangle {
                id: cell
                readonly property bool active: root.selected === modelData.value
                width: cellLbl.implicitWidth + 18
                height: 22
                radius: 3
                color: active
                    ? Theme.wash(root.accent, 0.18)
                    : (cellArea.containsMouse ? Theme.surface3 : "transparent")
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                activeFocusOnTab: true
                Keys.onReturnPressed: root.activated(modelData.value)
                Keys.onEnterPressed:  root.activated(modelData.value)
                Keys.onSpacePressed:  root.activated(modelData.value)
                FocusRing { }

                Text {
                    id: cellLbl
                    anchors.centerIn: parent
                    text: modelData.label
                    color: active ? root.accent : Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: active ? Font.DemiBold : Font.Medium
                }

                MouseArea {
                    id: cellArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        cell.forceActiveFocus()
                        root.activated(modelData.value)
                    }
                }
            }
        }
    }
}
