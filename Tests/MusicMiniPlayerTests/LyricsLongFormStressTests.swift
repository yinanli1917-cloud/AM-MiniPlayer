import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Long-form EDGE — 500+ rows, a megabyte-class single line, CJK/emoji mix.
//
// Layout and caches must stay bounded by the VISIBLE window, not by the
// song's line count. A 520-row ballad must not mount 520 native views,
// must not grow the reuse pool, and must not make text measurement
// unbounded. The 08-25 crash class also shows up here: a long display
// array vs a shorter source must still fall back, never trap.
//
// Headless. Founder rule 2026-08-21.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsLongFormStressTests: XCTestCase {

    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        hostedSurfaces.forEach { $0.stopAnimations() }
        hostedSurfaces.removeAll()
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    private let longLineCount = 520

    private func megaLineText() -> String {
        // Super-long single row: CJK + latin + emoji, well past a wrap.
        let unit = "超长一行混排 lyric line 🎵🎶 日本語ハングルไทย ✨ "
        return String(repeating: unit, count: 40) // ~1600+ scalars
    }

    private func longSource(includingMegaAt index: Int) -> [LyricLine] {
        (0..<longLineCount).map { i in
            let s = TimeInterval(i) * 2
            let text = i == index ? megaLineText() : "long-form line \(i) 词"
            return LyricLine(text: text, startTime: s, endTime: s + 2)
        }
    }

    private func rows(from source: [LyricLine]) -> [LayerBackedLyricRow] {
        let displayLines = source.enumerated().map { i, line in
            DisplayLyricLine(id: "L\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
        }
        return LyricLayerRowBuilder.makeRows(
            from: displayLines,
            sourceLines: source,
            firstRealLyricIndex: 0
        )
    }

    func test_builder_fiveHundredPlusRows_indexInvariantsHold() {
        let source = longSource(includingMegaAt: 17)
        let built = rows(from: source)
        XCTAssertEqual(built.count, longLineCount)
        XCTAssertEqual(built[17].sourceLine.text.count, megaLineText().count)
        for (i, row) in built.enumerated() {
            XCTAssertEqual(row.index, i)
            XCTAssertEqual(row.displayLine.sourceIndex, i)
            XCTAssertEqual(row.sourceLine.text, source[i].text)
            XCTAssertFalse(row.preludeEndTime.isNaN)
        }
    }

    func test_renderPlan_fiveHundredPlusRows_totalHeightIsLinearAndFinite() {
        let source = longSource(includingMegaAt: 3)
        let plan = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: source,
            firstRealLyricIndex: 0,
            currentDisplayIndex: 260,
            anchorY: 300,
            rowSpacing: 6,
            defaultRowHeight: 36
        ))
        XCTAssertEqual(plan.rows.count, longLineCount)
        XCTAssertEqual(plan.renderedIndices.count, longLineCount)
        XCTAssertTrue(plan.rows.indices.contains(plan.activeDisplayIndex))
        let expected = CGFloat(longLineCount) * 36 + CGFloat(longLineCount - 1) * 6
        XCTAssertEqual(plan.totalHeight, expected, accuracy: 0.5)
        XCTAssertLessThan(plan.totalHeight, 50_000, "height must stay linear in row count, not explode")
        XCTAssertGreaterThan(plan.totalHeight, 10_000)
    }

    func test_visibleSelector_andRenderCache_stayBoundedToWindowNotSongLength() {
        let all = Array(0..<longLineCount)
        let visible = NativeLyricsVisibleRowSelector.visibleIndices(
            allIndices: all, currentIndex: 260, activeTargetIndices: [260], radius: 12
        )
        XCTAssertLessThanOrEqual(visible.count, 25, "radius 12 around one index is ≤25 rows, not 520")
        XCTAssertTrue(visible.allSatisfy { all.contains($0) })

        let source = longSource(includingMegaAt: 0)
        let plan = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: source,
            firstRealLyricIndex: 0,
            currentDisplayIndex: 260,
            anchorY: 300
        ))
        var cache = NativeLyricsRenderCache()
        let first = cache.reconcile(rows: plan.rows, width: 320, showTranslation: false)
        XCTAssertEqual(first.mountedRowCount, longLineCount)
        let second = cache.reconcile(rows: plan.rows, width: 320, showTranslation: false)
        XCTAssertEqual(second.reusedRowCount, longLineCount, "identical re-reconcile must reuse every key, not grow")
        XCTAssertEqual(second.mountedRowCount, 0)
        XCTAssertEqual(second.unmountedRowCount, 0)
    }

    func test_megaCJKEmojiLine_measurementIsFiniteAndWraps() {
        NativeLyricsTextMeasurement.debugMeasureCount = 0
        let font = NSFont.systemFont(ofSize: 17)
        let metrics = NativeLyricsTextMeasurement.metrics(megaLineText(), width: 280, font: font)
        XCTAssertGreaterThan(metrics.height, 1)
        XCTAssertLessThan(metrics.height, 20_000, "a wrapped mega-line must not report unbounded height")
        XCTAssertGreaterThan(metrics.lineCount, 4, "the mega-line must actually wrap")
        XCTAssertFalse(metrics.height.isNaN)
        XCTAssertFalse(metrics.height.isInfinite)
        XCTAssertEqual(NativeLyricsTextMeasurement.debugMeasureCount, 1)
    }

    func test_displayLongerThanSource_onALongSong_builderFallsBackNeverTraps() {
        // 520 stale display rows vs 8 source lines — shrink window at long-form scale.
        let source = (0..<8).map { i in
            LyricLine(text: "src \(i)", startTime: TimeInterval(i), endTime: TimeInterval(i) + 1)
        }
        let displayLines: [DisplayLyricLine] = (0..<longLineCount).map { i in
            DisplayLyricLine(
                id: "stale-\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1,
                line: LyricLine(text: "stale \(i)", startTime: TimeInterval(i), endTime: TimeInterval(i) + 1)
            )
        }
        let built = LyricLayerRowBuilder.makeRows(
            from: displayLines,
            sourceLines: source,
            firstRealLyricIndex: 0
        )
        XCTAssertEqual(built.count, longLineCount)
        XCTAssertEqual(built[0].sourceLine.text, "src 0")
        XCTAssertEqual(built[7].sourceLine.text, "src 7")
        XCTAssertEqual(built[8].sourceLine.text, "stale 8", "past-the-end must fall back to the display line")
        XCTAssertEqual(built[519].sourceLine.text, "stale 519")
    }

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        if let surface = view as? NativeLyricsSurfaceView {
            hostedSurfaces.append(surface)
        }
    }

    @MainActor
    private func config(
        _ rows: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "Long Form", artist: "A", album: "Al", duration: 1200),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: true, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    @MainActor
    func test_hostedSurface_fiveHundredPlusRows_mountsVisibleWindowNotTheWholeSong() {
        let built = rows(from: longSource(includingMegaAt: 17))
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 1200
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 4_000
        var date = Date(timeIntervalSinceReferenceDate: 720_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        // Jump the focal row: head → mid → mega-line → tail. Mounted count
        // must stay in the visible-radius ballpark the whole time.
        for current in [0, 17, 260, 519] {
            let t = TimeInterval(current) * 2 + 0.4
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            surface.configure(config(built, current: current, mc: mc))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<4 {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
            XCTAssertLessThanOrEqual(surface.debugMountedRowCount, 40,
                                     "520-row song must not mount more than the visible+warmup window at index \(current)")
            // Visible-window prune (A-rule stage 2 / 2026-08-26 stress bug):
            // same-track seeks used to keep visualStates for every visited
            // index (55 at 260, 68 at 519). Focal band is visible-radius×4
            // (=48); a jump to a new neighborhood drops the old band.
            XCTAssertLessThanOrEqual(
                surface.debugVisualStateCount,
                52,
                "index \(current): visualStates must prune to a focal band, not accumulate across seeks (was 55@260 / 68@519)"
            )
            XCTAssertLessThanOrEqual(surface.debugReusePoolCount, 80, "index \(current)")
            if let sem = surface.debugNativeSemanticIndex {
                XCTAssertTrue(built.indices.contains(sem))
            }
        }
    }
}
