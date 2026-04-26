import QtQuick
import QtQuick.Controls
import Wflow

// Top bar inside the main pane. Title on the left, contextual actions on the right.
// When `titleEditable` / `subtitleEditable` are true, the matching label renders
// as a TextField (borderless until focus) instead of plain Text. Focus loss or
// Return emits `titleCommitted` / `subtitleCommitted`.
Rectangle {
    id: root
    color: Theme.bg
    height: 56
    property string title: ""
    property string subtitle: ""
    property bool titleEditable: false
    property bool subtitleEditable: false
    default property alias actions: actionRow.data

    signal titleCommitted(string newTitle)
    signal subtitleCommitted(string newSubtitle)

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

            // Title — plain Text when read-only, TextField when editable.
            Text {
                visible: !root.titleEditable
                text: root.title
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                width: parent.width
            }
            TextField {
                id: titleField
                visible: root.titleEditable
                width: parent.width
                text: root.title
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                selectByMouse: true
                leftPadding: 0
                rightPadding: 0
                topPadding: 0
                bottomPadding: 0
                background: Rectangle {
                    color: "transparent"
                    border.color: titleField.activeFocus ? Theme.accent : "transparent"
                    border.width: 1
                    radius: 2
                }
                // Resync from upstream when not actively focused.
                property string upstream: root.title
                onUpstreamChanged: if (!activeFocus) text = upstream
                // Auto-commit on every keystroke. Save is debounced on
                // the parent page; dirty indicator reflects the change
                // immediately so the user knows their edit is tracked.
                function _commit() {
                    if (text !== root.title) root.titleCommitted(text)
                }
                onTextEdited: _commit()
                onEditingFinished: _commit()
            }

            // Subtitle.
            Text {
                visible: !root.subtitleEditable && root.subtitle.length > 0
                text: root.subtitle
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                elide: Text.ElideRight
                width: parent.width
            }
            TextField {
                id: subtitleField
                visible: root.subtitleEditable
                width: parent.width
                text: root.subtitle
                placeholderText: "add a subtitle…"
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                selectByMouse: true
                leftPadding: 0
                rightPadding: 0
                topPadding: 0
                bottomPadding: 0
                background: Rectangle {
                    color: "transparent"
                    border.color: subtitleField.activeFocus ? Theme.accent : "transparent"
                    border.width: 1
                    radius: 2
                }
                property string upstream: root.subtitle
                onUpstreamChanged: if (!activeFocus) text = upstream
                function _commit() {
                    if (text !== root.subtitle) root.subtitleCommitted(text)
                }
                onTextEdited: _commit()
                onEditingFinished: _commit()
            }
        }

        Row {
            id: actionRow
            spacing: 8
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
