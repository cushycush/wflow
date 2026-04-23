import QtQuick
import QtQuick.Controls
import Wflow

// Variant 0 — CLASSIC
// The original two-pane layout, polished. Deck on the left, event ledger on
// the right. Adds a subtle color pulse while armed.
Item {
    id: root
    property string phase: "idle"
    property int totalMs: 0
    property var events: []

    signal armRequested()
    signal stopRequested()

    Row {
        anchors.fill: parent
        spacing: 0

        // LEFT — deck
        Rectangle {
            width: 340
            height: parent.height
            color: root.phase === "armed"
                ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.04)
                : "transparent"
            Behavior on color { ColorAnimation { duration: 400 } }

            Column {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 20

                Text {
                    text: "STATE"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.0
                }

                // Big rec card
                Rectangle {
                    id: recBtn
                    width: parent.width
                    height: 160
                    radius: Theme.radiusLg
                    color: Theme.surface
                    border.color: root.phase === "recording"
                        ? Theme.err
                        : (root.phase === "armed" ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.55) : Theme.lineSoft)
                    border.width: root.phase === "recording" ? 2 : 1
                    Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                    // Armed pulsing halo
                    Rectangle {
                        visible: root.phase === "armed" || root.phase === "recording"
                        anchors.centerIn: parent
                        width: parent.width - 8
                        height: parent.height - 8
                        radius: parent.radius
                        color: "transparent"
                        border.color: Theme.err
                        border.width: 1
                        opacity: 0.4
                        SequentialAnimation on opacity {
                            running: root.phase === "armed" || root.phase === "recording"
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.1; duration: 900; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 0.5; duration: 900; easing.type: Easing.InOutSine }
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 12

                        Rectangle {
                            width: 64
                            height: 64
                            radius: 32
                            anchors.horizontalCenter: parent.horizontalCenter
                            color: root.phase === "recording" ? Theme.err
                                 : root.phase === "armed"     ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.7)
                                                               : Theme.accent
                            Behavior on color { ColorAnimation { duration: Theme.durBase } }

                            Rectangle {
                                width: root.phase === "recording" ? 18 : 22
                                height: width
                                radius: root.phase === "recording" ? 3 : width / 2
                                anchors.centerIn: parent
                                color: "white"
                                opacity: 0.95
                                Behavior on width { NumberAnimation { duration: Theme.durBase } }
                                Behavior on radius { NumberAnimation { duration: Theme.durBase } }
                            }
                        }

                        Text {
                            text: root.phase === "recording" ? "STOP" :
                                  root.phase === "armed" ? "ARMED" : "ARM"
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.Bold
                            font.letterSpacing: 1.4
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
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

                // Timer
                Rectangle {
                    width: parent.width
                    height: 72
                    radius: Theme.radiusMd
                    color: Theme.surface
                    border.color: Theme.lineSoft
                    border.width: 1

                    Column {
                        anchors.centerIn: parent
                        spacing: 2
                        Text {
                            text: {
                                const total = Math.floor(root.totalMs / 100) / 10
                                const mm = Math.floor(total / 60)
                                const ss = Math.floor(total % 60)
                                const dec = Math.floor((root.totalMs % 1000) / 100)
                                return String(mm).padStart(2, "0") + ":" +
                                       String(ss).padStart(2, "0") + "." + dec
                            }
                            color: root.phase === "recording" ? Theme.err : Theme.text
                            font.family: Theme.familyMono
                            font.pixelSize: 28
                            font.weight: Font.Medium
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        Text {
                            text: "mm:ss.d"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXs
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: root.phase === "idle"
                          ? "Click ARM, switch to the target window, then do the thing. Click STOP when done."
                          : root.phase === "armed"
                          ? "Armed. Perform the actions you want captured — events will appear to the right."
                          : root.phase === "recording"
                          ? "Listening. Don't type into wflow — switch windows and go."
                          : "Review the captured events and save them as a new workflow."
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                    lineHeight: 1.45
                }
            }
        }

        Rectangle { width: 1; height: parent.height; color: Theme.lineSoft }

        // RIGHT — event ledger
        Column {
            width: parent.width - 340 - 1
            height: parent.height
            spacing: 0

            Row {
                width: parent.width
                height: 40
                leftPadding: 24
                rightPadding: 24
                spacing: 12
                Text {
                    text: "EVENTS"
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
                title: "Nothing captured yet"
                description: "Arm the recorder and perform the actions you want as a workflow."
            }

            ScrollView {
                width: parent.width
                height: parent.height - 41
                visible: root.events.length > 0
                clip: true
                contentWidth: availableWidth

                Column {
                    x: 24; y: 12
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
}
