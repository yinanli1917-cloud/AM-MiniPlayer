import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Real-NSView integration layer for the progress-bar hover-intent gate:
// hosts an actual NativePlaybackProgressView in a real NSWindow (pattern
// borrowed from LiquidEdgeCapsuleInputTests) and drives it with synthesized
// NSEvents, so the responder-method wiring (mouseEntered/mouseMoved/
// mouseExited/mouseDown/mouseDragged -> ProgressHoverIntentEngine calls) is
// exercised, not just the pure reducer in isolation.
//
// Scope note: `syncHoverStateToPointer()` (called from layout(),
// updateTrackingAreas(), and mouseUp()) resolves against
// `window.mouseLocationOutsideOfEventStream` — the REAL live system
// pointer, not the synthetic event's own coordinates. This suite never
// moves the actual OS cursor (this project's rules forbid computer-use /
// screen automation for feel verification), so those specific call sites
// are exercised only up to the point where they'd need the real pointer;
// `resolve()`'s own logic (what they all delegate to) is fully covered by
// ProgressHoverIntentEngineTests instead. See the report for this
// consciously-scoped gap.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
@MainActor
final class ProgressHoverIntentViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: NativePlaybackProgressView!

    override func setUp() {
        super.setUp()
        MicroInteractionFeel.resetTestingOverrides()
        MicroInteractionFeel.testingProgressHoverIntent = .intent
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        view = NativePlaybackProgressView(frame: CGRect(x: 0, y: 0, width: 300, height: 32))
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        spin(0.05)
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
        view = nil
        MicroInteractionFeel.resetTestingOverrides()
        super.tearDown()
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Point / event helpers

    private var insidePoint: CGPoint {
        let r = view.progressInteractiveRect()
        return CGPoint(x: r.midX, y: r.midY)
    }

    private var outsidePoint: CGPoint {
        // Above the bar (progressInteractiveRect's height is the bottom
        // strip of the 32pt-tall view) — still inside the view's own
        // bounds, but outside the interactive hit rect.
        let r = view.progressInteractiveRect()
        return CGPoint(x: r.midX, y: r.maxY + 10)
    }

    private func farInsidePoint(dx: CGFloat) -> CGPoint {
        let r = view.progressInteractiveRect()
        return CGPoint(x: min(r.maxX - 1, r.midX + dx), y: r.midY)
    }

    private func enterExitEvent(_ type: NSEvent.EventType, local: CGPoint) -> NSEvent {
        let windowPoint = view.convert(local, to: nil)
        return NSEvent.enterExitEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    private func mouseEvent(_ type: NSEvent.EventType, local: CGPoint) -> NSEvent {
        let windowPoint = view.convert(local, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // MARK: - Fast transit never thickens

    func test_fastPassThrough_neverThickens() {
        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        view.mouseMoved(with: mouseEvent(.mouseMoved, local: farInsidePoint(dx: 60)))
        view.mouseExited(with: enterExitEvent(.mouseExited, local: outsidePoint))

        XCTAssertFalse(view.isProgressHovering, "a fast pass through must never thicken the bar")
        XCTAssertEqual(view.hoverIntentState, .idle)

        // Wait past the (superseded) dwell + grace windows to prove no
        // stale timer sneaks a late commit in.
        spin(MicroInteractionFeel.Tokens.progressHoverIntentDwellDuration + MicroInteractionFeel.Tokens.progressHoverIntentExitGrace + 0.05)
        XCTAssertFalse(view.isProgressHovering, "no stale timer may thicken the bar after the pointer already left")
        XCTAssertEqual(view.hoverIntentState, .idle)
    }

    // MARK: - Slow entry commits after the dwell

    func test_slowEntryThenStop_thickensAfterDwell() {
        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        XCTAssertFalse(view.isProgressHovering, "must not thicken instantly on entry")

        spin(MicroInteractionFeel.Tokens.progressHoverIntentDwellDuration + 0.08)
        XCTAssertTrue(view.isProgressHovering, "a genuine pause must thicken the bar after the dwell")
        XCTAssertEqual(view.hoverIntentState, .committed)
    }

    func test_subToleranceJitter_stillThickensOnSchedule() {
        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        // 1pt nudge, well under the 4pt tolerance.
        view.mouseMoved(with: mouseEvent(.mouseMoved, local: CGPoint(x: insidePoint.x + 1, y: insidePoint.y)))

        spin(MicroInteractionFeel.Tokens.progressHoverIntentDwellDuration + 0.08)
        XCTAssertTrue(view.isProgressHovering, "tiny jitter must not block the commit")
    }

    // MARK: - Direct manipulation always wins immediately

    func test_mouseDown_thickensImmediately_withNoPriorHover() {
        XCTAssertEqual(view.hoverIntentState, .idle)
        view.mouseDown(with: mouseEvent(.leftMouseDown, local: insidePoint))
        XCTAssertTrue(view.isProgressHovering, "direct manipulation must never wait for the dwell")
        XCTAssertEqual(view.hoverIntentState, .committed)
    }

    func test_dragOutsideRegion_staysThick_ignoresExitedDuringDrag() {
        view.mouseDown(with: mouseEvent(.leftMouseDown, local: insidePoint))
        XCTAssertTrue(view.isProgressHovering)

        view.mouseDragged(with: mouseEvent(.leftMouseDragged, local: outsidePoint))
        XCTAssertTrue(view.isProgressHovering, "dragging outside the hit rect must not un-thicken mid-drag")

        // Even if the OS also delivers a tracking-area exit during the
        // drag, the existing isDraggingProgress guard must still hold.
        view.mouseExited(with: enterExitEvent(.mouseExited, local: outsidePoint))
        XCTAssertTrue(view.isProgressHovering, "an exited event received while dragging must be ignored")
        XCTAssertEqual(view.hoverIntentState, .committed)
    }

    // MARK: - Leaving the window resets immediately, regardless of arm

    func test_leavingWindow_resetsImmediately() {
        view.mouseDown(with: mouseEvent(.leftMouseDown, local: insidePoint))
        XCTAssertTrue(view.isProgressHovering)

        view.removeFromSuperview()

        XCTAssertFalse(view.isProgressHovering, "leaving the window must reset immediately, no grace")
        XCTAssertEqual(view.hoverIntentState, .idle)
        XCTAssertFalse(view.hasScheduledHoverIntentWork)
    }

    // MARK: - No residual timers/work items

    func test_noResidualWork_afterFastExit() {
        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        XCTAssertTrue(view.hasScheduledHoverIntentWork, "dwell timer should be armed while pending")

        view.mouseExited(with: enterExitEvent(.mouseExited, local: outsidePoint))
        XCTAssertFalse(view.hasScheduledHoverIntentWork, "exiting from pending must cancel the dwell timer immediately")
    }

    func test_noResidualWork_afterGraceElapses() {
        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        spin(MicroInteractionFeel.Tokens.progressHoverIntentDwellDuration + 0.05)
        XCTAssertTrue(view.isProgressHovering)
        XCTAssertFalse(view.hasScheduledHoverIntentWork, "no timer should be left armed once committed and settled")

        view.mouseExited(with: enterExitEvent(.mouseExited, local: outsidePoint))
        XCTAssertTrue(view.hasScheduledHoverIntentWork, "exit grace timer should be armed briefly")

        spin(MicroInteractionFeel.Tokens.progressHoverIntentExitGrace + 0.05)
        XCTAssertFalse(view.isProgressHovering)
        XCTAssertFalse(view.hasScheduledHoverIntentWork, "grace timer must be drained, nothing left scheduled")
    }

    // MARK: - Re-entry within the exit grace resumes without flicker

    func test_reEntryWithinGrace_resumesThickWithoutFlicker() {
        view.mouseDown(with: mouseEvent(.leftMouseDown, local: insidePoint))
        XCTAssertTrue(view.isProgressHovering)
        // mouseUp with the (synthetic) pointer still inside keeps it simple
        // and avoids depending on the live system pointer that
        // syncHoverStateToPointer() would otherwise consult.
        view.mouseUp(with: mouseEvent(.leftMouseUp, local: insidePoint))

        view.mouseExited(with: enterExitEvent(.mouseExited, local: outsidePoint))
        XCTAssertTrue(view.isProgressHovering, "exit grace must not un-thicken instantly")

        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        XCTAssertTrue(view.isProgressHovering, "re-entering within the grace window must resume with zero flicker")
        XCTAssertEqual(view.hoverIntentState, .committed)
    }

    // MARK: - Reduced motion does not bypass the intent gate

    func test_reducedMotion_doesNotBypassIntentGate() {
        view.prefersReducedMotion = true

        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        view.mouseExited(with: enterExitEvent(.mouseExited, local: outsidePoint))
        XCTAssertFalse(view.isProgressHovering, "reduced motion must not shortcut the dwell gate for a fast pass")

        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        spin(MicroInteractionFeel.Tokens.progressHoverIntentDwellDuration + 0.08)
        XCTAssertTrue(view.isProgressHovering, "reduced motion must still allow a genuine dwell to commit")
    }

    // MARK: - Legacy `.immediate` arm matches today's shipped behaviour

    func test_legacyImmediateArm_thickensInstantly_noDwell() {
        MicroInteractionFeel.testingProgressHoverIntent = .immediate
        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        XCTAssertTrue(view.isProgressHovering, "the legacy arm must thicken instantly, exactly like before this change")
    }

    func test_legacyImmediateArm_neverSchedulesWork() {
        MicroInteractionFeel.testingProgressHoverIntent = .immediate
        view.mouseEntered(with: enterExitEvent(.mouseEntered, local: insidePoint))
        XCTAssertFalse(view.hasScheduledHoverIntentWork, "legacy arm must never touch the hover-intent timer machinery")
        view.mouseExited(with: enterExitEvent(.mouseExited, local: outsidePoint))
        XCTAssertFalse(view.isProgressHovering)
        XCTAssertFalse(view.hasScheduledHoverIntentWork)
    }
}
