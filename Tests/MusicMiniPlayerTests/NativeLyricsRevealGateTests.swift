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
}
