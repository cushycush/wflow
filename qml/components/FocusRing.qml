import QtQuick
import Wflow

// Pass radiusOverride when the parent isn't a Rectangle.
Rectangle {
    id: root
    property Item target: parent
    property real radiusOverride: -1

    readonly property real _r: radiusOverride >= 0
        ? radiusOverride
        : (target && target.radius !== undefined ? target.radius + 2 : Theme.radiusSm + 2)

    anchors.fill: parent
    anchors.margins: -2
    radius: _r
    color: "transparent"
    border.color: Theme.accent
    border.width: 2
    visible: target && target.activeFocus
    z: 1000
}
