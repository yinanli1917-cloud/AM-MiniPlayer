import XCTest
import AppKit
@testable import MusicMiniPlayerCore

/// Founder 2026-09-23: on the capsule, the pause button could not be pressed
/// — the panel expanded instead. Clicks are synthesized into the real stage
/// window at the buttons' centres; player commands are replaced so the test
/// never touches Music.
@MainActor
final class LiquidEdgeCapsuleInputTests: XCTestCase {
    private var window: LiquidEdgeStageWindow!
    private var stage: LiquidEdgeStageView!
    private var expands = 0, playPauses = 0, nexts = 0
    private let g = LiquidEdgeGeometry.reference

    override func setUp() {
        super.setUp()
        let screen = NSScreen.main!.visibleFrame
        window = LiquidEdgeStageWindow()
        window.setFrame(CGRect(x: screen.maxX - g.edgeX, y: screen.maxY - 360, width: g.edgeX, height: 360), display: false)
        stage = LiquidEdgeStageView(frame: CGRect(x: 0, y: 0, width: g.edgeX, height: 360))
        stage.geometry = g
        stage.activeHitRegionProvider = { [g] in LiquidEdgePoses(g).hitRegion(for: .floating) }
        stage.onTap = { [unowned self] in self.expands += 1; print("TAPSTACK", Thread.callStackSymbols.prefix(14).joined(separator: "\n")) }
        stage.playPauseOverride = { [unowned self] in self.playPauses += 1 }
        stage.nextOverride = { [unowned self] in self.nexts += 1 }
        window.contentView = stage
        window.orderFront(nil)
        stage.apply(LiquidEdgePoses(g).pose(.floating))
        stage.layoutSubtreeIfNeeded()
        spin(0.3)
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil; stage = nil
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Centre of the controls row, in stage (flipped) coordinates.
    private var controlsY: CGFloat {
        let t = LiquidEdgeTokens.self
        let c = LiquidEdgePoses(g).capsuleRect
        return c.minY + t.capsulePadding + t.capsuleArtwork + 8 + t.capsuleTextHeight + 4 + t.capsuleControlsHeight / 2
    }
    private var pauseCentre: CGPoint { CGPoint(x: LiquidEdgePoses(g).capsuleRect.midX - 25, y: controlsY) }
    private var nextCentre: CGPoint { CGPoint(x: LiquidEdgePoses(g).capsuleRect.midX + 23, y: controlsY) }

    private func click(_ p: CGPoint) {
        let inWindow = CGPoint(x: p.x, y: stage.bounds.height - p.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(e)
            spin(0.05)
        }
        spin(0.3)
    }

    func test_clickPause_pausesAndDoesNotExpand() {
        let inW = CGPoint(x: pauseCentre.x, y: stage.bounds.height - pauseCentre.y); let hv = window.contentView?.superview?.hitTest(inW); print("HIT", String(describing: hv), "idx", stage.subviews.firstIndex { $0 === hv } ?? -1, "subviews", stage.subviews.map { String(describing: type(of: $0)) })
        click(pauseCentre)
        XCTAssertEqual(expands, 0, "clicking pause expanded the panel")
        XCTAssertEqual(playPauses, 1, "pause did not receive the click")
    }

    func test_clickNext_skipsAndDoesNotExpand() {
        click(nextCentre)
        XCTAssertEqual(expands, 0, "clicking next expanded the panel")
        XCTAssertEqual(nexts, 1, "next did not receive the click")
    }

    func test_clickCover_expands() {
        click(CGPoint(x: LiquidEdgePoses(g).capsuleCoverRect.midX, y: LiquidEdgePoses(g).capsuleCoverRect.midY))
        XCTAssertEqual(expands, 1, "the cover is the capsule's expand target")
        XCTAssertEqual(playPauses + nexts, 0)
    }

    func test_clickTitle_doesNothing() {
        let t = LiquidEdgeTokens.self
        let c = LiquidEdgePoses(g).capsuleRect
        click(CGPoint(x: c.midX, y: c.minY + t.capsulePadding + t.capsuleArtwork + 8 + t.capsuleTextHeight / 2))
        XCTAssertEqual(expands, 0, "only the cover expands")
    }

    func test_tuckedSliverClick_expands() {
        stage.activeHitRegionProvider = { [g] in LiquidEdgePoses(g).hitRegion(for: .tucked) }
        stage.apply(LiquidEdgePoses(g).pose(.tucked))
        stage.refreshHitRegion()
        spin(0.2)
        let r = LiquidEdgePoses(g).tuckedRegion()
        click(CGPoint(x: r.maxX - 3, y: r.midY))
        XCTAssertEqual(expands, 1, "a click on the sliver expands")
    }

    /// Progress is only a glow whose lit length is the played part: no
    /// full-length track line, no knob.
    func test_tuckedProgress_isGlowOnly() {
        stage.apply(LiquidEdgePoses(g).pose(.tucked))
        let light = stage.debugProgressLight
        XCTAssertEqual(light.layerCount, 3, "halo, wide halo, soft core — nothing else")
        let first = light.strokeEnds.first ?? -1
        XCTAssertTrue(light.strokeEnds.allSatisfy { abs($0 - first) < 1e-6 }, "every glow stroke ends at the progress point")
    }

    func test_clickRingEdge_doesNotExpand() {
        // Inside the 30pt progress ring but outside the scaled pause button.
        click(CGPoint(x: pauseCentre.x + 13, y: pauseCentre.y))
        XCTAssertEqual(expands, 0, "a click on the pause ring expanded the panel")
    }
}
