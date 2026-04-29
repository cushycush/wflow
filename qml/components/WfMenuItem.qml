import QtQuick
import QtQuick.Controls
import Wflow

// MenuItem styled to match wflow's dark theme. Hover raises a
// subtle accent wash; text uses the body font and Theme.text.
//
// Set `destructive: true` to render the entry in the err palette
// (red) — the convention for "Delete <thing>" entries so they read
// as dangerous at a glance.
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
