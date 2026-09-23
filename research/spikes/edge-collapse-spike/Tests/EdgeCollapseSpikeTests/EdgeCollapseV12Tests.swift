import XCTest
import SwiftUI
import MusicMiniPlayerCore
@testable import EdgeCollapseSpike

/// v12: edge light, swipe that follows the fingers, track-change peek,
/// interruption anywhere.
final class EdgeCollapseV12Tests: XCTestCase {
    private let dt = 1.0 / 120
    private let zeros = Array(repeating: 0.0, count: EdgeCollapsePose.channelCount)

    private func motion(_ kind: EdgeCollapseTransitionKind, _ from: EdgeCollapseKeyPose, bounce: EdgeCollapseBounce = .settle) -> EdgeCollapseMotion {
        EdgeCollapseMotion(from: EdgeCollapsePoses.pose(from, page: .album, style: .handle).vector(), velocity: zeros,
                           stages: EdgeCollapseChoreography.stages(kind: kind, fromTucked: from == .tucked, page: .album,
                                                                   style: .handle, bounce: bounce, tempo: .normal))
    }
    private func pose(_ m: EdgeCollapseMotion, _ t: Double) -> EdgeCollapsePose { EdgeCollapsePose(vector: m.sample(at: t).value) }

    // MARK: Edge light

    /// The light gathers to where the drop comes out, and is gone by the blob.
    func test_floatOut_lightGathersThenGoes() {
        let m = motion(.floatOut, .tucked)
        XCTAssertLessThan(pose(m, 0.06).glowLength, Double(EdgeCollapseTokens.glowLength) - 10, "gathering")
        let blobT = m.stages[1].start + 0.12
        XCTAssertLessThan(pose(m, blobT).glow, 0.2, "gone by the round blob")
    }

    /// On collapse the light comes up only once the black is mostly in the bezel.
    func test_collapse_lightAfterBlackGoesIn() {
        let m = motion(.collapse, .card)
        var t = 0.0
        while t < m.nominalDuration {
            let p = pose(m, t)
            if p.body.width > 8 { XCTAssertLessThan(p.glow, 0.25, "t=\(Int(t * 1000))ms light on while black still out") }
            t += dt
        }
        XCTAssertEqual(pose(m, m.settledDuration).glow, 1, accuracy: 0.02)
    }

    // MARK: Swipe follows the fingers

    func test_swipe_progressFollowsFingers_andRubberBands() {
        var s = EdgeCollapseSwipe()
        s.add(dx: 40, dy: 0, at: 0)
        XCTAssertEqual(s.progress, 40 / EdgeCollapseSwipe.fullDistance, accuracy: 1e-9)
        s.add(dx: 400, dy: 0, at: 0.1)
        XCTAssertGreaterThan(s.progress, 1)
        XCTAssertLessThan(s.progress, 1.16, "resists past the end")
        XCTAssertLessThan(s.trackedMotionTime, 0.09, "the landing stage is never driven by the fingers")
    }

    func test_swipe_verticalScrollIsIgnored() {
        var s = EdgeCollapseSwipe()
        XCTAssertFalse(s.add(dx: 1, dy: 9, at: 0))
        XCTAssertFalse(s.commits)
    }

    func test_swipe_commitByDistance_orByFlick_elseSpringBack() {
        var slowShort = EdgeCollapseSwipe()
        slowShort.add(dx: 10, dy: 0, at: 0); slowShort.add(dx: 10, dy: 0, at: 0.2)
        XCTAssertFalse(slowShort.commits, "short slow drag springs back")

        var slowFar = EdgeCollapseSwipe()
        for i in 0..<10 { slowFar.add(dx: 9, dy: 0, at: Double(i) * 0.05) }
        XCTAssertTrue(slowFar.commits, "dragged past 40% commits")

        var flick = EdgeCollapseSwipe()
        flick.add(dx: 8, dy: 0, at: 0); flick.add(dx: 16, dy: 0, at: 0.016); flick.add(dx: 16, dy: 0, at: 0.032)
        XCTAssertTrue(flick.commits, "a short flick commits by projected momentum")
    }

    // MARK: Track change peek

    func test_autoPeek_onlyWhenTucked_enabled_notHovering_andPlayerSilent() {
        XCTAssertTrue(EdgeCollapseAutoPeek.shouldPeek(presentation: .tucked, enabled: true, playerAlreadyNotifies: false, hovering: false))
        XCTAssertFalse(EdgeCollapseAutoPeek.shouldPeek(presentation: .tucked, enabled: true, playerAlreadyNotifies: true, hovering: false), "no double announcement")
        XCTAssertFalse(EdgeCollapseAutoPeek.shouldPeek(presentation: .tucked, enabled: false, playerAlreadyNotifies: false, hovering: false))
        XCTAssertFalse(EdgeCollapseAutoPeek.shouldPeek(presentation: .tucked, enabled: true, playerAlreadyNotifies: false, hovering: true))
        for p in [EdgePresentation.card, .collapsing, .floating, .expanding] {
            XCTAssertFalse(EdgeCollapseAutoPeek.shouldPeek(presentation: p, enabled: true, playerAlreadyNotifies: false, hovering: false))
        }
    }

    // MARK: Interrupt anywhere

    /// Every transition, cut every 20ms and sent to every resting state:
    /// value and velocity are continuous at the cut.
    func test_interruptAnywhere_isContinuous() {
        let cases: [(EdgeCollapseTransitionKind, EdgeCollapseKeyPose)] = [(.collapse, .card), (.floatOut, .tucked), (.retract, .floating), (.expand, .floating), (.expand, .tucked)]
        for (kind, from) in cases {
            let m = motion(kind, from)
            var t = 0.02
            while t < m.nominalDuration {
                let at = m.sample(at: t)
                for target in [EdgeCollapseKeyPose.card, .tucked, .floating] {
                    let n = EdgeCollapseMotion(from: at.value, velocity: at.velocity,
                                               stages: EdgeCollapseChoreography.direct(to: EdgeCollapsePoses.pose(target, page: .album, style: .handle).vector(), tempo: .normal))
                    let b = n.sample(at: 0)
                    for i in b.value.indices {
                        XCTAssertEqual(b.value[i], at.value[i], accuracy: 1e-9, "\(kind) cut at \(Int(t * 1000))ms → \(target) ch\(i)")
                        XCTAssertEqual(b.velocity[i], at.velocity[i], accuracy: 1e-6)
                    }
                }
                t += 0.02
            }
        }
    }
}
