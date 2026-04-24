import QtQuick
import Wflow

// Drop-in accessibility focus visual. Anchors itself just outside its parent
// and paints a 2-px accent ring with a 2-px offset whenever that parent has
// keyboard focus. Sits at a high z so hover backgrounds don't cover it.
//
// Usage:
//     Rectangle {
//         activeFocusOnTab: true
//         Keys.onReturnPressed: doAction()
//         FocusRing { }
//     }
//
// If the parent is itself a non-Rectangle (Item, FocusScope) pass the
// `radius` explicitly.
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
