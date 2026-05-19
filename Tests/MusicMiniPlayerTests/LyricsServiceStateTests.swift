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
}
