import QtQuick
import Wflow

// Per-kind glyph table with a size multiplier + 2D nudge so each
// Unicode glyph can be optically centred against its bounding box.
// Numbers tuned by eye; adjust when a kind looks off.
Rectangle {
    id: root
    property string kind: "wait"
    property real size: 36
    property bool hovered: false

    readonly property color _c: Theme.catFor(kind)
    readonly property string _g: Theme.catGlyph(kind)

    width: size
    height: size
    // Caps at radiusMd so a big CategoryIcon doesn't read as a circle.
    radius: Math.min(Theme.radiusMd, Math.max(3, Math.round(size * 0.22)))
    color: Theme.wash(_c, root.hovered ? 0.24 : 0.16)

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.color: Theme.wash(root._c, root.hovered ? 0.6 : 0.35)
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: Theme.dur(160) } }
    }

    // Default 0.55, calibrated so "T" reads correctly at any size.
    function _glyphRatio(k) {
        switch (k) {
        case "wait":      return 0.78   // ⏱ has whitespace, render bigger
        case "shell":     return 0.46   // ❯ is wide; trim back
        case "repeat":    return 0.60
        case "scroll":    return 0.58
        case "move":      return 0.58
        case "clipboard": return 0.58
        case "type":      return 0.52
        case "key":       return 0.56
        case "click":     return 0.54
        case "notify":    return 0.58
        case "note":      return 0.55
        case "when":      return 0.58
        case "unless":    return 0.58
        case "use":       return 0.58
        }
        return 0.55
    }

    // Fractional-of-size units. +y down, +x right. Default +y because
    // Qt's Text reserves descender space most of these glyphs don't
    // use, hanging the glyph above visual center.
    function _nudgeX(k) {
        switch (k) {
        case "type":   return 0.04    // T sits visually left of its bounding box
        case "shell":  return -0.02   // ❯ leans right; pull it back
        case "notify": return -0.03   // ◐ is heavier on the left, pull leftward to compensate
        }
        return 0.0
    }
    function _nudgeY(k) {
        switch (k) {
        case "click":     return -0.02   // ◉ floats high but the glyph is dense, lift it
        case "shell":     return -0.02   // ❯ chevron sits low against the cap line
        case "notify":    return -0.01   // pull up off the descender padding
        case "clipboard": return -0.01
        case "use":       return -0.01   // @ glyph hangs slightly low
        case "type":      return 0.06    // T reads quite high; push down hardest
        case "wait":      return 0.04    // timer's pendulum hangs slightly low
        case "note":      return -0.04   // pilcrow has its own descender
        }
        return 0.03   // generic small downward nudge for descender padding
    }

    Text {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: Math.round(root.size * root._nudgeX(root.kind))
        anchors.verticalCenterOffset:   Math.round(root.size * root._nudgeY(root.kind))
        text: root._g
        color: root._c
        font.family: Theme.familyBody
        font.pixelSize: Math.max(10, Math.round(root.size * root._glyphRatio(root.kind)))
        font.weight: Font.Bold

        rotation: (VisualStyle.iconHoverSpin && root.hovered) ? 8 : 0
        scale: (VisualStyle.iconHoverSpin && root.hovered) ? 1.08 : 1.0
        Behavior on rotation { NumberAnimation { duration: Theme.dur(240); easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: Theme.dur(240); easing.type: Easing.OutCubic } }
    }
}
