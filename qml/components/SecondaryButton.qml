import QtQuick
import QtQuick.Controls
import Wflow

// Quiet surface-2 button with a hairline border. Used for every non-dominant
// action — Share, Record, Cancel, Close — so amber accent stays reserved.
Button {
    id: root
    topPadding: 8
    bottomPadding: 8
    leftPadding: 14
    rightPadding: 14
    activeFocusOnTab: true

    background: Rectangle {
        radius: Theme.radiusSm
        color: root.hovered ? Theme.surface3 : Theme.surface2
        border.color: Theme.line
        border.width: 1
        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
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
