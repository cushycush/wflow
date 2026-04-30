import QtQuick
import QtQuick.Controls
import Wflow

// destructive: true renders in err palette for "Delete X" entries.
MenuItem {
    id: root
    implicitHeight: 32
    leftPadding: 12
    rightPadding: 12

    property bool destructive: false

    contentItem: Text {
        text: root.text
        color: root.destructive ? Theme.err : Theme.text
        font.family: Theme.familyBody
        font.pixelSize: Theme.fontSm
        verticalAlignment: Text.AlignVCenter
    }

    background: Rectangle {
        radius: 4
        color: root.highlighted
            ? (root.destructive
                ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                : Theme.accentWash(0.18))
            : "transparent"
    }
}
