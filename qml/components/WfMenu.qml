import QtQuick
import QtQuick.Controls
import Wflow

// Drop-in replacement for QtQuick.Controls.Menu with a background +
// padding that matches the rest of the app (dark surface + line
// border + radius). The default Menu chrome inherits the system
// Qt style which clashes hard with our dark theme.
//
// Use alongside WfMenuItem for the entries.
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
