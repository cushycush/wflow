import QtQuick
import QtQuick.Controls
import Wflow

// Right-side slide-in drawer for a community workflow.
// Shows step preview, safety banner for shell actions, Import + Dry run +
// Discussion. Closes on Esc or on the scrim.
FocusScope {
    id: root
    property var wf
    property bool open: false
    signal imported(string id)
    signal dryRunRequested(string id)
    signal closed()

    focus: open

    // Mock step generation from kinds, so every card has a preview without
    // the mock data having to list every step inline.
    readonly property var kindSummary: ({
        "key": "Press key chord",
        "type": "Type text",
        "click": "Click at",
        "move": "Move mouse",
        "scroll": "Scroll",
        "focus": "Focus window",
        "wait": "Wait",
        "shell": "Run shell command",
        "notify": "Show notification",
        "clipboard": "Clipboard",
        "note": "Note"
    })
    readonly property var kindValues: ({
        "key": ["Super + 1", "Ctrl + Shift + T", "Return", "Esc"],
        "type": ["hyprland wiki", "cd ~/projects && ls"],
        "shell": ["hyprctl dispatch exec 'kitty'", "wl-copy < /tmp/notes", "git log --oneline -20"],
        "focus": ["Firefox", "Slack", "Zoom", "kitty"],
        "notify": ["Started", "Connected", "Done"],
        "clipboard": ["paste"],
        "click": ["(pixel 612, 208)"],
        "scroll": ["dy +180"],
        "wait": ["220 ms", "500 ms"],
        "note": ["—"],
        "move": ["(400, 300)"]
    })

    function stepsFor(wf) {
        if (!wf || !wf.kinds) return []
        const pool = wf.kinds
        const total = wf.steps || pool.length
        const out = []
        for (let i = 0; i < total; i++) {
            const k = pool[i % pool.length]
            const values = kindValues[k] || ["—"]
            out.push({
                kind: k,
                summary: kindSummary[k] || k,
                value: values[i % values.length]
            })
        }
        return out
    }

    Keys.onEscapePressed: if (root.open) root.closed()

    // Scrim
    Rectangle {
        anchors.fill: parent
        color: "#000"
        opacity: root.open ? 0.45 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        MouseArea {
            anchors.fill: parent
            enabled: root.open
            onClicked: root.closed()
        }
    }

    // Drawer panel
    Rectangle {
        id: drawer
        width: Math.min(560, root.width - 40)
        height: root.height
        anchors.right: parent.right
        x: root.open ? root.width - width : root.width
        color: Theme.bg
        Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        // Left hairline
        Rectangle {
            width: 1
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            color: Theme.line
        }

        // Close
        Rectangle {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 14
            anchors.rightMargin: 14
            width: 32; height: 32; radius: 16
            color: closeArea.containsMouse ? Theme.surface2 : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.durFast } }
            Text {
                anchors.centerIn: parent
                text: "×"
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: 22
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.closed()
            }
        }

        ScrollView {
            anchors.fill: parent
            anchors.topMargin: 0
            anchors.bottomMargin: 88   // leave space for the action bar
            anchors.leftMargin: 1
            contentWidth: availableWidth
            clip: true

            Column {
                id: body
                width: parent.width
                topPadding: 28
                bottomPadding: 28
                leftPadding: 28
                rightPadding: 60
                spacing: 20

                // Category + author line
                Row {
                    spacing: 8

                    Rectangle {
                        readonly property color catColor: {
                            const k = root.wf && root.wf.kinds && root.wf.kinds.length > 0 ? root.wf.kinds[0] : "wait"
                            const t = ({
                                "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                                "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                                "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                                "clipboard": Theme.catClip, "note": Theme.catNote
                            })
                            return t[k] || Theme.catWait
                        }
                        width: chipLbl.implicitWidth + 14
                        height: 22
                        radius: 11
                        color: Qt.rgba(catColor.r, catColor.g, catColor.b, 0.14)
                        border.color: Qt.rgba(catColor.r, catColor.g, catColor.b, 0.5)
                        border.width: 1
                        Text {
                            id: chipLbl
                            anchors.centerIn: parent
                            text: root.wf ? root.wf.category : ""
                            color: parent.catColor
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            font.letterSpacing: 0.6
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.wf ? "by @" + root.wf.author : ""
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontSm
                    }
                }

                // Title
                Text {
                    text: root.wf ? root.wf.title : ""
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                    width: body.width - body.leftPadding - body.rightPadding
                    wrapMode: Text.WordWrap
                }

                Text {
                    text: root.wf ? root.wf.subtitle : ""
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontMd
                    lineHeight: 1.4
                    width: body.width - body.leftPadding - body.rightPadding
                    wrapMode: Text.WordWrap
                }

                // Metric strip
                Row {
                    spacing: 22

                    Column {
                        Text { text: root.wf ? root.wf.imports.toString() : "0"
                               color: Theme.text; font.family: Theme.familyBody
                               font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                        Text { text: "imports"; color: Theme.text3
                               font.family: Theme.familyMono; font.pixelSize: Theme.fontXs }
                    }
                    Column {
                        Text { text: root.wf ? root.wf.forks.toString() : "0"
                               color: Theme.text; font.family: Theme.familyBody
                               font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                        Text { text: "forks"; color: Theme.text3
                               font.family: Theme.familyMono; font.pixelSize: Theme.fontXs }
                    }
                    Column {
                        Text { text: root.wf ? root.wf.steps.toString() : "0"
                               color: Theme.text; font.family: Theme.familyBody
                               font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                        Text { text: "steps"; color: Theme.text3
                               font.family: Theme.familyMono; font.pixelSize: Theme.fontXs }
                    }
                }

                // Safety banner
                Rectangle {
                    visible: root.wf && root.wf.hasShell
                    width: body.width - body.leftPadding - body.rightPadding
                    height: bannerCol.implicitHeight + 22
                    radius: Theme.radiusSm
                    color: Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.09)
                    border.color: Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.4)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 10

                        Rectangle {
                            width: 22; height: 22; radius: 11
                            color: Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.2)
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                anchors.centerIn: parent
                                text: "›"
                                color: Theme.warn
                                font.family: Theme.familyBody
                                font.pixelSize: 14
                                font.weight: Font.Bold
                            }
                        }

                        Column {
                            id: bannerCol
                            width: parent.width - 22 - 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Text {
                                text: "Contains shell commands"
                                color: Theme.warn
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                font.weight: Font.DemiBold
                            }
                            Text {
                                text: "Review steps below before importing. Use Dry Run to walk through without executing."
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontXs
                                lineHeight: 1.3
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }
                        }
                    }
                }

                // Step preview
                Column {
                    width: body.width - body.leftPadding - body.rightPadding
                    spacing: 6

                    Text {
                        text: "STEPS"
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 0.9
                        bottomPadding: 4
                    }

                    Repeater {
                        model: root.stepsFor(root.wf)
                        delegate: Rectangle {
                            width: parent.width
                            height: 48
                            radius: Theme.radiusSm
                            color: Theme.surface
                            border.color: Theme.lineSoft
                            border.width: 1

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 14
                                spacing: 12

                                Text {
                                    text: (index + 1 < 10 ? "0" : "") + (index + 1)
                                    color: Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: Theme.fontXs
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 18
                                }

                                CategoryIcon {
                                    kind: modelData.kind
                                    size: 26
                                    hovered: false
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 18 - 12 - 26 - 12 - 14
                                    spacing: 1

                                    Text {
                                        text: modelData.summary
                                        color: Theme.text
                                        font.family: Theme.familyBody
                                        font.pixelSize: Theme.fontSm
                                        font.weight: Font.Medium
                                    }
                                    Text {
                                        text: modelData.value
                                        color: Theme.text3
                                        font.family: Theme.familyMono
                                        font.pixelSize: Theme.fontXs
                                        elide: Text.ElideRight
                                        width: parent.width
                                    }
                                }
                            }
                        }
                    }
                }

                // Discussion link
                Row {
                    spacing: 6
                    Text {
                        text: "Discussion on web"
                        color: Theme.accent
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                    }
                    Text {
                        text: "→"
                        color: Theme.accent
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                    }
                }
            }
        }

        // Sticky action bar at bottom of drawer
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 88
            color: Theme.surface

            Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Theme.line
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 28
                anchors.rightMargin: 28
                spacing: 10
                layoutDirection: Qt.RightToLeft

                Button {
                    text: "Import"
                    anchors.verticalCenter: parent.verticalCenter
                    topPadding: 12; bottomPadding: 12
                    leftPadding: 24; rightPadding: 24
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: parent.hovered ? Theme.accentHi : Theme.accent
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "#1a1208"
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                    }
                    onClicked: if (root.wf) root.imported(root.wf.id)
                }

                Button {
                    text: "Dry run"
                    anchors.verticalCenter: parent.verticalCenter
                    topPadding: 12; bottomPadding: 12
                    leftPadding: 18; rightPadding: 18
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: parent.hovered ? Theme.surface3 : Theme.surface2
                        border.color: Theme.line
                        border.width: 1
                    }
                    contentItem: Text {
                        text: parent.text
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                    }
                    onClicked: if (root.wf) root.dryRunRequested(root.wf.id)
                }

                Item { width: parent.width - 0; height: 1 }   // pushes report to the left

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Report"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor }
                }
            }
        }
    }
}
