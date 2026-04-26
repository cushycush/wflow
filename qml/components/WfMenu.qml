import QtQuick
import QtQuick.Controls
import Wflow

// Default Menu inherits the system Qt style; reskin to match our theme.
Menu {
    id: root
    padding: 4

    background: Rectangle {
        implicitWidth: 180
        color: Theme.surface2
        border.color: Theme.line
        border.width: 1
        radius: Theme.radiusMd
    }
}
