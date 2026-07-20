/**
 * [INPUT]: MusicMiniPlayerCore NativeLyricsStaticTextRenderPlan
 * [OUTPUT]: Unit tests for the all-emphasis line degenerate case
 * [POS]: Test module. Pins the 2026-07-19 mask defect: the active word-cascade
 *        path renders base+sweep ONLY from non-emphasis runs; a line where
 *        every word is emphasis-eligible (non-CJK, 2-7 chars, held >=1.5s —
 *        e.g. "Billie Jean is not my lover", "（I want you）", 45/5606 lines
 *        in the user's cache) produced an EMPTY base+sweep partition: only
 *        floating glow glyphs rendered, and the row blanked entirely on
 *        manual scroll. Rule: emphasis is contrast — a line that would be
 *        all-emphasis is emphasized nowhere.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsEmphasisPartitionTests: XCTestCase {

    private func line(_ words: [(String, TimeInterval)]) -> LyricLine {
        var t: TimeInterval = 10
        var lyricWords: [LyricWord] = []
        for (text, dur) in words {
            lyricWords.append(LyricWord(word: text, startTime: t, endTime: t + dur))
            t += dur
        }
        return LyricLine(text: words.map(\.0).joined(separator: " "),
                         startTime: 10, endTime: t, words: lyricWords)
    }

    func test_allEmphasisLine_stripsEmphasisEntirely() {
        // The Billie Jean chorus shape: every word Latin, 2-7 chars, held >= 1.5s.
        let plan = NativeLyricsStaticTextRenderPlan.make(
            line: line([("Billie", 1.6), ("Jean", 1.8), ("is", 1.5), ("not", 1.6), ("my", 1.5), ("lover", 2.2)])
        )
        XCTAssertTrue(plan.wordRuns.allSatisfy { !$0.isEmphasis },
                      "all-emphasis line must fall back to plain word cascade (base+sweep for every word)")
    }

    func test_backingVocalParenthetical_stripsEmphasis() {
        let plan = NativeLyricsStaticTextRenderPlan.make(
            line: line([("（I", 1.7), ("want", 1.9), ("you）", 2.0)])
        )
        XCTAssertTrue(plan.wordRuns.allSatisfy { !$0.isEmphasis })
    }

    func test_mixedLine_keepsEmphasisOnEligibleWords() {
        // One short word breaks the degenerate case: emphasis stays meaningful.
        let plan = NativeLyricsStaticTextRenderPlan.make(
            line: line([("Oh", 0.3), ("baby", 2.4)])
        )
        XCTAssertFalse(plan.wordRuns[0].isEmphasis)
        XCTAssertTrue(plan.wordRuns[1].isEmphasis)
    }

    func test_cjkLine_neverEmphasized_unchanged() {
        let plan = NativeLyricsStaticTextRenderPlan.make(
            line: line([("浪", 1.8), ("漫", 1.9)])
        )
        XCTAssertTrue(plan.wordRuns.allSatisfy { !$0.isEmphasis })
    }
}
