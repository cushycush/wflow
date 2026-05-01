pragma Singleton
import QtQuick
import Wflow

// Design tokens. Dark and light palettes both defined; the active one is
// picked via `mode` which defaults to "auto" (follow the desktop).
QtObject {
    id: theme

    // Persisted via StateController — _state.theme_mode is the
    // source of truth, this property mirrors it and writes back on
    // cycleMode so the user's choice survives a restart.
    property StateController _state: StateController { }
    property string mode: theme._state.theme_mode || "auto"

    function cycleMode() {
        const next = mode === "auto" ? "light"
                   : mode === "light" ? "dark" : "auto"
        mode = next
        theme._state.apply_theme_mode(next)
    }

    // Dark when the system reports Dark OR when it reports Unknown (e.g.
    // Hyprland without the xdg-desktop-portal appearance shim). The brand is
    // dark-first, so "no idea" → dark rather than surprising people with a
    // light flash.
    readonly property bool _systemDark: Qt.styleHints.colorScheme !== Qt.ColorScheme.Light
    readonly property bool isDark: mode === "dark" || (mode === "auto" && _systemDark)

    // ============ Surfaces ============
    // EXPERIMENT: warm-paper / warm-ink palette mirrored from wflows.com
    // (hue 35-60, not the parent's cool steel-blue 260). Surfaces still
    // step up by ~0.04 lightness so hovered/selected rows read clearly,
    // they just sit in a warmer tonal world.
    readonly property color bg:        isDark ? "#1a1611" : "#faf7f1"
    readonly property color surface:   isDark ? "#221d17" : "#f5f0e7"
    readonly property color surface2:  isDark ? "#2b241d" : "#e8e1d5"
    readonly property color surface3:  isDark ? "#342c23" : "#dad2c4"
    readonly property color line:      isDark ? "#3e362c" : "#c9beac"
    readonly property color lineSoft:  isDark ? "#2f281f" : "#dad2c5"

    // ============ Text ============
    readonly property color text:      isDark ? "#f4ede0" : "#2c2722"
    readonly property color text2:     isDark ? "#c2b6a2" : "#5d544a"
    readonly property color text3:     isDark ? "#8e8472" : "#87796c"

    // ============ Accent (warm coral) ============
    // EXPERIMENT: brand-aligned coral from wflows.com. Light mode runs a
    // darker coral so the fill carries enough contrast on cream surfaces.
    readonly property color accent:    isDark ? "#ff7565" : "#c43625"
    readonly property color accentHi:  isDark ? "#ff917f" : "#d34536"
    readonly property color accentLo:  isDark ? "#f15244" : "#ad2818"
    readonly property color accentDim: isDark ? "#4a2620" : "#f3d3cc"

    // Text color sitting on top of a filled accent surface (button fills etc).
    // Bright dark-mode coral carries deep warm near-black; darker light-mode
    // coral can't, so it flips to off-white. (Name avoids the `on<X>`
    // signal-handler pattern.)
    readonly property color accentText: isDark ? "#1a0a08" : "#fff7f5"

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
    // Flow-control tints — visually distinct from action kinds so the
    // structural blocks read as different beasts.
    readonly property color catWhen:    isDark ? "#df88d6" : "#a056a0"
    readonly property color catUnless:  isDark ? "#ee8896" : "#c45670"
    readonly property color catRepeat:  isDark ? "#cae870" : "#7da030"
    readonly property color catUse:     isDark ? "#a08ed0" : "#5a4090"

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
    // EXPERIMENT: bumped to wflows.com's 8/12/16 (it ships md=10, lg=16,
    // xl=22; we keep three steps and use the editorial register).
    readonly property int radiusSm: 8
    readonly property int radiusMd: 12
    readonly property int radiusLg: 16

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
    //
    // Mirrors StateController.reduce_motion so the user's choice survives a
    // restart. Flip via `Theme.applyReduceMotion(bool)` from the Settings
    // page; direct assignment also works but won't persist.
    property bool reduceMotion: theme._state.reduce_motion

    function applyReduceMotion(on) {
        reduceMotion = on
        theme._state.apply_reduce_motion(on)
    }

    // ============ Feature flags ============
    // Explore is hidden in 0.4.0 — the page renders but the catalog is
    // mock data until wflows.com integration lands. We'll flip this back
    // on as part of the wflows.com release branch (sign-in, real detail
    // drawer data, deeplink confirm dialog all land together).
    readonly property bool showExplore: false
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
        case "when":      return catWhen
        case "unless":    return catUnless
        case "repeat":    return catRepeat
        case "use":       return catUse
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
        case "shell":     return "❯"
        case "notify":    return "◐"
        case "clipboard": return "⎘"
        case "note":      return "¶"
        case "when":      return "?"
        case "unless":    return "!"
        case "repeat":    return "↻"
        case "use":       return "@"
        }
        return "•"
    }

    // Glyph-specific size tuning. Most icons read at the chip's
    // baseline (13px), but a few glyphs are visually narrower than
    // letterforms / geometric shapes at the same point size —
    // bumping them keeps the icon row feeling even.
    function catGlyphSize(kind) {
        switch (kind) {
        case "shell":   return 16
        case "wait":    return 15
        case "repeat":  return 16
        }
        return 13
    }
    // Translucent wash of the accent (or any color) at a named alpha. Saves
    // call sites from copy-pasting `Qt.rgba(c.r, c.g, c.b, 0.xx)` constants.
    function wash(c, alpha) { return Qt.rgba(c.r, c.g, c.b, alpha) }
    function accentWash(alpha) { return wash(accent, alpha) }

    // ============ Gradient palette ============
    // Pairs (A = light end, B = deep end) for filling pills, avatars,
    // and accent surfaces in the new explore + canvas designs. Each
    // pair stays cohesive across modes (we tune stops, not hues, on
    // the light variant) so the same `gradFor("shell")` reads as
    // "shell" on either theme.
    readonly property color gradCyanA:    isDark ? "#7ed8e8" : "#5cc7e0"
    readonly property color gradCyanB:    isDark ? "#3a82c0" : "#2a64a8"
    readonly property color gradBlueA:    isDark ? "#88aaee" : "#6a8edc"
    readonly property color gradBlueB:    isDark ? "#5a4dcc" : "#3b3aae"
    readonly property color gradAmberA:   isDark ? "#f5be60" : "#dca243"
    readonly property color gradAmberB:   isDark ? "#cc6f24" : "#a85a18"
    readonly property color gradCoralA:   isDark ? "#f29070" : "#dd6b50"
    readonly property color gradCoralB:   isDark ? "#cc4d3a" : "#a8362a"
    readonly property color gradMagentaA: isDark ? "#df88d6" : "#c469b8"
    readonly property color gradMagentaB: isDark ? "#7a45c0" : "#5e2e9c"
    readonly property color gradVioletA:  isDark ? "#c08be0" : "#a36ec0"
    readonly property color gradVioletB:  isDark ? "#6745c0" : "#4a2ea0"
    readonly property color gradEmeraldA: isDark ? "#7ed8a4" : "#5cc188"
    readonly property color gradEmeraldB: isDark ? "#2f9966" : "#1e7c50"
    readonly property color gradRoseA:    isDark ? "#ee8896" : "#d96878"
    readonly property color gradRoseB:    isDark ? "#c04880" : "#a32e60"
    readonly property color gradLimeA:    isDark ? "#cae870" : "#9fc24a"
    readonly property color gradLimeB:    isDark ? "#5fa040" : "#4a8030"

    // Map an action kind (or any free-form key) to its gradient pair.
    // Keys mirror catFor() so call sites can reuse the same string.
    // Returns [startColor, endColor].
    function gradFor(kind) {
        switch (kind) {
        case "key":       return [gradCyanA, gradCyanB]
        case "type":      return [gradBlueA, gradBlueB]
        case "focus":     return [gradAmberA, gradAmberB]
        case "shell":     return [gradCoralA, gradCoralB]
        case "notify":    return [gradVioletA, gradVioletB]
        case "clipboard": return [gradCyanA, gradCyanB]
        case "wait":      return [gradEmeraldA, gradEmeraldB]
        case "click":     return [gradEmeraldA, gradEmeraldB]
        case "move":      return [gradCyanA, gradCyanB]
        case "scroll":    return [gradCyanA, gradCyanB]
        case "trigger":   return [gradAmberA, gradAmberB]
        case "when":      return [gradMagentaA, gradMagentaB]
        case "unless":    return [gradRoseA, gradRoseB]
        case "repeat":    return [gradLimeA, gradLimeB]
        case "use":       return [gradVioletA, gradVioletB]
        // explore-only categories
        case "rose":      return [gradRoseA, gradRoseB]
        case "lime":      return [gradLimeA, gradLimeB]
        case "violet":    return [gradVioletA, gradVioletB]
        case "magenta":   return [gradMagentaA, gradMagentaB]
        }
        return [gradCyanA, gradCyanB]
    }

    // Stable monogram → gradient assignment so `@alaina` always reads
    // as cyan, `@mhmd_dev` as magenta, etc. Hash by first char.
    function gradForHandle(handle) {
        if (!handle || handle.length === 0) return [gradCyanA, gradCyanB]
        const palette = ["key", "rose", "violet", "shell", "wait",
                         "lime", "type", "magenta", "focus", "notify"]
        const c = handle.replace(/^@/, "").toLowerCase().charCodeAt(0) || 0
        return gradFor(palette[c % palette.length])
    }

    // Text color that sits readably on top of a given gradient pair.
    // Amber/lime/cyan want a deep warm-near-black; others want white.
    function gradTextColor(kind) {
        switch (kind) {
        case "focus": case "trigger": case "lime": case "repeat": return "#1a1208"
        case "wait": case "click": case "key": case "move": case "scroll":
            return isDark ? "#0a1320" : "#ffffff"
        }
        return "#ffffff"
    }

    // ============ Drop shadow recipe ============
    // Three offsets for the layered shadow we use on cards. Apply via
    // `layer.effect: MultiEffect` (or two stacked DropShadows) — the
    // tokens themselves are just numbers + colors so the recipe stays
    // consistent across components.
    readonly property color shadowColor: isDark
        ? Qt.rgba(0.02, 0.03, 0.06, 0.55)
        : Qt.rgba(0.10, 0.15, 0.25, 0.18)
    readonly property real shadowBlurNear: 8
    readonly property real shadowBlurMid:  20
    readonly property real shadowBlurFar:  48
    readonly property real shadowYNear: 1
    readonly property real shadowYMid:  8
    readonly property real shadowYFar:  24
}
