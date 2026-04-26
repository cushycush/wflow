import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Wflow

// Community workflow card. Avatar byline up top, mini-stack preview
// of the first 2-3 step kinds in the middle, stats + category tag at
// the bottom. Multi-layer drop shadow and a subtle lift on hover.
Rectangle {
    id: root
    property var wf
    property real cardW: 280
    property real cardH: 200
    signal activated(string id)

    width: cardW
    height: cardH
    radius: 14
    color: cardArea.containsMouse ? Theme.surface2 : Theme.surface
    border.color: cardArea.containsMouse ? Theme.line : Theme.lineSoft
    border.width: 1

    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: Theme.shadowColor
        shadowBlur: cardArea.containsMouse ? 1.0 : 0.7
        shadowVerticalOffset: cardArea.containsMouse ? 14 : 8
    }

    MouseArea {
        id: cardArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.wf) root.activated(root.wf.id)
    }

    Column {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Header: avatar + title + tagline (2 lines max).
        Row {
            width: parent.width
            spacing: 12

            Avatar {
                handle: root.wf ? "@" + root.wf.author : ""
                size: 30
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                width: parent.width - 30 - 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    text: root.wf ? root.wf.title : ""
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: 14
                    font.weight: Font.Bold
                    font.letterSpacing: -0.2
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    text: root.wf ? root.wf.subtitle : ""
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    width: parent.width
                    lineHeight: 1.3
                }
            }
        }

        // Mini step-stack — up to 3, plus a "+N more" sentinel.
        Column {
            id: stack
            width: parent.width
            spacing: 4

            readonly property var kindsToShow: {
                if (!root.wf || !root.wf.kinds) return []
                return root.wf.kinds.slice(0, Math.min(3, root.wf.kinds.length))
            }

            Repeater {
                model: stack.kindsToShow.length
                delegate: MiniStep {
                    width: stack.width
                    kind: stack.kindsToShow[index]
                    label: ""
                    value: _previewFor(stack.kindsToShow[index], index)
                }
            }

            Text {
                visible: root.wf && root.wf.steps > stack.kindsToShow.length
                text: "+ " + (root.wf ? (root.wf.steps - stack.kindsToShow.length) : 0)
                    + " more step"
                    + (root.wf && (root.wf.steps - stack.kindsToShow.length) === 1 ? "" : "s")
                color: Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: 11
                leftPadding: 26
                topPadding: 2
            }
        }

        Item { id: spacer; height: Math.max(0, parent.height - parent.spacing * 2 - 64 - stack.height); width: 1 }

        // Footer: stats on the left, category tag on the right.
        Row {
            width: parent.width
            spacing: 12

            Row {
                id: statsRow
                spacing: 12
                anchors.verticalCenter: parent.verticalCenter

                Row {
                    spacing: 4
                    Text {
                        text: "★"
                        color: Theme.accent
                        font.pixelSize: 11
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.wf ? root.wf.imports : ""
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                Row {
                    spacing: 4
                    Text {
                        text: "⑂"
                        color: Theme.text3
                        font.pixelSize: 11
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.wf ? root.wf.forks : ""
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            Item {
                width: Math.max(0, parent.width - statsRow.width - tag.width - 24)
                height: 1
            }

            Rectangle {
                id: tag
                anchors.verticalCenter: parent.verticalCenter
                radius: 999
                color: Theme.bg
                border.color: Theme.lineSoft
                border.width: 1
                width: tagText.implicitWidth + 16
                height: 22
                Text {
                    id: tagText
                    anchors.centerIn: parent
                    text: root.wf ? root.wf.category : ""
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 11
                    font.weight: Font.Medium
                }
            }
        }
    }

    // Sample-step helper — until each catalog entry carries real
    // per-step data, fabricate a plausible value per kind so users
    // see the SHAPE of the workflow at a glance.
    function _previewFor(kind, idx) {
        const samples = ({
            "key":       ["ctrl + l", "super + space", "alt + tab"],
            "type":      ["{{branch}}", "localhost:3000", "{{snippet}}"],
            "click":     ["primary", "context", "double"],
            "shell":     ["git status", "kitty -e nvim", "firefox {{url}}"],
            "focus":     ["kitty", "firefox", "slack"],
            "wait":      ["200ms", "window kitty", "1500ms"],
            "notify":    ["\"Done\"", "\"Synced\"", "\"Ready\""],
            "clipboard": ["{{selection}}", "screenshot.png", "{{url}}"]
        })
        const arr = samples[kind] || ["—"]
        return arr[idx % arr.length]
    }
}
