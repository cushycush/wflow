import QtQuick
import QtQuick.Controls
import Wflow

// Quiet surface button with a hairline border. Used for every non-dominant
// action — Share, Record, Cancel, Close — so coral accent stays reserved.
// Pill shape + line-strong border on hover mirrors wflows.com .btn-ghost.
Button {
    id: root
    topPadding: 8
    bottomPadding: 8
    leftPadding: 16
    rightPadding: 16
    activeFocusOnTab: true

    background: Rectangle {
        radius: Theme.radiusPill
        color: root.hovered ? Theme.surface2 : Theme.surface
        border.color: root.hovered ? Theme.lineStrong : Theme.line
        border.width: 1
        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
        FocusRing { target: root }
    }

    contentItem: Text {
        text: root.text
        color: root.enabled ? Theme.text : Theme.text3
        font.family: Theme.familyBody
        font.pixelSize: Theme.fontSm
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
