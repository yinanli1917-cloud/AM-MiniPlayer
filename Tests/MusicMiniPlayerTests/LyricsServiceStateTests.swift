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
}
