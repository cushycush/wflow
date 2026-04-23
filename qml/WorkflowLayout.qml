pragma Singleton
import QtQuick

// Editor layout preference. 5 layouts chosen so different kinds of workflows
// feel natural: a long shell recipe reads best as a stack, a scripted UI test
// as a timeline, a complex workflow with options as split, and so on.
//
// Switch in-product via the segmented control on the workflow page, or cycle
// with Ctrl+;
QtObject {
    // 0=stack 1=timeline 2=split 3=grouped 4=cards
    property int variant: 0

    readonly property var labels: [
        "Stack",
        "Timeline",
        "Split",
        "Groups",
        "Cards"
    ]

    readonly property var hints: [
        "Vertical list. Good default.",
        "Horizontal pipeline with a playhead.",
        "Step list + inspector pane.",
        "Bucketed by phase (setup / input / output).",
        "Large step cards."
    ]

    readonly property string label: labels[variant]
    readonly property string nextLabel: labels[(variant + 1) % labels.length]

    function cycle() {
        variant = (variant + 1) % labels.length
    }

    function set(i) {
        if (i >= 0 && i < labels.length) variant = i
    }
}
