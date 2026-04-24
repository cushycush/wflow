import QtQuick
import QtQuick.Controls
import Wflow

// Accent-filled button used for the dominant action on a page (New workflow,
// Run, Import, etc.). One per page at most — amber accent is load-bearing.
Button {
    id: root
    topPadding: 8
    bottomPadding: 8
    leftPadding: 14
    rightPadding: 14
    activeFocusOnTab: true

    background: Rectangle {
        radius: Theme.radiusSm
        color: !root.enabled
            ? Theme.surface3
            : (root.hovered ? Theme.accentHi : Theme.accent)
        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
        FocusRing { target: root }
    }

    contentItem: Text {
        text: root.text
        color: root.enabled ? Theme.accentText : Theme.text3
        font.family: Theme.familyBody
        font.pixelSize: Theme.fontSm
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
