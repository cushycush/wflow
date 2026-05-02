pragma Singleton
import QtQuick
import Wflow

// Design tokens. The runtime carries TWO brand palettes side-by-side —
// "warm" (warm-paper + coral, mirroring wflows.com) and "cool" (slate
// surfaces + amber, the original wflow brand brief). The active palette
// is set on first run via the tutorial and can be flipped any time
// from Settings; persisted via StateController.
//
// Each color token below picks via `_pl(coolDark, coolLight, warmDark,
// warmLight)`, which reads both `palette` and `isDark` and returns the
// matching string. Bindings stay reactive because QML tracks every
// property the function dereferences.
QtObject {
    id: theme

    // Persisted via StateController — _state.theme_mode + _state.palette
    // are the source of truth, the local properties mirror them and
    // write back on cycleMode / applyPalette so the user's choice
    // survives a restart.
    property StateController _state: StateController { }
    property string mode: theme._state.theme_mode || "auto"
    property string palette: theme._state.palette || "warm"

    function cycleMode() {
        const next = mode === "auto" ? "light"
                   : mode === "light" ? "dark" : "auto"
        mode = next
        theme._state.apply_theme_mode(next)
    }

    // Set the palette explicitly — used by the first-run tutorial card
    // and by the Settings page segmented control. Accepts "warm" or
    // "cool"; anything else snaps back to "warm" on the Rust side.
    function applyPalette(p) {
        palette = p
        theme._state.apply_palette(p)
    }

    function cyclePalette() {
        applyPalette(palette === "warm" ? "cool" : "warm")
    }

    // Dark when the system reports Dark OR when it reports Unknown (e.g.
    // Hyprland without the xdg-desktop-portal appearance shim). The brand
    // is dark-first, so "no idea" → dark rather than surprising people
    // with a light flash.
    readonly property bool _systemDark: Qt.styleHints.colorScheme !== Qt.ColorScheme.Light
    readonly property bool isDark: mode === "dark" || (mode === "auto" && _systemDark)

    // Per-palette + per-mode color picker. Order of args is
    // (coolDark, coolLight, warmDark, warmLight) to match how the eye
    // scans the literals below. Returns a string the QML color
    // converter accepts.
    function _pl(coolDark, coolLight, warmDark, warmLight) {
        if (palette === "warm") {
            return isDark ? warmDark : warmLight
        }
        return isDark ? coolDark : coolLight
    }

    // ============ Surfaces ============
    // Warm = wflows.com warm-paper / warm-near-black (hue 35-60).
    // Cool = original wflow brand brief: slate surfaces (hue 260, low
    // chroma) for dark, near-white cool gray for light.
    readonly property color bg:         _pl("#232629", "#f5f6f8", "#1b1411", "#faf8f2")
    readonly property color bgDeep:     _pl("#1d2024", "#ecedf0", "#16100d", "#f4f1e9")
    readonly property color surface:    _pl("#2c2f33", "#fafbfd", "#251d18", "#f6f2eb")
    readonly property color surface2:   _pl("#383b40", "#eef0f3", "#2d241e", "#ece6da")
    readonly property color surface3:   _pl("#44484e", "#e0e3e8", "#382d26", "#ded7c7")
    readonly property color line:       _pl("#4c4f55", "#cbd0d8", "#41362f", "#cbc2b0")
    readonly property color lineSoft:   _pl("#3d4046", "#dde0e6", "#332b25", "#dfd8c7")
    readonly property color lineStrong: _pl("#6b6f78", "#95989f", "#5a4d44", "#a19682")

    // ============ Text ============
    readonly property color text:    _pl("#f0f0f4", "#1c1f25", "#f2ebdf", "#2a221c")
    readonly property color text2:   _pl("#b0b1ba", "#4f535d", "#b7aa98", "#5b4f44")
    readonly property color text3:   _pl("#828590", "#7c8089", "#807365", "#897e70")
    readonly property color textInv: _pl("#232629", "#fafbfd", "#1b1411", "#f6f2eb")

    // ============ Accent ============
    // Warm = wflows.com coral (hue 25-32). Cool = original amber (hue
    // 55-65). On light surfaces the cool palette deepens the amber so
    // it carries enough contrast on cool gray paper.
    readonly property color accent:    _pl("#e1a04a", "#9c5a18", "#ed8068", "#c73e2c")
    readonly property color accentHi:  _pl("#f0b964", "#b87024", "#f49b82", "#d54f3d")
    readonly property color accentLo:  _pl("#b27418", "#844614", "#e36850", "#b72a1c")
    // Pre-baked soft accent surface (wflows.com --accent-wash analog).
    // Use this when you need the brand's named "wash" tone as a fixed
    // color; reach for the accentWash(alpha) helper below when you want
    // the blend to track an arbitrary alpha against the live accent.
    readonly property color accentDim: _pl("#4a3a1d", "#f3e6cc", "#463129", "#fbe7dd")
    readonly property color accentInk: _pl("#1d1408", "#5b3408", "#1f140f", "#6f1808")

    // Text color sitting on top of a filled accent surface (button fills
    // etc). Bright dark-mode accent carries deep near-black text;
    // darker light-mode accent flips to off-white.
    readonly property color accentText: _pl("#1d1408", "#fffaf0", "#1f140f", "#f6f2eb")

    // ============ Plum (secondary hue) ============
    readonly property color plum:     _pl("#c778a4", "#8a4a6f", "#c778a4", "#8a4a6f")
    readonly property color plumWash: _pl("#4a323f", "#f2dae3", "#4a323f", "#f2dae3")

    // ============ Semantic ============
    readonly property color ok:   _pl("#6acc83", "#1f7c52", "#67bc91", "#1f8c5f")
    readonly property color warn: _pl("#d8c043", "#8a6512", "#dcb348", "#b68421")
    readonly property color err:  _pl("#de6750", "#b0392b", "#eb7a66", "#bb2c1a")

    // ============ Category chip tints ============
    // Cool palette keeps the original saturated kind colors (they read
    // well on slate surfaces); warm palette uses the muted ink-* register
    // mirrored from wflows.com tokens.css so the chips don't compete
    // with the coral brand.
    readonly property color catKey:    _pl("#a890d2", "#6e54a8", "#a483c8", "#6c52a4")  // purple
    readonly property color catType:   _pl("#889bcb", "#4862ad", "#7b95c4", "#445e9e")  // blue
    readonly property color catClick:  _pl("#88b08e", "#3d7c58", "#4fb082", "#1f7c52")  // green
    readonly property color catMove:   _pl("#7da4a8", "#437576", "#6fa1b8", "#3e6f86")
    readonly property color catScroll: _pl("#80a0b8", "#436c83", "#6fa1b8", "#3d7095")  // cyan-blue
    readonly property color catFocus:  _pl("#c89e60", "#856425", "#bd9c50", "#856420")  // amber
    readonly property color catWait:   _pl("#8e8780", "#6e6862", "#93857b", "#6e6862")  // warm gray
    readonly property color catShell:  _pl("#c89070", "#985538", "#c77f4d", "#94511f")  // orange
    readonly property color catNotify: _pl("#c0859e", "#9e527a", "#c77e96", "#985070")  // pink
    readonly property color catClip:   _pl("#80a0b0", "#436b7c", "#6fa1b8", "#3d7095")
    readonly property color catNote:   _pl("#807870", "#5e5650", "#807870", "#5e5650")  // neutral
    // Flow-control tints — visually distinct from action kinds so the
    // structural blocks read as different beasts.
    readonly property color catWhen:   _pl("#b896b0", "#8a5a82", "#b896b0", "#8a5a82")  // mauve
    readonly property color catUnless: _pl("#c08878", "#985d4a", "#c08878", "#985d4a")  // rust
    readonly property color catRepeat: _pl("#b0b878", "#748640", "#b0b878", "#748640")  // olive
    readonly property color catUse:    _pl("#9d90ba", "#5e4880", "#9d90ba", "#5e4880")  // dusty violet

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
    // Mirrors wflows.com's full ladder: xs=4 (tiny chips/tags), sm=6
    // (compact buttons/inputs), md=10 (cards, dialogs, kdl blocks),
    // lg=16 (hero/big cards), xl=22 (the get-wflow callout, large
    // panels), pill=999 (triggers, install button, hero toggle).
    readonly property int radiusXs:  4
    readonly property int radiusSm:  6
    readonly property int radiusMd:  10
    readonly property int radiusLg:  16
    readonly property int radiusXl:  22
    readonly property int radiusPill: 999

    // ============ Type scale ============
    readonly property int fontXs:   11
    readonly property int fontSm:   13
    readonly property int fontBase: 14
    readonly property int fontMd:   16
    readonly property int fontLg:   20
    readonly property int fontXl:   28

    // ============ Fonts ============
    // Tried Boska + Supreme (the wflows.com brand pair) — they read poorly
    // at the dense UI sizes we use here. Back on Hanken Grotesk + Geist
    // Mono. familyDisplay stays as a separate token so titles can grow
    // a heavier weight without affecting body copy.
    readonly property string familyDisplay: "Hanken Grotesk"
    readonly property string familyBody:    "Hanken Grotesk"
    readonly property string familyMono:    "Geist Mono"

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
        const _kinds = ["key", "rose", "violet", "shell", "wait",
                        "lime", "type", "magenta", "focus", "notify"]
        const c = handle.replace(/^@/, "").toLowerCase().charCodeAt(0) || 0
        return gradFor(_kinds[c % _kinds.length])
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
