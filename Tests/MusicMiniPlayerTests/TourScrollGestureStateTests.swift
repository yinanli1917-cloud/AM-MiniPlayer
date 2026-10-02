/**
 * [INPUT]: TourRealPanelFixture + ScrollSynth (phased trackpad gestures delivered through NSApp.sendEvent).
 * [OUTPUT]: TourScrollGestureStateTests — the 2026-10 hunt for "the two-finger drag often stops working during the tour":
 *           one test per hypothesis (cancelled/lost gesture endings, momentum vs the corner spring, page flips, the
 *           controls overlay, window re-ordering mid-gesture).
 * [POS]: Tests. Every gesture goes through `NSApp.sendEvent` (local monitors first, then the target window), with
 *        mayBegin / cancelled / momentum phases, never straight into `panel.sendEvent`.
 */

import XCTest
import AppKit
import Combine
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourScrollGestureStateTests: XCTestCase {
    private var f: TourRealPanelFixture!
    private var decisions: [SnappablePanel.ScrollDecision] = []
    private var movement: (began: Int, ended: Int) = (0, 0)
    private var observers: [NSObjectProtocol] = []

    private let allButMoveAndBack: Set<TourStep> = Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])
    /// Everything before the corners step: the tour sits on "Put it in a corner you like".
    private let beforeCorners: Set<TourStep> = [.connect, .reveal]

    override func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        f?.tearDown(); f = nil
        super.tearDown()
    }

    /// The real panel in the top-right corner, the tour on its corners step, and a decision recorder on the panel.
    private func makeTourOnCornersStep(page: PlayerPage = .album) {
        f = TourRealPanelFixture(page: page)
        f.controller.send(.resume(completed: beforeCorners))
        XCTAssertTrue(f.wait { f.cardWindow != nil }, "the tour's card is on screen")
        f.spin(0.8)
        decisions = []
        // The trace owns `scrollDecisionObserver` while the tour is up: chain onto it rather than replace it.
        let previous = f.panel.scrollDecisionObserver
        f.panel.scrollDecisionObserver = { [weak self] d in previous?(d); self?.decisions.append(d) }
        movement = (0, 0)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Notification.Name("windowMovementBegan"), object: f.panel, queue: nil) { [weak self] _ in self?.movement.began += 1 })
        observers.append(nc.addObserver(forName: Notification.Name("windowMovementEnded"), object: f.panel, queue: nil) { [weak self] _ in self?.movement.ended += 1 })
    }

    private func routes() -> [SnappablePanel.ScrollRoute] { decisions.map(\.route) }

    // MARK: - Control

    /// Control: a synthesized gesture through NSApp reaches the panel's router and moves it, with every phase present.
    func test_control_gestureThroughNSApp_reachesThePanelAndMovesIt() {
        makeTourOnCornersStep()
        let start = f.panel.frame.origin
        f.gesture(dx: -40, dy: 30, steps: 12)
        XCTAssertNotEqual(f.panel.frame.origin, start, "the panel followed the fingers")
        XCTAssertTrue(routes().contains(.albumDragApplied))
        XCTAssertTrue(routes().contains(.albumEndSpring), "the end started the corner spring: \(routes())")
        XCTAssertTrue(f.wait(3) { f.panel.currentCorner() != nil && f.panel.currentCorner() != .topRight }, "and it settled in another corner")
    }

    // MARK: - H1: how a gesture ENDS

    /// `.cancelled` is a real trackpad phase (the system takes the gesture away: another gesture claims the fingers, an
    /// edge swipe, ...). The album branch used to hand it straight to the content: the drag never ended, no spring ran,
    /// the panel stayed wherever the fingers had left it (off its corner), and `windowMovementBegan` had no `Ended`.
    func test_cancelledGesture_endsTheDragLikeAnEnd() {
        makeTourOnCornersStep()
        f.gesture(dx: -6, dy: 4, steps: 10, end: .cancelled)
        XCTAssertFalse(decisions.last?.isScrollDragging ?? true, "no drag is left open after a cancel: \(routes())")
        XCTAssertTrue(f.wait(3) { f.panel.currentCorner() != nil }, "the panel settles in a corner instead of being stranded at \(f.panel.frame.origin)")
        XCTAssertTrue(f.wait(2) { movement.ended >= 1 }, "windowMovementEnded follows windowMovementBegan (the playback clock must not stay paused)")
    }

    /// Same defect on the lyrics/playlist pages: a cancelled horizontal gesture left the panel where it was dragged, with
    /// the direction latch still set.
    func test_cancelledHorizontalGesture_onLyricsPage_springsBack() {
        makeTourOnCornersStep(page: .lyrics)
        let start = f.panel.frame.origin
        f.gesture(dx: -3, dy: 0, steps: 6, end: .cancelled)
        XCTAssertTrue(f.wait(3) { abs(f.panel.frame.origin.x - start.x) < 1 && abs(f.panel.frame.origin.y - start.y) < 1 },
                      "the panel returns to where the gesture began, is at \(f.panel.frame.origin) (began at \(start))")
    }

    /// A gesture whose `.ended` never arrives (the window it was aimed at changed under it) must not leave the next one
    /// without its bookkeeping: the next `.began` closes the stale drag first.
    func test_lostEnded_nextGestureStartsClean() {
        makeTourOnCornersStep()
        f.scroll(.mayBegin); f.scroll(.began)
        for _ in 0..<8 { f.scroll(dx: -8, dy: 6, .changed); f.spin(0.008) }
        // ... no ended. The fingers lift, touch again:
        f.spin(0.3)
        let beganBefore = movement.began
        f.gesture(dx: 6, dy: -4, steps: 6)
        XCTAssertGreaterThan(movement.began, beganBefore, "the new gesture announced its own start")
        XCTAssertTrue(f.wait(3) { f.panel.currentCorner() != nil }, "and the panel ends in a corner: \(String(describing: f.panel.currentCorner()))")
        XCTAssertFalse(decisions.last?.isScrollDragging ?? true)
    }

    // MARK: - H2: momentum vs the corner spring

    /// The trackpad keeps sending momentum events for a moment after `.ended`; they must pass the panel by without
    /// touching the spring it just started.
    func test_momentumAfterEnded_doesNotDisturbTheCornerSpring() {
        makeTourOnCornersStep()
        f.gesture(dx: -20, dy: 16, steps: 10, momentumEvents: 12)
        let momentum = decisions.filter { $0.momentumPhase != [] }
        XCTAssertEqual(momentum.count, 12)
        XCTAssertTrue(momentum.allSatisfy { $0.route == .albumPassedOn }, "momentum is passed on, never routed as a drag or an end")
        let projected = decisions.first { $0.route == .albumEndSpring }?.projectedCorner
        XCTAssertNotNil(projected, "the release picked a corner")
        XCTAssertTrue(f.wait(3) { f.panel.currentCorner() == projected }, "the spring still lands where the release projected it (\(String(describing: projected))): \(String(describing: f.panel.currentCorner()))")
    }

    /// A new gesture while the corner spring is still running takes over at once: no frozen frame, no waiting for isAnimating.
    func test_newGestureDuringTheSpring_followsTheFingersAtOnce() {
        makeTourOnCornersStep()
        f.gesture(dx: -20, dy: 16, steps: 10)
        f.spin(0.12)                               // mid-spring
        XCTAssertTrue(decisions.last?.isAnimating ?? false, "the spring is running")
        let before = f.panel.frame.origin
        f.scroll(.mayBegin); f.scroll(.began)
        f.scroll(dx: 10, dy: 0, .changed)
        let after = f.panel.frame.origin
        XCTAssertEqual(after.x - before.x, 15, accuracy: 1.0, "the first delta of the new gesture moved the panel by 1.5x: \(before) -> \(after)")
        f.scroll(.ended)
    }

    // MARK: - H3: the page the panel reads

    /// While the tour walks the corners step (controls revealed, hovered, hidden again) the provider the panel routes by
    /// never reports anything but the album page.
    func test_pageProvider_staysAlbumThroughTheCornersStep() {
        makeTourOnCornersStep()
        var pages: [PlayerPage] = []
        let end = Date().addingTimeInterval(4)
        var toggle = false
        while Date() < end {
            toggle.toggle()
            TourHookBus.shared.controlsVisible.send(toggle)
            f.spin(0.05)
            pages.append(f.panel.currentPageProvider?() ?? .lyrics)
        }
        XCTAssertTrue(pages.allSatisfy { $0 == .album }, "pages seen: \(Set(pages.map { "\($0)" }))")
    }

    // MARK: - H4: does anything take the event before the panel's sendEvent?

    /// With the controls revealed (the state the corners step is usually in), every phase of a gesture still reaches the
    /// panel's router: no local monitor eats it first.
    func test_controlsRevealed_everyPhaseStillReachesThePanel() {
        makeTourOnCornersStep()
        f.showControls(on: .album)
        decisions = []
        f.gesture(dx: -8, dy: 6, steps: 10, momentumEvents: 4)
        let phases = Set(decisions.map { $0.phase.rawValue })
        XCTAssertTrue(phases.contains(NSEvent.Phase.mayBegin.rawValue), "mayBegin reached the panel")
        XCTAssertTrue(phases.contains(NSEvent.Phase.began.rawValue))
        XCTAssertTrue(phases.contains(NSEvent.Phase.changed.rawValue))
        XCTAssertTrue(phases.contains(NSEvent.Phase.ended.rawValue))
        XCTAssertEqual(decisions.filter { $0.momentumPhase != [] }.count, 4)
        XCTAssertEqual(decisions.count, 1 + 1 + 10 + 1 + 4)
    }

    // MARK: - H5: window re-ordering in the middle of a gesture

    /// Fingers resting for longer than the card's 0.4 s resume delay: the card comes back mid-gesture and
    /// `raiseTourWindows` re-orders the panel (`orderFrontRegardless`) and the card. The gesture keeps working: the deltas
    /// after the re-order still move the panel, and WindowServer still says the panel is topmost at the cursor.
    /// (Whether AppKit itself would deliver `.cancelled` for such a re-order cannot be told in-process: the gesture trace
    /// records phases, raises and the topmost window in the real app to settle exactly that.)
    func test_raiseTourWindowsMidGesture_theGestureKeepsMovingThePanel() {
        makeTourOnCornersStep()
        f.scroll(.mayBegin); f.scroll(.began)
        for _ in 0..<6 { f.scroll(dx: -4, dy: 3, .changed); f.spin(0.008) }
        let mid = f.panel.frame.origin
        f.spin(1.0)                                  // fingers rest: the card resumes (and raises the windows) meanwhile
        XCTAssertEqual(f.panel.frame.origin, mid, "nothing moved the panel while the fingers rested")
        XCTAssertTrue(f.controller.gestureTrace.ring.elements.contains { $0.text.contains("raiseTourWindows") },
                      "the card came back and raised the windows during the gesture")
        let top = NSWindow.windowNumber(at: f.panelCentre, belowWindowWithWindowNumber: 0)
        if NSApp.window(withWindowNumber: top) != nil { XCTAssertEqual(top, f.panel.windowNumber, "the panel is still topmost at the cursor") }
        for _ in 0..<6 { f.scroll(dx: -4, dy: 3, .changed); f.spin(0.008) }
        XCTAssertEqual(f.panel.frame.origin.x - mid.x, -6 * 4 * 1.5, accuracy: 2, "the deltas after the re-order still move the panel")
        f.scroll(.ended)
        XCTAssertTrue(f.wait(3) { f.panel.currentCorner() != nil })
    }

    // MARK: - H6: the liquid-edge swipe's ownership (panel parked next to the edge, as the tour starts it)

    private func gesture(_ samples: [(CGFloat, CGFloat)]) {
        f.scroll(.mayBegin); f.scroll(.began)
        for (dx, dy) in samples { f.scroll(dx: dx, dy: dy, .changed); f.spin(0.008) }
        f.scroll(.ended)
    }

    /// The default start: top-right corner, within reach of the right edge. A gentle nudge that opens with a small wind-up
    /// toward the edge and then goes LEFT used to be swallowed whole by the edge swipe (decided from that one sample, never
    /// revisited): no drag, no tuck, "the two-finger drag does nothing".
    func test_windUpTowardTheEdge_thenAwayFromIt_stillMovesThePanel() {
        makeTourOnCornersStep()
        XCTAssertEqual(f.panel.currentCorner(), .topRight)
        let start = f.panel.frame.origin
        gesture([(3, 0)] + Array(repeating: (-9, 6), count: 12))
        let peak = decisions.map { hypot($0.frameAfter.origin.x - start.x, $0.frameAfter.origin.y - start.y) }.max() ?? 0
        XCTAssertGreaterThan(peak, 40, "the panel followed the fingers after the swipe let go of the gesture: \(routes())")
        XCTAssertTrue(routes().contains(.liquidSwipeOwned), "(the wind-up was taken for a tuck first)")
        XCTAssertTrue(routes().contains(.albumDragApplied))
        XCTAssertFalse(f.liquidEdge.isActive, "and nothing tucked")
        XCTAssertTrue(f.wait(3) { f.panel.currentCorner() != nil }, "and it settled in a corner: \(f.panel.frame.origin)")
    }

    /// Same wind-up, then straight down: a vertical turn also lets go.
    func test_windUpTowardTheEdge_thenDown_stillMovesThePanel() {
        makeTourOnCornersStep()
        let startY = f.panel.frame.origin.y
        gesture([(3, 0)] + Array(repeating: (0, 10), count: 14))
        XCTAssertTrue(routes().contains(.albumDragApplied), "\(routes())")
        XCTAssertGreaterThan(decisions.map { abs($0.frameAfter.origin.y - startY) }.max() ?? 0, 40, "the panel followed the fingers down")
        XCTAssertFalse(f.liquidEdge.isActive)
        XCTAssertTrue(f.wait(3) { f.panel.currentCorner() != nil }, "and settled in a corner: \(f.panel.frame.origin)")
    }

    /// A deliberate swipe toward the edge still tucks at once, and — held back until decided — never starts a drag under it
    /// (the drag used to be left open for good: `isScrollDragging` stuck, `windowMovementBegan` without an end).
    func test_swipeTowardTheEdge_tucks_andNeverStartsADrag() {
        makeTourOnCornersStep()
        gesture([(1, 0), (1, 0), (1, 0)] + Array(repeating: (6, 1), count: 6))
        XCTAssertEqual(Array(routes().dropFirst(2).prefix(2)), [.liquidSwipeHeld, .liquidSwipeHeld], "the first points of travel are held: \(routes())")
        XCTAssertTrue(routes().contains(.liquidSwipeFired), "\(routes())")
        XCTAssertFalse(routes().contains(.albumDragApplied), "no drag ever started")
        XCTAssertTrue(decisions.allSatisfy { !$0.isScrollDragging }, "and none is left open")
        XCTAssertEqual(movement.began, 0, "the panel never announced a movement of its own")
        XCTAssertTrue(f.wait(3) { f.liquidEdge.isActive })
    }

    /// Away from the edges nothing is held back: the very first sample drags.
    func test_awayFromTheEdges_nothingIsHeldBack() {
        makeTourOnCornersStep()
        let visible = NSScreen.main!.visibleFrame
        f.panel.setFrameOrigin(NSPoint(x: visible.midX - 125, y: visible.midY - 140))
        f.spin(0.3)
        decisions = []
        f.scroll(.mayBegin); f.scroll(.began)
        f.scroll(dx: 1, dy: 0, .changed)
        XCTAssertEqual(routes().last, .albumDragApplied)
        f.scroll(.ended)
    }

    // MARK: - Soak

    /// Many gestures of every size and direction at random moments of the corners step, with random pauses, cancels and
    /// momentum: after every one the panel is in a corner (or legitimately tucked, then brought back) and not stuck dragging,
    /// and every large one moved it.
    func test_soak_randomGesturesDuringTheCornersStep_neverLeaveTheDragStuck() {
        makeTourOnCornersStep()
        var rng = SystemRandomNumberGenerator()
        for i in 0..<14 {
            let dx = CGFloat.random(in: -14...14, using: &rng), dy = CGFloat.random(in: -14...14, using: &rng)
            let steps = Int.random(in: 4...16, using: &rng)
            let end: NSEvent.Phase = Int.random(in: 0..<5, using: &rng) == 0 ? .cancelled : .ended
            let before = f.panel.frame.origin
            let seen = decisions.count
            f.gesture(dx: dx, dy: dy, steps: steps, end: end, momentumEvents: Int.random(in: 0...4, using: &rng))
            f.spin(Double.random(in: 0...0.5, using: &rng))
            let mine = decisions[seen...]
            let tucked = mine.contains { $0.route == .liquidSwipeFired || $0.route == .albumEndTucked }
            if tucked {
                XCTAssertTrue(f.wait(3) { f.liquidEdge.isActive }, "#\(i): a tuck is a tuck")
                f.liquidEdge.reset()                 // the app's own way of putting a tucked panel back at once
                f.spin(0.4)
                f.panel.snapToNearestCorner()        // (where a restored panel sits is not what this soak is about)
            }
            XCTAssertTrue(f.wait(3) { f.panel.currentCorner() != nil }, "#\(i): in a corner after \(end) dx=\(dx) dy=\(dy) steps=\(steps) tucked=\(tucked), at \(f.panel.frame.origin)")
            XCTAssertFalse(decisions.last?.isScrollDragging ?? false, "#\(i): no drag left open")
            if !tucked, (abs(dx) + abs(dy)) * CGFloat(steps) > 120 {
                let peak = mine.map { hypot($0.frameAfter.origin.x - before.x, $0.frameAfter.origin.y - before.y) }.max() ?? 0
                XCTAssertGreaterThan(peak, 4, "#\(i): a big gesture moved the panel")
            }
        }
    }
}
