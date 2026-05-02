import XCTest
@testable import MusicMiniPlayerCore

final class LanguageUtilsTests: XCTestCase {

    func testLikelyRomanizedJapaneseDetectsParticlePhrases() {
        XCTAssertTrue(LanguageUtils.isLikelyRomanizedJapanese("Dream Boat ga Deru Yoru ni"))
        XCTAssertTrue(LanguageUtils.isLikelyRomanizedJapanese("Mayonaka No Shujinkou"))
        XCTAssertTrue(LanguageUtils.isLikelyRomanizedJapanese("Koibitotachi no Chiheisen"))
    }

    func testLikelyRomanizedJapaneseRejectsCommonEnglishTitles() {
        XCTAssertFalse(LanguageUtils.isLikelyRomanizedJapanese("No Time To Die"))
        XCTAssertFalse(LanguageUtils.isLikelyRomanizedJapanese("No More Sad Songs"))
        XCTAssertFalse(LanguageUtils.isLikelyRomanizedJapanese("While My Guitar Gently Weeps"))
    }

    func testLikelyEnglishTitleDetectsShortCommonTitleWords() {
        XCTAssertTrue(LanguageUtils.isLikelyEnglishTitle("Second Love"))
        XCTAssertTrue(LanguageUtils.isLikelyEnglishTitle("Tough Days"))
        XCTAssertFalse(LanguageUtils.isLikelyRomanizedJapanese("Second Love"))
    }

    func testNormalizeTrackNameFoldsCurlyApostrophes() {
        XCTAssertEqual(
            LanguageUtils.normalizeTrackName("Boys Don’t Cry"),
            LanguageUtils.normalizeTrackName("Boys Don't Cry")
        )
    }
}
