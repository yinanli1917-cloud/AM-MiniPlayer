import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Translation-toggle EDGE — row-level and word-level, on/off × N.
//
// Writeback is a pure merge: it must fill translation text WITHOUT
// clearing the word timeline. The P1 display lock (same-song refetch
// blocked while content is on screen) must survive a toggle storm —
// flipping showTranslation is not a fetch, and must not become one.
//
// Headless, injected clocks. Founder rule 2026-08-21.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsTranslationToggleStressTests: XCTestCase {

    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []
    private var isolation: LyricsPipelineTestIsolation!
    private var savedShowTranslation: Bool?

    @MainActor
    override func setUp() {
        super.setUp()
        savedShowTranslation = LyricsService.shared.showTranslation
        isolation = LyricsPipelineTestIsolation()
    }

    // XCTest runs this before the synchronous tearDown below.
    override func tearDown() async throws {
        await isolation.tearDown()
        isolation = nil
        try await super.tearDown()
    }

    @MainActor
    override func tearDown() {
        hostedSurfaces.forEach { $0.stopAnimations() }
        hostedSurfaces.removeAll()
        hostWindow?.orderOut(nil)
        hostWindow = nil
        if let savedShowTranslation {
            LyricsService.shared.showTranslation = savedShowTranslation
        }
        super.tearDown()
    }

    private func wordLine(_ text: String, start: TimeInterval, translation: String? = nil) -> LyricLine {
        let tokens = text.split(separator: " ").map(String.init)
        let end = start + 3
        let slice = 3.0 / Double(max(tokens.count, 1))
        let words = tokens.enumerated().map { i, token in
            let s = start + slice * Double(i)
            return LyricWord(word: i == tokens.count - 1 ? token : token + " ", startTime: s, endTime: s + slice)
        }
        return LyricLine(text: text, startTime: start, endTime: end, words: words, translation: translation)
    }

    private func lineLevel(_ text: String, start: TimeInterval, translation: String? = nil) -> LyricLine {
        LyricLine(text: text, startTime: start, endTime: start + 4, translation: translation)
    }

    // ── Writeback must not clear the word axis ───────────────────────────

    func test_mergingTranslations_preservesWordTimeline_onWordAndLineLevelRows() {
        let base = [
            wordLine("hello there world", start: 0),
            lineLevel("plain line without words", start: 3),
            wordLine("karaoke continues here", start: 7)
        ]
        let wordAxisBefore = base.map { $0.words.map { ($0.word, $0.startTime, $0.endTime) } }
        let merged = LyricsService.mergingTranslations(
            into: base,
            eligibleIndices: [0, 1, 2],
            translatedTexts: ["你好世界", "普通一行", "卡拉OK继续"]
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].translation, "你好世界")
        XCTAssertEqual(merged[1].translation, "普通一行")
        XCTAssertEqual(merged[2].translation, "卡拉OK继续")
        for i in 0..<3 {
            XCTAssertEqual(merged[i].words.count, wordAxisBefore[i].count, "row \(i) word count")
            for (w, before) in zip(merged[i].words, wordAxisBefore[i]) {
                XCTAssertEqual(w.word, before.0)
                XCTAssertEqual(w.startTime, before.1, accuracy: 0.0001)
                XCTAssertEqual(w.endTime, before.2, accuracy: 0.0001)
            }
            XCTAssertEqual(merged[i].hasSyllableSync, base[i].hasSyllableSync)
            XCTAssertEqual(merged[i].text, base[i].text)
            XCTAssertEqual(merged[i].startTime, base[i].startTime, accuracy: 0.0001)
            XCTAssertEqual(merged[i].endTime, base[i].endTime, accuracy: 0.0001)
        }
        XCTAssertNil(base[0].translation, "merge must not mutate the input array")
    }

    func test_textRenderPlan_toggleShowTranslation_doesNotRewireWordRunsOrSweep() {
        let line = wordLine("shine through the night", start: 10, translation: "照亮黑夜")
        let on = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: 11.5, isActive: true, showTranslation: true
        ))
        let off = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: 11.5, isActive: true, showTranslation: false
        ))
        XCTAssertEqual(on.displayText, off.displayText)
        XCTAssertEqual(on.wordRuns.map(\.text), off.wordRuns.map(\.text))
        XCTAssertEqual(on.wordRuns.map(\.startTime), off.wordRuns.map(\.startTime))
        XCTAssertEqual(on.wordRuns.map(\.endTime), off.wordRuns.map(\.endTime))
        XCTAssertEqual(on.mainSweepProgress, off.mainSweepProgress, accuracy: 0.0001)
        XCTAssertNotNil(on.translation)
        XCTAssertNil(off.translation, "off must drop the translation plan, not the word axis")
        XCTAssertEqual(on.translation!.progress, on.mainSweepProgress, accuracy: 0.0001,
                       "word-level translation sweep must share the word-count progress")
    }

    func test_lineLevelTranslation_hasNoWordAxisToClear_andToggleIsIdempotent() {
        let line = lineLevel("line level lyric text", start: 0, translation: "逐行翻译")
        XCTAssertTrue(line.words.isEmpty)
        XCTAssertFalse(line.hasSyllableSync)
        for show in [true, false, true, false, true] {
            let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
                line: line, currentTime: 2, isActive: true, showTranslation: show
            ))
            XCTAssertTrue(plan.wordRuns.isEmpty || plan.wordRuns.allSatisfy { $0.startTime >= 0 })
            XCTAssertEqual(plan.displayText.isEmpty, false)
            if show {
                XCTAssertEqual(plan.translation?.text, "逐行翻译")
            } else {
                XCTAssertNil(plan.translation)
            }
        }
    }

    func test_renderCache_toggleStorm_invalidatesVisibilityButKeepsWordKeysStable() {
        let lyrics = [
            wordLine("first row words here", start: 0, translation: "第一行"),
            wordLine("second row words here", start: 3, translation: "第二行")
        ]
        let plan = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: lyrics, firstRealLyricIndex: 0, currentDisplayIndex: 0, anchorY: 100
        ))
        XCTAssertEqual(plan.rows[0].words.count, lyrics[0].words.count)
        var cache = NativeLyricsRenderCache()
        _ = cache.reconcile(rows: plan.rows, width: 220, showTranslation: true)
        var lastDecision: NativeLyricsRenderCacheDecision?
        for i in 0..<40 {
            lastDecision = cache.reconcile(rows: plan.rows, width: 220, showTranslation: i % 2 == 0)
        }
        // Last toggle flipped visibility → every row invalidated, none leaked extra mounts.
        XCTAssertEqual(lastDecision?.invalidatedRowCount, 2)
        XCTAssertEqual(lastDecision?.mountedRowCount, 0)
        XCTAssertEqual(lastDecision?.unmountedRowCount, 0)
        // Word axis on the plan rows is untouched by the visibility bit.
        XCTAssertEqual(plan.rows[0].words.map(\.word), lyrics[0].words.map(\.word))
        XCTAssertEqual(plan.rows[1].words.map(\.startTime), lyrics[1].words.map(\.startTime))
    }

    // ── P1 display lock must survive a translation toggle ────────────────

    @MainActor
    func test_p1DisplayLock_survivesTranslationToggleStorm_sameSongRefetchStillBlocked() {
        let temp = isolation.lyricsCache

        let service = LyricsService.shared
        let title = "Toggle Lock \(UUID().uuidString.prefix(8))"
        let artist = "Lock Artist"
        let words: [LyricLine] = (0..<8).map { i in
            wordLine("lock line \(i) words here", start: TimeInterval(i) * 3)
        }
        temp.set(title: title, artist: artist, duration: 210, album: "Alb",
                 source: LyricsSource.netEase.rawValue, lines: words, matchedDurationDiff: 0.1)

        service.fetchLyrics(for: title, artist: artist, duration: 210, album: "Alb",
                            persistentID: "toggle-lock", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content)
        XCTAssertTrue(service.lyrics.contains { $0.hasSyllableSync })
        let wordCounts = service.lyrics.map(\.words.count)

        for i in 0..<20 {
            service.showTranslation = i % 2 == 0
        }
        XCTAssertEqual(service.displayState, .content, "toggling translation must not demote content")
        XCTAssertEqual(service.lyrics.map(\.words.count), wordCounts, "toggle must not clear the word axis")
        XCTAssertFalse(service.displayState.isSearchPhase)

        // Same-song duration-correction refetch: P1 lock still holds after the storm.
        let worse = (0..<8).map { i in
            lineLevel("downgrade \(i)", start: TimeInterval(i) * 3)
        }
        temp.set(title: title, artist: artist, duration: 211, album: "Alb",
                 source: LyricsSource.lrclib.rawValue, lines: worse, matchedDurationDiff: 0.0)
        service.fetchLyrics(for: title, artist: artist, duration: 211, album: "Alb",
                            persistentID: "toggle-lock", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content)
        XCTAssertTrue(service.lyrics.contains { $0.hasSyllableSync },
                      "P1: translation toggle must not punch a hole in the display lock")
        XCTAssertFalse(service.lyrics.contains { $0.text.contains("downgrade") })
        XCTAssertEqual(service.lyrics.map(\.words.count), wordCounts)
    }

    // ── Hosted surface: toggle while a word-level line is sweeping ───────

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
    private func rows() -> [LayerBackedLyricRow] {
        (0..<6).map { i in
            let lyric = wordLine("toggle row \(i) words here", start: TimeInterval(i) * 3, translation: "翻译第\(i)行")
            let dl = DisplayLyricLine(id: "t\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: lyric)
            return LayerBackedLyricRow(
                id: dl.id, index: i, displayLine: dl, sourceLine: lyric,
                isPrelude: false, preludeEndTime: lyric.endTime, interlude: nil
            )
        }
    }

    @MainActor
    private func config(
        _ rowList: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController,
        showTranslation: Bool
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 3, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "Toggle", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: true, pendingTranslationLineIndices: [], showTranslation: showTranslation,
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
    func test_hostedSurface_translationToggleStorm_keepsSweepAndIndex() {
        let rowList = rows()
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 730_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let t: TimeInterval = 7.4 // mid line 2
        mc.syncPlaybackClock(to: t, playing: true, at: date)
        for n in 0..<24 {
            let show = n % 2 == 0
            surface.configure(config(rowList, current: 2, mc: mc, showTranslation: show))
            surface.layoutSubtreeIfNeeded()
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            surface.debugTick(displayInterval: 1.0 / 60.0)

            if let sem = surface.debugNativeSemanticIndex {
                XCTAssertTrue(rowList.indices.contains(sem), "n=\(n)")
            }
            if let view = surface.debugRowView(forIndex: 2), let applied = view.debugLastMainAppliedProgress {
                XCTAssertGreaterThanOrEqual(applied, -0.01, "n=\(n)")
                XCTAssertLessThanOrEqual(applied, 1.01, "n=\(n)")
            }
            XCTAssertEqual(rowList[2].sourceLine.words.count, 5)
            XCTAssertLessThanOrEqual(surface.debugReusePoolCount, 80)
        }
    }
}
