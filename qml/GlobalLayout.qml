pragma Singleton
import QtQuick

// Runtime shell/chrome switcher. Controls whether the app has a sidebar,
// a rail, a top bar, or something else. Cycle with Ctrl+[
QtObject {
    // 0=sidebar 1=rail 2=topbar 3=hybrid 4=floating
    property int variant: 0

    readonly property var labels: [
        "SIDEBAR",
        "RAIL",
        "TOP BAR",
        "HYBRID",
        "FLOATING"
    ]

    readonly property string label: labels[variant]
    readonly property string nextLabel: labels[(variant + 1) % labels.length]

    function cycle() {
        variant = (variant + 1) % labels.length
    }
}
