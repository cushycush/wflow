import QtQuick
import QtQuick.Controls
import Wflow

// One dominant action per page; coral accent is load-bearing.
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
