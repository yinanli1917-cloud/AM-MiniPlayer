import XCTest
@testable import MusicMiniPlayerCore

/// Pure-logic tests + eval for LyricPieceTranslation (Phase 2, 2026-09-22
/// founder decision: every Plan-A split piece gets its own translation,
/// overriding the interim "translation on the first piece only"). No
/// Translation-framework calls needed for this layer -- a plain dictionary
/// stands in for the async per-piece cache tier 2 would eventually populate.
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
}
