import QtQuick
import QtQuick.Controls
import Wflow

// A single workflow entry in the sidebar list.
Rectangle {
    id: root
    property string title: ""
    property int stepCount: 0
    property bool selected: false
    signal clicked()

    height: 36
    radius: Theme.radiusSm
    color: root.selected
        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.10)
        : (mouseArea.containsMouse ? Theme.surface2 : "transparent")

    // The 2px accent rail for the selected row — the one place in the app
    // where this pattern appears, on purpose: macOS source list convention.
    Rectangle {
        visible: root.selected
        x: 0
        y: 6
        width: 2
        height: parent.height - 12
        radius: 1
        color: Theme.accent
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 10
        spacing: 8

        Text {
            text: root.title || "untitled"
            color: root.selected ? Theme.text : Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontSm
            font.weight: root.selected ? Font.Medium : Font.Normal
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - countLabel.width - 8
            elide: Text.ElideRight
        }

        Text {
            id: countLabel
            text: root.stepCount
            color: Theme.text3
            font.family: Theme.familyMono
            font.pixelSize: Theme.fontXs
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
