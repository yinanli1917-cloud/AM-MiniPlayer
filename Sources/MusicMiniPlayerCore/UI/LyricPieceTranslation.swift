/**
 * [INPUT]: Foundation only (pure text logic -- no Translation framework, no
 *          LyricsService). Reuses no other module; the punctuation sets
 *          mirror LyricDisplaySegmenter's strong/weak boundary characters on
 *          purpose (same notion of "clause").
 * [OUTPUT]: Exports LyricPieceTranslation.clauses/clauseAlignedTranslations/
 *           pieceTranslations and LyricPieceTranslationTier.
 * [POS]: UI -- consumed by LyricsView.makeDisplayLyricLines to decide each
 *        Plan-A display piece's translation (2026-09-22 founder decision:
 *        every split piece gets its own translation, overriding the interim
 *        "translation on the first piece only" -- see
 *        docs/lyrics-ux-contract.md §E and
 *        research/translation-popup-and-piece-translation-2026-09-22.md).
 *
 * Three tiers, in priority order, per split line:
 * 1. Clause alignment: the ORIGINAL was split exactly at clause punctuation
 *    AND the line's existing translation (system or lyrics-source) splits at
 *    its OWN clause punctuation into the SAME number of clauses -> pair in
 *    order. Purely positional -- see the documented limitation on
 *    reordered-clause translations below.
 * 2. Otherwise: an async per-piece on-device translation (cached by the
 *    caller, keyed on piece text + source + target -- this module never
 *    talks to a cache or the Translation framework itself, staying a pure
 *    function of its inputs).
 * 3. If unavailable: the FULL translation attaches to the first piece only
 *    (unchanged fallback), later pieces get none. Never chop a translation
 *    by length.
 */

import Foundation

public enum LyricPieceTranslationTier: Equatable {
    /// Tier 1 -- paired against the translation's own clause split, in order.
    case clauseAligned
    /// Tier 2 -- an already-cached per-piece translation (the async pass may
    /// have completed on an earlier call, or a previous width's split
    /// produced and cached the same piece text).
    case perPieceCache
    /// Tier 3 -- the fallback: the piece is segment 0 and carries the FULL
    /// original-line translation, because neither tier 1 nor tier 2 applied.
    case fallbackFirstPiece
    /// No translation at all for this piece (not segment 0, no clause
    /// pairing, no cache hit yet). The caller should register this piece's
    /// text for an async tier-2 translation attempt.
    case none
}

public enum LyricPieceTranslation {

    private static let strongClauseBoundary = ".!?。！？…"
    private static let weakClauseBoundary = ",;:，、；：،؛¿¡"

    /// Splits `text` into clauses at strong/weak punctuation (the same
    /// boundary characters `LyricDisplaySegmenter` treats as sentence/clause
    /// breaks), each clause keeping its own trailing punctuation. Empty
    /// fragments (leading/trailing/doubled punctuation) are dropped.
    public static func clauses(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if strongClauseBoundary.contains(character) || weakClauseBoundary.contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { result.append(trailing) }
        return result
    }

    /// True when `text` ends (after trimming whitespace) with a clause
    /// punctuation character -- the signal that a piece boundary in the
    /// ORIGINAL text was cut exactly at a clause, not mid-phrase.
    private static func endsWithClauseBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return strongClauseBoundary.contains(last) || weakClauseBoundary.contains(last)
    }

    /// Tier 1. Returns nil (no clause-aligned pairing) unless EVERY piece
    /// except the last ends at a clause boundary in the original text,
    /// `fullTranslation` splits into exactly `originalPieces.count` clauses,
    /// AND the two sides' relative clause-length ordering agrees (see
    /// `lengthRankPermutation` below). Purely positional otherwise: pieces
    /// are paired with clauses IN ORDER.
    ///
    /// The length-rank check is a CONSERVATIVE, honestly-imperfect guard
    /// against clause reordering between languages -- e.g. English "I'll
    /// wait for you, until the end of time" (piece 1 shorter, piece 2
    /// longer) vs. Chinese "直到时间尽头，我都会等你" (clause 1 longer,
    /// clause 2 shorter): the clause COUNT matches (2 == 2) but the meaning
    /// is reversed -- Chinese clause 1 translates English piece 2. This
    /// module has no semantic/alignment model, so it cannot PROVE reordering
    /// in general; comparing which clause is relatively longer/shorter on
    /// each side is a cheap proxy that happens to catch this documented
    /// example (and any case where relative length order flips), but for a
    /// 2-piece line with near-equal lengths on both sides it is only
    /// marginally better than a coin flip -- see the eval writeup's tier-1
    /// sampled-pairing table for how often this actually rejects vs. accepts
    /// on the extended dataset.
    public static func clauseAlignedTranslations(
        originalPieces: [String],
        fullTranslation: String?
    ) -> [String]? {
        guard originalPieces.count > 1,
              let fullTranslation, !fullTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let allButLastEndAtClause = originalPieces.dropLast().allSatisfy(endsWithClauseBoundary)
        guard allButLastEndAtClause else { return nil }

        let translationClauses = clauses(in: fullTranslation)
        guard translationClauses.count == originalPieces.count else { return nil }

        let pieceRanks = lengthRankPermutation(originalPieces.map(\.count))
        let clauseRanks = lengthRankPermutation(translationClauses.map(\.count))
        guard pieceRanks == clauseRanks else { return nil }

        return translationClauses
    }

    /// The permutation of `lengths`' indices sorted ascending by length
    /// (ties broken by original index, for stability). Two length arrays
    /// with the SAME permutation have the same relative ordering.
    ///
    /// EMPIRICAL FINDING (this module's own eval,
    /// Tests/Fixtures/piece_translation_eval.json pt-001/pt-002): raw
    /// character count is NOT a reliable cross-language length proxy even
    /// for correctly-ordered translations -- e.g. English "When the rain
    /// falls down," (26 chars) / "I will still be here" (21 chars, piece 1
    /// SHORTER) translates naturally to Chinese "当雨落下时，" (6 chars) /
    /// "我依然在这里等你" (8 chars, clause 1 LONGER) -- the relative order
    /// flips purely from ordinary phrasing variance, not reordering. This
    /// heuristic accepts that cost DELIBERATELY: a false REJECT only costs a
    /// blunt-but-CORRECT tier-3 fallback (the full translation under piece
    /// 0), while a false ACCEPT would show an ACTIVELY WRONG pairing to the
    /// user (the documented "I'll wait for you," example). Given that
    /// asymmetry, this module stays conservative (reject on any rank
    /// mismatch) rather than trying to tune the metric to accept more cases
    /// -- see the eval's printed tier distribution for how often this
    /// actually costs a clause-aligned pairing in practice.
    private static func lengthRankPermutation(_ lengths: [Int]) -> [Int] {
        lengths.indices.sorted { a, b in
            lengths[a] != lengths[b] ? lengths[a] < lengths[b] : a < b
        }
    }

    /// Full three-tier decision for one line's already-split pieces.
    /// `cache` is a synchronous lookup (piece text -> already-translated
    /// text, if any); the caller owns the actual cache/async translation.
    /// Returns one entry per piece in `originalPieces`, matching order.
    public static func pieceTranslations(
        originalPieces: [String],
        fullTranslation: String?,
        cache: (String) -> String?
    ) -> (translations: [String?], tiers: [LyricPieceTranslationTier]) {
        guard !originalPieces.isEmpty else { return ([], []) }
        guard originalPieces.count > 1 else {
            // Not actually split -- the single piece just carries the whole
            // line's translation verbatim (existing simple behavior).
            return ([fullTranslation], [fullTranslation == nil ? .none : .fallbackFirstPiece])
        }

        if let aligned = clauseAlignedTranslations(originalPieces: originalPieces, fullTranslation: fullTranslation) {
            return (aligned.map { $0 }, Array(repeating: .clauseAligned, count: originalPieces.count))
        }

        var translations: [String?] = []
        var tiers: [LyricPieceTranslationTier] = []
        for (index, piece) in originalPieces.enumerated() {
            if let cached = cache(piece) {
                translations.append(cached)
                tiers.append(.perPieceCache)
            } else if index == 0, let fullTranslation, !fullTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translations.append(fullTranslation)
                tiers.append(.fallbackFirstPiece)
            } else {
                translations.append(nil)
                tiers.append(.none)
            }
        }
        return (translations, tiers)
    }
}
