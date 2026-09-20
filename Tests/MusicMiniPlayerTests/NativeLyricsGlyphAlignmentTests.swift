import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 2026-09-19 coordinator follow-up ("下雨天" real-device report: "点点雨似渗出眼泪",唱到「出」
// 时暗底的「眼泪」整体比亮字块偏右约 1/3 字，扫掠边界处还有一条竖纹" — a horizontal desync between
// the per-glyph BRIGHT tile (positioned from `NativeLyricsTextSweepLayout`'s
// `layoutManager.boundingRect(forGlyphRange:in:)`, an INK-BOUNDS API) and where the SAME
// `NSLayoutManager` would place that glyph via `lineFragmentRect(forGlyphAt:).origin.x +
// location(forGlyphAt:).x` (an ADVANCE/BASELINE-ORIGIN API) — the two CAN legitimately disagree
// for glyphs with side bearings, and the founder's report of drift accumulating toward the end of
// the line is exactly the shape a per-glyph ACCUMULATED side-bearing error would produce.
//
// This is pure-code instrumentation + a pure-code assertion — no device needed to run it. It
// drives a REAL `NativeLyricsRowView` through REAL AppKit text layout (the same
// `NativeLyricsTextSweepLayout.makeUnifiedBuild` production code path uses), then compares the
// two APIs against each other for every glyph of an active, actively-sweeping line.
//
// `NativeLyricsRowView.debugGlyphAlignmentSamples` and `debugPerGlyphAlignmentDump()` (wired into
// `rowDumpLines`) expose the same two x values for the founder to capture on a real device
// (font/contentsScale/screen-scaling can differ there in ways this synthetic harness cannot
// reproduce) — this test only proves the MODEL-level formulas agree (or documents where they
// don't) in a controlled, deterministic environment.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsGlyphAlignmentTests: XCTestCase {
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
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
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
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

    /// 8-character CJK line, one character per word (matches "点点雨似渗出眼泪"'s shape).
    private func cjk8Line() -> LyricLine {
        let chars = ["点", "点", "雨", "似", "渗", "出", "眼", "泪"]
        var t: TimeInterval = 10
        var words: [LyricWord] = []
        for c in chars {
            words.append(LyricWord(word: c, startTime: t, endTime: t + 0.4))
            t += 0.4
        }
        return LyricLine(text: chars.joined(), startTime: 10, endTime: t, words: words)
    }

    /// 13-character CJK line, no spaces, single combined word run (matches the founder's "只有你
    /// 能带我走向未来的旅程" 13-字无空格 report shape).
    private func cjk13Line() -> LyricLine {
        let text = "只有你能带我走向未来的旅程"
        return LyricLine(
            text: text, startTime: 10, endTime: 12,
            words: [LyricWord(word: text, startTime: 10, endTime: 12)]
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

    @MainActor
    private func glyphAlignmentSamples(
        line: LyricLine, width: CGFloat, atTime currentTime: TimeInterval
    ) -> [NativeLyricsRowView.DebugGlyphAlignmentSample] {
        let target = row(for: line, index: 0)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        host(view, NSSize(width: width, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240
        mc.syncPlaybackClock(to: currentTime, playing: true)
        let cfg = config(rows: [target], current: 0, mc: mc, width: width)
        view.configure(row: target, configuration: cfg)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: cfg)
        return view.debugGlyphAlignmentSamples ?? []
    }

    /// Core assertion: for every glyph of an actively-sweeping line, the per-glyph tile's own
    /// `frame.minX` (what `NativeLyricsTextSweepLayout` positioned it from — the ink-bounds API)
    /// must equal the SAME `NSLayoutManager`'s advance/baseline-origin API
    /// (`lineFragmentRect(forGlyphAt:).origin.x + location(forGlyphAt:).x`) within a sub-pixel
    /// tolerance. A real, non-trivial mismatch here — not assumed, not device-only — would be
    /// exactly the founder's reported drift, and would show up as a growing delta toward the end
    /// of the line (accumulated side-bearing error) rather than a constant offset.
    @MainActor
    private func assertGlyphAlignment(line: LyricLine, width: CGFloat, label: String) {
        let currentTime = (line.words.last?.startTime ?? line.startTime) + 0.05
        let samples = glyphAlignmentSamples(line: line, width: width, atTime: currentTime)
        XCTAssertFalse(samples.isEmpty, "\(label): expected at least one glyph sample")

        var maxDelta: CGFloat = 0
        var deltas: [CGFloat] = []
        for sample in samples {
            XCTAssertFalse(sample.layoutManagerX.isNaN, "\(label): char \"\(sample.char)\" has no resolvable glyph range")
            let delta = abs(sample.tileFrameMinX - sample.layoutManagerX)
            deltas.append(delta)
            maxDelta = max(maxDelta, delta)
        }
        print("[NativeLyricsGlyphAlignmentTests] \(label): deltas=\(deltas.map { String(format: "%.3f", $0) })")
        XCTAssertLessThanOrEqual(
            maxDelta, 0.5,
            "\(label): max |tileFrame.minX − layoutManagerX| = \(maxDelta)pt across \(samples.count) glyphs — "
                + "the two NSLayoutManager APIs disagree by more than half a point, which is model-level "
                + "evidence for the founder's reported horizontal drift"
        )
    }

    @MainActor
    func test_cjk8CharLine_tileFrameMatchesLayoutManagerAdvance() {
        assertGlyphAlignment(line: cjk8Line(), width: 250, label: "CJK-8")
    }

    @MainActor
    func test_cjk13CharNoSpaceLine_tileFrameMatchesLayoutManagerAdvance() {
        assertGlyphAlignment(line: cjk13Line(), width: 186, label: "CJK-13-nospace")
    }

    @MainActor
    func test_englishLine_tileFrameMatchesLayoutManagerAdvance() {
        assertGlyphAlignment(line: englishLine(), width: 250, label: "EN")
    }
}
