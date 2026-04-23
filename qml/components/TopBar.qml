import QtQuick
import QtQuick.Controls
import Wflow

// Top bar inside the main pane. Title on the left, contextual actions on the right.
// Renders nothing if `title` is empty (used for record / empty-library states).
Rectangle {
    id: root
    color: Theme.bg
    height: 56
    property string title: ""
    property string subtitle: ""
    default property alias actions: actionRow.data

    // Bottom hairline
    Rectangle {
        height: 1
        color: Theme.lineSoft
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: 24
        anchors.rightMargin: 16
        spacing: 16

        Column {
            width: parent.width - actionRow.width - 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                text: root.title
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                width: parent.width
            }
            Text {
                text: root.subtitle
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                visible: text.length > 0
                elide: Text.ElideRight
                width: parent.width
            }
        }

        Row {
            id: actionRow
            spacing: 8
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
