import QtQuick
import QtQuick.Controls
import Wflow

// Editable title/subtitle render as borderless TextFields when their
// *Editable flag is set; commit on focus loss or Return.
Rectangle {
    id: root
    color: Theme.bg
    height: 56
    property string title: ""
    property string subtitle: ""
    property bool titleEditable: false
    property bool subtitleEditable: false
    property bool backVisible: false
    default property alias actions: actionRow.data

    // Index 0 = workflow root, last entry = current depth. Replaces
    // the subtitle row so the topbar height stays 56.
    property var crumbLabels: []
    signal crumbClicked(int depth)

    readonly property bool _crumbVisible: root.crumbLabels.length > 1

    signal titleCommitted(string newTitle)
    signal subtitleCommitted(string newSubtitle)
    signal backClicked()

    Rectangle {
        height: 1
        color: Theme.lineSoft
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 12

        Rectangle {
            id: backBtn
            visible: root.backVisible
            width: visible ? 32 : 0
            height: 32
            radius: 6
            anchors.verticalCenter: parent.verticalCenter
            color: backArea.containsMouse ? Theme.surface2 : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.durFast } }

            Text {
                anchors.centerIn: parent
                text: "←"
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: 18
            }

            MouseArea {
                id: backArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.backClicked()
                ToolTip.visible: containsMouse
                ToolTip.delay: 400
                ToolTip.text: "Back to library"
            }
        }

        Column {
            width: parent.width - backBtn.width - actionRow.width - 28
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                visible: !root.titleEditable
                text: root.title
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                width: parent.width
            }
            TextField {
                id: titleField
                visible: root.titleEditable
                width: parent.width
                text: root.title
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                selectByMouse: true
                leftPadding: 0
                rightPadding: 0
                topPadding: 0
                bottomPadding: 0
                background: Rectangle {
                    color: "transparent"
                    border.color: titleField.activeFocus ? Theme.accent : "transparent"
                    border.width: 1
                    radius: 2
                }
                // Don't clobber in-progress typing on upstream changes.
                property string upstream: root.title
                onUpstreamChanged: if (!activeFocus) text = upstream
                // Per-keystroke; the page's save is debounced.
                function _commit() {
                    if (text !== root.title) root.titleCommitted(text)
                }
                onTextEdited: _commit()
                onEditingFinished: _commit()
            }

            Row {
                visible: root._crumbVisible
                spacing: 4
                topPadding: 2

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "in"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Bold
                    font.letterSpacing: 1.0
                    rightPadding: 6
                }

                Repeater {
                    model: root.crumbLabels
                    delegate: Row {
                        spacing: 4
                        readonly property bool isLast: model.index === root.crumbLabels.length - 1

                        Rectangle {
                            id: crumbChip
                            anchors.verticalCenter: parent.verticalCenter
                            height: 22
                            width: crumbText.implicitWidth + 14
                            radius: Theme.radiusSm
                            color: parent.isLast
                                ? Theme.accentWash(0.18)
                                : (chipMA.containsMouse ? Theme.surface3 : Theme.surface2)
                            border.color: parent.isLast
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                                : Theme.lineSoft
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }
                            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                            Text {
                                id: crumbText
                                anchors.centerIn: parent
                                text: modelData
                                color: parent.parent.isLast
                                    ? Theme.accent
                                    : (chipMA.containsMouse ? Theme.text : Theme.text2)
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontXs
                                font.weight: parent.parent.isLast ? Font.Bold : Font.Medium
                            }

                            MouseArea {
                                id: chipMA
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: !parent.parent.isLast
                                cursorShape: enabled
                                    ? Qt.PointingHandCursor
                                    : Qt.ArrowCursor
                                onClicked: root.crumbClicked(model.index)
                            }
                        }

                        Text {
                            visible: !parent.isLast
                            anchors.verticalCenter: parent.verticalCenter
                            text: "›"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.Medium
                        }
                    }
                }
            }

            Text {
                visible: !root._crumbVisible && !root.subtitleEditable && root.subtitle.length > 0
                text: root.subtitle
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                elide: Text.ElideRight
                width: parent.width
            }
            TextField {
                id: subtitleField
                visible: !root._crumbVisible && root.subtitleEditable
                width: parent.width
                text: root.subtitle
                placeholderText: "add a subtitle…"
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                selectByMouse: true
                leftPadding: 0
                rightPadding: 0
                topPadding: 0
                bottomPadding: 0
                background: Rectangle {
                    color: "transparent"
                    border.color: subtitleField.activeFocus ? Theme.accent : "transparent"
                    border.width: 1
                    radius: 2
                }
                property string upstream: root.subtitle
                onUpstreamChanged: if (!activeFocus) text = upstream
                function _commit() {
                    if (text !== root.subtitle) root.subtitleCommitted(text)
                }
                onTextEdited: _commit()
                onEditingFinished: _commit()
            }
        }

        Row {
            id: actionRow
            spacing: 8
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
