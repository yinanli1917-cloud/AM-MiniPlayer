import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Reveal gate contract.
//
// The owner's presentation-layer census proved the line-switch "blurred row flash":
// a just-mounted row's PRESENTATION Y sits at its un-positioned default (≈0, the top)
// for one frame while its MODEL Y is already correct (far) — so Core Animation paints
// it at the top, blurred. The fix suppresses that one frame (opacity 0) until the
// presentation Y catches up. Census facts pinned here: settled rows diverge ≤10px,
// normal spring lag ≤150px, just-mounted rows diverge >150 (stuck at 0/edge).
//
// The on-screen flash is a presentation-timing event with no clean deterministic unit
// seam, so this verifies the pure DECISION; the rendered result is verified via the
// census + the owner at 120 Hz.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsRevealGateTests: XCTestCase {

    @MainActor
    func test_unpositionedRowSuppressed_settledRowKept() {
        let t = NativeLyricsSurfaceView.unpositionedDivergenceThreshold

        // Never rendered (nil presentation) → not yet positioned → suppress.
        XCTAssertTrue(NativeLyricsSurfaceView.isRowUnpositioned(presentationY: nil, modelY: 760))

        // Just-mounted: presentation stuck at the top (0) while model is far → suppress.
        // (These are the exact census signatures: py0/my760, py0/my-352.)
        XCTAssertTrue(NativeLyricsSurfaceView.isRowUnpositioned(presentationY: 0, modelY: 760))
        XCTAssertTrue(NativeLyricsSurfaceView.isRowUnpositioned(presentationY: 0, modelY: -352))

        // Settled (presentation == model) → keep. This is what protects the faded context
        // lines above/below the active line — the reverted viewport-cull wrongly hid these.
        XCTAssertFalse(NativeLyricsSurfaceView.isRowUnpositioned(presentationY: 300, modelY: 300))
        XCTAssertFalse(NativeLyricsSurfaceView.isRowUnpositioned(presentationY: 300, modelY: 308))

        // Normal spring lag (≤ threshold) → keep (a legitimately-moving row stays visible).
        XCTAssertFalse(NativeLyricsSurfaceView.isRowUnpositioned(presentationY: 300, modelY: 300 + (t - 1)))
        // Beyond the threshold → suppress.
        XCTAssertTrue(NativeLyricsSurfaceView.isRowUnpositioned(presentationY: 300, modelY: 300 + (t + 1)))
    }

    // ── Census oscillation detector (the "stumble / flicker / repeat" signature) ──

    @MainActor
    func test_censusOscillationDetector() {
        // Smooth monotonic motion → NOT flagged.
        XCTAssertFalse(NativeLyricsSurfaceView.censusOscillates([0.1, 0.3, 0.6, 1.0], epsilon: 0.05))
        // Flat / held → NOT flagged.
        XCTAssertFalse(NativeLyricsSurfaceView.censusOscillates([0.35, 0.35, 0.35], epsilon: 0.05))
        // Rise then fall within the window (a flicker / stumble) → FLAGGED.
        XCTAssertTrue(NativeLyricsSurfaceView.censusOscillates([0.35, 1.0, 0.35], epsilon: 0.05))
        // A receded line that dims then briefly re-brightens → FLAGGED.
        XCTAssertTrue(NativeLyricsSurfaceView.censusOscillates([1.0, 0.5, 0.35, 0.6], epsilon: 0.05))
        // Sub-epsilon jitter (rendering noise) → NOT flagged.
        XCTAssertFalse(NativeLyricsSurfaceView.censusOscillates([0.35, 0.37, 0.35], epsilon: 0.05))
        // Too few samples → NOT flagged.
        XCTAssertFalse(NativeLyricsSurfaceView.censusOscillates([0.35, 1.0], epsilon: 0.05))
    }

    // ── Transform-reset reproduction (the load-correlated 花屏 root) ──

    /// Census proved a one-frame global reset of every row's positioning transform to identity
    /// (Y[42,0,42] + SCALE[0.95,1,0.95]). Rows are positioned by a manual layer transform, which
    /// AppKit's layout pass is known to reset on a layer-backed NSView. Drive a realised layout
    /// pass and assert the positioning transform SURVIVES. If it does not, this is the root.
    @MainActor
    func test_appKitLayoutPreservesRowPositioningTransform() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        container.wantsLayer = true
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let view = NativeLyricsRowView(frame: CGRect(x: 0, y: 0, width: 320, height: 40))
        view.wantsLayer = true
        container.addSubview(view)

        let target = CGAffineTransform(translationX: 0, y: 300).scaledBy(x: 0.95, y: 0.95)
        view.setPositioning(target)  // the real positioning path (re-asserted in layout())
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        // Force an AppKit layout pass — the suspected transform-reset trigger.
        view.needsLayout = true
        container.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let ty = view.layer?.affineTransform().ty ?? -999
        let presTy = view.layer?.presentation()?.affineTransform().ty ?? ty
        XCTAssertEqual(ty, 300, accuracy: 1.0,
                       "MODEL transform reset by layout (ty=\(ty)) — code/AppKit reset the positioning transform")
        XCTAssertEqual(presTy, 300, accuracy: 1.0,
                       "PRESENTATION transform reset by layout (presTy=\(presTy)) — AppKit/CA reset on render")
    }
}
