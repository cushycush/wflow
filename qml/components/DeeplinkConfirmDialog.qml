import QtQuick
import QtQuick.Controls
import Wflow

// Without this, a wflow:// link could land a workflow silently. Shows
// the bridge-fetched metadata before the user says yes.
Dialog {
    id: root
    modal: true
    closePolicy: Popup.CloseOnEscape
    width: 480
    anchors.centerIn: parent

    // {title, handle, slug, description, stepCount, sourceUrl}.
    property var preview: null

    signal confirmed(string sourceUrl)
    signal cancelled()

    header: Item { width: 0; height: 0 }
    footer: Item { width: 0; height: 0 }

    background: Rectangle {
        color: Theme.surface
        radius: Theme.radiusMd
        border.color: Theme.line
        border.width: 1
    }

    onAccepted: {
        if (root.preview && root.preview.sourceUrl) {
            root.confirmed(root.preview.sourceUrl)
        }
    }
    onRejected: root.cancelled()

    contentItem: Item {
        anchors.fill: parent

        Column {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            Rectangle {
                visible: pillText.text.length > 0
                width: pillText.implicitWidth + 16
                height: 22
                radius: Theme.radiusSm
                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                border.width: 1
                Text {
                    id: pillText
                    anchors.centerIn: parent
                    text: "from wflows.io"
                    color: Theme.accent
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    font.letterSpacing: 0.5
                }
            }

            Column {
                width: parent.width
                spacing: 6
                Text {
                    text: root.preview ? (root.preview.title || "Untitled workflow") : ""
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                    wrapMode: Text.WordWrap
                    width: parent.width
                }
                Text {
                    visible: text.length > 0
                    text: root.preview && root.preview.handle
                        ? "by @" + root.preview.handle
                        : ""
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontSm
                    width: parent.width
                }
                Text {
                    visible: text.length > 0
                    text: root.preview ? (root.preview.description || "") : ""
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                    width: parent.width
                }
            }

            Rectangle {
                visible: root.preview && root.preview.stepCount !== undefined
                width: stepCountText.implicitWidth + 16
                height: 24
                radius: Theme.radiusSm
                color: Theme.surface2
                border.color: Theme.lineSoft
                border.width: 1
                Text {
                    id: stepCountText
                    anchors.centerIn: parent
                    text: {
                        if (!root.preview) return ""
                        const n = root.preview.stepCount
                        return n + (n === 1 ? " step" : " steps")
                    }
                    color: Theme.text2
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontSm
                }
            }

            // Chords this workflow wants to bind on import; the user
            // sees them before global registration.
            Column {
                visible: root.preview && root.preview.chords && root.preview.chords.length > 0
                width: parent.width
                spacing: 6

                Text {
                    text: "Will bind"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    font.letterSpacing: 0.5
                    font.weight: Font.Bold
                }

                Repeater {
                    model: root.preview ? (root.preview.chords || []) : []
                    delegate: Column {
                        spacing: 2
                        width: parent.width

                        Row {
                            spacing: 8
                            Rectangle {
                                width: chordText.implicitWidth + 14
                                height: 24
                                radius: Theme.radiusSm
                                color: Theme.surface2
                                border.color: modelData.conflictsWith
                                    ? Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.6)
                                    : Theme.lineStrong
                                border.width: 1
                                Text {
                                    id: chordText
                                    anchors.centerIn: parent
                                    text: modelData.chord
                                    color: Theme.text
                                    font.family: Theme.familyMono
                                    font.pixelSize: Theme.fontSm
                                    font.weight: Font.DemiBold
                                }
                            }
                            Text {
                                visible: modelData.whenLabel.length > 0
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.whenLabel
                                color: Theme.text3
                                font.family: Theme.familyMono
                                font.pixelSize: Theme.fontXs
                            }
                        }

                        // Heads-up only; the daemon replaces the binding
                        // on save when the file-watcher diffs it.
                        Text {
                            visible: modelData.conflictsWith.length > 0
                            text: "⚠ replaces an existing binding on “" + modelData.conflictsWith + "”"
                            color: Theme.warn
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXs
                            wrapMode: Text.WordWrap
                            width: 380
                        }
                    }
                }
            }

            Row {
                width: parent.width
                spacing: 8
                layoutDirection: Qt.RightToLeft

                Button {
                    id: confirmBtn
                    text: "Install"
                    topPadding: 8
                    bottomPadding: 8
                    leftPadding: 14
                    rightPadding: 14

                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: confirmBtn.hovered ? Theme.accentHi : Theme.accent
                        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    }
                    contentItem: Text {
                        text: confirmBtn.text
                        color: "white"
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: root.accept()
                }
                SecondaryButton {
                    text: "Cancel"
                    onClicked: root.reject()
                }
            }
        }
    }
}
