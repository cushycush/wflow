import QtQuick
import QtQuick.Controls
import Wflow

// A simple centered empty state with title + description + optional action.
Item {
    id: root
    property string title: ""
    property string description: ""
    property string actionLabel: ""
    signal actionClicked()

    Column {
        anchors.centerIn: parent
        spacing: 10
        width: Math.min(parent.width - 80, 440)

        Text {
            text: root.title
            color: Theme.text
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontLg
            font.weight: Font.DemiBold
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            width: parent.width
            wrapMode: Text.WordWrap
        }

        Text {
            text: root.description
            color: Theme.text3
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontSm
            lineHeight: 1.5
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            width: parent.width
            wrapMode: Text.WordWrap
        }

        Button {
            visible: root.actionLabel.length > 0
            text: root.actionLabel
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: 10
            bottomPadding: 10
            leftPadding: 20
            rightPadding: 20
            onClicked: root.actionClicked()

            background: Rectangle {
                radius: Theme.radiusSm
                color: parent.hovered ? Theme.accentHi : Theme.accent
            }
            contentItem: Text {
                text: parent.text
                color: "#1a1208"
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
