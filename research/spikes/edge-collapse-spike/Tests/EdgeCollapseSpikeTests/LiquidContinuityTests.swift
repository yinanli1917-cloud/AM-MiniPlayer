import XCTest
import SwiftUI
import MusicMiniPlayerCore
@testable import EdgeCollapseSpike

/// Founder 2026-09-22: the drop coming out of the edge and going back in has
/// a small hitch. Measured cause: chained stages handed over after the
/// previous one had nearly stopped, so the drop went fast → slow → kicked
/// fast again (floatOut: 484 → 140 → 660 pt/s within 100ms). One motion must
/// read as one push: its speed rises, peaks, and falls; once it has slowed
/// down it must not be kicked back up.
final class LiquidContinuityTests: XCTestCase {
    private let dt = 1.0 / 120

    private func motion(_ kind: EdgeCollapseTransitionKind, _ from: EdgeCollapseKeyPose, fromTucked: Bool = false) -> EdgeCollapseMotion {
        EdgeCollapseMotion(
            from: EdgeCollapsePoses.pose(from, page: .album, style: .handle).vector(),
            velocity: Array(repeating: 0, count: EdgeCollapsePose.channelCount),
            stages: EdgeCollapseChoreography.stages(kind: kind, fromTucked: fromTucked, page: .album, style: .handle, bounce: .bouncy, tempo: .normal))
    }

    /// Speed of the moving part: position + size channels of `channels`.
    private func speed(_ m: EdgeCollapseMotion, _ t: Double, _ channels: [Int]) -> Double {
        let v = m.sample(at: t).velocity
        return channels.map { v[$0] * v[$0] }.reduce(0, +).squareRoot()
    }

    /// Largest re-acceleration after the speed has fallen below 60% of the
    /// peak so far, as a fraction of that peak.
    private func kick(_ m: EdgeCollapseMotion, _ channels: [Int]) -> (Double, Double) {
        var peak = 0.0, trough = Double.infinity, worst = 0.0, at = 0.0
        var t = 0.0
        while t < m.nominalDuration {
            let s = speed(m, t, channels)
            if s > peak { if trough < peak * 0.6 { let k = (s - trough) / peak; if k > worst { worst = k; at = t } }; peak = max(peak, s) }
            if peak > 0, s < peak * 0.6 { trough = min(trough, s) }
            if trough < .infinity, s - trough > 0 { let k = (s - trough) / max(peak, 1); if k > worst { worst = k; at = t } }
            t += dt
        }
        return (worst, at)
    }

    private let capsule = [6, 7, 8, 9]
    private let body = [0, 1, 2, 3]

    func test_dropComingOut_isOnePush() {
        let (k, at) = kick(motion(.floatOut, .tucked), capsule)
        print("KICK floatOut", k, Int(at * 1000))
        XCTAssertLessThan(k, 0.15, "kicked again at \(Int(at * 1000))ms")
    }

    func test_dropGoingBack_isOnePush() {
        let (k, at) = kick(motion(.retract, .floating), capsule)
        print("KICK retract", k, Int(at * 1000))
        XCTAssertLessThan(k, 0.15, "kicked again at \(Int(at * 1000))ms")
    }

    func test_expandFromTucked_isOnePush() {
        let (k, at) = kick(motion(.expand, .tucked, fromTucked: true), capsule)
        print("KICK expandFromTucked", k, Int(at * 1000))
        XCTAssertLessThan(k, 0.15, "kicked again at \(Int(at * 1000))ms")
    }

    func test_collapse_isOnePush() {
        let (k, at) = kick(motion(.collapse, .card), body)
        print("KICK collapse", k, Int(at * 1000))
        XCTAssertLessThan(k, 0.15, "kicked again at \(Int(at * 1000))ms")
    }

    /// Tucked: a thin black sliver joined to the bezel (founder 2026-09-22:
    /// it must show a little so you know something is there), square on the
    /// edge side, round inside; the light runs along its inner sides.
    func test_tucked_isABlackSliverJoinedToTheEdge() {
        let p = EdgeCollapsePoses.pose(.tucked, page: .album, style: .handle)
        XCTAssertEqual(p.glass, 0, "plain black, not glass")
        XCTAssertEqual(p.glow, 1)
        let r = EdgeCollapsePoses.tuckedRect(.handle)
        XCTAssertLessThanOrEqual(r.width, 8, "only a little shows")
        let path = LiquidOutline.path(parts: EdgeCollapsePoses.liquidParts(p), neck: EdgeCollapseTokens.liquidNeck).cgPath
        let edge = EdgeCollapseTokens.containerSize.width
        XCTAssertTrue(path.contains(CGPoint(x: edge - 0.2, y: r.minY + 0.2)), "square at the edge")
        XCTAssertTrue(path.contains(CGPoint(x: edge - 0.2, y: r.maxY - 0.2)))
        XCTAssertFalse(path.contains(CGPoint(x: r.minX + 0.2, y: r.minY + 0.2)), "round inside")
    }

    /// While a black body sits at the edge it is joined to the bezel: the
    /// corners on the edge side are square (the drop stage's bulge).
    func test_bulgeAtTheEdge_isFlush() {
        let p = EdgeCollapsePoses.pose(.drop, page: .album, style: .handle)
        let path = LiquidOutline.path(parts: EdgeCollapsePoses.liquidParts(p), neck: EdgeCollapseTokens.liquidNeck).cgPath
        let edge = EdgeCollapseTokens.containerSize.width
        XCTAssertTrue(path.contains(CGPoint(x: edge - 0.2, y: p.body.minY + 0.3)))
        XCTAssertTrue(path.contains(CGPoint(x: edge - 0.2, y: p.body.maxY - 0.3)))
    }
}
