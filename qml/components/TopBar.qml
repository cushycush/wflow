import QtQuick
import QtQuick.Controls
import Wflow

// Top bar inside the main pane. Title on the left, contextual actions on the right.
// When `titleEditable` / `subtitleEditable` are true, the matching label renders
// as a TextField (borderless until focus) instead of plain Text. Focus loss or
// Return emits `titleCommitted` / `subtitleCommitted`.
Rectangle {
    id: root
    color: Theme.bg
    height: 56
    property string title: ""
    property string subtitle: ""
    property bool titleEditable: false
    property bool subtitleEditable: false
    // Show a back arrow on the left. Pages that are reached by
    // drilling in (e.g. WorkflowPage from Library) opt into this
    // and connect backClicked to their navigation handler.
    property bool backVisible: false
    default property alias actions: actionRow.data

    // Container-nav breadcrumb. `crumbLabels` is a parallel array
    // where index 0 is the workflow root and the last entry is the
    // currently-viewed depth. When non-empty, the breadcrumb row
    // replaces the subtitle line so the topbar height stays at 56.
    property var crumbLabels: []
    signal crumbClicked(int depth)

    readonly property bool _crumbVisible: root.crumbLabels.length > 1

    signal titleCommitted(string newTitle)
    signal subtitleCommitted(string newSubtitle)
    signal backClicked()

    // Bottom hairline
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

        // Back arrow. Only rendered when the page opts in via
        // backVisible; absent on top-level pages so the layout stays
        // identical for Library/Record/etc.
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

            // Title — plain Text when read-only, TextField when editable.
            Text {
                visible: !root.titleEditable
                text: root.title
                color: Theme.text
                font.family: Theme.familyDisplay
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
                font.family: Theme.familyDisplay
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
                // Resync from upstream when not actively focused.
                property string upstream: root.title
                onUpstreamChanged: if (!activeFocus) text = upstream
                // Auto-commit on every keystroke. Save is debounced on
                // the parent page; dirty indicator reflects the change
                // immediately so the user knows their edit is tracked.
                function _commit() {
                    if (text !== root.title) root.titleCommitted(text)
                }
                onTextEdited: _commit()
                onEditingFinished: _commit()
            }

            // Crumb row — only shown when the user has descended into
            // a container. Replaces the subtitle line so the topbar
            // doesn't grow. Each segment renders as a pill with a
            // surface-step background so it reads as nav state, not
            // supplementary copy. Active (last) crumb gets the accent
            // tint; parents are clickable to pop back.
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

            // Subtitle. Hidden while the crumb row is showing so the
            // topbar doesn't try to render two metadata lines below
            // the title.
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
