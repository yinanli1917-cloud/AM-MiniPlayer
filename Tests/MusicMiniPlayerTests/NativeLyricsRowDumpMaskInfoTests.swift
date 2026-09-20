import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Coordinator follow-up (item B, 2026-09-19): every prior `rowDumpLines()` field could look
// perfectly normal (opacity 1, string present, not hidden) while the karaoke MASK itself was the
// thing wrong — a nil mask, or a gradient parked at full-reveal, reads on screen as "整行全亮"
// with nothing else in the dump to explain it. This pins that the dump now reports:
//   - `mainBrightTextLayer`'s own `.mask` (class/frame/locations when it is the sweep gradient),
//   - each visible per-run (wrapped-line) sweep mask layer's frame + wavefront X,
//   - each visible bright word-glyph tile's OWN mask (expected nil; a non-nil value is itself
//     the anomaly a future report needs).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsRowDumpMaskInfoTests: XCTestCase {

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

    private func row(_ line: LyricLine, index: Int = 0) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
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
    func test_rowDumpLines_includesMainSweepMaskAndTileMaskInfo() {
        let line = LyricLine(
            text: "hello brave world", startTime: 0, endTime: 3,
            words: [
                LyricWord(word: "hello ", startTime: 0, endTime: 1),
                LyricWord(word: "brave ", startTime: 1, endTime: 2),
                LyricWord(word: "world", startTime: 2, endTime: 3),
            ]
        )
        let target = row(line)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        host(view, NSSize(width: 320, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240
        mc.syncPlaybackClock(to: 1.4, playing: true)
        let cfg = config([target], current: 0, mc: mc)
        view.configure(row: target, configuration: cfg)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: view.measuredHeight(width: 320))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: cfg)

        let dump = view.rowDumpLines(role: "active(idx=0)").joined(separator: "\n")
        print(dump)

        XCTAssertTrue(
            dump.contains("mainBrightTextLayer.mask"),
            "dump must report mainBrightTextLayer's own mask state"
        )
        XCTAssertTrue(
            dump.contains(".mask = nil") || dump.contains("mainBrightWordGlyphLayers"),
            "dump must report per-glyph bright tile mask state when tiles are mounted"
        )
    }
}
