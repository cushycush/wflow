import QtQuick
import QtQuick.Controls
import Wflow

// Variant 4 — AMBIENT
// Large breathing gradient behind everything. Color shifts between amber
// (idle), dim red (armed), and full red (recording). Central controls
// feel quiet; the mood does the talking.
Item {
    id: root
    property string phase: "idle"
    property int totalMs: 0
    property var events: []

    signal armRequested()
    signal stopRequested()

    readonly property bool hot: phase === "armed" || phase === "recording"
    readonly property color moodColor: {
        if (phase === "recording") return Theme.err
        if (phase === "armed") return Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.8)
        return Theme.accent
    }

    // Ambient wash layer — large radial tint centered on the button
    Rectangle {
        id: wash
        anchors.centerIn: parent
        width: Math.min(parent.width, 900)
        height: width
        radius: width / 2
        color: Qt.rgba(root.moodColor.r, root.moodColor.g, root.moodColor.b, root.hot ? 0.16 : 0.07)
        Behavior on color { ColorAnimation { duration: 900 } }
        opacity: 0.9

        SequentialAnimation on scale {
            running: true
            loops: Animation.Infinite
            NumberAnimation { to: 1.06; duration: 4200; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0;  duration: 4200; easing.type: Easing.InOutSine }
        }
    }

    // Second wash — a little offset for depth
    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width, 600)
        height: width
        radius: width / 2
        color: Qt.rgba(root.moodColor.r, root.moodColor.g, root.moodColor.b, root.hot ? 0.12 : 0.05)
        Behavior on color { ColorAnimation { duration: 900 } }
        y: parent.height * 0.25 - width / 2

        SequentialAnimation on scale {
            running: true
            loops: Animation.Infinite
            NumberAnimation { to: 1.08; duration: 5500; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.95; duration: 5500; easing.type: Easing.InOutSine }
        }
    }

    // Center column
    Column {
        anchors.centerIn: parent
        spacing: 36
        width: 560

        // State label
        Text {
            text: root.phase === "recording" ? "RECORDING" :
                  root.phase === "armed"     ? "ARMED — GO AHEAD" :
                                               "READY WHEN YOU ARE"
            color: root.hot ? Theme.err : Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: 13
            font.weight: Font.Bold
            font.letterSpacing: 3.0
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
        }

        // Central button
        Rectangle {
            width: 128
            height: 128
            radius: 64
            anchors.horizontalCenter: parent.horizontalCenter
            color: root.moodColor
            Behavior on color { ColorAnimation { duration: Theme.durBase } }

            // Soft ring
            Rectangle {
                anchors.centerIn: parent
                width: parent.width + 24
                height: parent.height + 24
                radius: width / 2
                color: "transparent"
                border.color: Qt.rgba(root.moodColor.r, root.moodColor.g, root.moodColor.b, 0.5)
                border.width: 1
            }

            SequentialAnimation on scale {
                running: root.phase === "armed"
                loops: Animation.Infinite
                NumberAnimation { to: 1.05; duration: 900; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutSine }
            }

            Rectangle {
                anchors.centerIn: parent
                width: root.phase === "recording" ? 30 : 42
                height: width
                radius: root.phase === "recording" ? 4 : width / 2
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

        // Timer
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
            font.pixelSize: 44
            font.weight: Font.Medium
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // Event count pill
        Rectangle {
            visible: root.events.length > 0 || root.hot
            anchors.horizontalCenter: parent.horizontalCenter
            width: cntRow.implicitWidth + 28
            height: 36
            radius: 18
            color: Qt.rgba(root.moodColor.r, root.moodColor.g, root.moodColor.b, 0.15)
            border.color: Qt.rgba(root.moodColor.r, root.moodColor.g, root.moodColor.b, 0.4)
            border.width: 1

            Row {
                id: cntRow
                anchors.centerIn: parent
                spacing: 10

                Rectangle {
                    visible: root.hot
                    width: 8; height: 8; radius: 4
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
                    text: root.events.length + " events captured"
                    color: root.moodColor
                    font.family: Theme.familyMono
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // Subtle event drawer at the bottom — opens when there's content
    Rectangle {
        visible: root.events.length > 0
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 64, 800)
        anchors.bottomMargin: 24
        height: Math.min(260, 40 + root.events.length * 28)
        radius: Theme.radiusLg
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.92)
        border.color: Theme.lineSoft
        border.width: 1

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 6

            Text {
                text: "RECENT"
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: 10
                font.weight: Font.Bold
                font.letterSpacing: 1.0
            }

            ScrollView {
                width: parent.width
                height: parent.height - 24
                clip: true
                contentWidth: availableWidth

                Column {
                    width: parent.parent.width
                    spacing: 3

                    Repeater {
                        model: root.events
                        delegate: Row {
                            width: parent.width
                            spacing: 12
                            Text {
                                text: (modelData.t_ms / 1000).toFixed(2) + "s"
                                color: Theme.text3
                                font.family: Theme.familyMono
                                font.pixelSize: Theme.fontXs
                                width: 54
                            }
                            CategoryChip { kind: modelData.category }
                            Text {
                                text: modelData.body
                                color: Theme.text
                                font.family: Theme.familyMono
                                font.pixelSize: Theme.fontSm
                                elide: Text.ElideRight
                                width: parent.width - 54 - 12 - 74 - 12
                            }
                        }
                    }
                }
            }
        }
    }
}
