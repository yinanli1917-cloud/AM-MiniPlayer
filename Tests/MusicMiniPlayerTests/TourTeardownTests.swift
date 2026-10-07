import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// §11.1 TourTeardownTests / §11.2: once the tour stops or finishes, its
/// three overlay windows must be fully released (not just hidden) and no
/// timer left pending — the ONLY thing allowed to survive is the translation
/// tip's watcher, and only when a tour that ran has not already taught translation.
/// Drives `TourController` directly via `send(_:)` (an internal test seam),
/// bypassing real button clicks — the reducer's own transition table is
/// TourMachineTests' job; this file is only about what the AppKit layer does
/// with windows once the reducer tells it to.
@MainActor
final class TourTeardownTests: XCTestCase {
    private var panel: SnappablePanel!
    private var liquidEdge: LiquidEdgeController!
    private var controller: TourController!
    private var savedShowTranslation = false

    override func setUp() {
        super.setUp()
        TourPersistence.reset()
        // `TourController.init()` wires `LyricsService.$showTranslation` —
        // pin it to false here so that real, cross-test-shared singleton
        // state can't change what the tour does. Restored in tearDown.
        savedShowTranslation = LyricsService.shared.showTranslation
        LyricsService.shared.showTranslation = false

        let visible = NSScreen.main!.visibleFrame
        panel = SnappablePanel(
            contentRect: NSRect(x: visible.midX, y: visible.midY, width: 250, height: 284),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentView = NSView()
        panel.orderFront(nil)
        liquidEdge = LiquidEdgeController(card: panel)
        controller = TourController(panel: panel, liquidEdge: liquidEdge)
    }

    override func tearDown() {
        controller.send(.stopTour) // best-effort cleanup even if a test failed mid-way
        controller = nil
        liquidEdge = nil
        panel?.orderOut(nil)
        panel = nil
        TourPersistence.reset()
        LyricsService.shared.showTranslation = savedShowTranslation
        super.tearDown()
    }

    func test_start_allocatesACardWindow() {
        XCTAssertEqual(controller.debugAllocatedWindowCount, 0)
        controller.send(.start)
        XCTAssertGreaterThan(controller.debugAllocatedWindowCount, 0)
    }

    func test_stopTour_fromMidStep_releasesAllWindowsAndTimers() {
        controller.send(.start)
        controller.send(.signal(.controlsRevealed))
        XCTAssertGreaterThan(controller.debugAllocatedWindowCount, 0)

        controller.send(.stopTour)

        XCTAssertEqual(controller.debugAllocatedWindowCount, 0)
        XCTAssertFalse(controller.debugHasPendingTimers)
        XCTAssertTrue(controller.debugIsDeferredWatcherArmed, "the tour ran: the one watcher of the translation tip is armed")
    }

    /// The one exception (§3.3 S4L, §5.2 `idle(deferredArmed: true)`): a finished tour leaves exactly the translation
    /// tip's watcher subscription armed — windows and timers are still fully released.
    func test_finaleDismiss_leavesOnlyTheTipWatcherArmed() {
        controller.send(.resume(completed: Set(TourStep.orderedSteps)))
        XCTAssertEqual(controller.state.phase, .finale)
        XCTAssertGreaterThan(controller.debugAllocatedWindowCount, 0, "the finale card must be showing")

        controller.send(.finaleDismiss)

        XCTAssertEqual(controller.debugAllocatedWindowCount, 0)
        XCTAssertFalse(controller.debugHasPendingTimers)
        XCTAssertTrue(controller.debugIsDeferredWatcherArmed)
    }

    func test_finaleDismiss_translationAlreadyTurnedOn_leavesNothingRunning() {
        controller.send(.resume(completed: Set(TourStep.orderedSteps)))
        controller.send(.signal(.translationEnabled))   // the user got there on their own
        controller.send(.finaleDismiss)

        XCTAssertEqual(controller.debugAllocatedWindowCount, 0)
        XCTAssertFalse(controller.debugHasPendingTimers)
        XCTAssertFalse(controller.debugIsDeferredWatcherArmed, "nothing left to teach: nothing left running at all")
    }

    /// A second `stopTour` (or any further event) after teardown must not
    /// resurrect a window — the reducer only re-enters `.step`/`.transitioning`
    /// from `start`/`resume`/`advanceTransition`, none of which `stopTour` or
    /// an already-idle state can reach.
    func test_teardownIsIdempotent_furtherStopEventsAllocateNothing() {
        controller.send(.start)
        controller.send(.stopTour)
        XCTAssertEqual(controller.debugAllocatedWindowCount, 0)
        controller.send(.stopTour)
        XCTAssertEqual(controller.debugAllocatedWindowCount, 0)
    }
}
