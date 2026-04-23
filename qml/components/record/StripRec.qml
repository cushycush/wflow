import QtQuick
import QtQuick.Controls
import Wflow

// Variant 3 — STRIP
// Horizontal recording strip up top. Events flow in from the right as colored
// tokens. The strip scrolls sideways like a seismograph.
Item {
    id: root
    property string phase: "idle"
    property int totalMs: 0
    property var events: []

    signal armRequested()
    signal stopRequested()

    readonly property bool hot: phase === "armed" || phase === "recording"

    Column {
        anchors.fill: parent
        spacing: 0

        // TOP CONTROL STRIP
        Rectangle {
            width: parent.width
            height: 120
            color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 1)
            border.color: Theme.lineSoft
            border.width: 0

            Row {
                anchors.fill: parent
                anchors.leftMargin: 28
                anchors.rightMargin: 28
                spacing: 24

                // Record button
                Rectangle {
                    id: recBtn
                    width: 72
                    height: 72
                    radius: 36
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.phase === "recording" ? Theme.err
                         : root.phase === "armed"     ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.8)
                                                      : Theme.accent
                    Behavior on color { ColorAnimation { duration: Theme.durBase } }

                    SequentialAnimation on scale {
                        running: root.phase === "armed"
                        loops: Animation.Infinite
                        NumberAnimation { to: 1.08; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0;  duration: 700; easing.type: Easing.InOutSine }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: root.phase === "recording" ? 20 : 26
                        height: width
                        radius: root.phase === "recording" ? 3 : width / 2
                        color: "white"
                        Behavior on width  { NumberAnimation { duration: Theme.durBase } }
                        Behavior on radius { NumberAnimation { duration: Theme.durBase } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.phase === "recording") root.stopRequested()
                            else root.armRequested()
                        }
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    width: 180

                    Text {
                        text: root.phase === "recording" ? "RECORDING" :
                              root.phase === "armed"     ? "ARMED" :
                                                           "IDLE"
                        color: root.hot ? Theme.err : Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        font.letterSpacing: 1.5
                    }
                    Text {
                        text: {
                            const total = Math.floor(root.totalMs / 100) / 10
                            const mm = Math.floor(total / 60)
                            const ss = Math.floor(total % 60)
                            const dec = Math.floor((root.totalMs % 1000) / 100)
                            return String(mm).padStart(2, "0") + ":" +
                                   String(ss).padStart(2, "0") + "." + dec
                        }
                        color: Theme.text
                        font.family: Theme.familyMono
                        font.pixelSize: 26
                        font.weight: Font.Medium
                    }
                }

                // Scrolling event token strip
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 72 - 24 - 180 - 24
                    height: 80
                    radius: Theme.radiusMd
                    color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.6)
                    border.color: Theme.lineSoft
                    border.width: 1
                    clip: true

                    // "Playhead" line on the right indicating most recent
                    Rectangle {
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.margins: 6
                        width: 2
                        color: root.hot ? Theme.err : Theme.lineSoft
                        Behavior on color { ColorAnimation { duration: 400 } }
                    }

                    // Latest events as tokens, right-to-left
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: 18
                        spacing: 8
                        layoutDirection: Qt.RightToLeft

                        Repeater {
                            model: root.events.slice(-10).reverse()
                            delegate: Rectangle {
                                readonly property color catColor: {
                                    const t = ({
                                        "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                                        "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                                        "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                                        "clipboard": Theme.catClip, "note": Theme.catNote
                                    })
                                    return t[modelData.category] || Theme.catWait
                                }
                                width: tokText.implicitWidth + 20
                                height: 28
                                radius: 14
                                color: Qt.rgba(catColor.r, catColor.g, catColor.b, 0.2)
                                border.color: Qt.rgba(catColor.r, catColor.g, catColor.b, 0.5)
                                border.width: 1
                                Text {
                                    id: tokText
                                    anchors.centerIn: parent
                                    text: modelData.body
                                    color: catColor
                                    font.family: Theme.familyMono
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                }
                            }
                        }
                    }

                    // "Empty" hint when no events
                    Text {
                        anchors.centerIn: parent
                        visible: root.events.length === 0
                        text: root.hot ? "listening ..." : "arm to start"
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 12
                        font.letterSpacing: 0.8
                        opacity: root.hot ? 0.8 : 0.5
                        SequentialAnimation on opacity {
                            running: root.hot
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.3; duration: 800 }
                            NumberAnimation { to: 0.8; duration: 800 }
                        }
                    }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.lineSoft }

        // BOTTOM LEDGER
        Column {
            width: parent.width
            height: parent.height - 121
            spacing: 0

            Row {
                width: parent.width
                height: 40
                leftPadding: 28
                spacing: 12
                Text {
                    text: "FULL LEDGER"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.0
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.events.length
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontXs
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Rectangle { width: parent.width; height: 1; color: Theme.lineSoft }

            EmptyState {
                width: parent.width
                height: parent.height - 41
                visible: root.events.length === 0
                title: "No events yet"
                description: "Arm and perform — the ledger is the full history."
            }

            ScrollView {
                width: parent.width
                height: parent.height - 41
                visible: root.events.length > 0
                clip: true
                contentWidth: availableWidth

                Column {
                    x: 28; y: 8
                    width: parent.width - 56
                    spacing: 4

                    Repeater {
                        model: root.events
                        delegate: Row {
                            width: parent.width
                            height: 30
                            spacing: 14
                            Text {
                                text: (modelData.t_ms / 1000).toFixed(2) + "s"
                                color: Theme.text3
                                font.family: Theme.familyMono
                                font.pixelSize: Theme.fontXs
                                width: 50
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            CategoryChip {
                                kind: modelData.category
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: modelData.body
                                color: Theme.text
                                font.family: Theme.familyMono
                                font.pixelSize: Theme.fontSm
                                elide: Text.ElideRight
                                width: parent.width - 50 - 14 - 74 - 14
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }
            }
        }
    }
}
