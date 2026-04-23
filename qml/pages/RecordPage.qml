import QtQuick
import QtQuick.Controls
import Wflow

// Record Mode — 5 layout variants, cycle with Ctrl+'
// Picks a starting phase of "armed" in the demo so animations read.
Item {
    id: root
    property string phase: "armed"
    property int totalMs: 3420
    // Mock events so the variants have content to show.
    property var events: [
        { t_ms: 120,  category: "key",      body: "Super + 1" },
        { t_ms: 480,  category: "focus",    body: "Firefox" },
        { t_ms: 1230, category: "key",      body: "Ctrl + L" },
        { t_ms: 1680, category: "type",     body: "hyprland wiki" },
        { t_ms: 2010, category: "key",      body: "Return" },
        { t_ms: 2410, category: "click",    body: "(pixel 612, 208)" },
        { t_ms: 2950, category: "scroll",   body: "dy +180" },
        { t_ms: 3420, category: "shell",    body: "wl-copy < /tmp/notes" }
    ]

    signal armRequested()
    signal stopRequested()

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: "Record"
            subtitle: "perform once, wflow transcribes it into a workflow · " + RecordLayout.label
        }

        // Variant host
        Item {
            id: host
            width: parent.width
            height: parent.height - tb.height

            Loader {
                id: variantLoader
                anchors.fill: parent

                sourceComponent: {
                    switch (RecordLayout.variant) {
                    case 0: return classicComp
                    case 1: return radialComp
                    case 2: return theaterComp
                    case 3: return stripComp
                    case 4: return ambientComp
                    }
                    return classicComp
                }

                opacity: 0
                Component.onCompleted: opacity = 1
                onSourceComponentChanged: {
                    opacity = 0
                    fadeIn.restart()
                }
                Timer {
                    id: fadeIn
                    interval: 30
                    onTriggered: variantLoader.opacity = 1
                }
                Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            }

            Component {
                id: classicComp
                ClassicRec {
                    phase: root.phase
                    totalMs: root.totalMs
                    events: root.events
                    onArmRequested: root.armRequested()
                    onStopRequested: root.stopRequested()
                }
            }
            Component {
                id: radialComp
                RadialRec {
                    phase: root.phase
                    totalMs: root.totalMs
                    events: root.events
                    onArmRequested: root.armRequested()
                    onStopRequested: root.stopRequested()
                }
            }
            Component {
                id: theaterComp
                TheaterRec {
                    phase: root.phase
                    totalMs: root.totalMs
                    events: root.events
                    onArmRequested: root.armRequested()
                    onStopRequested: root.stopRequested()
                }
            }
            Component {
                id: stripComp
                StripRec {
                    phase: root.phase
                    totalMs: root.totalMs
                    events: root.events
                    onArmRequested: root.armRequested()
                    onStopRequested: root.stopRequested()
                }
            }
            Component {
                id: ambientComp
                AmbientRec {
                    phase: root.phase
                    totalMs: root.totalMs
                    events: root.events
                    onArmRequested: root.armRequested()
                    onStopRequested: root.stopRequested()
                }
            }
        }
    }
}
