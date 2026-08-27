import XCTest
import AppKit
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

    func test_occludedWindow_stopsLoopEvenDuringWordSweep() {
        XCTAssertFalse(
            NativeLyricsLoopIdleDecision.shouldKeepPresentationLoopRunning(
                isWindowOccluded: true,
                vetoes: ["textAnim"]
            )
        )
    }

    func test_visibleWindow_keepsLoopForWordSweep() {
        XCTAssertTrue(
            NativeLyricsLoopIdleDecision.shouldKeepPresentationLoopRunning(
                isWindowOccluded: false,
                vetoes: ["textAnim"]
            )
        )
    }

    func test_visibleSettled_stopsLoop() {
        XCTAssertFalse(
            NativeLyricsLoopIdleDecision.shouldKeepPresentationLoopRunning(
                isWindowOccluded: false,
                vetoes: []
            )
        )
    }

    func test_interpolationStopsWhenPanelOccluded() {
        XCTAssertFalse(
            PlaybackInterpolationPolicy.shouldRun(
                isPlaying: true, windowMovementPaused: false, panelOccluded: true
            )
        )
        XCTAssertTrue(
            PlaybackInterpolationPolicy.shouldRun(
                isPlaying: true, windowMovementPaused: false, panelOccluded: false
            )
        )
        XCTAssertFalse(
            PlaybackInterpolationPolicy.shouldRun(
                isPlaying: false, windowMovementPaused: false, panelOccluded: false
            )
        )
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

    // ── Text-animation need (line-level CPU regression, cfb5308ae/cfc152c/7653221) ──
    // A line-level (non-syllable-synced) active row's MAIN text never sweeps, and its
    // TRANSLATION only sweeps when the main line is word-timed (translations render
    // statically otherwise — NativeLyricsRowView.appliesTranslationSweep). So a shown,
    // non-empty translation must never by itself justify holding the display link open;
    // doing so pinned line-level+translation playback at steady CPU with nothing
    // actually animating on screen.

    func test_wordTimedRow_needsTextAnimation() {
        XCTAssertTrue(
            NativeLyricsLoopIdleDecision.needsTextAnimation(
                hasSyllableSync: true, hasInterlude: false, isPrelude: false
            )
        )
    }

    func test_lineLevelRow_withNoInterludeOrPrelude_doesNotNeedTextAnimation() {
        XCTAssertFalse(
            NativeLyricsLoopIdleDecision.needsTextAnimation(
                hasSyllableSync: false, hasInterlude: false, isPrelude: false
            )
        )
    }

    func test_lineLevelRow_withInterlude_stillNeedsTextAnimation() {
        XCTAssertTrue(
            NativeLyricsLoopIdleDecision.needsTextAnimation(
                hasSyllableSync: false, hasInterlude: true, isPrelude: false
            )
        )
    }

    func test_lineLevelRow_isPrelude_stillNeedsTextAnimation() {
        XCTAssertTrue(
            NativeLyricsLoopIdleDecision.needsTextAnimation(
                hasSyllableSync: false, hasInterlude: false, isPrelude: true
            )
        )
    }

    // ── Hosted window occlusion ──

    @MainActor
    func test_orderOut_stopsPresentationLoopDuringWordSweep() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 600)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = surface
        window.orderFrontRegardless()
        defer {
            surface.stopAnimations()
            window.orderOut(nil)
        }

        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        mc.syncPlaybackClock(to: 0.4, playing: true)
        let rows: [LayerBackedLyricRow] = (0..<8).map { i in
            let s = TimeInterval(i) * 1.2, e = TimeInterval(i) * 1.2 + 1.2
            let d = (e - s) / 3
            let line = LyricLine(
                text: "line \(i) words here", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "line ", startTime: s, endTime: s + d),
                    LyricWord(word: "\(i) ", startTime: s + d, endTime: s + 2 * d),
                    LyricWord(word: "words here", startTime: s + 2 * d, endTime: e),
                ]
            )
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(
                id: dl.id, index: i, displayLine: dl, sourceLine: line,
                isPrelude: false, preludeEndTime: 0, interlude: nil
            )
        }
        var heights: [Int: CGFloat] = [:]
        for row in rows { heights[row.index] = 56 }
        surface.configure(
            LyricsLayerRendererConfiguration(
                rows: rows, currentIndex: 0, anchorY: 300, rowWidth: 320,
                renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
                lineInterval: 4, hasSyllableSync: true,
                trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
                isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
                suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
                isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
                controlsVisible: false, musicController: mc,
                onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
                onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
                onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
                lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
                onLineMotionFrames: { _, _, _, _ in }
            )
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(surface.debugIsPresentationLoopRunning, "visible playing word-sweep must arm the display link")

        window.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(surface.debugIsPresentationLoopRunning, "orderOut must stop the display link even while playing")
    }
}
