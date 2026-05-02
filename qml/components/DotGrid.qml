import QtQuick
import Wflow

// Subtle dot-grid background. Lives behind the workflow editor canvas
// so the surface reads as graph paper, not a flat document. Other
// pages render against the plain Theme.bg.
//
// Dots use Theme.text2 at low alpha so they pick up whichever palette
// is active — light dots on dark surfaces, dark dots on cream paper —
// without any per-palette branching. 28px spacing, 2.5px dot.
//
// Repaints on resize, theme flip, and palette flip; cheap enough that
// it can sit under the whole canvas without measurable cost.
Item {
    id: root
    property real spacing: 28
    property real dotSize: 2.5
    property color dotColor: Qt.rgba(Theme.text2.r, Theme.text2.g, Theme.text2.b, 0.10)
    property color baseColor: Theme.bg

    Rectangle {
        anchors.fill: parent
        color: root.baseColor
    }

    Canvas {
        id: dots
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.fillStyle = root.dotColor
            const step = root.spacing
            const sz = root.dotSize
            for (let y = step / 2; y < height; y += step) {
                for (let x = step / 2; x < width; x += step) {
                    ctx.fillRect(x, y, sz, sz)
                }
            }
        }
        Component.onCompleted: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        // Theme flip (light/dark) and palette flip (warm/cool) both
        // change dotColor's underlying RGB — repaint on either.
        Connections {
            target: Theme
            function onModeChanged() { dots.requestPaint() }
            function onPaletteChanged() { dots.requestPaint() }
        }
    }
}
