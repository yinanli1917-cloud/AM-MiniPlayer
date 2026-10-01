// ──────────────────────────────────────────────
// SettingsStageWallpaperTests — the demo stage background: one palette definition, no blue /
// violet wash (the founder's 2026-10-01 "AI gradient" verdict), and the real render paints it.
// Candidate screenshots live in SettingsStageWallpaperScreenshotTests (opt-in).
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsStageWallpaperTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SettingsPalette.accentOverride = SettingsPalette.brandAccent
    }

    override func tearDown() {
        StageWallpaper.override = nil
        SettingsPalette.accentOverride = nil
        L10n.languageOverride = nil
        super.tearDown()
    }

    /// Hue in degrees and saturation of a 0xRRGGBB value.
    private func hueSat(_ hex: UInt32) -> (hue: Double, sat: Double) {
        let c = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        return (Double(c.hueComponent) * 360, Double(c.saturationComponent))
    }

    func test_shippedWallpaper_isEmber_andIsTheActiveOne() {
        XCTAssertEqual(StageWallpaper.shipped.name, "ember")
        XCTAssertEqual(StageWallpaper.active, StageWallpaper.shipped)
        StageWallpaper.override = .rosewood
        XCTAssertEqual(StageWallpaper.active.name, "rosewood")
        XCTAssertEqual(StageWallpaper.candidates.count, 4)
        XCTAssertEqual(Set(StageWallpaper.candidates.map(\.name)).count, 4)
    }

    /// No candidate, light or dark, has a visibly coloured stop in the blue-to-violet hue band.
    func test_noCandidate_hasABlueVioletStop() {
        for candidate in StageWallpaper.candidates {
            for (mode, look) in [("light", candidate.light), ("dark", candidate.dark)] {
                for hex in [look.w1, look.w2, look.w3, look.w4] {
                    let (hue, sat) = hueSat(hex)
                    let blueViolet = hue >= 190 && hue <= 340
                    XCTAssertFalse(blueViolet && sat > 0.08, "\(candidate.name) \(mode) \(String(hex, radix: 16)): hue \(hue) sat \(sat)")
                }
            }
        }
    }

    /// Light stops are light, dark stops are dark: the glyph inks and the panel keep their contrast.
    func test_lightStopsAreLight_darkStopsAreDark() {
        func luma(_ hex: UInt32) -> Double {
            (0.2126 * Double((hex >> 16) & 0xFF) + 0.7152 * Double((hex >> 8) & 0xFF) + 0.0722 * Double(hex & 0xFF)) / 255
        }
        for candidate in StageWallpaper.candidates {
            for hex in [candidate.light.w1, candidate.light.w2, candidate.light.w3, candidate.light.w4] {
                XCTAssertGreaterThan(luma(hex), 0.70, "\(candidate.name) light \(String(hex, radix: 16))")
            }
            for hex in [candidate.dark.w1, candidate.dark.w2, candidate.dark.w3, candidate.dark.w4] {
                XCTAssertLessThan(luma(hex), 0.40, "\(candidate.name) dark \(String(hex, radix: 16))")
            }
        }
    }

    /// The prototype's tokens (--w1…--w4) carry the shipped numbers.
    func test_prototypeTokens_matchTheShippedWallpaper() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design/2026-09-29-motion-prototype/prototype.html")
        let html = try String(contentsOf: url, encoding: .utf8).lowercased()
        func hex(_ v: UInt32) -> String { "#" + String(format: "%06x", v) }
        let s = StageWallpaper.shipped
        XCTAssertTrue(html.contains("--w1:\(hex(s.light.w1)); --w2:\(hex(s.light.w2)); --w3:\(hex(s.light.w3)); --w4:\(hex(s.light.w4));"))
        XCTAssertTrue(html.contains("--w1:\(hex(s.dark.w1)); --w2:\(hex(s.dark.w2)); --w3:\(hex(s.dark.w3)); --w4:\(hex(s.dark.w4));"))
    }

    /// Real render: the stage corners carry the wallpaper stops (top-left glow, bottom-right glow),
    /// and the picture is warm (red above blue) in both appearances.
    func test_render_stagePaintsTheShippedWallpaper_warm() {
        func px(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
            (rep.colorAt(x: x, y: y) ?? .black).usingColorSpace(.sRGB) ?? .black
        }
        for dark in [false, true] {
            let rep = SettingsDemoFrameRenderTests.renderStage(.showInDock, at: 0.3, dark: dark)
            let look = StageWallpaper.shipped.look(dark: dark)
            // Just inside the bottom-right corner (clear of the rounded clip): near w2, clearly warm.
            let br = px(rep, 560, 322)
            XCTAssertGreaterThan(br.redComponent, br.blueComponent, "bottom-right is warm (dark=\(dark))")
            let w2 = NSColor(srgbRed: CGFloat((look.w2 >> 16) & 0xFF) / 255, green: CGFloat((look.w2 >> 8) & 0xFF) / 255, blue: CGFloat(look.w2 & 0xFF) / 255, alpha: 1)
            XCTAssertEqual(br.redComponent, w2.redComponent, accuracy: 0.12, "bottom-right red tracks w2 (dark=\(dark))")
            // Mid-left, below the menu bar: base gradient region, warm and on the right side of the lightness split.
            let left = px(rep, 40, 150)
            XCTAssertGreaterThanOrEqual(left.redComponent, left.blueComponent, "mid-left is warm (dark=\(dark))")
            XCTAssertEqual(left.brightnessComponent > 0.5, !dark, "appearance decides lightness (dark=\(dark))")
        }
    }
}
