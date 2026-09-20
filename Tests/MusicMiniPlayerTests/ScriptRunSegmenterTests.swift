/**
 * [INPUT]: MusicMiniPlayerCore ScriptRunSegmenter (pure, no Translation
 *          framework, no NLLanguageRecognizer).
 * [OUTPUT]: Segmentation + reassembly tests pinned to the 2026-09-20 NewJeans
 *           "How Sweet" evidence (mixed Hangul+Latin lines that whole-line
 *           auto-detect only half-translates).
 * [POS]: Test module.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class ScriptRunSegmenterTests: XCTestCase {

    // ------------------------------------------------------------------
    // MARK: - Evidence lines (translation_cache.json, 2026-09-20)
    // ------------------------------------------------------------------

    func test_evidenceLine1_deoNeunAnBwaDrama_segmentsKoreanThenLatin() {
        let runs = ScriptRunSegmenter.segment("더는 안 봐 drama it's good karma")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].language, .korean)
        XCTAssertEqual(runs[0].text, "더는 안 봐 ")
        XCTAssertEqual(runs[1].language, .unknown)
        XCTAssertEqual(runs[1].text, "drama it's good karma")
    }

    func test_evidenceLine2_geumanhaeCusItsClear_segmentsKoreanThenLatin() {
        let runs = ScriptRunSegmenter.segment("그만해 cus it's clear")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].language, .korean)
        XCTAssertEqual(runs[0].text, "그만해 ")
        XCTAssertEqual(runs[1].language, .unknown)
        XCTAssertEqual(runs[1].text, "cus it's clear")
    }

    func test_evidenceLine3_modeunGeTypical_segmentsKoreanThenLatin() {
        let runs = ScriptRunSegmenter.segment("모든 게 typical")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].language, .korean)
        XCTAssertEqual(runs[0].text, "모든 게 ")
        XCTAssertEqual(runs[1].language, .unknown)
        XCTAssertEqual(runs[1].text, "typical")
    }

    // ------------------------------------------------------------------
    // MARK: - Single-run lines (must keep the current whole-line path)
    // ------------------------------------------------------------------

    func test_pureKoreanLine_isOneKoreanRun() {
        let runs = ScriptRunSegmenter.segment("사랑해 너무 많이")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].language, .korean)
    }

    func test_pureEnglishLine_isOneUnknownRun() {
        let runs = ScriptRunSegmenter.segment("I love you so much")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].language, .unknown)
    }

    func test_japaneseWithKana_isOneJapaneseRun_kanjiIncluded() {
        // 大好き = kanji "大" + kana "好き" — the kanji must merge into the
        // adjacent kana run as Japanese, not stay a separate ambiguous run.
        let runs = ScriptRunSegmenter.segment("大好きだよ")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].language, .japanese)
        XCTAssertEqual(runs[0].text, "大好きだよ")
    }

    func test_hanOnlyLine_withoutKana_isUnknown() {
        // Pure Han text with no kana context is script-ambiguous
        // (shared between Chinese and Japanese) — stays unknown.
        let runs = ScriptRunSegmenter.segment("大好")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].language, .unknown)
    }

    // ------------------------------------------------------------------
    // MARK: - Punctuation attachment
    // ------------------------------------------------------------------

    func test_punctuationAttachesToPrecedingRun_doesNotSplitLatinRun() {
        let runs = ScriptRunSegmenter.segment("안녕, hello there")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].language, .korean)
        XCTAssertEqual(runs[0].text, "안녕, ")
        XCTAssertEqual(runs[1].language, .unknown)
        XCTAssertEqual(runs[1].text, "hello there")
    }

    func test_apostropheInsideLatinWord_staysOneRun() {
        let runs = ScriptRunSegmenter.segment("it's good karma")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].language, .unknown)
        XCTAssertEqual(runs[0].text, "it's good karma")
    }

    // ------------------------------------------------------------------
    // MARK: - Short-run merge
    // ------------------------------------------------------------------

    func test_lonelySingleLetterLatinToken_mergesIntoNeighborRun_notItsOwnRun() {
        // A single stray Latin letter surrounded by Korean text (below the
        // 2-letter minimum) must not survive as its own fragment.
        let runs = ScriptRunSegmenter.segment("안녕 I 사랑해")
        XCTAssertEqual(runs.count, 1, "a 1-letter run merges into a neighbor instead of splitting the line into three")
        XCTAssertEqual(runs[0].language, .korean)
    }

    // ------------------------------------------------------------------
    // MARK: - Empty input
    // ------------------------------------------------------------------

    func test_emptyLine_segmentsToNoRuns() {
        XCTAssertEqual(ScriptRunSegmenter.segment(""), [])
    }

    // ------------------------------------------------------------------
    // MARK: - Reassembly (pure, stubbed per-run outputs)
    // ------------------------------------------------------------------

    func test_reassemble_latinAndCJKOutputs_joinWithSpace() {
        // Latin run translated to English stays Latin; joining with a CJK
        // neighbor's output needs a space.
        let result = ScriptRunSegmenter.reassemble(["Don't watch it anymore", "戏剧是好业力"])
        XCTAssertEqual(result, "Don't watch it anymore 戏剧是好业力")
    }

    func test_reassemble_twoCJKOutputs_joinWithoutSpace() {
        // Both runs translate into Chinese (ko target zh + auto-detected
        // English target zh) — CJK-to-CJK boundary must not carry a space.
        let result = ScriptRunSegmenter.reassemble(["不再看了", "戏剧是好业力"])
        XCTAssertEqual(result, "不再看了戏剧是好业力")
    }

    func test_reassemble_singleRun_returnsItUnchanged() {
        XCTAssertEqual(ScriptRunSegmenter.reassemble(["hello there"]), "hello there")
    }

    func test_reassemble_trimsWhitespaceCarriedFromSourceRunText() {
        // Source runs carry trailing whitespace attached from the original
        // line (e.g. "더는 안 봐 "); translated output for that run may or may
        // not preserve it — reassembly must not depend on it.
        let result = ScriptRunSegmenter.reassemble(["더 이상 안 봐 ", " drama it's good karma"])
        XCTAssertEqual(result, "더 이상 안 봐 drama it's good karma")
    }

    func test_reassemble_ignoresEmptyRunOutputs() {
        let result = ScriptRunSegmenter.reassemble(["hello", "", "world"])
        XCTAssertEqual(result, "hello world")
    }
}
