import QtQuick
import QtQuick.Controls
import Wflow

// Small rounded pill that colors itself by action kind.
// Usage: CategoryChip { kind: "key" }
Rectangle {
    id: root
    property string kind: "wait"

    readonly property color _c: Theme.catFor(kind)

    implicitWidth: label.implicitWidth + 18
    implicitHeight: 22
    radius: Theme.radiusPill
    color: Theme.wash(_c, 0.16)
    border.color: Theme.wash(_c, 0.36)
    border.width: 1

    Text {
        id: label
        anchors.centerIn: parent
        text: kind.toUpperCase()
        color: _c
        font.family: Theme.familyMono
        font.pixelSize: 10
        font.weight: Font.Medium
        font.letterSpacing: 0.6
    }
}
