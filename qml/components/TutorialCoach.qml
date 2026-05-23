import QtQuick
import Wflow

// Coach-mark tour. Each step is { title, body, getTarget?, placement?,
// page?, scrim?, paletteChooser? }. Bump intro_tour_vN whenever the
// step list grows materially so existing users see the new content.
Item {
    id: root
    anchors.fill: parent
    visible: opacity > 0.01
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durBase); easing.type: Easing.OutCubic } }
    z: 1000

    property bool open: false
    property var stateCtrl: null
    property var steps: []
    property int step: 0

    signal navigateToPage(string page)

    readonly property var current:
        (step >= 0 && step < steps.length) ? steps[step] : null

    // Lazy because getTarget can reference items that don't exist yet
    // (editor canvas before a doc is open). Null falls through to a
    // centered modal.
    readonly property var _target: {
        if (!current || !current.getTarget) return null
        try {
            const t = current.getTarget()
            return (t && t.visible) ? t : null
        } catch (e) {
            return null
        }
    }
    readonly property bool _hasTarget: _target !== null

    readonly property rect _targetRect: {
        if (!_hasTarget) return Qt.rect(0, 0, 0, 0)
        const p = _target.mapToItem(root, 0, 0)
        return Qt.rect(p.x, p.y, _target.width, _target.height)
    }

    function start() {
        step = 0
        if (current && current.page) navigateToPage(current.page)
        open = true
    }

    function _finish() {
        open = false
        if (stateCtrl) stateCtrl.mark_tutorial_seen("intro_tour_v3")
    }

    function _next() {
        if (step >= steps.length - 1) {
            _finish()
            return
        }
        step += 1
        if (current && current.page) navigateToPage(current.page)
    }

    function _back() {
        if (step > 0) {
            step -= 1
            if (current && current.page) navigateToPage(current.page)
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.42)
        opacity: (root.current && root.current.scrim === false) ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
        // Click anywhere to bail; trapping focus on a tour feels hostile.
        MouseArea {
            anchors.fill: parent
            onClicked: root._finish()
        }
    }

    Rectangle {
        id: halo
        readonly property real margin: 8
        x: root._hasTarget ? root._targetRect.x - margin : root.width / 2
        y: root._hasTarget ? root._targetRect.y - margin : root.height / 2
        width: root._hasTarget ? root._targetRect.width + margin * 2 : 0
        height: root._hasTarget ? root._targetRect.height + margin * 2 : 0
        radius: Theme.radiusMd + 4
        color: "transparent"
        border.color: Theme.accent
        border.width: 2
        visible: root._hasTarget
        Behavior on x { NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Easing.InOutCubic } }
        Behavior on y { NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Easing.InOutCubic } }
        Behavior on width { NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Easing.InOutCubic } }
        Behavior on height { NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Easing.InOutCubic } }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: parent.radius - 1
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.08)
            border.width: 0
        }

        SequentialAnimation on opacity {
            running: root._hasTarget && root.open && !Theme.reduceMotion
            loops: Animation.Infinite
            NumberAnimation { from: 0.7; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { from: 1.0; to: 0.7; duration: 900; easing.type: Easing.InOutSine }
        }
    }

    Rectangle {
        id: callout
        width: 380
        implicitHeight: calloutBody.implicitHeight + 32
        height: implicitHeight
        radius: Theme.radiusMd
        color: Theme.surface
        border.color: Theme.line
        border.width: 1

        readonly property string _placement:
            root.current && root.current.placement
                ? root.current.placement : "auto"

        readonly property real _gap: 18

        // Most chrome lives at the top, so "below" is the default fallback.
        readonly property string _resolvedPlacement: {
            if (!root._hasTarget) return "center"
            if (_placement !== "auto") return _placement
            const tr = root._targetRect
            const roomAbove = tr.y
            const roomBelow = root.height - (tr.y + tr.height)
            const roomLeft  = tr.x
            const roomRight = root.width - (tr.x + tr.width)
            if (roomBelow >= height + _gap) return "below"
            if (roomAbove >= height + _gap) return "above"
            if (roomRight >= width + _gap)  return "right"
            return "left"
        }

        x: {
            if (!root._hasTarget) return (root.width - width) / 2
            const tr = root._targetRect
            const p = _resolvedPlacement
            let v
            if (p === "left")  v = tr.x - width - _gap
            else if (p === "right") v = tr.x + tr.width + _gap
            else v = tr.x + tr.width / 2 - width / 2
            return Math.max(16, Math.min(root.width - width - 16, v))
        }
        y: {
            if (!root._hasTarget) return (root.height - height) / 2
            const tr = root._targetRect
            const p = _resolvedPlacement
            let v
            if (p === "above") v = tr.y - height - _gap
            else if (p === "below") v = tr.y + tr.height + _gap
            else v = tr.y + tr.height / 2 - height / 2
            return Math.max(16, Math.min(root.height - height - 16, v))
        }
        Behavior on x      { NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Easing.InOutCubic } }
        Behavior on y      { NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Easing.InOutCubic } }
        Behavior on height { NumberAnimation { duration: Theme.dur(Theme.durFast) } }

        Column {
            id: calloutBody
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            Item {
                width: parent.width
                height: 22

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Repeater {
                        model: root.steps.length
                        delegate: Rectangle {
                            width: model.index === root.step ? 22 : 6
                            height: 6
                            radius: 3
                            color: model.index === root.step
                                ? Theme.accent
                                : (model.index < root.step
                                    ? Theme.wash(Theme.accent, 0.55)
                                    : Theme.surface3)
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on width { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                        }
                    }
                }

                Rectangle {
                    id: skipBtn
                    width: skipText.implicitWidth + 16
                    height: 22
                    radius: Theme.radiusSm
                    color: skipArea.containsMouse ? Theme.surface2 : "transparent"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Text {
                        id: skipText
                        anchors.centerIn: parent
                        text: "Skip"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        id: skipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._finish()
                    }
                }
            }

            Text {
                width: parent.width
                text: root.current ? root.current.title : ""
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
            }

            Text {
                width: parent.width
                text: root.current ? root.current.body : ""
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }

            // Tiles draw from hardcoded hex pairs (not Theme tokens) so
            // each tile previews its OWN palette regardless of active.
            Row {
                width: parent.width
                spacing: 10
                visible: root.current && root.current.paletteChooser === true

                Repeater {
                    model: [
                        {
                            id: "warm",
                            label: "Warm Paper",
                            sub: "wflows.io brand",
                            bg:      "#faf8f2",
                            bgDark:  "#1b1411",
                            surface: "#ece6da",
                            accent:  "#c73e2c",
                            line:    "#cbc2b0"
                        },
                        {
                            id: "cool",
                            label: "Cool Slate",
                            sub: "Original brand",
                            bg:      "#f5f6f8",
                            bgDark:  "#232629",
                            surface: "#383b40",
                            accent:  "#e1a04a",
                            line:    "#4c4f55"
                        },
                        {
                            id: "drift",
                            label: "Drift",
                            sub: "drift brand",
                            bg:      "#e9e0d0",
                            bgDark:  "#21242d",
                            surface: "#2c3848",
                            accent:  "#c9a45c",
                            line:    "#3f4651"
                        }
                    ]
                    delegate: Rectangle {
                        readonly property bool isSelected: Theme.palette === modelData.id
                        readonly property bool useDark: Theme.isDark
                        width: (parent.width - parent.spacing * 2) / 3
                        height: 92
                        radius: Theme.radiusMd
                        color: useDark ? modelData.bgDark : modelData.bg
                        border.color: isSelected ? Theme.accent : Theme.line
                        border.width: isSelected ? 2 : 1
                        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                        Behavior on border.width { NumberAnimation { duration: Theme.dur(Theme.durFast) } }

                        Column {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 6

                            Row {
                                spacing: 6
                                width: parent.width
                                Rectangle {
                                    width: 14; height: 14
                                    radius: 7
                                    color: modelData.accent
                                }
                                Rectangle {
                                    width: parent.width - 14 - 6 - 6 - 18
                                    height: 6
                                    radius: 3
                                    color: modelData.surface
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Rectangle {
                                    width: 18; height: 6
                                    radius: 3
                                    color: modelData.line
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Text {
                                text: modelData.label
                                color: useDark ? "#f0ece5" : "#2a221c"
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontBase
                                font.weight: Font.DemiBold
                            }
                            Text {
                                text: modelData.sub
                                color: useDark ? "#9b8f80" : "#7c7066"
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontXs
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Theme.applyPalette(modelData.id)
                        }
                    }
                }
            }

            Row {
                width: parent.width
                spacing: 8

                Rectangle {
                    width: backText.implicitWidth + 24
                    height: 30
                    radius: Theme.radiusSm
                    color: backArea.containsMouse ? Theme.surface2 : "transparent"
                    border.color: Theme.lineSoft
                    border.width: 1
                    visible: root.step > 0
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Text {
                        id: backText
                        anchors.centerIn: parent
                        text: "Back"
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        id: backArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._back()
                    }
                }

                Item {
                    width: Math.max(0, parent.width
                        - (root.step > 0 ? backText.implicitWidth + 24 + 8 : 0)
                        - nextText.implicitWidth - 32)
                    height: 1
                }

                Rectangle {
                    width: nextText.implicitWidth + 32
                    height: 30
                    radius: Theme.radiusSm
                    color: nextArea.containsMouse ? Theme.accentHi : Theme.accent
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Text {
                        id: nextText
                        anchors.centerIn: parent
                        text: root.step === root.steps.length - 1 ? "Get started" : "Next →"
                        color: Theme.accentText
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                    }
                    MouseArea {
                        id: nextArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._next()
                    }
                }
            }
        }
    }

    Keys.onPressed: (event) => {
        if (!open) return
        switch (event.key) {
        case Qt.Key_Escape: _finish(); event.accepted = true; break
        case Qt.Key_Left:   _back();   event.accepted = true; break
        case Qt.Key_Right:
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            _next(); event.accepted = true; break
        }
    }
    focus: open
}
