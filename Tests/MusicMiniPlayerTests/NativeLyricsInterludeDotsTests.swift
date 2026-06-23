import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Interlude overlay dots — anti-collapse contract.
//
// Reported bug: on manual scroll the three interlude dots "重合在一起" (collapsed/overlapping).
// Root cause: the dots' horizontal positions were written ONLY inside the per-frame
// updateSurfaceInterludeDots loop. Any frame that mutated the dot group without re-running that
// loop (e.g. a manual-scroll reconcile) left the dots at their default origin (0,0) — all three
// stacked. The fix makes the dot layout STATIC: positions/bounds are assigned once in
// setupSurfaceInterludeDots and never re-derived, so the per-frame update can only move the whole
// group (Y) and change opacity/scale — it can never collapse the dots.
//
// This test reads the actual dot-layer X positions (presentation-model values, not pixels) and
// asserts they stay spaced — including BEFORE any configure/tick, which the old per-frame-only
// layout could not satisfy.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsInterludeDotsTests: XCTestCase {

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    @MainActor
    private func hostInWindow(_ view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
    }

    @MainActor
    func test_interludeDots_areSpaced_andNeverCollapse() {
        let surface = NativeLyricsSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        hostInWindow(surface)

        let dotSize = NativeLyricsDotPhasePlan.baseDotSize
        let spacing = NativeLyricsDotPhasePlan.baseDotSpacing
        let step = dotSize + spacing

        // Spaced from the moment the surface exists — BEFORE any configure/tick. The old per-frame
        // layout left these at (0,0) here (collapsed), so this assertion is the anti-regression.
        let xs = surface.debugInterludeDotCenterXs
        XCTAssertEqual(xs.count, 3, "three interlude dots")
        XCTAssertEqual(xs[1] - xs[0], step, accuracy: 0.01, "dot 0→1 spacing fixed at setup")
        XCTAssertEqual(xs[2] - xs[1], step, accuracy: 0.01, "dot 1→2 spacing fixed at setup")
        XCTAssertGreaterThan(xs[2] - xs[0], dotSize, "dots must not be collapsed at the origin")
    }
}
