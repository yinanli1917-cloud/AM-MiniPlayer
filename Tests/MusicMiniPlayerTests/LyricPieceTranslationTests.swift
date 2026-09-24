import NaturalLanguage
import XCTest
@testable import MusicMiniPlayerCore

/// Pure-logic tests + eval for LyricPieceTranslation.
///
/// Original scope (Phase 2, 2026-09-22 founder decision): every Plan-A split
/// piece gets its own translation, overriding the interim "translation on
/// the first piece only". No Translation-framework calls needed for this
/// layer -- a plain dictionary stands in for the async per-piece cache tier
/// 2 would eventually populate.
///
/// 2026-09-23 addition: the machine-origin tests above are UNCHANGED (all
/// call `pieceTranslations` with the default `isHumanTranslation: false`,
/// preserving their exact pre-2026-09-23 behavior/assertions). New tests
/// below cover the founder's same-day follow-up rule: a HUMAN-origin line
/// (`isHumanTranslation: true`) never machine-translates its pieces --
/// instead the human translation itself is hard-split (tier `.humanSplit`).
final class LyricPieceTranslationTests: XCTestCase {

    private func fakeCache(_ table: [String: String]) -> (String) -> String? {
        { table[$0] }
    }

    // ------------------------------------------------------------------
    // MARK: - Tier 1: clause alignment
    // ------------------------------------------------------------------

    func test_clauses_splitsOnStrongAndWeakPunctuation() {
        XCTAssertEqual(
            LyricPieceTranslation.clauses(in: "直到时间尽头，我都会等你"),
            ["直到时间尽头，", "我都会等你"]
        )
        XCTAssertEqual(
            LyricPieceTranslation.clauses(in: "Hello there. How are you?"),
            ["Hello there.", "How are you?"]
        )
        XCTAssertEqual(LyricPieceTranslation.clauses(in: "no punctuation here"), ["no punctuation here"])
    }

    func test_clauseAligned_pairsInOrderWhenCountsAndLengthOrderMatch() {
        // Original split exactly at the comma; translation also splits at a
        // comma into the SAME count, with an UNAMBIGUOUS length gap on both
        // sides (piece/clause 2 several times longer than piece/clause 1) --
        // large enough that ordinary translation-phrasing variance (see
        // pt-001/pt-002 in the eval dataset, and lengthRankPermutation's own
        // doc comment) cannot flip the relative order.
        let pieces = ["Hi,", "this is a much longer trailing piece with many extra words to pad it out"]
        let translation = "嗨，这是一段长得多的后半部分带着很多额外的字词让它变得又臭又长"
        let aligned = LyricPieceTranslation.clauseAlignedTranslations(originalPieces: pieces, fullTranslation: translation)
        XCTAssertEqual(aligned, LyricPieceTranslation.clauses(in: translation))
    }

    func test_clauseAligned_rejectsCountMismatch() {
        let pieces = ["Line one,", "line two"]
        let translation = "第一句，第二句，第三句"
        XCTAssertNil(LyricPieceTranslation.clauseAlignedTranslations(originalPieces: pieces, fullTranslation: translation))
    }

    func test_clauseAligned_rejectsWhenOriginalNotSplitAtClauseBoundary() {
        // Original pieces don't end at clause punctuation (a mid-phrase
        // width-driven cut) -- must not pretend a clause-level pairing.
        let pieces = ["I will wait for you until", "the end of time"]
        let translation = "我会等你直到，时间的尽头"
        XCTAssertNil(LyricPieceTranslation.clauseAlignedTranslations(originalPieces: pieces, fullTranslation: translation))
    }

    /// The task's own documented example: clause COUNT matches (2 == 2) but
    /// the Chinese clause order is reversed relative to the English -- tier 1
    /// must NOT pair these by position. This is exactly the length-rank
    /// mismatch the module's conservative heuristic is designed to catch:
    /// English piece 1 ("I'll wait for you,") is shorter than piece 2
    /// ("until the end of time"), but Chinese clause 1 ("直到时间尽头，") is
    /// LONGER than clause 2 ("我都会等你") -- the relative order flips.
    func test_clauseAligned_rejectsReorderedClausesViaLengthRankMismatch() {
        let pieces = ["I'll wait for you,", "until the end of time"]
        let translation = "直到时间尽头，我都会等你"
        XCTAssertNil(
            LyricPieceTranslation.clauseAlignedTranslations(originalPieces: pieces, fullTranslation: translation),
            "Reordered clauses with matching count but flipped relative length order must be rejected, not positionally mispaired."
        )
    }

    func test_clauseAligned_nilTranslationOrEmptyReturnsNil() {
        XCTAssertNil(LyricPieceTranslation.clauseAlignedTranslations(originalPieces: ["a,", "b"], fullTranslation: nil))
        XCTAssertNil(LyricPieceTranslation.clauseAlignedTranslations(originalPieces: ["a,", "b"], fullTranslation: "   "))
    }

    func test_clauseAligned_singlePieceNeverAligns() {
        XCTAssertNil(LyricPieceTranslation.clauseAlignedTranslations(originalPieces: ["only one piece"], fullTranslation: "只有一段"))
    }

    // ------------------------------------------------------------------
    // MARK: - Full three-tier decision
    // ------------------------------------------------------------------

    func test_pieceTranslations_unsplitLineCarriesWholeTranslationVerbatim() {
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: ["only one piece"],
            fullTranslation: "唯一的一段",
            cache: fakeCache([:])
        )
        XCTAssertEqual(translations, ["唯一的一段"])
        XCTAssertEqual(tiers, [.fallbackFirstPiece])
    }

    func test_pieceTranslations_tier1WinsOverTier2WhenBothAvailable() {
        let pieces = ["Hi,", "this is a much longer trailing piece with many extra words to pad it out"]
        let translation = "嗨，这是一段长得多的后半部分带着很多额外的字词让它变得又臭又长"
        let cache = fakeCache([pieces[0]: "CACHED WRONG", pieces[1]: "CACHED WRONG 2"])
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces, fullTranslation: translation, cache: cache
        )
        XCTAssertEqual(tiers, [.clauseAligned, .clauseAligned])
        XCTAssertEqual(translations, LyricPieceTranslation.clauses(in: translation))
    }

    func test_pieceTranslations_tier2CacheHitPerPiece() {
        let pieces = ["first piece text", "second piece text"]
        let cache = fakeCache([
            "first piece text": "第一段翻译",
            "second piece text": "第二段翻译",
        ])
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces, fullTranslation: "整行翻译不该被用到", cache: cache
        )
        XCTAssertEqual(translations, ["第一段翻译", "第二段翻译"])
        XCTAssertEqual(tiers, [.perPieceCache, .perPieceCache])
    }

    func test_pieceTranslations_tier3FallbackOnFirstPieceOnlyWhenNothingElseAvailable() {
        let pieces = ["first piece text", "second piece text", "third piece text"]
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces, fullTranslation: "整行翻译", cache: fakeCache([:])
        )
        XCTAssertEqual(translations, ["整行翻译", nil, nil])
        XCTAssertEqual(tiers, [.fallbackFirstPiece, .none, .none])
    }

    func test_pieceTranslations_mixedTiersPerPiece() {
        // Piece 0: no cache, gets the fallback. Piece 1: cached. Piece 2:
        // neither -- must be `.none` (queued for async translation by the
        // caller), never silently duplicating the full translation.
        let pieces = ["alpha piece", "beta piece", "gamma piece"]
        let cache = fakeCache(["beta piece": "贝塔"])
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces, fullTranslation: "整行翻译", cache: cache
        )
        XCTAssertEqual(translations, ["整行翻译", "贝塔", nil])
        XCTAssertEqual(tiers, [.fallbackFirstPiece, .perPieceCache, .none])
    }

    func test_pieceTranslations_firstPieceCacheHitBeatsFallback() {
        // Even segment 0 should prefer an accurate per-piece cache hit over
        // the blunt whole-line fallback, once one becomes available.
        let pieces = ["alpha piece", "beta piece"]
        let cache = fakeCache(["alpha piece": "阿尔法"])
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces, fullTranslation: "整行翻译", cache: cache
        )
        XCTAssertEqual(translations, ["阿尔法", nil])
        XCTAssertEqual(tiers, [.perPieceCache, .none])
    }

    func test_pieceTranslations_noOriginalPiecesReturnsEmpty() {
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: [], fullTranslation: "x", cache: fakeCache([:])
        )
        XCTAssertTrue(translations.isEmpty)
        XCTAssertTrue(tiers.isEmpty)
    }

    func test_pieceTranslations_noTranslationAtAllLeavesEveryPieceNilOrNone() {
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: ["a", "b"], fullTranslation: nil, cache: fakeCache([:])
        )
        XCTAssertEqual(translations, [nil, nil])
        XCTAssertEqual(tiers, [.none, .none])
    }

    // ------------------------------------------------------------------
    // MARK: - Extended eval dataset (Tests/Fixtures/piece_translation_eval.json)
    // ------------------------------------------------------------------
    //
    // A SEPARATE fixture from long_line_eval.json (rather than extending it
    // in place): long_line_eval.json's 54-row shape is pinned by
    // LongLineEvalTests' own contract test (test_mirrorMatchesProductionSource
    // and the (a)-(f) acceptance assertions), and this eval needs a DIFFERENT
    // shape of row (original pieces + a translation + an expected tier),
    // which those tests don't have fields for. Extending the same file would
    // either break that pinning or require rows this module ignores. This is
    // this task's own reading of "extend the long-line dataset" -- noted here
    // and in the research writeup as the interpretation taken.

    private struct PieceEvalCase: Decodable {
        let id: String
        let note: String
        let originalPieces: [String]
        let fullTranslation: String?
        let expectedTier: String // "clauseAligned" | "perPieceCache" | "fallbackFirstPiece" | "none" | "mixed"
        let cache: [String: String]?
    }

    private func loadPieceEvalCases() throws -> [PieceEvalCase] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/piece_translation_eval.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PieceEvalCase].self, from: data)
    }

    func test_extendedDataset_tierDistributionAndInvariants() throws {
        let cases = try loadPieceEvalCases()
        XCTAssertFalse(cases.isEmpty, "piece_translation_eval.json must not be empty")

        var tierCounts: [String: Int] = [:]
        var midClauseCuts = 0
        var missingPieceCountWithoutTier3 = 0
        var sampledClauseAlignedPairs: [String] = []

        for testCase in cases {
            let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
                originalPieces: testCase.originalPieces,
                fullTranslation: testCase.fullTranslation,
                cache: fakeCache(testCase.cache ?? [:])
            )
            XCTAssertEqual(translations.count, testCase.originalPieces.count, "\(testCase.id): translation count must match piece count")
            XCTAssertEqual(tiers.count, testCase.originalPieces.count, "\(testCase.id): tier count must match piece count")

            for tier in tiers { tierCounts[String(describing: tier), default: 0] += 1 }

            // Metric: 0 translations cut mid-clause -- every NON-nil
            // translation piece must be a recognizable whole clause/fallback,
            // never a truncated fragment ending without terminal punctuation
            // AND shorter than the piece it covers in a way that suggests a
            // hard character-count slice. Since this module only ever
            // assigns a cached whole piece translation, a full-line
            // fallback, or a whole clause -- NEVER a substring slice -- the
            // structural guarantee is that every non-nil translation is
            // exactly one of: a clause from `clauses(in:)`, a cache value
            // verbatim, or the full `fullTranslation` verbatim. Verify that
            // directly instead of guessing at "looks truncated" heuristics.
            let translationClauses = testCase.fullTranslation.map(LyricPieceTranslation.clauses(in:)) ?? []
            for (index, translation) in translations.enumerated() {
                guard let translation else { continue }
                let isClause = translationClauses.contains(translation)
                let isCacheValue = (testCase.cache ?? [:]).values.contains(translation)
                let isFullFallback = translation == testCase.fullTranslation
                if !(isClause || isCacheValue || isFullFallback) {
                    midClauseCuts += 1
                    XCTFail("\(testCase.id) piece \(index): translation '\(translation)' is neither a whole clause, a whole cache value, nor the full fallback -- looks like a mid-text cut")
                }
            }

            // Metric: every piece has a translation unless tier 3 (i.e. only
            // pieces AFTER the first may legitimately be nil, and only when
            // no tier-1/2 covered them).
            for (index, tier) in tiers.enumerated() where tier == .none {
                if index == 0 {
                    missingPieceCountWithoutTier3 += 1
                }
            }

            if tiers.first == .clauseAligned {
                sampledClauseAlignedPairs.append("\(testCase.id): \(zip(testCase.originalPieces, translations.map { $0 ?? "nil" }).map { "\($0)=>\($1)" }.joined(separator: " | "))")
            }

            // Cross-check the fixture's own `expectedTier` label for the
            // FIRST piece against what the implementation actually produced
            // -- catches drift between the hand-labeled dataset and the
            // real tier decision.
            if testCase.expectedTier != "mixed" {
                let actualTierLabel = String(describing: tiers.first ?? .none)
                XCTAssertEqual(
                    actualTierLabel, testCase.expectedTier,
                    "\(testCase.id) (\(testCase.note)): expected first-piece tier '\(testCase.expectedTier)', got '\(actualTierLabel)'"
                )
            }
        }

        print("\n=== LyricPieceTranslation extended eval: tier distribution ===")
        for (tier, count) in tierCounts.sorted(by: { $0.key < $1.key }) {
            print("\(tier): \(count)")
        }
        print("mid-clause cuts: \(midClauseCuts) (must be 0)")
        print("piece 0 with tier .none (should be 0 -- piece 0 always has tier1/2/3): \(missingPieceCountWithoutTier3)")
        print("--- sampled tier-1 clause-aligned pairings (sanity check) ---")
        sampledClauseAlignedPairs.forEach { print($0) }
        print("================================================================\n")

        XCTAssertEqual(midClauseCuts, 0, "No translation may ever be a mid-clause/mid-text cut")
        XCTAssertEqual(missingPieceCountWithoutTier3, 0, "The first piece of a split line must always have a translation (tier 1, 2, or the tier-3 fallback) unless there is no translation at all for the whole line")
    }

    // ------------------------------------------------------------------
    // MARK: - 2026-09-23: human-origin lines never machine-translate pieces
    // ------------------------------------------------------------------

    /// A `cache` closure that fails the test if it is ever invoked -- proves
    /// a human-origin line's pieces never even CONSULT the machine
    /// per-piece cache, let alone register for async translation.
    private func forbiddenCache(_ file: StaticString = #filePath, _ line: UInt = #line) -> (String) -> String? {
        { text in
            XCTFail("cache(\(text)) must never be called for a human-origin line", file: file, line: line)
            return nil
        }
    }

    func test_pieceTranslations_humanOrigin_neverConsultsMachineCache() {
        let pieces = ["今晚留在我身边", "永远不要放开我的手"]
        let (_, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces,
            pieceWeights: pieces.map { Double($0.count) },
            fullTranslation: "Stay with me tonight and never let go",
            isHumanTranslation: true,
            cache: forbiddenCache()
        )
        XCTAssertFalse(tiers.contains(.perPieceCache), "human-origin pieces must never resolve via .perPieceCache")
    }

    func test_pieceTranslations_humanOrigin_clauseAlignedStillWinsWhenClausesMatch() {
        let pieces = ["Hi,", "this is a much longer trailing piece with many extra words to pad it out"]
        let translation = "嗨，这是一段长得多的后半部分带着很多额外的字词让它变得又臭又长"
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces,
            pieceWeights: pieces.map { Double($0.count) },
            fullTranslation: translation,
            isHumanTranslation: true,
            cache: forbiddenCache()
        )
        XCTAssertEqual(tiers, [.clauseAligned, .clauseAligned])
        XCTAssertEqual(translations, LyricPieceTranslation.clauses(in: translation))
    }

    /// The founder's own documented reordered-clause example (pt-003):
    /// under the 2026-09-23 rule the length-rank guard is SKIPPED for human
    /// lines, so this now clause-aligns (accepting the risk of an imperfect
    /// pairing) instead of falling through to tier 3 -- the exact opposite
    /// of the machine-origin default tested in
    /// `test_clauseAligned_rejectsReorderedClausesViaLengthRankMismatch`
    /// above.
    func test_pieceTranslations_humanOrigin_acceptsReorderedClausesWithoutLengthRankGuard() {
        let pieces = ["I'll wait for you,", "until the end of time"]
        let translation = "直到时间尽头，我都会等你"
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces,
            pieceWeights: pieces.map { Double($0.count) },
            fullTranslation: translation,
            isHumanTranslation: true,
            cache: forbiddenCache()
        )
        XCTAssertEqual(tiers, [.clauseAligned, .clauseAligned])
        XCTAssertEqual(translations, LyricPieceTranslation.clauses(in: translation))
        // The SAME inputs with the default (machine) guard still reject --
        // pinning that the guard's presence/absence is what changed, not
        // some other behavior.
        XCTAssertNil(LyricPieceTranslation.clauseAlignedTranslations(originalPieces: pieces, fullTranslation: translation))
    }

    func test_humanTranslationSplit_simpleSpaceSeparated_deterministic() {
        // "你好呀 世界很大" = 你(0)好(1)呀(2) space(3) 世(4)界(5)很(6)大(7) --
        // the only tier-1 (space) candidate is at charIndex 4, matching the
        // 50/50 weight target exactly, and both resulting segments (3 and 4
        // glyphs) clear the orphan floor.
        let result = LyricPieceTranslation.humanTranslationSplit(
            originalPieces: ["a", "b"],
            pieceWeights: [1, 1],
            fullTranslation: "你好呀 世界很大"
        )
        XCTAssertEqual(result, ["你好呀", "世界很大"])
    }

    func test_humanTranslationSplit_neverBreaksInsideBracketsOrQuotes() {
        // The only comma sits INSIDE parentheses -- must not be used as a
        // break; falls back to a tokenizer/space candidate outside the
        // brackets, or to a single unsplit segment if none exists.
        let translation = "他说了一句话（你好，世界）然后就走了"
        let result = LyricPieceTranslation.humanTranslationSplit(
            originalPieces: ["a", "b"],
            pieceWeights: [1, 1],
            fullTranslation: translation
        )
        // Whatever the split (or non-split) is, no piece may contain a
        // dangling unmatched bracket -- the break, if any, was not taken
        // inside the parentheses.
        if let result, let first = result[0], let second = result[1] {
            XCTAssertEqual(first.filter { $0 == "（" }.count, first.filter { $0 == "）" }.count, "piece 0 must not contain an unmatched bracket")
            XCTAssertEqual(second.filter { $0 == "（" }.count, second.filter { $0 == "）" }.count, "piece 1 must not contain an unmatched bracket")
        }
    }

    func test_humanTranslationSplit_neverLeavesOrphanBelowThreeGlyphs() {
        // "你好 x" -- a 2-character tail after the space is an orphan (< 3
        // glyphs); the trailing-orphan trim must drop that break rather than
        // hand out a 1-character piece.
        let result = LyricPieceTranslation.humanTranslationSplit(
            originalPieces: ["a", "b"],
            pieceWeights: [1, 1],
            fullTranslation: "你好世界啊 x"
        )
        // Either no split happened (nil) or, if one did, no non-nil segment
        // is an orphan.
        if let result {
            for segment in result.compactMap({ $0 }) {
                XCTAssertGreaterThan(segment.count, 2, "no segment may be an orphan of <=2 glyphs")
            }
        }
    }

    func test_humanTranslationSplit_tooShortTranslation_wholeTextOnFirstPieceOnly() {
        let result = LyricPieceTranslation.humanTranslationSplit(
            originalPieces: ["a", "b"],
            pieceWeights: [1, 1],
            fullTranslation: "好的"
        )
        XCTAssertEqual(result, ["好的", nil])
    }

    func test_humanTranslationSplit_singlePieceReturnsNil() {
        XCTAssertNil(LyricPieceTranslation.humanTranslationSplit(originalPieces: ["only one"], pieceWeights: [1], fullTranslation: "只有一个"))
    }

    func test_humanTranslationSplit_emptyTranslationReturnsNil() {
        XCTAssertNil(LyricPieceTranslation.humanTranslationSplit(originalPieces: ["a", "b"], pieceWeights: [1, 1], fullTranslation: "   "))
    }

    func test_humanTranslationSplit_mismatchedWeightsFallsBackToEqualShares() {
        // pieceWeights.count != originalPieces.count -- must not crash;
        // falls back to equal shares (documented safety net).
        let result = LyricPieceTranslation.humanTranslationSplit(
            originalPieces: ["a", "b"],
            pieceWeights: [1],
            fullTranslation: "你好呀 世界很大"
        )
        XCTAssertEqual(result, ["你好呀", "世界很大"])
    }

    // ------------------------------------------------------------------
    // MARK: - Extended eval dataset:
    // Fixtures/piece_translation_human_split_eval.json (2026-09-23, 36
    // cases across spaces / punctuationOnly / continuous / japanese /
    // veryShort / translationLongerThanOriginal / wordLevelUnevenTiming)
    // ------------------------------------------------------------------

    private struct HumanSplitEvalCase: Decodable {
        let id: String
        let category: String
        let note: String
        let originalPieces: [String]
        let fullTranslation: String
        let weightMode: String // "displayLength" | "timing"
        let durations: [Double]?
        let allowNilBeyondFirst: Bool
    }

    private func loadHumanSplitEvalCases() throws -> [HumanSplitEvalCase] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/piece_translation_human_split_eval.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([HumanSplitEvalCase].self, from: data)
    }

    /// Independent (NOT reusing LyricPieceTranslation's own candidate scan)
    /// word-span computation via a fresh `NLTokenizer(unit: .word)` pass
    /// over the FULL translation -- used to verify "0 breaks inside a word"
    /// from outside the implementation under test.
    private func independentWordSpans(_ text: String) -> [(lower: Int, upper: Int)] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var spans: [(Int, Int)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            spans.append((lower, upper))
            return true
        }
        return spans
    }

    /// Locates each of `segments` as a contiguous run of Characters within
    /// `text`, IN ORDER, starting each search after the previous match's
    /// end. Returns nil for a segment it cannot find (should not happen for
    /// this dataset's segments, which are always literal substrings of
    /// their translation by construction). Used both for the mid-word-break
    /// check and the share-deviation measurement.
    private func locateSegmentEndOffsets(_ segments: [String], in text: String) -> [Int]? {
        let chars = Array(text)
        var searchStart = 0
        var endOffsets: [Int] = []
        for segment in segments {
            let segChars = Array(segment)
            guard !segChars.isEmpty else { return nil }
            var found: Int?
            var i = searchStart
            while i + segChars.count <= chars.count {
                if Array(chars[i..<(i + segChars.count)]) == segChars {
                    found = i
                    break
                }
                i += 1
            }
            guard let start = found else { return nil }
            let end = start + segChars.count
            endOffsets.append(end)
            searchStart = end
        }
        return endOffsets
    }

    func test_extendedHumanSplitDataset_invariantsAndDeviationStats() throws {
        let cases = try loadHumanSplitEvalCases()
        XCTAssertGreaterThanOrEqual(cases.count, 30, "human-split eval dataset must have at least 30 cases")

        var tierCounts: [String: Int] = [:]
        var midWordBreakViolations = 0
        var midWordBreaksChecked = 0
        var orphanViolations = 0
        var emptyBeyondFirstUnexpected = 0
        var deviations: [Double] = []
        var samplePairs: [String] = []

        for testCase in cases {
            let weights: [Double]
            switch testCase.weightMode {
            case "timing":
                guard let durations = testCase.durations else {
                    XCTFail("\(testCase.id): weightMode=timing requires durations")
                    continue
                }
                weights = durations
            default:
                weights = testCase.originalPieces.map { Double($0.count) }
            }

            let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
                originalPieces: testCase.originalPieces,
                pieceWeights: weights,
                fullTranslation: testCase.fullTranslation,
                isHumanTranslation: true,
                cache: forbiddenCache()
            )
            XCTAssertEqual(translations.count, testCase.originalPieces.count, "\(testCase.id): translation count must match piece count")
            XCTAssertEqual(tiers.count, testCase.originalPieces.count, "\(testCase.id): tier count must match piece count")
            XCTAssertFalse(tiers.contains(.perPieceCache), "\(testCase.id): human-origin pieces must never resolve via .perPieceCache")

            for tier in tiers { tierCounts[String(describing: tier), default: 0] += 1 }

            // Piece 0 must always carry a translation (fullTranslation is
            // always non-empty in this dataset).
            XCTAssertNotNil(translations[0], "\(testCase.id): piece 0 must always have a translation")

            // Nils beyond piece 0 are only expected for the veryShort
            // category (fixture-flagged via allowNilBeyondFirst).
            let nilsBeyondFirst = translations.dropFirst().filter { $0 == nil }.count
            if nilsBeyondFirst > 0, !testCase.allowNilBeyondFirst {
                emptyBeyondFirstUnexpected += nilsBeyondFirst
                XCTFail("\(testCase.id): unexpected nil piece(s) beyond the first (category=\(testCase.category))")
            }

            let nonNilSegments = translations.compactMap { $0 }

            // Orphan check: skip when there is only ONE non-nil segment for
            // the whole line (the "whole translation on piece 0" shape,
            // legitimately short by design in the veryShort category).
            if nonNilSegments.count > 1 {
                for segment in nonNilSegments {
                    if segment.count <= 2 {
                        orphanViolations += 1
                        XCTFail("\(testCase.id): orphan segment '\(segment)' (<=2 glyphs) among \(nonNilSegments.count) segments")
                    }
                }
            }

            // Mid-word-break + deviation check: only meaningful when a REAL
            // split happened (>1 non-nil segment), verified via an
            // INDEPENDENT NLTokenizer pass over the translation (not the
            // implementation's own candidate scan).
            if nonNilSegments.count > 1,
               let endOffsets = locateSegmentEndOffsets(nonNilSegments, in: testCase.fullTranslation) {
                let spans = independentWordSpans(testCase.fullTranslation)
                let totalChars = testCase.fullTranslation.count
                var cumulativeWeight = 0.0
                let totalWeight = weights.reduce(0, +)
                for (index, endOffset) in endOffsets.enumerated() where index < endOffsets.count - 1 {
                    midWordBreaksChecked += 1
                    let insideAWord = spans.contains { endOffset > $0.lower && endOffset < $0.upper }
                    if insideAWord {
                        midWordBreakViolations += 1
                        XCTFail("\(testCase.id): break at offset \(endOffset) falls inside an NLTokenizer word span")
                    }

                    // Deviation: compare this break's achieved position
                    // share (in the TRANSLATION's own character count)
                    // against the target share derived from the ORIGINAL
                    // pieces' weights -- the two are different units (one
                    // is a position in the translation, the other a share
                    // of the original line), so this measures how well
                    // position-matching approximates the intended split,
                    // not an exact-equality contract.
                    cumulativeWeight += weights[index]
                    let targetShare = cumulativeWeight / totalWeight
                    let achievedShare = Double(endOffset) / Double(totalChars)
                    deviations.append(abs(achievedShare - targetShare))
                }
            }

            samplePairs.append(
                "\(testCase.id) [\(testCase.category)] tiers=\(tiers.map { String(describing: $0) }): " +
                zip(testCase.originalPieces, translations.map { $0 ?? "∅" }).map { "\($0)=>\($1)" }.joined(separator: " | ")
            )
        }

        let sortedDeviations = deviations.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sortedDeviations.isEmpty else { return 0 }
            let index = min(sortedDeviations.count - 1, Int(Double(sortedDeviations.count - 1) * p))
            return sortedDeviations[index]
        }

        print("\n=== LyricPieceTranslation human-split extended eval ===")
        print("cases: \(cases.count)")
        for (tier, count) in tierCounts.sorted(by: { $0.key < $1.key }) {
            print("tier \(tier): \(count)")
        }
        print("mid-word breaks checked: \(midWordBreaksChecked), violations: \(midWordBreakViolations) (must be 0)")
        print("orphan violations: \(orphanViolations) (must be 0)")
        print("unexpected nil-beyond-first: \(emptyBeyondFirstUnexpected) (must be 0)")
        print("share deviation -- median: \(String(format: "%.4f", percentile(0.5))), p90: \(String(format: "%.4f", percentile(0.9))), n=\(deviations.count)")
        print("--- every (original piece -> translation piece) pair, all \(cases.count) cases ---")
        samplePairs.forEach { print($0) }
        print("========================================================\n")

        XCTAssertEqual(midWordBreakViolations, 0)
        XCTAssertEqual(orphanViolations, 0)
        XCTAssertEqual(emptyBeyondFirstUnexpected, 0)
    }
}
