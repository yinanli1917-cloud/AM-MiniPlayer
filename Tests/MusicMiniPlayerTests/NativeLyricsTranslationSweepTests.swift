import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// "逐字歌词的翻译没有逐字遮罩了" — the word-level translation renders FULLY BRIGHT
// INSTANTLY instead of revealing left-to-right with the karaoke wavefront.
//
// Model-only tests pass (the plan computes a correct partial progress), so this
// drives the REAL surface and reads BOTH:
//   (A) the renderer's APPLIED sweep progress value, and
//   (B) the ACTUAL composited pixels (cacheDisplay) at two playback times. The MAIN
//       line's own karaoke sweep is the control: if MAIN reveals across time but the
//       TRANSLATION stays flat-bright, the translation mask is broken (and cacheDisplay
//       is proven mask-faithful in this setup). If BOTH stay flat, cacheDisplay is blind.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsTranslationSweepTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() { windows.forEach { $0.orderOut(nil) }; windows = []; super.tearDown() }

    @MainActor
    private func hostInWindow(_ view: NSView, size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        windows.append(w)
    }

    @MainActor
    private func translatedRows() -> [LayerBackedLyricRow] {
        let spans: [(TimeInterval, TimeInterval)] = [(0,3),(3,6),(6,9),(9,12),(12,15)]
        return spans.enumerated().map { i, s in
            let dur = (s.1 - s.0) / 3
            let line = LyricLine(
                text: "line \(i) words here now", startTime: s.0, endTime: s.1,
                words: [
                    LyricWord(word: "line ", startTime: s.0, endTime: s.0 + dur),
                    LyricWord(word: "\(i) words ", startTime: s.0 + dur, endTime: s.0 + 2 * dur),
                    LyricWord(word: "here now", startTime: s.0 + 2 * dur, endTime: s.1),
                ],
                translation: "翻译第\(i)行文字内容长一点方便看遮罩"
            )
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], currentIndex: Int,
                        mc: MusicController, pending: [Int] = [], translating: Bool = false) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = CGFloat(r.index) * 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: currentIndex, anchorY: 250, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 3, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: Set(pending), showTranslation: true,
            isTranslating: translating, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    // Drive a fresh surface to time `t`; active line is index 2, span (6,9). Return its row view.
    @MainActor
    private func driveTo(_ t: TimeInterval) -> (NativeLyricsSurfaceView, NativeLyricsRowView?) {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = translatedRows()
        mc.syncPlaybackClock(to: t, playing: true)
        surface.configure(config(rows: rows, currentIndex: 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        mc.syncPlaybackClock(to: t, playing: true)
        surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        return (surface, surface.debugRowView(forIndex: 2))
    }

    // ── GATE: translation sweep is word-timing-driven (contract core rule 3) ──
    // A LINE-LEVEL song has no word timeline; "sweeping" its translation degrades into one
    // gradient mask wiping the whole block — the exact violation core rule 3 forbids and the
    // regression the user reported twice. History: widened by cfb5308, fixed by cfc152c
    // (appliesTranslationSweep gated on hasSyllableSync), un-fixed by bare revert 7653221.

    @MainActor
    private func lineLevelRow(index: Int = 0) -> LayerBackedLyricRow {
        let line = LyricLine(
            text: "line level lyric text \(index)",
            startTime: TimeInterval(index * 10), endTime: TimeInterval(index * 10 + 10),
            translation: "逐行歌的翻译不该有扫掠遮罩"
        )
        let dl = DisplayLyricLine(id: "L\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                   isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    func test_lineLevelActiveRow_hasNoTranslationSweepOverlay() {
        let row = lineLevelRow()
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        mc.syncPlaybackClock(to: 2.0, playing: true)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        view.configure(row: row, configuration: config(rows: [row], currentIndex: 0, mc: mc))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(
            view.debugTranslationSweepEngaged,
            "line-level song: the active row's translation must render statically at the active opacity — a sweep here becomes the whole-block gradient wipe (core rule 3)"
        )
        XCTAssertFalse(view.debugTranslationTextLayerHidden,
                       "the static translation itself must stay visible")
    }

    @MainActor
    func test_wordSyncedActiveRow_keepsTranslationSweepOverlay() {
        let rows = translatedRows()
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        mc.syncPlaybackClock(to: 7.5, playing: true)   // mid-line of index 2 (6..9)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        view.configure(row: rows[2], configuration: config(rows: rows, currentIndex: 2, mc: mc))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            view.debugTranslationSweepEngaged,
            "word-synced song: the translation must keep its word-timed sweep (user directive + contract Phase 5)"
        )
    }

    // ── Check A: renderer's applied translation sweep progress (value level) ──
    @MainActor
    func test_translation_appliedProgress_midLine() {
        let (_, active) = driveTo(7.5)
        XCTAssertNotNil(active)
        print("[SweepA] expected=\(String(describing: active?.debugLastTranslationExpectedProgress)) applied=\(String(describing: active?.debugLastTranslationAppliedProgress)) overlay=\(active?.debugLastTranslationBrightOverlayPresent ?? false)")
    }

    // ── Check B: actual pixels at EARLY vs LATE. Main line = cacheDisplay-fidelity control. ──
    @MainActor
    func test_translation_pixelSweep_earlyVsLate() {
        let cols = 12, rows = 16
        let (_, early) = driveTo(6.8)   // ~27% through the active line
        guard let earlyView = early, let earlyGrid = luminanceGrid(of: earlyView, cols: cols, rows: rows) else {
            return XCTFail("early capture failed")
        }
        let earlyTF = earlyView.debugTranslationTextLayerFrame
        let (_, late) = driveTo(8.6)    // ~87% through the active line
        guard let lateView = late, let lateGrid = luminanceGrid(of: lateView, cols: cols, rows: rows) else {
            return XCTFail("late capture failed")
        }
        print("[SweepB] rowBounds=\(earlyView.bounds) translationFrame=\(earlyTF)")
        printGrid("EARLY(t=6.8)", earlyGrid)
        printGrid("LATE(t=8.6)", lateGrid)
        // Sanity: capture is not blank.
        let earlyMax = earlyGrid.flatMap { $0 }.max() ?? 0
        XCTAssertGreaterThan(earlyMax, 0.03, "cacheDisplay captured blank — capture path wrong, not the sweep")
    }

    @MainActor
    private func printGrid(_ label: String, _ grid: [[Float]]) {
        print("[SweepB] --- \(label) ---")
        for (r, band) in grid.enumerated() {
            let n3 = max(1, band.count / 3)
            let left = band.prefix(n3).reduce(0, +) / Float(n3)
            let right = band.suffix(n3).reduce(0, +) / Float(n3)
            let cells = band.map { String(format: "%.2f", $0) }.joined(separator: " ")
            print(String(format: "  b%02d L=%.2f R=%.2f | %@", r, left, right, cells))
        }
    }

    @MainActor
    private func manyTranslatedRows(_ n: Int) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i * 3), e = TimeInterval(i * 3 + 3)
            let line = LyricLine(
                text: "line \(i) words here now", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "line ", startTime: s, endTime: s + 1),
                    LyricWord(word: "\(i) words ", startTime: s + 1, endTime: s + 2),
                    LyricWord(word: "here now", startTime: s + 2, endTime: e),
                ],
                translation: "翻译第\(i)行文字内容长一点方便看遮罩")
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    // Continuous playback: advance line by line so rows recycle, then capture a freshly-activated
    // line EARLY. A stale monotonic wavefront surviving reuse = right side already bright at ~16%.
    @MainActor
    func test_translation_pixelSweep_afterPlaybackAdvance() {
        let n = 12, targetIdx = 8
        let rows = manyTranslatedRows(n)
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true); mc.duration = 240; mc.isPlaying = true
        for i in 0...targetIdx {
            let t = TimeInterval(i * 3) + 0.5
            mc.syncPlaybackClock(to: t, playing: true)
            surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? i, mc: mc))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        }
        guard let active = surface.debugRowView(forIndex: targetIdx) else { return XCTFail("no active row \(targetIdx)") }
        print("[Advance] targetIdx=\(targetIdx) semantic=\(surface.debugNativeSemanticIndex ?? -1) applied=\(String(describing: active.debugLastTranslationAppliedProgress)) expected=\(String(describing: active.debugLastTranslationExpectedProgress)) overlay=\(active.debugLastTranslationBrightOverlayPresent)")
        guard let grid = luminanceGrid(of: active, cols: 12, rows: 16) else { return XCTFail("capture failed") }
        printGrid("ADVANCE line\(targetIdx) EARLY(~16%)", grid)
        let maxLum = grid.flatMap { $0 }.max() ?? 0
        XCTAssertGreaterThan(maxLum, 0.03, "capture blank")
    }

    // Real word-synced + translated lines from the user's cache ("Free Drink", NetEase): many words,
    // CJK-heavy, translations long enough to wrap. The exact shape the app renders.
    @MainActor
    private func realRows(translations: Bool = true) -> [LayerBackedLyricRow] {
        let real: [(String, TimeInterval, TimeInterval, [(String, TimeInterval, TimeInterval)], String)] = [
            ("Just Summer Night 流れるビル街 追い越し", 19.330000000000002, 28.89, [("Just ", 19.330000000000002, 19.76), ("Summer ", 19.76, 20.16), ("Night ", 20.16, 21.73), ("流", 21.73, 22.43), ("れ", 22.43, 22.67), ("る", 22.67, 23.35), ("ビ", 23.35, 23.75), ("ル", 23.75, 24.45), ("街 ", 24.45, 26.650000000000002), ("追", 26.650000000000002, 27.05), ("い", 27.05, 27.310000000000002), ("越", 27.310000000000002, 27.5), ("し", 27.5, 28.89)], "Just Summer Night 街头高楼如水 徐徐经过"),
            ("今さら 照れてしまう", 29.04, 38.89, [("今", 29.04, 29.63), ("さ", 29.63, 29.91), ("ら ", 29.91, 31.63), ("照", 31.63, 31.88), ("れ", 31.88, 32.12), ("て", 32.12, 32.33), ("し", 32.33, 32.97), ("ま", 32.97, 33.36), ("う", 33.36, 34.209999999999994), ("程 ", 34.209999999999994, 36.25), ("Just ", 36.25, 37.199999999999996), ("Fallin' ", 37.199999999999996, 37.25), ("Love", 37.25, 38.89)], "时至今日 到了令人害羞的程度啊 Just Fallin' Love"),
            ("いつものように送るつもりでいたけれど", 39.8, 48.44, [("い", 39.8, 40.01), ("つ", 40.01, 40.29), ("も", 40.29, 40.669999999999995), ("の", 40.669999999999995, 40.9), ("よ", 40.9, 41.059999999999995), ("う", 41.059999999999995, 41.449999999999996), ("に", 41.449999999999996, 42.129999999999995), ("送", 42.129999999999995, 42.82), ("る", 42.82, 42.989999999999995), ("つ", 42.989999999999995, 43.279999999999994), ("も", 43.279999999999994, 43.69), ("り", 43.69, 43.89), ("で", 43.89, 44.29), ("い", 44.29, 44.51), ("た", 44.51, 45.779999999999994), ("け", 45.779999999999994, 46.39), ("れ", 46.39, 46.91), ("ど", 46.91, 48.44)], "一如既往 本打算为你送行"),
            ("\"Take me far away, tonight!\"君の言葉が", 49.43, 53.87, [("\"Take ", 49.43, 49.8), ("me ", 49.8, 49.91), ("far ", 49.91, 50.419999999999995), ("away, ", 50.419999999999995, 50.9), ("tonight!\"", 50.9, 51.809999999999995), ("君", 51.809999999999995, 52.4), ("の", 52.4, 52.68), ("言", 52.68, 53.349999999999994), ("葉", 53.349999999999994, 53.599999999999994), ("が", 53.599999999999994, 53.87)], "“今夜带我远走高飞吧！”你的话语"),
            ("今 懐かしく響いて", 53.9, 59.029999999999994, [("今 ", 53.9, 55.059999999999995), ("懐", 55.059999999999995, 55.79), ("か", 55.79, 56.07), ("し", 56.07, 56.37), ("く", 56.37, 56.529999999999994), ("響", 56.529999999999994, 56.89), ("い", 56.89, 58.459999999999994), ("て", 58.459999999999994, 59.029999999999994)], "现在令人怀念地在耳边响起"),
        ]
        return real.enumerated().map { i, t in
            let words = t.3.map { LyricWord(word: $0.0, startTime: $0.1, endTime: $0.2) }
            let line = LyricLine(text: t.0, startTime: t.1, endTime: t.2, words: words,
                                 translation: translations ? t.4 : nil)
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    // ASYNC ARRIVAL: line 1 goes active with NO translation yet (Apple Translation pending → loading
    // dots), main line sweeping. Then the translation arrives mid-line (grow-in). Does the sweep engage?
    @MainActor
    func test_translation_asyncArrival_midActiveLine() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true); mc.duration = 240; mc.isPlaying = true
        let t = 34.0
        // Phase 1: line 1 active, translation pending (awaiting) → dots; main sweeps.
        let pendingRows = realRows(translations: false)
        mc.syncPlaybackClock(to: t, playing: true)
        surface.configure(config(rows: pendingRows, currentIndex: 1, mc: mc, pending: [1], translating: true))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        // Phase 2: translation ARRIVES for the already-active line 1.
        let arrivedRows = realRows(translations: true)
        mc.syncPlaybackClock(to: t + 0.3, playing: true)
        surface.configure(config(rows: arrivedRows, currentIndex: surface.debugNativeSemanticIndex ?? 1, mc: mc, pending: [], translating: false))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }

        guard let active = surface.debugRowView(forIndex: 1) else { return XCTFail("no active row 1") }
        print("[Async] mainSweepApplied=\(active.debugLastAppliedActivePerRunSweep) transExpected=\(String(describing: active.debugLastTranslationExpectedProgress)) transApplied=\(String(describing: active.debugLastTranslationAppliedProgress)) transOverlay=\(active.debugLastTranslationBrightOverlayPresent)")
        print("[Async] rowBounds=\(active.bounds) transFrame=\(active.debugTranslationTextLayerFrame)")
        guard let grid = luminanceGrid(of: active, cols: 12, rows: 20) else { return XCTFail("capture failed") }
        printGrid("ASYNC line1 t=34.3", grid)
        XCTAssertGreaterThan(grid.flatMap { $0 }.max() ?? 0, 0.03, "capture blank")
    }

    // Real data, active line 1 (span 29.04-38.89) at t=34 (mid). Main sweeps (control =
    // debugLastAppliedActivePerRunSweep); does the translation sweep or go flat?
    @MainActor
    func test_translation_realData_freeDrink_line1() {
        let rows = realRows()
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true); mc.duration = 240; mc.isPlaying = true
        let t = 34.0
        mc.syncPlaybackClock(to: t, playing: true)
        surface.configure(config(rows: rows, currentIndex: 1, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        mc.syncPlaybackClock(to: t, playing: true)
        surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? 1, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        guard let active = surface.debugRowView(forIndex: 1) else { return XCTFail("no active row 1") }
        print("[Real] mainSweepApplied=\(active.debugLastAppliedActivePerRunSweep) transExpected=\(String(describing: active.debugLastTranslationExpectedProgress)) transApplied=\(String(describing: active.debugLastTranslationAppliedProgress)) transOverlay=\(active.debugLastTranslationBrightOverlayPresent)")
        print("[Real] rowBounds=\(active.bounds) transFrame=\(active.debugTranslationTextLayerFrame)")
        guard let grid = luminanceGrid(of: active, cols: 12, rows: 20) else { return XCTFail("capture failed") }
        printGrid("REAL line1 t=34", grid)
        XCTAssertGreaterThan(grid.flatMap { $0 }.max() ?? 0, 0.03, "capture blank")
    }

    // LINE-SYNCED path: segmentation (LyricsView.makeDisplayLyricLines line ~1983) builds split
    // lines with words:[] → hasSyllableSync=false → makeTranslationPlan forces translation
    // progress=1 (INSTANT full reveal). Reproduce that exact input: no-words line + translation.
    @MainActor
    private func lineSyncedRows() -> [LayerBackedLyricRow] {
        let spans: [(TimeInterval, TimeInterval)] = [(0,3),(3,6),(6,9),(9,12),(12,15)]
        return spans.enumerated().map { i, s in
            let line = LyricLine(text: "line \(i) sings a whole phrase now", startTime: s.0, endTime: s.1,
                                 words: [], translation: "翻译第\(i)行文字内容长一点方便看遮罩")
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    func test_translation_lineSynced_noWords_forcesFullBright() {
        let rows = lineSyncedRows()
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true); mc.duration = 240; mc.isPlaying = true
        let t = 7.4  // mid active line 2 (span 6-9)
        mc.syncPlaybackClock(to: t, playing: true)
        surface.configure(config(rows: rows, currentIndex: 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        mc.syncPlaybackClock(to: t, playing: true)
        surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        guard let active = surface.debugRowView(forIndex: 2) else { return XCTFail("no active row 2") }
        print("[LineSynced] mainSweepApplied=\(active.debugLastAppliedActivePerRunSweep) transExpected=\(String(describing: active.debugLastTranslationExpectedProgress)) transApplied=\(String(describing: active.debugLastTranslationAppliedProgress)) transOverlay=\(active.debugLastTranslationBrightOverlayPresent)")
        guard let grid = luminanceGrid(of: active, cols: 12, rows: 16) else { return XCTFail("capture failed") }
        printGrid("LINE-SYNCED line2 t=7.4", grid)
        // Regression gate: a line-synced translation must sweep gradually (in step with the main
        // line-level sweep), NOT pop to full reveal instantly. t=7.4 in the (6,9) line ≈ 0.47.
        guard let applied = active.debugLastTranslationAppliedProgress else { return XCTFail("no applied progress") }
        XCTAssertLessThan(applied, 0.9, "line-synced translation popped fully bright instantly (a5daf28 regression)")
        XCTAssertGreaterThan(applied, 0.1, "line-synced translation did not reveal at all")
    }

    // ROOT CAUSE PROOF: during the natural wave (a line change), the singing line's ACTIVE phase is
    // bound to the scroll wave's visual target (1e1ffbf), not the semantic index. So the active line
    // renders INACTIVE mid-wave (no sweep). The A/B seam forces the semantic binding; compare.
    @MainActor
    private func sampleActiveLineAfterLineChange(forceSemantic: Bool) -> (mainSweep: Bool, transApplied: CGFloat?, overlay: Bool) {
        NativeLyricsSurfaceView.debugForceSemanticVisualIndex = forceSemantic
        defer { NativeLyricsSurfaceView.debugForceSemanticVisualIndex = false }
        let rows = realRows()
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true); mc.duration = 240; mc.isPlaying = true
        // settle on line 0 (span 19.33-28.89)
        mc.syncPlaybackClock(to: 24.0, playing: true)
        surface.configure(config(rows: rows, currentIndex: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        // CHANGE to line 1 (span 29.04-38.89) → starts the natural wave; sample mid-wave immediately.
        mc.syncPlaybackClock(to: 34.0, playing: true)
        surface.configure(config(rows: rows, currentIndex: 1, mc: mc))
        for _ in 0..<2 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        let active = surface.debugRowView(forIndex: 1)
        return (active?.debugLastAppliedActivePerRunSweep ?? false,
                active?.debugLastTranslationAppliedProgress,
                active?.debugLastTranslationBrightOverlayPresent ?? false)
    }

    @MainActor
    func test_ROOT_activeLinePhaseBoundToScrollWaveNotSemantic() {
        let waveBound = sampleActiveLineAfterLineChange(forceSemantic: false)   // current (1e1ffbf)
        let semantic = sampleActiveLineAfterLineChange(forceSemantic: true)     // pre-1e1ffbf
        print("[ROOT] wave-bound (current): mainSweep=\(waveBound.mainSweep) transApplied=\(String(describing: waveBound.transApplied)) overlay=\(waveBound.overlay)")
        print("[ROOT] semantic  (proposed): mainSweep=\(semantic.mainSweep) transApplied=\(String(describing: semantic.transApplied)) overlay=\(semantic.overlay)")
        // No hard assert yet — this is a diagnostic to PROVE the divergence before any fix.
    }

    // LIVE reproduction: drive frame-by-frame at 1x real time through real line changes (the wave
    // activates, like the churn test). Every frame, check whether the SINGING line's translation sweep
    // is present. If it vanishes on many frames (during waves) under wave-binding but not under the
    // semantic seam, the intermittency ("有时候有有时候没有") is the phase↔wave coupling.
    @MainActor
    func test_ROOT_LIVE_translationSweepIntermittencyAcrossLineChanges() {
        func run(forceSemantic: Bool) -> (absent: Int, total: Int, transitions: Int) {
            NativeLyricsSurfaceView.debugForceSemanticVisualIndex = forceSemantic
            defer { NativeLyricsSurfaceView.debugForceSemanticVisualIndex = false }
            let rows = realRows()
            let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
            hostInWindow(surface, size: NSSize(width: 360, height: 600))
            let mc = MusicController(preview: true); mc.duration = 240; mc.isPlaying = true
            let frameInterval = 1.0 / 60.0
            mc.syncPlaybackClock(to: 20.0, playing: true)
            surface.configure(config(rows: rows, currentIndex: 0, mc: mc))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(frameInterval)) }
            var absent = 0, total = 0, transitions = 0, lastSem = -1
            let start = 29.0, dur = 21.0
            let frames = Int(dur / frameInterval)
            for i in 0..<frames {
                mc.syncPlaybackClock(to: start + Double(i) * frameInterval, playing: true)
                surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? 0, mc: mc))
                RunLoop.main.run(until: Date().addingTimeInterval(frameInterval))
                let sem = surface.debugNativeSemanticIndex ?? -1
                if sem != lastSem { transitions += 1; lastSem = sem }
                guard sem >= 1, sem <= 3, let active = surface.debugRowView(forIndex: sem) else { continue }
                total += 1
                if !active.debugLastTranslationBrightOverlayPresent || active.debugLastTranslationAppliedProgress == nil {
                    absent += 1
                }
            }
            return (absent, total, transitions)
        }
        let waveBound = run(forceSemantic: false)
        let semantic = run(forceSemantic: true)
        print("[LIVE] wave-bound (current):  singing-line translation ABSENT on \(waveBound.absent)/\(waveBound.total) frames, \(waveBound.transitions) transitions")
        print("[LIVE] semantic  (proposed):  singing-line translation ABSENT on \(semantic.absent)/\(semantic.total) frames, \(semantic.transitions) transitions")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 2026-07-11 recording repro (docs/defect-recordings/2026-07-11-defect3-handoff-flicker):
    //   Defect B — the newly-promoted line's translation arrives FULLY BRIGHT and stays frozen
    //     while the main line sweeps normally. Structural suspect: lastTranslationSweepWavefrontX
    //     is a monotonic max that survives every frame of the row's active life, so ONE overshoot
    //     frame (clock glitch / pre-layout wavefront) pins the mask at full reveal permanently.
    //   Defect A — rows flash active-style bright for 1-2 frames (2-3 times) BEFORE the scroll
    //     moves, staggered down the panel.
    // This drives REAL wrapped-CJK data at ~1x through two handoffs with a noisy clock and scans
    // the census: (B) applied progress must never exceed expected mid-line; (A) a row's bright
    // channels must show no short spike segment before its sustained active run.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Segments of `values` where value > threshold, as (start, length) pairs.
    private func spikeSegments(_ values: [CGFloat], threshold: CGFloat) -> [(start: Int, length: Int)] {
        var segs: [(Int, Int)] = []
        var runStart: Int?
        for (i, v) in values.enumerated() {
            if v > threshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                segs.append((s, i - s)); runStart = nil
            }
        }
        if let s = runStart { segs.append((s, values.count - s)) }
        return segs
    }

    /// A short (≤ maxLen) above-threshold segment separated from the NEXT segment by ≥ minGap
    /// clean frames = a pre-activation flash (defect A shape: on, off again, then the real run).
    private func preActivationFlashes(_ values: [CGFloat], threshold: CGFloat,
                                      maxLen: Int = 5, minGap: Int = 3) -> [(start: Int, length: Int)] {
        let segs = spikeSegments(values, threshold: threshold)
        guard segs.count >= 2 else { return [] }
        var flashes: [(Int, Int)] = []
        for i in 0..<(segs.count - 1) {
            let cur = segs[i], next = segs[i + 1]
            if cur.length <= maxLen && (next.start - (cur.start + cur.length)) >= minGap {
                flashes.append(cur)
            }
        }
        return flashes
    }

    // A deterministic noisy clock like the real SB clock (matches NativeLyricsRenderChurnTests).
    private func noisyClock(step i: Int, base: TimeInterval) -> TimeInterval {
        let jitter: TimeInterval = (i % 3 == 0) ? 0.30 : (i % 3 == 1 ? -0.28 : 0.0)
        return max(0, base + jitter)
    }

    @MainActor
    func test_LIVE_handoffs_translationMaskPinAndPreActivationFlash() {
        let rows = realRows()
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true); mc.duration = 240; mc.isPlaying = true

        // Warm up mid line 0 (span 19.33-28.89) so the surface settles before scoring.
        mc.syncPlaybackClock(to: 24.0, playing: true)
        surface.configure(config(rows: rows, currentIndex: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }

        surface.debugResetCensus()
        surface.debugCensusEnabled = true
        surface.debugSkipDedupe = true

        // Drive 27.0 → 45.0 at ~1x (handoffs at 29.04 and 39.8) with the noisy clock.
        let frameInterval = 1.0 / 60.0
        let frames = Int(18.0 / frameInterval)
        for i in 0..<frames {
            let base = 27.0 + Double(i) * frameInterval
            mc.syncPlaybackClock(to: noisyClock(step: i, base: base), playing: true)
            surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? 0, mc: mc))
            RunLoop.main.run(until: Date().addingTimeInterval(frameInterval))
        }

        var pinViolations: [String] = []
        var flashViolations: [String] = []
        for (idx, track) in surface.debugCensusByIndex.sorted(by: { $0.key < $1.key }) {
            let n = min(track.transBright.count, min(track.transExpected.count, track.transApplied.count))
            // Defect B: while the bright overlay is actually visible and the expected sweep is
            // mid-line, the applied progress must track it — never sit far above (the pin).
            for f in 0..<n {
                let exp = track.transExpected[f], app = track.transApplied[f]
                if track.transBright[f] > 0.5, exp > 0.05, exp < 0.8, app > exp + 0.25 {
                    pinViolations.append("idx=\(idx) frame=\(f) expected=\(String(format: "%.2f", exp)) applied=\(String(format: "%.2f", app))")
                }
            }
            // Defect A: short bright segment, dark gap, then the real run — on either bright channel.
            for (ch, name) in [(track.bright, "mainBright"), (track.transBright, "transBright")] {
                for flash in preActivationFlashes(ch, threshold: 0.5) {
                    flashViolations.append("idx=\(idx) ch=\(name) flashStart=\(flash.start) len=\(flash.length)")
                }
            }
        }
        let paints = surface.debugCensusByIndex.values.map(\.transBright.count).max() ?? 0
        print("[LiveHandoff] rows=\(surface.debugCensusByIndex.count) maxPaints=\(paints)")
        print("[LiveHandoff] PIN violations (defect B): \(pinViolations.count)")
        pinViolations.prefix(12).forEach { print("  ", $0) }
        print("[LiveHandoff] FLASH violations (defect A): \(flashViolations.count)")
        flashViolations.prefix(12).forEach { print("  ", $0) }
        // Dump the active rows' progress traces around each handoff for eyes-on diagnosis.
        for idx in [1, 2] {
            if let t = surface.debugCensusByIndex[idx] {
                let n = min(t.transExpected.count, t.transApplied.count)
                let firstActive = (0..<n).first { t.transBright[$0] > 0.5 } ?? 0
                let end = min(n, firstActive + 24)
                if firstActive < end {
                    print("idx=\(idx) transExpected[\(firstActive)..<\(end)]: " + t.transExpected[firstActive..<end].map { String(format: "%.2f", $0) }.joined(separator: " "))
                    print("idx=\(idx) transApplied [\(firstActive)..<\(end)]: " + t.transApplied[firstActive..<end].map { String(format: "%.2f", $0) }.joined(separator: " "))
                    print("idx=\(idx) transBright  [\(firstActive)..<\(end)]: " + t.transBright[firstActive..<end].map { String(format: "%.2f", $0) }.joined(separator: " "))
                }
            }
        }
        XCTAssertGreaterThan(paints, 200, "precondition: the drive must have painted")
        XCTAssertTrue(pinViolations.isEmpty, "translation sweep applied progress exceeded expected (full-reveal pin):\n\(pinViolations.prefix(20).joined(separator: "\n"))")
        XCTAssertTrue(flashViolations.isEmpty, "bright channel flashed before activation (handoff style flash):\n\(flashViolations.prefix(20).joined(separator: "\n"))")
    }

    // Variant with the REAL app's currentIndex coupling: LyricsView derives currentIndex from the
    // SAME jittery clock (time → line mapping), so at a boundary the CONFIG input itself flaps
    // N↔N+1 — harsher than feeding back the surface's own smoothed semantic index. Covers all
    // four handoffs of the real data. Hunts the defect-B pin under realistic input.
    @MainActor
    func test_LIVE_handoffs_realCurrentIndexCoupling_maskPin() {
        let rows = realRows()
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true); mc.duration = 240; mc.isPlaying = true

        func lineIndex(at t: TimeInterval) -> Int {
            var idx = 0
            for (i, r) in rows.enumerated() where t >= r.displayLine.line.startTime { idx = i }
            return idx
        }

        mc.syncPlaybackClock(to: 24.0, playing: true)
        surface.configure(config(rows: rows, currentIndex: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }

        surface.debugResetCensus()
        surface.debugCensusEnabled = true
        surface.debugSkipDedupe = true

        // 27.0 → 58.0 covers handoffs at 29.04, 39.8, 49.43, 53.9.
        let frameInterval = 1.0 / 60.0
        let frames = Int(31.0 / frameInterval)
        for i in 0..<frames {
            let noisy = noisyClock(step: i, base: 27.0 + Double(i) * frameInterval)
            mc.syncPlaybackClock(to: noisy, playing: true)
            surface.configure(config(rows: rows, currentIndex: lineIndex(at: noisy), mc: mc))
            RunLoop.main.run(until: Date().addingTimeInterval(frameInterval))
        }

        var pinViolations: [String] = []
        for (idx, track) in surface.debugCensusByIndex.sorted(by: { $0.key < $1.key }) {
            let n = min(track.transBright.count, min(track.transExpected.count, track.transApplied.count))
            for f in 0..<n {
                let exp = track.transExpected[f], app = track.transApplied[f]
                if track.transBright[f] > 0.5, exp > 0.05, exp < 0.8, app > exp + 0.25 {
                    pinViolations.append("idx=\(idx) frame=\(f) expected=\(String(format: "%.2f", exp)) applied=\(String(format: "%.2f", app))")
                }
            }
        }
        print("[RealCoupling] PIN violations (defect B): \(pinViolations.count)")
        pinViolations.prefix(16).forEach { print("  ", $0) }
        XCTAssertTrue(pinViolations.isEmpty, "translation sweep pinned above expected under real currentIndex coupling:\n\(pinViolations.prefix(20).joined(separator: "\n"))")
    }

    // cacheDisplay composites the layer-backed view (the pattern NativeLyricsBloomReproductionTests
    // uses). Reduce to a cols×rows mean-luminance grid (luminance premultiplied by alpha so
    // transparent gaps read as dark, only painted text contributes).
    @MainActor
    private func luminanceGrid(of view: NSView, cols: Int, rows: Int) -> [[Float]]? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }
        var grid = Array(repeating: Array(repeating: Float(0), count: cols), count: rows)
        var counts = Array(repeating: Array(repeating: 0, count: cols), count: rows)
        for y in 0..<h {
            let gr = min(rows - 1, y * rows / h)
            for x in 0..<w {
                let gc = min(cols - 1, x * cols / w)
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let lum = Float(0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent)
                    * Float(c.alphaComponent)
                grid[gr][gc] += lum
                counts[gr][gc] += 1
            }
        }
        for gr in 0..<rows { for gc in 0..<cols where counts[gr][gc] > 0 { grid[gr][gc] /= Float(counts[gr][gc]) } }
        return grid
    }
}
