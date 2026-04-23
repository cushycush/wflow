pragma Singleton
import QtQuick

QtObject {
    // ============ Surfaces (dark neutral, cool tint) ============
    readonly property color bg:        "#232429"
    readonly property color surface:   "#2a2b31"
    readonly property color surface2:  "#313239"
    readonly property color surface3:  "#3a3b42"
    readonly property color line:      "#40414a"
    readonly property color lineSoft:  "#33343c"

    // ============ Text ============
    readonly property color text:      "#edeef1"
    readonly property color text2:     "#a9acb4"
    readonly property color text3:     "#6f727a"

    // ============ The one accent — warm amber ============
    readonly property color accent:    "#e29846"
    readonly property color accentHi:  "#f1a95a"
    readonly property color accentLo:  "#c7833a"
    readonly property color accentDim: "#5a4025"

    // ============ Semantic ============
    readonly property color ok:        "#64c28a"
    readonly property color warn:      "#d8b24e"
    readonly property color err:       "#dd6b55"

    // ============ Category chip tints (HTTP-method-style) ============
    readonly property color catKey:    "#a184ea"
    readonly property color catType:   "#7393e6"
    readonly property color catClick:  "#64c28a"
    readonly property color catMove:   "#5fb3b9"
    readonly property color catScroll: "#5fb0cb"
    readonly property color catFocus:  "#d8a74e"
    readonly property color catWait:   "#878a94"
    readonly property color catShell:  "#e09066"
    readonly property color catNotify: "#da77a8"
    readonly property color catClip:   "#62b2c7"
    readonly property color catNote:   "#707278"

    // ============ Spacing (4pt) ============
    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s5: 24
    readonly property int s6: 32
    readonly property int s7: 48
    readonly property int s8: 64

    // ============ Radii ============
    readonly property int radiusSm: 6
    readonly property int radiusMd: 8
    readonly property int radiusLg: 12

    // ============ Type scale ============
    readonly property int fontXs:   11
    readonly property int fontSm:   13
    readonly property int fontBase: 14
    readonly property int fontMd:   16
    readonly property int fontLg:   20
    readonly property int fontXl:   28

    // ============ Fonts ============
    readonly property string familyBody: "Hanken Grotesk"
    readonly property string familyMono: "Geist Mono"

    // ============ Motion ============
    readonly property int durFast: 120
    readonly property int durBase: 160
    readonly property int durSlow: 220
    readonly property int easingStd: Easing.OutCubic
}
