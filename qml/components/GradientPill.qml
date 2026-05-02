import QtQuick
import Wflow

// Despite the name, this is now a flat chip; the gradient skin
// predates the warm-coral palette. icon is a presence sentinel only;
// the actual glyph comes from CategoryIcon.catGlyph(kind).
Rectangle {
    id: root

    property string kind: "key"
    property string text: ""
    property string icon: ""
    property string trailingIcon: ""
    property bool clickable: false

    signal clicked()

    implicitHeight: 36
    implicitWidth: (iconChip.visible ? iconChip.width + 8 : 0) + valueText.implicitWidth + 24
    radius: Theme.radiusMd
    color: Theme.surface
    border.color: Theme.lineSoft
    border.width: 1

    CategoryIcon {
        id: iconChip
        visible: root.icon.length > 0
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        kind: root.kind
        size: 22
        width: visible ? size : 0
    }

    // Value text fills the remaining width and elides on overflow.
    // Mono font because the content is almost always a command, key
    // chord, or path — same register as wflows.com's .kdl-block
    // values, just inline.
    Text {
        id: valueText
        anchors.left: iconChip.right
        anchors.leftMargin: iconChip.visible ? 8 : 8
        anchors.right: trailingChip.visible ? trailingChip.left : parent.right
        anchors.rightMargin: trailingChip.visible ? 6 : 12
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        color: Theme.text
        font.family: Theme.familyMono
        font.pixelSize: Theme.fontSm
        font.weight: Font.Medium
        elide: Text.ElideRight
    }

    Rectangle {
        id: trailingChip
        visible: root.trailingIcon.length > 0
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        width: 22; height: 22
        radius: Theme.radiusSm
        color: Theme.surface2
        border.color: Theme.lineSoft
        border.width: 1
        Text {
            anchors.centerIn: parent
            text: root.trailingIcon
            color: Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontXs
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.clickable
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }
}
