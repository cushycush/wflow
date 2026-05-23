pragma Singleton
import QtQuick
import Wflow

// Design tokens. Three brand palettes: "warm" (paper + coral, the
// wflows.io identity), "cool" (slate + amber, the original brief),
// and "drift" (slate + gold, the third skin). Each token picks via
// `_pl(coolDark, coolLight, warmDark, warmLight, driftDark, driftLight)`.
QtObject {
    id: theme

    // StateController is the source of truth; locals mirror + write back.
    property StateController _state: StateController { }
    // Shared so Main.qml's deeplink handler and SettingsPage's sign-in
    // UI see the same nonce.
    property AuthController _auth: AuthController { }
    property string mode: theme._state.theme_mode || "auto"
    property string palette: theme._state.palette || "warm"

    function cycleMode() {
        const next = mode === "auto" ? "light"
                   : mode === "light" ? "dark" : "auto"
        mode = next
        theme._state.apply_theme_mode(next)
    }

    // "warm" | "cool" | "drift"; anything else snaps to "warm" on the
    // Rust side.
    function applyPalette(p) {
        palette = p
        theme._state.apply_palette(p)
    }

    function cyclePalette() {
        const next = palette === "warm" ? "cool"
                   : palette === "cool" ? "drift" : "warm"
        applyPalette(next)
    }

    // Treat Unknown as dark (brand is dark-first).
    readonly property bool _systemDark: Qt.styleHints.colorScheme !== Qt.ColorScheme.Light
    readonly property bool isDark: mode === "dark" || (mode === "auto" && _systemDark)

    function _pl(coolDark, coolLight, warmDark, warmLight, driftDark, driftLight) {
        if (palette === "warm") {
            return isDark ? warmDark : warmLight
        }
        if (palette === "drift") {
            return isDark ? driftDark : driftLight
        }
        return isDark ? coolDark : coolLight
    }

    // Surfaces. Warm = paper / near-black (hue 35-60). Cool = slate
    // (hue 260, low chroma) / near-white cool gray. Drift = slate-blue
    // dark / cream-deep light, the drift brand.
    readonly property color bg:         _pl("#232629", "#f5f6f8", "#1b1411", "#faf8f2", "#21242d", "#e9e0d0")
    readonly property color bgDeep:     _pl("#1d2024", "#ecedf0", "#16100d", "#f4f1e9", "#181b23", "#dad0bd")
    readonly property color surface:    _pl("#2c2f33", "#fafbfd", "#251d18", "#f6f2eb", "#262b36", "#f2eadd")
    readonly property color surface2:   _pl("#383b40", "#eef0f3", "#2d241e", "#ece6da", "#2c3848", "#e9e0d0")
    readonly property color surface3:   _pl("#44484e", "#e0e3e8", "#382d26", "#ded7c7", "#3a4658", "#bfb39c")
    readonly property color line:       _pl("#4c4f55", "#cbd0d8", "#41362f", "#cbc2b0", "#3f4651", "#968f84")
    readonly property color lineSoft:   _pl("#3d4046", "#dde0e6", "#332b25", "#dfd8c7", "#2f3640", "#b0aaa0")
    readonly property color lineStrong: _pl("#6b6f78", "#95989f", "#5a4d44", "#a19682", "#525e72", "#645d50")

    // Text.
    readonly property color text:    _pl("#f0f0f4", "#1c1f25", "#f2ebdf", "#2a221c", "#e8ebf0", "#1b1f2a")
    readonly property color text2:   _pl("#b0b1ba", "#4f535d", "#b7aa98", "#5b4f44", "#a0aabc", "#3e4554")
    readonly property color text3:   _pl("#828590", "#7c8089", "#807365", "#897e70", "#7a8598", "#5e6678")
    readonly property color textInv: _pl("#232629", "#fafbfd", "#1b1411", "#f6f2eb", "#21242d", "#e9e0d0")

    // Accent. Warm = coral (hue 25-32), cool = amber (hue 55-65),
    // drift = gold (hue 40-45).
    readonly property color accent:    _pl("#e1a04a", "#9c5a18", "#ed8068", "#c73e2c", "#c9a45c", "#a78641")
    readonly property color accentHi:  _pl("#f0b964", "#b87024", "#f49b82", "#d54f3d", "#e8c77a", "#c9a45c")
    readonly property color accentLo:  _pl("#b27418", "#844614", "#e36850", "#b72a1c", "#a78641", "#7e662f")
    // Brand --accent-wash analog. accentWash(alpha) for live blends.
    readonly property color accentDim: _pl("#4a3a1d", "#f3e6cc", "#463129", "#fbe7dd", "#3d341f", "#faeec9")
    readonly property color accentInk: _pl("#1d1408", "#5b3408", "#1f140f", "#6f1808", "#181b23", "#5c4a22")

    // Text on top of a filled accent surface.
    readonly property color accentText: _pl("#1d1408", "#fffaf0", "#1f140f", "#f6f2eb", "#181b23", "#181b23")

    // Plum (secondary hue).
    readonly property color plum:     _pl("#c778a4", "#8a4a6f", "#c778a4", "#8a4a6f", "#b59baa", "#573d4a")
    readonly property color plumWash: _pl("#4a323f", "#f2dae3", "#4a323f", "#f2dae3", "#3a2932", "#ecdde3")

    // Semantic. Drift uses sage / ochre / terra brand-tier scales.
    readonly property color ok:   _pl("#6acc83", "#1f7c52", "#67bc91", "#1f8c5f", "#9bb29f", "#44594b")
    readonly property color warn: _pl("#d8c043", "#8a6512", "#dcb348", "#b68421", "#b5a87b", "#524c25")
    readonly property color err:  _pl("#de6750", "#b0392b", "#eb7a66", "#bb2c1a", "#c29586", "#5e3e2d")

    // Category chips. Cool keeps the saturated kind colors; warm uses
    // the muted ink-* register so chips don't compete with the coral.
    // Drift pulls from its brand-tier scales (plum / steel / sage /
    // teal / ochre / terra) so chips stay in the slate-gold register.
    readonly property color catKey:    _pl("#a890d2", "#6e54a8", "#a483c8", "#6c52a4", "#b59baa", "#573d4a")  // purple
    readonly property color catType:   _pl("#889bcb", "#4862ad", "#7b95c4", "#445e9e", "#9aafc4", "#3f546c")  // blue
    readonly property color catClick:  _pl("#88b08e", "#3d7c58", "#4fb082", "#1f7c52", "#9bb29f", "#44594b")  // green
    readonly property color catMove:   _pl("#7da4a8", "#437576", "#6fa1b8", "#3e6f86", "#7fafaf", "#2f5759")
    readonly property color catScroll: _pl("#80a0b8", "#436c83", "#6fa1b8", "#3d7095", "#6580a0", "#3f546c")  // cyan-blue
    readonly property color catFocus:  _pl("#c89e60", "#856425", "#bd9c50", "#856420", "#e8c77a", "#7e662f")  // amber
    readonly property color catWait:   _pl("#8e8780", "#6e6862", "#93857b", "#6e6862", "#a0aabc", "#3a4658")  // warm gray
    readonly property color catShell:  _pl("#c89070", "#985538", "#c77f4d", "#94511f", "#c29586", "#5e3e2d")  // orange
    readonly property color catNotify: _pl("#c0859e", "#9e527a", "#c77e96", "#985070", "#876275", "#876275")  // pink
    readonly property color catClip:   _pl("#80a0b0", "#436b7c", "#6fa1b8", "#3d7095", "#4d8388", "#2f5759")
    readonly property color catNote:   _pl("#807870", "#5e5650", "#807870", "#5e5650", "#7a8598", "#525e72")  // neutral
    // Flow-control tints, distinct from action kinds.
    readonly property color catWhen:   _pl("#b896b0", "#8a5a82", "#b896b0", "#8a5a82", "#b59baa", "#876275")  // mauve
    readonly property color catUnless: _pl("#c08878", "#985d4a", "#c08878", "#985d4a", "#95654f", "#5e3e2d")  // rust
    readonly property color catRepeat: _pl("#b0b878", "#748640", "#b0b878", "#748640", "#b5a87b", "#524c25")  // olive
    readonly property color catUse:    _pl("#9d90ba", "#5e4880", "#9d90ba", "#5e4880", "#876275", "#573d4a")  // dusty violet

    // 4pt spacing.
    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s5: 24
    readonly property int s6: 32
    readonly property int s7: 48
    readonly property int s8: 64

    // Radii ladder. xs=tags, sm=buttons, md=cards, lg=hero, xl=callouts.
    readonly property int radiusXs:  4
    readonly property int radiusSm:  6
    readonly property int radiusMd:  10
    readonly property int radiusLg:  16
    readonly property int radiusXl:  22
    readonly property int radiusPill: 999

    // Type scale.
    readonly property int fontXs:   11
    readonly property int fontSm:   13
    readonly property int fontBase: 14
    readonly property int fontMd:   16
    readonly property int fontLg:   20
    readonly property int fontXl:   28

    // Boska + Supreme (the wflows.io pair) read poorly at dense UI
    // sizes. Hanken Grotesk + Geist Mono.
    readonly property string familyDisplay: "Hanken Grotesk"
    readonly property string familyBody:    "Hanken Grotesk"
    readonly property string familyMono:    "Geist Mono"

    // `reduceMotion` zeroes every `dur()` return; gate infinite
    // animations on `!Theme.reduceMotion`.
    property bool reduceMotion: theme._state.reduce_motion

    function applyReduceMotion(on) {
        reduceMotion = on
        theme._state.apply_reduce_motion(on)
    }

    // Falls back to a bundled mock catalog so the tab never paints empty.
    readonly property bool showExplore: true
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
    // KDL syntax-highlight palette. Token kinds come from
    // `kdl_format::highlight::tokenize`. The keyword color tracks
    // `accent` so structural words read in the active brand tone;
    // everything else picks a distinct hue from the category set so
    // the four palette skins stay distinguishable on the source pane.
    function kdlColor(kind) {
        switch (kind) {
        case "keyword": return accent
        case "node":    return catType
        case "prop":    return catMove
        case "string":  return catClick
        case "number":  return catRepeat
        case "bool":    return catKey
        case "ident":   return text2
        case "punct":   return text3
        case "comment": return text3
        }
        return text
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

    // Most icons read at 13px; a few need a bump to feel even.
    function catGlyphSize(kind) {
        switch (kind) {
        case "shell":   return 16
        case "wait":    return 15
        case "repeat":  return 16
        }
        return 13
    }
    function wash(c, alpha) { return Qt.rgba(c.r, c.g, c.b, alpha) }
    function accentWash(alpha) { return wash(accent, alpha) }

    // Gradient pairs (A=light, B=deep). Same `gradFor(kind)` reads
    // as the same hue on either theme (stops differ, hues don't).
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

    // Stable per-handle assignment by first-char hash.
    function gradForHandle(handle) {
        if (!handle || handle.length === 0) return [gradCyanA, gradCyanB]
        const _kinds = ["key", "rose", "violet", "shell", "wait",
                        "lime", "type", "magenta", "focus", "notify"]
        const c = handle.replace(/^@/, "").toLowerCase().charCodeAt(0) || 0
        return gradFor(_kinds[c % _kinds.length])
    }

    // Text on top of a gradient pair. Amber/lime/cyan want near-black.
    function gradTextColor(kind) {
        switch (kind) {
        case "focus": case "trigger": case "lime": case "repeat": return "#1a1208"
        case "wait": case "click": case "key": case "move": case "scroll":
            return isDark ? "#0a1320" : "#ffffff"
        }
        return "#ffffff"
    }

    // Layered card shadow. Apply via `layer.effect: MultiEffect`.
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
