import QtQuick
import QtQuick.Controls
import Wflow

// Record Mode — ambient layout.
// Picks a starting phase of "armed" in the demo so animations read.
Item {
    id: root
    property string phase: "armed"
    property int totalMs: 3420
    // Mock events so the layout has content to show.
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
            subtitle: "perform once, wflow transcribes it into a workflow"
        }

        AmbientRec {
            width: parent.width
            height: parent.height - tb.height
            phase: root.phase
            totalMs: root.totalMs
            events: root.events
            onArmRequested: root.armRequested()
            onStopRequested: root.stopRequested()
        }
    }
}
