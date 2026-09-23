import XCTest
@testable import EdgeCollapseSpike

/// Choreography contract, checked on the pure pose(t) function with a fake
/// clock at 120Hz. Evidence for v7's failures came from the founder's
/// recording: a ~200ms hold of the full-size cover at collapse start, and an
/// empty glass slab at full size before the cover and panel arrived on expand.
final class EdgeCollapseMotionTests: XCTestCase {
    private let dt = 1.0 / 120
    private typealias L = EdgeCollapseLayout.VisualLayout

    private func motion(_ kind: EdgeCollapseTransitionKind, _ a: L, _ b: L, bounce: EdgeCollapseBounce = .bouncy) -> EdgeCollapseMotion {
        EdgeCollapseMotion(
            from: EdgeCollapsePoses.pose(for: a).vector(),
            velocity: Array(repeating: 0, count: EdgeCollapsePose.channelCount),
            to: EdgeCollapsePoses.pose(for: b).vector(),
            plan: .plan(for: kind, bounce: bounce, tempo: .normal))
    }

    private func pose(_ m: EdgeCollapseMotion, _ t: Double) -> EdgeCollapsePose {
        EdgeCollapsePose(vector: m.sample(at: t).value)
    }

    private var cases: [(EdgeCollapseTransitionKind, L, L)] {
        [(.collapse, .card, .tucked), (.floatOut, .tucked, .floating), (.retract, .floating, .tucked),
         (.expand, .floating, .card), (.expand, .tucked, .card)]
    }

    func test_startsAtFrom_endsAtTo() {
        for (k, a, b) in cases {
            let m = motion(k, a, b)
            XCTAssertEqual(pose(m, 0), EdgeCollapsePoses.pose(for: a), "\(k)")
            let end = m.sample(at: m.settledDuration).value
            for (i, v) in end.enumerated() {
                XCTAssertEqual(v, m.to[i], accuracy: 0.15, "\(k) channel \(i)")
            }
        }
    }

    /// The largest visible element moves on the first frame.
    func test_noHoldAtStart() {
        let checks: [(EdgeCollapseTransitionKind, L, L, (EdgeCollapsePose) -> CGFloat)] = [
            (.collapse, .card, .tucked, { $0.hero.width }),
            (.collapse, .card, .tucked, { $0.body.width }),
            (.floatOut, .tucked, .floating, { $0.capsule.width }),
            (.retract, .floating, .tucked, { $0.capsule.width }),
            (.expand, .floating, .card, { $0.capsule.width }),
            (.expand, .floating, .card, { $0.hero.width }),
        ]
        for (k, a, b, measure) in checks {
            let m = motion(k, a, b)
            XCTAssertGreaterThan(abs(measure(pose(m, dt)) - measure(pose(m, 0))), 0.5, "\(k) holds still on the first frame")
        }
    }

    /// While the transition is running, something on screen moves every frame.
    func test_noFrozenFramesMidTransition() {
        for (k, a, b) in cases {
            let m = motion(k, a, b)
            var t = dt
            var still = 0.0, longestStill = 0.0
            var prev = pose(m, 0)
            while t < m.nominalDuration * 0.8 {
                let p = pose(m, t)
                let moved = [abs(p.body.width - prev.body.width), abs(p.body.minX - prev.body.minX),
                             abs(p.capsule.width - prev.capsule.width), abs(p.capsule.minX - prev.capsule.minX),
                             abs(p.hero.width - prev.hero.width)].max()!
                still = moved < 0.05 ? still + dt : 0
                longestStill = max(longestStill, still)
                prev = p; t += dt
            }
            XCTAssertLessThan(longestStill, 0.034, "\(k): geometry froze for \(Int(longestStill * 1000))ms")
        }
    }

    /// The real panel only fades in once the cover has reached the panel's
    /// cover rect, so the crossfade is between two identical images.
    func test_expand_panelFadesInOnlyAfterCoverArrives() {
        for from in [L.floating, .tucked] {
            let m = motion(.expand, from, .card)
            let target = EdgeCollapsePoses.cardCoverRect
            var t = 0.0
            while t < m.settledDuration {
                let p = pose(m, t)
                if p.panelOpacity > 0.05 {
                    XCTAssertEqual(p.hero.width, target.width, accuracy: 12, "t=\(Int(t * 1000))ms panel \(p.panelOpacity) while cover is \(p.hero.width)")
                    XCTAssertEqual(p.hero.minX, target.minX, accuracy: 12)
                }
                t += dt
            }
        }
    }

    /// Expand never shows an empty glass slab: mid-flight, the share of the
    /// glass covered by the cover never drops below the emptier of the two
    /// resting states (capsule 96² of 120×204; card 250² of 250×316).
    func test_expand_coverFillsTheGrowingGlass() {
        func ratio(_ p: EdgeCollapsePose) -> Double {
            Double(max(p.hero.width, 0) * max(p.hero.height, 0)) / Double(max(p.capsule.width * p.capsule.height, 1))
        }
        let floor = min(ratio(EdgeCollapsePoses.pose(for: .floating)), ratio(EdgeCollapsePoses.pose(for: .card))) - 0.03
        let m = motion(.expand, .floating, .card)
        var t = 0.0
        while t < m.nominalDuration {
            let p = pose(m, t)
            if p.panelOpacity < 0.5 {
                XCTAssertGreaterThan(ratio(p), floor, "t=\(Int(t * 1000))ms cover/glass=\(ratio(p))")
            }
            t += dt
        }
    }

    /// The cover lands last on collapse (Apple Music hero flight).
    func test_collapse_coverLandsAfterBody() {
        let m = motion(.collapse, .card, .tucked)
        func arrive(_ f: (EdgeCollapsePose) -> CGFloat, _ target: CGFloat) -> Double {
            var t = m.settledDuration
            while t > 0, abs(f(pose(m, t)) - target) < 3 { t -= dt }
            return t
        }
        let body = arrive({ $0.body.width }, EdgeCollapsePoses.stripRect.width)
        let hero = arrive({ $0.hero.width }, EdgeCollapsePoses.tuckedHeroRect.width)
        XCTAssertGreaterThan(hero, body - 0.05, "cover arrives \(Int(hero * 1000))ms, body \(Int(body * 1000))ms")
    }

    /// Hover out mid float-out continues from the same value and velocity.
    func test_retargetMidFlight_isContinuous() {
        let out = motion(.floatOut, .tucked, .floating)
        let tCut = 0.12
        let at = out.sample(at: tCut)
        let back = EdgeCollapseMotion(from: at.value, velocity: at.velocity,
                                      to: EdgeCollapsePoses.pose(for: .tucked).vector(),
                                      plan: .plan(for: .retract, bounce: .bouncy, tempo: .normal))
        let b0 = back.sample(at: 0)
        for i in 0..<EdgeCollapsePose.channelCount {
            XCTAssertEqual(b0.value[i], at.value[i], accuracy: 1e-9)
            XCTAssertEqual(b0.velocity[i], at.velocity[i], accuracy: 1e-9)
        }
        // First frame after the cut moves by what the velocity implies, not a jump.
        let b1 = back.sample(at: dt).value
        let capsuleW = 8
        XCTAssertLessThan(abs(b1[capsuleW] - at.value[capsuleW]), abs(at.velocity[capsuleW]) * dt + 3)
    }

    func test_tempoSlowStretchesDuration() {
        let n = EdgeCollapseMotion(from: EdgeCollapsePoses.pose(for: .card).vector(), velocity: Array(repeating: 0, count: 23),
                                   to: EdgeCollapsePoses.pose(for: .tucked).vector(), plan: .plan(for: .collapse, bounce: .bouncy, tempo: .normal))
        let s = EdgeCollapseMotion(from: n.from, velocity: n.velocity, to: n.to, plan: .plan(for: .collapse, bounce: .bouncy, tempo: .slow))
        XCTAssertEqual(s.nominalDuration, n.nominalDuration * 1.5, accuracy: 1e-9)
    }
}
