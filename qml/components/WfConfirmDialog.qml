import QtQuick
import QtQuick.Controls
import Wflow

// Destructive flag swaps the confirm button to red.
Dialog {
    id: root
    modal: true
    closePolicy: Popup.CloseOnEscape
    width: 420
    anchors.centerIn: parent

    property string message: ""
    property string confirmText: "OK"
    property bool destructive: false

    signal confirmed()

    header: Item { width: 0; height: 0 }
    footer: Item { width: 0; height: 0 }

    background: Rectangle {
        color: Theme.surface
        radius: Theme.radiusMd
        border.color: Theme.line
        border.width: 1
    }

    onAccepted: root.confirmed()

    // Column-direct contentItem so implicitHeight propagates; an
    // Item wrapper would zero it and long messages spill past bg.
    padding: 24
    contentItem: Column {
        spacing: 16

        Column {
            width: parent.width
            spacing: 6
            Text {
                text: root.title
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
                width: parent.width
            }
            Text {
                visible: root.message.length > 0
                text: root.message
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                lineHeight: 1.4
                wrapMode: Text.WordWrap
                width: parent.width
            }
        }

        Row {
            width: parent.width
            spacing: 8
            layoutDirection: Qt.RightToLeft

            Button {
                id: confirmBtn
                text: root.confirmText
                topPadding: 8
                bottomPadding: 8
                leftPadding: 14
                rightPadding: 14

                background: Rectangle {
                    radius: Theme.radiusSm
                    color: root.destructive
                        ? (confirmBtn.hovered ? Qt.lighter(Theme.err, 1.1) : Theme.err)
                        : (confirmBtn.hovered ? Theme.accentHi : Theme.accent)
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                }
                contentItem: Text {
                    text: confirmBtn.text
                    color: "white"
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: root.accept()
            }
            SecondaryButton {
                text: "Cancel"
                onClicked: root.reject()
            }
        }
    }
}
