import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// End to end, in a REAL window stack: the real `TourController`, a real
/// `SnappablePanel` hosting the real `MiniPlayerView`, real `TourCardWindow`
/// content snapshotted with `cacheDisplay` — no fake views. A user finishes
/// step 2 ("hover + press play") and we watch the pixels the card window
/// actually draws.
///
/// `cacheDisplay` cannot draw real Liquid Glass (it paints a placeholder
/// block), so the flow swaps the card's material for the `simulated` fill via
/// the store; everything else — window, hosting view, controller, feedback
/// timer — is the shipping path.
@MainActor
final class TourCompletionFlowTests: XCTestCase {
    private var panel: SnappablePanel!
    private var liquidEdge: LiquidEdgeController!
    private var controller: TourController!
    private var savedShowTranslation = false
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TourCompletionFlowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        TourAnchorRegistry.shared.reset()
        savedShowTranslation = LyricsService.shared.showTranslation
        LyricsService.shared.showTranslation = false

        let visible = NSScreen.main!.visibleFrame
        let size = PanelWindowMetrics.defaultSize
        let origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        panel = SnappablePanel(contentRect: NSRect(origin: origin, size: size), styleMask: PanelWindowMetrics.styleMask, backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let root = MiniPlayerView().environmentObject(MusicController.shared).environmentObject(EdgePresentationModel())
        panel.contentView = PanelWindowMetrics.makeContentView(root: root)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
        spin(0.5)
        liquidEdge = LiquidEdgeController(card: panel)
        controller = TourController(panel: panel, liquidEdge: liquidEdge, defaults: defaults)
    }

    override func tearDown() {
        controller.send(.stopTour)
        controller = nil
        liquidEdge = nil
        panel?.orderOut(nil)
        panel = nil
        defaults.removePersistentDomain(forName: suiteName)
        TourAnchorRegistry.shared.reset()
        LyricsService.shared.showTranslation = savedShowTranslation
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private var cardWindow: NSWindow? { NSApp.windows.first { $0 is TourCardWindow && $0.isVisible } }

    /// Solid-pink pixels in the card's top-right 64x64pt (title row + ring).
    private func ringRegionAccentCount() -> Int {
        guard let view = cardWindow?.contentView else { return -1 }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var count = 0
        let x0 = Int((view.bounds.width - 64) * scale)
        for y in 0..<Int(64 * scale) { for x in x0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
            if c.alphaComponent > 0.8, r > 215, r - g > 120, r - b > 90 { count += 1 }
        } }
        return count
    }

    /// Root cause #1 of "no feedback at all": each state change used to build
    /// a brand-new NSHostingController, so the ring and dots were born in
    /// their final state and nothing could animate. The window's content view
    /// must survive a step completion (and the step change that follows).
    func test_cardContentView_isTheSameInstance_acrossACompletionAndTheNextStep() {
        controller.send(.resume(completed: [.connect]))
        spin(0.3)
        let host = cardWindow?.contentView
        XCTAssertNotNil(host)
        controller.send(.signal(.controlsRevealed))
        spin(0.05)
        XCTAssertTrue(cardWindow?.contentView === host, "a beat completing must update the card in place")
        controller.send(.signal(.isPlaying))
        spin(0.05)
        XCTAssertTrue(cardWindow?.contentView === host, "a step completing must update the card in place")
        spin(TourMotionPolicy.Tokens.stepCompletionFeedback + 0.25)
        XCTAssertTrue(cardWindow?.contentView === host, "and the next step's card reuses the same hosting view")
    }

    func test_finishingAStep_animatesTheRing_inTheRealCardWindow() throws {
        controller.send(.resume(completed: [.connect]))
        spin(0.4)
        XCTAssertNotNil(cardWindow, "the reveal card must be on screen")
        controller.debugCardStore?.arm = .simulated
        spin(0.1)
        let before = ringRegionAccentCount()
        XCTAssertGreaterThan(before, 0, "fixture sanity: the ring (1/7) is drawn in the card")

        controller.send(.signal(.controlsRevealed))
        controller.send(.signal(.isPlaying))   // step 2 complete -> ring 1/7 -> 2/7
        XCTAssertEqual(controller.state.completedSteps.count, 2)

        // Sample the real window while the feedback plays.
        var series: [Int] = []
        let start = Date()
        for dt in [0.03, 0.10, 0.18, 0.26, 0.36, 0.50, 0.70] {
            spin(max(0, dt - Date().timeIntervalSince(start)))
            series.append(ringRegionAccentCount())
        }
        let distinct = Set(series.filter { $0 >= 0 }).count
        XCTAssertGreaterThanOrEqual(distinct, 4, "the ring must grow over time (samples: \(series)), not jump once")
        let last = try XCTUnwrap(series.last)
        XCTAssertGreaterThan(last, before, "and end longer than it started (\(before) -> \(last))")
    }
}
