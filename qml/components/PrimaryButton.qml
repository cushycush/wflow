import QtQuick
import QtQuick.Controls
import Wflow

// Accent-filled button used for the dominant action on a page (New workflow,
// Run, Import, etc.). One per page at most — coral accent is load-bearing.
// Pill shape mirrors wflows.io .btn-primary so the chrome reads from the
// same family as the marketing site.
Button {
    id: root
    topPadding: 9
    bottomPadding: 9
    leftPadding: 18
    rightPadding: 18
    activeFocusOnTab: true

    background: Rectangle {
        radius: Theme.radiusPill
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
        font.letterSpacing: 0.1
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
