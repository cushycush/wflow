import QtQuick
import QtQuick.Controls
import Wflow

// A compact, icon-first button with an optional text label.
// Sits on `surface` by default, elevates by 1 step on hover.
Button {
    id: root
    property string iconText: ""   // the unicode glyph or letter to render
    property color iconColor: Theme.text2
    property color hoverColor: Theme.text
    property color activeColor: Theme.accent
    property bool active: false
    property bool compact: false

    implicitHeight: compact ? 28 : 32
    implicitWidth: text.length > 0 ? (contentLabel.implicitWidth + 28) : implicitHeight
    padding: 0
    topPadding: 0
    bottomPadding: 0
    leftPadding: compact ? 8 : 10
    rightPadding: compact ? 8 : 10

    background: Rectangle {
        radius: Theme.radiusSm
        color: root.active
            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.14)
            : (root.hovered ? Theme.surface2 : "transparent")
    }

    contentItem: Row {
        spacing: 8
        anchors.verticalCenter: parent.verticalCenter
        leftPadding: 0

        Text {
            id: iconLabel
            text: root.iconText
            color: root.active ? root.activeColor : (root.hovered ? root.hoverColor : root.iconColor)
            font.family: Theme.familyBody
            font.pixelSize: 16
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: contentLabel
            text: root.text
            visible: root.text.length > 0
            color: root.active ? root.activeColor : (root.hovered ? root.hoverColor : Theme.text2)
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontSm
            font.weight: Font.Medium
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
