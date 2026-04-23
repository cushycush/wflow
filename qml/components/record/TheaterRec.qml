import QtQuick
import QtQuick.Controls
import Wflow

// Variant 2 — THEATER
// Full-dark spotlight. Central huge record ring, events stream below in
// a muted monospace log, like a terminal session. Dim surrounds.
Item {
    id: root
    property string phase: "idle"
    property int totalMs: 0
    property var events: []

    signal armRequested()
    signal stopRequested()

    readonly property bool hot: phase === "armed" || phase === "recording"

    // Full dark underlay
    Rectangle {
        anchors.fill: parent
        color: "#15161b"
    }

    // Spotlight ring
    Rectangle {
        id: spotlight
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 60
        width: 240
        height: 240
        radius: 120
        color: "transparent"
        border.color: root.hot ? Theme.err : Theme.line
        border.width: 2

        Behavior on border.color { ColorAnimation { duration: 400 } }

        // Inner ring — spins slowly when hot
        Rectangle {
            anchors.centerIn: parent
            width: 180
            height: 180
            radius: 90
            color: "transparent"
            border.color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, root.hot ? 0.4 : 0.1)
            border.width: 1
            opacity: 0.9

            RotationAnimator on rotation {
                from: 0; to: 360
                duration: 14000
                loops: Animation.Infinite
                running: root.hot
            }
        }

        // Core button
        Rectangle {
            id: core
            anchors.centerIn: parent
            width: 100
            height: 100
            radius: 50
            color: root.phase === "recording" ? Theme.err
                 : root.phase === "armed"     ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.75)
                                              : Theme.accent
            Behavior on color { ColorAnimation { duration: Theme.durBase } }

            Rectangle {
                anchors.centerIn: parent
                width: root.phase === "recording" ? 24 : 32
                height: width
                radius: root.phase === "recording" ? 3 : width / 2
                color: "#fff"
                Behavior on width  { NumberAnimation { duration: Theme.durBase } }
                Behavior on radius { NumberAnimation { duration: Theme.durBase } }
            }

            // Armed breathing
            SequentialAnimation on scale {
                running: root.phase === "armed"
                loops: Animation.Infinite
                NumberAnimation { to: 1.08; duration: 800; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0;  duration: 800; easing.type: Easing.InOutSine }
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
    }

    // State + timer text
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: spotlight.bottom
        anchors.topMargin: 24
        spacing: 6

        Text {
            text: root.phase === "recording" ? "RECORDING" :
                  root.phase === "armed"     ? "ARMED" :
                                               "IDLE"
            color: root.hot ? Theme.err : Theme.text3
            font.family: Theme.familyBody
            font.pixelSize: 13
            font.weight: Font.Bold
            font.letterSpacing: 2.4
            anchors.horizontalCenter: parent.horizontalCenter
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
            font.pixelSize: 40
            font.weight: Font.Medium
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    // Terminal-style log
    Rectangle {
        width: parent.width - 96
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 32
        height: parent.height * 0.33
        radius: Theme.radiusMd
        color: Qt.rgba(0, 0, 0, 0.3)
        border.color: Theme.lineSoft
        border.width: 1

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 6

            Row {
                spacing: 8
                Rectangle { width: 8; height: 8; radius: 4; color: Theme.err }
                Rectangle { width: 8; height: 8; radius: 4; color: Theme.warn }
                Rectangle { width: 8; height: 8; radius: 4; color: Theme.ok }
                Item { width: 12; height: 1 }
                Text {
                    text: "wflow record  ·  capturing"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                }
            }

            Rectangle { width: parent.width; height: 1; color: Theme.lineSoft }

            Item {
                width: parent.width
                height: parent.height - 24

                EmptyState {
                    anchors.fill: parent
                    visible: root.events.length === 0
                    title: "> waiting for input..."
                    description: "armed recorder has nothing to capture yet."
                }

                ScrollView {
                    anchors.fill: parent
                    visible: root.events.length > 0
                    clip: true
                    contentWidth: availableWidth

                    Column {
                        width: parent.parent.width
                        spacing: 2

                        Repeater {
                            model: root.events
                            delegate: Text {
                                text: "[" + (modelData.t_ms / 1000).toFixed(2).padStart(6, " ") + "s] "
                                      + modelData.category.padEnd(10, " ") + " "
                                      + modelData.body
                                color: Theme.text
                                font.family: Theme.familyMono
                                font.pixelSize: 11
                                elide: Text.ElideRight
                                width: parent.width
                            }
                        }
                    }
                }
            }
        }
    }
}
