pragma Singleton
import QtQuick

// Runtime library-layout switcher. Cycle with Ctrl+,
// Six variants so we can compare and settle on one.
QtObject {
    // 0=grid_rich 1=list_dense 2=mosaic 3=hero_grid 4=timeline 5=compact
    // HERO + GRID is the picked default.
    property int variant: 3

    readonly property var labels: [
        "GRID RICH",
        "LIST DENSE",
        "MOSAIC",
        "HERO + GRID",
        "TIMELINE",
        "COMPACT"
    ]

    readonly property string label: labels[variant]
    readonly property string nextLabel: labels[(variant + 1) % labels.length]

    function cycle() {
        variant = (variant + 1) % labels.length
    }
}
