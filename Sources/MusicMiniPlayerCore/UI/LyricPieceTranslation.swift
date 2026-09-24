/**
 * [INPUT]: Foundation + NaturalLanguage (NLTokenizer(unit: .word) for the
 *          tier-3 word-boundary fallback in `humanTranslationSplit`). Pure
 *          text logic -- no Translation framework, no LyricsService. The
 *          punctuation sets mirror LyricDisplaySegmenter's strong/weak
 *          boundary characters on purpose (same notion of "clause").
 * [OUTPUT]: Exports LyricPieceTranslation.clauses/clauseAlignedTranslations/
 *           humanTranslationSplit/pieceTranslations and
 *           LyricPieceTranslationTier.
 * [POS]: UI -- consumed by LyricsView.makeDisplayLyricLines to decide each
 *        Plan-A display piece's translation.
 *
 * 2026-09-23 founder decision (supersedes the 2026-09-22 "every piece gets
 * its own MACHINE-translated segment" design -- see
 * docs/lyrics-ux-contract.md §E and
 * research/translation-popup-and-piece-translation-2026-09-22.md): per-piece
 * machine (on-device) translation of a line that already has a HUMAN
 * translation (from the lyrics source -- NetEase/QQ/AMLL/Apple TTML etc.,
 * i.e. `translationsAreFromLyricsSource` / non-system origin) reads
 * "重复/生硬" (repetitive, heavy) -- the human whole-line translation and a
 * separately machine-translated piece often say almost the same thing in
 * different words, right next to each other. The fix: for a HUMAN-origin
 * line, never call the Translation framework on its pieces at all. Instead
 * split the human translation ITSELF across the pieces ("smart hard split"):
 *
 * 1. Tier `.clauseAligned` (unchanged mechanism, `enforceLengthRankGuard`
 *    now FALSE for human lines -- see that parameter's doc comment): the
 *    ORIGINAL was cut exactly at clause punctuation and the translation
 *    splits into the same clause count -> pair in order.
 * 2. Tier `.humanSplit` (NEW, human-origin only): the translation is split
 *    at ITS OWN natural boundaries -- clause punctuation, then spaces
 *    (Chinese fan translations often separate clauses with spaces), then
 *    `NLTokenizer(unit: .word)` boundaries -- choosing, for each original
 *    piece boundary, the candidate whose cumulative position best matches
 *    that piece's share of the line (timing share for word-level lines,
 *    display-length share otherwise). Never breaks inside a word, never
 *    leaves an orphan piece of <=2 glyphs, never breaks inside
 *    brackets/quotes. When there are fewer usable candidates than needed,
 *    the remainder merges into the last piece that got a real segment
 *    (documented in `humanTranslationSplit`'s own comment) -- pieces past
 *    that stay nil, never silently duplicating machine-translated text.
 * 3. Tier `.fallbackFirstPiece`: only when neither of the above produced
 *    anything (e.g. no translation at all, or `humanTranslationSplit`
 *    itself found zero usable candidates -- which degrades to exactly this
 *    fallback shape by construction, see that function).
 *
 * A MACHINE-origin line (no human translation -- `isHumanTranslation ==
 * false`, the default) keeps the PRE-EXISTING three-tier pipeline
 * unchanged: clause-aligned (WITH the length-rank guard), then an async
 * per-piece on-device translation cached by the caller (tier
 * `.perPieceCache`), then the tier-3 fallback.
 */

import Foundation
import NaturalLanguage

public enum LyricPieceTranslationTier: Equatable {
    /// Tier 1 -- paired against the translation's own clause split, in order.
    /// Used by both human- and machine-origin lines (the length-rank guard
    /// differs between them; see `clauseAlignedTranslations`).
    case clauseAligned
    /// Tier 2 (human-origin lines only) -- the human translation itself,
    /// hard-split at its own natural boundaries and assigned to this piece
    /// by best cumulative-share match. Never involves the Translation
    /// framework.
    case humanSplit
    /// Tier 2 (machine-origin lines only) -- an already-cached per-piece
    /// on-device translation (the async pass may have completed on an
    /// earlier call, or a previous width's split produced and cached the
    /// same piece text).
    case perPieceCache
    /// Tier 3 -- the fallback: the piece is segment 0 and carries the FULL
    /// original-line translation, because nothing more precise applied.
    case fallbackFirstPiece
    /// No translation at all for this piece. For a machine-origin line the
    /// caller should register this piece's text for an async tier-2
    /// translation attempt; for a human-origin line this means
    /// `humanTranslationSplit` ran out of usable candidates before reaching
    /// this piece -- there is nothing further to schedule (human-origin
    /// pieces are NEVER queued for machine translation).
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
    /// except the last ends at a clause boundary in the original text AND
    /// `fullTranslation` splits into exactly `originalPieces.count` clauses.
    /// Purely positional: pieces are paired with clauses IN ORDER.
    ///
    /// `enforceLengthRankGuard` (2026-09-23 founder decision): when `true`
    /// (the default -- MACHINE-origin lines), an additional conservative
    /// guard rejects the pairing if the two sides' relative clause-length
    /// ordering disagrees (see `lengthRankPermutation`) -- a cheap proxy
    /// against clause reordering, e.g. English "I'll wait for you," /
    /// "until the end of time" vs. Chinese "直到时间尽头，我都会等你" (clause
    /// count matches, order is reversed). When `false` (HUMAN-origin lines,
    /// 2026-09-23) this guard is SKIPPED -- the founder's own eval
    /// (pt-001/pt-002 in piece_translation_eval.json) found it rejects a
    /// large share of ordinary, CORRECTLY-ordered human translations too
    /// (Chinese is simply denser per-clause than English on average, so
    /// relative length order flips from normal phrasing variance, not
    /// reordering) -- for a HUMAN translation the founder's explicit
    /// trade-off is to accept clause order as written and document that a
    /// genuinely reordered translation may pair imperfectly, rather than
    /// reject the common case to guard the rare one.
    public static func clauseAlignedTranslations(
        originalPieces: [String],
        fullTranslation: String?,
        enforceLengthRankGuard: Bool = true
    ) -> [String]? {
        guard originalPieces.count > 1,
              let fullTranslation, !fullTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let allButLastEndAtClause = originalPieces.dropLast().allSatisfy(endsWithClauseBoundary)
        guard allButLastEndAtClause else { return nil }

        let translationClauses = clauses(in: fullTranslation)
        guard translationClauses.count == originalPieces.count else { return nil }

        if enforceLengthRankGuard {
            let pieceRanks = lengthRankPermutation(originalPieces.map(\.count))
            let clauseRanks = lengthRankPermutation(translationClauses.map(\.count))
            guard pieceRanks == clauseRanks else { return nil }
        }

        return translationClauses
    }

    /// The permutation of `lengths`' indices sorted ascending by length
    /// (ties broken by original index, for stability). Two length arrays
    /// with the SAME permutation have the same relative ordering. Used only
    /// when `enforceLengthRankGuard` is true (machine-origin lines) -- see
    /// that parameter's doc comment on `clauseAlignedTranslations` for why
    /// human-origin lines skip this check entirely.
    private static func lengthRankPermutation(_ lengths: [Int]) -> [Int] {
        lengths.indices.sorted { a, b in
            lengths[a] != lengths[b] ? lengths[a] < lengths[b] : a < b
        }
    }

    // ------------------------------------------------------------------
    // MARK: - Tier 2 (human-origin): smart hard split of the human
    // translation itself.
    // ------------------------------------------------------------------

    private static let humanSplitClausePunctuation = Set("，。！？；、,.!?;")
    private static let bracketPairs: [(open: Character, close: Character)] = [
        ("(", ")"), ("[", "]"), ("{", "}"),
        ("（", "）"), ("【", "】"), ("《", "》"), ("〈", "〉"), ("「", "」"), ("『", "』"),
    ]
    /// Minimum glyphs (Characters) a segment must have to avoid being
    /// treated as an orphan -- "<=2 glyphs" per the founder's rule, so the
    /// floor for an acceptable segment is 3.
    private static let humanSplitMinSegmentGlyphs = 3

    private struct BreakCandidate {
        /// Number of Characters of `text` BEFORE this break point (i.e. the
        /// break falls between index `charIndex - 1` and `charIndex`).
        let charIndex: Int
        /// 0 = clause punctuation (highest priority), 1 = space,
        /// 2 = NLTokenizer word boundary (lowest priority / densest).
        let tier: Int
    }

    /// Scans `text` once, tracking bracket/quote nesting, and returns every
    /// valid break candidate (deduplicated by position, sorted by position)
    /// across all three priority tiers. A candidate is never generated
    /// inside brackets/quotes. Never breaks inside a word: punctuation/space
    /// candidates fall immediately after a punctuation/space character
    /// (never mid-word by construction), and tokenizer candidates fall
    /// exactly at `NLTokenizer(unit: .word)` token boundaries.
    private static func breakCandidates(in text: String) -> [BreakCandidate] {
        let chars = Array(text)
        guard chars.count > humanSplitMinSegmentGlyphs else { return [] }

        var protectedAfter = [Bool](repeating: false, count: chars.count)
        var bracketDepth = 0
        var insideDoubleQuote = false
        var insideSingleQuote = false
        var candidates: [BreakCandidate] = []

        for (i, c) in chars.enumerated() {
            if bracketPairs.contains(where: { $0.open == c }) {
                bracketDepth += 1
            } else if bracketPairs.contains(where: { $0.close == c }) {
                bracketDepth = max(0, bracketDepth - 1)
            } else if c == "\"" || c == "\u{201C}" || c == "\u{201D}" {
                insideDoubleQuote.toggle()
            } else if c == "'" || c == "\u{2018}" || c == "\u{2019}" {
                insideSingleQuote.toggle()
            }
            protectedAfter[i] = bracketDepth > 0 || insideDoubleQuote || insideSingleQuote

            guard !protectedAfter[i] else { continue }
            if humanSplitClausePunctuation.contains(c) {
                candidates.append(BreakCandidate(charIndex: i + 1, tier: 0))
            } else if c == " " {
                candidates.append(BreakCandidate(charIndex: i + 1, tier: 1))
            }
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let offset = text.distance(from: text.startIndex, to: range.upperBound)
            if offset > 0, offset < chars.count, !protectedAfter[offset - 1] {
                if !candidates.contains(where: { $0.charIndex == offset }) {
                    candidates.append(BreakCandidate(charIndex: offset, tier: 2))
                }
            }
            return true
        }

        candidates.sort { $0.charIndex < $1.charIndex }
        return candidates
    }

    /// Tier `.humanSplit`. Hard-splits `fullTranslation` into
    /// `originalPieces.count` segments by choosing, for each of the
    /// `originalPieces.count - 1` internal boundaries, the break candidate
    /// (see `breakCandidates`) whose cumulative character position in the
    /// translation best matches that boundary's cumulative SHARE of
    /// `pieceWeights` (duration for word-level lines, display length
    /// otherwise -- the caller decides which by what it passes). Selection
    /// proceeds left-to-right, STRICT-TIER-FALLBACK (punctuation candidates
    /// considered first; only if NONE are usable does a space candidate
    /// even enter consideration; only if neither exist does a tokenizer
    /// candidate) then nearest-share WITHIN that tier; each chosen break
    /// must land at least `humanSplitMinSegmentGlyphs` characters past the
    /// previous one. A separate post-pass then verifies the ACTUAL trimmed
    /// segments (trimming can shrink a segment by the boundary whitespace a
    /// space-tier break consumed) and merges away any orphan (<=2 glyphs)
    /// wherever it lands, not just at the very end.
    ///
    /// Returns one optional segment per original piece. When there are
    /// FEWER usable candidates than boundaries needed (short translation,
    /// heavy bracket/quote protection, etc.), the pieces that DID get a
    /// resolved break each carry their own segment; the remainder of the
    /// translation (from the last resolved break to the end) is NOT handed
    /// out piecemeal -- it merges into the next piece in line (the "last
    /// piece that has one"), and any pieces after THAT stay nil. This falls
    /// out of the algorithm without a special case: with zero usable
    /// candidates at all, `selected` is empty, there is exactly one segment
    /// (the whole trimmed translation), and it lands on piece 0 -- the
    /// same shape as the old tier-3 fallback, but reached in this tier
    /// rather than falling through to it (a human-origin line's `.none`
    /// pieces are simply "less lucky splits", never machine-translated).
    public static func humanTranslationSplit(
        originalPieces: [String],
        pieceWeights: [Double],
        fullTranslation: String
    ) -> [String?]? {
        guard originalPieces.count > 1 else { return nil }
        let trimmed = fullTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let weights: [Double]
        if pieceWeights.count == originalPieces.count, pieceWeights.reduce(0, +) > 0 {
            weights = pieceWeights
        } else {
            // Malformed/missing weights (caller bug, or genuinely degenerate
            // zero-duration pieces): fall back to equal shares rather than
            // crashing or mis-splitting. Not expected in normal use --
            // LyricsView always passes real durations or character counts.
            weights = Array(repeating: 1.0, count: originalPieces.count)
        }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        var targetShares: [Double] = []
        var cumulative: Double = 0
        for weight in weights.dropLast() {
            cumulative += weight
            targetShares.append(cumulative / totalWeight)
        }

        let chars = Array(trimmed)
        let allCandidates = breakCandidates(in: trimmed)

        // Selection is STRICT-TIER-FALLBACK, not "globally nearest
        // regardless of tier": for each break, only candidates from the
        // HIGHEST tier that has ANY usable candidate are even considered --
        // a natural clause-punctuation or space boundary always wins over a
        // numerically closer tokenizer boundary, exactly the founder's
        // stated "priority" ordering. (An earlier version picked whichever
        // candidate was numerically nearest across ALL tiers and used tier
        // only as an exact-distance tie-break -- ties are rare, so in
        // practice it almost always ignored the priority entirely and
        // sometimes broke mid-phrase 1-2 characters from an obviously
        // better space/punctuation boundary; caught by this module's own
        // eval, see piece_translation_human_split_eval.json's hs-002.)
        var selected: [Int] = []
        var lastBreak = 0
        for targetShare in targetShares {
            let targetOffset = targetShare * Double(chars.count)
            var best: BreakCandidate?
            for tier in 0...2 {
                // Both sides matter: a candidate must leave at least
                // `humanSplitMinSegmentGlyphs` characters BEHIND it (since
                // the last break) AND at least that many characters of the
                // translation REMAINING ahead of it -- a candidate sitting
                // right before the string's end (e.g. a lone trailing
                // period) would otherwise "win" tier 0 purely by tier
                // priority while producing a degenerate empty/orphan final
                // segment, starving a MUCH better-fitting lower-tier
                // candidate (a mid-string space) of any consideration at
                // all. Caught by this module's own eval, see
                // piece_translation_human_split_eval.json's hs-006.
                let usable = allCandidates.filter {
                    $0.tier == tier
                        && $0.charIndex - lastBreak >= humanSplitMinSegmentGlyphs
                        && chars.count - $0.charIndex >= humanSplitMinSegmentGlyphs
                }
                if let nearest = usable.min(by: {
                    abs(Double($0.charIndex) - targetOffset) < abs(Double($1.charIndex) - targetOffset)
                }) {
                    best = nearest
                    break
                }
            }
            guard let best else {
                break // Out of usable candidates at every tier -- remainder merges below.
            }
            selected.append(best.charIndex)
            lastBreak = best.charIndex
        }

        // Trimming (below) can shrink a segment by exactly the boundary
        // whitespace character a space-tier break consumed, so the RAW
        // charIndex gap checked during selection above is not the final
        // word on orphan-avoidance -- verify the ACTUAL trimmed segments
        // and merge away any orphan (<=2 glyphs) wherever it lands (start,
        // middle, or end), re-checking after each merge. Bounded by
        // `selected.count` (each iteration removes exactly one break).
        func buildSegments(_ breaks: [Int]) -> [String] {
            var segs: [String] = []
            var cursor = 0
            for breakPoint in breaks {
                segs.append(String(chars[cursor..<breakPoint]).trimmingCharacters(in: .whitespaces))
                cursor = breakPoint
            }
            segs.append(String(chars[cursor...]).trimmingCharacters(in: .whitespaces))
            return segs
        }

        var breaks = selected
        var segments = buildSegments(breaks)
        while segments.count > 1, let orphanIndex = segments.firstIndex(where: { !$0.isEmpty && $0.count <= 2 }) {
            if orphanIndex == segments.count - 1 {
                breaks.removeLast()
            } else {
                breaks.remove(at: orphanIndex)
            }
            segments = buildSegments(breaks)
        }

        segments = segments.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }

        var result: [String?] = Array(repeating: nil, count: originalPieces.count)
        for (index, segment) in segments.enumerated() where index < originalPieces.count {
            result[index] = segment
        }
        return result
    }

    /// Full decision for one line's already-split pieces.
    ///
    /// - `pieceWeights`: only consulted for `.humanSplit` (human-origin
    ///   lines whose pieces didn't clause-align) -- pass real per-piece
    ///   durations for word-level lines, display-length (character count)
    ///   otherwise. Ignored entirely for machine-origin lines; defaults to
    ///   `[]` (equal shares) when the caller has nothing meaningful to pass.
    /// - `isHumanTranslation`: `true` when `fullTranslation` came from the
    ///   lyrics source (NetEase/QQ/AMLL/Apple TTML etc. -- the caller's
    ///   `!isSystemTranslationSource`). Defaults to `false` (machine/system
    ///   origin, the pre-2026-09-23 behavior) so existing call sites that
    ///   only ever exercised the machine pipeline keep compiling and keep
    ///   their exact prior behavior unless they opt in.
    /// - `cache`: a synchronous lookup (piece text -> already-translated
    ///   text). Used ONLY on the machine-origin path (tier `.perPieceCache`)
    ///   -- a human-origin line's pieces are NEVER looked up here, because
    ///   they are never machine-translated at all.
    ///
    /// Returns one entry per piece in `originalPieces`, matching order.
    public static func pieceTranslations(
        originalPieces: [String],
        pieceWeights: [Double] = [],
        fullTranslation: String?,
        isHumanTranslation: Bool = false,
        cache: (String) -> String?
    ) -> (translations: [String?], tiers: [LyricPieceTranslationTier]) {
        guard !originalPieces.isEmpty else { return ([], []) }
        guard originalPieces.count > 1 else {
            // Not actually split -- the single piece just carries the whole
            // line's translation verbatim (existing simple behavior, true
            // for both human- and machine-origin lines).
            return ([fullTranslation], [fullTranslation == nil ? .none : .fallbackFirstPiece])
        }

        if let aligned = clauseAlignedTranslations(
            originalPieces: originalPieces,
            fullTranslation: fullTranslation,
            enforceLengthRankGuard: !isHumanTranslation
        ) {
            return (aligned.map { $0 }, Array(repeating: .clauseAligned, count: originalPieces.count))
        }

        if isHumanTranslation {
            guard let fullTranslation,
                  let split = humanTranslationSplit(
                    originalPieces: originalPieces,
                    pieceWeights: pieceWeights,
                    fullTranslation: fullTranslation
                  )
            else {
                return (
                    Array(repeating: nil, count: originalPieces.count),
                    Array(repeating: .none, count: originalPieces.count)
                )
            }
            let tiers = split.map { $0 == nil ? LyricPieceTranslationTier.none : .humanSplit }
            return (split, tiers)
        }

        // Machine/system-origin translation (or no translation at all):
        // unchanged tier 2/3 pipeline (pre-2026-09-23 behavior).
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
