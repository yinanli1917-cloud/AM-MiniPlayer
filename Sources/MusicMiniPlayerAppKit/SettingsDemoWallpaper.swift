/**
 * [INPUT]: SwiftUI Color only.
 * [OUTPUT]: Exports StageWallpaper (one named light + dark colour set for the demo stage
 *           background), StageWallpaper.candidates / .shipped / .active, and StageChrome
 *           (the warm-neutral ink and shadow tints that sit on every wallpaper).
 * [POS]: The ONE definition of the settings demo stage's background colours. DemoPalette
 *        reads `StageWallpaper.active` and nothing else names a wallpaper colour, so
 *        switching the look is the single line `shipped = .ember`. The prototype
 *        (docs/design/2026-09-29-motion-prototype, tokens --w1..--w4 + chrome tokens) and
 *        spec.md A.1 carry the same numbers.
 *
 *        Design brief (2026-10-01): the old wallpaper was a cool blue-to-violet wash, the
 *        textbook generic-AI-gradient look, worst in dark mode. These sets come from the
 *        other end of the palette: warm, slightly desaturated, natural-pigment colours with
 *        real depth (paper and bone into blush or apricot by day; charcoal and umber with one
 *        low ember glow by night), the way a macOS desktop picture or Apple Music's own
 *        surfaces read. The accent pink stays rare; it only marks what is happening.
 *
 *        Structure (unchanged, so the prototype's three CSS layers still map 1:1):
 *        base `linear-gradient(160deg, w3, w4)`, a glow of `w2` from the bottom-right
 *        corner and a glow of `w1` from the top-left corner. w1 is the "second light
 *        source": cream by day, a faint warm lift by night.
 */

import SwiftUI

struct StageWallpaper: Equatable {

    struct Look: Equatable {
        /// Top-left glow, bottom-right glow, base gradient start / end (prototype --w1 … --w4).
        let w1, w2, w3, w4: UInt32
    }

    let name: String
    let light: Look
    let dark: Look

    func look(dark isDark: Bool) -> Look { isDark ? dark : light }
}

extension StageWallpaper {

    // MARK: candidates

    /// Bone paper into apricot-blush; charcoal-umber with a low rust ember in the corner.
    static let ember = StageWallpaper(
        name: "ember",
        light: Look(w1: 0xFFF3E0, w2: 0xF8C9B4, w3: 0xF4ECE2, w4: 0xEFD9CF),
        dark: Look(w1: 0x43302C, w2: 0x7C3B2B, w3: 0x211B19, w4: 0x2F2320))

    /// Blush paper with a dusty-rose bloom; wine-brown with a muted plum-rosewood glow.
    static let rosewood = StageWallpaper(
        name: "rosewood",
        light: Look(w1: 0xFFF0E2, w2: 0xEDB3B2, w3: 0xF8ECE6, w4: 0xEED8D3),
        dark: Look(w1: 0x47292D, w2: 0x732F3F, w3: 0x211617, w4: 0x301C1F))

    /// Sandstone and terracotta; umber with an amber-brown glow. The least pink of the four.
    static let dune = StageWallpaper(
        name: "dune",
        light: Look(w1: 0xFFF4DC, w2: 0xE8B590, w3: 0xF2E9DA, w4: 0xE5D3BD),
        dark: Look(w1: 0x40341F, w2: 0x7A4F26, w3: 0x211B14, w4: 0x2F2418))

    /// Sage-white with a peach bloom; green-charcoal with a clay glow. The one cool-leaning
    /// set (green, never blue or violet): pink accents sit on it as a complement.
    static let sage = StageWallpaper(
        name: "sage",
        light: Look(w1: 0xFFF6E4, w2: 0xF4CDB8, w3: 0xEEEFE6, w4: 0xDFE3D6),
        dark: Look(w1: 0x2E3C33, w2: 0x5A3B2E, w3: 0x1A1E1B, w4: 0x232A25))

    static let candidates: [StageWallpaper] = [.ember, .rosewood, .dune, .sage]

    // MARK: the one-line switch

    /// What ships.
    static let shipped: StageWallpaper = .ember

    #if DEBUG
    /// Test seam: the candidate screenshots render each set in the real window.
    nonisolated(unsafe) static var override: StageWallpaper?
    #endif

    /// What the stage paints right now.
    static var active: StageWallpaper {
        #if DEBUG
        if let override { return override }
        #endif
        return shipped
    }
}

// ──────────────────────────────────────────────
// MARK: - Chrome on top of the wallpaper
// ──────────────────────────────────────────────

/// Menu-bar / background-window / glyph inks and the shadow tint. Warm neutrals so nothing
/// on the stage carries the old navy-violet cast (the old values were #14141E menu bar,
/// #282834 background window, lavender glyph ink, rgb(30,20,70) shadows).
enum StageChrome {
    /// RGB of every soft shadow on the stage (panel, glass card, keycap): a warm brown-black.
    static let shadowRGB: (r: Double, g: Double, b: Double) = (38 / 255, 22 / 255, 18 / 255)

    /// The power-on glow that sweeps the stage in the Launch at Login scene: soft white by day, a warm
    /// peach at low strength by night.
    static func sweep(dark: Bool) -> Color {
        dark ? Color(.sRGB, red: 1, green: 214 / 255, blue: 184 / 255, opacity: 0.22)
             : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.55)
    }

    static func shadow(_ opacity: Double) -> Color {
        Color(.sRGB, red: shadowRGB.r, green: shadowRGB.g, blue: shadowRGB.b, opacity: opacity)
    }

    // Light: translucent white bar, warm dark ink. Dark: translucent warm black, warm white ink.
    static let menubarLight = (hex: UInt32(0xFFFFFF), alpha: 0.55)
    static let menubarDark = (hex: UInt32(0x1A1412), alpha: 0.45)
    static let bgwinLight = (hex: UInt32(0xFFFFFF), alpha: 0.55)
    static let bgwinDark = (hex: UInt32(0x2E2623), alpha: 0.60)
    static let capInkLight = (hex: UInt32(0x2E1E1A), alpha: 0.60)
    static let capInkDark = (hex: UInt32(0xFFF1EA), alpha: 0.62)
}
