import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder 2026-08-27 诊断批 #0: 逐字优先 + 回填升级必须真发生。
//
// Two invariants, independent of provider weather:
//   1. Word-level (syllable ≥30%) that is already in the foreground pool MUST
//      beat line-level, including a higher-scoring album-matched LRCLIB hit.
//   2. Line-level (or unsynced) on screen MUST launch authoritative backfill,
//      and a later word-level result MUST hot-switch the display. P1 freeze
//      still blocks demotion (word → line) so oscillation cannot return.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsWordLevelPriorityTests: XCTestCase {

    private func makeLines(_ seed: [String], wordLevel: Bool = false) -> [LyricLine] {
        seed.enumerated().map { index, text in
            let start = Double(index) * 4.0
            let end = start + 3.5
            let words: [LyricWord] = wordLevel
                ? text.split(separator: " ").enumerated().map { wordIndex, word in
                    let wordStart = start + Double(wordIndex) * 0.25
                    return LyricWord(word: String(word), startTime: wordStart, endTime: wordStart + 0.2)
                }
                : []
            return LyricLine(text: text, startTime: start, endTime: end, words: words)
        }
    }

    private func completeLines(prefix: String, wordLevel: Bool) -> [LyricLine] {
        makeLines(
            (1...12).map { "\(prefix) corroborated lyric line \($0) through the night" },
            wordLevel: wordLevel
        )
    }

    // MARK: - Invariant A: word-level in the pool wins

    func testTitleMatchedWordLevelInPoolBeatsHigherScoringAlbumMatchedLineLevel() {
        let fetcher = LyricsFetcher.shared
        let lineLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: completeLines(prefix: "line", wordLevel: false),
            source: .lrclib,
            score: 92,
            kind: .synced,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.1
        )
        let wordLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: completeLines(prefix: "line", wordLevel: true),
            source: .amll,
            score: 61,
            kind: .synced,
            albumMatched: false,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        let selected = fetcher.selectBestResult(
            from: [lineLevel, wordLevel],
            songDuration: 48
        )

        XCTAssertEqual(selected?.source, .amll, "预算内到手的逐字必须优先于更高分的行级")
        XCTAssertTrue(
            selected?.lyrics.contains(where: { $0.hasSyllableSync }) == true,
            "selected lyrics must remain word-level"
        )
    }

    func testNetEaseWordLevelBeatsLRCLIBLineLevelWhenBothTitleMatched() {
        let fetcher = LyricsFetcher.shared
        let lineLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: completeLines(prefix: "shared", wordLevel: false),
            source: .lrclibSearch,
            score: 88,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.0
        )
        let wordLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: completeLines(prefix: "shared", wordLevel: true),
            source: .netEase,
            score: 70,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.4
        )

        let selected = fetcher.selectBestResult(
            from: [lineLevel, wordLevel],
            songDuration: 48
        )
        XCTAssertEqual(selected?.source, .netEase)
        XCTAssertTrue(selected?.lyrics.contains(where: { $0.hasSyllableSync }) == true)
    }

    // MARK: - Invariant B: backfill must keep racing after a line-level hit

    func testAuthoritativeBackfillDoesNotCancelOnLineLevelSyncedHit() {
        let fetcher = LyricsFetcher.shared
        let lineLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: completeLines(prefix: "line", wordLevel: false),
            source: .lrclib,
            score: 80,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.1
        )
        XCTAssertFalse(
            fetcher.shouldCancelAuthoritativeBackfill(after: lineLevel),
            "line-level LRCLIB must not cancel AMLL/NE/QQ still in the backfill group"
        )
    }

    func testAuthoritativeBackfillMayCancelOnceWordLevelIdentityLands() {
        let fetcher = LyricsFetcher.shared
        let wordLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: completeLines(prefix: "word", wordLevel: true),
            source: .netEase,
            score: 72,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.3
        )
        XCTAssertTrue(
            fetcher.shouldCancelAuthoritativeBackfill(after: wordLevel),
            "a title-matched word-level hit is allowed to stop the backfill race"
        )
    }

    func testShouldLaunchBackfillForLineLevelAndUnsyncedButNotWordLevel() {
        XCTAssertTrue(
            LyricsService.shouldLaunchAuthoritativeBackfill(
                hasForegroundResult: false,
                kind: nil,
                hasWordLevel: false
            )
        )
        XCTAssertTrue(
            LyricsService.shouldLaunchAuthoritativeBackfill(
                hasForegroundResult: true,
                kind: .unsynced,
                hasWordLevel: false
            )
        )
        XCTAssertTrue(
            LyricsService.shouldLaunchAuthoritativeBackfill(
                hasForegroundResult: true,
                kind: .synced,
                hasWordLevel: false
            ),
            "行级前景必须启动回填去升级逐字"
        )
        XCTAssertFalse(
            LyricsService.shouldLaunchAuthoritativeBackfill(
                hasForegroundResult: true,
                kind: .synced,
                hasWordLevel: true
            ),
            "already word-level: do not relaunch the 9s backfill"
        )
    }

    func testQualityGateAllowsLineToWordUpgradeAndBlocksDemotion() {
        XCTAssertTrue(
            LyricsService.shouldReplaceDisplayedLyrics(
                displayState: .content,
                displayedIsEmpty: false,
                displayedHasWordLevel: false,
                displayedIsUnsynced: false,
                incomingHasWordLevel: true,
                incomingIsUnsynced: false,
                incomingIsEmpty: false
            ),
            "行级 → 逐字 must hot-switch"
        )
        XCTAssertFalse(
            LyricsService.shouldReplaceDisplayedLyrics(
                displayState: .content,
                displayedIsEmpty: false,
                displayedHasWordLevel: true,
                displayedIsUnsynced: false,
                incomingHasWordLevel: false,
                incomingIsUnsynced: false,
                incomingIsEmpty: false
            ),
            "P1: 逐字 must never demote to 行级"
        )
        XCTAssertTrue(
            LyricsService.shouldReplaceDisplayedLyrics(
                displayState: .searching,
                displayedIsEmpty: true,
                displayedHasWordLevel: false,
                displayedIsUnsynced: false,
                incomingHasWordLevel: false,
                incomingIsUnsynced: false,
                incomingIsEmpty: false
            ),
            "first publish of line-level is allowed"
        )
        XCTAssertFalse(
            LyricsService.shouldReplaceDisplayedLyrics(
                displayState: .content,
                displayedIsEmpty: false,
                displayedHasWordLevel: false,
                displayedIsUnsynced: false,
                incomingHasWordLevel: false,
                incomingIsUnsynced: false,
                incomingIsEmpty: false
            ),
            "same-granularity replacement stays frozen (oscillation guard)"
        )
    }

    @MainActor
    func testLineLevelDisplayHotSwitchesWhenWordLevelArrives() async {
        let service = LyricsService.shared
        let title = "WordLevelUpgrade \(UUID().uuidString.prefix(8))"
        let artist = "Upgrade Artist"
        let duration: TimeInterval = 48

        service.debugSeedDisplayedLyricsForTesting(
            completeLines(prefix: "line", wordLevel: false),
            title: title,
            artist: artist,
            duration: duration,
            isUnsynced: false
        )
        XCTAssertEqual(service.displayState, .content)
        XCTAssertFalse(service.lyrics.contains { $0.hasSyllableSync })

        let wordLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: completeLines(prefix: "word", wordLevel: true),
            source: .amll,
            score: 70,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )
        await service.debugApplyFetchedResultForTesting(
            wordLevel,
            title: title,
            artist: artist,
            duration: duration
        )

        XCTAssertEqual(service.displayState, .content)
        XCTAssertTrue(
            service.lyrics.contains { $0.hasSyllableSync },
            "回填升级到逐字必须热切换到当前显示"
        )
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("word") })
    }

    @MainActor
    func testWordLevelDisplayDoesNotDemoteWhenLineLevelArrivesLater() async {
        let service = LyricsService.shared
        let title = "NoDemote \(UUID().uuidString.prefix(8))"
        let artist = "Freeze Artist"
        let duration: TimeInterval = 48

        service.debugSeedDisplayedLyricsForTesting(
            completeLines(prefix: "word", wordLevel: true),
            title: title,
            artist: artist,
            duration: duration,
            isUnsynced: false
        )

        let lineLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: completeLines(prefix: "line", wordLevel: false),
            source: .lrclib,
            score: 90,
            kind: .synced,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.0
        )
        await service.debugApplyFetchedResultForTesting(
            lineLevel,
            title: title,
            artist: artist,
            duration: duration
        )

        XCTAssertTrue(service.lyrics.contains { $0.hasSyllableSync })
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("word") })
        XCTAssertFalse(service.lyrics.contains { $0.text.contains("line corroborated") })
    }
}
