import XCTest
@testable import MusicMiniPlayerCore

/// The S5 demo-panel arc's math (proposal §8.8 v3.3): quadratic Bézier,
/// sagitta 9% of the chord, peak at 45% of the path, ease-out, no overshoot.
/// Ported 1:1 from `storyboard.html`'s `arcControl`/`arcPoint` — ONLY the
/// in-card illustration; the real panel's corner-snap spring is untouched.
final class TourDemoPathTests: XCTestCase {
    // Storyboard's own worked example (§8.8 table): "右上角 20pt → 右下角
    // 16pt 这一下位移 ≈ 96pt，弧高 ≈ 8.6pt".
    private let from = CGPoint(x: 450, y: 44)   // 720×440 stage, panel 250×284, top-right 20pt margin
    private let to = CGPoint(x: 454, y: 140)    // bottom-right 16pt margin
    private let stageCenter = CGPoint(x: 360, y: 220)

    func test_startsAtFrom_endsAtTo() {
        XCTAssertEqual(TourDemoPath.point(from: from, to: to, bulgeToward: stageCenter, progress: 0), from)
        let end = TourDemoPath.point(from: from, to: to, bulgeToward: stageCenter, progress: 1)
        XCTAssertEqual(end.x, to.x, accuracy: 0.01)
        XCTAssertEqual(end.y, to.y, accuracy: 0.01)
    }

    func test_maxDeviationFromChord_isApproximatelyNinePercentOfChordLength() {
        let dx = to.x - from.x, dy = to.y - from.y
        let chordLength = hypot(dx, dy)
        var maxDeviation: CGFloat = 0
        var t: CGFloat = 0
        while t <= 1 {
            let p = TourDemoPath.point(from: from, to: to, bulgeToward: stageCenter, progress: t)
            // Perpendicular distance from p to the chord line (from -> to).
            let deviation = abs((p.x - from.x) * dy - (p.y - from.y) * dx) / chordLength
            maxDeviation = max(maxDeviation, deviation)
            t += 1.0 / 240
        }
        let expected = TourDemoPath.sagittaRatio * chordLength
        XCTAssertEqual(maxDeviation, expected, accuracy: expected * 0.15)
    }

    /// §8.8: "最高点位置 = 行程 45% 处" describes where the CONTROL POINT sits
    /// along the chord — `control(from:to:bulgeToward:)`'s `mid` term — not
    /// where the deviation-from-chord happens to peak along the timeline (for
    /// any quadratic Bézier with a purely perpendicular control offset, that
    /// peaks at the curve's own t=0.5 regardless of the control point's
    /// position along the chord — a property of the Bernstein basis, not
    /// something this curve is meant to defeat).
    func test_controlPoint_sitsAtFortyFivePercentOfChord_beforeBulgeOffset() {
        let c = TourDemoPath.control(from: from, to: to, bulgeToward: stageCenter)
        let chordMid = CGPoint(x: from.x + (to.x - from.x) * TourDemoPath.peak, y: from.y + (to.y - from.y) * TourDemoPath.peak)
        // The control point's projection back onto the chord must land at
        // `chordMid` — i.e. c minus its perpendicular offset equals chordMid.
        let dx = to.x - from.x, dy = to.y - from.y
        let len = hypot(dx, dy)
        let ux = dx / len, uy = dy / len
        let alongChord = (c.x - from.x) * ux + (c.y - from.y) * uy
        XCTAssertEqual(alongChord, len * TourDemoPath.peak, accuracy: 0.01)
        _ = chordMid
    }

    /// The Bézier's own raw parameter (not the eased animation progress) is
    /// where a quadratic curve's chord-deviation is exactly maximal, and
    /// that is always its t=0.5 — independent of where the control point
    /// sits along the chord (§8.8's ease-out only reparametrizes time, it
    /// never resamples the curve's shape).
    func test_deviationFromChord_peaksAtBezierParameterOneHalf() {
        let c = TourDemoPath.control(from: from, to: to, bulgeToward: stageCenter)
        let dx = to.x - from.x, dy = to.y - from.y
        let chordLength = hypot(dx, dy)
        var bestT: CGFloat = 0
        var bestDeviation: CGFloat = -1
        var t: CGFloat = 0
        while t <= 1 {
            let p = TourDemoPath.point(from: from, control: c, to: to, t: t)
            let deviation = abs((p.x - from.x) * dy - (p.y - from.y) * dx) / chordLength
            if deviation > bestDeviation { bestDeviation = deviation; bestT = t }
            t += 1.0 / 480
        }
        XCTAssertEqual(bestT, 0.5, accuracy: 0.01)
    }

    func test_noOvershoot_pathStaysWithinBoundingBoxOfEndpoints() {
        let minX = min(from.x, to.x) - 20, maxX = max(from.x, to.x) + 20 // generous margin for the bulge
        var t: CGFloat = 0
        while t <= 1 {
            let p = TourDemoPath.point(from: from, to: to, bulgeToward: stageCenter, progress: t)
            XCTAssertGreaterThanOrEqual(p.x, minX)
            XCTAssertLessThanOrEqual(p.x, maxX)
            t += 1.0 / 60
        }
    }

    func test_easeOut_monotonicNoOvershoot() {
        var previous: CGFloat = -1
        var t: CGFloat = 0
        while t <= 1 {
            let eased = TourDemoPath.easeOut(t)
            XCTAssertGreaterThanOrEqual(eased, previous - 0.0001)
            XCTAssertLessThanOrEqual(eased, 1.0001)
            previous = eased
            t += 1.0 / 240
        }
        XCTAssertEqual(TourDemoPath.easeOut(0), 0, accuracy: 0.0001)
        XCTAssertEqual(TourDemoPath.easeOut(1), 1, accuracy: 0.0001)
    }

    func test_bulgesTowardScreenCenter_notAwayFromIt() {
        // from top-right toward bottom-right (near-vertical) — the bulge
        // must lean toward the stage center (left of the chord), matching
        // storyboard's "鼓出方向：弦的法向里指向屏幕中心的那一侧".
        let mid = TourDemoPath.point(from: from, to: to, bulgeToward: stageCenter, progress: 0.45)
        let chordXAtMidY = from.x + (to.x - from.x) * 0.45
        XCTAssertLessThan(mid.x, chordXAtMidY, "the arc must bulge toward the screen center (left), not away from it")
    }

    func test_reducedMotion_landsDirectlyOnTarget() {
        XCTAssertEqual(TourDemoPath.reducedMotionPoint(to: to), to)
    }
}
