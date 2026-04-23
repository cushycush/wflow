pragma Singleton
import QtQuick

// Runtime layout switcher for the Record page. Cycle with Ctrl+'
QtObject {
    // 0=classic 1=radial 2=theater 3=strip 4=ambient
    property int variant: 0

    readonly property var labels: [
        "CLASSIC",
        "RADIAL",
        "THEATER",
        "STRIP",
        "AMBIENT"
    ]

    readonly property string label: labels[variant]
    readonly property string nextLabel: labels[(variant + 1) % labels.length]

    function cycle() {
        variant = (variant + 1) % labels.length
    }
}
