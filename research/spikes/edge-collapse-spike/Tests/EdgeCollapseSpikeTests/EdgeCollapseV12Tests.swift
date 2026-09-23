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

    // MARK: Two-finger swipe: one swipe, one action, at once

    func test_swipeRight_onPanel_collapsesAtOnce_once() {
        var s = EdgeCollapseSwipe()
        XCTAssertNil(s.add(dx: 6, dy: 0, presentation: .card))
        XCTAssertEqual(s.add(dx: 6, dy: 0, presentation: .card), .collapse, "fires past 10pt, mid-gesture")
        XCTAssertNil(s.add(dx: 30, dy: 0, presentation: .card), "only once per gesture")
    }

    func test_swipeLeft_onCapsuleOrSliver_expands_notOnPanel() {
        for p in [EdgePresentation.tucked, .floating] {
            var s = EdgeCollapseSwipe()
            XCTAssertEqual(s.add(dx: -12, dy: 0, presentation: p), .expand)
        }
        var onPanel = EdgeCollapseSwipe()
        XCTAssertNil(onPanel.add(dx: -40, dy: 0, presentation: .card))
        var rightOnCapsule = EdgeCollapseSwipe()
        XCTAssertNil(rightOnCapsule.add(dx: 40, dy: 0, presentation: .floating))
    }

    func test_swipe_verticalScrollIsIgnored() {
        var s = EdgeCollapseSwipe()
        XCTAssertNil(s.add(dx: 1, dy: 9, presentation: .card))
        XCTAssertNil(s.add(dx: 30, dy: 0, presentation: .card), "decided vertical: lyrics scrolling stays scrolling")
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

/// Founder 2026-09-22: coming out to the capsule it went "darker, then darker
/// again after a delay"; and the progress line must hug the sliver's curve.
final class EdgeCollapseV14Tests: XCTestCase {
    private let dt = 1.0 / 120

    func test_fillSpan_isContinuous_inEveryTransition() {
        let cases: [(EdgeCollapseTransitionKind, EdgeCollapseKeyPose)] = [(.floatOut, .tucked), (.retract, .floating), (.collapse, .card), (.expand, .floating)]
        for (kind, from) in cases {
            let m = EdgeCollapseMotion(from: EdgeCollapsePoses.pose(from, page: .album, style: .handle).vector(),
                                       velocity: Array(repeating: 0, count: EdgeCollapsePose.channelCount),
                                       stages: EdgeCollapseChoreography.stages(kind: kind, fromTucked: false, page: .album, style: .handle, bounce: .bouncy, tempo: .normal))
            var prev = EdgeCollapsePoses.fillSpan(EdgeCollapsePose(vector: m.from))
            var t = dt
            while t < m.settledDuration {
                let s = EdgeCollapsePoses.fillSpan(EdgeCollapsePose(vector: m.sample(at: t).value))
                XCTAssertLessThan(abs(s.maxX - prev.maxX), 8, "\(kind): dark end jumped at t=\(Int(t * 1000))ms")
                prev = s
                t += dt
            }
        }
    }

    /// Every point of the progress line is exactly `gap` outside the sliver
    /// (its rounded corners included): it hugs the curvature.
    func test_progressLine_hugsTheSliverCurve() {
        let w = EdgeCollapseTokens.handleSize.width, h = EdgeCollapseTokens.handleSize.height
        let edge = EdgeCollapseTokens.containerSize.width, midY = EdgeCollapseTokens.containerSize.height / 2
        let rc = w / 2
        for i in 0...200 {
            let p = EdgeRimGeometry.point(atFraction: CGFloat(i) / 200, sliverWidth: w, height: h, edge: edge, midY: midY)
            // Distance to the sliver: a rounded rect (inner corners rc) that runs past the edge.
            let d = LiquidOutline.sdf(Double(p.x), Double(p.y), cx: Double(edge - w / 2 + 10), cy: Double(midY),
                                      hx: Double(w / 2 + 10), hy: Double(h / 2), r: Double(rc))
            if p.x < edge - 0.5 {
                XCTAssertEqual(d, Double(EdgeRimGeometry.gap), accuracy: 0.05, "point \(i) at \(p)")
            }
        }
    }
}
