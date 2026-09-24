import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerCore

/// The liquid edge on real windows: a SnappablePanel next to a screen edge,
/// frames stepped on a fake clock (no display link), checking what the two
/// windows do — the panel's alpha / mask / shadow / on-screen state and the
/// stage window — through collapse, hover out, hover back, and expand.
@MainActor
final class LiquidEdgeControllerTests: XCTestCase {
    private var now: CFTimeInterval = 1000
    private var card: SnappablePanel!
    private var controller: LiquidEdgeController!
    private var occluded: [Bool] = []

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
        controller.onPanelOccluded = { [unowned self] in self.occluded.append($0) }
    }

    override func tearDown() {
        controller?.reset()
        controller?.stageWindow?.orderOut(nil)
        card?.orderOut(nil)
        card = nil
        controller = nil
        super.tearDown()
    }

    /// Steps 120Hz frames until the motion settles; returns the panel mask
    /// rects seen (panel content coordinates).
    @discardableResult
    private func settle(maxSeconds: Double = 3) -> [CGRect] {
        var rects: [CGRect] = []
        var frames = 0
        while controller.isAnimating, frames < Int(maxSeconds * 120) {
            now += 1.0 / 120
            controller.tick(at: now)
            if let path = controller.panelMask.path { rects.append(path.boundingBox) }
            frames += 1
        }
        XCTAssertFalse(controller.isAnimating, "motion never settled")
        return rects
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func test_collapse_tucksPanelOffScreen_withStageBelowIt() throws {
        try makeCard(edge: .right)
        XCTAssertTrue(controller.collapse(to: .right))
        XCTAssertEqual(controller.state, .collapsing)
        XCTAssertFalse(card.hasShadow, "the panel's own shadow would outline the old card while the liquid shrinks")
        XCTAssertTrue(controller.stageWindow?.isVisible == true)
        XCTAssertFalse(controller.collapse(to: .right), "a second request while busy is refused")

        let rects = settle()
        XCTAssertEqual(controller.state, .tucked)
        XCTAssertFalse(card.isVisible, "tucked: the panel window is ordered out so its per-frame work stops")
        XCTAssertEqual(occluded.last, true)
        XCTAssertTrue(controller.stageWindow?.isVisible == true, "the sliver stays on screen")

        // Responds on contact: the first frame already narrows the panel.
        let first = try XCTUnwrap(rects.first)
        XCTAssertLessThan(first.width, 250 - 0.5)
        // Right edge: the liquid drains toward the right, so the visible
        // part's right side stays at the panel's right side.
        let bounds = card.contentView!.bounds
        for r in rects.prefix(12) where r.width > 1 {
            XCTAssertGreaterThan(r.maxX, bounds.width - 40, "right-edge collapse shrank toward the wrong side: \(r)")
        }
    }

    /// Founder 2026-09-23: the expanded shape did not match the real panel.
    /// At the default top corner the stage window reached 12pt under the
    /// menu bar, AppKit pushed it down, and every liquid shape was drawn
    /// 12pt below the panel. The liquid's card must sit exactly on the
    /// panel's frame, at every corner, on both edges.
    func test_liquidCard_coincidesWithPanelFrame_atEveryCorner() throws {
        for edge in [SnappablePanel.Edge.right, .left] {
            for top in [true, false] {
                try makeCard(edge: edge, top: top)
                XCTAssertTrue(controller.collapse(to: edge))
                let stage = try XCTUnwrap(controller.stageWindow).frame
                var c = controller.geometry.card
                if edge == .left { c.origin.x = stage.width - c.maxX }
                let onScreen = CGRect(x: stage.minX + c.minX, y: stage.maxY - c.maxY, width: c.width, height: c.height)
                XCTAssertEqual(onScreen.minX, card.frame.minX, accuracy: 0.01, "\(edge) top=\(top)")
                XCTAssertEqual(onScreen.minY, card.frame.minY, accuracy: 0.01, "\(edge) top=\(top): liquid drawn off the panel vertically")
                XCTAssertEqual(onScreen.size, card.frame.size, "\(edge) top=\(top)")
                tearDown()
                occluded = []
            }
        }
    }

    /// Founder 2026-09-23 (recording Screen-2026-09-23-171622): the liquid
    /// expanded to a shape that was not the panel. The panel window is now
    /// exactly the panel (PanelWindowMetrics); the title bar still reports a
    /// 32pt AppKit safe area over it, which the panel draws under. The
    /// liquid must land on the window = the drawn panel, not the safe area.
    func test_liquidCard_coincidesWithDrawnPanel_inAppWindow() throws {
        try makeCard(edge: .right)
        let frame = card.frame
        card.orderOut(nil)
        card = SnappablePanel(contentRect: NSRect(origin: frame.origin, size: PanelWindowMetrics.defaultSize),
                              styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        card.titlebarAppearsTransparent = true
        card.titleVisibility = .hidden
        card.isOpaque = false
        card.backgroundColor = .clear
        card.contentView = PanelWindowMetrics.makeContentView(root: Color.red)
        card.orderFront(nil)
        controller = LiquidEdgeController(card: card)
        controller.clock = { [unowned self] in self.now }
        controller.drivesFrames = false
        controller.reduceMotionOverride = false

        let content = try XCTUnwrap(card.contentView)
        XCTAssertLessThan(content.safeAreaRect.height, content.bounds.height,
                          "precondition: the title bar still reports a safe area the panel draws under")

        XCTAssertTrue(controller.collapse(to: .right))
        let stage = try XCTUnwrap(controller.stageWindow).frame
        let c = controller.geometry.card
        let onScreen = CGRect(x: stage.minX + c.minX, y: stage.maxY - c.maxY, width: c.width, height: c.height)
        XCTAssertEqual(onScreen, card.frame, "the liquid's card must be the panel = the window")

        // The expand ends exactly on it: the last mask is the whole panel.
        settle()
        controller.expand()
        var last = CGRect.zero
        while controller.isAnimating {
            now += 1.0 / 120
            controller.tick(at: now)
            if let p = controller.panelMask.path { last = p.boundingBox }
        }
        XCTAssertEqual(last, content.bounds)
    }

    func test_leftEdge_isMirrored() throws {
        try makeCard(edge: .left)
        XCTAssertTrue(controller.collapse(to: .left))
        let rects = settle()
        XCTAssertEqual(controller.state, .tucked)
        for r in rects.prefix(12) where r.width > 1 {
            XCTAssertLessThan(r.minX, 40, "left-edge collapse shrank toward the wrong side: \(r)")
        }
        let stage = try XCTUnwrap(controller.stageWindow)
        XCTAssertLessThanOrEqual(stage.frame.minX, card.frame.minX, "the stage reaches the left screen edge")
    }

    func test_hover_floatsCapsule_prewarmsPanel_thenRetractsAndParks() throws {
        try makeCard(edge: .right)
        controller.collapse(to: .right)
        settle()

        controller.hoverEntered()
        XCTAssertEqual(controller.state, .tucked, "hover must dwell before floating out")
        spin(0.2)
        XCTAssertEqual(controller.state, .floating)
        settle()
        XCTAssertTrue(card.isVisible, "capsule resting: the panel is back on-window, ready to expand")
        XCTAssertEqual(card.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(card.ignoresMouseEvents, "the invisible panel must not catch clicks")

        // Resting on the capsule keeps the capsule (founder 2026-09-23).
        controller.hoverEntered()
        spin(0.3)
        XCTAssertEqual(controller.state, .floating, "hovering the capsule must not expand it")
        XCTAssertFalse(controller.isAnimating)

        controller.hoverExited()
        settle()
        XCTAssertEqual(controller.state, .tucked)
        XCTAssertFalse(card.isVisible)
    }

    func test_expand_restoresThePanelExactly() throws {
        try makeCard(edge: .right)
        let frame = card.frame
        controller.collapse(to: .right)
        settle()
        controller.hoverEntered()
        spin(0.2)
        settle()

        controller.expand()
        XCTAssertEqual(controller.state, .expanding)
        settle()
        XCTAssertEqual(controller.state, .card)
        XCTAssertTrue(card.isVisible)
        XCTAssertEqual(card.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(card.contentView?.layer?.mask)
        XCTAssertTrue(card.hasShadow)
        XCTAssertFalse(card.ignoresMouseEvents)
        XCTAssertEqual(card.frame, frame, "the panel never moves")
        XCTAssertFalse(controller.stageWindow?.isVisible ?? false)
        XCTAssertEqual(occluded.last, false)
    }

    func test_expandFromTucked_directly() throws {
        try makeCard(edge: .right)
        controller.collapse(to: .right)
        settle()
        controller.expand()
        XCTAssertTrue(card.isVisible, "expanding orders the panel in at once")
        settle()
        XCTAssertEqual(controller.state, .card)
        XCTAssertEqual(card.alphaValue, 1, accuracy: 0.001)
    }

    func test_reset_midCollapse_restoresPanel() throws {
        try makeCard(edge: .right)
        controller.collapse(to: .right)
        for _ in 0..<10 { now += 1.0 / 120; controller.tick(at: now) }
        controller.reset()
        XCTAssertEqual(controller.state, .card)
        XCTAssertTrue(card.isVisible)
        XCTAssertEqual(card.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(card.contentView?.layer?.mask)
        XCTAssertFalse(controller.stageWindow?.isVisible ?? false)
    }

    func test_trackChange_peeksOnlyWhenTuckedAndEnabled() throws {
        let key = LiquidEdgeController.autoPeekDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        try makeCard(edge: .right)

        controller.trackChanged()
        XCTAssertEqual(controller.state, .card, "no peek while the panel is out")

        controller.collapse(to: .right)
        settle()
        UserDefaults.standard.set(false, forKey: key)
        controller.trackChanged()
        XCTAssertEqual(controller.state, .tucked, "setting off: no peek")

        UserDefaults.standard.removeObject(forKey: key)
        controller.trackChanged()
        XCTAssertEqual(controller.state, .floating, "default on: peek")
    }

    func test_reduceMotion_snaps() throws {
        try makeCard(edge: .right)
        controller.reduceMotionOverride = true
        controller.collapse(to: .right)
        XCTAssertEqual(controller.state, .tucked)
        XCTAssertFalse(controller.isAnimating)
        XCTAssertFalse(card.isVisible)
        controller.expand()
        XCTAssertEqual(controller.state, .card)
        XCTAssertTrue(card.isVisible)
    }
}
