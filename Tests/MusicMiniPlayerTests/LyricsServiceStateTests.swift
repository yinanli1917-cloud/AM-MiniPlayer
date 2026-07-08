import XCTest
@testable import MusicMiniPlayerCore

final class LyricsServiceStateTests: XCTestCase {
    func testNoLyricsMissDoesNotOverrideDisplayedLyricsForSameSong() {
        XCTAssertFalse(
            LyricsService.shouldApplyNoLyricsMiss(
                currentSongID: "deep-tanya-chua-244",
                missSongID: "deep-tanya-chua-244",
                hasDisplayedLyrics: true
            )
        )
    }

    func testNoLyricsMissAppliesOnlyForCurrentSongWithNoLyrics() {
        XCTAssertTrue(
            LyricsService.shouldApplyNoLyricsMiss(
                currentSongID: "deep-tanya-chua-244",
                missSongID: "deep-tanya-chua-244",
                hasDisplayedLyrics: false
            )
        )

        XCTAssertFalse(
            LyricsService.shouldApplyNoLyricsMiss(
                currentSongID: "dream-deca-joins-245",
                missSongID: "deep-tanya-chua-244",
                hasDisplayedLyrics: false
            )
        )
    }

    func testEmptyCurrentResultCanRetryWhenUserReopensLyrics() {
        XCTAssertTrue(
            LyricsService.shouldRetryAfterEmptyCurrentResult(
                currentSongID: "lemon|kenshi-yonezu||254",
                requestSongID: "lemon|kenshi-yonezu||254",
                isLoading: false,
                hasDisplayedLyrics: false,
                hasError: true,
                forceRefresh: false
            )
        )
    }

    func testEmptyCurrentRetryDoesNotInterruptLoadingOrDisplayedLyrics() {
        XCTAssertFalse(
            LyricsService.shouldRetryAfterEmptyCurrentResult(
                currentSongID: "lemon|kenshi-yonezu||254",
                requestSongID: "lemon|kenshi-yonezu||254",
                isLoading: true,
                hasDisplayedLyrics: false,
                hasError: true,
                forceRefresh: false
            )
        )

        XCTAssertFalse(
            LyricsService.shouldRetryAfterEmptyCurrentResult(
                currentSongID: "lemon|kenshi-yonezu||254",
                requestSongID: "lemon|kenshi-yonezu||254",
                isLoading: false,
                hasDisplayedLyrics: true,
                hasError: true,
                forceRefresh: false
            )
        )
    }

    func testMetadataCorrectionGuardAcceptsEmptyAlbumAndUnknownDuration() {
        XCTAssertTrue(
            LyricsService.isLikelySameSongMetadataCorrection(
                currentStableSongID: "lemon|kenshi-yonezu",
                requestStableSongID: "lemon|kenshi-yonezu",
                currentDuration: 0,
                requestDuration: 254,
                currentAlbum: "",
                requestAlbum: "STRAY SHEEP"
            )
        )
    }

    func testMetadataCorrectionGuardRejectsDifferentKnownVersion() {
        XCTAssertFalse(
            LyricsService.isLikelySameSongMetadataCorrection(
                currentStableSongID: "lemon|kenshi-yonezu",
                requestStableSongID: "lemon|kenshi-yonezu",
                currentDuration: 254,
                requestDuration: 315,
                currentAlbum: "STRAY SHEEP",
                requestAlbum: "Live Album"
            )
        )
    }

    func testTranslationAvailabilitySkipsChineseLyricsForChineseTarget() {
        let lyrics = [
            LyricLine(text: "我们一起走过雨天", startTime: 0, endTime: 2),
            LyricLine(text: "风吹过旧街边", startTime: 2, endTime: 4),
            LyricLine(text: "留下温柔的画面", startTime: 4, endTime: 6)
        ]

        XCTAssertFalse(
            LyricsService.translationAvailability(
                lyrics: lyrics,
                translationLanguage: "zh-Hans",
                translationsAreFromLyricsSource: false
            )
        )
    }

    func testTranslationAvailabilityAllowsNonTargetLyricsAndSourceTranslations() {
        let lyrics = [
            LyricLine(text: "Every time you call my name", startTime: 0, endTime: 2),
            LyricLine(text: "I can hear it through the rain", startTime: 2, endTime: 4),
            LyricLine(text: "Waiting on the other side", startTime: 4, endTime: 6)
        ]

        XCTAssertTrue(
            LyricsService.translationAvailability(
                lyrics: lyrics,
                translationLanguage: "zh-Hans",
                translationsAreFromLyricsSource: false
            )
        )
        XCTAssertTrue(
            LyricsService.translationAvailability(
                lyrics: lyrics,
                translationLanguage: "zh-Hans",
                translationsAreFromLyricsSource: true
            )
        )
    }

    func testBareChineseTranslationLanguageUsesConcreteSystemTarget() {
        XCTAssertEqual(LyricsService.normalizedSystemTranslationLanguage("zh"), "zh-Hans")
        XCTAssertEqual(LyricsService.normalizedSystemTranslationLanguage("zh-Hant"), "zh-Hant")
    }

    func testPartialSourceTranslationFillTargetsOnlyMissingVisibleLines() {
        let lyrics = [
            LyricLine(text: "⋯", startTime: 0, endTime: 10),
            LyricLine(text: "泣きながら　ちぎった写真を", startTime: 14, endTime: 22, translation: "一边哭着 把撕碎的照片"),
            LyricLine(text: "悩みなき　きのうのほほえみ", startTime: 29, endTime: 37),
            LyricLine(text: "la la la", startTime: 38, endTime: 40),
            LyricLine(text: "伤つける人もないけど", startTime: 160, endTime: 168)
        ]

        XCTAssertEqual(
            LyricsService.translationEligibleLineIndices(in: lyrics, onlyMissingTranslations: true),
            [2, 4]
        )
        XCTAssertTrue(LyricsService.hasMissingEligibleTranslations(lyrics))
    }

    func testTranslationCoverageSkipsRoleMarkersAndAdlibs() {
        let lyrics = [
            LyricLine(text: "⋯", startTime: 0, endTime: 2),
            LyricLine(text: "Snoh Aalegra：", startTime: 2.3, endTime: 2.5),
            LyricLine(text: "Somethin' 'bout the way that you talk to me", startTime: 2.6, endTime: 13.6, translation: "你谈吐的样子如此优雅"),
            LyricLine(text: "Oh I I", startTime: 114.4, endTime: 115.4),
            LyricLine(text: "Choir/Snoh Aalegra：", startTime: 157.5, endTime: 158.1),
            LyricLine(text: "I've been waitin' my whole life to find someone like you", startTime: 158.1, endTime: 163.5, translation: "我穷尽一生去找寻像你这样的人")
        ]

        XCTAssertEqual(
            LyricsService.translationEligibleLineIndices(in: lyrics, onlyMissingTranslations: true),
            []
        )
        XCTAssertEqual(LyricsService.translationCoverageStats(in: lyrics).eligible, 2)
        XCTAssertFalse(LyricsService.hasMissingEligibleTranslations(lyrics))
    }

    func testVisibleVocableGapCanBeHiddenByAggregateTranslationCoverage() {
        let lyrics = [
            LyricLine(text: "Yeah, yeah", startTime: 42, endTime: 44),
            LyricLine(text: "Yeah I walked right in", startTime: 44, endTime: 48, translation: "Yeah 我径直走入"),
            LyricLine(text: "I found the door", startTime: 48, endTime: 52, translation: "我找到了那扇门")
        ]

        XCTAssertTrue(isVocableLine("Yeah, yeah"))
        XCTAssertEqual(LyricsService.translationCoverageStats(in: lyrics).eligible, 2)
        XCTAssertEqual(LyricsService.translationCoverageStats(in: lyrics).missing, 0)
        XCTAssertFalse(LyricsService.hasMissingEligibleTranslations(lyrics))
    }

    func testTranslationPendingLayoutDoesNotReserveBlankRowsForVocableLines() {
        let lyrics = [
            LyricLine(text: "Yeah, yeah", startTime: 42, endTime: 44),
            LyricLine(text: "I walked right in", startTime: 44, endTime: 48)
        ]
        let pending = LyricLineTranslationLayoutPolicy.pendingLineIndices(in: lyrics)

        XCTAssertFalse(
            LyricLineTranslationLayoutPolicy.isAwaitingTranslation(
                index: 0,
                line: lyrics[0],
                pendingLineIndices: pending,
                isTranslating: true
            )
        )
        XCTAssertTrue(
            LyricLineTranslationLayoutPolicy.isAwaitingTranslation(
                index: 1,
                line: lyrics[1],
                pendingLineIndices: pending,
                isTranslating: true
            )
        )
    }

    func testCompleteSourceTranslationDoesNotRequestSystemFill() {
        let lyrics = [
            LyricLine(text: "⋯", startTime: 0, endTime: 10),
            LyricLine(text: "あの顷のわたしに戻って", startTime: 60, endTime: 68, translation: "我好想回到那时候"),
            LyricLine(text: "あなたに会いたい", startTime: 68, endTime: 76, translation: "与你相遇")
        ]

        XCTAssertEqual(
            LyricsService.translationEligibleLineIndices(in: lyrics, onlyMissingTranslations: true),
            []
        )
        XCTAssertFalse(LyricsService.hasMissingEligibleTranslations(lyrics))
    }

    func testSystemTranslationSampleUsesOnlyMissingSourceTranslationLines() {
        let lyrics = [
            LyricLine(text: "⋯", startTime: 0, endTime: 10),
            LyricLine(text: "泣きながら　ちぎった写真を", startTime: 14, endTime: 22, translation: "一边哭着 把撕碎的照片"),
            LyricLine(text: "悩みなき　きのうのほほえみ", startTime: 29, endTime: 37),
            LyricLine(text: "la la la", startTime: 38, endTime: 40),
            LyricLine(text: "伤つける人もないけど", startTime: 160, endTime: 168)
        ]

        let sample = LyricsService.systemTranslationSampleText(
            in: lyrics,
            onlyMissingTranslations: true
        )

        XCTAssertEqual(sample, "悩みなき　きのうのほほえみ\n伤つける人もないけど")
    }

    func testLineSyncCacheIsProvisionalUntilWordLevelRefreshRuns() {
        let lineSyncLyrics = [
            LyricLine(text: "浪漫節日燈飾太亮掩蓋了隱憂", startTime: 29.54, endTime: 33.0),
            LyricLine(text: "情人陪同來到多擠迫的關口", startTime: 33.1, endTime: 37.0)
        ]
        let wordLevelLyrics = [
            LyricLine(
                text: "浪漫節日燈飾太亮掩蓋了隱憂",
                startTime: 29.54,
                endTime: 33.0,
                words: [LyricWord(word: "浪漫", startTime: 29.54, endTime: 29.9)]
            )
        ]

        XCTAssertTrue(
            LyricsService.shouldRefreshCachedLyricsForGranularity(
                lyrics: lineSyncLyrics,
                isNoLyrics: false,
                isUnsynced: false
            )
        )
        XCTAssertFalse(
            LyricsService.shouldRefreshCachedLyricsForGranularity(
                lyrics: wordLevelLyrics,
                isNoLyrics: false,
                isUnsynced: false
            )
        )
        XCTAssertFalse(
            LyricsService.shouldRefreshCachedLyricsForGranularity(
                lyrics: lineSyncLyrics,
                isNoLyrics: false,
                isUnsynced: true
            )
        )
    }

    func testSystemTranslationSampleRejectsUnstableShortText() {
        let lyrics = [
            LyricLine(text: "⋯", startTime: 0, endTime: 10),
            LyricLine(text: "la", startTime: 10, endTime: 12),
            LyricLine(text: "oh", startTime: 12, endTime: 14)
        ]

        XCTAssertNil(
            LyricsService.systemTranslationSampleText(
                in: lyrics,
                onlyMissingTranslations: false
            )
        )
    }

    func testSystemTranslationSourceLanguageUsesStableSample() {
        let source = LyricsService.systemTranslationSourceLanguage(
            for: "泣きながら　ちぎった写真を\n悩みなき　きのうのほほえみ\nあなたに会いたい"
        )

        XCTAssertEqual(source?.languageCode?.identifier, "ja")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Display-state machine (review #5)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testSearchingMayEnterDeepSearch() {
        XCTAssertEqual(LyricsDisplayState.searching.enteringDeepSearch(), .deepSearching)
    }

    func testDeepSearchNeverDemotesContentOrTerminals() {
        // REQUIRED CORRECTION from the adversarial review: deep-searching may
        // only replace the plain spinner. Content (e.g. a Genius-only
        // unsynced result already on screen) and the terminals must survive
        // a backfill launch untouched.
        XCTAssertEqual(LyricsDisplayState.content.enteringDeepSearch(), .content)
        XCTAssertEqual(LyricsDisplayState.noLyrics.enteringDeepSearch(), .noLyrics)
        XCTAssertEqual(LyricsDisplayState.networkUnreachable.enteringDeepSearch(), .networkUnreachable)
        XCTAssertEqual(LyricsDisplayState.deepSearching.enteringDeepSearch(), .deepSearching)
    }

    func testFetchDispatchOwesSpinnerUnlessProvisionalContentIsShowing() {
        XCTAssertEqual(
            LyricsDisplayState.dispatchingFetch(showingProvisionalContent: true),
            .content
        )
        XCTAssertEqual(
            LyricsDisplayState.dispatchingFetch(showingProvisionalContent: false),
            .searching
        )
    }

    func testCachedContentThenBetterSourceRefetchStaysContentEndToEnd() {
        // applyLyrics published cached lyrics → content. Its own granularity
        // refetch dispatches and may later launch the deep backfill; neither
        // step may put a spinner back over the visible lyrics.
        var state = LyricsDisplayState.content
        state = LyricsDisplayState.dispatchingFetch(showingProvisionalContent: true)
        XCTAssertEqual(state, .content)
        state = state.enteringDeepSearch()
        XCTAssertEqual(state, .content)
    }

    @MainActor
    func testVisibleLyricsStayContentDuringSameSongMetadataRefresh() {
        guard let fixture = NativeLyricsDebugFixture.fixture(named: "translated-word") else {
            return XCTFail("missing debug fixture")
        }
        let service = LyricsService.shared
        service.applyDebugFixture(fixture)
        defer { service.applyDebugFixture(fixture) }

        let visibleLineCount = service.lyrics.count
        XCTAssertGreaterThan(visibleLineCount, 0)
        XCTAssertEqual(service.displayState, .content)

        service.debugExpireStabilityGuardForTesting()
        service.fetchLyrics(
            for: fixture.title,
            artist: fixture.artist,
            duration: fixture.duration + 2.0,
            album: fixture.album
        )

        XCTAssertEqual(
            service.displayState,
            .content,
            "same-song duration corrections must refresh in the background instead of blanking visible lyrics"
        )
        XCTAssertEqual(service.lyrics.count, visibleLineCount)
    }

    @MainActor
    func testDifferentTrackFetchDropsStaleRowsBeforeSearching() {
        guard let fixture = NativeLyricsDebugFixture.fixture(named: "translated-word") else {
            return XCTFail("missing debug fixture")
        }
        let service = LyricsService.shared
        service.applyDebugFixture(fixture)
        defer { service.applyDebugFixture(fixture) }

        XCTAssertFalse(service.lyrics.isEmpty)

        service.debugExpireStabilityGuardForTesting()
        service.fetchLyrics(
            for: "Different Debug Track",
            artist: "nanoPod Debug",
            duration: fixture.duration,
            album: fixture.album
        )

        XCTAssertEqual(service.displayState, .searching)
        XCTAssertTrue(service.lyrics.isEmpty, "new-track searches must not let old rows block terminal no-lyrics publication")
    }

    func testMissPathReachesLabeledTerminals() {
        // searching → deepSearching → terminal: a no-result search ends in an
        // explained terminal instead of an anonymous spinner.
        var state = LyricsDisplayState.dispatchingFetch(showingProvisionalContent: false)
        XCTAssertEqual(state, .searching)
        state = state.enteringDeepSearch()
        XCTAssertEqual(state, .deepSearching)

        XCTAssertEqual(LyricsService.TerminalMissVerdict.noLyrics.displayState, .noLyrics)
        XCTAssertEqual(LyricsService.TerminalMissVerdict.instrumental.displayState, .noLyrics)
        XCTAssertEqual(LyricsService.TerminalMissVerdict.networkUnreachable.displayState, .networkUnreachable)
    }

    func testIsLoadingCompatibilityDerivesFromSearchPhases() {
        XCTAssertTrue(LyricsDisplayState.searching.isSearchPhase)
        XCTAssertTrue(LyricsDisplayState.deepSearching.isSearchPhase)
        XCTAssertFalse(LyricsDisplayState.content.isSearchPhase)
        XCTAssertFalse(LyricsDisplayState.noLyrics.isSearchPhase)
        XCTAssertFalse(LyricsDisplayState.networkUnreachable.isSearchPhase)
    }
}
