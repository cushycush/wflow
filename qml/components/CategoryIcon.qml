import QtQuick
import Wflow

// Compact rounded-square icon for an action category. Foreground glyph
// (Unicode) on a tinted background. Used everywhere we need a small
// "this step is a <kind>" marker — chips, palette, inspector, library
// step row, canvas mini-cards.
//
// The radius matches the rest of the app's rounded-square language
// (see design-system.md) instead of the old circle treatment, so step
// icons sit consistently next to library cards, gradient pills, and
// the chrome.
//
// Each Unicode glyph has slightly different metrics — different
// optical centers, different cap-heights, different stem lengths.
// Rather than try to push everything through font.pixelSize alone,
// we keep two per-kind tables: a SIZE multiplier (so the timer can
// be bigger and the chevron smaller without anyone having to guess)
// and a 2D NUDGE in fractional-of-size units (so the half-circle
// notify glyph that visually leans down-left can be pulled back
// toward the center). The numbers were tuned by eye against the
// rendered output; adjust here when a kind looks off.
Rectangle {
    id: root
    property string kind: "wait"
    property real size: 36
    property bool hovered: false

    readonly property color _c: Theme.catFor(kind)
    readonly property string _g: Theme.catGlyph(kind)

    width: size
    height: size
    // Match the design-system convention: radiusSm at small sizes,
    // scaling roughly with the icon. Caps at radiusMd so a big
    // CategoryIcon doesn't read as a circle by accident.
    radius: Math.min(Theme.radiusMd, Math.max(3, Math.round(size * 0.22)))
    color: Theme.wash(_c, root.hovered ? 0.24 : 0.16)

    // Subtle outline ring that strengthens on hover.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.color: Theme.wash(root._c, root.hovered ? 0.6 : 0.35)
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: Theme.dur(160) } }
    }

    // Per-kind glyph size, expressed as a fraction of the icon's
    // size. Default of 0.55 is calibrated so a "T" reads as the right
    // weight at every size; outliers get pulled in or out from there.
    function _glyphRatio(k) {
        switch (k) {
        case "wait":      return 0.78   // ⏱ has lots of inner whitespace, render much bigger
        case "shell":     return 0.46   // ❯ is wide; trim it back
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

    // Per-kind centering nudge (in fractional-of-size units, so the
    // tuning still reads at any icon size). Positive y pushes the
    // glyph DOWN; positive x pushes it RIGHT. Defaults to a small
    // +y on most kinds because Qt's Text bounding box reserves
    // descender space that most of these glyphs don't use, leaving
    // the glyph hanging above the visual center. Per-kind overrides
    // here are tuned by eye against the rendered output — adjust
    // when a kind reads off in the editor or library.
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

        // Maximalist — slight spin on hover (from VisualStyle).
        rotation: (VisualStyle.iconHoverSpin && root.hovered) ? 8 : 0
        scale: (VisualStyle.iconHoverSpin && root.hovered) ? 1.08 : 1.0
        Behavior on rotation { NumberAnimation { duration: Theme.dur(240); easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: Theme.dur(240); easing.type: Easing.OutCubic } }
    }
}
