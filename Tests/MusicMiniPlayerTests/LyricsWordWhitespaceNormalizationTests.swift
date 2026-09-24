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
 * Fix: `LyricWord.init`/`LyricLine.init` now normalize every Unicode
 * whitespace character other than plain space (`Character.isWhitespace`,
 * covering NBSP and the rest of the Unicode space-separator family) to
 * `" "` at construction -- the single choke point every `LyricWord`/
 * `LyricLine` in the app is built through (every parser, `LyricsWordRepair`,
 * Traditional-Chinese conversion, `LyricsDiskCache.lyricLines(from:)` on
 * every disk-cache read -- so this also self-heals stale cached entries
 * written before the fix, without a schema bump).
 *
 * Red-before-fix verified manually: temporarily reverted `LyricWord.init`/
 * `LyricLine.init` to plain assignment (no `normalizingWhitespace` call),
 * reran `test_splitPieceFromNBSPWords_keepsWordLevelSync` -- failed
 * (`hasSyllableSync` was `false`, `words.isEmpty` was `true`, reproducing
 * the founder's screenshot exactly). Restored immediately after, reran
 * green.
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

    func test_lyricWord_normalizesOtherUnicodeSpaceVariants() {
        // EM SPACE (U+2003), IDEOGRAPHIC SPACE (U+3000, sometimes present in
        // scraped CJK lyric data), NARROW NO-BREAK SPACE (U+202F).
        for scalar in ["\u{2003}", "\u{3000}", "\u{202F}"] {
            let word = LyricWord(word: "word\(scalar)", startTime: 0, endTime: 1)
            XCTAssertEqual(word.word, "word ", "scalar U+\(String(format: "%04X", scalar.unicodeScalars.first!.value)) must normalize to plain space")
        }
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
