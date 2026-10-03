/**
 * [INPUT]: MusicMiniPlayerAppKit's TourGestureMotion / TourGestureGlyph; TourRender (ImageRenderer).
 * [OUTPUT]: TourGestureGlyphTests — the move step's two-finger demo: the pure timeline and pixels.
 * [POS]: Tests. Founder 2026-09-29, item 8: the band between the beats and the footnote was BLANK.
 *        The first glyph paused its own clock on a cycle boundary, where the timeline is fully
 *        transparent, so after two cycles nothing was drawn for good.
 */

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit

@MainActor
final class TourGestureGlyphTests: XCTestCase {
    typealias M = TourGestureMotion

    func test_timeline_playsTwoCycles_thenRestsAtTheStartPose_visibly() {
        for kind in [TourGestureKind.nudgeToCorner(), .swipeToEdge(rightward: true), .swipeToEdge(rightward: false)] {
            let done = M.frame(kind: kind, elapsed: M.cycleDuration * 2, reduceMotion: false)
            XCTAssertEqual(done, M.Frame(dx: 0, dy: 0, opacity: M.restOpacity), "\(kind): at rest it sits at its start pose at 0.31")
            XCTAssertEqual(M.frame(kind: kind, elapsed: 500, reduceMotion: false).opacity, 0.31, accuracy: 1e-9)
        }
        XCTAssertTrue(M.isFinished(elapsed: M.cycleDuration * 2))
        XCTAssertFalse(M.isFinished(elapsed: M.cycleDuration * 2 - 0.01))
    }

    func test_timeline_theOldPauseInstant_isNoLongerTheEnd() {
        // The old glyph froze at cycle boundaries; a cycle boundary IS fully transparent.
        XCTAssertEqual(M.frame(kind: .nudgeToCorner(), elapsed: M.cycleDuration, reduceMotion: false).opacity, 0)
        XCTAssertGreaterThan(M.frame(kind: .nudgeToCorner(), elapsed: M.cycleDuration * 2, reduceMotion: false).opacity, 0.3)
    }

    func test_timeline_cycleShape() {
        let k = TourGestureKind.nudgeToCorner()
        XCTAssertEqual(M.frame(kind: k, elapsed: 0.0, reduceMotion: false).opacity, 0)
        XCTAssertEqual(M.frame(kind: k, elapsed: 0.6, reduceMotion: false).opacity, 1)
        let mid = M.frame(kind: k, elapsed: 1.275, reduceMotion: false)      // halfway through the 0.95 s move
        XCTAssertEqual(mid.dx, M.displacement(k).dx / 2, accuracy: 0.5)
        XCTAssertEqual(mid.dy, M.displacement(k).dy / 2, accuracy: 0.5)
        XCTAssertEqual(M.frame(kind: k, elapsed: 2.7, reduceMotion: false).opacity, 0.31, accuracy: 1e-9)
        XCTAssertEqual(M.frame(kind: k, elapsed: 3.5, reduceMotion: false).opacity, 0)
    }

    func test_reduceMotion_isTheStaticStartPose() {
        XCTAssertEqual(M.frame(kind: .nudgeToCorner(), elapsed: 1.3, reduceMotion: true), M.Frame(dx: 0, dy: 0, opacity: 0.31))
    }

    func test_scale_isThePrototypesOnePointOneFive() {
        XCTAssertEqual(M.scale, 1.15, accuracy: 1e-9)
        XCTAssertEqual(M.displacement(.nudgeToCorner()).dx, 30 * 1.15, accuracy: 1e-9)
        XCTAssertEqual(M.displacement(.swipeToEdge(rightward: false)).dx, -36 * 1.15, accuracy: 1e-9)
    }

    /// Pixels: the resting glyph draws two blue dots. (The band was empty on the founder's Mac.)
    func test_rest_drawsTwoBlueDots_notABlankBand() throws {
        let glyph = TourGestureGlyph(kind: .nudgeToCorner(), reduceMotion: false, startedAt: Date().addingTimeInterval(-30)).background(Color.white)
        let px = try XCTUnwrap(TourRender.pixels(glyph, size: CGSize(width: 110, height: 83), scale: 2))
        var blue = 0
        for y in 0..<px.height { for x in 0..<px.width {
            let p = px.rgba(x: x, y: y)
            if Int(p.b) > Int(p.r) + 30 && p.a > 200 { blue += 1 }
        } }
        XCTAssertGreaterThan(blue, 200, "two 12.6pt dots at 31% still leave a clear blue mark (\(blue) px)")
    }
}
