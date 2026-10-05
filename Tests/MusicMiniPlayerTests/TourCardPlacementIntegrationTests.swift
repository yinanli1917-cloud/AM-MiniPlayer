import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// Founder 2026-09-29: on a real Mac the card sat in the screen's lower-left
/// corner, far from the panel in the upper right, and its arrow pointed at
/// nothing. Root cause: `TourAnchorKey` publishes SwiftUI `.global` rects
/// (top-left origin, hosting-view space) but `TourPlacement` computes in
/// AppKit screen space (bottom-left origin). These tests host the REAL
/// `MiniPlayerView` inside a real `SnappablePanel` (PanelWindowMetrics'
/// content view, the 32pt-taller hosting view) in the screen's top-right
/// corner and check where the controller actually puts its windows.
@MainActor
final class TourCardPlacementIntegrationTests: XCTestCase {
    private var panel: SnappablePanel!
    private var liquidEdge: LiquidEdgeController!
    private var controller: TourController!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let music = MusicController.shared

    override func setUp() {
        super.setUp()
        suiteName = "TourCardPlacementIntegrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        TourAnchorRegistry.shared.reset()
        music.currentPage = .album

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
        spin(0.6)

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

    /// The panel's own layout (PlayPauseControlButton 30pt, 16pt above the
    /// panel's bottom, centered — storyboard `anchorsFor`), in screen space.
    private var expectedPlayCenter: CGPoint {
        CGPoint(x: panel.frame.midX, y: panel.frame.minY + 16 + 15)
    }

    func test_anchorRegistryRect_isTheControlInsideThePanelOnScreen() throws {
        controller.send(.resume(completed: [.connect]))
        spin(0.2)
        let anchor = try XCTUnwrap(controller.debugLastAnchorRect, "reveal step must resolve an anchor rect")
        XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: anchor.midX, y: anchor.midY)),
                      "anchor \(anchor) must be inside the panel \(panel.frame) in SCREEN coordinates")
        XCTAssertEqual(anchor.midX, expectedPlayCenter.x, accuracy: 3)
        // Tight on purpose: the anchor used to read 32pt too high (safe area)
        // while the panel was hovered and, unhovered, 30pt too low (the hide
        // offset) — the two nearly cancelled at rest, so a 6pt tolerance let
        // both bugs through.
        XCTAssertEqual(anchor.midY, expectedPlayCenter.y, accuracy: 3)
    }

    func test_revealCard_sitsBesideThePanelWithinSixteenPoints_andOnScreen() throws {
        controller.send(.resume(completed: [.connect]))
        spin(1.0)   // settled: the card's window frame is whole points (TourGuidance.wholePointFrame), mid-spring it is still travelling
        let card = try XCTUnwrap(controller.debugCardFrame)
        let visible = NSScreen.main!.visibleFrame
        XCTAssertTrue(visible.contains(card), "card \(card) must be fully on screen \(visible)")
        // Panel is in the top-right corner: the card is on its LEFT, gap 16.
        XCTAssertEqual(panel.frame.minX - card.maxX, TourPlacement.panelGap, accuracy: 0.5)
        // The beak tip points at the play button's row, not the card's far side.
        let placement = try XCTUnwrap(controller.debugLastPlacement)
        XCTAssertEqual(placement.beakSide, .right)
        let tipY = card.minY + placement.beakOffset
        XCTAssertEqual(tipY, expectedPlayCenter.y, accuracy: 6, "beak must point at the play button row")
    }

    func test_haloCentersOnTheAnchoredControl() throws {
        controller.send(.resume(completed: [.connect]))
        spin(1.0)
        let halo = try XCTUnwrap(controller.debugHaloFrame, "reveal step draws a halo")
        XCTAssertEqual(halo.midX, expectedPlayCenter.x, accuracy: 6)
        XCTAssertEqual(halo.midY, expectedPlayCenter.y, accuracy: 6)
    }

    /// The corner buttons only exist while the panel is hovered, and their
    /// rects are remembered from the last hover (step 1 makes the user hover
    /// first). If the card gets there without a hover, it must fall back to
    /// sitting beside the panel edge — on screen, 16pt away, no crash.
    func test_cornersStep_withoutAHoverYet_fallsBackToThePanelEdge() throws {
        controller.send(.resume(completed: [.connect, .reveal]))
        spin(0.3)
        let card = try XCTUnwrap(controller.debugCardFrame)
        XCTAssertTrue(NSScreen.main!.visibleFrame.contains(card))
        XCTAssertEqual(panel.frame.minX - card.maxX, TourPlacement.panelGap, accuracy: 0.5)
    }

    func test_lyricsStep_anchorsToTheLyricsButton_bottomLeftOfThePanel() throws {
        controller.send(.resume(completed: [.connect, .reveal, .corners]))
        spin(1.0)
        let anchor = try XCTUnwrap(controller.debugLastAnchorRect)
        XCTAssertEqual(anchor.midX, panel.frame.minX + 25, accuracy: 10)
        XCTAssertEqual(anchor.midY, panel.frame.minY + 31, accuracy: 10)
        let halo = try XCTUnwrap(controller.debugHaloFrame)
        XCTAssertEqual(halo.midX, anchor.midX, accuracy: 1)
        XCTAssertEqual(halo.midY, anchor.midY, accuracy: 1)
    }

    // MARK: - Material (what the card window really contains)

    private func classNames(of layer: CALayer, into out: inout [String]) {
        out.append(String(describing: type(of: layer)))
        (layer.sublayers ?? []).forEach { classNames(of: $0, into: &out) }
    }

    private func allClassNames(_ window: NSWindow) -> [String] {
        var names: [String] = []
        func walk(_ v: NSView) {
            names.append(String(describing: type(of: v)))
            if let l = v.layer { classNames(of: l, into: &names) }
            v.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return names
    }

    /// Offscreen capture cannot show Liquid Glass, so this pins the material
    /// arm by what the shipping card window actually instantiates: the glass
    /// arm mounts SwiftUI glass, the vibrancy arm an NSVisualEffectView, and
    /// no arm mounts both (glass-on-glass over-exposes, banned-patterns).
    func test_cardWindow_mountsExactlyOneMaterial_perArm() throws {
        controller.send(.resume(completed: [.connect]))
        spin(0.3)
        let window = try XCTUnwrap(NSApp.windows.first { $0 is TourCardWindow && $0.isVisible })
        let store = try XCTUnwrap(controller.debugCardStore)
        XCTAssertEqual(store.arm, .glass, "default arm is glass")
        let glassNames = allClassNames(window)
        print("[material] glass arm classes: \(Set(glassNames).sorted())")
        // Liquid Glass renders through signed-distance-field layers
        // (CASDFLayer / SDFPortalLayer / CASDFElementLayer) over a CABackdropLayer;
        // observed on macOS 26 via the layer census above.
        let sdfCount = glassNames.filter { $0.contains("SDF") }.count
        let vfx = glassNames.filter { $0.contains("VisualEffect") || $0.contains("TourVibrancy") }.count
        if #available(macOS 26.0, *) {
            XCTAssertGreaterThan(sdfCount, 0, "glass arm on macOS 26 must mount Liquid Glass (SDF layers)")
            XCTAssertEqual(vfx, 0, "and no NSVisualEffectView under it")
        }
        store.arm = .vibrancy
        spin(0.3)
        let vibNames = allClassNames(window)
        print("[material] vibrancy arm classes: \(Set(vibNames).sorted())")
        XCTAssertGreaterThan(vibNames.filter { $0.contains("TourVibrancy") }.count, 0, "vibrancy arm mounts the popover-material view")
        XCTAssertEqual(vibNames.filter { $0.contains("SDF") }.count, 0, "and no glass")
    }
}
