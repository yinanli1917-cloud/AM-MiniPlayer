import XCTest
@testable import EdgeCollapseSpike
import MusicMiniPlayerCore

/// Choreography contract on the pure pose(t) function, fake clock at 120Hz.
final class EdgeCollapseMotionTests: XCTestCase {
    private let dt = 1.0 / 120
    private typealias K = EdgeCollapseTransitionKind

    private func rest(_ key: EdgeCollapseKeyPose, _ page: PlayerPage = .album, _ style: EdgeCollapseTuckStyle = .handle) -> [Double] {
        EdgeCollapsePoses.pose(key, page: page, style: style).vector()
    }

    private func motion(_ kind: K, fromTucked: Bool = false, page: PlayerPage = .album,
                        style: EdgeCollapseTuckStyle = .handle, bounce: EdgeCollapseBounce = .bouncy,
                        tempo: EdgeCollapseTempo = .normal) -> EdgeCollapseMotion {
        let from: EdgeCollapseKeyPose
        switch kind {
        case .collapse: from = .card
        case .floatOut: from = .tucked
        case .retract: from = .floating
        case .expand: from = fromTucked ? .tucked : .floating
        }
        return EdgeCollapseMotion(
            from: rest(from, page, style),
            velocity: Array(repeating: 0, count: EdgeCollapsePose.channelCount),
            stages: EdgeCollapseChoreography.stages(kind: kind, fromTucked: fromTucked, page: page, style: style, bounce: bounce, tempo: tempo))
    }

    private func pose(_ m: EdgeCollapseMotion, _ t: Double) -> EdgeCollapsePose { EdgeCollapsePose(vector: m.sample(at: t).value) }

    private var all: [EdgeCollapseMotion] {
        var list: [EdgeCollapseMotion] = []
        for page in [PlayerPage.album, .lyrics, .playlist] {
            for style in EdgeCollapseTuckStyle.allCases {
                list += [motion(.collapse, page: page, style: style), motion(.floatOut, page: page, style: style),
                         motion(.retract, page: page, style: style), motion(.expand, page: page, style: style),
                         motion(.expand, fromTucked: true, page: page, style: style)]
            }
        }
        return list
    }

    func test_startsAtFrom_endsAtLastStage() {
        for m in all {
            XCTAssertEqual(m.sample(at: 0).value, m.from)
            let end = m.sample(at: m.settledDuration).value
            for (i, v) in end.enumerated() { XCTAssertEqual(v, m.to[i], accuracy: 0.15, "channel \(i)") }
        }
    }

    /// Something visible moves on the first frame, and never freezes mid-way.
    func test_noHoldNoFreeze() {
        for m in all {
            var t = dt, still = 0.0, longest = 0.0
            var prev = pose(m, 0)
            let first = pose(m, dt)
            let firstMove = max(abs(first.body.width - prev.body.width), abs(first.body.height - prev.body.height),
                                abs(first.capsule.width - prev.capsule.width), abs(first.capsule.minX - prev.capsule.minX))
            XCTAssertGreaterThan(firstMove, 0.3, "holds on the first frame")
            while t < m.nominalDuration * 0.8 {
                let p = pose(m, t)
                let moved = [abs(p.body.width - prev.body.width), abs(p.body.height - prev.body.height), abs(p.body.maxX - prev.body.maxX),
                             abs(p.capsule.width - prev.capsule.width), abs(p.capsule.minX - prev.capsule.minX),
                             abs(p.capsule.height - prev.capsule.height), abs(p.hero.width - prev.hero.width)].max()!
                still = moved < 0.05 ? still + dt : 0
                longest = max(longest, still)
                prev = p; t += dt
            }
            XCTAssertLessThan(longest, 0.034, "froze \(Int(longest * 1000))ms")
        }
    }

    /// ref4: the drop stays joined to the handle by a neck for a while, then
    /// pinches off; ref1: it passes a round blob, rounder than both ends.
    func test_floatOut_neckThenPinchOff_thenRoundBlob() {
        for style in EdgeCollapseTuckStyle.allCases {
            let m = motion(.floatOut, style: style)
            var neck = 0.0, detached = false, roundBlob = false, t = 0.0
            while t < m.nominalDuration {
                let p = pose(m, t)
                // Measured on the real outline: still one piece, and just
                // right of the drop it is clearly narrower than the drop — a
                // waist joining it to the edge = the neck.
                let outline = LiquidOutline.path(parts: EdgeCollapsePoses.liquidParts(p), neck: EdgeCollapseTokens.liquidNeck)
                var pieces = 0
                outline.forEach { if case .move = $0 { pieces += 1 } }
                if pieces == 1, p.capsule.width > 8, p.body.width > 0.5 {
                    // Narrowest vertical span between the drop's centre and
                    // the screen edge: a waist thinner than both parts.
                    let cg = outline.cgPath
                    var waist = Double.infinity
                    var x = Double(p.capsule.midX)
                    while x < Double(EdgeCollapseTokens.containerSize.width) - 1 {
                        var span = 0.0, y = Double(min(p.capsule.minY, p.body.minY)) - 10
                        while y < Double(max(p.capsule.maxY, p.body.maxY)) + 10 { if cg.contains(CGPoint(x: x, y: y)) { span += 0.5 }; y += 0.5 }
                        waist = min(waist, span)
                        x += 1
                    }
                    if waist > 0.5, waist < 0.8 * Double(max(p.capsule.height, p.body.height)) { neck += dt }
                }
                if p.body.width <= 0.5 || pieces > 1 { detached = true }
                if p.capsule.width > 50, abs(p.capsule.width / p.capsule.height - 1) < 0.12 { roundBlob = true }
                t += dt
            }
            // A neck forms and pinches off cleanly (>= 2 frames). The old 40ms bar
            // was met only by leaving a stub at the edge that dimpled the
            // capsule — the "sticky hitch" (founder 2026-09-22).
            XCTAssertGreaterThanOrEqual(neck, 2 * dt - 1e-9, "\(style): neck lasted \(Int(neck * 1000))ms")
            XCTAssertTrue(detached)
            XCTAssertTrue(roundBlob, "\(style): no round blob")
        }
    }

    /// ref1: collapse loses height first, then width pinches into a stalk
    /// narrower than both ends (for the cover tab) before it is absorbed.
    func test_collapse_heightFirst_thenStalk() {
        let m = motion(.collapse)
        let from = pose(m, 0)
        func firstTime(_ f: (EdgeCollapsePose) -> Bool) -> Double {
            var t = 0.0
            while t < m.settledDuration { if f(pose(m, t)) { return t }; t += dt }
            return .infinity
        }
        let halfHeight = firstTime { $0.body.height < from.body.height * 0.5 + 1 }
        let halfWidth = firstTime { $0.body.width < from.body.width * 0.5 }
        XCTAssertLessThan(halfHeight, halfWidth, "height must collapse before width")
        var t = 0.0, stalk = false
        while t < m.nominalDuration {
            let p = pose(m, t)
            if p.body.height > 70, p.body.width < 40 { stalk = true }
            t += dt
        }
        XCTAssertTrue(stalk, "no stalk (tall and narrow) on the way into the edge")
    }

    /// At the edge the object is pure black, not glass (system glass always
    /// has a rim and never reaches black): through the drop, the neck and
    /// the round blob the glass amount is zero; it is glass only as the
    /// capsule (founder 2026-09-22).
    func test_floatOut_blackUntilItBecomesTheCapsule() {
        let m = motion(.floatOut)
        var t = 0.0
        while t < m.nominalDuration {
            let p = pose(m, t)
            // While it is still a round drop (aspect within 15%), it is black.
            if p.capsule.width > 4, abs(p.capsule.height / p.capsule.width - 1) < 0.15 {
                XCTAssertLessThan(p.glass, 0.05, "glass on a round drop at t=\(Int(t * 1000))ms")
            }
            t += dt
        }
        XCTAssertEqual(EdgeCollapsePose(vector: m.to).glass, 1, accuracy: 0.01)
        XCTAssertEqual(EdgeCollapsePoses.pose(.tucked, page: .album, style: .handle).glass, 0)
    }

    /// ref1: on collapse the material turns black mid-way, by the stalk.
    func test_collapse_turnsBlackByTheStalk() {
        let m = motion(.collapse)
        let stalkStart = m.stages[1].start
        XCTAssertGreaterThan(pose(m, 0.02).glass, 0.7)
        XCTAssertLessThan(pose(m, stalkStart + 0.2).glass, 0.1)
    }

    /// Expand draws one outline: the edge body does not grow alongside the
    /// capsule (recording: a circle and a rounded rect overlapped).
    func test_expandFromCapsule_edgeBodyStaysGone() {
        let m = motion(.expand)
        var t = 0.0
        while t < m.settledDuration {
            XCTAssertLessThanOrEqual(pose(m, t).body.width, 0.5, "t=\(Int(t * 1000))ms")
            t += dt
        }
    }

    /// The capsule's edge-side gradient only shows with its content, so it
    /// never sits as a separate layer on a morphing shape.
    func test_capsuleGradient_onlyWithContent() {
        for kind in [K.floatOut, .retract, .expand] {
            let m = motion(kind)
            var t = 0.0
            while t < m.settledDuration {
                let p = pose(m, t)
                if abs(p.capsule.width / max(p.capsule.height, 1) - 1) < 0.12, p.capsule.width > 40 {
                    XCTAssertLessThan(p.capsuleContentOpacity, 0.2, "\(kind) round blob with gradient at t=\(Int(t * 1000))ms")
                }
                t += dt
            }
        }
    }

    /// Expanding IS the panel appearing: the panel is shown while the
    /// liquid is still growing (not faded in at the end), and the capsule's
    /// cover never grows or travels toward the panel (no migration).
    func test_expand_revealsThePanelInPlace_noMigration() {
        for fromTucked in [false, true] {
            let m = motion(.expand, fromTucked: fromTucked)
            var t = 0.0, sawPanelWhileGrowing = false
            let capCover = EdgeCollapsePoses.capsuleCoverRect
            while t < m.nominalDuration {
                let p = pose(m, t)
                if p.panelOpacity > 0.8, p.capsule.width < EdgeCollapsePoses.cardRect.width - 20 { sawPanelWhileGrowing = true }
                XCTAssertLessThanOrEqual(p.hero.width, capCover.width + 1, "cover grew at t=\(Int(t * 1000))ms")
                t += dt
            }
            XCTAssertTrue(sawPanelWhileGrowing, "fromTucked=\(fromTucked): panel only appeared at the end")
        }
    }

    func test_retargetMidFlight_isContinuous() {
        let out = motion(.floatOut)
        let at = out.sample(at: 0.12)
        let back = EdgeCollapseMotion(from: at.value, velocity: at.velocity,
                                      stages: EdgeCollapseChoreography.direct(to: rest(.tucked), tempo: .normal))
        let b0 = back.sample(at: 0)
        for i in 0..<EdgeCollapsePose.channelCount {
            XCTAssertEqual(b0.value[i], at.value[i], accuracy: 1e-9)
            XCTAssertEqual(b0.velocity[i], at.velocity[i], accuracy: 1e-6)
        }
    }

    func test_multiStageVelocity_isContinuousAcrossStageStarts() {
        let m = motion(.floatOut)
        for stage in m.stages.dropFirst() {
            // A new stage starts from zero added velocity, so crossing its start
            // moves each channel only by what its current velocity implies.
            let h = 1e-6
            let a = m.sample(at: stage.start - h), b = m.sample(at: stage.start + h)
            for i in a.value.indices {
                XCTAssertEqual(a.velocity[i], b.velocity[i], accuracy: 0.2, "velocity jump on channel \(i)")
                XCTAssertLessThanOrEqual(abs(b.value[i] - a.value[i]), abs(a.velocity[i]) * 2 * h + 0.01)
            }
        }
    }

    func test_tempoSlowStretchesDuration() {
        XCTAssertEqual(motion(.collapse, tempo: .slow).nominalDuration, motion(.collapse).nominalDuration * 1.5, accuracy: 1e-9)
    }
}

extension EdgeCollapseMotionTests {
    /// After the neck breaks the edge is clean within 60ms (no stub).
    func test_floatOut_edgeCleanSoonAfterPinchOff() {
        let m = EdgeCollapseMotion(from: EdgeCollapsePoses.pose(.tucked, page: .album, style: .handle).vector(),
                                   velocity: Array(repeating: 0, count: EdgeCollapsePose.channelCount),
                                   stages: EdgeCollapseChoreography.stages(kind: .floatOut, fromTucked: false, page: .album, style: .handle, bounce: .settle, tempo: .normal))
        var t = 0.0, pinch: Double?
        while t < 0.5 {
            let p = EdgeCollapsePose(vector: m.sample(at: t).value)
            var pieces = 0
            LiquidOutline.path(parts: EdgeCollapsePoses.liquidParts(p), neck: EdgeCollapseTokens.liquidNeck).forEach { if case .move = $0 { pieces += 1 } }
            if pinch == nil, pieces > 1 { pinch = t }
            if let pinch, t > pinch + 0.06 { XCTAssertLessThan(p.body.width, 1.5, "stub at the edge at t=\(Int(t * 1000))ms") }
            t += 1.0 / 120
        }
        XCTAssertNotNil(pinch, "never pinched off")
    }
}
