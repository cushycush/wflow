import QtQuick
import Wflow

// Subtle dot-grid background. Used app-wide as the bottom layer of
// every page so the surface reads as a workspace canvas, not a flat
// document. Themed: 28px spacing, 1.5px dots, faint white in dark
// mode and faint black in light mode.
//
// Repaints on resize; cheap enough that it can sit under the whole
// app without measurable cost.
Item {
    id: root
    property real spacing: 28
    property real dotSize: 1.5
    property color dotColor: Theme.isDark
        ? Qt.rgba(1, 1, 1, 0.05)
        : Qt.rgba(0, 0, 0, 0.05)
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

        Connections {
            target: Theme
            function onModeChanged() { dots.requestPaint() }
        }
    }
}
