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
                let gap = p.body.minX - p.capsule.maxX
                if p.body.width > 1, p.capsule.width > 8, gap > 0, gap < EdgeCollapseTokens.containerSpacing { neck += dt }
                if p.body.width <= 1 || gap > EdgeCollapseTokens.containerSpacing { detached = true }
                if p.capsule.width > 50, abs(p.capsule.width / p.capsule.height - 1) < 0.12 { roundBlob = true }
                t += dt
            }
            XCTAssertGreaterThan(neck, 0.04, "\(style): neck lasted \(Int(neck * 1000))ms")
            XCTAssertTrue(detached)
            XCTAssertTrue(roundBlob, "\(style): no round blob")
        }
    }

    /// ref1: collapse loses height first, then width pinches into a stalk
    /// narrower than both ends (for the cover tab) before it is absorbed.
    func test_collapse_heightFirst_thenStalk() {
        let m = motion(.collapse, style: .coverTab)
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

    /// The real panel fades in only once the cover sits where the page has it.
    func test_expand_panelFadesInOnlyAfterCoverArrives() {
        for page in [PlayerPage.album, .playlist, .lyrics] {
            for fromTucked in [false, true] {
                let m = motion(.expand, fromTucked: fromTucked, page: page)
                let target = EdgeCollapsePoses.cardHero(page).rect
                var t = 0.0
                while t < m.settledDuration {
                    let p = pose(m, t)
                    if p.panelOpacity > 0.05 {
                        XCTAssertEqual(p.hero.width, target.width, accuracy: max(8, target.width * 0.06), "\(page) t=\(Int(t * 1000))ms")
                        XCTAssertEqual(p.hero.midX, target.midX, accuracy: 8, "\(page)")
                    }
                    t += dt
                }
            }
        }
    }

    /// Lyrics page has no cover: the cover becomes a blurred fill of the card.
    func test_lyricsPage_coverBecomesBlurredBackground() {
        let m = motion(.expand, page: .lyrics)
        let end = EdgeCollapsePose(vector: m.to)
        XCTAssertTrue(end.hero.contains(EdgeCollapsePoses.cardRect), "fills the card")
        XCTAssertGreaterThan(end.heroBlur, 15)
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
