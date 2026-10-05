/**
 * [INPUT]: MusicMiniPlayerAppKit's TourController/TourCardWindow/TourCardStore, TourWindowCapture, TourRenderSupport.
 * [OUTPUT]: TourCardWindowTests (window fits its content, refits on change, transparent outside the bubble, glass + vibrancy arms).
 * [POS]: Tests. The real-window gate the ImageRenderer-only tour tests could not be.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// Founder 2026-09-29 (real Mac): the tour card was a hard-edged rectangle,
/// its bottom links cut in half, the ring's top shaved off, the beak floating
/// beside the body. Every earlier check rendered `TourCardView` alone
/// (ImageRenderer), so nothing ever looked at the WINDOW: its size, its
/// clipping, its transparency. These tests build the REAL `TourCardWindow`
/// through the real controller and ask WindowServer for its pixels.
///
/// Root cause pinned here: `TourHostingView` set `sizingOptions = []`, which
/// makes `fittingSize` return (0, 0); `measureCardSize` then silently fell
/// back to a 150pt height for EVERY card. A 171pt card in a 150pt window is
/// centered and clipped top and bottom: no top corners, no bottom links, a
/// sliced ring.
@MainActor
final class TourCardWindowTests: XCTestCase {
    private var panel: SnappablePanel!
    private var liquidEdge: LiquidEdgeController!
    private var controller: TourController!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let music = MusicController.shared

    override func setUp() {
        super.setUp()
        suiteName = "TourCardWindowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        TourAnchorRegistry.shared.reset()

        let visible = NSScreen.main!.visibleFrame
        let size = PanelWindowMetrics.defaultSize
        let origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        panel = SnappablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: PanelWindowMetrics.styleMask, backing: .buffered, defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let root = MiniPlayerView().environmentObject(music).environmentObject(EdgePresentationModel())
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
        TourAnchorRegistry.shared.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func cardWindow() throws -> TourCardWindow {
        try XCTUnwrap(NSApp.windows.first { $0 is TourCardWindow && $0.isVisible } as? TourCardWindow)
    }

    /// What the card's content needs at the window's width, measured on a
    /// fresh default hosting view (independent of the code under test).
    private func neededSize(_ store: TourCardStore, width: CGFloat) -> CGSize {
        // A STATIC card (no guidance frame): its natural height, not the animated one.
        let ref = NSHostingView(rootView: TourCardView(
            model: store.model, beakSide: store.beakSide, beakOffset: store.beakOffset, gestureKind: store.gestureKind,
            arm: store.arm, feedback: store.feedback, onPrimary: {}, onSecondary: {}, onStop: {}, onSkipStep: {}, onFallback: {}))
        ref.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        return ref.fittingSize
    }

    // MARK: - Size

    func test_windowIsAsTallAsTheCardNeeds_S1() throws {
        controller.send(.resume(completed: [.connect]))
        spin(0.4)
        let window = try cardWindow()
        let store = try XCTUnwrap(controller.debugCardStore)
        let need = neededSize(store, width: window.frame.width)
        XCTAssertGreaterThan(need.height, 100, "sanity: the reference measurement works")
        XCTAssertGreaterThanOrEqual(window.contentView!.bounds.height, need.height - 0.5,
                                    "window \(window.frame.size) is shorter than its content \(need): the content is clipped")
        XCTAssertGreaterThanOrEqual(window.contentView!.bounds.width, need.width - 0.5)
        // The hosting view itself must be able to say how big its content is.
        let own = window.contentView!.fittingSize
        XCTAssertEqual(own.height, need.height, accuracy: 0.5, "the card's hosting view must report its content size")
    }

    func test_windowRefitsWhenTheCardContentChanges() throws {
        controller.send(.resume(completed: [.connect]))
        spin(0.4)
        let window = try cardWindow()
        let store = try XCTUnwrap(controller.debugCardStore)
        let before = window.frame
        // A taller card lands in the store WITHOUT the controller re-placing
        // it (font/copy/state changed under a live window).
        store.gestureKind = .nudgeToCorner()
        store.model = TourSceneFixtures.move(.en)
        store.contentKey += 1
        spin(1.0)   // the height springs (0.4 s) to the new content
        let need = neededSize(store, width: window.frame.width)
        XCTAssertGreaterThan(need.height, before.height + 20, "sanity: the new card really is taller")
        XCTAssertGreaterThanOrEqual(window.frame.height, need.height - 0.5, "the window must be re-measured for the new content")
        XCTAssertEqual(window.frame.maxY, before.maxY, accuracy: 0.5, "a refit keeps the card's top edge (the beak offset is measured from it)")
    }

    // MARK: - Pixels of the real window

    func test_pixelsOutsideTheBubbleAreTransparent_glass() throws {
        controller.send(.resume(completed: [.connect]))
        spin(0.6)
        try assertOutsideBubbleTransparent(arm: .glass)
    }

    func test_pixelsOutsideTheBubbleAreTransparent_liquid() throws {
        controller.send(.resume(completed: [.connect]))
        spin(0.6)
        try assertOutsideBubbleTransparent(arm: nil)   // liquid is the shipping default
    }

    func test_pixelsOutsideTheBubbleAreTransparent_vibrancy() throws {
        controller.send(.resume(completed: [.connect]))
        spin(0.3)
        try assertOutsideBubbleTransparent(arm: .vibrancy)
    }

    private func assertOutsideBubbleTransparent(arm: TourCardMaterialArm?) throws {
        let window = try cardWindow()
        let store = try XCTUnwrap(controller.debugCardStore)
        if let arm { store.arm = arm; spin(0.5) }
        let image = try XCTUnwrap(TourWindowCapture.image(of: window), "WindowServer gave no image for the card window")
        let scale = CGFloat(image.width) / window.frame.width
        let px = TourRender.pixels(from: image, scale: scale)
        let size = window.frame.size
        let shape = TourBubbleShape(beakSide: store.beakSide, beakOffset: store.beakOffset)
        let rect = CGRect(origin: .zero, size: size)
        let body = shape.bodyRect(in: rect)
        func a(_ p: CGPoint) -> UInt8 { px.rgba(atPoint: p).a }

        // The four corners of the window's box are outside a rounded body
        // (radius 14) — and, on the beak side, outside the triangle too.
        let inset: CGFloat = 1.5
        for corner in [CGPoint(x: body.minX + inset, y: body.minY + inset), CGPoint(x: body.maxX - inset, y: body.minY + inset),
                       CGPoint(x: body.minX + inset, y: body.maxY - inset), CGPoint(x: body.maxX - inset, y: body.maxY - inset)] {
            XCTAssertEqual(a(corner), 0, "\(corner) is outside the rounded body but has alpha \(a(corner)) (arm \(String(describing: arm)))")
        }
        // The beak's box corners away from the tip are outside the triangle.
        let tip = shape.beakTip(in: rect)
        switch store.beakSide {
        case .left, .right:
            let x = store.beakSide == .right ? size.width - inset : inset
            XCTAssertEqual(a(CGPoint(x: x, y: tip.y - 9)), 0, "beak box above the tip must be empty")
            XCTAssertEqual(a(CGPoint(x: x, y: tip.y + 9)), 0, "beak box below the tip must be empty")
        default: break
        }
        // And the bubble itself is really there: body centre, and the beak's root.
        XCTAssertGreaterThan(a(CGPoint(x: body.midX, y: body.midY)), 100, "the body must be drawn")
        let root = CGPoint(x: store.beakSide == .right ? body.maxX + 2 : body.minX - 2, y: tip.y)
        XCTAssertGreaterThan(a(root), 60, "the beak must be filled where it meets the body (one shape)")
    }
}
