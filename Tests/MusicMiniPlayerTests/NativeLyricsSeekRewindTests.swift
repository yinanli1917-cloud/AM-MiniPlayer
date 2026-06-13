import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// The "dim line reverts to bright" glitch (#3, the "永不会变异" line).
//
// Observed: a lyric line dims (it stopped being the active/sung line), then — mid-transition —
// snaps back to a bright active state with a quick, broken animation, then dims again.
//
// Root cause (read off the renderer's natural-playback index resolution):
//   1. Interpolated playback time is ALLOWED to move BACKWARD up to ~0.5s so a poll resync can
//      correct interpolation overshoot (documented timing trap).
//   2. NativeLyricsTimelinePolicy.amllState resolves the active line directly from playback time,
//      so a sub-0.5s backward correction that crosses a line boundary regresses semanticIndex
//      from N+1 back to N (proven by `test_amllState_regressesOnBackwardTimeJitter`).
//   3. NativeLyricsSeekClassifier.isSeek treats ANY backward index move as a SEEK, so the renderer
//      directSnaps back to line N — reactivating the just-demoted line at full brightness. Then time
//      recovers forward and it demotes again. That snap-back IS the broken bright revert.
//
// The interpolation jitter is NOT a user seek. The fix: a sub-tolerance backward time correction
// that is not an explicit (progress-bar) seek must HOLD the active line, never snap back to a
// demoted one. `isResyncRewind` classifies exactly that case so the renderer can hold instead of snap.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsSeekRewindTests: XCTestCase {

    // Three lines back-to-back: [0,4) [4,8) [8,12).
    private func threeLineRows() -> [LayerBackedLyricRow] {
        (0..<3).map { i in
            let line = LyricLine(
                text: "line \(i)",
                startTime: TimeInterval(i * 4),
                endTime: TimeInterval(i * 4 + 4)
            )
            let displayLine = DisplayLyricLine(
                id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line
            )
            return LayerBackedLyricRow(
                id: displayLine.id, index: i, displayLine: displayLine,
                sourceLine: line, isPrelude: false, preludeEndTime: 0, interlude: nil
            )
        }
    }

    // ── The raw signal: amllState follows playback time, so backward time regresses the index. ──

    /// Just past the 0→1 boundary the active line is 1; a tiny backward correction to just before the
    /// boundary regresses it to 0. This is the upstream cause — documenting it pins the mechanism.
    func test_amllState_regressesOnBackwardTimeJitter() {
        let rows = threeLineRows()
        let forward = NativeLyricsTimelinePolicy.amllState(
            at: 4.10, rows: rows, fallback: 0, previous: nil, isSeeking: false
        )
        XCTAssertEqual(forward.semanticIndex, 1, "precondition: just past the boundary, line 1 is active")

        let jittered = NativeLyricsTimelinePolicy.amllState(
            at: 3.90, rows: rows, fallback: 0, previous: forward, isSeeking: false
        )
        XCTAssertEqual(
            jittered.semanticIndex, 0,
            "amllState follows playback time: a backward correction across the boundary regresses to line 0"
        )
    }

    // ── The classifier the renderer uses to tell jitter from a real seek. ──

    /// A small (≤ tolerance) backward time correction that pulls the index back is interpolation
    /// jitter — must be held, NOT snapped. This is the case that produces the bright revert today.
    func test_isResyncRewind_holdsSubToleranceBackwardJitter() {
        XCTAssertTrue(
            NativeLyricsSeekClassifier.isResyncRewind(
                previousIndex: 1, liveIndex: 0,
                previousPlaybackTime: 4.10, playbackTime: 3.90,
                explicitSeek: false, tolerance: 0.5
            ),
            "a 0.2s non-explicit backward correction is resync jitter — hold the active line"
        )
    }

    /// A large backward jump is a genuine discontinuity (the user scrubbed back) — NOT jitter.
    func test_isResyncRewind_ignoresLargeBackwardJump() {
        XCTAssertFalse(
            NativeLyricsSeekClassifier.isResyncRewind(
                previousIndex: 2, liveIndex: 0,
                previousPlaybackTime: 9.0, playbackTime: 0.5,
                explicitSeek: false, tolerance: 0.5
            ),
            "an 8.5s backward jump exceeds the resync tolerance — it is a real seek, not jitter"
        )
    }

    /// An explicit (progress-bar) seek is always a real seek, even if small/backward.
    func test_isResyncRewind_neverHoldsExplicitSeek() {
        XCTAssertFalse(
            NativeLyricsSeekClassifier.isResyncRewind(
                previousIndex: 1, liveIndex: 0,
                previousPlaybackTime: 4.10, playbackTime: 3.90,
                explicitSeek: true, tolerance: 0.5
            ),
            "an explicit seek must snap even within the tolerance window"
        )
    }

    /// Forward motion (the normal 0→+1 advance) is never a rewind hold.
    func test_isResyncRewind_ignoresForwardMotion() {
        XCTAssertFalse(
            NativeLyricsSeekClassifier.isResyncRewind(
                previousIndex: 0, liveIndex: 1,
                previousPlaybackTime: 3.90, playbackTime: 4.10,
                explicitSeek: false, tolerance: 0.5
            ),
            "a normal forward advance is not a backward rewind"
        )
    }

    /// No prior index / no prior time (cold start) can never be a rewind.
    func test_isResyncRewind_requiresPriorState() {
        XCTAssertFalse(
            NativeLyricsSeekClassifier.isResyncRewind(
                previousIndex: nil, liveIndex: 0,
                previousPlaybackTime: nil, playbackTime: 0,
                explicitSeek: false, tolerance: 0.5
            ),
            "cold start has no prior line to revert from"
        )
    }
}
