/**
 * [INPUT]: MusicMiniPlayerAppKit's TourGestureMotion / TourGestureGlyphFace; TourRender (ImageRenderer).
 * [OUTPUT]: TourGestureGlyphParityTests — the move step's two-finger demo against the motion prototype: dot motion,
 *           the motion trails, and the spacing of the two dots.
 * [POS]: Tests. Founder 2026-09-29 (third walk): "the prototype's dots leave trails, the app's have none; the two dots
 *        sit too far apart". The truth table below was read from docs/design/2026-09-29-motion-prototype/prototype.html
 *        with the Web Animations API: every animation on `.tp .pad .f` paused at `t`, `getComputedStyle` on the dot
 *        and on its `::after` (CSS px; the card shows the pad at zoom 1.15).
 */

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit

@MainActor
final class TourGestureGlyphParityTests: XCTestCase {
    typealias M = TourGestureMotion

    private struct Truth {
        let t: Double, dotOpacity: Double, x: Double, y: Double, trailOpacity: Double, trailStretch: Double, trailShift: Double
    }

    private let nudgeTruth = [
        Truth(t: 0.2, dotOpacity: 0.4436, x: 0, y: 0, trailOpacity: 0, trailStretch: 1, trailShift: 0),
        Truth(t: 1.0, dotOpacity: 1, x: 2.749, y: 1.649, trailOpacity: 0.189, trailStretch: 1.3359, trailShift: 1.680),
        Truth(t: 1.1, dotOpacity: 1, x: 6.271, y: 3.762, trailOpacity: 0.2829, trailStretch: 1.5029, trailShift: 2.514),
        Truth(t: 1.275, dotOpacity: 1, x: 15.03, y: 9.018, trailOpacity: 0.4472, trailStretch: 1.795, trailShift: 3.975),
        Truth(t: 1.5, dotOpacity: 1, x: 25.704, y: 15.422, trailOpacity: 0.2384, trailStretch: 1.4239, trailShift: 2.119),
        Truth(t: 1.75, dotOpacity: 1, x: 30, y: 18, trailOpacity: 0, trailStretch: 1, trailShift: 0),
        Truth(t: 2.25, dotOpacity: 0.6566, x: 30, y: 18, trailOpacity: 0, trailStretch: 1, trailShift: 0),
        Truth(t: 3.2, dotOpacity: 0.1474, x: 30, y: 18, trailOpacity: 0, trailStretch: 1, trailShift: 0),
    ]

    func test_nudge_dotsAndTrail_matchThePrototypeFrameForFrame() {
        for r in nudgeTruth {
            let f = M.frame(kind: .nudgeToCorner(), elapsed: r.t, reduceMotion: false)
            let tr = M.trail(kind: .nudgeToCorner(), elapsed: r.t, reduceMotion: false)
            XCTAssertEqual(f.opacity, r.dotOpacity, accuracy: 0.004, "dot opacity @ \(r.t)s")
            XCTAssertEqual(Double(f.dx) / Double(M.scale), r.x, accuracy: 0.08, "dot x @ \(r.t)s")
            XCTAssertEqual(Double(f.dy) / Double(M.scale), r.y, accuracy: 0.08, "dot y @ \(r.t)s")
            XCTAssertEqual(tr.opacity, r.trailOpacity, accuracy: 0.004, "trail opacity @ \(r.t)s")
            XCTAssertEqual(Double(tr.stretch), r.trailStretch, accuracy: 0.004, "trail stretch @ \(r.t)s")
            XCTAssertEqual(abs(Double(tr.shift)), r.trailShift, accuracy: 0.03, "trail shift @ \(r.t)s")
            if r.trailOpacity > 0 { XCTAssertEqual(tr.angleDegrees, 31, accuracy: 1e-9, "the nudge trail lies along the 31 degree diagonal") }
        }
    }

    func test_swipe_trailTrailsBehindTheDot_inBothDirections() {
        // Prototype @1.275: swipe -> dot x 18.036, trail translateX(-3.975); swipeL -> dot x -18.036, trail translateX(+3.975).
        let right = M.frame(kind: .swipeToEdge(rightward: true), elapsed: 1.275, reduceMotion: false)
        let rightTrail = M.trail(kind: .swipeToEdge(rightward: true), elapsed: 1.275, reduceMotion: false)
        XCTAssertEqual(Double(right.dx) / Double(M.scale), 18.036, accuracy: 0.08)
        XCTAssertEqual(Double(rightTrail.shift), -3.975, accuracy: 0.03, "behind a rightward dot")
        XCTAssertEqual(rightTrail.angleDegrees, 0)
        let left = M.frame(kind: .swipeToEdge(rightward: false), elapsed: 1.275, reduceMotion: false)
        let leftTrail = M.trail(kind: .swipeToEdge(rightward: false), elapsed: 1.275, reduceMotion: false)
        XCTAssertEqual(Double(left.dx) / Double(M.scale), -18.036, accuracy: 0.08)
        XCTAssertEqual(Double(leftTrail.shift), 3.975, accuracy: 0.03, "behind a leftward dot")
    }

    func test_noTrail_atRest_inReduceMotion_andOutsideTheMove_butTheSecondCycleTrailsToo() {
        for t in [0.0, 0.5, 0.79, 1.76, 2.5, 3.5, 100] {
            XCTAssertEqual(M.trail(kind: .nudgeToCorner(), elapsed: t, reduceMotion: false), .none, "@ \(t)")
        }
        XCTAssertEqual(M.trail(kind: .nudgeToCorner(), elapsed: 1.275, reduceMotion: true), .none)
        XCTAssertGreaterThan(M.trail(kind: .nudgeToCorner(), elapsed: M.cycleDuration + 1.275, reduceMotion: false).opacity, 0.4)
    }

    /// The prototype's two dots are 16 CSS px apart, centre to centre (`.f.a{left:20px}` / `.f.b{left:36px}`): 18.4 pt at
    /// 1.15x. (The app's were 31 pt apart: an HStack `spacing` of 16 between two 11 pt dots.)
    func test_dotSpacing_isThePrototypes_andSoAreTheStartPositions() {
        for kind in [TourGestureKind.nudgeToCorner(), .swipeToEdge(rightward: true), .swipeToEdge(rightward: false)] {
            let c = M.dotCenters(kind)
            XCTAssertEqual(Double(c.b.x - c.a.x) * Double(M.scale), 18.4, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(c.a.y, c.b.y)
        }
        XCTAssertEqual(M.dotCenters(.nudgeToCorner()).a.x, 25.5)
        XCTAssertEqual(M.dotCenters(.nudgeToCorner()).a.y, 27.5)
        XCTAssertEqual(M.dotCenters(.swipeToEdge(rightward: true)).a.x, 29.5)
        XCTAssertEqual(M.dotCenters(.swipeToEdge(rightward: false)).a.x, 49.5)
        XCTAssertEqual(M.dotCenters(.swipeToEdge(rightward: true)).a.y, 35.5)
    }

    /// Pixels: mid-slide the trail puts blue behind the rear dot that the same frame without a trail does not have.
    func test_trail_isDrawn_behindTheRearDot() throws {
        let kind = TourGestureKind.swipeToEdge(rightward: true)
        let elapsed = 1.275
        let f = M.frame(kind: kind, elapsed: elapsed, reduceMotion: false)
        func render(showTrail: Bool) throws -> TourPixels {
            let view = TourGestureGlyphFace(kind: kind, elapsed: elapsed, reduceMotion: false, showTrail: showTrail).background(Color.white)
            return try XCTUnwrap(TourRender.pixels(view, size: TourGestureGlyphFace.size, scale: 2))
        }
        func blueInk(_ px: TourPixels, upToX limit: Int) -> Int {
            var n = 0
            for y in 0..<px.height { for x in 0..<min(limit, px.width) {
                let p = px.rgba(x: x, y: y)
                if Int(p.b) > Int(p.r) + 30 { n += 1 }
            } }
            return n
        }
        let withTrail = try render(showTrail: true), without = try render(showTrail: false)
        // Left edge of the rear dot (pad point (29.5 - 5.5) * 1.15 + slide), in 2x pixels: everything left of it is trail.
        let leftEdge = Int(((29.5 - 5.5) * 1.15 + Double(f.dx) - 0.5) * 2)
        XCTAssertGreaterThan(blueInk(withTrail, upToX: leftEdge), blueInk(without, upToX: leftEdge) + 12, "a blurred trail sticks out behind the rear dot")
        XCTAssertGreaterThan(blueInk(withTrail, upToX: withTrail.width), blueInk(without, upToX: without.width), "and adds ink overall")
        // The dots themselves are where the prototype has them: the rear dot's centre pixel is solid blue.
        let rear = without.rgba(atPoint: CGPoint(x: 29.5 * 1.15 + Double(f.dx), y: 35.5 * 1.15))
        XCTAssertGreaterThan(Int(rear.b), Int(rear.r) + 60, "the rear dot sits at its prototype position")
        let front = without.rgba(atPoint: CGPoint(x: 45.5 * 1.15 + Double(f.dx), y: 35.5 * 1.15))
        XCTAssertGreaterThan(Int(front.b), Int(front.r) + 60, "and the front dot 16 CSS px (18.4 pt) further along")
        let between = without.rgba(atPoint: CGPoint(x: 37.5 * 1.15 + Double(f.dx) + 0.0, y: 35.5 * 1.15 - 6.4))
        XCTAssertLessThan(Int(between.b) - Int(between.r), 30, "white space above the gap between the two dots")
    }
}
