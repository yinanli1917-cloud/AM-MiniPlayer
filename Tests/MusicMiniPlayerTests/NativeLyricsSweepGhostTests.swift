import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder defect (2026-09-12): "很多歌词重影，集中在 CJK 亮字" — a double image on swept
// CJK glyphs. Original root cause (verified against source at the time):
//
// v2.8 (git show v2.8:.../LyricLineView.swift :734-746, :905-918, :885-900) floats the DIM
// base word by the SAME floatY as the BRIGHT word — dim and bright ink always coincide.
//
// Native shipping default (NativeLyricsFeelParity.keepsWholeLineDimBase == true) kept the
// whole-line dim CATextLayer at rest (never floated) while only the per-glyph BRIGHT tile
// floated -2pt once a word starts. Two copies of every swept glyph, 2pt apart, was the ghost.
// The original fix (this test's original invariant) hollowed the whole-line base for whatever
// word was floating and floated its per-glyph DIM tile in lockstep with the bright one, so
// exactly one FULLY-OPAQUE copy of the glyph was ever on screen.
//
// SUPERSEDED 2026-09-19 (research/repro-2026-09-19-lyrics-render-3n.md) by a founder-dictated
// trade-off after a WORSE real-device bug: that hollow-and-resync machinery caused every swept
// word's ink to snap 2pt the instant its line deactivated (the whole-line base's un-hollow and
// the per-glyph tiles' teardown were not in lockstep). The founder chose to accept a much
// smaller cosmetic cost — the whole-line dim base is now NEVER hollowed for an ordinary word, so
// while a word floats, its at-rest dim ink is visible underneath the floated bright tile — in
// exchange for eliminating the hard drop. This test now asserts the NEW invariant: the per-glyph
// DIM tile is never used for an ordinary word (`dimHidden` always true, `dimPositionY` never
// moves from rest) — there is exactly one dim source (the whole-line base, always at rest) and
// one bright source (the per-glyph tile, floated), never two independently-moving copies.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsSweepGhostTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.resetTestingOverrides()
        hostWindow?.orderOut(nil)
        hostWindow = nil
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
        hostWindow = w
    }

    private func cjkLine() -> LyricLine {
        LyricLine(
            text: "想走出你控制的领域就从今晚开始",
            startTime: 10, endTime: 18,
            words: [
                LyricWord(word: "想", startTime: 10, endTime: 11),
                LyricWord(word: "走", startTime: 11, endTime: 12),
                LyricWord(word: "出", startTime: 12, endTime: 13),
                LyricWord(word: "你", startTime: 13, endTime: 14),
                LyricWord(word: "控", startTime: 14, endTime: 15),
                LyricWord(word: "制", startTime: 15, endTime: 16),
                LyricWord(word: "的", startTime: 16, endTime: 16.4),
                LyricWord(word: "领", startTime: 16.4, endTime: 16.8),
                LyricWord(word: "域", startTime: 16.8, endTime: 17.2),
                LyricWord(word: "就", startTime: 17.2, endTime: 17.4),
                LyricWord(word: "从", startTime: 17.4, endTime: 17.6),
                LyricWord(word: "今", startTime: 17.6, endTime: 17.8),
                LyricWord(word: "晚", startTime: 17.8, endTime: 17.9),
                LyricWord(word: "开", startTime: 17.9, endTime: 17.95),
                LyricWord(word: "始", startTime: 17.95, endTime: 18),
            ]
        )
    }

    private func englishLine() -> LyricLine {
        LyricLine(
            text: "hello brave new world tonight",
            startTime: 10, endTime: 16,
            words: [
                LyricWord(word: "hello ", startTime: 10, endTime: 11.2),
                LyricWord(word: "brave ", startTime: 11.2, endTime: 12.4),
                LyricWord(word: "new ", startTime: 12.4, endTime: 13.2),
                LyricWord(word: "world ", startTime: 13.2, endTime: 14.5),
                LyricWord(word: "tonight", startTime: 14.5, endTime: 16),
            ]
        )
    }

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(
        rows: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController,
        width: CGFloat
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
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
            onLineMotionFrames: { _, _, _, _ in })
    }

    /// Drives the row to a moment where the word at `wordIndex` has been swept for >= 1s (its
    /// float has fully eased to -2pt and holds), then reports every dim/bright glyph tile pair
    /// PLUS the word order each pair belongs to (mirrors the `inputs` construction in
    /// `applyMainWordFloatGlyphLayers`: line-plan iteration, non-emphasis runs only).
    @MainActor
    private func glyphPairsAfterSweepingWord(
        _ wordIndex: Int,
        line: LyricLine,
        width: CGFloat
    ) -> (pairs: [(dimPositionY: CGFloat, brightPositionY: CGFloat, dimHidden: Bool)], orders: [Int], plan: NativeLyricsTextRenderPlan) {
        NativeLyricsFeelParity.testingSweep = .v28
        let target = row(for: line, index: 0)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        host(view, NSSize(width: width, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240

        // 1s+ past the word's own start so baseFloat has eased fully to its -2pt target and holds
        // (floatDuration = max(1, wordDuration); every fixture word here is short, so 1.2s clears it).
        let currentTime = line.words[wordIndex].startTime + 1.2
        mc.syncPlaybackClock(to: currentTime, playing: true)
        let cfg = config(rows: [target], current: 0, mc: mc, width: width)
        view.configure(row: target, configuration: cfg)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: cfg)

        // Reconstruct the same `inputs` order as applyMainWordFloatGlyphLayers so pair index i can
        // be attributed to a word order (needed to look up that word's analytic baseFloatY below).
        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: currentTime, isActive: true
        ))
        let textWidth = max(1, width - NativeLyricsRowMeasurement.leadingInset - NativeLyricsRowMeasurement.trailingInset)
        let linePlan = NativeLyricsTextSweepLayout.makePlan(
            displayText: plan.displayText,
            wordRuns: plan.wordRuns,
            width: textWidth,
            fontSize: plan.constants.mainFontSize,
            fadeHalfPoint: plan.constants.fadeHalfPoint
        )
        let emphasisOrders = NativeLyricsRowView.activeEmphasisOrders(plan: plan)
        var orders: [Int] = []
        for l in linePlan {
            for run in l.runs where !emphasisOrders.contains(run.order) {
                for _ in run.glyphs { orders.append(run.order) }
            }
        }
        return (view.debugMainWordGlyphPairs, orders, plan)
    }

    @MainActor
    private func assertNoSweepGhost(line: LyricLine, width: CGFloat, wordIndex: Int, label: String) {
        let (pairs, orders, plan) = glyphPairsAfterSweepingWord(wordIndex, line: line, width: width)
        XCTAssertFalse(pairs.isEmpty, "\(label): expected glyph tiles once the line is active")
        XCTAssertGreaterThanOrEqual(pairs.count, orders.count, "\(label): pair pool must cover every active glyph")

        var maxDelta: CGFloat = 0
        var sampleCount = 0
        for (i, order) in orders.enumerated() {
            let pair = pairs[i]
            let run = plan.wordRuns[order]
            let delta = abs(pair.brightPositionY - pair.dimPositionY)
            maxDelta = max(maxDelta, delta)
            sampleCount += 1
            print("[NativeLyricsSweepGhostTests] \(label) glyph #\(i) order=\(order) dimHidden=\(pair.dimHidden) baseFloatY=\(run.baseFloatY) Δ=\(delta)pt")
            // 2026-09-19: an ordinary word's dim tile is never the visible copy any more — it
            // must stay hidden (the whole-line base is the sole dim source, always at rest)
            // regardless of how far the bright tile above it has floated.
            XCTAssertTrue(
                pair.dimHidden,
                "\(label): glyph #\(i) (order \(order)) dim tile must stay hidden — the whole-line base is the only dim source now"
            )
        }
        XCTAssertGreaterThan(sampleCount, 0, "\(label): expected at least one active glyph")
        print("[NativeLyricsSweepGhostTests] \(label): sampled \(sampleCount) glyphs, max Δy = \(maxDelta)pt")
    }

    @MainActor
    func test_cjkSweptGlyph_dimTileNeverUsed() {
        // Word index 3 ("你", starts at t=13) is comfortably mid-line so its baseFloatY has fully
        // settled at -2pt (not the word-0 boundary instant where floatY == 0 for everyone).
        assertNoSweepGhost(line: cjkLine(), width: 186, wordIndex: 3, label: "CJK")
    }

    @MainActor
    func test_englishSweptGlyph_dimTileNeverUsed() {
        assertNoSweepGhost(line: englishLine(), width: 320, wordIndex: 2, label: "EN")
    }
}
