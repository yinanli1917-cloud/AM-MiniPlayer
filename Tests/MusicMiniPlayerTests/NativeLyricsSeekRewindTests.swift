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

    // Rows with explicit [start, end) spans, so a span can OUTLAST the next line's start (overlap).
    private func rows(_ spans: [(start: TimeInterval, end: TimeInterval)]) -> [LayerBackedLyricRow] {
        spans.enumerated().map { i, span in
            let line = LyricLine(text: "line \(i)", startTime: span.start, endTime: span.end)
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
                previousPlaybackTime: nil, playbackTime: 0,
                explicitSeek: false, tolerance: 0.5
            ),
            "cold start has no prior line to revert from"
        )
    }

    // ── The gap that kept the revert alive: poll overshoots in the 0.5–2s band. ──
    // lyricRenderTime (what the renderer reads) takes its BACKWARD jumps from the poll, which the clock
    // treats as non-seek jitter all the way to ~2s (only >2s hard-syncs as a seek). The renderer's hold
    // tolerance must match THAT window, not the unrelated 0.5s interpolateTime currentTime allowance —
    // otherwise a 0.5–2s poll overshoot (increasingly common as drift accumulates over a long track)
    // escapes the hold and re-lights the just-passed line.

    /// A non-explicit backward correction anywhere within the clock's non-seek window must hold.
    func test_isResyncRewind_holdsPollOvershootWithinClockSeekWindow() {
        for backStep in [0.7, 1.4, 1.9] as [TimeInterval] {
            XCTAssertTrue(
                NativeLyricsSeekClassifier.isResyncRewind(
                    previousPlaybackTime: 20.30, playbackTime: 20.30 - backStep,
                    explicitSeek: false,
                    tolerance: NativeLyricsSurfaceView.resyncRewindTolerance
                ),
                "a \(backStep)s non-explicit poll overshoot is drift the clock silently applies (<2s) — must hold, not re-light"
            )
        }
    }

    /// A backward jump beyond the clock's seek threshold (~2s) is a genuine external seek — must snap.
    func test_isResyncRewind_snapsBeyondClockSeekWindow() {
        XCTAssertFalse(
            NativeLyricsSeekClassifier.isResyncRewind(
                previousPlaybackTime: 22.5, playbackTime: 0.5,   // 22s backward = a real external seek
                explicitSeek: false,
                tolerance: NativeLyricsSurfaceView.resyncRewindTolerance
            ),
            "a >2s backward jump is a real external seek — must snap, not hold"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // The RESIDUAL "状态突变": the previous line partially re-brightens with NO index regression.
    //
    // 逐字 (word-level) lyrics overlap — a line's end-time outlasts the next line's start. While both
    // overlap, both are "hot" (the harmony tier, opacity 0.85). When time passes the earlier line's
    // end it drops out of hotGroups and recedes to a past line (opacity 0.35). A backward poll-resync
    // dip back across that end-time REGROWS hotGroups to re-include the earlier line — but the MAX
    // index is unchanged (the later line is still hot), so semanticIndex does not regress. The
    // index-keyed isResyncRewind hold never fires, the regrown hotGroups reach the surface, and the
    // just-receded line bumps 0.35 → 0.85: a partial brighten, occasional, more frequent as drift grows.
    //
    // The fix: the hold must key on the backward TIME step (resync jitter), not on the index regressing.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Overlapping lines: a backward dip across the earlier line's end regrows hotGroups to re-include
    /// it, while the max (semantic) index stays on the later line. This is the upstream mechanism.
    func test_amllState_regrowsHotGroupsOnBackwardDipIntoOverlap() {
        // line 1: [16, 21)  — outlasts line 2's start (overlap [20, 21)).
        // line 2: [20, 24)
        let overlap = rows([(0, 16), (16, 21), (20, 24)])

        let afterEnd = NativeLyricsTimelinePolicy.amllState(
            at: 21.20, rows: overlap, fallback: 0, previous: nil, isSeeking: false
        )
        XCTAssertEqual(afterEnd.hotGroups, [2], "past line 1's end: only line 2 is hot")
        XCTAssertEqual(afterEnd.semanticIndex, 2)

        let dipped = NativeLyricsTimelinePolicy.amllState(
            at: 20.80, rows: overlap, fallback: 0, previous: afterEnd, isSeeking: false
        )
        XCTAssertEqual(
            dipped.hotGroups, [1, 2],
            "a 0.4s backward dip re-enters line 1's window — hotGroups regrows to include it"
        )
        XCTAssertEqual(
            dipped.semanticIndex, 2,
            "the MAX index is unchanged — the index-keyed hold has nothing to catch"
        )
    }

    /// The visible cost of that regrow: feeding the regrown hot set to amllTarget bumps the just-receded
    /// previous line from a past line (0.35) back up to the harmony tier (0.85) — the "状态突变".
    func test_amllTarget_previousLineBumpsToHarmonyWhenHotGroupsRegrow() {
        let recededPast = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 1, currentIndex: 2, scrollTargetIndex: 2,
            hotActiveIndices: [2], isManualScrolling: false
        )
        XCTAssertEqual(recededPast.opacity, 0.35, accuracy: 0.001, "line 1 has receded to a past line")

        let bumped = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 1, currentIndex: 2, scrollTargetIndex: 2,
            hotActiveIndices: [1, 2], isManualScrolling: false
        )
        XCTAssertEqual(
            bumped.opacity, 0.85, accuracy: 0.001,
            "regrown hotGroups re-light line 1 to the harmony tier — the previous line's state jump"
        )
    }

    /// The fix point. A sub-tolerance backward time dip is resync jitter the hold must catch EVEN when
    /// the index is unchanged (the overlap regrow above). The classifier must key on the time step.
    func test_isResyncRewind_holdsBackwardJitterWhenIndexUnchanged() {
        XCTAssertTrue(
            NativeLyricsSeekClassifier.isResyncRewind(
                // index is UNCHANGED here (overlap regrow, not an index regression) — the hold keys on time
                previousPlaybackTime: 21.20, playbackTime: 20.80,
                explicitSeek: false,
                tolerance: NativeLyricsSurfaceView.resyncRewindTolerance
            ),
            "a 0.4s non-explicit backward dip is resync jitter even with the index unchanged — hold so hotGroups can't regrow"
        )
    }
}
