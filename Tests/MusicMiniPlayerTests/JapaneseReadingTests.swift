import XCTest
@testable import MusicMiniPlayerCore

// =========================================================================
// MARK: - Japanese reading corroboration (review #11)
//
// Replaces the former 8-word romaji→kanji alias table with a real Japanese
// reading function (CFStringTokenizer Latin transcription, ja locale).
// Semantics fixed by the adversarial review:
//   - isTitleMatch admission door requires reading EQUALITY (no 0.6 fuzz):
//     prefix-extended different songs ("namida" vs 涙色 "namidairo") must
//     NOT pass.
//   - The 0.6 fuzziness stays only at the already-battle-tested ranking
//     doors (romanizedTitleCorroboration), which now try Mandarin pinyin
//     AND the Japanese reading.
//   - Fail closed: a CJK token without a transcription voids the reading —
//     never a crash, never a partial-reading false positive.
//   - The containment shortcut in the title-match chain is floored: the
//     contained side must carry >= 4 Latin characters of identity.
//
// Probe ground truth (CFStringTokenizer, ja locale, 2026-06):
//   初恋→hatsukoi 恋人→koibito 恋人たち→koibito|tachi 真夜中→ma|yonaka
//   涙→namida 泪→namida 淚→namida 夢→yume 梦→(empty; trad 夢→yume)
//   空→sora 風→kaze 风→(empty; trad 風→kaze) 星→hoshi
//   東京→toukyou ありがとう→arigatou 希望→kibou (kana-spelling long
//   vowels, no macrons) 二十歲的浪漫→nijuu|<empty>|roman (partial → void)
// =========================================================================

final class JapaneseReadingTests: XCTestCase {

    // ────────────────────────────────────────────────────────────────────
    // MARK: Reading keys — the 8 former whitelist pairs become fixtures
    // ────────────────────────────────────────────────────────────────────

    func testReadingKeysCoverFormerWhitelistPairs() {
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("初恋").contains("hatsukoi"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("恋人").contains("koibito"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("恋人たち").contains("koibitotachi"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("真夜中").contains("mayonaka"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("涙").contains("namida"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("夢").contains("yume"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("空").contains("sora"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("風").contains("kaze"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("星").contains("hoshi"))
    }

    func testReadingKeysHandleSimplifiedAndTraditionalVariants() {
        // The old whitelist listed 泪/梦/风 explicitly because catalogs may
        // index Simplified glyphs. 泪/淚 transcribe directly; 梦/风 only via
        // their Traditional forms (夢/風) — the reading function must try
        // the toTraditionalChinese variant before giving up.
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("泪").contains("namida"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("淚").contains("namida"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("梦").contains("yume"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("风").contains("kaze"))
    }

    func testReadingKeysFoldKanaSpellingLongVowels() {
        // The tokenizer emits kana-spelling long vowels ("toukyou", "kibou"),
        // never macrons. One uniform rule on both sides: "ou" and doubled
        // vowels collapse to the short vowel.
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("東京").contains("tokyo"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("希望").contains("kibo"))
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("ありがとう").contains("arigato"))
    }

    func testReadingKeysFailClosed() {
        // No CJK → no Japanese reading (the ASCII side is handled separately).
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("hello world").isEmpty)
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("").isEmpty)
        // Partial transcription (some CJK tokens have no reading) voids the
        // whole reading — a reading that silently dropped ideographs is NOT
        // the reading of the title.
        XCTAssertTrue(LanguageUtils.japaneseReadingKeys("二十歲的浪漫").isEmpty)
    }

    func testRomajiComparisonKeyAppliesTheSameLongVowelRule() {
        // Wapuro-style romanized inputs ("Toukyou") and Hepburn-style
        // ("Tokyo") must land on the same key as the reading side.
        XCTAssertEqual(LanguageUtils.romajiComparisonKey("Toukyou"), "tokyo")
        XCTAssertEqual(LanguageUtils.romajiComparisonKey("Tokyo"), "tokyo")
        XCTAssertEqual(LanguageUtils.romajiComparisonKey("Hatsukoi"), "hatsukoi")
        // "oi" is NOT a long vowel — must survive the fold untouched.
        XCTAssertEqual(LanguageUtils.romajiComparisonKey("Koibito"), "koibito")
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: isTitleMatch — reading EQUALITY door (the whitelist replacement)
    // ────────────────────────────────────────────────────────────────────

    private func titleMatch(_ input: String, _ result: String) -> Bool {
        LyricsFetcher.shared.isTitleMatch(
            input: input,
            result: result,
            simplifiedInput: LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(input)
            )
        )
    }

    func testEqualityDoorAdmitsAllFormerWhitelistPairs() {
        XCTAssertTrue(titleMatch("Hatsukoi", "初恋"))
        XCTAssertTrue(titleMatch("Koibito", "恋人"))
        XCTAssertTrue(titleMatch("Koibitotachi", "恋人たち"))
        XCTAssertTrue(titleMatch("Mayonaka", "真夜中"))
        XCTAssertTrue(titleMatch("Namida", "涙"))
        XCTAssertTrue(titleMatch("Namida", "泪"))
        XCTAssertTrue(titleMatch("Yume", "夢"))
        XCTAssertTrue(titleMatch("Yume", "梦"))
        XCTAssertTrue(titleMatch("Sora", "空"))
        XCTAssertTrue(titleMatch("Kaze", "風"))
        XCTAssertTrue(titleMatch("Kaze", "风"))
        XCTAssertTrue(titleMatch("Hoshi", "星"))
    }

    func testEqualityDoorIsDirectionAgnostic() {
        // The old alias table only fired for romaji INPUT vs CJK result.
        // Reading equality is symmetric: a CJK library title must also match
        // a romaji catalog title.
        XCTAssertTrue(titleMatch("初恋", "Hatsukoi"))
        XCTAssertTrue(titleMatch("夢", "Yume"))
    }

    func testYumenoMatchesItsActualReadingNotTheBareKanji() {
        // The old alias mapped compact "yumeno" → 夢 — whitelist sloppiness.
        // Equality semantics: "yumeno" is the reading of 夢の, not of 夢.
        XCTAssertTrue(titleMatch("Yumeno", "夢の"))
        XCTAssertFalse(titleMatch("Yumeno", "夢"))
    }

    func testEqualityDoorRejectsPrefixExtendedDifferentSongs() {
        // Mandated negative fixtures (review #11): a 0.6 fuzzy door would
        // admit these ("namida" vs "namidairo" scores 0.667). Equality must
        // reject them — they are different songs.
        XCTAssertFalse(titleMatch("Namida", "涙色"))
        XCTAssertFalse(titleMatch("Yume", "夢の中"))
        XCTAssertFalse(titleMatch("Sora", "空と君のあいだに"))
        XCTAssertFalse(titleMatch("Hatsukoi", "初恋物語"))
    }

    func testReadingDoorStaysInertForMandarinPinyinInputs() {
        // 平凡 has a Japanese on'yomi reading ("heibon") — it must not
        // interfere with the pinyin door, which still matches as before.
        XCTAssertTrue(titleMatch("Ping Fan", "平凡"))
        XCTAssertFalse(titleMatch("Heibon Wrong Length", "平凡"))
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: isTitleMatch — containment floor
    // ────────────────────────────────────────────────────────────────────

    func testContainmentRequiresFourLatinCharactersOfIdentity() {
        // 涙 transliterates to "lei" (3 chars) — too little identity to let
        // 涙 ⊂ 涙色 pass as a title match (different songs).
        XCTAssertFalse(titleMatch("涙", "涙色"))
        // Single-letter containment is trivially true and meaningless.
        XCTAssertFalse(titleMatch("E", "Everything"))
    }

    func testContainmentStillMatchesRealDecoratedTitles() {
        // Legit containments keep working: the contained side carries
        // >= 4 Latin characters of identity.
        XCTAssertTrue(titleMatch("Hello World", "Hello World Song"))
        // 晴天 → "qingtian" (8 chars): an unstripped suffix still matches.
        XCTAssertTrue(titleMatch("晴天", "晴天 翻唱版"))
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Shared corroboration helper (ranking doors, 0.6 fuzz preserved)
    // ────────────────────────────────────────────────────────────────────

    func testCorroborationLearnsJapaneseReadings() {
        // Before #11 the postmortem-006 doors only knew Mandarin pinyin
        // (初恋 → "chulian"), so every Japanese candidate scored ~0.
        XCTAssertTrue(
            LanguageUtils.isRomanizedTitleCorroborated(input: "Hatsukoi", candidateTitle: "初恋")
        )
        XCTAssertTrue(
            LanguageUtils.isRomanizedTitleCorroborated(input: "Tokyo", candidateTitle: "東京")
        )
        XCTAssertTrue(
            LanguageUtils.isRomanizedTitleCorroborated(input: "Mayonaka", candidateTitle: "真夜中")
        )
    }

    func testRankingDoorsKeepTheirBattleTestedFuzz() {
        // Review decision: 0.6 containment fuzz STAYS at ranking doors —
        // "namida" ⊂ "namidairo" = 6/9 ≈ 0.667 is corroboration evidence for
        // RANKING; admission (isTitleMatch) requires equality and rejects it.
        XCTAssertGreaterThanOrEqual(
            LanguageUtils.romanizedTitleCorroboration(input: "Namida", candidateTitle: "涙色"),
            LanguageUtils.romanizedTitleCorroborationThreshold
        )
    }

    func testAsciiOnlyPairsAreUntouchedByTheReadingLane() {
        // The long-vowel fold must never apply to ASCII↔ASCII comparisons
        // ("house" would otherwise collapse to "hose" and score 1.0).
        XCTAssertFalse(
            LanguageUtils.isRomanizedTitleCorroborated(input: "house", candidateTitle: "hose")
        )
    }

    func testCorroborationFailsClosedOnPartialReadings() {
        // 二十歲的浪漫 has no complete Japanese reading (void, fail closed);
        // a fabricated input resembling its partial reading must not match.
        XCTAssertFalse(
            LanguageUtils.isRomanizedTitleCorroborated(
                input: "Nijuuroman",
                candidateTitle: "二十歲的浪漫"
            )
        )
        // The pinyin lane still corroborates the true romanization.
        XCTAssertTrue(
            LanguageUtils.isRomanizedTitleCorroborated(
                input: "Er Shi Sui De Lang Man",
                candidateTitle: "二十歲的浪漫"
            )
        )
    }
}
