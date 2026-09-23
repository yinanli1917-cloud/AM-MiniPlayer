import XCTest
import SwiftUI
@testable import MusicMiniPlayerCore

/// The liquid edge (ported from research/spikes/edge-collapse-spike, founder-
/// approved 2026-09-22). Pure pose(t) checks on a fake 120Hz clock, on the
/// prototype's geometry and on the smallest and largest card sizes.
final class LiquidEdgeTests: XCTestCase {
    private let dt = 1.0 / 120
    private let zeros = Array(repeating: 0.0, count: LiquidEdgePose.channelCount)

    /// Prototype layout, min card (180x228) and max card (400x506), each 16pt off the edge.
    private var geometries: [LiquidEdgeGeometry] {
        [.reference,
         LiquidEdgeGeometry(card: CGRect(x: 28, y: 28, width: 180, height: 228), edgeX: 224),
         LiquidEdgeGeometry(card: CGRect(x: 28, y: 28, width: 400, height: 506), edgeX: 444)]
    }

    private func motion(_ kind: LiquidEdgeTransition, from: LiquidEdgeKeyPose, g: LiquidEdgeGeometry = .reference,
                        fromTucked: Bool = false, bouncy: Bool = false) -> LiquidEdgeMotion {
        LiquidEdgeMotion(from: LiquidEdgePoses(g).pose(from).vector(), velocity: zeros,
                         stages: LiquidEdgeChoreography.stages(kind: kind, fromTucked: fromTucked, geometry: g, bouncy: bouncy))
    }
    private func pose(_ m: LiquidEdgeMotion, _ t: Double) -> LiquidEdgePose { LiquidEdgePose(vector: m.sample(at: t).value) }

    private func all(_ g: LiquidEdgeGeometry) -> [LiquidEdgeMotion] {
        [motion(.collapse, from: .card, g: g), motion(.floatOut, from: .tucked, g: g), motion(.retract, from: .floating, g: g),
         motion(.expand, from: .floating, g: g), motion(.expand, from: .tucked, g: g, fromTucked: true)]
    }

    // MARK: Basics

    func test_startsAtFrom_endsAtTarget_everySize() {
        for g in geometries {
            for m in all(g) {
                XCTAssertEqual(m.sample(at: 0).value, m.from)
                let end = m.sample(at: m.settledDuration).value
                for (i, v) in end.enumerated() { XCTAssertEqual(v, m.to[i], accuracy: 0.15, "channel \(i)") }
                for v in end { XCTAssertFalse(v.isNaN) }
            }
        }
    }

    func test_reducer() {
        XCTAssertEqual(LiquidEdgeReducer.reduce(.card, .collapseRequested), .collapsing)
        XCTAssertEqual(LiquidEdgeReducer.reduce(.collapsing, .settled), .tucked)
        XCTAssertEqual(LiquidEdgeReducer.reduce(.tucked, .hoverEntered), .floating)
        XCTAssertEqual(LiquidEdgeReducer.reduce(.floating, .expandRequested), .expanding)
        XCTAssertEqual(LiquidEdgeReducer.reduce(.expanding, .settled), .card)
        XCTAssertEqual(LiquidEdgeReducer.reduce(.card, .hoverEntered), .card)
    }

    // MARK: One push, no freeze (founder: "卡一下顿一下")

    /// Speed rises once, peaks and falls; once slowed it is never kicked back up.
    func test_everyTransition_isOnePush() {
        for g in geometries {
            let cases: [(LiquidEdgeMotion, [Int])] = [
                (motion(.collapse, from: .card, g: g), [0, 1, 2, 3]),
                (motion(.floatOut, from: .tucked, g: g), [6, 7, 8, 9]),
                (motion(.retract, from: .floating, g: g), [6, 7, 8, 9]),
                (motion(.expand, from: .tucked, g: g, fromTucked: true), [6, 7, 8, 9]),
            ]
            for (m, ch) in cases {
                var peak = 0.0, trough = Double.infinity, worst = 0.0, t = 0.0
                while t < m.nominalDuration {
                    let v = m.sample(at: t).velocity
                    let s = ch.map { v[$0] * v[$0] }.reduce(0, +).squareRoot()
                    peak = max(peak, s)
                    if peak > 0, s < peak * 0.6 { trough = min(trough, s) }
                    if trough < .infinity { worst = max(worst, (s - trough) / max(peak, 1)) }
                    t += dt
                }
                XCTAssertLessThan(worst, 0.15)
            }
        }
    }

    // MARK: Shapes the references show

    func test_collapse_heightFirst_thenStalk_andLandsWithRebound() {
        let m = motion(.collapse, from: .card)
        let from = pose(m, 0)
        func first(_ f: (LiquidEdgePose) -> Bool) -> Double {
            var t = 0.0
            while t < m.settledDuration { if f(pose(m, t)) { return t }; t += dt }
            return .infinity
        }
        XCTAssertLessThan(first { $0.body.height < from.body.height * 0.5 + 1 }, first { $0.body.width < from.body.width * 0.5 })
        var t = 0.0, stalk = false
        while t < m.nominalDuration { let p = pose(m, t); if p.body.height > 70, p.body.width < 40 { stalk = true }; t += dt }
        XCTAssertTrue(stalk)

        let b = motion(.collapse, from: .card, bouncy: true)
        let rest = LiquidEdgeTokens.sliverSize.width
        var dived = false, back = false
        t = 0
        while t < b.settledDuration { let w = pose(b, t).body.width; if w < rest * 0.5 { dived = true }; if dived, w > rest * 0.9 { back = true }; t += dt }
        XCTAssertTrue(dived && back, "Dynamic-Island landing: dives into the edge and pops back")
    }

    func test_floatOut_roundDrop_neck_cleanPinchOff() {
        for g in geometries {
            let m = motion(.floatOut, from: .tucked, g: g)
            let poses = LiquidEdgePoses(g)
            var round = false, pinch: Double?, t = 0.0
            while t < 0.6 {
                let p = pose(m, t)
                if p.capsule.width > 50, abs(p.capsule.width / p.capsule.height - 1) < 0.12 { round = true }
                var pieces = 0
                LiquidOutline.path(parts: poses.liquidParts(p), neck: LiquidEdgeTokens.liquidNeck).forEach { if case .move = $0 { pieces += 1 } }
                if pinch == nil, pieces > 1 { pinch = t }
                if let pinch, t > pinch + 0.06 { XCTAssertLessThan(p.body.width, 1.5, "stub left at the edge") }
                t += dt
            }
            XCTAssertTrue(round, "passes a round drop")
            XCTAssertNotNil(pinch, "pinches off")
            XCTAssertLessThan(pose(m, dt).capsule.width, 12, "does not pop in")
        }
    }

    func test_retract_mergesIntoTheSliver_staysRound() {
        let m = motion(.retract, from: .floating)
        var out = false, lastVisible: LiquidEdgePose?, t = 0.0
        while t < m.settledDuration {
            let p = pose(m, t)
            if p.body.width >= 4 { out = true }
            if out { XCTAssertGreaterThanOrEqual(p.body.width, 4) }
            if p.capsule.width > 1 { lastVisible = p }
            if p.capsule.width > 1, p.capsule.width < 60 {
                XCTAssertGreaterThanOrEqual(p.capsuleCorner, min(p.capsule.width, p.capsule.height) / 2 - 1)
            }
            t += dt
        }
        let last = try! XCTUnwrap(lastVisible)
        XCTAssertGreaterThanOrEqual(last.capsule.maxX, last.body.minX - 1, "joined to the sliver when last seen")
    }

    /// Expanding IS the panel appearing (revealed in place while the liquid
    /// grows); the capsule's cover never travels; one outline only.
    func test_expand_revealsPanelInPlace_oneOutline() {
        for fromTucked in [false, true] {
            let m = motion(.expand, from: fromTucked ? .tucked : .floating, fromTucked: fromTucked)
            var t = 0.0, early = false
            let cover = LiquidEdgePoses(.reference).capsuleCoverRect
            while t < m.nominalDuration {
                let p = pose(m, t)
                if p.panelOpacity > 0.8, p.capsule.width < LiquidEdgeGeometry.reference.card.width - 20 { early = true }
                XCTAssertLessThanOrEqual(p.hero.width, cover.width + 1)
                if !fromTucked { XCTAssertLessThanOrEqual(p.body.width, 0.5) }
                t += dt
            }
            XCTAssertTrue(early)
        }
    }

    // MARK: Material and light

    func test_black_atTheEdge_glass_onlyAsCapsuleOrCard() {
        let out = motion(.floatOut, from: .tucked)
        var t = 0.0
        while t < out.nominalDuration {
            let p = pose(out, t)
            if p.capsule.width > 4, abs(p.capsule.height / p.capsule.width - 1) < 0.15 { XCTAssertLessThan(p.glass, 0.05) }
            t += dt
        }
        XCTAssertEqual(LiquidEdgePoses(.reference).pose(.tucked).glass, 0)
        let c = motion(.collapse, from: .card)
        XCTAssertLessThan(pose(c, 0.3).glass, 0.1, "black by the stalk")
    }

    func test_light_gathersOnTheWayOut_comesUpAfterBlackGoesIn() {
        let out = motion(.floatOut, from: .tucked)
        XCTAssertLessThan(pose(out, 0.06).glowLength, Double(LiquidEdgeTokens.glowLength) - 10)
        let c = motion(.collapse, from: .card)
        var t = 0.0
        while t < c.nominalDuration { let p = pose(c, t); if p.body.width > 8 { XCTAssertLessThan(p.glow, 0.25) }; t += dt }
    }

    /// The dark end of the fill never jumps (founder: "darker, then darker again").
    func test_fillSpan_isContinuous() {
        for (kind, from) in [(LiquidEdgeTransition.floatOut, LiquidEdgeKeyPose.tucked), (.retract, .floating), (.collapse, .card), (.expand, .floating)] {
            let m = motion(kind, from: from, bouncy: true)
            let poses = LiquidEdgePoses(.reference)
            var prev = poses.fillSpan(pose(m, 0)), t = dt
            while t < m.settledDuration {
                let s = poses.fillSpan(pose(m, t))
                XCTAssertLessThan(abs(s.maxX - prev.maxX), 8, "\(kind) t=\(Int(t * 1000))ms")
                prev = s; t += dt
            }
        }
    }

    // MARK: Interruption

    func test_interruptAnywhere_isContinuous() {
        let g = LiquidEdgeGeometry.reference
        for m in all(g) {
            var t = 0.02
            while t < m.nominalDuration {
                let at = m.sample(at: t)
                for target in [LiquidEdgeKeyPose.card, .tucked, .floating] {
                    let n = LiquidEdgeMotion(from: at.value, velocity: at.velocity,
                                             stages: LiquidEdgeChoreography.direct(to: LiquidEdgePoses(g).pose(target).vector()))
                    let b = n.sample(at: 0)
                    for i in b.value.indices {
                        XCTAssertEqual(b.value[i], at.value[i], accuracy: 1e-9)
                        XCTAssertEqual(b.velocity[i], at.velocity[i], accuracy: 1e-6)
                    }
                }
                t += 0.05
            }
        }
    }

    // MARK: Outline

    func test_outline_neckJoinsCloseParts_farPartsSeparate() {
        let handle = LiquidPart(rect: CGRect(x: 308, y: 160, width: 30, height: 40), radius: 6)
        let near = LiquidPart(rect: CGRect(x: 281, y: 169, width: 22, height: 22), radius: 11)
        let far = LiquidPart(rect: CGRect(x: 240, y: 169, width: 22, height: 22), radius: 11)
        func pieces(_ p: Path) -> Int { var n = 0; p.forEach { if case .move = $0 { n += 1 } }; return n }
        let joined = LiquidOutline.path(parts: [handle, near], neck: 14)
        XCTAssertEqual(pieces(joined), 1)
        XCTAssertTrue(joined.cgPath.contains(CGPoint(x: 305.5, y: 180)))
        XCTAssertEqual(pieces(LiquidOutline.path(parts: [handle, far], neck: 14)), 2)
    }

    func test_tucked_sliver_squareAtTheEdge_roundInside() {
        let poses = LiquidEdgePoses(.reference)
        let p = poses.pose(.tucked)
        let r = poses.tuckedRect
        let path = LiquidOutline.path(parts: poses.liquidParts(p), neck: LiquidEdgeTokens.liquidNeck).cgPath
        XCTAssertTrue(path.contains(CGPoint(x: 319.8, y: r.minY + 0.2)))
        XCTAssertTrue(path.contains(CGPoint(x: 319.8, y: r.maxY - 0.2)))
        XCTAssertFalse(path.contains(CGPoint(x: r.minX + 0.2, y: r.minY + 0.2)))
    }

    // MARK: Hit regions

    func test_hitRegions() {
        let poses = LiquidEdgePoses(.reference)
        XCTAssertTrue(poses.hitRegion(for: .floating).contains(poses.capsuleRect))
        let tucked = poses.hitRegion(for: .tucked)
        XCTAssertLessThanOrEqual(tucked.width, 12, "passing near the edge must not open it")
        XCTAssertLessThan(tucked.height, 100)
    }

    // MARK: Gestures and peek

    func test_swipe_actsAtOnce_bothWays_once() {
        var s = LiquidEdgeSwipe()
        XCTAssertNil(s.add(dx: 6, dy: 0, presentation: .card))
        XCTAssertEqual(s.add(dx: 6, dy: 0, presentation: .card), .collapse)
        XCTAssertNil(s.add(dx: 30, dy: 0, presentation: .card))
        for st in [LiquidEdgeState.tucked, .floating] {
            var e = LiquidEdgeSwipe()
            XCTAssertEqual(e.add(dx: -12, dy: 0, presentation: st), .expand)
        }
        var v = LiquidEdgeSwipe()
        XCTAssertNil(v.add(dx: 1, dy: 9, presentation: .card))
        XCTAssertNil(v.add(dx: 30, dy: 0, presentation: .card), "vertical scroll stays a scroll")
    }

    func test_autoPeek() {
        XCTAssertTrue(LiquidEdgeAutoPeek.shouldPeek(presentation: .tucked, enabled: true, playerAlreadyNotifies: false, hovering: false))
        XCTAssertFalse(LiquidEdgeAutoPeek.shouldPeek(presentation: .tucked, enabled: true, playerAlreadyNotifies: true, hovering: false))
        XCTAssertFalse(LiquidEdgeAutoPeek.shouldPeek(presentation: .card, enabled: true, playerAlreadyNotifies: false, hovering: false))
    }
}
