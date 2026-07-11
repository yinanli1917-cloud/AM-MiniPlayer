import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Presentation-loop idle decision (defect 5).
//
// A paused panel froze inside an interlude window kept the display link alive
// forever: `interludeAfterIndex` is playback-time-derived and playback time does
// not advance while paused, so the veto never cleared, the loop ticked at 60 Hz,
// and every tick's commit forced WindowServer to re-evaluate the resident blur
// stack (+20 WS CPU on a fully static panel — measured 2026-07-10).
//
// The rule these tests pin: the interlude veto only holds while PLAYING. The
// dots are driven by playback time (NativeLyricsDotPhasePlan takes track times
// only), so a paused interlude is already visually frozen and ticking cannot
// change a pixel. Motion vetoes (engine/visual) are playback-independent: rows
// still gliding after a pause must finish settling before the loop stops.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsLoopIdleTests: XCTestCase {

    private func vetoes(
        appearWindow: Bool = false,
        tapSettle: Bool = false,
        engineMotion: Bool = false,
        visualMotion: Bool = false,
        textAnimation: Bool = false,
        interlude: Bool = false,
        deferredDeactivation: Bool = false,
        isPlaying: Bool
    ) -> [String] {
        NativeLyricsLoopIdleDecision.vetoes(
            keepsAppearWindowAlive: appearWindow,
            hasPendingTapSettle: tapSettle,
            hasEngineMotion: engineMotion,
            hasVisualMotion: visualMotion,
            hasActiveTextAnimation: textAnimation,
            hasInterlude: interlude,
            hasDeferredDeactivation: deferredDeactivation,
            isPlaying: isPlaying
        )
    }

    func test_pausedInsideInterlude_allowsLoopStop() {
        XCTAssertTrue(vetoes(interlude: true, isPlaying: false).isEmpty)
    }

    func test_playingInsideInterlude_vetoesLoopStop() {
        XCTAssertEqual(vetoes(interlude: true, isPlaying: true), ["interlude"])
    }

    func test_pausedWithUnsettledMotion_stillVetoes() {
        XCTAssertEqual(
            vetoes(engineMotion: true, visualMotion: true, isPlaying: false),
            ["engineMotion", "visualMotion"]
        )
    }

    func test_appearWindow_vetoesRegardlessOfPlayback() {
        XCTAssertEqual(vetoes(appearWindow: true, isPlaying: false), ["appearWindow"])
        XCTAssertEqual(vetoes(appearWindow: true, isPlaying: true), ["appearWindow"])
    }

    func test_fullySettledPaused_allowsLoopStop() {
        XCTAssertTrue(vetoes(isPlaying: false).isEmpty)
    }

    // ── Deferred-deactivation cancellation ──
    // Pausing mid-handoff can re-resolve the current line back to the row whose
    // deactivation was just deferred; that row's opacity returns to active-high,
    // so the finalize threshold (opacity < 0.38) is unreachable and the veto
    // sticks forever. Deactivating the CURRENT row is moot in any playback state:
    // the deferral must be cancelled, not awaited.

    func test_deferredRowBecameCurrentAgain_cancelsDeferral() {
        XCTAssertTrue(
            NativeLyricsLoopIdleDecision.shouldCancelDeferredDeactivation(
                deferredIndex: 7, currentIndex: 7
            )
        )
    }

    func test_deferredRowStillReceding_keepsDeferral() {
        XCTAssertFalse(
            NativeLyricsLoopIdleDecision.shouldCancelDeferredDeactivation(
                deferredIndex: 7, currentIndex: 8
            )
        )
    }

    func test_noDeferral_nothingToCancel() {
        XCTAssertFalse(
            NativeLyricsLoopIdleDecision.shouldCancelDeferredDeactivation(
                deferredIndex: nil, currentIndex: 7
            )
        )
    }
}
