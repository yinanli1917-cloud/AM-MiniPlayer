import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Past-line opacity-revert reproduction (the "永不会变异" glitch).
//
// Observed on a 60fps screen capture: when a lyric line stops being the active
// (currently-sung) line and becomes a PAST line, it should fade bright→dim
// monotonically. Instead it briefly REVERTS toward bright (opacity bumps UP
// above its dim settle value) before fading down — a non-monotonic, broken
// transition. Per-line luminance on the recording: dim ~46 → spike 64 → settle ~50.
//
// Root cause (confirmed by live OpacityTrace capture on "Xia Nie Piao Piao Chu Chu Wen",
// Eman Lam): the natural-playback spring (amllNatural: mass 1, stiffness 100, damping 16.5)
// is UNDERDAMPED — critical damping = 2√(k·m) = 20 > 16.5 — and opacity is driven on it
// (shared with line position so depth-of-field stays locked to the scroll). On demotion the
// scalar therefore overshoots: every dimming line was measured undershooting BELOW its 0.35
// target to ~0.328 then rebounding back up to ~0.343 — a brightness direction-reversal that
// reads as a just-dimmed line "reverting to a normal bright state". quickRetarget()'s 12×
// velocity kick amplifies it but the underdamped spring overshoots from rest regardless.
//
// Fix: opacity advances with `monotonic: true` — it snaps to target the instant a step would
// cross it, so brightness approaches smoothly but never overshoots or rebounds.
//
// This test drives the REAL NativeLyricsVisualMotionState through the exact transition the
// renderer performs (LyricsLayerRendererView.syncVisualTargets + advanceVisualStates), and
// asserts the demoted line's opacity falls monotonically with no upward revert or undershoot.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class NativeLyricsOpacityDemotionTests: XCTestCase {

    // The active line (displayIndex == currentIndex): opacity 1.0, isActive true.
    private func activeTarget() -> NativeLyricsVisualTarget {
        NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5,
            currentIndex: 5,
            scrollTargetIndex: 5,
            hotActiveIndices: [],
            isManualScrolling: false
        )
    }

    // The same line one tick later, after playback advanced to the next line:
    // displayIndex 5, currentIndex 6 → past line, opacity 0.35, isActive false.
    private func demotedTarget() -> NativeLyricsVisualTarget {
        NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5,
            currentIndex: 6,
            scrollTargetIndex: 6,
            hotActiveIndices: [],
            isManualScrolling: false
        )
    }

    // Replays syncVisualTargets()'s active-flip branch + advanceVisualStates()'s
    // per-tick advance on the natural-playback spring, returning the opacity per frame.
    private func demotionOpacityTrajectory(frames: Int = 40,
                                           frameDelta: TimeInterval = 1.0 / 60.0) -> [CGFloat] {
        var state = NativeLyricsVisualMotionState(target: activeTarget())
        XCTAssertEqual(state.opacity, 1.0, accuracy: 1e-6, "precondition: line starts active/bright")

        // syncVisualTargets: wasActive(true) != isNowActive(false) → quickRetarget.
        state.quickRetarget(to: demotedTarget())

        var trajectory: [CGFloat] = [state.opacity]
        for _ in 0..<frames {
            // advanceVisualStates drives every state on the natural-playback spring.
            state.advance(delta: frameDelta, spring: .amllNatural)
            trajectory.append(state.opacity)
        }
        return trajectory
    }

    /// The demoted line's opacity must fall monotonically to its dim target with no upward revert.
    func testDemotedLineOpacityNeverRevertsUpward() {
        let trajectory = demotionOpacityTrajectory()
        let pretty = trajectory.map { String(format: "%.3f", $0) }.joined(separator: " ")

        var maxUpwardStep: CGFloat = 0
        var worstFrame = 0
        for i in 1..<trajectory.count {
            let step = trajectory[i] - trajectory[i - 1]
            if step > maxUpwardStep { maxUpwardStep = step; worstFrame = i }
        }

        // Allow only tiny numerical jitter. A real revert is an order of magnitude larger.
        XCTAssertLessThanOrEqual(
            maxUpwardStep, 0.005,
            """
            Demoted (active→past) line opacity reverted UPWARD by \(String(format: "%.3f", maxUpwardStep)) \
            at frame \(worstFrame) — the bright-revert glitch.
            trajectory: [\(pretty)]
            """
        )
    }

    /// It must also never dip below the dim target then rebound (the undershoot half of the oscillation).
    func testDemotedLineOpacityStaysAtOrAboveDimTarget() {
        let trajectory = demotionOpacityTrajectory()
        let dimTarget = demotedTarget().opacity // 0.35
        let minOpacity = trajectory.min() ?? 0
        let pretty = trajectory.map { String(format: "%.3f", $0) }.joined(separator: " ")
        XCTAssertGreaterThanOrEqual(
            minOpacity, dimTarget - 0.01,
            """
            Demoted line undershot below its dim target (\(dimTarget)) to \(String(format: "%.3f", minOpacity)) \
            before rebounding — the oscillation that produces the revert.
            trajectory: [\(pretty)]
            """
        )
    }

    /// Final settle must land on the dim target regardless of the transition shape.
    func testDemotedLineSettlesAtDimTarget() {
        let trajectory = demotionOpacityTrajectory()
        XCTAssertEqual(trajectory.last ?? -1, demotedTarget().opacity, accuracy: 0.01,
                       "demoted line must settle at the dim target opacity")
    }
}
