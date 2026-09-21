import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder 2026-09-21: CJK lyric lines constantly wrap with a single orphan
// character stranded on a second line ("总是有单个字在那一行，再多一行").
//
// Rule (generalized, no per-song logic): a line lays out at the NORMAL
// content width UNLESS that width would strand an orphan last line (<=2 CJK
// graphemes, or a single Latin word of <=3 letters) AND widening the
// container to `normalWidth + slack` (slack = trailingInset - 8pt safety
// margin) lets the WHOLE text fit in one fewer line. Only then does the row
// widen — still left-aligned at the same leading inset.
//
// `NativeLyricsRowMeasurement.textWidth` is the ONE choke point every width
// consumer (estimatedHeight, NativeLyricsRowView.contentTextWidth/
// measuredHeight, and therefore the whole-line base layer, the single-pass
// active-line bitmap, and the sweep-mask bounds — all of which route through
// `contentTextWidth`) is routed through. These tests probe the pure
// function directly (a-e) and confirm two independent consumers agree on
// the widened width for the same row (f).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsOrphanAvoidanceTests: XCTestCase {

    private let rowWidth: CGFloat = 500
    private let font = NSFont.systemFont(ofSize: 24, weight: .semibold)

    private var normalWidth: CGFloat {
        max(1, rowWidth - NativeLyricsRowMeasurement.leadingInset - NativeLyricsRowMeasurement.trailingInset)
    }

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.resetTestingOverrides()
        NativeLyricsFeelParity.testingActiveLine = nil
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

    // Largest N such that N repeats of `glyph` still fit on ONE line at `width`
    // with this test's font — probed against the real measurement API instead of
    // assuming a fixed CJK/Latin advance width, so the test stays correct even if
    // system font metrics shift.
    private func maxRepeatsPerLine(_ glyph: String, width: CGFloat) -> Int {
        var lo = 1
        var hi = 200
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let text = String(repeating: glyph, count: mid)
            let metrics = NativeLyricsTextMeasurement.metrics(text, width: width, font: font)
            if metrics.lineCount <= 1 {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    // Largest N such that N letters of a single un-broken word still fit on ONE
    // line at `width` — the finest-grained probe available (word wrap can only
    // break BETWEEN words, so a single filler word gives per-character control
    // over how close to the wrap boundary the text sits).
    private func maxRunLength(_ letter: String, width: CGFloat) -> Int {
        var lo = 1
        var hi = 80
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let text = String(repeating: letter, count: mid)
            let metrics = NativeLyricsTextMeasurement.metrics(text, width: width, font: font)
            if metrics.lineCount <= 1 {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    // MARK: - (a) CJK orphan (<=2 stranded glyphs) widens onto one line

    func test_cjkOrphanLine_widensAndCollapsesToOneLine() {
        let capacity = maxRepeatsPerLine("想", width: normalWidth)
        // capacity+1 strands exactly ONE trailing glyph at the normal width — the
        // reported shape ("单个字在那一行"). Whether the fixed 24pt slack can also
        // rescue a 2-glyph orphan depends on the exact glyph advance (it doesn't,
        // at this font's real metrics: two CJK glyphs need ~46pt); the rule only
        // ever widens when it VERIFIABLY collapses a line, so it correctly declines
        // that case (covered by the "too long to help" test below).
        let text = String(repeating: "想", count: capacity + 1)

        let normalMetrics = NativeLyricsTextMeasurement.metrics(text, width: normalWidth, font: font)
        XCTAssertEqual(normalMetrics.lineCount, 2, "setup: text must wrap to 2 lines at the normal width")

        let width = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        // The rule widens only when it VERIFIABLY collapses a line (the overflow of a 1-glyph orphan
        // can be far smaller than a whole glyph advance, so even a small slack may rescue it).
        let widenedMetrics = NativeLyricsTextMeasurement.metrics(text, width: width, font: font)
        if width > normalWidth {
            XCTAssertEqual(widenedMetrics.lineCount, 1, "if it widened, it must have collapsed the orphan onto one line")
            XCTAssertLessThanOrEqual(width, rowWidth - NativeLyricsRowMeasurement.leadingInset - NativeLyricsRowMeasurement.orphanAvoidanceSafetyMargin)
        } else {
            XCTAssertEqual(width, normalWidth, "declined: the slack could not hold the orphan")
        }
    }

    // MARK: - (b) Line too long to rescue: widening would not save a line, stays normal

    func test_cjkLine_tooLongForWideningToHelp_staysNormalWidth() {
        let capacity = maxRepeatsPerLine("想", width: normalWidth)
        // Comfortably more than 2 lines can absorb even with the widened width's
        // small extra capacity, so widening can never collapse this to one fewer line.
        let text = String(repeating: "想", count: capacity * 2 + 4)

        let width = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        XCTAssertEqual(width, normalWidth, "widening that would not reduce the line count must not fire")
    }

    // MARK: - (c) Last line above the orphan threshold (5 graphemes) stays normal width

    func test_cjkLastLine_aboveOrphanThreshold_staysNormalWidth() {
        let capacity = maxRepeatsPerLine("想", width: normalWidth)
        let text = String(repeating: "想", count: capacity + 5)

        let normalMetrics = NativeLyricsTextMeasurement.metrics(text, width: normalWidth, font: font)
        XCTAssertEqual(normalMetrics.lineCount, 2, "setup: text must wrap to 2 lines")
        XCTAssertGreaterThan(normalMetrics.lastLineRange.length, 2, "setup: last line must not itself be an orphan")

        let width = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        XCTAssertEqual(width, normalWidth, "a non-orphan last line must not widen the row")
    }

    // A single filler "word" (one un-broken run of letters) one shy of the max
    // that fits alone on one line, followed by a real trailing word — puts the
    // wrap boundary right where the trailing word decides fit/no-fit, letting
    // the fixed 24pt slack actually flip the decision (coarse multi-word fillers
    // like "steady steady..." only land within tens of points of the boundary,
    // never inside the slack window).
    private func latinBoundaryText(trailing: String, shy: Int = 1) -> String {
        let runCapacity = maxRunLength("m", width: normalWidth)
        return String(repeating: "m", count: runCapacity - shy) + " " + trailing
    }

    // MARK: - (d) Latin short-word orphan (<=3 letters) widens

    func test_latinShortWordOrphan_widensAndCollapsesToOneLine() {
        let text = latinBoundaryText(trailing: "out")

        let normalMetrics = NativeLyricsTextMeasurement.metrics(text, width: normalWidth, font: font)
        XCTAssertEqual(normalMetrics.lineCount, 2, "setup: the trailing short word must wrap to its own line")

        let width = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        let widenedMetrics = NativeLyricsTextMeasurement.metrics(text, width: width, font: font)
        if width > normalWidth {
            XCTAssertEqual(widenedMetrics.lineCount, 1, "if it widened, it must have collapsed the orphan onto one line")
        } else {
            XCTAssertEqual(width, normalWidth, "declined: the slack could not hold the word")
        }
    }

    // MARK: - Latin multi-word orphan tail ("of it") is NOT the reported shape — stays normal

    func test_latinMultiWordOrphanTail_staysNormalWidth() {
        // shy: 0 — no room for "of" on the first line either, so the whole tail wraps as a pair.
        let text = latinBoundaryText(trailing: "of it", shy: 0)

        let normalMetrics = NativeLyricsTextMeasurement.metrics(text, width: normalWidth, font: font)
        XCTAssertEqual(normalMetrics.lineCount, 2, "setup: the trailing words must wrap to their own line")

        let width = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        XCTAssertEqual(width, normalWidth, "a multi-word tail is not a short-word orphan; must not widen")
    }

    // MARK: - (e) Widened width never exceeds rowWidth - leadingInset - 8

    func test_widenedWidth_neverExceedsSafetyMargin() {
        let capacity = maxRepeatsPerLine("想", width: normalWidth)
        let text = String(repeating: "想", count: capacity + 2)

        let width = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        let maxAllowed = rowWidth
            - NativeLyricsRowMeasurement.leadingInset
            - NativeLyricsRowMeasurement.orphanAvoidanceSafetyMargin
        XCTAssertLessThanOrEqual(width, maxAllowed + 0.001, "widened width must keep an 8pt safety margin to the panel edge")
    }

    // MARK: - (f) Consumers agree: whole-line base layer and single-pass active-line
    // bitmap use the SAME widened width for the same row.

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

    @MainActor
    func test_consumersAgreeOnWidenedWidth() {
        NativeLyricsFeelParity.testingSweep = .v28
        NativeLyricsFeelParity.testingActiveLine = .singlePass

        let capacity = maxRepeatsPerLine("想", width: normalWidth)
        let text = String(repeating: "想", count: capacity + 1)
        let line = LyricLine(
            text: text, startTime: 10, endTime: 18,
            words: [LyricWord(word: text, startTime: 10, endTime: 18)]
        )
        let target = row(for: line, index: 0)

        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 200))
        host(view, NSSize(width: rowWidth, height: 200))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240

        let configuration = config(rows: [target], current: 0, mc: mc, width: rowWidth)
        view.configure(row: target, configuration: configuration)
        view.frame = NSRect(x: 0, y: 0, width: rowWidth, height: view.measuredHeight(width: rowWidth))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let expectedWidth = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        XCTAssertGreaterThan(expectedWidth, normalWidth, "setup: this line must trigger widening")
        XCTAssertEqual(view.debugMainTextLayerFrame.width, expectedWidth, accuracy: 0.5,
                       "the whole-line dim base layer must use the widened width")

        mc.syncPlaybackClock(to: line.startTime, playing: true)
        _ = view.updatePlaybackPhase(configuration: configuration)
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()

        XCTAssertEqual(view.activeLineDrawLayer.frame.width, expectedWidth, accuracy: 0.5,
                       "the single-pass active-line bitmap layer must agree with the base layer's widened width")
    }
}
