import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Defect-5 instrument: whole-window animation census.
//
// A paused, static panel keeps billing WindowServer (+18 on a virgin panel with zero
// app-side commits). Zero commits means the driver was committed EARLIER and lives on
// in the render server — the signature of an infinite CAAnimation that nobody removed
// (a hidden loading/breathing layer, etc.). The census walks EVERY window's full layer
// tree on demand and reports every attached animation plus the NSVisualEffectView
// inventory, so the culprit can be named instead of bisected by feel.
//
// These tests pin the census contract: attached animations are found wherever they
// hide (hidden layers, mask layers), infinity is flagged, quiet trees report clean,
// and effect views are inventoried.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class WindowAnimationCensusTests: XCTestCase {

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    /// The census reads committed render-server state conceptually; host the tree in a
    /// realized window so the sweep exercises the same layer hierarchy shape as the app
    /// (frame view above contentView included).
    @MainActor
    private func makeHostedView() -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
        return view
    }

    private func infiniteAnimation(keyPath: String) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = 0.2
        anim.toValue = 1.0
        anim.duration = 1.4
        anim.repeatCount = .infinity
        return anim
    }

    // MARK: - Detection

    @MainActor
    func test_sweep_findsInfiniteAnimationOnHiddenSublayer() throws {
        let view = makeHostedView()
        let hidden = CALayer()
        hidden.name = "breathingDot"
        hidden.isHidden = true
        view.layer?.addSublayer(hidden)
        hidden.add(infiniteAnimation(keyPath: "opacity"), forKey: "dotBreathing")

        let report = WindowAnimationCensus.sweep(window: try XCTUnwrap(hostWindow))

        XCTAssertEqual(report.animations.count, 1)
        let entry = try XCTUnwrap(report.animations.first)
        XCTAssertEqual(entry.key, "dotBreathing")
        XCTAssertEqual(entry.keyPath, "opacity")
        XCTAssertTrue(entry.isInfinite)
        XCTAssertTrue(entry.layerIsHidden)
        XCTAssertTrue(entry.layerPath.contains("breathingDot"))
    }

    @MainActor
    func test_sweep_findsAnimationOnMaskLayer() throws {
        let view = makeHostedView()
        let masked = CALayer()
        view.layer?.addSublayer(masked)
        let mask = CALayer()
        masked.mask = mask
        mask.add(infiniteAnimation(keyPath: "position.x"), forKey: "sweepMask")

        let report = WindowAnimationCensus.sweep(window: try XCTUnwrap(hostWindow))

        XCTAssertEqual(report.animations.count, 1)
        let entry = try XCTUnwrap(report.animations.first)
        XCTAssertEqual(entry.key, "sweepMask")
        XCTAssertTrue(entry.layerPath.contains("mask"))
    }

    @MainActor
    func test_sweep_finiteAnimationIsReportedButNotFlaggedInfinite() throws {
        let view = makeHostedView()
        let sub = CALayer()
        view.layer?.addSublayer(sub)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.duration = 0.3
        sub.add(anim, forKey: "fadeOnce")

        let report = WindowAnimationCensus.sweep(window: try XCTUnwrap(hostWindow))

        XCTAssertEqual(report.animations.count, 1)
        XCTAssertFalse(try XCTUnwrap(report.animations.first).isInfinite)
    }

    // MARK: - Quiet tree

    @MainActor
    func test_sweep_quietTreeReportsNoAnimationsButCountsLayers() throws {
        let view = makeHostedView()
        let sub = CALayer()
        view.layer?.addSublayer(sub)

        let report = WindowAnimationCensus.sweep(window: try XCTUnwrap(hostWindow))

        XCTAssertTrue(report.animations.isEmpty)
        XCTAssertGreaterThanOrEqual(report.stats.layerCount, 2)
    }

    // MARK: - Effect-view inventory

    @MainActor
    func test_sweep_inventoriesVisualEffectViews() throws {
        let view = makeHostedView()
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        effect.blendingMode = .behindWindow
        view.addSubview(effect)

        let report = WindowAnimationCensus.sweep(window: try XCTUnwrap(hostWindow))

        XCTAssertEqual(report.effectViews.count, 1)
        XCTAssertEqual(try XCTUnwrap(report.effectViews.first).blendingMode, "behindWindow")
    }

    // MARK: - Formatting

    @MainActor
    func test_format_namesLayerPathKeyAndInfinity() throws {
        let view = makeHostedView()
        let hidden = CALayer()
        hidden.name = "breathingDot"
        hidden.isHidden = true
        view.layer?.addSublayer(hidden)
        hidden.add(infiniteAnimation(keyPath: "opacity"), forKey: "dotBreathing")

        let text = WindowAnimationCensus.format([WindowAnimationCensus.sweep(window: try XCTUnwrap(hostWindow))])

        XCTAssertTrue(text.contains("dotBreathing"))
        XCTAssertTrue(text.contains("breathingDot"))
        XCTAssertTrue(text.contains("INFINITE"))
        XCTAssertTrue(text.contains("hidden"))
    }
}
