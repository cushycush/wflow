import QtQuick
import QtQuick.Controls
import Wflow

// Community workflow card. Mirrors the LibraryGrid workflow card layout
// (avatar + title-block + open-pill on top, a description block, then
// the step-trail, then a ruled footer with meta on the left and a
// category tag on the right) so a workflow on Explore reads like a
// workflow on Library — same shape, same rhythm. The step trail is
// the wflows.com hero-card preview look: a row of CategoryIcons for
// the first few kinds, plus a `+N` sentinel when there are more.
Rectangle {
    id: card
    property var wf
    property real cardW: 280
    property real cardH: 200
    signal activated(string id)

    width: cardW
    height: cardH
    radius: Theme.radiusLg
    color: cardArea.containsMouse ? Theme.surface2 : Theme.surface
    border.color: cardArea.containsMouse ? Theme.lineStrong : Theme.line
    border.width: 1

    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

    MouseArea {
        id: cardArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (card.wf) card.activated(card.wf.id)
    }

    Item {
        anchors.fill: parent

        // ── Top row: avatar + title-block + open-pill ──
        Item {
            id: topRow
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 16
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            height: 36

            Avatar {
                id: monoAvatar
                handle: card.wf ? "@" + card.wf.author : ""
                size: 32
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                anchors.left: monoAvatar.right
                anchors.leftMargin: 10
                anchors.right: openPill.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    text: card.wf ? card.wf.title : ""
                    color: Theme.text
                    font.family: Theme.familyDisplay
                    font.pixelSize: Theme.fontBase
                    font.weight: Font.DemiBold
                    font.letterSpacing: -0.2
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    text: card.wf ? "@" + card.wf.author : ""
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            // Pill mirror of wflows.com's "Open in wflow" CTA, except
            // for catalog cards it reads "Install" so the action is
            // unambiguous before the user even reaches the drawer.
            Rectangle {
                id: openPill
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: openText.implicitWidth + 22
                height: 26
                radius: height / 2
                color: openArea.containsMouse ? Theme.accent : Theme.surface2
                border.color: openArea.containsMouse ? Theme.accent : Theme.line
                border.width: 1
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                Text {
                    id: openText
                    anchors.centerIn: parent
                    text: "↗  Install"
                    color: openArea.containsMouse ? Theme.accentText : Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.4
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                }

                MouseArea {
                    id: openArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (card.wf) card.activated(card.wf.id)
                }
            }
        }

        // ── Description (subtitle as its own block) ──
        Text {
            id: descText
            anchors.top: topRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 12
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            text: card.wf ? (card.wf.subtitle || "") : ""
            color: Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
            maximumLineCount: 2
            lineHeight: 1.35
            visible: text.length > 0
        }

        // ── Step trail (CategoryIcon row, wflows.com hero-card preview) ──
        Row {
            id: trailRow
            anchors.top: descText.visible ? descText.bottom : topRow.bottom
            anchors.topMargin: 12
            anchors.left: parent.left
            anchors.leftMargin: 16
            spacing: 6

            readonly property int kindsCount: (card.wf && card.wf.kinds) ? card.wf.kinds.length : 0
            readonly property int kindsCap: 7
            readonly property int kindsHidden: Math.max(0, kindsCount - kindsCap)

            Repeater {
                model: (card.wf && card.wf.kinds ? card.wf.kinds : []).slice(0, parent.kindsCap)
                delegate: CategoryIcon {
                    kind: modelData
                    size: 20
                    hovered: false
                }
            }

            Rectangle {
                visible: parent.kindsHidden > 0
                width: moreText.implicitWidth + 10
                height: 20
                radius: 10
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                border.color: Theme.lineSoft
                border.width: 1

                Text {
                    id: moreText
                    anchors.centerIn: parent
                    text: "+" + parent.parent.kindsHidden
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                }
            }
        }

        // ── Footer with rule: meta left, category tag right ──
        Rectangle {
            id: footerRule
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footerRow.top
            anchors.bottomMargin: 10
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            height: 1
            color: Theme.lineSoft
        }

        Item {
            id: footerRow
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottomMargin: 14
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            height: 14

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Text {
                    text: card.wf ? card.wf.steps + " STEPS" : ""
                    color: Theme.text2
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    font.letterSpacing: 0.6
                    font.weight: Font.DemiBold
                }
                Text {
                    text: "·"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    visible: card.wf && card.wf.imports
                }
                Text {
                    text: card.wf ? _formatCount(card.wf.imports) + " installs" : ""
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    font.letterSpacing: 0.4
                    visible: card.wf && card.wf.imports
                }
            }

            // Category tag in the same slot library cards use for the
            // "imported from @x" badge — right-anchored, hairline pill
            // so it sits as quiet metadata, not a CTA.
            Rectangle {
                visible: card.wf && card.wf.category && card.wf.category.length > 0
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: tagText.implicitWidth + 12
                height: 16
                radius: 8
                color: "transparent"
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                border.width: 1
                Text {
                    id: tagText
                    anchors.centerIn: parent
                    text: card.wf ? card.wf.category : ""
                    color: Theme.accent
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    font.letterSpacing: 0.3
                }
            }
        }
    }

    // Compact "1.2k" / "12k" formatter so install counts stay readable
    // in the footer's tiny mono register. 4-digit raw values eat the
    // available width and fight the STEPS / category tag for space.
    function _formatCount(n) {
        if (!n || n < 1000) return (n || 0).toString()
        if (n < 10000) return (Math.floor(n / 100) / 10).toFixed(1) + "k"
        return Math.floor(n / 1000) + "k"
    }
}
