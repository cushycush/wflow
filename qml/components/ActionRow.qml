import QtQuick
import QtQuick.Controls
import Wflow

// A single action in a workflow. Appearance shifts with VisualStyle.mode:
//  • Bold        — flat row, small chip, hover: surface2.
//  • Cinematic   — category-tinted fill, icon badge, hover: scale 1.015 + brighter tint.
//  • Maximalist  — Cinematic + active step pulse aura + slow chip shimmer.
Rectangle {
    id: root
    property int index: 0
    property string kind: "wait"
    property string summary: ""
    property string valueText: ""
    property bool active: false
    property bool hasError: false
    property string errorMessage: ""
    property color categoryColor: {
        const t = ({
            "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
            "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
            "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
            "clipboard": Theme.catClip, "note": Theme.catNote
        })
        return t[kind] || Theme.catWait
    }
    signal activated()
    signal removeRequested()

    implicitHeight: (root.hasError ? 76 : 60) + (root.summary ? 14 : 0)
    radius: Theme.radiusMd

    // Base color — surface + category tint (cinematic) + active lift
    color: {
        if (VisualStyle.categoryTintedRow) {
            const c = root.categoryColor
            const alpha = root.active ? 0.18 :
                          hoverArea.containsMouse ? 0.12 : 0.07
            return Qt.rgba(c.r, c.g, c.b, alpha)
        }
        // Bold mode: plain flat surfaces
        return root.active
            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.08)
            : (hoverArea.containsMouse ? Theme.surface2 : Theme.surface)
    }
    Behavior on color { ColorAnimation { duration: Theme.durFast } }

    border.color: {
        if (root.hasError) return Theme.err
        if (root.active) return root.categoryColor
        if (VisualStyle.categoryTintedRow && hoverArea.containsMouse) {
            const c = root.categoryColor
            return Qt.rgba(c.r, c.g, c.b, 0.45)
        }
        return Theme.lineSoft
    }
    border.width: root.active ? 1 : 1
    Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

    // Hover scale (cinematic)
    transform: Scale {
        origin.x: root.width / 2
        origin.y: root.height / 2
        xScale: (VisualStyle.rowHoverScale && hoverArea.containsMouse) ? 1.012 : 1.0
        yScale: xScale
        Behavior on xScale { NumberAnimation { duration: Theme.durFast; easing.type: Easing.OutCubic } }
    }

    // Active-step aura (maximalist)
    Rectangle {
        visible: VisualStyle.richActiveStep && root.active
        anchors.centerIn: parent
        width: parent.width + 8
        height: parent.height + 8
        radius: parent.radius + 2
        color: "transparent"
        border.color: root.categoryColor
        border.width: 1
        opacity: 0.55
        z: -1
        SequentialAnimation on opacity {
            running: VisualStyle.richActiveStep && root.active
            loops: Animation.Infinite
            NumberAnimation { to: 0.15; duration: 1100; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.55; duration: 1100; easing.type: Easing.InOutSine }
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 12
        spacing: 14

        // Step index
        Text {
            text: String(root.index).padStart(2, "0")
            color: root.active ? root.categoryColor : Theme.text3
            font.family: Theme.familyMono
            font.pixelSize: Theme.fontSm
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            Behavior on color { ColorAnimation { duration: Theme.durFast } }
        }

        // Category — icon (cinematic+) or chip (bold)
        Loader {
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: VisualStyle.categoryIcons ? iconComp
                           : VisualStyle.isCinematic  ? iconComp
                           : chipComp
            Component {
                id: iconComp
                CategoryIcon {
                    kind: root.kind
                    size: 32
                    hovered: hoverArea.containsMouse
                }
            }
            Component {
                id: chipComp
                CategoryChip { kind: root.kind }
            }
        }

        // Summary + value
        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 22 - 14 - 44 - 14 - removeBtn.width - 12
            spacing: 2

            Text {
                text: root.summary
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontBase
                font.weight: Font.Medium
                visible: text.length > 0
                elide: Text.ElideRight
                width: parent.width
            }
            Text {
                text: root.valueText
                color: Theme.text2
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontSm
                visible: text.length > 0 && !root.hasError
                elide: Text.ElideRight
                width: parent.width
            }
            Text {
                text: root.errorMessage
                color: Theme.err
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontXs
                visible: root.hasError && text.length > 0
                elide: Text.ElideRight
                width: parent.width
                wrapMode: Text.NoWrap
            }
        }

        // Delete on hover
        IconButton {
            id: removeBtn
            iconText: "×"
            iconColor: Theme.text3
            hoverColor: Theme.err
            opacity: hoverArea.containsMouse ? 1.0 : 0.0
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            onClicked: root.removeRequested()
            Behavior on opacity { NumberAnimation { duration: Theme.durFast } }
        }
    }
}
