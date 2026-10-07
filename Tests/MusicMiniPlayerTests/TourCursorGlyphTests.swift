/**
 * [INPUT]: MusicMiniPlayerAppKit's TourCursorGlyph / TourCardPalette; TourRender (ImageRenderer).
 * [OUTPUT]: TourCursorGlyphTests — the ghost cursor's pixels: a near-black arrow with a thin white outline and an accent
 *           eighth note at its tail, on a light and a dark ground, at 1x and 2x; the note's bob moves only the note;
 *           opt-in stills (TOUR_CURSOR_SHOTS_DIR).
 * [POS]: Tests. Founder 2026-10-07: the ghost cursor is black, a little playful and about music, still a pointer.
 */

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit

@MainActor
final class TourCursorGlyphTests: XCTestCase {
    private let tip = CGPoint(x: 8, y: 6)
    private let size = CGSize(width: 48, height: 46)

    private func render(dark: Bool, scale: CGFloat, ripple: Double? = nil) -> TourPixels? {
        let palette = TourCardPalette.resolve(dark: dark)
        let tip = self.tip
        let view = Canvas { ctx, _ in
            TourCursorGlyph.draw(ctx, tip: tip, palette: palette, rippleProgress: ripple, shadow: false)
        }
        .frame(width: size.width, height: size.height)
        .background(dark ? Color(hex: 0x2A2A30) : Color(hex: 0xEDEDF0))
        return TourRender.pixels(view, size: size, scale: scale, dark: dark)
    }

    private func at(_ px: TourPixels, _ dx: CGFloat, _ dy: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        px.rgba(atPoint: CGPoint(x: tip.x + dx, y: tip.y + dy))
    }

    func test_arrowBodyIsNearBlack_outlineIsWhite_noteIsAccent_lightAndDark_1xAnd2x() throws {
        for dark in [false, true] {
            for scale in [CGFloat(1), 2] {
                let px = try XCTUnwrap(render(dark: dark, scale: scale), "dark=\(dark) \(scale)x")
                let body = at(px, 3.5, 9)
                XCTAssertLessThan(Int(body.r) + Int(body.g) + Int(body.b), 3 * 50, "arrow body is near-black (dark=\(dark) \(scale)x)")
                // Just outside the arrow's left edge (x = 0): the white outline, then the ground.
                let rim = at(px, -0.6, 9)
                XCTAssertGreaterThan(Int(rim.r) + Int(rim.g) + Int(rim.b), 3 * 215, "thin white outline (dark=\(dark) \(scale)x)")
                // The note's head: the tour's accent.
                let head = at(px, 18.0, 25.4)
                XCTAssertTrue(TourRender.isAccent(head) || (head.r > 200 && Int(head.r) - Int(head.g) > 100), "note head is accent: \(head) (dark=\(dark) \(scale)x)")
            }
        }
    }

    func test_noteIsClearOfTheArrow_andNothingAccentTouchesTheArrowBody() throws {
        let px = try XCTUnwrap(render(dark: false, scale: 2))
        for (dx, dy) in [(3.5, 5.0), (3.5, 9.0), (2.0, 15.0), (6.0, 12.5), (9.0, 12.0)] as [(CGFloat, CGFloat)] {
            XCTAssertFalse(TourRender.isAccent(at(px, dx, dy)), "arrow pixel (\(dx), \(dy))")
        }
    }

    func test_bob_liftsOnlyTheNote_andIsZeroAtRestAndAtTheEnds() throws {
        XCTAssertEqual(TourCursorGlyph.bob(rippleProgress: nil).lift, 0)
        XCTAssertEqual(TourCursorGlyph.bob(rippleProgress: 0).lift, 0)
        XCTAssertEqual(TourCursorGlyph.bob(rippleProgress: 1).lift, 0)
        XCTAssertEqual(TourCursorGlyph.bob(rippleProgress: 0.5).lift, -TourCursorGlyph.bobLift, accuracy: 1e-6)

        let rest = try XCTUnwrap(render(dark: false, scale: 2))
        let mid = try XCTUnwrap(render(dark: false, scale: 2, ripple: 0.5))
        // The arrow's pixels are identical; the note's head has moved up (its old spot is no longer accent).
        for (dx, dy) in [(3.5, 9.0), (-0.6, 9.0), (2.0, 15.0)] as [(CGFloat, CGFloat)] {
            let a = at(rest, dx, dy), b = at(mid, dx, dy)
            XCTAssertEqual([a.r, a.g, a.b], [b.r, b.g, b.b], "arrow pixel (\(dx), \(dy)) must not move")
        }
        XCTAssertTrue(TourRender.isAccent(at(rest, 18.0, 25.4)) || at(rest, 18.0, 25.4).r > 200)
        XCTAssertFalse(TourRender.isAccent(at(mid, 18.0, 25.4 + 2.4)), "the head left its resting spot")
    }

    /// Opt-in stills for looking at: light and dark ground, 1x and 2x, and the mid-bob.
    func test_stills() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOUR_CURSOR_SHOTS_DIR"] else { throw XCTSkip("opt-in: writes PNGs") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            for scale in [CGFloat(1), 2] {
                for (name, ripple) in [("rest", nil), ("bob", 0.5)] as [(String, Double?)] {
                    let palette = TourCardPalette.resolve(dark: dark)
                    let tip = self.tip
                    // A 6x magnified copy beside the real size, so the shape can be judged by eye.
                    let big = Canvas { ctx, _ in
                        var c = ctx
                        c.scaleBy(x: 6, y: 6)
                        TourCursorGlyph.draw(c, tip: tip, palette: palette, rippleProgress: ripple)
                    }.frame(width: size.width * 6, height: size.height * 6)
                    let sheet = HStack(alignment: .top, spacing: 0) {
                        Canvas { ctx, _ in TourCursorGlyph.draw(ctx, tip: tip, palette: palette, rippleProgress: ripple) }
                            .frame(width: size.width, height: size.height)
                        big
                    }
                    .background(dark ? Color(hex: 0x2A2A30) : Color(hex: 0xEDEDF0))
                    let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = scale
                    if let cg = renderer.cgImage {
                        TourRender.writePNG(cg, to: "\(dir)/cursor-\(dark ? "dark" : "light")-\(Int(scale))x-\(name).png")
                    }
                }
            }
        }
    }
}
