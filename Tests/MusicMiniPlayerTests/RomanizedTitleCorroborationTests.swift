import XCTest
@testable import MusicMiniPlayerCore

// =========================================================================
// MARK: - Romanized→CJK title corroboration
//
// Guards the loosest metadata-resolver tier: a romanized library title
// (e.g. "Er Shi Sui De Lang Man") must only resolve to a CJK candidate whose
// Latin transliteration is consistent with the input. Prevents a different
// song by the same/featured artist with a close duration from being accepted
// (the "Funky那個女孩 (feat. 藍心湄)" vs "二十歲的浪漫" collision; postmortem 006).
// =========================================================================

final class RomanizedTitleCorroborationTests: XCTestCase {

    func testCorrectPinyinTitleCorroborates() {
        // "二十歲的浪漫" romanizes to "ershisuidelangman" — exactly the input.
        XCTAssertTrue(
            LanguageUtils.isRomanizedTitleCorroborated(
                input: "Er Shi Sui De Lang Man",
                candidateTitle: "二十歲的浪漫"
            )
        )
    }

    func testSimplifiedVariantCorroborates() {
        XCTAssertTrue(
            LanguageUtils.isRomanizedTitleCorroborated(
                input: "Er Shi Sui De Lang Man",
                candidateTitle: "二十岁的浪漫"
            )
        )
    }

    func testFeatSuffixOnCorrectTitleStillCorroborates() {
        XCTAssertTrue(
            LanguageUtils.isRomanizedTitleCorroborated(
                input: "Er Shi Sui De Lang Man",
                candidateTitle: "二十歲的浪漫 (feat. 某人)"
            )
        )
    }

    func testDifferentSongSameFeaturedArtistIsRejected() {
        // 藍心湄 is a *featured* artist here, duration was near-identical, but
        // the title romanizes to "funkynagenuhai…" — nothing like the input.
        XCTAssertFalse(
            LanguageUtils.isRomanizedTitleCorroborated(
                input: "Er Shi Sui De Lang Man",
                candidateTitle: "Funky那個女孩 (feat. 藍心湄)"
            )
        )
    }

    func testUnrelatedSameArtistSongIsRejected() {
        // "快節奏" → "kuaijiezou" ≠ "ershisuidelangman"
        XCTAssertFalse(
            LanguageUtils.isRomanizedTitleCorroborated(
                input: "Er Shi Sui De Lang Man",
                candidateTitle: "快節奏"
            )
        )
    }

    func testScoreIsHigherForCorrectThanWrong() {
        let correct = LanguageUtils.romanizedTitleCorroboration(
            input: "Er Shi Sui De Lang Man",
            candidateTitle: "二十歲的浪漫"
        )
        let wrong = LanguageUtils.romanizedTitleCorroboration(
            input: "Er Shi Sui De Lang Man",
            candidateTitle: "Funky那個女孩 (feat. 藍心湄)"
        )
        XCTAssertGreaterThan(correct, wrong)
        XCTAssertEqual(correct, 1.0, accuracy: 0.0001)
    }
}
