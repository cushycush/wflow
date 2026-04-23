pragma Singleton
import QtQuick

// Runtime layout switcher for the workflow editor page. Cycle with Ctrl+;
QtObject {
    // 0=stack 1=timeline 2=split 3=grouped 4=cards
    property int variant: 0

    readonly property var labels: [
        "STACK",
        "TIMELINE",
        "SPLIT",
        "GROUPED",
        "CARDS"
    ]

    readonly property string label: labels[variant]
    readonly property string nextLabel: labels[(variant + 1) % labels.length]

    function cycle() {
        variant = (variant + 1) % labels.length
    }
}
