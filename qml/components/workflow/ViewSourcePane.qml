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
                SecondaryButton {
                    text: "⧉ Copy"
                    topPadding: 4
                    bottomPadding: 4
                    leftPadding: 12
                    rightPadding: 12
                    enabled: root.hasText
                    onClicked: root.copyRequested()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "Copy the full KDL source to the clipboard"
                }
                Item { width: 4; height: 1 }
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

        // Body. Plain Flickable + TextEdit because Controls TextArea
        // inside a ScrollView defers its initial layout until the user
        // clicks in — the text exists but doesn't paint until focus.
        Flickable {
            id: scroll
            anchors.top: headerBar.bottom
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 1
            anchors.leftMargin: 1
            anchors.rightMargin: 1
            anchors.bottomMargin: 1
            clip: true
            contentWidth: body.contentWidth + body.leftPadding + body.rightPadding
            contentHeight: body.contentHeight + body.topPadding + body.bottomPadding
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

            TextEdit {
                id: body
                width: scroll.contentWidth
                height: scroll.contentHeight
                text: root.hasText ? root.kdlText : "(no workflow loaded)"
                readOnly: true
                wrapMode: TextEdit.NoWrap
                selectByMouse: true
                selectByKeyboard: true
                persistentSelection: true
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontSm
                color: root.hasText ? Theme.text : Theme.text3
                selectionColor: Theme.accentDim
                selectedTextColor: Theme.text
                leftPadding: 16
                rightPadding: 16
                topPadding: 12
                bottomPadding: 16
            }
        }
    }
}
