import QtQuick
import QtQuick.Controls
import Wflow

// MenuItem styled to match wflow's dark theme. Hover raises a
// subtle accent wash; text uses the body font and Theme.text.
MenuItem {
    id: root
    implicitHeight: 32
    leftPadding: 12
    rightPadding: 12

    contentItem: Text {
        text: root.text
        color: Theme.text
        font.family: Theme.familyBody
        font.pixelSize: Theme.fontSm
        verticalAlignment: Text.AlignVCenter
    }

    background: Rectangle {
        radius: 4
        color: root.highlighted
            ? Theme.accentWash(0.18)
            : "transparent"
    }
}
