import XCTest
import AppKit
@testable import MusicMiniPlayerCore

/// `SnappablePanel`'s onboarding-tour additions: `onSnappedToCorner` fires
/// only on a real corner-snap settle (never edge-hide/peek/restore),
/// `tuckableEdge()`/`currentCorner()` read the panel's current geometry.
@MainActor
final class SnappablePanelCornerHookTests: XCTestCase {
    private var panel: SnappablePanel!

    private func makePanel(at origin: NSPoint, size: NSSize = NSSize(width: 250, height: 284)) {
        panel = SnappablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.reduceMotionProvider = { true } // deterministic: settle happens synchronously
        panel.contentView = NSView()
        panel.orderFront(nil)
    }

    override func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        super.tearDown()
    }

    /// `snapToNearestCorner()`/`revealAtNearbySnapPosition()` don't consult
    /// `reduceMotionProvider` (they always spring, async via CADisplayLink) —
    /// `moveToEdgeCorner(_:completion:)` DOES, and its target IS one of the
    /// four exact corner points, so it's the deterministic way to exercise
    /// the settle → `onSnappedToCorner` path synchronously in a test.
    func test_moveToEdgeCorner_settlesSynchronously_firesOnSnappedToCorner() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        makePanel(at: NSPoint(x: visible.midX, y: visible.midY))

        var firedCorner: ScreenCorner?
        panel.onSnappedToCorner = { _, corner in firedCorner = corner }
        var completed = false
        panel.moveToEdgeCorner(.right) { completed = true }

        XCTAssertTrue(completed, "reduceMotion must settle synchronously")
        XCTAssertNotNil(firedCorner)
    }

    func test_hideToEdge_doesNotFireOnSnappedToCorner() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        // Start already in the top-right corner, well inside the panel's own
        // edge-hide gesture target — `hideToNearestEdge()` slides it further
        // right, off a real corner point.
        makePanel(at: NSPoint(x: visible.maxX - 250 - 16, y: visible.maxY - 284 - 16))

        var fired = false
        panel.onSnappedToCorner = { _, _ in fired = true }
        panel.hideToNearestEdge()

        XCTAssertFalse(fired, "edge-hide must never be mistaken for a corner-snap")
    }

    func test_currentCorner_matchesAfterSnap() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        makePanel(at: NSPoint(x: visible.minX + 5, y: visible.minY + 5)) // bottom half -> bottom-left
        panel.moveToEdgeCorner(.left) { }
        XCTAssertEqual(panel.currentCorner(), .bottomLeft)
    }

    func test_currentCorner_nilWhenNotInACorner() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        makePanel(at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
        XCTAssertNil(panel.currentCorner())
    }

    func test_tuckableEdge_nilAwayFromEdges() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        makePanel(at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
        XCTAssertNil(panel.tuckableEdge())
    }

    func test_tuckableEdge_rightNearRightEdge() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        makePanel(at: NSPoint(x: visible.maxX - 250, y: visible.midY))
        XCTAssertEqual(panel.tuckableEdge(), .right)
    }
}
