import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Wflow

// Featured workflow hero. Warm-amber bezel + a vertical mini-stack of
// the workflow's first 4 step kinds on the right, mirroring the
// flow-canvas treatment so users coming from the canvas recognize
// the visual vocabulary instantly.
Rectangle {
    id: root
    property var wf
    signal activated(string id)

    readonly property var kinds: root.wf && root.wf.kinds ? root.wf.kinds : []
    readonly property string firstKind: kinds.length > 0 ? kinds[0] : "wait"

    height: 220
    radius: 18
    // Two-layer fill: a warm amber wash drifting in from the top-left
    // over the regular surface so the bezel reads as light catching
    // an edge, not a solid tint.
    color: Theme.surface
    border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b,
        heroArea.containsMouse ? 0.55 : 0.35)
    border.width: 1
    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: Theme.shadowColor
        shadowBlur: 1.0
        shadowVerticalOffset: Theme.shadowYMid
    }

    // Inner warm wash — restricted to the upper-left so the right
    // half (where the mini-stack sits) stays neutral.
    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: 17
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18) }
            GradientStop { position: 0.55; color: Qt.rgba(0, 0, 0, 0) }
        }
    }

    MouseArea {
        id: heroArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.wf) root.activated(root.wf.id)
    }

    Row {
        anchors.fill: parent
        anchors.margins: 28
        spacing: 32

        // Left column — eyebrow, title, byline, install button.
        Column {
            id: leftCol
            width: parent.width - previewCol.width - 32
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            Row {
                spacing: 8
                Rectangle {
                    width: 6; height: 6; radius: 3
                    color: Theme.accent
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "FEATURED TODAY"
                    color: Theme.accent
                    font.family: Theme.familyBody
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    font.letterSpacing: 1.6
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.wf ? "·  curated by @wflow  ·  " + (root.wf.category || "uncategorized") : ""
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: 11
                    font.letterSpacing: 0.4
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Text {
                text: root.wf ? root.wf.title : ""
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: 26
                font.weight: Font.Bold
                font.letterSpacing: -0.5
                elide: Text.ElideRight
                width: parent.width
            }

            Text {
                text: root.wf ? root.wf.subtitle : ""
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontBase
                wrapMode: Text.WordWrap
                width: parent.width
                lineHeight: 1.45
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            // Byline row.
            Row {
                spacing: 10
                topPadding: 4

                Avatar {
                    handle: root.wf ? "@" + root.wf.author : ""
                    size: 32
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    spacing: 1
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        text: root.wf ? "@" + root.wf.author : ""
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: 12.5
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: root.wf
                            ? root.wf.imports + " installs · " + root.wf.forks + " forks · " + root.wf.steps + " steps"
                            : ""
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 11
                    }
                }
            }

            // Action row.
            Row {
                spacing: 8
                topPadding: 4

                PrimaryButton {
                    text: "↓  Install workflow"
                    leftPadding: 18
                    rightPadding: 18
                    onClicked: if (root.wf) root.activated(root.wf.id)
                }
                SecondaryButton { text: "⑂  Fork" }
                SecondaryButton { text: "★  Star" }
            }
        }

        // Right column — vertical mini-stack preview.
        Rectangle {
            id: previewCol
            width: 260
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height - 12
            radius: Theme.radiusMd
            color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.7)
            border.color: Theme.lineSoft
            border.width: 1

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                Row {
                    width: parent.width
                    Text {
                        text: "STEPS · " + (root.wf ? root.wf.steps : 0)
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 9.5
                        font.letterSpacing: 1.4
                        font.weight: Font.Bold
                    }
                    Item { width: parent.width - 80 - parent.children[0].width - 8; height: 1 }
                    Text {
                        text: "PREVIEW"
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 9.5
                        font.letterSpacing: 1.0
                    }
                }

                Repeater {
                    model: Math.min(4, root.kinds.length)
                    delegate: MiniStep {
                        width: previewCol.width - 28
                        kind: root.kinds[index]
                        label: _kindLabel(root.kinds[index])
                        value: _kindValue(root.kinds[index], index)
                    }
                }

                Text {
                    visible: root.wf && root.wf.steps > 4
                    text: "+ " + (root.wf ? (root.wf.steps - 4) : 0) + " more step" +
                        (root.wf && (root.wf.steps - 4) === 1 ? "" : "s")
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 11
                    leftPadding: 28
                    topPadding: 4
                }
            }
        }
    }

    // Sample-text helpers — until each catalog entry carries a real
    // step preview, fabricate a plausible value per kind so the hero
    // mini-stack feels populated rather than empty.
    function _kindLabel(kind) {
        switch (kind) {
        case "key":       return "Key"
        case "type":      return "Type"
        case "click":     return "Click"
        case "shell":     return "Shell"
        case "focus":     return "Focus"
        case "wait":      return "Wait"
        case "notify":    return "Notify"
        case "clipboard": return "Clip"
        }
        return kind
    }
    function _kindValue(kind, idx) {
        const samples = ({
            "key":       ["ctrl + l", "super + space", "alt + tab", "Return"],
            "type":      ["{{project}}", "localhost:3000", "branch-name", "{{message}}"],
            "click":     ["primary", "context", "double", "primary"],
            "shell":     ["kitty -e nvim", "firefox {{url}}", "git status", "cargo run"],
            "focus":     ["firefox", "kitty", "slack", "obsidian"],
            "wait":      ["window kitty · 10s", "200ms", "1500ms", "until firefox"],
            "notify":    ["\"Setup ready\"", "\"Done\"", "\"Sync complete\"", "\"Hi\""],
            "clipboard": ["{{selection}}", "screenshot.png", "{{url}}", "{{snippet}}"]
        })
        const arr = samples[kind] || ["—"]
        return arr[idx % arr.length]
    }
}
