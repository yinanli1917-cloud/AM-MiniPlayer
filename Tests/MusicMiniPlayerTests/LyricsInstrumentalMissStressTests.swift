import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// No-lyrics / instrumental EDGE — availability row, session memo, no
// spinner deadlock.
//
// A confirmed miss is a statement about the SONG. Instrumental is the
// same terminal class (nothing to display) with a distinct payload so
// replay says "Instrumental track", not generic unavailable. Offline
// never memos. The spinner (`isSearchPhase`) must not survive a terminal.
// Disk availability rows are durable evidence for the async path; the
// sync pre-flight must NOT serve them as karaoke content.
//
// Headless, zero real network. Founder rule 2026-08-21.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsInstrumentalMissStressTests: XCTestCase {

    // ── Parser: instrumental notices are not displayable lyrics ──────────

    func test_processLyrics_instrumentalNotice_returnsEmpty() {
        let notices = [
            "纯音乐，请欣赏",
            "Instrumental",
            "This song is instrumental",
            "此歌曲为没有填词的纯音乐"
        ]
        for text in notices {
            let (lyrics, firstReal) = LyricsParser.shared.processLyrics([
                LyricLine(text: text, startTime: 0, endTime: 180)
            ])
            XCTAssertTrue(lyrics.isEmpty, "notice '\(text)' must not become a displayable row")
            XCTAssertEqual(firstReal, 0)
        }
    }

    func test_instrumentalNotice_isDetected_andTranslationSkipsIt() {
        XCTAssertTrue(isInstrumentalNotice("纯音乐，请欣赏"))
        XCTAssertTrue(isInstrumentalNotice("Instrumental"))
        XCTAssertFalse(isInstrumentalNotice("週末の夜はパーティ"))
        let mixed = [
            LyricLine(text: "⋯", startTime: 0, endTime: 4),
            LyricLine(text: "Instrumental", startTime: 4, endTime: 180)
        ]
        XCTAssertEqual(
            LyricsService.translationEligibleLineIndices(in: mixed, onlyMissingTranslations: false),
            [],
            "instrumental notices must never enter the translation pipeline"
        )
    }

    // ── Terminal machine: not a spinner, memo records the payload ────────

    func test_instrumentalVerdict_isNotASearchPhase_andMemosDistinctPayload() {
        XCTAssertEqual(
            LyricsService.TerminalMissVerdict.instrumental.displayState,
            .noLyrics,
            "instrumental folds into the no-lyrics terminal (nothing to draw)"
        )
        XCTAssertEqual(
            LyricsService.TerminalMissVerdict.instrumental.errorMessage,
            "Instrumental track"
        )
        XCTAssertFalse(LyricsService.TerminalMissVerdict.instrumental.displayState.isSearchPhase)
        XCTAssertFalse(LyricsDisplayState.noLyrics.isSearchPhase)
        XCTAssertTrue(LyricsService.shouldRecordTerminalMiss(verdict: .instrumental))
        XCTAssertTrue(LyricsService.shouldRecordTerminalMiss(verdict: .noLyrics))
        XCTAssertFalse(LyricsService.shouldRecordTerminalMiss(verdict: .networkUnreachable))
        XCTAssertFalse(LyricsService.shouldRecordTerminalMiss(verdict: .searchIncomplete))
    }

    func test_instrumentalThenNoLyrics_displayStateNeverLeftHangingInSearch() {
        var state = LyricsDisplayState.searching
        let steps: [(LyricsDisplayState, expectSearch: Bool)] = [
            (.searching, true),
            (.deepSearching, true),
            (.noLyrics, false),
            (.searching, true),
            (LyricsDisplayState.dispatchingFetch(showingProvisionalContent: false), true),
            (.noLyrics, false),
            (.content, false),
            (.searching, true),
            (.noLyrics, false)
        ]
        for (i, step) in steps.enumerated() {
            state = step.0
            let afterBackfill = state.enteringDeepSearch()
            if step.0 == .searching {
                XCTAssertEqual(afterBackfill, .deepSearching, "step \(i)")
            } else {
                XCTAssertEqual(afterBackfill, step.0, "step \(i) must not demote a terminal into a spinner")
            }
            XCTAssertEqual(afterBackfill.isSearchPhase, step.expectSearch, "step \(i) hanging?")
            state = afterBackfill
        }
        XCTAssertFalse(state.isSearchPhase)
    }

    func test_missMemo_recordsInstrumental_andReplaysWithoutSearching() {
        let memo = LyricsMissMemo<LyricsService.TerminalMissVerdict>()
        let songID = "memento|resavoir & matt gold|horizon|228"
        let key = LyricsService.missMemoKey(forSongID: songID)
        XCTAssertEqual(key, "memento|resavoir & matt gold|horizon")

        if LyricsService.shouldRecordTerminalMiss(verdict: .instrumental) {
            memo.record(.instrumental, forKey: key)
        }
        XCTAssertEqual(memo.confirmedMiss(forKey: key), .instrumental)
        XCTAssertEqual(memo.entryCountForTesting(), 1)

        // Replay identity: duration drift ±1s still serves; a different song does not.
        XCTAssertTrue(LyricsService.shouldServeMemoHit(storedDuration: 228, currentDuration: 227))
        XCTAssertNil(memo.confirmedMiss(forKey: LyricsService.missMemoKey(forSongID: "other|artist|album|180")))

        let replayState = LyricsService.TerminalMissVerdict.instrumental.displayState
        XCTAssertFalse(replayState.isSearchPhase, "a memo hit must land on a terminal, never a spinner")
    }

    func test_noLyricsMiss_doesNotOverrideDisplayedContent() {
        XCTAssertFalse(
            LyricsService.shouldApplyNoLyricsMiss(
                currentSongID: "same|id",
                missSongID: "same|id",
                hasDisplayedLyrics: true
            ),
            "a late instrumental/no-lyrics miss must not blank lyrics already on screen"
        )
        XCTAssertTrue(
            LyricsService.shouldApplyNoLyricsMiss(
                currentSongID: "same|id",
                missSongID: "same|id",
                hasDisplayedLyrics: false
            )
        )
    }

    // ── Disk availability row: persist, don't serve as karaoke ───────────

    func test_diskAvailabilityRow_preservesInstrumentalKind_andPreflightDoesNotServeAsLyrics() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inst-avail-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = LyricsDiskCache(fileURL: url)
        cache.setAvailability(
            title: "Memento",
            artist: "Resavoir",
            duration: 228,
            album: "Horizon",
            source: LyricsSource.qq.rawValue,
            kind: .instrumental,
            lines: [LyricLine(text: "Instrumental", startTime: 0, endTime: 228)],
            matchedDurationDiff: 0.3
        )
        let cached = cache.get(title: "Memento", artist: "Resavoir", duration: 228, album: "Horizon")
        XCTAssertEqual(cached?.kind, .instrumental)
        XCTAssertEqual(cached?.source, LyricsSource.qq.rawValue)

        let saved = LyricsFetcher.shared.lyricsDiskCache
        LyricsFetcher.shared.lyricsDiskCache = cache
        defer { LyricsFetcher.shared.lyricsDiskCache = saved }

        let served = LyricsFetcher.shared.immediateSyncedDiskLyrics(
            title: "Memento", artist: "Resavoir", duration: 228, album: "Horizon", translationEnabled: false
        )
        XCTAssertNil(served, "availability rows must not be served as karaoke content by the sync pre-flight")

        XCTAssertTrue(
            LyricsFetcher.shared.shouldUseImmediateCachedAvailability(
                cached!,
                requestedAlbum: "Horizon"
            ),
            "album-matched instrumental evidence is durable for the async availability short-circuit"
        )
        XCTAssertFalse(
            LyricsFetcher.shared.shouldUseImmediateCachedAvailability(
                cached!,
                requestedAlbum: "Some Other LP"
            )
        )
    }

    func test_selectInstrumentalResult_requiresTitleMatchAndNonEmptyPayload() {
        let fetcher = LyricsFetcher.shared
        let good = LyricsFetcher.LyricsFetchResult(
            lyrics: [LyricLine(text: "Instrumental", startTime: 0, endTime: 180)],
            source: .qq,
            score: -100,
            kind: .instrumental,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )
        let empty = LyricsFetcher.LyricsFetchResult(
            lyrics: [],
            source: .qq,
            score: -100,
            kind: .instrumental,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )
        XCTAssertEqual(fetcher.selectInstrumentalResult(from: [good])?.kind, .instrumental)
        XCTAssertNil(fetcher.selectInstrumentalResult(from: [empty]), "empty payload is not durable instrumental evidence")
        XCTAssertTrue(fetcher.shouldPersistAvailabilityResult(good, requestedAlbum: "Horizon"))
        XCTAssertFalse(
            fetcher.shouldPersistAvailabilityResult(
                LyricsFetcher.LyricsFetchResult(
                    lyrics: [LyricLine(text: "x", startTime: 0, endTime: 1)],
                    source: .netEase,
                    score: -80,
                    kind: .unavailable,
                    albumMatched: true,
                    titleMatched: true,
                    matchedDurationDiff: 0.2
                ),
                requestedAlbum: "Horizon"
            ),
            "provider-unavailable is retryable, never a 24h availability row"
        )
    }
}
