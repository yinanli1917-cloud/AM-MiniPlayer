/**
 * [INPUT]: Depends on MusicMiniPlayerCore's NativeLyricsRowView, LyricsLayerRendererConfiguration
 * [OUTPUT]: Regression tests for the dim-base/bright-glyph line-wrap width race
 * [POS]: Test module — stage bundle 3i item 3 (trailing-line CJK ghost)
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Stage bundle 3i item 3 (founder report, 2026-09-18): a blurred duplicate copy of the
// SECOND VISUAL LINE of a Chinese lyric row, offset downward ~10pt, seen on nanopod://debug/
// rowdump evidence (rowdump_1/2/3.txt, read in full before writing this). The row in the
// evidence is row-level (no per-word timing) yet carries per-glyph floating tiles — but the
// dump's "string=" field truncates to the first 8 characters (NativeLyricsRowView.rowDumpLines,
// `string.prefix(8)`), so "dim-base only shows line 1" was a DISPLAY ARTIFACT of the dump, not
// evidence the dim-base's actual layer content is missing line 2 — that theory does not hold
// once the truncation is accounted for.
//
// The real structural hazard, found by reading the two independent width sources side by side:
//   - The dim base (`applyFloatingHiddenBase`) wraps against `contentTextWidth(configuration)`
//     — `configuration.rowWidth` minus insets, KNOWN at configure() time, documented at its own
//     declaration as "the single source of truth ... never bounds.width, which can be stale/
//     zero on a fresh view [or] pooled one before layout() runs".
//   - The bright per-glyph sweep layout (`mainSweepLinePlan`, feeding `applyMainWordFloatGlyphLayers`
//     as the SAME text's second, per-character rendering) wraps against
//     `mainBrightTextLayer.bounds.width` — exactly the quantity the dim-base's own doc comment
//     warns is unsafe. `bounds` is set by `layout()` (an AppKit layout pass, `layoutSubtreeIfNeeded()`
//     or a scheduled commit), a DIFFERENT call than `configure()`. Under a dropped frame or any
//     ordering where a playback-phase update (`updatePlaybackPhase`) runs before the pending
//     layout pass catches the view's bounds up to a newly configured `rowWidth`, the two systems
//     wrap the SAME text against DIFFERENT widths — matching the founder's own observation that
//     these glitches show up more under system load (dropped frames = exactly this ordering).
//
// This test drives the real NativeLyricsRowView through that exact ordering (reconfigure at a
// narrower width WITHOUT giving AppKit a layout pass first, so `bounds` stays stale at the wide
// value) and shows the resulting divergence: the dim base (correctly wrapped at the NEW, narrow
// width) now carries line-2 text with NO bright/floating counterpart at all — the bright glyph
// layout, still using the stale wide bounds, sees no wrap at all — so line 2 renders as
// dim-only ink (opacity 0.35, no bright overlay to compensate), which is exactly the "blurred
// duplicate" signature.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsTrailingLineWidthRaceTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor override func tearDown() {
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

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                    isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(row target: LayerBackedLyricRow, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: [target], currentIndex: 0, anchorY: 200, rowWidth: width,
            renderedIndices: [0], accumulatedHeights: [0: 72], lineTargetIndices: [:],
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

    /// 12-character CJK line with word-level timing (matches the rowdump evidence shape: a
    /// synced line with per-word timestamps, long enough to wrap at a normal panel width).
    private func cjkLine() -> LyricLine {
        let chars = ["每", "颗", "心", "都", "有", "值", "得", "期", "待", "的", "成", "分"]
        var words: [LyricWord] = []
        var t: TimeInterval = 0
        for c in chars {
            words.append(LyricWord(word: c, startTime: t, endTime: t + 0.3))
            t += 0.3
        }
        return LyricLine(text: chars.joined(), startTime: 0, endTime: t, words: words)
    }

    @MainActor
    func test_reconfigureAtNarrowerWidthWithoutLayoutPass_dimBaseWrapsButBrightGlyphsDoNot() {
        let line = cjkLine()
        let target = row(for: line, index: 0)
        let wideWidth: CGFloat = 360   // fits all 12 CJK glyphs on one line
        let narrowWidth: CGFloat = 160 // forces a 2-line wrap

        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: wideWidth, height: 96))
        host(view, NSSize(width: wideWidth, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240
        mc.syncPlaybackClock(to: 1.0, playing: true)

        // Step 1: configure + a REAL layout pass at the wide width — establishes a settled,
        // single-line baseline (both dim base and bright glyphs agree: one line).
        let wideConfig = config(row: target, mc: mc, width: wideWidth)
        view.configure(row: target, configuration: wideConfig)
        view.frame = NSRect(x: 0, y: 0, width: wideWidth, height: view.measuredHeight(width: wideWidth))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: wideConfig)

        XCTAssertEqual(view.debugMainTextLayerString?.contains("\n"), false,
            "sanity: at the wide width the line must NOT wrap")

        // Step 2: reconfigure at the NARROW width — matches what `configure()` alone does in
        // production (it does not itself force a layout pass) — but deliberately do NOT call
        // `layoutSubtreeIfNeeded()` afterward, simulating a dropped/delayed frame where AppKit's
        // own layout pass for the new width has not run yet by the time the playback-phase
        // update fires. `view.frame`/`bounds` therefore stay at the OLD (wide) size.
        let narrowConfig = config(row: target, mc: mc, width: narrowWidth)
        view.configure(row: target, configuration: narrowConfig)
        // Deliberately skipped: view.frame = ...; view.layoutSubtreeIfNeeded()
        _ = view.updatePlaybackPhase(configuration: narrowConfig)

        let dimBaseWrapLineCount = (view.debugMainTextLayerString ?? "").components(separatedBy: "\n").count
        let brightGlyphCount = view.debugVisibleBrightWordGlyphCount
        // Distinct Y bands among the bright per-glyph tiles == how many VISUAL LINES the bright
        // layout thinks this row occupies. Bucket width (12pt) folds the within-line float noise
        // of an actively-sweeping word (a few points around its rest Y) without folding together
        // two genuinely different visual lines (this fixture's own line pitch is ~24-26pt).
        let brightYBands = Set(view.debugMainWordGlyphPairs.map { ($0.brightPositionY / 12).rounded() }).count

        print("[3i-item3] after narrow reconfigure WITHOUT layout pass: " +
              "dimBaseString=\(String(describing: view.debugMainTextLayerString)) " +
              "dimBaseWrapLineCount=\(dimBaseWrapLineCount) brightGlyphCount=\(brightGlyphCount) " +
              "brightYBands=\(brightYBands) brightYs=\(view.debugMainWordGlyphPairs.map(\.brightPositionY)) " +
              "viewFrame=\(view.frame) mainTextLayerFrame=\(view.debugMainTextLayerFrame)")

        // FIX: the dim base (narrow width, correctly wrapped into 3 lines by contentTextWidth)
        // and the bright per-glyph sweep layout must AGREE on how many visual lines this row
        // occupies — both now read from the exact same width source
        // (`contentTextWidth(configuration)`), so the bright layout must also see 3 lines, not
        // stay stuck on the stale wide bounds' single line. Before the fix, brightYBands stayed
        // at 1 while dimBaseWrapLineCount was already 3 — the divergence that left the dim
        // base's newly-revealed trailing lines with no bright tile drawn over them at all (a
        // dim-only, blurred-looking duplicate of the row's own trailing text).
        XCTAssertEqual(brightYBands, dimBaseWrapLineCount,
            "FIX: bright per-glyph layout must see the SAME number of visual lines (\(brightYBands)) " +
            "as the dim base's own wrap (\(dimBaseWrapLineCount)) — a mismatch means the dim base's " +
            "trailing line(s) render as unfloated dim-only ink with no bright tile ever drawn over " +
            "them (the reported blurred duplicate line)")
    }
}
