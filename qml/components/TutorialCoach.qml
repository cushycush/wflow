import QtQuick
import Wflow

// First-run guided tour. Replaces the static IntroTutorial dialog
// with a coach-mark overlay that tracks specific UI elements,
// animates between them as the user advances, and breaks the same
// content into smaller, anchored steps.
//
// Each step in `steps` is:
//   { title, body, getTarget?, placement?, page?, scrim? }
//
//   title       — short headline
//   body        — one focused sentence or two
//   getTarget   — () => Item; returns the QML item to point at, or
//                 null for a centered modal step (no target)
//   placement   — "above" | "below" | "left" | "right" | "auto"
//                 (default: auto, prefers below)
//   page        — "library" | "explore" | "workflow" | "record" |
//                 "settings" — switch to this page before showing
//                 the step. Optional; omitted = stay where you are.
//   scrim       — true/false. Default true. Dims the page so the
//                 target reads as the focal point.
//
// Lifecycle: stateCtrl marks the tour key as seen on Skip / Finish.
// The key is bumped (intro_tour → intro_tour_v2 → ...) whenever the
// step list grows materially so existing users get one more pass at
// the new content instead of silently inheriting the old "seen"
// flag. Bump it again the next time you add a step.
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

    // Page-navigation hook. Main.qml routes this to its
    // currentPage setter.
    signal navigateToPage(string page)

    readonly property var current:
        (step >= 0 && step < steps.length) ? steps[step] : null

    // Resolve the current step's target lazily — getTarget may
    // reference items that don't exist yet on first read (e.g. the
    // editor canvas before any document is open). A stale read
    // returns null and the step degrades to a centered modal.
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
        if (stateCtrl) stateCtrl.mark_tutorial_seen("intro_tour_v2")
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

    // ---- Scrim ----
    // Soft dim, not full block. The target stays visible through
    // it; the spotlight halo + callout do the focusing.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.42)
        opacity: (root.current && root.current.scrim === false) ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
        // Click anywhere on the scrim to skip out. Coach-mark tours
        // that trap focus feel hostile; let the user bail at any time.
        MouseArea {
            anchors.fill: parent
            onClicked: root._finish()
        }
    }

    // ---- Spotlight halo ----
    // Accent-tinted rounded rect that grows around the target. Soft
    // pulse keeps it discoverable. Geometry animates via Behaviors,
    // so step-to-step transitions glide rather than snap.
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

        // Inner glow — a subtle accent wash inside the halo to
        // brighten the target's surroundings without obscuring it.
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: parent.radius - 1
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.08)
            border.width: 0
        }

        // Slow breathing pulse so the eye snaps to the halo without
        // it feeling agitated. Gates on Theme.reduceMotion so the
        // accessibility setting kills it cleanly.
        SequentialAnimation on opacity {
            running: root._hasTarget && root.open && !Theme.reduceMotion
            loops: Animation.Infinite
            NumberAnimation { from: 0.7; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { from: 1.0; to: 0.7; duration: 900; easing.type: Easing.InOutSine }
        }
    }

    // ---- Callout box ----
    // Floating card with the step's text and Back / Skip / Next.
    // Position animates with the halo so the whole tour feels like
    // one moving thing, not a static dialog that snaps to the
    // active target.
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

        // Auto-placement: pick the side of the target with the most
        // room. Defaults to "below" because most page chrome lives
        // at the top, leaving more vertical room beneath.
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

            // Step indicator pills + Skip. Use an Item with anchored
            // children so the dots stay left-aligned and Skip stays
            // right-aligned at any callout width.
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

            // Title
            Text {
                width: parent.width
                text: root.current ? root.current.title : ""
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
            }

            // Body
            Text {
                width: parent.width
                text: root.current ? root.current.body : ""
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }

            // Nav row
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

    // Keyboard nav — Esc skips, ←/→ for back/next.
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
