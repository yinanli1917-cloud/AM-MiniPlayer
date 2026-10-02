import XCTest
import AppKit
import Combine
@testable import MusicMiniPlayerCore

/// `LiquidEdgeController`'s onboarding-tour additions: `statePublisher`
/// (§6 "贴边状态") and the `tuckedRegionInScreen`/`floatingHitRegionInScreen`
/// screen-space rects (§4.2 item 2). Same fixture style as
/// `LiquidEdgeControllerTests` (fake clock, no display link).
@MainActor
final class LiquidEdgeControllerTourHooksTests: XCTestCase {
    private var now: CFTimeInterval = 1000
    private var card: SnappablePanel!
    private var controller: LiquidEdgeController!
    private var cancellables = Set<AnyCancellable>()

    private func makeCard(edge: SnappablePanel.Edge, top: Bool = true) throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let v = screen.visibleFrame
        let size = NSSize(width: 250, height: 316)
        let x = edge == .right ? v.maxX - size.width - 16 : v.minX + 16
        let y = top ? v.maxY - size.height - 16 : v.minY + 16
        card = SnappablePanel(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.level = .floating
        card.isOpaque = false
        card.hasShadow = true
        card.contentView = NSView()
        card.orderFront(nil)
        controller = LiquidEdgeController(card: card)
        controller.clock = { [unowned self] in self.now }
        controller.drivesFrames = false
        controller.reduceMotionOverride = false
    }

    override func tearDown() {
        cancellables.removeAll()
        controller?.reset()
        controller?.stageWindow?.orderOut(nil)
        card?.orderOut(nil)
        card = nil
        controller = nil
        super.tearDown()
    }

    @discardableResult
    private func settle(maxSeconds: Double = 3) -> Bool {
        var frames = 0
        while controller.isAnimating, frames < Int(maxSeconds * 120) {
            now += 1.0 / 120
            controller.tick(at: now)
            frames += 1
        }
        return !controller.isAnimating
    }

    /// `hoverEntered()`'s dwell timer is real `DispatchQueue.main.asyncAfter`
    /// (not on the injected fake clock) — same as `LiquidEdgeControllerTests`.
    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - statePublisher

    func test_statePublisher_currentValueSubject_repliesImmediatelyWithCurrentState() throws {
        try makeCard(edge: .right)
        var received: [LiquidEdgeState] = []
        controller.statePublisher.sink { received.append($0) }.store(in: &cancellables)
        XCTAssertEqual(received, [.card], "CurrentValueSubject: a fresh subscriber sees the current state immediately")
    }

    func test_statePublisher_emitsThroughCollapseSettleExpand() throws {
        try makeCard(edge: .right)
        var received: [LiquidEdgeState] = []
        controller.statePublisher.sink { received.append($0) }.store(in: &cancellables)

        XCTAssertTrue(controller.collapse(to: .right))
        XCTAssertTrue(settle())
        XCTAssertEqual(received, [.card, .collapsing, .tucked])

        controller.mouseLocation = { .zero }

        controller.hoverEntered()
        spin(0.35)
        XCTAssertTrue(settle())
        XCTAssertEqual(received, [.card, .collapsing, .tucked, .floating])

        controller.expand()
        XCTAssertTrue(settle())
        XCTAssertEqual(received, [.card, .collapsing, .tucked, .floating, .expanding, .card])
    }

    func test_statePublisher_doesNotEmit_forRepeatedIdenticalState() throws {
        try makeCard(edge: .right)
        var count = 0
        controller.statePublisher.dropFirst().sink { _ in count += 1 }.store(in: &cancellables)
        controller.reset() // already .card — must be a no-op, not a duplicate emission
        XCTAssertEqual(count, 0)
    }

    // MARK: - Screen-space rects

    func test_tuckedRegionInScreen_isZero_beforeAnyCollapse() throws {
        try makeCard(edge: .right)
        XCTAssertEqual(controller.tuckedRegionInScreen, .zero)
    }

    func test_tuckedRegionInScreen_afterCollapse_isNearThePanelsOriginalEdge() throws {
        try makeCard(edge: .right)
        XCTAssertTrue(controller.collapse(to: .right))
        XCTAssertTrue(settle())
        let region = controller.tuckedRegionInScreen
        XCTAssertGreaterThan(region.width, 0)
        XCTAssertGreaterThan(region.height, 0)
        // The sliver sits at the same screen edge the panel collapsed into.
        let screenMaxX = try XCTUnwrap(NSScreen.main).visibleFrame.maxX
        XCTAssertEqual(region.maxX, screenMaxX, accuracy: 40)
    }

    func test_floatingHitRegionInScreen_growsToIncludeCapsule_whileFloating() throws {
        try makeCard(edge: .right)
        XCTAssertTrue(controller.collapse(to: .right))
        XCTAssertTrue(settle())
        let tuckedRegion = controller.tuckedRegionInScreen

        controller.mouseLocation = { .zero }

        controller.hoverEntered()
        spin(0.35)
        XCTAssertTrue(settle())
        let floatingRegion = controller.floatingHitRegionInScreen
        XCTAssertGreaterThanOrEqual(floatingRegion.height, tuckedRegion.height, "the floating hit region must cover at least the sliver's own span")
    }

    func test_leftEdge_tuckedRegionInScreen_mirroredCorrectly() throws {
        try makeCard(edge: .left)
        XCTAssertTrue(controller.collapse(to: .left))
        XCTAssertTrue(settle())
        let region = controller.tuckedRegionInScreen
        let screenMinX = try XCTUnwrap(NSScreen.main).visibleFrame.minX
        XCTAssertEqual(region.minX, screenMinX, accuracy: 40)
    }
}
