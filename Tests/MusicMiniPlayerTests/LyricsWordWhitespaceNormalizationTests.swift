/**
 * [INPUT]: Depends on LyricWord/LyricLine (Models/LyricModels.swift) +
 *          LyricDisplaySegmenter.realWrapWordPieces/displayText(forWords:)
 *          (UI/LyricDisplaySegmenter.swift) + NativeLyricsStaticTextRenderPlan/
 *          NativeLyricsTextRenderPlan (UI/NativeLyricsTextRenderPlan.swift) +
 *          NativeLyricsTextSweepLayout (UI/NativeLyricsTextSweepLayout.swift)
 * [OUTPUT]: Regression tests pinning the 2026-09-24 fix for U+00A0 NO-BREAK
 *           SPACE in NetEase YRC word text silently clearing `words` on split
 *           display pieces.
 * [POS]: Tests -- exercises the real production functions directly (all
 *        non-private). The word-level split branch of `LyricsView.
 *        makeDisplayLyricLines` (private, SwiftUI) is mirrored exactly for
 *        the end-to-end fixture test below (same convention as
 *        PieceTranslationRebuildOrderingTests.simulateDisplayLinesBuilt):
 *        `LyricDisplaySegmenter.realWrapWordPieces` then
 *        `LyricLine(text: displayText(forWords: group), words: group)` per
 *        group -- see LyricsView.swift:2170-2229. No SwiftUI hosting needed.
 *
 * Founder report (2026-09-24, radio): Teresa Teng "The Way We Were" --
 * word-level lyrics render as line-level. Coordinator follow-up traced the
 * REAL data (founder's own disk cache, NetEase, album 愛之世界, 207s):
 * every word carries a trailing U+00A0 NO-BREAK SPACE instead of a plain
 * space, e.g. words == ["Memories\u{00A0}", "light\u{00A0}", "the\u{00A0}",
 * "corners\u{00A0}", "of\u{00A0}", "my\u{00A0}", "mind"] for the line
 * "Memories light the corners of my mind". Only ONE lyrics apply happened
 * for this song (no line->word hot-switch), ruling out the fingerprint fix
 * from this session's earlier commit as the explanation here.
 *
 * Mechanism (LyricModels.swift, pre-fix): `LyricLine.init`'s words/text
 * consistency invariant --
 *
 *   let wordsText = words.map(\.word).joined().replacingOccurrences(of: " ", with: "")
 *   let normalizedText = text.replacingOccurrences(of: " ", with: "")
 *   self.words = normalizedText.hasPrefix(wordsText) || wordsText.hasPrefix(normalizedText) ? words : []
 *
 * -- only strips the plain ASCII space (U+0020), never U+00A0. Plan A's
 * word-level split path (`LyricsView.makeDisplayLyricLines`'s
 * `hasSyllableSync` branch, 2026-09-22) builds each split piece as
 * `LyricLine(text: LyricDisplaySegmenter.displayText(forWords: group), words: group)`
 * -- `text` comes from `displayText(forWords:)`, which ALWAYS normalizes a
 * word's trailing whitespace (any `Character.isWhitespace`, which includes
 * U+00A0) into a plain ASCII space when reconstructing the joined string,
 * but `words: group` is the RAW word array, untouched. For a NetEase
 * YRC line with NBSP separators, `text` therefore uses plain spaces while
 * `words` still has NBSP -- the invariant's prefix check fails on the very
 * first separator character, and `self.words` is silently cleared. This
 * hits every real-world line long enough to need more than one display
 * piece (the common case for lyrics at the app's narrow default width, not
 * an edge case) -- `line.hasSyllableSync` flips to `false` for that split
 * piece with no error, no log line, nothing to catch it, and the renderer's
 * `line.hasSyllableSync && !plan.wordRuns.isEmpty` gate (used throughout
 * NativeLyricsRowView to pick the per-word sweep vs whole-line rendering)
 * falls through to whole-line/line-level rendering for that piece.
 *
 * Separately (not this bug's proximate cause, but the same root data
 * defect and worth pinning): U+00A0 is defined by Unicode to NOT be a
 * valid line-break opportunity, so `NSLayoutManager`'s `.byWordWrapping`
 * cannot wrap between NBSP-separated words at all.
 *
 * Fix (v1, this session): `LyricWord.init`/`LyricLine.init` normalized
 * every Unicode whitespace character other than plain space
 * (`Character.isWhitespace`) to `" "` at construction.
 *
 * Fix (v2, coordinator scope correction, same day): v1 was too broad -- it
 * silently rewrote U+3000 IDEOGRAPHIC SPACE, a DELIBERATE full-width clause
 * separator in CJK lyrics/translations (founder-tuned spacing, not a data
 * artifact), and would have turned a literal tab/newline into a space too.
 * Storage-level normalization (`LyricWord.normalizingNonBreakingSpaces`) is
 * now narrowed to exactly: (1) the non-breaking family that actually causes
 * the wrap/consistency failure -- U+00A0 NO-BREAK SPACE, U+202F NARROW
 * NO-BREAK SPACE, U+2007 FIGURE SPACE -- mapped to a plain space; (2) the
 * zero-width formatting characters U+200B ZERO WIDTH SPACE, U+2060 WORD
 * JOINER, U+FEFF ZERO WIDTH NO-BREAK SPACE (BOM), which are DROPPED
 * entirely (they render as nothing). U+3000, tabs, newlines, and every
 * other whitespace variant are left completely untouched. Because that
 * narrower set can still leave SOME whitespace mismatch between `words`
 * and `text` unresolved (e.g. U+3000 on one side only), the words/text
 * consistency invariant in `LyricLine.init` no longer compares the raw
 * stored strings at all -- it compares through
 * `LyricWord.whitespaceStrippedComparisonKey`, which strips ALL whitespace
 * (`Character.isWhitespace`, not just the narrowed family) for the
 * comparison ONLY, leaving the stored text/words exactly as constructed.
 * That comparison-only key is the actual belt-and-suspenders fix for the
 * words-silently-cleared class of bug; the storage-level normalization
 * only prevents the U+00A0 wrap failure and keeps display text free of
 * invisible zero-width characters.
 *
 * This is the single choke point every `LyricWord`/`LyricLine` in the app
 * is built through (every parser, `LyricsWordRepair`, Traditional-Chinese
 * conversion, `LyricsDiskCache.lyricLines(from:)` on every disk-cache
 * read), so it also self-heals stale cached entries written before the
 * fix, without a schema bump.
 *
 * Red-before-fix verified manually (v1): temporarily reverted
 * `LyricWord.init`/`LyricLine.init` to plain assignment, reran
 * `test_splitPieceFromNBSPWords_keepsWordLevelSync` -- failed
 * (`hasSyllableSync` was `false`, `words.isEmpty` was `true`, reproducing
 * the founder's screenshot exactly). Restored, reran green. v2's narrowed
 * scope re-verified against the same fixture (all fixture words are ASCII
 * with NBSP separators, unaffected by narrowing the normalized set) plus
 * the new U+3000/zero-width/comparison-key tests added for v2.
 *
 * Safety: pure value-type tests, no network, no LyricsService/disk-cache
 * access, no ~/Library/Application Support/nanoPod/ I/O.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class LyricsWordWhitespaceNormalizationTests: XCTestCase {

    // MARK: - LyricWord/LyricLine normalize whitespace at construction

    func test_lyricWord_normalizesTrailingNBSPToPlainSpace() {
        let word = LyricWord(word: "Memories\u{00A0}", startTime: 0, endTime: 0.35)
        XCTAssertEqual(word.word, "Memories ")
        XCTAssertFalse(word.word.contains("\u{00A0}"))
    }

    /// 2026-09-24 coordinator scope correction: only the NON-BREAKING space
    /// family (the actual cause of the wrap/consistency failures) normalizes
    /// to a plain space. NARROW NO-BREAK SPACE (U+202F) and FIGURE SPACE
    /// (U+2007) join U+00A0 in that family.
    func test_lyricWord_normalizesNonBreakingSpaceFamilyToPlainSpace() {
        for scalar in ["\u{00A0}", "\u{202F}", "\u{2007}"] {
            let word = LyricWord(word: "word\(scalar)", startTime: 0, endTime: 1)
            XCTAssertEqual(word.word, "word ", "U+\(String(format: "%04X", scalar.unicodeScalars.first!.value)) must normalize to plain space")
        }
    }

    /// 2026-09-24 coordinator scope correction: U+3000 IDEOGRAPHIC SPACE is
    /// a DELIBERATE full-width clause separator in CJK lyrics/translations
    /// (founder-tuned spacing), not a data artifact -- it must survive
    /// untouched, in both `LyricWord.word` and `LyricLine.text`. EM SPACE
    /// (U+2003) is likewise outside the non-breaking family and must also
    /// be left alone.
    func test_ideographicAndOtherGeneralSpacesAreNeverTouched() {
        for scalar in ["\u{3000}", "\u{2003}"] {
            let word = LyricWord(word: "word\(scalar)", startTime: 0, endTime: 1)
            XCTAssertEqual(word.word, "word\(scalar)", "U+\(String(format: "%04X", scalar.unicodeScalars.first!.value)) must be left untouched in LyricWord.word")
        }
        let line = LyricLine(text: "你好\u{3000}世界", startTime: 0, endTime: 1)
        XCTAssertEqual(line.text, "你好\u{3000}世界", "U+3000 must be left untouched in LyricLine.text")
    }

    /// Zero-width formatting characters render as nothing -- folding them to
    /// a VISIBLE space would be wrong (they never were a separator). They
    /// must be dropped entirely, not replaced.
    func test_zeroWidthFormattingCharactersAreDropped() {
        for scalar in ["\u{200B}", "\u{2060}", "\u{FEFF}"] {
            let word = LyricWord(word: "wo\(scalar)rd", startTime: 0, endTime: 1)
            XCTAssertEqual(word.word, "word", "U+\(String(format: "%04X", scalar.unicodeScalars.first!.value)) must be dropped, not replaced with a space")
        }
        let line = LyricLine(text: "hi\u{FEFF}there", startTime: 0, endTime: 1)
        XCTAssertEqual(line.text, "hithere")
    }

    /// Tabs/newlines are neither the non-breaking family nor zero-width --
    /// left completely untouched (the coordinator's explicit scope bound).
    func test_tabsAndNewlinesAreNeverTouched() {
        let word = LyricWord(word: "a\tb\nc", startTime: 0, endTime: 1)
        XCTAssertEqual(word.word, "a\tb\nc")
    }

    func test_lyricWord_plainSpaceAndNonWhitespaceUnaffected() {
        XCTAssertEqual(LyricWord(word: "hello ", startTime: 0, endTime: 1).word, "hello ")
        XCTAssertEqual(LyricWord(word: "hello", startTime: 0, endTime: 1).word, "hello")
        XCTAssertEqual(LyricWord(word: "你好", startTime: 0, endTime: 1).word, "你好")
    }

    func test_lyricWord_normalizesLeadingAndInternalWhitespaceToo() {
        // Not just trailing -- any occurrence, matching the fix's stated scope.
        let word = LyricWord(word: "\u{00A0}I'm\u{00A0}fine\u{00A0}", startTime: 0, endTime: 1)
        XCTAssertEqual(word.word, " I'm fine ")
    }

    func test_lyricLine_normalizesTextWhitespaceToo() {
        let line = LyricLine(text: "hi\u{00A0}there", startTime: 0, endTime: 1)
        XCTAssertEqual(line.text, "hi there")
    }

    // MARK: - Comparison-only invariant: ANY residual whitespace mismatch must not clear words

    /// The narrowed storage-level normalization deliberately leaves U+3000
    /// (and other non-family whitespace) untouched, so `words` and `text`
    /// CAN still disagree on whitespace after construction -- e.g. a
    /// caller's `text` uses U+3000 as a clause separator where the
    /// underlying `words` array happens to use a plain space at the same
    /// position (or vice versa). The consistency invariant must still keep
    /// `words` in that case: only a REAL (non-whitespace) content mismatch
    /// may clear it.
    func test_wordsSurviveConsistencyCheck_whenOnlyOtherWhitespaceDiffers() {
        let words = [
            LyricWord(word: "你好", startTime: 0, endTime: 0.4),
            LyricWord(word: "世界", startTime: 0.4, endTime: 0.8),
        ]
        // `text` inserts an IDEOGRAPHIC SPACE between the two words where
        // `words`' own concatenation has none at all -- a pure whitespace
        // discrepancy, no character content differs.
        let line = LyricLine(text: "你好\u{3000}世界", startTime: 0, endTime: 0.8, words: words)
        XCTAssertTrue(line.hasSyllableSync, "a whitespace-only (U+3000) mismatch between text and words must not clear words")
        XCTAssertEqual(line.words.count, 2)
        // The stored text keeps its own U+3000 verbatim -- the fix does not
        // rewrite it away.
        XCTAssertEqual(line.text, "你好\u{3000}世界")
    }

    /// Same invariant, tab variant.
    func test_wordsSurviveConsistencyCheck_whenOnlyTabDiffers() {
        let words = [
            LyricWord(word: "one", startTime: 0, endTime: 0.4),
            LyricWord(word: "two", startTime: 0.4, endTime: 0.8),
        ]
        let line = LyricLine(text: "one\ttwo", startTime: 0, endTime: 0.8, words: words)
        XCTAssertTrue(line.hasSyllableSync)
        XCTAssertEqual(line.words.count, 2)
    }

    // MARK: - The regression itself: NBSP words must survive LyricLine's consistency invariant

    /// Exactly the shape Plan A's split path builds: `text` reconstructed via
    /// `displayText(forWords:)` (always plain-space), `words` raw from a
    /// source with NBSP separators.
    func test_splitPieceFromNBSPWords_keepsWordLevelSync() {
        let nbsp = "\u{00A0}"
        let rawWords: [LyricWord] = [
            LyricWord(word: "light" + nbsp, startTime: 0.0, endTime: 0.35),
            LyricWord(word: "the" + nbsp, startTime: 0.4, endTime: 0.75),
            LyricWord(word: "corners" + nbsp, startTime: 0.8, endTime: 1.15),
        ]
        let text = LyricDisplaySegmenter.displayText(forWords: rawWords)
        XCTAssertFalse(text.contains(nbsp), "sanity: displayText always normalizes to plain space")

        let splitLine = LyricLine(text: text, startTime: 0.0, endTime: 1.15, words: rawWords)

        XCTAssertTrue(splitLine.hasSyllableSync, "a split piece built from NBSP-separated source words must stay word-level")
        XCTAssertEqual(splitLine.words.count, 3)
    }

    // MARK: - End-to-end fixture: the founder's exact reported lines

    /// "The Way We Were" as read from the founder's real disk cache
    /// (coordinator's report): every word carries a trailing U+00A0 except
    /// the line's last word. Timings are synthetic but plausible (not the
    /// bug's subject -- the word/text consistency and wrap geometry are).
    private static let nbsp = "\u{00A0}"

    private func makeNBSPLine(_ words: [String], lineStart: TimeInterval) -> LyricLine {
        let wordDuration = 0.35
        let gap = 0.05
        let step = wordDuration + gap
        let lyricWords: [LyricWord] = words.enumerated().map { index, w in
            let start = lineStart + Double(index) * step
            let raw = index < words.count - 1 ? w + Self.nbsp : w
            return LyricWord(word: raw, startTime: start, endTime: start + wordDuration)
        }
        let text = lyricWords.map(\.word).joined()
        return LyricLine(text: text, startTime: lineStart, endTime: lyricWords.last!.endTime, words: lyricWords)
    }

    private static let fixtureLines: [[String]] = [
        ["Memories", "light", "the", "corners", "of", "my", "mind"],
        ["Misty", "water", "color", "memories"],
        ["Of", "the", "way", "we", "were"],
        ["Scattered", "pictures", "of", "the", "smiles", "we", "left", "behind"],
        ["Smiles", "we", "gave", "to", "one", "another"],
        // Reported verbatim from the founder's disk cache, including its
        // apparent garble ("Fore" for "For") -- the fix must not depend on
        // the WORDS being grammatically clean.
        ["Fore", "the", "way", "we", "were"],
    ]

    /// Mirrors `LyricsView.makeDisplayLyricLines`'s `hasSyllableSync` branch
    /// (LyricsView.swift:2170-2229) exactly for the word-level split path:
    /// `realWrapWordPieces` then one `LyricLine` per group, `words: group`
    /// verbatim, `text` from `displayText(forWords:)`.
    private func splitDisplayLines(for line: LyricLine, rowWidth: CGFloat) -> [LyricLine] {
        let wordGroups = LyricDisplaySegmenter.realWrapWordPieces(for: line.words, rowWidth: rowWidth)
        guard wordGroups.count > 1 else { return [line] }
        return wordGroups.map { group in
            LyricLine(
                text: LyricDisplaySegmenter.displayText(forWords: group),
                startTime: group.first?.startTime ?? line.startTime,
                endTime: group.last?.endTime ?? line.endTime,
                words: group
            )
        }
    }

    /// (Task acceptance bar 1/2): every display row built from a word-level
    /// source line, at both widths, keeps its words.
    func test_fixture_allSplitPieces_keepWordLevelSync_at250And180() {
        for width: CGFloat in [250, 180] {
            for (lineIndex, words) in Self.fixtureLines.enumerated() {
                let line = makeNBSPLine(words, lineStart: Double(lineIndex) * 10)
                let pieces = splitDisplayLines(for: line, rowWidth: width)
                XCTAssertFalse(pieces.isEmpty, "width=\(width) line=\(lineIndex): must produce at least one display piece")
                for (pieceIndex, piece) in pieces.enumerated() {
                    XCTAssertTrue(
                        piece.hasSyllableSync,
                        "width=\(width) line=\(lineIndex) piece=\(pieceIndex) ('\(piece.text)') lost word-level sync"
                    )
                }
                // Every original word must be accounted for across the pieces
                // (no silent drop, no duplication) -- a stronger check than
                // just "non-empty".
                let totalWords = pieces.reduce(0) { $0 + $1.words.count }
                XCTAssertEqual(totalWords, line.words.count, "width=\(width) line=\(lineIndex): word count must be preserved across the split")
            }
        }
    }

    /// (Task acceptance bar 2/2): the render plan actually produces word
    /// runs for every word, and the sweep-path gate
    /// (`hasSyllableSync && !wordRuns.isEmpty`, the exact condition
    /// NativeLyricsRowView checks e.g. at line 835/1600/1893/1909/3037) is
    /// satisfied for every piece -- not just that `words` survived
    /// construction, but that the renderer would actually take the
    /// per-word sweep path instead of falling back to whole-line.
    func test_fixture_renderPlan_producesWordRunsAndSweepGate_forEveryPiece() {
        for width: CGFloat in [250, 180] {
            for (lineIndex, words) in Self.fixtureLines.enumerated() {
                let line = makeNBSPLine(words, lineStart: Double(lineIndex) * 10)
                let pieces = splitDisplayLines(for: line, rowWidth: width)
                for (pieceIndex, piece) in pieces.enumerated() {
                    let staticPlan = NativeLyricsStaticTextRenderPlan.make(line: piece)
                    let expectsPerRunSweep = piece.hasSyllableSync && !staticPlan.wordRuns.isEmpty
                    XCTAssertTrue(
                        expectsPerRunSweep,
                        "width=\(width) line=\(lineIndex) piece=\(pieceIndex): renderer's sweep-path gate must pass"
                    )
                    XCTAssertEqual(
                        staticPlan.wordRuns.count, piece.words.count,
                        "width=\(width) line=\(lineIndex) piece=\(pieceIndex): every word must produce a run plan"
                    )

                    let config = NativeLyricsTextRenderPlan.Configuration(
                        line: piece, currentTime: piece.startTime + 0.05, isActive: true
                    )
                    let plan = NativeLyricsTextRenderPlan.make(configuration: config, staticPlan: staticPlan)
                    XCTAssertEqual(plan.wordRuns.count, piece.words.count)
                }
            }
        }
    }

    /// Closes the loop at the actual glyph-geometry layer the row draws
    /// from (`NativeLyricsTextSweepLayout.makePlan`, real NSLayoutManager):
    /// every word must be LOCATED as its own visual run with real glyphs,
    /// not merged into one giant unbreakable blob (the NBSP-as-non-breaking
    /// side effect) and not silently dropped.
    func test_fixture_sweepLayout_locatesEveryWordAsARun_forRepresentativeLine() {
        let line = makeNBSPLine(Self.fixtureLines[0], lineStart: 0) // "Memories light the corners of my mind"
        for width: CGFloat in [250, 180] {
            let pieces = splitDisplayLines(for: line, rowWidth: width)
            var totalOrdersSeen = Set<Int>()
            var pieceWordOffset = 0
            for piece in pieces {
                let staticPlan = NativeLyricsStaticTextRenderPlan.make(line: piece)
                let config = NativeLyricsTextRenderPlan.Configuration(line: piece, currentTime: piece.startTime, isActive: true)
                let dynPlan = NativeLyricsTextRenderPlan.make(configuration: config, staticPlan: staticPlan)
                let sweepPlan = NativeLyricsTextSweepLayout.makePlan(
                    displayText: dynPlan.displayText,
                    wordRuns: dynPlan.wordRuns,
                    width: width,
                    fontSize: 24,
                    fadeHalfPoint: 12,
                    lineSpacing: 4
                )
                XCTAssertFalse(sweepPlan.isEmpty, "width=\(width): sweep layout must produce at least one visual line for a word-level piece")
                var ordersInPiece = Set<Int>()
                for visualLine in sweepPlan {
                    for run in visualLine.runs {
                        XCTAssertFalse(run.glyphs.isEmpty, "width=\(width): every word run must have located glyphs")
                        ordersInPiece.insert(run.order)
                    }
                }
                XCTAssertEqual(
                    ordersInPiece.count, piece.words.count,
                    "width=\(width): every word in this piece must be located as its own run (order), none merged/dropped"
                )
                for order in ordersInPiece { totalOrdersSeen.insert(order + pieceWordOffset) }
                pieceWordOffset += piece.words.count
            }
            XCTAssertEqual(totalOrdersSeen.count, line.words.count, "width=\(width): every word across the whole line must be located exactly once")
        }
    }
}
