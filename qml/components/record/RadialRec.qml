import QtQuick
import QtQuick.Controls
import Wflow

// Variant 1 — RADIAL
// Center-stage record button surrounded by 3 concentric pulsing rings.
// While armed/recording, rings expand outward with staggered phase.
// Event list runs beneath, compact and animated.
Item {
    id: root
    property string phase: "idle"
    property int totalMs: 0
    property var events: []

    signal armRequested()
    signal stopRequested()

    readonly property bool hot: phase === "armed" || phase === "recording"

    // Top block — rec center with rings
    Item {
        id: stage
        width: parent.width
        height: parent.height * 0.55
        anchors.top: parent.top

        // Ambient radial gradient backing (non-animating — static color wash)
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width, 800)
            height: width
            radius: width / 2
            color: "transparent"
            border.color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, root.hot ? 0.15 : 0.05)
            border.width: 1
            Behavior on border.color { ColorAnimation { duration: 600 } }
        }

        // Three pulsing rings
        Repeater {
            model: 3
            delegate: Rectangle {
                anchors.centerIn: parent
                property real baseSize: 160 + index * 90
                property real scaleFactor: 1.0
                width: baseSize
                height: baseSize
                radius: width / 2
                color: "transparent"
                border.color: root.hot ? Theme.err : Theme.lineSoft
                border.width: 1
                opacity: root.hot ? (0.5 - index * 0.12) : 0.18
                Behavior on opacity { NumberAnimation { duration: 600 } }
                Behavior on border.color { ColorAnimation { duration: 600 } }

                transform: Scale {
                    origin.x: width / 2
                    origin.y: height / 2
                    xScale: scaleFactor
                    yScale: scaleFactor
                }

                SequentialAnimation on scaleFactor {
                    running: root.hot
                    loops: Animation.Infinite
                    PauseAnimation { duration: index * 400 }
                    NumberAnimation { to: 1.12; duration: 1200; easing.type: Easing.OutQuad }
                    NumberAnimation { to: 1.0;  duration: 1200; easing.type: Easing.InQuad }
                }
            }
        }

        // Center button
        Rectangle {
            id: core
            anchors.centerIn: parent
            width: 120
            height: 120
            radius: 60
            color: root.phase === "recording" ? Theme.err
                 : root.phase === "armed"     ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.7)
                                              : Theme.accent
            Behavior on color { ColorAnimation { duration: Theme.durBase } }

            SequentialAnimation on scale {
                running: root.phase === "armed"
                loops: Animation.Infinite
                NumberAnimation { to: 1.05; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0;  duration: 700; easing.type: Easing.InOutSine }
            }

            Rectangle {
                anchors.centerIn: parent
                width: root.phase === "recording" ? 28 : 38
                height: width
                radius: root.phase === "recording" ? 4 : width / 2
                color: "white"
                opacity: 0.95
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

        // State label below the core
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: core.bottom
            anchors.topMargin: 28
            text: root.phase === "recording" ? "● RECORDING" :
                  root.phase === "armed"     ? "✦ ARMED" :
                                               "▶ ARM"
            color: root.hot ? Theme.err : Theme.text
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontMd
            font.weight: Font.Bold
            font.letterSpacing: 1.8
        }

        // Timer below state label
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 24
            text: {
                const total = Math.floor(root.totalMs / 100) / 10
                const mm = Math.floor(total / 60)
                const ss = Math.floor(total % 60)
                const dec = Math.floor((root.totalMs % 1000) / 100)
                return String(mm).padStart(2, "0") + ":" +
                       String(ss).padStart(2, "0") + "." + dec
            }
            color: root.hot ? Theme.err : Theme.text3
            font.family: Theme.familyMono
            font.pixelSize: 32
            font.weight: Font.Medium
        }
    }

    // Divider
    Rectangle {
        width: parent.width
        anchors.top: stage.bottom
        height: 1
        color: Theme.lineSoft
    }

    // Bottom — live event feed
    Column {
        width: parent.width
        anchors.top: stage.bottom
        anchors.topMargin: 1
        anchors.bottom: parent.bottom
        spacing: 0

        Row {
            width: parent.width
            height: 40
            leftPadding: 24
            spacing: 12
            Text {
                text: "LIVE EVENTS"
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
                font.weight: Font.DemiBold
                font.letterSpacing: 1.0
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                visible: root.hot
                width: 6; height: 6; radius: 3
                color: Theme.err
                anchors.verticalCenter: parent.verticalCenter
                SequentialAnimation on opacity {
                    running: root.hot
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.2; duration: 500 }
                    NumberAnimation { to: 1.0; duration: 500 }
                }
            }
            Text {
                text: root.events.length + " events"
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
            title: "Waiting for your first action"
            description: "Armed? Perform any action and it'll land here."
        }

        ScrollView {
            width: parent.width
            height: parent.height - 41
            visible: root.events.length > 0
            clip: true
            contentWidth: availableWidth

            Column {
                x: 24; y: 8
                width: parent.width - 48
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
