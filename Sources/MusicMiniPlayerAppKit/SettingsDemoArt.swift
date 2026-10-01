/**
 * [INPUT]: SwiftUI Color only.
 * [OUTPUT]: Exports StageArt (the demo's sample cover and the panel / card / lyrics-page
 *           colours taken from it; sea candidates teal / olive; shipped / active / override)
 *           and Color(stageHex:).
 * [POS]: Single definition of the colours INSIDE the settings demo stage (the wallpaper behind
 *        it lives in SettingsDemoWallpaper.swift). A dusk over water: the coral-peach sky and
 *        cream sun of the original cover are kept; the violet / indigo (sea, panel body, peek
 *        card, lyrics page) is replaced by a desaturated sea and warm deep tones (coral ->
 *        rosewood -> umber) so the art sits on the warm wallpaper instead of fighting it.
 *        Nothing here has a hue between 230 and 300 degrees (StageWallpaper tests pin it).
 *        The prototype (docs/design/2026-09-29-motion-prototype) and spec.md A.1 carry the
 *        same numbers.
 */

import SwiftUI

struct StageArt: Equatable {
    let name: String
    /// Sea gradient, top to bottom.
    let seaTop, seaBottom: UInt32

    /// Deep teal-slate: reads as water at dusk and complements the warm wallpaper.
    static let teal = StageArt(name: "teal", seaTop: 0x3E6C70, seaBottom: 0x1C3438)
    /// Olive-slate alternative.
    static let olive = StageArt(name: "olive", seaTop: 0x4A5A50, seaBottom: 0x232B26)
    static let candidates: [StageArt] = [.teal, .olive]

    /// What ships (one-line switch, like `StageWallpaper.shipped`).
    static let shipped: StageArt = .teal

    #if DEBUG
    nonisolated(unsafe) static var override: StageArt?
    #endif

    static var active: StageArt {
        #if DEBUG
        if let override { return override }
        #endif
        return shipped
    }

    // MARK: shared dusk colours

    /// Cover sky: peach-gold, coral, dusk rose (the last stop only shows between the horizon haze
    /// and the sea's top edge).
    static let skyTop: UInt32 = 0xFFD58F
    static let skyMid: UInt32 = 0xFF7F8F
    static let skyLow: UInt32 = 0xC9605F
    static let sun: UInt32 = 0xFFF1D0

    /// Inset-look album panel: rosewood body, a peach-coral glow top-left, an umber glow bottom-right.
    static let panelBase: UInt32 = 0x8C4444
    static let panelGlowLight: UInt32 = 0xFF9A86
    static let panelGlowDark: UInt32 = 0x4A2626

    /// Lyrics / history page in the fullscreen look (170 degrees): the cover's dusk, deepened so
    /// white lyric lines clear WCAG 4.5:1 where they sit (active line 100%, translation 78% white) (top of the page): dusk coral, rosewood, umber.
    static let pageStops: [(hex: UInt32, at: Double)] = [(0x9A4A44, 0), (0x7A3A3A, 0.62), (0x2A1C1A, 1)]

    /// Peek / song card body, left (lit) to right (edge-dimmed).
    static let cardStops: [(hex: UInt32, at: Double)] = [(0xB8605A, 0), (0x7A3A3A, 0.52), (0x2A1C1A, 1)]

    /// Every colour of the art, for the hue test.
    static var allHexes: [UInt32] {
        var all: [UInt32] = [skyTop, skyMid, skyLow, sun, panelBase, panelGlowLight, panelGlowDark]
        all += pageStops.map(\.hex) + cardStops.map(\.hex)
        for candidate in candidates { all += [candidate.seaTop, candidate.seaBottom] }
        return all
    }

    /// Page colour `t` (0...1) of the way down the gradient (linear interpolation in sRGB, as the Canvas does).
    static func pageColor(at t: Double) -> (r: Double, g: Double, b: Double) {
        let stops = pageStops
        var lo = stops[0], hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where t >= stops[i].at && t <= stops[i + 1].at { lo = stops[i]; hi = stops[i + 1] }
        let f = hi.at == lo.at ? 0 : max(0, min(1, (t - lo.at) / (hi.at - lo.at)))
        func channel(_ shift: UInt32) -> Double {
            let a = Double((lo.hex >> shift) & 0xFF) / 255, b = Double((hi.hex >> shift) & 0xFF) / 255
            return a + (b - a) * f
        }
        return (channel(16), channel(8), channel(0))
    }
}

extension Color {
    /// 0xRRGGBB in sRGB.
    init(stageHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
