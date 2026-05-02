import QtQuick
import QtQuick.Controls
import Wflow

// kind drives the hero glyph: "empty" | "first-run" | "error".
Item {
    id: root
    property string title: ""
    property string description: ""
    property string actionLabel: ""
    property string secondaryActionLabel: ""
    property string kind: "empty"   // "empty" | "first-run" | "error"
    signal actionClicked()
    signal secondaryActionClicked()

    Column {
        anchors.centerIn: parent
        spacing: 14
        width: Math.min(parent.width - 80, 480)

        Rectangle {
            visible: root.kind === "first-run"
            width: 56; height: 56; radius: 28
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
            border.color: Theme.accent
            border.width: 2
            anchors.horizontalCenter: parent.horizontalCenter
            Text {
                anchors.centerIn: parent
                text: "w"
                color: Theme.accent
                font.family: Theme.familyDisplay
                font.pixelSize: 28
                font.weight: Font.DemiBold
            }
        }

        Text {
            text: root.title
            color: Theme.text
            font.family: Theme.familyDisplay
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

        Row {
            visible: root.actionLabel.length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 10

            PrimaryButton {
                text: root.actionLabel
                topPadding: 10
                bottomPadding: 10
                leftPadding: 20
                rightPadding: 20
                onClicked: root.actionClicked()
            }
            SecondaryButton {
                visible: root.secondaryActionLabel.length > 0
                text: root.secondaryActionLabel
                topPadding: 10
                bottomPadding: 10
                leftPadding: 20
                rightPadding: 20
                onClicked: root.secondaryActionClicked()
            }
        }
    }
}
