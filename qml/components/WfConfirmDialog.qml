import QtQuick
import QtQuick.Controls
import Wflow

// Confirmation dialog for destructive actions (Delete workflow,
// Discard changes, etc.). Built with the same chrome as the
// recorder save prompt and NewWorkflowDialog so the styling stays
// consistent. Primary button is red on a destructive confirm.
//
// Usage:
//   WfConfirmDialog {
//       id: deleteDialog
//       title: "Delete workflow?"
//       message: "This permanently removes 'Open dev setup' from your library."
//       confirmText: "Delete"
//       destructive: true
//       onConfirmed: libCtrl.remove(targetId)
//   }
//   ...
//   deleteDialog.open()
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

    // Suppress Dialog's default system-styled header bar — we render
    // our own inside contentItem and don't want the light bar
    // sitting above it.
    header: Item { width: 0; height: 0 }
    footer: Item { width: 0; height: 0 }

    background: Rectangle {
        color: Theme.surface
        radius: Theme.radiusMd
        border.color: Theme.line
        border.width: 1
    }

    onAccepted: root.confirmed()

    contentItem: Item {
        anchors.fill: parent

        Column {
            anchors.fill: parent
            anchors.margins: 24
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
                    wrapMode: Text.WordWrap
                    width: parent.width
                }
            }

            Row {
                width: parent.width
                spacing: 8
                layoutDirection: Qt.RightToLeft

                // Inline destructive button — red instead of accent
                // when destructive is true. Falls back to the same
                // accent fill PrimaryButton uses otherwise.
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
}
