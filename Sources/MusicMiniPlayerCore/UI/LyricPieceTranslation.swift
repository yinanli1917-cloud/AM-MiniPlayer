/**
 * [INPUT]: Foundation + NaturalLanguage (NLTagger(.lexicalClass) for the
 *          phrase-aware tokenizer tier in `humanTranslationSplit`, gated per
 *          translation language via `NLTagger.availableTagSchemes`) +
 *          `Utils/DebugLogger.swift` (same-module; a single diagnostic line
 *          when the tokenizer tier is disabled for an unsupported
 *          language). Otherwise pure text logic -- no Translation
 *          framework, no LyricsService. The punctuation sets mirror
 *          LyricDisplaySegmenter's strong/weak boundary characters on
 *          purpose (same notion of "clause").
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
 *    (Chinese fan translations often separate clauses with spaces), then a
 *    PHRASE-AWARE word-boundary tier -- choosing, for each original piece
 *    boundary, the candidate whose cumulative position best matches that
 *    piece's share of the line (timing share for word-level lines,
 *    display-length share otherwise). Never breaks inside a word or a
 *    grammatical phrase, never leaves an orphan piece relative to its
 *    ORIGINAL piece's own length, never breaks inside brackets/quotes. When
 *    there are fewer usable candidates than needed, the remainder merges
 *    into the last piece that got a real segment (documented in
 *    `humanTranslationSplit`'s own comment) -- pieces past that stay nil,
 *    never silently duplicating machine-translated text.
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
 *
 * 2026-09-23-afternoon-2 founder review of the first landing (459cd98)
 * found two remaining defects, both fixed in this revision:
 *
 * (A) The word-boundary tier's "0 mid-word breaks" self-check was
 *     CIRCULAR: it verified breaks against the SAME `NLTokenizer` that
 *     proposed them, so it could never catch the tokenizer's own mistakes
 *     -- e.g. Japanese "待っている" (a single te-iru verb form) got split
 *     "待っ|ている", and Chinese "每一次" ("every single time") got split
 *     "每|一次", both reported as clean. Fixed by gating the word-boundary
 *     tier on `NLTagger.availableTagSchemes(for:.word,language:)` actually
 *     containing `.lexicalClass` for the TRANSLATION's language (queried
 *     per call, never assumed) -- see `lexicalClassIsAvailable(for:)`.
 *     EMPIRICALLY VERIFIED on this SDK (Xcode 26, see
 *     LyricPieceTranslationTests' `test_nlTaggerSupportProbe_...` which
 *     prints the exact scheme lists): `.lexicalClass` is available for
 *     `zh-Hans` but NOT for `ja`, `zh-Hant`, or `ko` -- so for those three
 *     languages this tier is DISABLED entirely (never falls back to a bare
 *     `NLTokenizer` word boundary, which is exactly the mechanism that
 *     produced 待っ|ている), one `DebugLogger` line is emitted, and
 *     `humanTranslationSplit` relies on clause-punctuation/space candidates
 *     only -- degrading gracefully to fewer pieces (or the whole
 *     translation on piece 0) rather than guessing. Where `.lexicalClass`
 *     IS available (zh-Hans on this SDK), candidates come from
 *     `NLTagger.enumerateTags(unit:.word,scheme:.lexicalClass)` boundaries,
 *     filtered: a break is rejected if the token STARTING the new segment
 *     is `.particle` or `.classifier` (Apple's public `NLTag` scheme has no
 *     distinct "auxiliary" or "suffix" case -- verified via the same probe
 *     -- `.particle` is the closest available tag and covers Chinese
 *     aspect/structural particles 的/了/着 directly), OR if the token
 *     ENDING the old segment is `.determiner` or `.number` (no distinct
 *     "prefix" case either). An ADDITIONAL rule beyond the founder's
 *     literal list, found necessary by this revision's own probe of the
 *     每一次 example: either side tagged `.otherWord` (the tagger's own "I
 *     don't know" bucket) ALSO vetoes the break -- `一`/`次` in 每一次 come
 *     back `.otherWord` rather than the ideal Number/Classifier tags on
 *     this SDK's Chinese model, so trusting a low-confidence tag is exactly
 *     the same mistake as trusting the raw tokenizer; treating `.otherWord`
 *     as "insufficient evidence, don't break here" closes that gap.
 * (B) The orphan floor (originally a flat "<=2 glyphs is always an orphan")
 *     was NOT relative to the ORIGINAL piece it would become: a genuinely
 *     short original piece (an ad-lib like "oh"/"yeah"/"mmm") deserves a
 *     genuinely short translation segment, but the flat floor rejected that
 *     short segment as an "orphan" and merged the NEXT piece's leading
 *     characters into it instead (founder repro: "oh"=>"哦" was being
 *     reported as "哦 我 | 从来没想过…", stealing "我" from the second
 *     piece). Fixed by `perPieceFloor(_:)`: a piece whose ORIGINAL text is
 *     `<=3` characters or `<=1` word gets floor 1 (any non-empty segment is
 *     acceptable); every other piece keeps the `humanSplitMinSegmentGlyphs`
 *     (3) floor. Applied identically during candidate selection AND the
 *     post-merge orphan sweep, so the two stay consistent.
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
    /// Default minimum glyphs (Characters) a segment must have to avoid
    /// being treated as an orphan. Used for any piece whose ORIGINAL text
    /// is NOT itself short -- see `perPieceFloor(_:originalPieces:)`.
    private static let humanSplitMinSegmentGlyphs = 3

    /// True when `piece` is short enough (an ad-lib like "oh"/"yeah"/"mmm",
    /// or any <=3-character/<=1-word original piece) that its OWN
    /// translation segment is allowed to be equally short -- see this
    /// file's header, defect (B). The threshold is deliberately the
    /// founder's own stated proxy ("<=1 word / <=3 characters"), an OR: a
    /// single long word (e.g. a 5-character CJK word) does not count as
    /// short even though it's "1 word", so the character-count arm alone
    /// still applies as a ceiling for CJK originals; the word-count arm
    /// exists for short Latin ad-libs whose character count alone might
    /// exceed 3 (e.g. none in practice for single ad-lib words, but a
    /// 2-word ad-lib like "oh oh" would still want an equally short
    /// translation and IS caught by the character-count arm at that
    /// length; the word-count arm is the fallback for the rare case a
    /// short piece is exactly 4 ASCII characters, e.g. "yeah").
    private static func originalPieceIsShort(_ piece: String) -> Bool {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 3 { return true }
        let wordCount = trimmed.split(separator: " ", omittingEmptySubsequences: true).count
        return wordCount <= 1
    }

    private struct BreakCandidate {
        /// Number of Characters of `text` BEFORE this break point (i.e. the
        /// break falls between index `charIndex - 1` and `charIndex`).
        let charIndex: Int
        /// 0 = clause punctuation (highest priority), 1 = space,
        /// 2 = phrase-aware word boundary (lowest priority / densest; only
        /// generated when the translation's language has NLTagger
        /// `.lexicalClass` support -- see `lexicalClassIsAvailable(for:)`).
        let tier: Int
    }

    /// Lexical-class tags that must never START a new displayed segment
    /// (the break lands right before them) -- grammatical "glue" that
    /// binds BACKWARD to what precedes it. `.otherWord` is included
    /// defensively: it is the tagger's own "could not classify this token"
    /// bucket, and this file's header documents the empirical case
    /// (Chinese 每一次) where trusting an `.otherWord` tag as "safe" would
    /// have reproduced the exact mid-phrase-split bug this revision fixes.
    private static let forbiddenFollowingLexicalTags: Set<NLTag> = [.particle, .classifier, .otherWord]

    /// Tags that must never END a segment (the break lands right after
    /// them) -- forward-binding modifiers. See `forbiddenFollowingLexicalTags`
    /// for why `.otherWord` is included on both sides.
    private static let forbiddenPrecedingLexicalTags: Set<NLTag> = [.determiner, .number, .otherWord]

    /// Per-language cache of whether `NLTagger` actually has a
    /// `.lexicalClass` model on THIS system (`NLTagger.availableTagSchemes`
    /// is a real capability query, not a static list -- this file never
    /// assumes support). A plain dictionary behind an `NSLock` (the same
    /// pattern `PieceTranslationCache` uses) since this can be queried from
    /// more than one call site.
    private final class LexicalClassSupportMemo {
        static let shared = LexicalClassSupportMemo()
        private let lock = NSLock()
        private var cache: [String: Bool] = [:]

        func isAvailable(for languageCode: String) -> Bool {
            lock.lock()
            if let cached = cache[languageCode] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            let supported = NLTagger.availableTagSchemes(for: .word, language: NLLanguage(languageCode))
                .contains(.lexicalClass)
            lock.lock()
            cache[languageCode] = supported
            lock.unlock()
            return supported
        }

        #if DEBUG
        func debugReset() {
            lock.lock()
            cache.removeAll()
            lock.unlock()
        }
        #endif
    }

    /// Public only so `LyricPieceTranslationTests` can print the REAL,
    /// on-device support table for the languages this app actually
    /// translates into/from, rather than asserting from documentation.
    public static func lexicalClassIsAvailable(for languageCode: String) -> Bool {
        LexicalClassSupportMemo.shared.isAvailable(for: languageCode)
    }

    #if DEBUG
    public static func debugResetLexicalClassSupportMemo() {
        LexicalClassSupportMemo.shared.debugReset()
    }
    #endif

    /// Scans `text` once, tracking bracket/quote nesting, and returns every
    /// valid break candidate (deduplicated by position, sorted by position)
    /// across all three priority tiers. A candidate is never generated
    /// inside brackets/quotes.
    ///
    /// Tier 0/1 (punctuation/space) candidates fall immediately after a
    /// punctuation/space character -- never mid-word by construction, and
    /// unaffected by language/tagger support (a comma or a space IS a
    /// genuine boundary in any script).
    ///
    /// Tier 2 (phrase-aware word boundary) is gated by
    /// `lexicalClassIsAvailable(for: translationLanguageCode)`. When
    /// UNAVAILABLE, this tier contributes ZERO candidates -- this file no
    /// longer falls back to a bare `NLTokenizer(unit: .word)` boundary
    /// (which is exactly the mechanism that split Japanese 待っている
    /// mid-morpheme; see this file's header). When available, candidates
    /// come from `NLTagger.enumerateTags(unit:.word,scheme:.lexicalClass)`
    /// token boundaries, filtered by `forbiddenFollowingLexicalTags`/
    /// `forbiddenPrecedingLexicalTags`.
    private static func breakCandidates(in text: String, translationLanguageCode: String) -> [BreakCandidate] {
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

        guard lexicalClassIsAvailable(for: translationLanguageCode) else {
            // 2026-09-23-afternoon-2 fix: do NOT fall back to a bare
            // NLTokenizer word boundary here -- that is the exact
            // mechanism that produced 待っ|ている. Log once per call (not
            // per-frame -- this runs at most once per split-line rebuild,
            // already debounced by LyricsView) only when it could actually
            // have mattered (a translation long enough that the punctuation
            // candidates it can generate below may not be enough).
            if chars.count > humanSplitMinSegmentGlyphs * 2 {
                DebugLogger.log(
                    "Translation",
                    "🈳 humanSplit: NLTagger.lexicalClass unsupported for '\(translationLanguageCode)' " +
                    "-- word-boundary tier disabled, relying on punctuation/space candidates only"
                )
            }
            candidates.sort { $0.charIndex < $1.charIndex }
            return candidates
        }

        let language = NLLanguage(translationLanguageCode)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)

        var tokens: [(range: Range<String.Index>, tag: NLTag?)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            tokens.append((range, tag))
            return true
        }

        for index in 0..<tokens.count {
            guard index + 1 < tokens.count else { continue }
            let precedingTag = tokens[index].tag
            let followingTag = tokens[index + 1].tag
            if let p = precedingTag, forbiddenPrecedingLexicalTags.contains(p) { continue }
            if let f = followingTag, forbiddenFollowingLexicalTags.contains(f) { continue }

            let offset = text.distance(from: text.startIndex, to: tokens[index].range.upperBound)
            guard offset > 0, offset < chars.count, !protectedAfter[offset - 1] else { continue }
            if !candidates.contains(where: { $0.charIndex == offset }) {
                candidates.append(BreakCandidate(charIndex: offset, tier: 2))
            }
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
    /// even enter consideration; only if neither exist does a phrase-aware
    /// word-boundary candidate) then nearest-share WITHIN that tier.
    ///
    /// `translationLanguageCode`: the translation's own language (the
    /// app's configured target language, e.g. "zh-Hans" -- NOT the
    /// original line's source language). Gates whether tier 2 candidates
    /// are generated at all; see `breakCandidates`.
    ///
    /// The orphan floor is PER-PIECE (2026-09-23-afternoon-2 fix, defect
    /// B): `perPieceFloor(pieceIndex:)` returns 1 when
    /// `originalPieces[pieceIndex]` is itself short
    /// (`originalPieceIsShort`), else the standard `humanSplitMinSegmentGlyphs`
    /// (3). Applied both during candidate selection (so a short-original
    /// piece's boundary can land close to its tiny target share) and in the
    /// post-merge sweep below (trimming can shrink a segment by the
    /// boundary whitespace a space-tier break consumed, so the raw
    /// charIndex gap checked during selection is not the final word --
    /// this pass verifies the ACTUAL trimmed segments and merges away any
    /// orphan wherever it lands, not just at the very end).
    ///
    /// Returns one optional segment per original piece. When there are
    /// FEWER usable candidates than boundaries needed (short translation,
    /// heavy bracket/quote protection, an unsupported language disabling
    /// tier 2, etc.), the pieces that DID get a resolved break each carry
    /// their own segment; the remainder of the translation (from the last
    /// resolved break to the end) is NOT handed out piecemeal -- it merges
    /// into the next piece in line (the "last piece that has one"), and any
    /// pieces after THAT stay nil. This falls out of the algorithm without
    /// a special case: with zero usable candidates at all, `selected` is
    /// empty, there is exactly one segment (the whole trimmed translation),
    /// and it lands on piece 0 -- the same shape as the old tier-3
    /// fallback, but reached in this tier rather than falling through to it
    /// (a human-origin line's `.none` pieces are simply "less lucky
    /// splits", never machine-translated).
    public static func humanTranslationSplit(
        originalPieces: [String],
        pieceWeights: [Double],
        fullTranslation: String,
        translationLanguageCode: String
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

        // Per-ORIGINAL-piece orphan floor -- see this function's doc
        // comment and this file's header, defect (B). `pieceIndex` is
        // clamped defensively; callers always pass a valid range.
        func perPieceFloor(_ pieceIndex: Int) -> Int {
            guard pieceIndex >= 0, pieceIndex < originalPieces.count else { return humanSplitMinSegmentGlyphs }
            return originalPieceIsShort(originalPieces[pieceIndex]) ? 1 : humanSplitMinSegmentGlyphs
        }

        let chars = Array(trimmed)
        let allCandidates = breakCandidates(in: trimmed, translationLanguageCode: translationLanguageCode)

        // Selection is STRICT-TIER-FALLBACK, not "globally nearest
        // regardless of tier": for each break, only candidates from the
        // HIGHEST tier that has ANY usable candidate are even considered --
        // a natural clause-punctuation or space boundary always wins over a
        // numerically closer word-boundary candidate, exactly the founder's
        // stated "priority" ordering. (An earlier version picked whichever
        // candidate was numerically nearest across ALL tiers and used tier
        // only as an exact-distance tie-break -- ties are rare, so in
        // practice it almost always ignored the priority entirely and
        // sometimes broke mid-phrase 1-2 characters from an obviously
        // better space/punctuation boundary; caught by this module's own
        // eval, see piece_translation_human_split_eval.json's hs-002.)
        var selected: [Int] = []
        var lastBreak = 0
        for (boundaryIndex, targetShare) in targetShares.enumerated() {
            let targetOffset = targetShare * Double(chars.count)
            var best: BreakCandidate?
            for tier in 0...2 {
                // Both sides matter: a candidate must leave at least
                // `perPieceFloor(boundaryIndex)` characters BEHIND it (the
                // piece it would close out) AND at least
                // `perPieceFloor(boundaryIndex + 1)` characters of the
                // translation REMAINING ahead of it (the piece that would
                // start there) -- a candidate sitting right before the
                // string's end (e.g. a lone trailing period) would
                // otherwise "win" tier 0 purely by tier priority while
                // producing a degenerate empty/orphan final segment,
                // starving a MUCH better-fitting lower-tier candidate (a
                // mid-string space) of any consideration at all. Caught by
                // this module's own eval, see
                // piece_translation_human_split_eval.json's hs-006.
                let usable = allCandidates.filter {
                    $0.tier == tier
                        && $0.charIndex - lastBreak >= perPieceFloor(boundaryIndex)
                        && chars.count - $0.charIndex >= perPieceFloor(boundaryIndex + 1)
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
        while segments.count > 1 {
            guard let orphanIndex = segments.indices.first(where: { idx in
                let segment = segments[idx]
                return !segment.isEmpty && segment.count < perPieceFloor(idx)
            }) else { break }
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
    /// - `translationLanguageCode`: only consulted for `.humanSplit` --
    ///   the translation's OWN language (e.g. the app's configured target
    ///   language), used to gate the phrase-aware word-boundary tier.
    ///   Defaults to `"und"` (undetermined), which `NLTagger` never reports
    ///   `.lexicalClass` support for -- the safest possible default
    ///   (fail-closed: no language specified means no risky bare-tokenizer
    ///   tier, same as an explicitly-unsupported language).
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
        translationLanguageCode: String = "und",
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
                    fullTranslation: fullTranslation,
                    translationLanguageCode: translationLanguageCode
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
