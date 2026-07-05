//
//  NativeLyricsReuseStateResetTests.swift
//
//  Cycle 1 — reuse-state pair. Two teardown paths in NativeLyricsRowView forgot to restore a
//  layer property to its resting value, so a recycled or re-shown row carried stale state for a
//  frame:
//
//    Issue 6 — active-line size pop on seek. prepareForReuse() resets text-layer opacity and many
//    caches, but never resets positioningTransform. layout() re-asserts positioningTransform on
//    every commit, so a remounted row shows the PREVIOUS row's scale (e.g. 0.8) for one frame
//    before applyFrame writes the new scale.
//
//    Issue 2 — dim-then-relight. The deactivation fade scales the bright sung-overlay opacity
//    toward 0 as a line recedes. endDeactivationFade() only cleared the baselines; it left the
//    bright layer at the residual fraction. A row that finished the fade but stayed mounted
//    relit from that fraction the next time it was shown.
//
//  Both assertions read MODEL state (the stored transform / the layer's model opacity), so no
//  window host or CATransaction flush is needed — these are reset-contract tests, not
//  implicit-animation tests.
//

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

final class NativeLyricsReuseStateResetTests: XCTestCase {

    private func row(index: Int) -> LayerBackedLyricRow {
        let start = TimeInterval(index * 4)
        let line = LyricLine(
            text: "line \(index) words here",
            startTime: start,
            endTime: start + 3,
            words: [
                LyricWord(word: "line ", startTime: start, endTime: start + 1),
                LyricWord(word: "\(index) ", startTime: start + 1, endTime: start + 2),
                LyricWord(word: "words here", startTime: start + 2, endTime: start + 3),
            ]
        )
        let displayLine = DisplayLyricLine(
            id: "reuse-\(index)",
            sourceIndex: index,
            segmentIndex: 0,
            segmentCount: 1,
            line: line
        )
        return LayerBackedLyricRow(
            id: displayLine.id,
            index: index,
            displayLine: displayLine,
            sourceLine: line,
            isPrelude: false,
            preludeEndTime: 0,
            interlude: nil
        )
    }

    @MainActor
    private func config(
        rows: [LayerBackedLyricRow],
        currentIndex: Int,
        musicController: MusicController
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for row in rows {
            heights[row.index] = CGFloat(row.index) * 56
        }
        return LyricsLayerRendererConfiguration(
            rows: rows,
            currentIndex: currentIndex,
            anchorY: 250,
            rowWidth: 320,
            renderedIndices: rows.map(\.index),
            accumulatedHeights: heights,
            lineTargetIndices: [:],
            lineInterval: 3,
            hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 60),
            isWaveTimelineDiagnosticsEnabled: false,
            isManualScrolling: false,
            reduceMotion: false,
            suppressInitialMotion: false,
            pendingTranslationLineIndices: [],
            showTranslation: false,
            isTranslating: false,
            translationFailed: false,
            interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: false,
            musicController: musicController,
            onLineTap: { _ in },
            onDirectSnapConsumed: { _ in },
            onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in },
            onManualScrollEnded: {},
            onManualScrollRecovered: {},
            onManualScrollChromeReset: nil,
            onHeightMeasured: { _, _ in },
            lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast,
            lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    // ── Issue 6 ──────────────────────────────────────────────────────────────
    @MainActor
    func test_prepareForReuse_resetsPositioningTransformToIdentity() {
        let row = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))

        // A receding/active row carries a non-identity scale.
        row.setPositioning(CGAffineTransform(scaleX: 0.8, y: 0.8))
        XCTAssertNotEqual(row.positioningTransform, .identity, "precondition: row holds a scaled transform")

        // Recycle it. Without the reset, positioningTransform keeps 0.8 and layout() re-asserts it
        // for one frame on the next mount = the size pop.
        row.prepareForReuse()

        XCTAssertEqual(row.positioningTransform, .identity,
                       "reuse must clear the scale so the remounted row never flashes the old size")
        XCTAssertEqual(row.layer?.affineTransform() ?? .identity, .identity,
                       "the backing layer transform is reset too, so layout() re-asserts identity, not 0.8")
    }

    // ── Issue 2 ──────────────────────────────────────────────────────────────
    @MainActor
    func test_endDeactivationFade_restoresBrightOpacityToOne() {
        let row = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))

        // commonInit leaves the bright overlays visible at full opacity — the active-line resting state.
        XCTAssertEqual(row.debugMainBrightOpacity, 1, accuracy: 0.001, "precondition: bright overlay starts opaque")

        // Recede: capture the baseline, then fade most of the way out.
        row.beginDeactivationFade()
        row.updateDeactivationFade(progress: 0.3)
        XCTAssertEqual(row.debugMainBrightOpacity, 0.3, accuracy: 0.01, "the fade actually dims the bright overlay")
        XCTAssertEqual(row.debugTranslationBrightOpacity, 0.3, accuracy: 0.01, "translation overlay dims in lockstep")

        // End of fade must restore the resting value so a later re-light starts from full, not 0.3.
        row.endDeactivationFade()
        XCTAssertEqual(row.debugMainBrightOpacity, 1, accuracy: 0.001,
                       "endDeactivationFade restores the main bright overlay to 1 (no residual dim relights wrong)")
        XCTAssertEqual(row.debugTranslationBrightOpacity, 1, accuracy: 0.001,
                       "endDeactivationFade restores the translation bright overlay to 1")
    }

    @MainActor
    func test_finalizeDeactivationStateDoesNotReenterPlaybackPhase() {
        let rowView = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        let musicController = MusicController(preview: true)
        musicController.duration = 60
        musicController.isPlaying = true
        musicController.syncPlaybackClock(to: 1.5, playing: true)
        let rows = [row(index: 0), row(index: 1)]

        rowView.configure(
            row: rows[0],
            configuration: config(rows: rows, currentIndex: 0, musicController: musicController)
        )
        XCTAssertTrue(rowView.debugMainBrightOverlayActive, "precondition: active syllable row has a bright overlay")

        let phaseUpdatesAfterActiveConfigure = rowView.debugPlaybackPhaseUpdateCount
        rowView.beginDeactivationFade()
        rowView.updateDeactivationFade(progress: 0.25)
        XCTAssertLessThan(rowView.debugMainBrightOpacity, 0.5, "precondition: deactivation fade dimmed the overlay")

        rowView.configure(
            row: rows[0],
            configuration: config(rows: rows, currentIndex: 1, musicController: musicController),
            updatesPlaybackPhase: false
        )
        rowView.finalizeDeactivationState(renderTime: musicController.lyricRenderTime())

        XCTAssertEqual(
            rowView.debugPlaybackPhaseUpdateCount,
            phaseUpdatesAfterActiveConfigure,
            "deactivation finalization must not run the full playback phase updater a second time"
        )
        XCTAssertFalse(rowView.debugMainBrightOverlayActive, "inactive finalization hides the karaoke overlay")
        XCTAssertEqual(rowView.debugMainBrightOpacity, 0, accuracy: 0.001)
    }
}
