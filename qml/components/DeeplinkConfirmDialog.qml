import QtQuick
import QtQuick.Controls
import Wflow

// Confirm dialog the wflow:// import flow shows before installing.
// Without it, a malicious page could open `wflow://import?source=...`
// in the user's browser and silently land a workflow on disk. The
// dialog renders the metadata the bridge fetched (title, author
// handle, description, step count) plus a "from wflows.io" pill
// the user can read before saying yes.
//
// Usage:
//   DeeplinkConfirmDialog {
//       id: dlg
//       onConfirmed: (sourceUrl) => ctrl.import_from_url(sourceUrl)
//       onCancelled: console.info("import cancelled")
//   }
//   ...
//   dlg.preview = parsedJson
//   dlg.open()
Dialog {
    id: root
    modal: true
    closePolicy: Popup.CloseOnEscape
    width: 480
    anchors.centerIn: parent

    // Bridge-supplied JSON object: {title, handle, slug, description,
    // stepCount, sourceUrl}. Set this BEFORE calling .open().
    property var preview: null

    signal confirmed(string sourceUrl)
    signal cancelled()

    // Suppress Dialog's default system header / footer the same way
    // WfConfirmDialog does so we own the chrome.
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

            // Source pill — quiet "from wflows.io" tag at the top
            // so the user knows where this came from before reading
            // anything else.
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

            // Title + author + description block.
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

            // Step count badge — concrete, scannable. "12 steps" reads
            // faster than walking the whole workflow.
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
