import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// Founder 2026-09-29: finishing a step showed NOTHING — no ring growth, no
/// check in the ring, no solid beat dot, no sparks. Root causes (all found by
/// reading + reproduced below):
///  1. every change rebuilt the card in a brand-new NSHostingController, so
///     the ring/dot were born already in their final state;
///  2. the ring's number never turned into a check (`showRingCheckmark` was
///     never set by anything);
///  3. the sparks were positioned in SCREEN coordinates inside a window-local
///     canvas (off-window), and used the system accent instead of the tour pink.
/// These tests drive the feedback with a fake clock and read the PIXELS the
/// real views draw (ImageRenderer, offscreen). A view that ignores the
/// feedback frame fails them.
@MainActor
final class TourCompletionFeedbackTests: XCTestCase {
    private var now: TimeInterval = 100
    private let palette = TourCardPalette.light
    private let center = CGPoint(x: 20, y: 20) // ring center inside a 40x40 host
    /// The round caps add half a line width at each end of the arc.
    private let capAllowance = 2 * 2.75 / (2 * Double.pi * 11.25)

    private func makeFeedback(reduceMotion: Bool = false) -> TourCompletionFeedback {
        TourCompletionFeedback(clock: { [unowned self] in self.now }, reduceMotion: { reduceMotion }, autoTick: false)
    }

    private func ringView(_ fb: TourCompletionFeedback, completed: Int = 2, closed: Bool = false, label: String = "3") -> some View {
        TourFeedbackRing(completed: completed, closed: closed, stepLabel: label, palette: palette, feedback: fb)
            .padding(6)
            .frame(width: 40, height: 40)
    }

    private func render<V: View>(_ v: V, size: CGSize) -> TourPixels {
        TourRender.pixels(v, size: size)!
    }

    /// Fraction of the ring's centerline (r = 11.25pt) drawn in solid accent.
    private func arcFraction(_ px: TourPixels) -> Double {
        let samples = 180
        var hit = 0
        for k in 0..<samples {
            let theta = (Double(k) + 0.5) / Double(samples) * 2 * .pi
            let p = CGPoint(x: center.x + 11.25 * sin(theta), y: center.y - 11.25 * cos(theta))
            if TourRender.isAccent(px.rgba(atPoint: p)) { hit += 1 }
        }
        return Double(hit) / Double(samples)
    }

    /// Thickness (pt) of the solid arc where it starts, along the vertical
    /// line through the ring's center, just right of 12 o'clock.
    private func lineThickness(_ px: TourPixels) -> Double {
        var run = 0
        var best = 0
        let x = Int((center.x + 3) * px.scale)
        for y in 0..<px.height {
            if TourRender.isAccent(px.rgba(x: x, y: y)) { run += 1; best = max(best, run) } else { run = 0 }
        }
        return Double(best) / Double(px.scale)
    }

    private func centerCrop(_ px: TourPixels) -> [UInt8] {
        var out: [UInt8] = []
        for dy in -7...7 { for dx in -7...7 {
            let p = px.rgba(atPoint: CGPoint(x: center.x + Double(dx) * 0.5, y: center.y + Double(dy) * 0.5))
            out += [p.r, p.g, p.b, p.a]
        } }
        return out
    }

    private func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(max(a.count, 1))
    }

    // MARK: - The ring grows (arc length is DRAWN, not just modelled)

    func test_ringArc_growsFromTwoSevenths_toThreeSevenths_inRenderedPixels() {
        let fb = makeFeedback()
        fb.begin(TourFeedbackEvent(ringFrom: 2, ringTo: 3, beatIndices: [1]))
        let size = CGSize(width: 40, height: 40)
        func arc(at dt: Double) -> Double { fb.advance(to: 100 + dt); return arcFraction(render(ringView(fb), size: size)) }

        let start = arc(at: 0.0), mid = arc(at: 0.25), end = arc(at: 0.75)
        XCTAssertEqual(start, 2.0 / 7 + capAllowance, accuracy: 0.05, "before the ring starts moving it shows 2/7")
        XCTAssertGreaterThan(mid, start + 0.02, "mid-flight arc must be longer than the start")
        XCTAssertLessThan(mid, end + 0.001)
        XCTAssertEqual(end, 3.0 / 7 + capAllowance, accuracy: 0.05, "after 0.6s it shows 3/7")
    }

    func test_ringLineWidth_breathes_thenReturnsToBase() {
        let fb = makeFeedback()
        fb.begin(TourFeedbackEvent(ringFrom: 2, ringTo: 3))
        let size = CGSize(width: 40, height: 40)
        func thickness(at dt: Double) -> Double { fb.advance(to: 100 + dt); return lineThickness(render(ringView(fb), size: size)) }

        let base = thickness(at: 0.0)
        let peak = thickness(at: 0.05 + 0.055)
        let settled = thickness(at: 0.9)
        XCTAssertEqual(base, 5.5, accuracy: 0.6)
        XCTAssertGreaterThan(peak, base + 0.5, "line width must swell (5.5 -> ~6.5) on the completion")
        XCTAssertEqual(settled, 5.5, accuracy: 0.6, "and return to 5.5")
    }

    // MARK: - The number becomes a check

    func test_ringCenter_swapsNumberForCheck() {
        let size = CGSize(width: 40, height: 40)
        let restFb = makeFeedback()
        let numberRef = centerCrop(render(ringView(restFb), size: size))
        let checkRef = centerCrop(render(ringView(restFb, completed: 7, closed: true, label: ""), size: size))
        XCTAssertGreaterThan(meanDiff(numberRef, checkRef), 3, "fixture sanity: number and check must look different")

        let fb = makeFeedback()
        fb.begin(TourFeedbackEvent(ringFrom: 2, ringTo: 3))
        fb.advance(to: 100.0)
        let atStart = centerCrop(render(ringView(fb), size: size))
        fb.advance(to: 100.0 + 0.7)
        let atEnd = centerCrop(render(ringView(fb), size: size))
        XCTAssertLessThan(meanDiff(atStart, numberRef), 3, "at t=0 the ring still shows the step number")
        XCTAssertLessThan(meanDiff(atEnd, checkRef), 6, "by 0.7s the number has been replaced by the check mark")
    }

    // MARK: - The beat dot turns into a solid check

    func test_beatDot_goesFromHollowToSolidAccentWithPop() {
        let fb = makeFeedback()
        fb.begin(TourFeedbackEvent(ringFrom: 1, ringTo: 1, beatIndices: [1]))
        func dot() -> TourPixels {
            render(TourFeedbackBeatDot(index: 1, checked: true, palette: palette, feedback: fb).padding(4), size: CGSize(width: 22, height: 22))
        }
        let c = CGPoint(x: 11, y: 11)
        fb.advance(to: 100.0)
        XCTAssertFalse(TourRender.isAccent(dot().rgba(atPoint: c)), "at t=0 the dot is still hollow")
        fb.advance(to: 100.0 + 0.3)
        XCTAssertTrue(TourRender.isAccent(dot().rgba(atPoint: CGPoint(x: 5.6, y: 11))), "by 0.3s the dot is solid accent")
        XCTAssertGreaterThan(fb.frame.beats[1]?.scale ?? 1, 0.99)
        // scale pop peaks above 1 early on
        fb.advance(to: 100.0 + 0.045)
        XCTAssertGreaterThan(fb.frame.beats[1]?.scale ?? 1, 1.1, "the dot pops (scale 1 -> 1.22 -> 1)")
    }

    // MARK: - Sparks are in the right place and actually painted

    func test_sparks_areInsideTheirWindow_andPaintPixelsAroundTheOrigin() throws {
        let fb = makeFeedback()
        let origin = CGPoint(x: 700, y: 500)
        fb.begin(TourFeedbackEvent(ringFrom: 1, ringTo: 2, sparkOriginOnScreen: origin))
        let overlay = fb.debugSparkOverlay
        let window = try XCTUnwrap(overlay.window, "sparks need their own click-through window")
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertTrue(window.frame.contains(origin), "window \(window.frame) must be centered on the ring \(origin)")
        let field = try XCTUnwrap(overlay.field)
        XCTAssertEqual(field.particles.count, TourMotionPolicy.Tokens.sparkCount)
        let local = try XCTUnwrap(overlay.originInWindow)
        XCTAssertEqual(local.x, window.frame.width / 2, accuracy: 0.5, "particles start at the window-local center, not at screen coordinates")

        let side = window.frame.width
        let sample = field.advanced(to: overlay.birth + 0.12, drag: 0.88)
        for p in sample.particles {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: side, height: side).contains(CGPoint(x: p.x, y: p.y)), "particle left its window: \(p.x),\(p.y)")
        }
        let px = try XCTUnwrap(TourRender.pixels(
            TourSparkView(field: field, startTime: overlay.birth, now: overlay.birth + 0.12).frame(width: side, height: side),
            size: CGSize(width: side, height: side)))
        var painted = 0, sx = 0.0, sy = 0.0
        for y in 0..<px.height { for x in 0..<px.width where px.rgba(x: x, y: y).a > 40 {
            painted += 1; sx += Double(x); sy += Double(y)
        } }
        XCTAssertGreaterThan(painted, 30, "sparks must paint pixels")
        XCTAssertEqual(sx / Double(painted) / px.scale, side / 2, accuracy: 14, "and be spread around the origin")
        XCTAssertEqual(sy / Double(painted) / px.scale, side / 2, accuracy: 14)
        fb.cancel()
        XCTAssertNil(overlay.window, "cancel closes the spark window")
    }

    func test_reduceMotion_noSparks_linearRing_noLineBreath() {
        let fb = makeFeedback(reduceMotion: true)
        fb.begin(TourFeedbackEvent(ringFrom: 1, ringTo: 2, sparkOriginOnScreen: CGPoint(x: 500, y: 500)))
        XCTAssertNil(fb.debugSparkOverlay.window)
        fb.advance(to: 100.0 + 0.2)
        XCTAssertEqual(fb.frame.ringLineWidth, 5.5, accuracy: 0.001)
        let progress = try? XCTUnwrap(fb.frame.ringProgress)
        XCTAssertNotNil(progress)
        fb.advance(to: 100.0 + 0.4)
        XCTAssertEqual(Double(fb.frame.ringProgress ?? 0), 2.0 / 7, accuracy: 0.001, "linear 0.30s fill is done by 0.35s")
    }

    // MARK: - Finale close + lifecycle

    func test_finale_closesRing_pulses_andRestsAfterwards() {
        let fb = makeFeedback()
        fb.begin(TourFeedbackEvent(ringFrom: 6, ringTo: 7, closesRing: true))
        fb.advance(to: 100.0 + 0.66)
        XCTAssertEqual(Double(fb.frame.ringProgress ?? 0), 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(fb.frame.ringScale, 1.0, "closing pulse scales the ring up")
        XCTAssertGreaterThan(fb.frame.ringLineWidth, 5.5)
        fb.advance(to: 100.0 + 5)
        XCTAssertFalse(fb.isActive)
        XCTAssertEqual(fb.frame, .rest)
    }

    func test_beatOnly_leavesTheRingAlone() {
        let fb = makeFeedback()
        fb.begin(TourFeedbackEvent(ringFrom: 1, ringTo: 1, beatIndices: [0]))
        fb.advance(to: 100.0 + 0.1)
        XCTAssertNil(fb.frame.ringProgress, "a beat completes no step: the ring keeps its static arc")
        XCTAssertEqual(fb.frame.numberOpacity, 1)
        XCTAssertNotNil(fb.frame.beats[0])
    }

    func test_timeline_isAPureFunctionOfElapsedTime() {
        let e = TourFeedbackEvent(ringFrom: 3, ringTo: 4, beatIndices: [1])
        let t = TourFeedbackTimeline(event: e, reduceMotion: false)
        XCTAssertEqual(t.frame(at: 0.3), t.frame(at: 0.3))
        XCTAssertEqual(t.frame(at: -1), .rest)
        XCTAssertEqual(t.frame(at: t.duration + 0.01), .rest)
    }
}
