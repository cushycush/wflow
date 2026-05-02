import QtQuick
import Wflow

// Theme.text2 at low alpha auto-tracks palette without branching.
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

        // dotColor's RGB changes on both flips; repaint on either.
        Connections {
            target: Theme
            function onModeChanged() { dots.requestPaint() }
            function onPaletteChanged() { dots.requestPaint() }
        }
    }
}
