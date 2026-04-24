import QtQuick
import QtQuick.Controls
import Wflow

// Small rounded pill that colors itself by action kind.
// Usage: CategoryChip { kind: "key" }
Rectangle {
    id: root
    property string kind: "wait"

    readonly property color _c: Theme.catFor(kind)

    implicitWidth: label.implicitWidth + 16
    implicitHeight: 20
    radius: 4
    color: Theme.wash(_c, 0.16)

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
