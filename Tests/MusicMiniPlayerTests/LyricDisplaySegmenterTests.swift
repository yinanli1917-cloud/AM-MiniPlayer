import XCTest
@testable import MusicMiniPlayerCore

final class LyricDisplaySegmenterTests: XCTestCase {
    func testLatinPunctuationSegmentsStayWithinThreeEstimatedLines() {
        let options = LyricDisplaySegmentationOptions(maxVisualLines: 3, maxLineUnits: 8)
        let text = "I keep running through the midnight, looking for a reason; every little echo becomes another chorus. Then the city answers back."

        let segments = LyricDisplaySegmenter.segments(for: text, options: options)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy {
            LyricDisplaySegmenter.estimatedVisualLineCount(for: $0, options: options) <= 3
        })
        XCTAssertEqual(normalizedWhitespace(segments.joined(separator: " ")), normalizedWhitespace(text))
    }

    func testCJKJapaneseKoreanPunctuationSegmentsStayWithinThreeEstimatedLines() {
        let options = LyricDisplaySegmentationOptions(maxVisualLines: 3, maxLineUnits: 5)
        let text = "月が綺麗ですね、でもまだ帰れない。숨이 차올라도 멈추지 않아！下一句继续向前走。"

        let segments = LyricDisplaySegmenter.segments(for: text, options: options)

        XCTAssertGreaterThan(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy {
            LyricDisplaySegmenter.estimatedVisualLineCount(for: $0, options: options) <= 3
        })
        XCTAssertEqual(segments.joined(), text)
    }

    func testExplicitNewlinesBecomeDisplayBoundaries() {
        let options = LyricDisplaySegmentationOptions(maxVisualLines: 3, maxLineUnits: 40)
        let text = "first branch\nsecond branch\nthird branch"

        let display = LyricDisplaySegmenter.displayText(for: text, options: options)

        XCTAssertEqual(display, text)
    }

    func testHardWrapFallbackHandlesTextWithoutPunctuation() {
        let options = LyricDisplaySegmentationOptions(maxVisualLines: 3, maxLineUnits: 4)
        let text = "lalalalalalalalalalalalalalalala"

        let segments = LyricDisplaySegmenter.segments(for: text, options: options)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy {
            LyricDisplaySegmenter.estimatedVisualLineCount(for: $0, options: options) <= 3
        })
        XCTAssertEqual(segments.joined(), text)
    }

    func testScreenshotLineIsSplitForCompactFloatingWindow() {
        let text = "There was a world when we were standing still"

        let display = LyricDisplaySegmenter.displayText(for: text, options: .mainLyric)
        let segments = LyricDisplaySegmenter.segments(for: text, options: .mainLyric)

        XCTAssertTrue(display.contains("\n"))
        XCTAssertTrue(segments.allSatisfy {
            LyricDisplaySegmenter.estimatedVisualLineCount(for: $0, options: .mainLyric) <= 3
        })
        XCTAssertEqual(normalizedWhitespace(segments.joined(separator: " ")), text)
    }

    func testScatteredPicturesLineSplitsIntoVisibleChunks() {
        let text = "Scattered pictures of the smiles we left behind"

        let segments = LyricDisplaySegmenter.segments(for: text, options: .mainLyric)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy {
            LyricDisplaySegmenter.estimatedVisualLineCount(for: $0, options: .mainLyric) <= 3
        })
        XCTAssertEqual(normalizedWhitespace(segments.joined(separator: " ")), text)
    }

    func testSplitterDoesNotCreateSingleWordOrphanForCompactEnglishLine() {
        let text = "give the other side another"

        let segments = LyricDisplaySegmenter.segments(for: text, options: .mainLyric)

        XCTAssertFalse(segments.contains { semanticWordCount($0) == 1 })
        XCTAssertEqual(normalizedWhitespace(segments.joined(separator: " ")), text)
    }

    func testSplitterKeepsCompactFiveWordPhraseTogether() {
        let text = "Myself one hundred per cent"

        let segments = LyricDisplaySegmenter.segments(for: text, options: .mainLyric)

        XCTAssertEqual(segments, [text])
    }

    func testSplitterKeepsCompactSixWordPhraseTogether() {
        let text = "Yeah, I feel my pulse quickening"

        let segments = LyricDisplaySegmenter.segments(for: text, options: .mainLyric)

        XCTAssertEqual(segments, [text])
    }

    func testSplitterAvoidsTinyGeneratedChunkForBrainScreenshotLine() {
        let text = "if you could save me from my brain?"

        let segments = LyricDisplaySegmenter.segments(for: text, options: .mainLyric)

        XCTAssertEqual(segments, [text])
    }

    func testSplitterDoesNotLeaveOneWordFinalVisualLine() {
        let text = "And if we had the chance to do it"

        let segments = LyricDisplaySegmenter.segments(for: text, options: .mainLyric)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy {
            LyricDisplaySegmenter.estimatedWrappedLineWordCounts(for: $0, options: .mainLyric).last != 1
        })
        XCTAssertEqual(normalizedWhitespace(segments.joined(separator: " ")), text)
    }

    func testSplitterAvoidsShortFinalVisualLineAcrossCommonCompactEnglishShapes() {
        let cases = [
            "I used to walk into the room",
            "the chance to do it all again",
            "there was a world when we were standing still",
            "smiles we gave to one another",
        ]

        for text in cases {
            let segments = LyricDisplaySegmenter.segments(for: text, options: .mainLyric)
            XCTAssertTrue(segments.allSatisfy {
                LyricDisplaySegmenter.estimatedWrappedLineWordCounts(for: $0, options: .mainLyric).last != 1
            }, text)
            XCTAssertEqual(normalizedWhitespace(segments.joined(separator: " ")), text)
        }
    }

    func testWordSplitterDoesNotLeaveSingleWordOrphanWhenItCanRebalance() {
        let words = [
            LyricWord(word: "give", startTime: 1, endTime: 1.2),
            LyricWord(word: "the", startTime: 1.2, endTime: 1.4),
            LyricWord(word: "other", startTime: 1.4, endTime: 1.6),
            LyricWord(word: "side", startTime: 1.6, endTime: 1.8),
            LyricWord(word: "another", startTime: 1.8, endTime: 2.0),
        ]
        let options = LyricDisplaySegmentationOptions(maxVisualLines: 2, maxLineUnits: 7.0)

        let segments = LyricDisplaySegmenter.wordSegments(for: words, options: options)

        XCTAssertFalse(segments.contains { $0.count == 1 })
        XCTAssertEqual(segments.flatMap { $0 }.map(\.word), words.map(\.word))
    }

    func testWordSplitterKeepsCompactFiveWordPhraseTogether() {
        let words = [
            LyricWord(word: "Myself", startTime: 1.0, endTime: 1.2),
            LyricWord(word: "one", startTime: 1.2, endTime: 1.4),
            LyricWord(word: "hundred", startTime: 1.4, endTime: 1.6),
            LyricWord(word: "per", startTime: 1.6, endTime: 1.8),
            LyricWord(word: "cent", startTime: 1.8, endTime: 2.0),
        ]

        let segments = LyricDisplaySegmenter.wordSegments(for: words, options: .mainLyric)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.flatMap { $0 }.map(\.word), words.map(\.word))
    }

    func testWordSplitterKeepsCompactSixWordPhraseTogether() {
        let words = [
            LyricWord(word: "Yeah,", startTime: 1.0, endTime: 1.2),
            LyricWord(word: "I", startTime: 1.2, endTime: 1.4),
            LyricWord(word: "feel", startTime: 1.4, endTime: 1.6),
            LyricWord(word: "my", startTime: 1.6, endTime: 1.8),
            LyricWord(word: "pulse", startTime: 1.8, endTime: 2.0),
            LyricWord(word: "quickening", startTime: 2.0, endTime: 2.2),
        ]

        let segments = LyricDisplaySegmenter.wordSegments(for: words, options: .mainLyric)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.flatMap { $0 }.map(\.word), words.map(\.word))
    }

    func testWordSplitterAvoidsTinyGeneratedChunkForBrainScreenshotLine() {
        let words = [
            LyricWord(word: "if", startTime: 1.0, endTime: 1.2),
            LyricWord(word: "you", startTime: 1.2, endTime: 1.4),
            LyricWord(word: "could", startTime: 1.4, endTime: 1.6),
            LyricWord(word: "save", startTime: 1.6, endTime: 1.8),
            LyricWord(word: "me", startTime: 1.8, endTime: 2.0),
            LyricWord(word: "from", startTime: 2.0, endTime: 2.2),
            LyricWord(word: "my", startTime: 2.2, endTime: 2.4),
            LyricWord(word: "brain?", startTime: 2.4, endTime: 2.6),
        ]

        let segments = LyricDisplaySegmenter.wordSegments(for: words, options: .mainLyric)
        let textSegments = segments.map { $0.map(\.word).joined(separator: " ") }

        XCTAssertEqual(textSegments, ["if you could save me from my brain?"])
        XCTAssertEqual(segments.flatMap { $0 }.map(\.word), words.map(\.word))
    }

    func testWordSplitterTreatsWhitespaceTimedSpanAsPhraseBoundary() {
        let words = [
            LyricWord(word: "Wouldn't ", startTime: 117.29, endTime: 117.53),
            LyricWord(word: "it ", startTime: 117.53, endTime: 117.59),
            LyricWord(word: "be ", startTime: 117.59, endTime: 117.65),
            LyricWord(word: "sweet ", startTime: 117.65, endTime: 118.22),
            LyricWord(word: " ", startTime: 118.22, endTime: 118.79),
            LyricWord(word: "if ", startTime: 118.79, endTime: 119.33),
            LyricWord(word: "you ", startTime: 119.33, endTime: 119.57),
            LyricWord(word: "could ", startTime: 119.57, endTime: 119.66),
            LyricWord(word: "save ", startTime: 119.66, endTime: 120.05),
            LyricWord(word: "me ", startTime: 120.05, endTime: 120.17),
            LyricWord(word: "from ", startTime: 120.17, endTime: 120.47),
            LyricWord(word: "my ", startTime: 120.47, endTime: 120.68),
            LyricWord(word: "brain?", startTime: 120.68, endTime: 121.04),
        ]

        let segments = LyricDisplaySegmenter.wordSegments(for: words, options: .mainLyric)
        let textSegments = segments.map {
            $0.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        XCTAssertEqual(textSegments, [
            "Wouldn't it be sweet",
            "if you could save me from my brain?",
        ])
        XCTAssertFalse(textSegments.contains("if you could"))
        XCTAssertFalse(segments.flatMap { $0 }.contains { $0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    func testWordSplitterDoesNotLeaveOneWordFinalVisualLine() {
        let words = [
            LyricWord(word: "And", startTime: 1.0, endTime: 1.2),
            LyricWord(word: "if", startTime: 1.2, endTime: 1.4),
            LyricWord(word: "we", startTime: 1.4, endTime: 1.6),
            LyricWord(word: "had", startTime: 1.6, endTime: 1.8),
            LyricWord(word: "the", startTime: 1.8, endTime: 2.0),
            LyricWord(word: "chance", startTime: 2.0, endTime: 2.2),
            LyricWord(word: "to", startTime: 2.2, endTime: 2.4),
            LyricWord(word: "do", startTime: 2.4, endTime: 2.6),
            LyricWord(word: "it", startTime: 2.6, endTime: 2.8),
        ]

        let segments = LyricDisplaySegmenter.wordSegments(for: words, options: .mainLyric)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy {
            let text = $0.map(\.word).joined(separator: " ")
            return LyricDisplaySegmenter.estimatedWrappedLineWordCounts(for: text, options: .mainLyric).last != 1
        })
        XCTAssertEqual(segments.flatMap { $0 }.map(\.word), words.map(\.word))
    }

    func testTranslationCanBeBalancedToMainLyricChunks() {
        let translation = "散落着我们留下的微笑的照片"

        let segments = LyricDisplaySegmenter.balancedSegments(
            for: translation,
            count: 2,
            options: .translation
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(segments.joined(), translation)
    }

    func testTranslationWithSingleInternalSpaceStillBalancesToEveryLyricChunk() {
        let translation = "若你能拯救我脱离苦海 这样难道不好吗"

        let segments = LyricDisplaySegmenter.balancedSegments(
            for: translation,
            count: 2,
            options: .translation
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy { !$0.isEmpty })
    }

    func testCompactTranslationWithoutSpacesStillBalancesToEveryLyricChunk() {
        let translation = "如果我们还有机会重新来过"

        let segments = LyricDisplaySegmenter.balancedSegments(
            for: translation,
            count: 3,
            options: .translation
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(segments.joined(), translation)
    }

    func testWordSegmentsPreserveOrderAndTimingWithoutMutatingLyricLine() {
        let options = LyricDisplaySegmentationOptions(maxVisualLines: 3, maxLineUnits: 3)
        let words = [
            LyricWord(word: "We", startTime: 1, endTime: 2),
            LyricWord(word: "keep", startTime: 2, endTime: 3),
            LyricWord(word: "moving", startTime: 3, endTime: 4),
            LyricWord(word: "forward.", startTime: 4, endTime: 5),
            LyricWord(word: "Again", startTime: 5, endTime: 6),
        ]
        let line = LyricLine(
            text: "We keep moving forward. Again",
            startTime: 1,
            endTime: 6,
            words: words,
            translation: "我们继续向前。再次出发。"
        )

        let segments = LyricDisplaySegmenter.wordSegments(for: line.words, options: options)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.flatMap { $0 }.map(\.word), words.map(\.word))
        XCTAssertEqual(segments.flatMap { $0 }.map(\.startTime), words.map(\.startTime))
        XCTAssertEqual(line.text, "We keep moving forward. Again")
        XCTAssertEqual(line.translation, "我们继续向前。再次出发。")
    }

    private func normalizedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func semanticWordCount(_ text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }
}
