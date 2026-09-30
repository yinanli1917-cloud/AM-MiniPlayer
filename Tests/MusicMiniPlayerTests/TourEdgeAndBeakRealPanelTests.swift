/**
 * [INPUT]: TourRealPanelFixture (the REAL panel, LiquidEdge controller and tour controller).
 * [OUTPUT]: TourEdgeAndBeakRealPanelTests — the founder's 2026-09-29 second walk (commit 10c8d42):
 *           A the "on the edge" card must stand at the strip after the REAL "Tuck it for me" tuck,
 *           B the ring must not outlive the peek card it was drawn around,
 *           C the move step's beak must follow the ring when the ring changes control mid-step.
 * [POS]: Tests. Every assertion reads the settled WINDOW frames / ring frame, not the placement target.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourEdgeAndBeakRealPanelTests: XCTestCase {
    private var f: TourRealPanelFixture!

    override func tearDown() {
        f?.tearDown()
        f = nil
        super.tearDown()
    }

    private let allButMoveAndBack: Set<TourStep> = Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])

    /// The card's beak tip in screen space (AppKit, y up), read from the card WINDOW as it is on screen.
    private func beakTip(of window: NSWindow, side: TourCardSide, offsetFromTop: CGFloat) -> CGPoint {
        let fr = window.frame
        switch side {
        case .right: return CGPoint(x: fr.maxX, y: fr.maxY - offsetFromTop)
        case .left: return CGPoint(x: fr.minX, y: fr.maxY - offsetFromTop)
        case .top: return CGPoint(x: fr.minX + offsetFromTop, y: fr.maxY)
        case .bottom: return CGPoint(x: fr.minX + offsetFromTop, y: fr.minY)
        }
    }

    // MARK: - A: the card stands at the strip

    /// Drives the same path as the card's "Tuck it for me" button (`onFallback` -> panel.hideToNearestEdge ->
    /// LiquidEdge collapse animation -> panelTucked -> completion handoff -> the "back" card), then reads
    /// the SETTLED card window. (The old test called `liquidEdge.collapse` from the "back" step and measured
    /// against the peek capsule's padded hit region, not the strip.)
    func test_A_tuckItForMe_backCardBeakTipStandsAtTheStrip() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [false, false]))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(0.8)
        let fallback = try XCTUnwrap(f.controller.debugCardStore?.onFallback, "the move card offers Tuck it for me")
        fallback()
        XCTAssertTrue(f.wait(6) { f.liquidEdge.state == .tucked }, "the panel tucks through the LiquidEdge animation")
        XCTAssertTrue(f.wait(6) { f.controller.debugCardStore?.model.kind == .step(.back) }, "the edge step arrives")
        f.spin(3.0)                                             // every spring settled

        let strip = f.liquidEdge.tuckedRegionInScreen
        XCTAssertFalse(strip.isEmpty)
        let store = try XCTUnwrap(f.controller.debugCardStore)
        let window = try XCTUnwrap(f.cardWindow)
        let tip = beakTip(of: window, side: store.beakSide, offsetFromTop: store.beakOffset)
        let gap = strip.minX - tip.x
        print("[A] strip=\(strip) card=\(window.frame) side=\(store.beakSide) tip=\(tip) gap=\(gap)")
        XCTAssertEqual(store.beakSide, .right, "the strip is on the right edge: the beak points right")
        XCTAssertEqual(gap, TourPlacement.sliverGap, accuracy: 4, "the beak tip stands ~20pt off the strip")
        XCTAssertLessThan(gap, 24)
        XCTAssertEqual(tip.y, strip.midY, accuracy: 2, "and level with it")

        // The peek card slides out over that ground: the card steps aside to stand 20pt off IT instead.
        f.liquidEdge.hoverEntered()
        XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .floating })
        f.spin(2.0)
        let peek = f.liquidEdge.floatingHitRegionInScreen
        let peekTip = beakTip(of: window, side: store.beakSide, offsetFromTop: store.beakOffset)
        XCTAssertEqual(peek.minX - peekTip.x, TourPlacement.sliverGap, accuracy: 4, "20pt off the peek card while it is out")
        XCTAssertLessThanOrEqual(window.frame.maxX, peek.minX, "and never under it")
    }

    // MARK: - B: no stale ring once the peek card is gone

    /// Tuck -> rest the cursor on the strip (peek out) -> click the peek card. From 0.3 s after the click until
    /// the finale card has been up for a while, the target ring must be gone (or on a live anchor) — never
    /// left drawn as a 132x216 rounded rect over the returned panel.
    func test_B_afterThePeekClick_theTargetRingLeavesAndNeverReturnsToTheStalePeekRect() throws {
        try runPeekClick(restBeforeClick: 0.8)
    }

    /// Clicking the peek card while beat 1's completion feedback is still playing (the natural quick click).
    func test_B_quickClickWhileTheFirstBeatFeedbackPlays_leavesNoStaleRing() throws {
        try runPeekClick(restBeforeClick: 0.0)
    }

    func test_B_clickAfterAFewHundredMs_leavesNoStaleRing() throws {
        try runPeekClick(restBeforeClick: 0.35)
    }

    private func runPeekClick(restBeforeClick: Double) throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.back])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        XCTAssertTrue(f.liquidEdge.collapse(to: .right))
        XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .tucked })
        f.spin(0.8)
        f.liquidEdge.hoverEntered()
        XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .floating })
        if restBeforeClick > 0 {
            XCTAssertTrue(f.wait(3) { (f.controller.debugHaloFrame?.size.width ?? 0) > 100 }, "fixture sanity: the ring is on the peek card")
            f.spin(restBeforeClick)
        }
        let peekRect = f.liquidEdge.floatingHitRegionInScreen

        f.liquidEdge.expand()                                   // click the peek card
        let t0 = Date()
        var stale: [(t: Double, rect: CGRect)] = []
        var sawFinale = false
        while Date().timeIntervalSince(t0) < 4.5 {
            f.spin(0.03)
            let t = Date().timeIntervalSince(t0)
            if f.controller.state.phase == .finale { sawFinale = true }
            if t > 0.3, let ring = f.controller.debugHaloFrame, !isLiveAnchor(ring) {
                stale.append((t, ring))
            }
        }
        XCTAssertTrue(sawFinale, "fixture sanity: the finale card arrived")
        XCTAssertTrue(stale.isEmpty, "a ring was left on a rect that is no live anchor (peek was \(peekRect)): first \(stale.first.map { "\($0.t)s \($0.rect)" } ?? "-")")
        XCTAssertNil(f.controller.debugHaloFrame, "the finale has no target ring at all")
    }

    private func isLiveAnchor(_ ring: CGRect) -> Bool {
        let live: [CGRect] = TourAnchorID.allCases.map { f.restingRect($0) }
        return live.contains { abs($0.midX - ring.midX) < 2 && abs($0.midY - ring.midY) < 2 }
    }

    // MARK: - C: the move card's beak follows the ring

    func test_C_moveStepOnTheLyricsPage_beakPointsAtTheBubbleRing_thenBackAtThePanelOnceTheRingLeaves() throws {
        f = TourRealPanelFixture(page: .lyrics)
        f.showControls(on: .lyrics)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(1.5)                                             // beak spring settled
        let store = try XCTUnwrap(f.controller.debugCardStore)
        let window = try XCTUnwrap(f.cardWindow)
        let ring = try XCTUnwrap(f.controller.debugHaloFrame)
        XCTAssertEqual(ring.midY, f.restingRect(.lyricsNav).midY, accuracy: 2, "fixture sanity: the ring is on the bubble")

        func expectedTipY(for targetMidY: CGFloat) -> CGFloat {
            min(max(targetMidY, window.frame.minY + TourPlacement.beakCornerClamp), window.frame.maxY - TourPlacement.beakCornerClamp)
        }
        var tip = beakTip(of: window, side: store.beakSide, offsetFromTop: store.beakOffset)
        print("[C] card=\(window.frame) ring=\(ring) tip=\(tip) panel=\(f.panel.frame)")
        XCTAssertEqual(tip.y, expectedTipY(for: ring.midY), accuracy: 2, "the beak points at the ringed bubble (clamped to the card's straight edge)")
        XCTAssertGreaterThan(abs(tip.y - f.panel.frame.midY), 20, "not at the panel's middle, where the lyrics text is")

        f.music.currentPage = .album                            // back on the cover: the ring leaves
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame == nil })
        f.spin(1.5)
        tip = beakTip(of: window, side: store.beakSide, offsetFromTop: store.beakOffset)
        XCTAssertEqual(tip.y, expectedTipY(for: f.panel.frame.midY), accuracy: 2, "with no ring the beak returns to the panel's middle")
    }
}
