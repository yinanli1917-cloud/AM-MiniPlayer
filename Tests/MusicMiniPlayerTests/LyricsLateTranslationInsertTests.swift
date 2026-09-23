import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Translation sidecar — late hot-insert (A-rule 2026-08-26).
//
// Toggle stress already proved showTranslation does not clear the word axis.
// This pins the OTHER seam: original already on screen, translation arrives
// at 3.1s (or any later instant) and merges in place. Display stays content,
// words/start/end stay put, hosted surface keeps semantic index + sweep.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsLateTranslationInsertTests: XCTestCase {

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

    func test_isTranslationOnlyWriteback_trueWhenOnlyTranslationChanges() {
        let before = [
            wordLine("hello there world", start: 0),
            wordLine("karaoke continues here", start: 3)
        ]
        let after = LyricsService.mergingTranslations(
            into: before,
            eligibleIndices: [0, 1],
            translatedTexts: ["你好世界", "卡拉OK继续"]
        )
        XCTAssertTrue(LyricsService.isTranslationOnlyWriteback(previous: before, next: after))
        XCTAssertEqual(after[0].words.map(\.word), before[0].words.map(\.word))
        XCTAssertEqual(after[1].words.map(\.startTime), before[1].words.map(\.startTime))
    }

    func test_isTranslationOnlyWriteback_falseOnTextOrWordAxisChange() {
        let before = [wordLine("hello there world", start: 0)]
        let differentText = [wordLine("goodbye there world", start: 0, translation: "再见")]
        XCTAssertFalse(LyricsService.isTranslationOnlyWriteback(previous: before, next: differentText))
        XCTAssertFalse(LyricsService.isTranslationOnlyWriteback(previous: [], next: before))
        XCTAssertFalse(LyricsService.isTranslationOnlyWriteback(previous: before, next: before))
    }

    func test_fakeClock_2_9sOriginalThen_3_1sSidecarIsLegal() {
        XCTAssertTrue(
            LyricsOriginalDeliverySLA.shouldPublishOriginal(
                elapsed: 2.9, hasOriginal: true, translationReady: false
            )
        )
        XCTAssertTrue(
            LyricsOriginalDeliverySLA.translationHotInsertAllowed(
                elapsed: 3.1, originalAlreadyPublished: true
            )
        )
    }

    @MainActor
    func test_applyLateTranslationWriteback_keepsContentAndWordAxis() {
        let temp = isolation.lyricsCache

        let title = "Late Insert \(UUID().uuidString.prefix(8))"
        let artist = "Sidecar Artist"
        let lines = (0..<6).map { i in
            wordLine("late row \(i) words here", start: TimeInterval(i) * 3)
        }
        temp.set(title: title, artist: artist, duration: 210, album: "Alb",
                 source: LyricsSource.netEase.rawValue, lines: lines, matchedDurationDiff: 0.1)

        let service = LyricsService.shared
        service.fetchLyrics(for: title, artist: artist, duration: 210, album: "Alb",
                            persistentID: "late-insert", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content)
        XCTAssertFalse(service.lyrics.contains { $0.hasTranslation })
        let wordCounts = service.lyrics.map(\.words.count)
        let texts = service.lyrics.map(\.text)
        let songID = service.debugCurrentSongID
        let lineCount = service.lyrics.count
        XCTAssertNotNil(songID)

        let eligible = Array(service.lyrics.indices)
        let translated = eligible.map { "译\($0)" }
        let ok = service.applyLateTranslationWriteback(
            eligibleIndices: eligible,
            translatedTexts: translated,
            expectedSongID: songID,
            expectedLineCount: lineCount
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(service.displayState, .content, "sidecar must not demote content")
        XCTAssertFalse(service.displayState.isSearchPhase)
        XCTAssertEqual(service.lyrics.map(\.words.count), wordCounts)
        XCTAssertEqual(service.lyrics.map(\.text), texts)
        XCTAssertTrue(service.lyrics.allSatisfy(\.hasTranslation))
        XCTAssertEqual(service.lyrics[0].translation, "译0")
    }

    @MainActor
    func test_applyLateTranslationWriteback_rejectsSongChange() {
        let temp = isolation.lyricsCache

        let title = "Reject \(UUID().uuidString.prefix(8))"
        let lines = [wordLine("keep this axis intact", start: 0)]
        temp.set(title: title, artist: "A", duration: 180, album: "Alb",
                 source: LyricsSource.netEase.rawValue, lines: lines, matchedDurationDiff: 0.1)
        let service = LyricsService.shared
        service.fetchLyrics(for: title, artist: "A", duration: 180, album: "Alb",
                            persistentID: "reject-sid", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content)
        let before = service.lyrics
        XCTAssertFalse(
            service.applyLateTranslationWriteback(
                eligibleIndices: [0],
                translatedTexts: ["不该写入"],
                expectedSongID: "some-other-song",
                expectedLineCount: before.count
            )
        )
        XCTAssertEqual(service.lyrics.map(\.text), before.map(\.text))
        XCTAssertFalse(service.lyrics.contains { $0.hasTranslation })
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
    private func layerRows(translated: Bool) -> [LayerBackedLyricRow] {
        (0..<6).map { i in
            let lyric = wordLine(
                "insert row \(i) words here",
                start: TimeInterval(i) * 3,
                translation: translated ? "翻译第\(i)行" : nil
            )
            let dl = DisplayLyricLine(id: "t\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: lyric)
            return LayerBackedLyricRow(
                id: dl.id, index: i, displayLine: dl, sourceLine: lyric,
                isPrelude: false, preludeEndTime: lyric.endTime, interlude: nil
            )
        }
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 280, rowWidth: 320,
            renderedIndices: Array(rows.indices),
            accumulatedHeights: Dictionary(uniqueKeysWithValues: rows.map { ($0.index, CGFloat($0.index) * 40) }),
            lineTargetIndices: [:], lineInterval: 3, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "Late Insert", artist: "Sidecar", album: "Alb", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: true,
            suppressInitialMotion: true, pendingTranslationLineIndices: [], showTranslation: true,
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
    func test_hostedSurface_lateTranslationInsert_keepsSweepAndIndex() {
        let original = layerRows(translated: false)
        let withTranslation = layerRows(translated: true)
        XCTAssertEqual(original.map(\.id), withTranslation.map(\.id))
        XCTAssertEqual(original[2].sourceLine.words.count, withTranslation[2].sourceLine.words.count)

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 8_000
        var date = Date(timeIntervalSinceReferenceDate: 740_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        // Original on screen at t=2.9s of the fixture clock, mid line 2.
        let playback: TimeInterval = 7.4
        mc.syncPlaybackClock(to: playback, playing: true, at: date)
        surface.configure(config(original, current: 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<8 {
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.debugTick(displayInterval: 1.0 / 60.0)
        }
        let semanticBefore = surface.debugNativeSemanticIndex
        let sweepBefore = surface.debugRowView(forIndex: 2)?.debugLastMainAppliedProgress
        XCTAssertEqual(semanticBefore, 2)

        // Translation sidecar at elapsed 3.1s of the SLA fixture — same row ids.
        wall += 0.2
        date = date.addingTimeInterval(0.2)
        mc.syncPlaybackClock(to: playback, playing: true, at: date)
        surface.configure(config(withTranslation, current: 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.debugTick(displayInterval: 1.0 / 60.0)
        }

        XCTAssertEqual(surface.debugNativeSemanticIndex, semanticBefore, "hot-insert must not rebuild semantic index")
        if let sweep = surface.debugRowView(forIndex: 2)?.debugLastMainAppliedProgress {
            XCTAssertGreaterThanOrEqual(sweep, -0.01)
            XCTAssertLessThanOrEqual(sweep, 1.01)
            if let sweepBefore {
                XCTAssertGreaterThan(sweep, 0.05, "sweep must not reset to 0 when translation lands")
                XCTAssertEqual(sweep, sweepBefore, accuracy: 0.35)
            }
        }
        XCTAssertEqual(withTranslation[2].sourceLine.words.count, original[2].sourceLine.words.count)
    }
}
