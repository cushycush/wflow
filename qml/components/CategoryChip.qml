import QtQuick
import QtQuick.Controls
import Wflow

// Small rounded pill that colors itself by action kind.
// Usage: CategoryChip { kind: "key" }
Rectangle {
    id: root
    property string kind: "wait"

    readonly property var _colors: ({
        "key": Theme.catKey,
        "type": Theme.catType,
        "click": Theme.catClick,
        "move": Theme.catMove,
        "scroll": Theme.catScroll,
        "focus": Theme.catFocus,
        "wait": Theme.catWait,
        "shell": Theme.catShell,
        "notify": Theme.catNotify,
        "clipboard": Theme.catClip,
        "note": Theme.catNote
    })
    readonly property color _c: _colors[kind] || Theme.catWait

    implicitWidth: label.implicitWidth + 16
    implicitHeight: 20
    radius: 4
    color: Qt.rgba(_c.r, _c.g, _c.b, 0.16)

    Text {
        id: label
        anchors.centerIn: parent
        text: kind.toUpperCase()
        color: _c
        font.family: Theme.familyBody
        font.pixelSize: 10
        font.weight: Font.Bold
        font.letterSpacing: 0.6
    }
}
