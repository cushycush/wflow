import QtQuick
import QtQuick.Controls
import Wflow

// Search input for the Explore tab. Focus-first on page entry.
// Ctrl+K from anywhere in the app should route here eventually.
Rectangle {
    id: root
    property alias text: field.text
    property string placeholder: "Search workflows, tags, authors…"
    signal submitted(string text)

    height: 44
    radius: 22
    color: field.activeFocus ? Theme.surface2 : Theme.surface
    border.color: field.activeFocus
        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.5)
        : Theme.line
    border.width: 1
    Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

    Text {
        id: glyph
        text: "⌕"
        color: Theme.text3
        font.family: Theme.familyBody
        font.pixelSize: 18
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 18
    }

    TextField {
        id: field
        anchors.left: glyph.right
        anchors.leftMargin: 10
        anchors.right: hint.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        placeholderText: root.placeholder
        placeholderTextColor: Theme.text3
        color: Theme.text
        font.family: Theme.familyBody
        font.pixelSize: Theme.fontBase
        background: null
        selectionColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.3)
        selectedTextColor: Theme.text
        onAccepted: root.submitted(text)
    }

    Row {
        id: hint
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Rectangle {
            width: kbdTxt.implicitWidth + 10
            height: 22
            radius: 4
            color: Theme.surface3
            border.color: Theme.lineSoft
            border.width: 1
            anchors.verticalCenter: parent.verticalCenter
            Text {
                id: kbdTxt
                anchors.centerIn: parent
                text: "Ctrl+K"
                color: Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: 10
            }
        }
    }
}
