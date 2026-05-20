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
}
