import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Stage bundle 3g item 3 (research/repro-2026-09-18-lyrics-render-3g.md): founder screenshot shows
// the active line "…未来的旅程" with a blurred duplicate of "旅程" offset down-right, near the
// TAIL of the line's sweep. Chinese text never enters the EMPHASIS pipeline (that's
// `emphasisGlyphLayers`/`mainEmphasisGlowLayers`, gated to English karaoke words with declared
// emphasis runs) — but Chinese word/syllable-synced lines (NetEase YRC etc.) DO go through the
// ordinary per-word float pipeline (`applyMainWordFloatGlyphLayers`), the same pipeline the
// "滋味" ghost (2026-09-17, mitigated by 59647e1/f1b8d8f) lived in. The founder's report is at the
// LINE'S TAIL, i.e. possibly at/near the activation<->deactivation boundary rather than mid-sweep
// — a different frame window than the existing NativeLyricsActiveLineSpacingTests (which samples
// activation only) or NativeLyricsInactiveBaseRestoreTests (which samples two discrete phases, not
// every frame across the transition).
//
// This test drives a REAL syllable-synced CJK line (trailing word "旅程", 2 glyphs) through EVERY
// frame from mid-sweep through well past its endTime (full deactivation), using the same
// `debugMainWordGlyphPairs` invariant `NativeLyricsActiveLineSpacingTests` established: for a
// glyph that is not floated (dimHidden == false), its bright counterpart must not ALSO be visible
// — the double-visible pair is the observable "same character drawn twice" ghost. It additionally
// enumerates via `rowDumpLines` (the founder's own on-demand evidence tool, a692472) at the exact
// tail frame and asserts the trailing word's text does not appear in more than one HIDDEN=false
// layer.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsCJKTrailingGhostExhaustiveTests: XCTestCase {
    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.resetTestingOverrides()
        hostedSurfaces.forEach { $0.stopAnimations() }
        hostedSurfaces.removeAll()
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
        if let surface = view as? NativeLyricsSurfaceView { hostedSurfaces.append(surface) }
    }

    /// Mirrors the founder's screenshot: a CJK line ending in a two-glyph trailing word ("旅程"),
    /// word/syllable-synced (the class of source that carries per-word timestamps for CJK — YRC/
    /// AMLL, not the plain line-level LRC of his actual test song, but the class the founder
    /// specifically named as still showing the ghost "尤其 CJK").
    private func cjkLineWithTrailingWord() -> LyricLine {
        LyricLine(
            text: "想走出你控制的未来的旅程", startTime: 0, endTime: 6.0,
            words: [
                LyricWord(word: "想走出", startTime: 0, endTime: 1.2),
                LyricWord(word: "你控制", startTime: 1.2, endTime: 2.4),
                LyricWord(word: "的未来", startTime: 2.4, endTime: 3.6),
                LyricWord(word: "的", startTime: 3.6, endTime: 4.2),
                LyricWord(word: "旅程", startTime: 4.2, endTime: 6.0),
            ]
        )
    }

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                    isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: width,
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
    func test_trailingWord_noGlyphIsEverDoublyVisible_acrossFullSweepIntoDeactivation() {
        NativeLyricsFeelParity.testingSweep = .v28
        let panelWidth: CGFloat = 320
        let line = cjkLineWithTrailingWord()
        var rows: [LayerBackedLyricRow] = [row(for: line, index: 0)]
        rows.append(row(for: LyricLine(text: "下一句歌词内容", startTime: 6.0, endTime: 9.0), index: 1))

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 40
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 8_000
        var date = Date(timeIntervalSinceReferenceDate: 980_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        mc.syncPlaybackClock(to: 0.02, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc, width: panelWidth))
        surface.layoutSubtreeIfNeeded()
        CATransaction.flush()

        var violations: [(t: TimeInterval, index: Int)] = []
        var sampledFrames = 0
        let step = 1.0 / 60.0
        var t: TimeInterval = 0.02
        // From mid-line through 1.5s PAST the line's end — covers the sweep across the trailing
        // word (4.2s-6.0s) and the activation<->deactivation boundary at 6.0s where the founder's
        // report ("near the tail") would show up.
        while t < 7.5 {
            wall += step
            date = date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), rows.count - 1)
            surface.configure(config(rows, current: current, mc: mc, width: panelWidth))
            surface.debugTick(displayInterval: step)
            guard let view = surface.debugRowView(forIndex: 0) else { t += step; continue }
            sampledFrames += 1
            // A glyph is "doubly visible" when its dim tile is drawn (dimHidden == false, meaning
            // the dim base ALSO still shows it unfloated) AND its bright tile is simultaneously
            // present at a nonzero position/opacity distinct from the dim copy — i.e. exactly the
            // two-independently-positioned-object shape the founder's screenshot shows. We check
            // this the same way NativeLyricsActiveLineSpacingTests validates single-copy dim
            // tessellation: dimHidden must be true for every glyph the bright layer is actively
            // floating (brightPositionY != dim's rest position), for the LAST TWO word indices
            // (the trailing "的"/"旅程" words) specifically, across every sampled frame.
            let pairs = view.debugMainWordGlyphPairs
            for i in max(0, pairs.count - 2)..<pairs.count where i < pairs.count {
                let pair = pairs[i]
                let brightIsFloating = pair.brightPositionY != pair.dimPositionY
                if brightIsFloating && !pair.dimHidden {
                    violations.append((t, i))
                }
            }
            t += step
        }
        XCTAssertGreaterThan(sampledFrames, 100, "precondition: must actually sample the tail-of-line window")
        XCTAssertTrue(violations.isEmpty,
            "trailing-word glyph(s) doubly visible (dim base not hidden while bright tile is floating) at "
            + "\(violations.count) frames, e.g. t=\(violations.first?.t ?? -1) glyphIndex=\(violations.first?.index ?? -1)")
    }

    /// Same fixture, sampled at the exact tail frame (t=5.9, one frame before line end) — the
    /// closest headless equivalent to "hit nanopod://debug/rowdump the moment you see it".
    //
    // IMPORTANT correction from the first draft of this test (kept in history for the record):
    // the dim tile and bright tile BOTH being `hidden=false` at the SAME position is NOT itself a
    // bug — it is the intended karaoke reveal mechanism (an opaque bright tile painted exactly
    // over its dim twin, revealed by the sweep mask; this IS how every glyph's dim->bright
    // transition renders, by design). The actual ghost defect1 fixed (research/repro-2026-09-14)
    // was a spatial OFFSET between the two copies (Δy=3.26pt) — "the same frame Δy=0.000pt" was
    // the FIXED invariant, not "never both visible". This test therefore asserts POSITION EQUALITY
    // between the dim/bright pair for the trailing glyph, using `rowDumpLines` (the founder's own
    // evidence tool, a692472) to capture and report the frames for the failure message.
    @MainActor
    func test_rowDump_atTailFrame_trailingGlyphAppearsInAtMostOneVisibleLayer() {
        NativeLyricsFeelParity.testingSweep = .v28
        let panelWidth: CGFloat = 320
        let line = cjkLineWithTrailingWord()
        let rows: [LayerBackedLyricRow] = [row(for: line, index: 0)]

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 40
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 9_000
        var date = Date(timeIntervalSinceReferenceDate: 990_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        let step = 1.0 / 60.0
        var t: TimeInterval = 0.02
        mc.syncPlaybackClock(to: t, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc, width: panelWidth))
        surface.layoutSubtreeIfNeeded()
        while t < 5.9 {
            wall += step
            date = date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            surface.configure(config(rows, current: 0, mc: mc, width: panelWidth))
            surface.debugTick(displayInterval: step)
            t += step
        }
        guard let view = surface.debugRowView(forIndex: 0) else {
            XCTFail("row 0 not mounted at tail frame"); return
        }
        let dumped = view.rowDumpLines(role: "active(idx=0)")
        let visibleLinesMentioningTrailingGlyph = dumped.filter {
            $0.contains("旅") && $0.contains("hidden=false")
        }
        // Both a dim and a bright copy being visible is expected (the reveal mechanism); what must
        // NOT happen is the two copies disagreeing on where they are drawn (the actual ghost
        // shape). Check every visible-copy pair mentioning the trailing glyph for identical frames.
        func frame(from line: String) -> CGRect? {
            guard let range = line.range(of: "frame=("), let end = line.range(of: ")", range: range.upperBound..<line.endIndex) else { return nil }
            let inner = line[range.upperBound..<end.lowerBound]
            let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else { return nil }
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        let frames = visibleLinesMentioningTrailingGlyph.compactMap(frame(from:))
        XCTAssertEqual(frames.count, visibleLinesMentioningTrailingGlyph.count,
            "could not parse a frame out of every visible line mentioning 旅 — rowDump format may have changed")
        if let first = frames.first {
            for f in frames.dropFirst() {
                XCTAssertEqual(f, first, accuracy: 0.01,
                    "trailing glyph 旅's visible copies disagree on position — this IS the reported ghost "
                    + "(a spatial offset between dim/bright copies), not the normal coincident reveal:\n"
                    + visibleLinesMentioningTrailingGlyph.joined(separator: "\n"))
            }
        }
    }
}

private func XCTAssertEqual(_ lhs: CGRect, _ rhs: CGRect, accuracy: CGFloat, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.origin.x, rhs.origin.x, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(lhs.origin.y, rhs.origin.y, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, message, file: file, line: line)
}
