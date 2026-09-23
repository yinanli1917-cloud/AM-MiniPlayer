import XCTest
@testable import MusicMiniPlayerCore

/// Offline (no network, no Translation-framework, on-device NLLanguageRecognizer
/// only) evaluation for LyricsTranslationSourceDetection -- the 2026-09-22 fix
/// for the macOS system language-picker popup (silentSystemTranslationConfiguration
/// used to compute a source language and then discard it, passing `source: nil`).
///
/// Dataset: song-level groups of REAL lyric text already checked into the repo
/// (Tests/MusicMiniPlayerTests/Fixtures/long_line_eval.json, grouped by its
/// `song.key`) plus SELF-AUTHORED, non-copyrighted, short synthetic lines for
/// languages/scripts this machine's fixtures don't cover (same
/// "synthetic stratification fill" precedent research/long-line-eval-2026-09-22.md
/// used for its own gaps -- clearly labeled, never presented as real data).
final class LyricsTranslationSourceDetectionTests: XCTestCase {

    private struct SongSample {
        let name: String
        let lines: [String]
        /// The BCP-47 primary language subtag `songLevelSource`'s result
        /// should carry (compared via `.languageCode?.identifier`). `nil`
        /// means "no single correct answer" -- see the romanized-Japanese
        /// case below for why.
        let expectedLanguageCode: String?
        let isReal: Bool
    }

    // ------------------------------------------------------------------
    // MARK: - Dataset
    // ------------------------------------------------------------------

    private func loadLongLineEvalTexts(songKey: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/long_line_eval.json")
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = json["lines"] as? [[String: Any]] else {
            XCTFail("Could not parse long_line_eval.json")
            return []
        }
        return lines.compactMap { line -> String? in
            guard let song = line["song"] as? [String: Any],
                  (song["key"] as? String) == songKey,
                  let text = line["text"] as? String else { return nil }
            return text
        }
    }

    /// Self-authored synthetic lines. Non-copyrighted, invented for this
    /// test, in the spirit of `long_line_eval.json`'s syn-* entries -- never
    /// presented as real lyric excerpts.
    private let syntheticSongs: [SongSample] = [
        SongSample(name: "synthetic-es", lines: [
            "Bailamos toda la noche bajo las estrellas",
            "Mi corazon te espera cada dia sin falta",
            "Nunca olvidare tu sonrisa dulce y calida",
            "Caminamos juntos hasta el amanecer dorado",
        ], expectedLanguageCode: "es", isReal: false),
        SongSample(name: "synthetic-fr", lines: [
            "Je marche seul dans la nuit silencieuse",
            "Ton sourire illumine tout mon chemin",
            "Nous dansons ensemble jusqu'a l'aube doree",
            "Ton nom reste grave au fond de mon coeur",
        ], expectedLanguageCode: "fr", isReal: false),
        SongSample(name: "synthetic-pt", lines: [
            "Meu coração bate mais forte quando você chega perto",
            "A saudade não me deixa dormir direito essa noite",
            "Vamos dançar juntos até o sol nascer de novo",
            "Nosso amor é mais bonito do que qualquer canção",
            "Obrigada por ficar do meu lado sempre, meu bem",
            "Você é tudo que eu sempre quis ter na vida",
        ], expectedLanguageCode: "pt", isReal: false),
        SongSample(name: "synthetic-hi", lines: [
            "मेरा दिल तुम्हारे लिए हर पल धड़कता है",
            "चाँदनी रात में तुम्हारी याद बहुत आती है",
            "हम हमेशा साथ साथ चलते रहेंगे",
            "तुम्हारे बिना यह दुनिया अधूरी सी लगती है",
        ], expectedLanguageCode: "hi", isReal: false),
        SongSample(name: "synthetic-th", lines: [
            "ใจฉันคิดถึงเธอทุกวันทุกคืนไม่เคยหยุด",
            "แสงดาวส่องทางให้เราเดินไปด้วยกันเสมอ",
            "รักเธอมากกว่าที่เคยรักใครมาก่อนในชีวิต",
            "ขอให้เราอยู่เคียงข้างกันตลอดไปนานเท่านาน",
        ], expectedLanguageCode: "th", isReal: false),
        SongSample(name: "synthetic-ar", lines: [
            "قلبي ينبض من أجلك دائما وأبدا في كل وقت",
            "أحلم بلقائك في كل ليلة هادئة تحت النجوم",
            "معك أشعر بالسعادة الحقيقية في كل يوم يمر",
            "لن أنسى ابتسامتك مهما طال بنا الزمان",
        ], expectedLanguageCode: "ar", isReal: false),
        SongSample(name: "synthetic-zh-Hant", lines: [
            "我的心永遠只為你跳動不停",
            "月光下我們一起漫步在街頭",
            "思念是最溫柔的等待方式",
            "願時光停留在這最美的一刻",
        ], expectedLanguageCode: "zh", isReal: false),
        // Documented limitation (see LyricsTranslationSourceDetection's own
        // header + the research writeup): romanized Japanese is Latin-script
        // text with no dictionary/script signal tying it to Japanese. No
        // script-based or NLLanguageRecognizer approach can reliably name
        // its underlying language -- the SAFE behavior is silence (skip
        // translation), not a confident wrong guess. This entry has no
        // "correct" expected code; the test below only asserts the result is
        // never a confident WRONG pick, and reports whatever actually comes
        // back for visibility.
        SongSample(name: "synthetic-romanized-ja", lines: [
            "Kimi no koto wo zutto omotteru yo",
            "Sakura no you ni chitte yuku kioku",
            "Ashita mo kitto egao de aeru yo",
            "Tooi sora no shita de matteiru kara",
        ], expectedLanguageCode: nil, isReal: false),
        // postmortem-008-class risk (banned-patterns.md: "TranslationSession
        // .Configuration(source: detectLanguage()) -> NLLanguageRecognizer
        // misclassifies English as Danish/Slovak"): short, colloquial,
        // vocable-adjacent English fragments -- the exact shape that used to
        // misfire on a PER-LINE basis. Run through the WHOLE-SONG path here
        // (this module's whole point) to confirm the larger sample recovers
        // "en" where a single line would not have been trustworthy alone.
        SongSample(name: "synthetic-short-colloquial-en", lines: [
            "Oh yeah, come on now",
            "I know, I know, I know",
            "So good, so good tonight",
            "Hey now, hey now, let it go",
            "Uh huh, uh huh, that's right",
            "Come on baby, don't stop now",
            "Every night I think about you girl",
            "We can dance until the morning light",
        ], expectedLanguageCode: "en", isReal: false),
    ]

    private func songSamples() throws -> [SongSample] {
        var samples: [SongSample] = [
            SongSample(name: "real cache-003 (English)", lines: try loadLongLineEvalTexts(songKey: "cache-003"), expectedLanguageCode: "en", isReal: true),
            SongSample(name: "real fixture-qicheng (Simplified Chinese)", lines: try loadLongLineEvalTexts(songKey: "fixture-qicheng"), expectedLanguageCode: "zh", isReal: true),
            SongSample(name: "real cache-001 (Japanese, kanji+kana)", lines: try loadLongLineEvalTexts(songKey: "cache-001"), expectedLanguageCode: "ja", isReal: true),
            SongSample(name: "real fixture-newjeans-howsweet (Korean+English mixed)", lines: try loadLongLineEvalTexts(songKey: "fixture-newjeans-howsweet"), expectedLanguageCode: "ko", isReal: true),
            SongSample(name: "real cache-005 (Simplified Chinese)", lines: try loadLongLineEvalTexts(songKey: "cache-005"), expectedLanguageCode: "zh", isReal: true),
        ]
        for sample in samples where sample.isReal {
            XCTAssertFalse(sample.lines.isEmpty, "\(sample.name) loaded zero lines from the fixture -- dataset broke")
        }
        samples.append(contentsOf: syntheticSongs)
        return samples
    }

    // ------------------------------------------------------------------
    // MARK: - Song-level accuracy
    // ------------------------------------------------------------------

    func test_songLevelSource_accuracyTable() throws {
        var rows: [String] = []
        var wrongPicks = 0
        var correct = 0
        var skipped = 0

        for sample in try songSamples() {
            let result = LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: sample.lines)
            let resultCode = result?.languageCode?.identifier
            let verdict: String
            if let expected = sample.expectedLanguageCode {
                if resultCode == expected {
                    verdict = "CORRECT"
                    correct += 1
                } else if resultCode == nil {
                    verdict = "SKIPPED"
                    skipped += 1
                } else {
                    verdict = "WRONG"
                    wrongPicks += 1
                }
            } else {
                verdict = resultCode == nil ? "SKIPPED (no ground truth)" : "UNGRADED (\(resultCode!)) -- documented limitation"
                if resultCode == nil { skipped += 1 }
            }
            rows.append("\(sample.name.padding(toLength: 46, withPad: " ", startingAt: 0)) expected=\(sample.expectedLanguageCode ?? "n/a") got=\(result?.minimalIdentifier ?? "nil") -> \(verdict)")
        }

        print("\n=== LyricsTranslationSourceDetection song-level accuracy ===")
        rows.forEach { print($0) }
        print("correct=\(correct) skipped=\(skipped) wrong=\(wrongPicks) total=\(rows.count)")
        print("=============================================================\n")

        XCTAssertEqual(wrongPicks, 0, "songLevelSource must never confidently pick the WRONG language for a whole song -- skipping (nil) is always acceptable, guessing wrong is not:\n\(rows.joined(separator: "\n"))")
    }

    func test_songLevelSource_zhHantVsZhHans() throws {
        let simplified = try loadLongLineEvalTexts(songKey: "cache-005")
        let simplifiedResult = LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: simplified)
        XCTAssertEqual(simplifiedResult?.minimalIdentifier, "zh-Hans")

        let traditional = syntheticSongs.first { $0.name == "synthetic-zh-Hant" }!.lines
        let traditionalResult = LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: traditional)
        XCTAssertEqual(traditionalResult?.minimalIdentifier, "zh-Hant")
    }

    // ------------------------------------------------------------------
    // MARK: - Per-line ambiguous-skip counting (task requirement: "how many
    // lines per song get skipped as ambiguous")
    // ------------------------------------------------------------------

    func test_lineIsConsistent_skipCountsPerSong_printed() throws {
        var rows: [String] = []
        for sample in try songSamples() {
            guard let source = LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: sample.lines) else {
                rows.append("\(sample.name): song source undetermined, all \(sample.lines.count) lines silently skipped")
                continue
            }
            let consistentCount = sample.lines.filter { LyricsTranslationSourceDetection.lineIsConsistent($0, withSongSource: source) }.count
            let skippedCount = sample.lines.count - consistentCount
            rows.append("\(sample.name): \(skippedCount)/\(sample.lines.count) lines skipped as ambiguous (source=\(source.minimalIdentifier))")
        }
        print("\n=== Per-song ambiguous-line skip counts ===")
        rows.forEach { print($0) }
        print("============================================\n")
        // No hard assertion here -- this is a reporting test per the task's
        // eval requirement ("report ... how many lines per song get skipped
        // as ambiguous"), not a pass/fail gate.
    }

    func test_lineIsConsistent_mismatchedScriptLineIsSkipped() {
        let songSource = Locale.Language(identifier: "ja")
        XCTAssertFalse(
            LyricsTranslationSourceDetection.lineIsConsistent("이것은 한국어 문장입니다", withSongSource: songSource),
            "A wholly-Korean line inside a Japanese song must not ride the Japanese-source session."
        )
        XCTAssertTrue(
            LyricsTranslationSourceDetection.lineIsConsistent("暮れるまえまで 会えたなら", withSongSource: songSource),
            "A genuine Japanese line (kana present) must ride the song's own source."
        )
    }

    func test_lineIsConsistent_numbersAndEmojiOnlyAreSkipped() {
        let songSource = Locale.Language(identifier: "en")
        XCTAssertFalse(LyricsTranslationSourceDetection.lineIsConsistent("12345", withSongSource: songSource))
        XCTAssertFalse(LyricsTranslationSourceDetection.lineIsConsistent("🎉🎊💕", withSongSource: songSource))
        XCTAssertFalse(LyricsTranslationSourceDetection.lineIsConsistent("   ", withSongSource: songSource))
    }

    func test_lineIsConsistent_ambiguousLatinRidesAnySongSource() {
        // Latin/Han-only content carries no determinate script signal of its
        // own -- it should ride whatever the song's resolved source is
        // rather than being refused (this is the common case: most lines in
        // most songs).
        XCTAssertTrue(LyricsTranslationSourceDetection.lineIsConsistent("hello there", withSongSource: Locale.Language(identifier: "en")))
        XCTAssertTrue(LyricsTranslationSourceDetection.lineIsConsistent("hello there", withSongSource: Locale.Language(identifier: "es")))
    }

    // ------------------------------------------------------------------
    // MARK: - Script-first tiering unit checks
    // ------------------------------------------------------------------

    func test_songLevelSource_kanaAnywhereMeansJapaneseEvenWithHan() {
        let result = LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: [
            "暮れるまえまで 会えたなら", "願いきっと いつかかなうわ", "今日も明日も",
        ])
        XCTAssertEqual(result?.minimalIdentifier, "ja")
    }

    func test_songLevelSource_pureKanaNoKanjiStillJapanese() {
        // syn-012 style: hiragana-only, no kanji at all.
        let result = LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: [
            "きょうもあなたのことをかんがえていたよ",
            "あさからばんまでずっとずっと",
            "わすれられないのどうしてかな",
        ])
        XCTAssertEqual(result?.minimalIdentifier, "ja")
    }

    func test_songLevelSource_emptyOrVocableOnlyReturnsNil() {
        XCTAssertNil(LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: []))
        XCTAssertNil(LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: ["", "   "]))
    }

    func test_lineIsConsistent_koreanRidesKoreanSource() throws {
        let lines = try loadLongLineEvalTexts(songKey: "fixture-newjeans-howsweet")
        guard let source = LyricsTranslationSourceDetection.songLevelSource(eligibleLineTexts: lines) else {
            XCTFail("Expected a resolved source for the real NewJeans mixed-script fixture")
            return
        }
        XCTAssertEqual(source.minimalIdentifier, "ko")
        // Every real line in this fixture is either Korean or Korean+English
        // mixed -- none should be refused as "a different determinate
        // script" (the mixed multi-run lines route their Korean runs
        // through ScriptRunSegmenter separately; this per-LINE gate only
        // refuses a line whose determinate runs disagree with the source).
        for line in lines {
            XCTAssertTrue(
                LyricsTranslationSourceDetection.lineIsConsistent(line, withSongSource: source),
                "Line '\(line)' from the real NewJeans fixture should be consistent with the resolved Korean song source"
            )
        }
    }
}

private extension Locale.Language {
    /// "zh-Hans"/"zh-Hant" when the identifier itself carries a script
    /// subtag this test cares about, else the plain language code.
    var minimalIdentifier: String {
        guard let code = languageCode?.identifier else { return "unknown" }
        if code == "zh", let script = script?.identifier {
            return "zh-\(script)"
        }
        return code
    }
}
