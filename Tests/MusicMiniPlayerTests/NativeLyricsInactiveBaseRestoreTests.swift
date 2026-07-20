/**
 * [INPUT]: MusicMiniPlayerCore NativeLyricsRowView + LyricsLayerRendererConfiguration
 * [OUTPUT]: Unit tests: the inactive path must restore the whole-line base text
 * [POS]: Test module. Pins the second half of the 2026-07-19 mask defect: the
 *        active word-cascade path deliberately nils the whole-line text layers
 *        (per-word glyphs carry the base), but every hide/deactivate path only
 *        hid the glyph layers WITHOUT restoring the whole-line string — a row
 *        caught by finalizeDeactivationState in that state rendered fully
 *        blank (the "line disappears on manual scroll" symptom). Rule: leaving
 *        the active cascade always restores the whole-line base text.
 *        MUST host in a realized NSWindow (banned-patterns: CA state is not
 *        exercised on detached views).
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

final class NativeLyricsInactiveBaseRestoreTests: XCTestCase {

    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        window = w
    }

    private func wordRow() -> LayerBackedLyricRow {
        let line = LyricLine(
            text: "hello brave new world",
            startTime: 0, endTime: 4.8,
            words: [
                LyricWord(word: "hello ", startTime: 0, endTime: 1.2),
                LyricWord(word: "brave ", startTime: 1.2, endTime: 2.4),
                LyricWord(word: "new ", startTime: 2.4, endTime: 3.6),
                LyricWord(word: "world", startTime: 3.6, endTime: 4.8),
            ]
        )
        let dl = DisplayLyricLine(id: "r0", sourceIndex: 0, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: 0, displayLine: dl, sourceLine: line,
                                   isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], mc: MusicController) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: 0, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [],
            showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    @MainActor
    func test_finalizeDeactivation_restoresWholeLineBaseText() {
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        host(view, NSSize(width: 320, height: 56))
        let mc = MusicController(preview: true)
        mc.isPlaying = true

        let row = wordRow()
        let cfg = config([row], mc: mc)
        view.configure(row: row, configuration: cfg)
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertNotNil(view.debugMainTextLayerString, "configured row starts with a whole-line base")

        // Drive the active word-cascade phase: geometryReady nils the whole-line
        // strings by design (per-word glyphs carry the base from here).
        _ = view.updatePlaybackPhase(configuration: cfg)
        XCTAssertNil(view.debugMainTextLayerString,
                     "precondition: the active cascade owns the base (whole-line string nil)")

        // Leaving the cascade must restore the whole-line base — this was the
        // blank-row door: glyphs hidden, string still nil, nothing on screen.
        view.finalizeDeactivationState(renderTime: 5.0)
        XCTAssertNotNil(view.debugMainTextLayerString,
                        "inactive row must never be left without its whole-line base text")
    }
}
