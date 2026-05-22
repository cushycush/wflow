import QtQuick
import QtQuick.Controls
import Wflow

// Read-only KDL view of the current workflow. Slides in from the right
// of the canvas. The text re-encodes as the user edits, so the source
// you see always matches what would hit disk on the next save.
Item {
    id: root

    property string kdlText: ""
    property string copyHint: ""
    readonly property bool hasText: kdlText.length > 0

    signal closeRequested()
    signal copyRequested()

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusMd
        color: Theme.surface
        border.color: Theme.lineSoft
        border.width: 1

        // Header
        Item {
            id: headerBar
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 1
            height: 44

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Text {
                    text: "SOURCE"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    font.letterSpacing: 1.2
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    width: 1; height: 12
                    color: Theme.lineSoft
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "read-only"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Text {
                    visible: root.copyHint.length > 0
                    text: root.copyHint
                    color: Theme.ok
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }
                IconButton {
                    iconText: "⧉"
                    text: "Copy"
                    compact: true
                    enabled: root.hasText
                    onClicked: root.copyRequested()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "Copy the full KDL source to the clipboard"
                }
                IconButton {
                    iconText: "×"
                    compact: true
                    onClicked: root.closeRequested()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "Close the source pane"
                }
            }
        }

        Rectangle {
            anchors.top: headerBar.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 1
            anchors.rightMargin: 1
            height: 1
            color: Theme.lineSoft
        }

        // Body
        ScrollView {
            id: scroll
            anchors.top: headerBar.bottom
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 1
            anchors.margins: 1
            clip: true

            TextArea {
                id: body
                text: root.kdlText
                readOnly: true
                wrapMode: TextArea.NoWrap
                selectByMouse: true
                selectByKeyboard: true
                persistentSelection: true
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontSm
                color: Theme.text
                selectionColor: Theme.accentDim
                selectedTextColor: Theme.text
                leftPadding: 16
                rightPadding: 16
                topPadding: 12
                bottomPadding: 16
                background: null
                placeholderText: root.hasText ? "" : "(no workflow loaded)"
                placeholderTextColor: Theme.text3
            }
        }
    }
}
