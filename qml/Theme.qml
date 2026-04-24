pragma Singleton
import QtQuick

// Design tokens. Dark and light palettes both defined; the active one is
// picked via `mode` which defaults to "auto" (follow the desktop).
QtObject {
    // "auto" | "dark" | "light". User can override from settings later; for
    // now we follow the system unless pinned.
    property string mode: "auto"

    function cycleMode() {
        mode = mode === "auto" ? "light" : mode === "light" ? "dark" : "auto"
    }

    // Dark when the system reports Dark OR when it reports Unknown (e.g.
    // Hyprland without the xdg-desktop-portal appearance shim). The brand is
    // dark-first, so "no idea" → dark rather than surprising people with a
    // light flash.
    readonly property bool _systemDark: Qt.styleHints.colorScheme !== Qt.ColorScheme.Light
    readonly property bool isDark: mode === "dark" || (mode === "auto" && _systemDark)

    // ============ Surfaces ============
    readonly property color bg:        isDark ? "#232429" : "#f6f6f8"
    readonly property color surface:   isDark ? "#2a2b31" : "#ffffff"
    readonly property color surface2:  isDark ? "#313239" : "#eeeef1"
    readonly property color surface3:  isDark ? "#3a3b42" : "#e2e3e8"
    readonly property color line:      isDark ? "#40414a" : "#d4d5dc"
    readonly property color lineSoft:  isDark ? "#33343c" : "#e2e3e8"

    // ============ Text ============
    readonly property color text:      isDark ? "#edeef1" : "#1c1d22"
    readonly property color text2:     isDark ? "#a9acb4" : "#55585f"
    readonly property color text3:     isDark ? "#6f727a" : "#82858c"

    // ============ Accent (warm amber) ============
    // Darker in light mode for AA on white surfaces. Still recognizably the
    // same warm amber — just tuned for the new backdrop.
    readonly property color accent:    isDark ? "#e29846" : "#b8742a"
    readonly property color accentHi:  isDark ? "#f1a95a" : "#c78232"
    readonly property color accentLo:  isDark ? "#c7833a" : "#9a5f1f"
    readonly property color accentDim: isDark ? "#5a4025" : "#f1dcbe"

    // Text color sitting on top of a filled accent surface (button fills etc).
    // The amber is always light-enough in chroma that a deep warm near-black
    // reads well in both modes. (Name avoids the `on<X>` signal-handler pattern.)
    readonly property color accentText: "#1a1208"

    // ============ Semantic ============
    readonly property color ok:        isDark ? "#64c28a" : "#1e8a52"
    readonly property color warn:      isDark ? "#d8b24e" : "#8a6512"
    readonly property color err:       isDark ? "#dd6b55" : "#b0392b"

    // ============ Category chip tints ============
    readonly property color catKey:    isDark ? "#a184ea" : "#6a4ed0"
    readonly property color catType:   isDark ? "#7393e6" : "#3b5fc2"
    readonly property color catClick:  isDark ? "#64c28a" : "#1e8a52"
    readonly property color catMove:   isDark ? "#5fb3b9" : "#297d83"
    readonly property color catScroll: isDark ? "#5fb0cb" : "#246d8a"
    readonly property color catFocus:  isDark ? "#d8a74e" : "#8a6512"
    readonly property color catWait:   isDark ? "#878a94" : "#6c7079"
    readonly property color catShell:  isDark ? "#e09066" : "#a0532e"
    readonly property color catNotify: isDark ? "#da77a8" : "#b0427a"
    readonly property color catClip:   isDark ? "#62b2c7" : "#2a7f94"
    readonly property color catNote:   isDark ? "#707278" : "#5a5d62"

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
    // `reduceMotion` zeroes every duration returned by `dur()`, which is what
    // every Behavior / NumberAnimation / ColorAnimation should read instead of
    // the raw constants. Infinite animations (pulses, shimmers, ambient washes)
    // should gate their `running` flag on `!Theme.reduceMotion`.
    property bool reduceMotion: false
    readonly property int durFast: 120
    readonly property int durBase: 160
    readonly property int durSlow: 220
    readonly property int easingStd: Easing.OutCubic
    function dur(ms) { return reduceMotion ? 0 : ms }

    // ============ Category helpers ============
    // Single source of truth for the kind → color + kind → glyph maps that
    // used to be copy-pasted in every action-aware component.
    function catFor(kind) {
        switch (kind) {
        case "key":       return catKey
        case "type":      return catType
        case "click":     return catClick
        case "move":      return catMove
        case "scroll":    return catScroll
        case "focus":     return catFocus
        case "wait":      return catWait
        case "shell":     return catShell
        case "notify":    return catNotify
        case "clipboard": return catClip
        case "note":      return catNote
        }
        return catWait
    }
    function catGlyph(kind) {
        switch (kind) {
        case "key":       return "⌘"
        case "type":      return "T"
        case "click":     return "◉"
        case "move":      return "↔"
        case "scroll":    return "⇅"
        case "focus":     return "⊡"
        case "wait":      return "⏱"
        case "shell":     return "›"
        case "notify":    return "◐"
        case "clipboard": return "⎘"
        case "note":      return "¶"
        }
        return "•"
    }
    // Translucent wash of the accent (or any color) at a named alpha. Saves
    // call sites from copy-pasting `Qt.rgba(c.r, c.g, c.b, 0.xx)` constants.
    function wash(c, alpha) { return Qt.rgba(c.r, c.g, c.b, alpha) }
    function accentWash(alpha) { return wash(accent, alpha) }
}
