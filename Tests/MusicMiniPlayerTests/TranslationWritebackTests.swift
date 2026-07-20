/**
 * [INPUT]: MusicMiniPlayerCore LyricsService.mergingTranslations
 * [OUTPUT]: Unit tests for the single-publish translation writeback
 * [POS]: Test module. Pins the 2026-07-20 flicker fix: the ML writeback used
 *        to mutate the @Published lyrics array element-by-element; the merge
 *        is now a pure function producing ONE new array so the service
 *        publishes exactly once (one SwiftUI re-render for the whole
 *        translation emergence).
 */

import XCTest
@testable import MusicMiniPlayerCore

final class TranslationWritebackTests: XCTestCase {

    private func lines(_ texts: [String]) -> [LyricLine] {
        texts.enumerated().map { i, t in
            LyricLine(text: t, startTime: TimeInterval(i), endTime: TimeInterval(i + 1))
        }
    }

    func test_merge_fillsEligibleIndicesOnly() {
        let base = lines(["hello", "la la la", "world"])
        let merged = LyricsService.mergingTranslations(
            into: base, eligibleIndices: [0, 2], translatedTexts: ["你好", "世界"])
        XCTAssertEqual(merged[0].translation, "你好")
        XCTAssertNil(merged[1].translation)
        XCTAssertEqual(merged[2].translation, "世界")
    }

    func test_merge_shortResultArray_isSafe() {
        let base = lines(["a", "b", "c"])
        let merged = LyricsService.mergingTranslations(
            into: base, eligibleIndices: [0, 1, 2], translatedTexts: ["甲"])
        XCTAssertEqual(merged[0].translation, "甲")
        XCTAssertNil(merged[1].translation)
        XCTAssertNil(merged[2].translation)
    }

    func test_merge_doesNotMutateInput() {
        let base = lines(["a"])
        _ = LyricsService.mergingTranslations(into: base, eligibleIndices: [0], translatedTexts: ["甲"])
        XCTAssertNil(base[0].translation)
    }

    func test_merge_preservesExistingSourceTranslations() {
        var base = lines(["a", "b"])
        base[0].translation = "源翻译"
        let merged = LyricsService.mergingTranslations(
            into: base, eligibleIndices: [1], translatedTexts: ["乙"])
        XCTAssertEqual(merged[0].translation, "源翻译")
        XCTAssertEqual(merged[1].translation, "乙")
    }
}
