pragma Singleton
import QtQuick

// User preference for the local Library view.
QtObject {
    // 0=grid 1=list
    property int variant: 0

    readonly property var labels: ["Grid", "List"]
    readonly property var hints: [
        "Cards in a grid. Good default.",
        "Dense rows. Best with lots of workflows."
    ]

    readonly property string label: labels[variant]

    function cycle() { variant = (variant + 1) % labels.length }
    function set(i) { if (i >= 0 && i < labels.length) variant = i }
}
