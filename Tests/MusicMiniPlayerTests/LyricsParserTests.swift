/**
 * [INPUT]: MusicMiniPlayerCore 的 LyricsParser, LyricLine, LyricWord
 * [OUTPUT]: LyricsParser 单元测试
 * [POS]: 测试模块，验证 LRC/TTML/YRC 解析 + processLyrics 后处理
 */

import XCTest
@testable import MusicMiniPlayerCore

final class LyricsParserTests: XCTestCase {

    private let parser = LyricsParser.shared

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - LRC 解析
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testParseLRC_basicSynced() {
        let lrc = """
        [00:12.34]第一行歌词
        [00:18.56]第二行歌词
        [00:25.00]第三行歌词
        """
        let lines = parser.parseLRC(lrc)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].text, "第一行歌词")
        XCTAssertEqual(lines[0].startTime, 12.34, accuracy: 0.01)
        // endTime 应被修正为下一行的 startTime
        XCTAssertEqual(lines[0].endTime, 18.56, accuracy: 0.01)
        XCTAssertEqual(lines[1].startTime, 18.56, accuracy: 0.01)
        XCTAssertEqual(lines[2].text, "第三行歌词")
    }

    func testParseLRC_threeDigitMilliseconds() {
        let lrc = "[01:05.123]Hello World"
        let lines = parser.parseLRC(lrc)

        XCTAssertEqual(lines.count, 1)
        // 3 位 → 除以 1000
        XCTAssertEqual(lines[0].startTime, 65.123, accuracy: 0.001)
    }

    func testParseLRC_twoDigitCentiseconds() {
        let lrc = "[01:05.12]Hello World"
        let lines = parser.parseLRC(lrc)

        XCTAssertEqual(lines.count, 1)
        // 2 位 → 除以 100
        XCTAssertEqual(lines[0].startTime, 65.12, accuracy: 0.01)
    }

    func testParseLRC_multipleTimestamps() {
        // 一行歌词多个时间戳（合唱/重复）
        let lrc = "[00:10.00][01:30.00]重复的歌词"
        let lines = parser.parseLRC(lrc)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.text == "重复的歌词" })
    }

    func testParseLRC_emptyInput() {
        let lines = parser.parseLRC("")
        XCTAssertTrue(lines.isEmpty)
    }

    func testParseLRC_noTimestamps() {
        let lrc = "Just plain text\nNo timestamps here"
        let lines = parser.parseLRC(lrc)
        XCTAssertTrue(lines.isEmpty)
    }

    func testParseLRC_skipEmptyText() {
        let lrc = """
        [00:05.00]
        [00:10.00]有内容的行
        """
        let lines = parser.parseLRC(lrc)
        // 空文本行应被跳过
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "有内容的行")
    }

    func testParseLRC_htmlEntities() {
        let lrc = "[00:10.00]Rock &amp; Roll"
        let lines = parser.parseLRC(lrc)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Rock & Roll")
    }

    func testParseLRC_sortedByTime() {
        let lrc = """
        [00:30.00]第三行
        [00:10.00]第一行
        [00:20.00]第二行
        """
        let lines = parser.parseLRC(lrc)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].text, "第一行")
        XCTAssertEqual(lines[1].text, "第二行")
        XCTAssertEqual(lines[2].text, "第三行")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - TTML 解析
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testParseTTML_basicLines() {
        let ttml = """
        <p begin="00:12.345" end="00:18.678">Hello World</p>
        <p begin="00:20.000" end="00:25.000">Second Line</p>
        """
        let lines = parser.parseTTML(ttml)

        XCTAssertNotNil(lines)
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?[0].text, "Hello World")
        XCTAssertEqual(lines?[0].startTime ?? 0, 12.345, accuracy: 0.001)
        XCTAssertEqual(lines?[0].endTime ?? 0, 18.678, accuracy: 0.001)
    }

    func testParseTTML_timedSpans() {
        let ttml = """
        <p begin="00:10.000" end="00:15.000"><span begin="00:10.000" end="00:11.000">Hello</span><span begin="00:11.000" end="00:12.000">World</span></p>
        """
        let lines = parser.parseTTML(ttml)

        XCTAssertNotNil(lines)
        XCTAssertEqual(lines?.count, 1)
        // 应有逐字信息
        XCTAssertEqual(lines?[0].words.count, 2)
        XCTAssertEqual(lines?[0].words[0].word, "Hello")
        XCTAssertEqual(lines?[0].words[1].word, "World")
    }

    func testParseTTML_withTranslation() {
        let ttml = """
        <p begin="00:10.000" end="00:15.000"><span begin="00:10.000" end="00:15.000">你好世界</span><span ttm:role="x-translation">Hello World</span></p>
        """
        let lines = parser.parseTTML(ttml)

        XCTAssertNotNil(lines)
        XCTAssertEqual(lines?[0].translation, "Hello World")
    }

    func testParseTTML_htmlEntities() {
        let ttml = """
        <p begin="00:05.000" end="00:10.000">Rock &amp; Roll</p>
        """
        let lines = parser.parseTTML(ttml)
        XCTAssertEqual(lines?[0].text, "Rock & Roll")
    }

    func testParseTTML_emptyInput() {
        let lines = parser.parseTTML("")
        XCTAssertNil(lines)
    }

    func testParseTTML_noValidParagraphs() {
        let ttml = "<div>No p tags here</div>"
        let lines = parser.parseTTML(ttml)
        XCTAssertNil(lines)
    }

    func testParseTTML_filtersRomanAndBgSpans() {
        let ttml = """
        <p begin="00:10.000" end="00:15.000"><span begin="00:10.000" end="00:15.000">歌词</span><span begin="00:10.000" end="00:15.000" ttm:role="x-roman">geci</span><span begin="00:10.000" end="00:15.000" ttm:role="x-bg">bg</span></p>
        """
        let lines = parser.parseTTML(ttml)

        XCTAssertNotNil(lines)
        // 只有"歌词"这个 word，roman 和 bg 被过滤
        XCTAssertEqual(lines?[0].words.count, 1)
        XCTAssertEqual(lines?[0].words[0].word, "歌词")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - YRC 解析
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testParseYRC_basicLine() {
        // 格式: [lineStartMs,lineDurationMs](wordStartMs,wordDurationMs,0)text
        let yrc = "[10000,5000](10000,2000,0)Hello(12000,3000,0)World"
        let lines = parser.parseYRC(yrc, timeOffset: 0)

        XCTAssertNotNil(lines)
        XCTAssertEqual(lines?.count, 1)
        XCTAssertEqual(lines?[0].text, "HelloWorld")
        XCTAssertEqual(lines?[0].startTime ?? 0, 10.0, accuracy: 0.01)
        XCTAssertEqual(lines?[0].endTime ?? 0, 15.0, accuracy: 0.01)
        // 逐字信息
        XCTAssertEqual(lines?[0].words.count, 2)
        XCTAssertEqual(lines?[0].words[0].word, "Hello")
        XCTAssertEqual(lines?[0].words[0].startTime ?? 0, 10.0, accuracy: 0.01)
        XCTAssertEqual(lines?[0].words[1].word, "World")
    }

    func testParseYRC_withTimeOffset() {
        let yrc = "[10000,5000](10000,2000,0)Hello"
        let lines = parser.parseYRC(yrc, timeOffset: 0.7)

        XCTAssertNotNil(lines)
        // startTime = 10000/1000 - 0.7 = 9.3
        XCTAssertEqual(lines?[0].startTime ?? 0, 9.3, accuracy: 0.01)
    }

    func testParseYRC_skipJsonLines() {
        let yrc = """
        {"key": "value"}
        [10000,5000](10000,2000,0)Hello
        """
        let lines = parser.parseYRC(yrc, timeOffset: 0)

        XCTAssertNotNil(lines)
        XCTAssertEqual(lines?.count, 1)
    }

    func testParseYRC_emptyInput() {
        let lines = parser.parseYRC("", timeOffset: 0)
        XCTAssertNil(lines)
    }

    func testParseYRC_multipleLines() {
        let yrc = """
        [5000,3000](5000,1500,0)你(6500,1500,0)好
        [10000,4000](10000,2000,0)世(12000,2000,0)界
        """
        let lines = parser.parseYRC(yrc, timeOffset: 0)

        XCTAssertNotNil(lines)
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?[0].text, "你好")
        XCTAssertEqual(lines?[1].text, "世界")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - createUnsyncedLyrics
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testCreateUnsyncedLyrics() {
        let text = "Line One\nLine Two\nLine Three"
        let lines = parser.createUnsyncedLyrics(text, duration: 90)

        XCTAssertEqual(lines.count, 3)
        // 每行 30 秒
        XCTAssertEqual(lines[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(lines[0].endTime, 30, accuracy: 0.01)
        XCTAssertEqual(lines[1].startTime, 30, accuracy: 0.01)
        XCTAssertEqual(lines[2].startTime, 60, accuracy: 0.01)
        XCTAssertEqual(lines[2].endTime, 90, accuracy: 0.01)
    }

    func testCreateUnsyncedLyrics_emptyInput() {
        let lines = parser.createUnsyncedLyrics("", duration: 100)
        XCTAssertTrue(lines.isEmpty)
    }

    func testCreateUnsyncedLyrics_skipsBlankLines() {
        let text = "Line One\n\n\nLine Two"
        let lines = parser.createUnsyncedLyrics(text, duration: 60)
        XCTAssertEqual(lines.count, 2)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - processLyrics 后处理
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testProcessLyrics_insertsLoadingPlaceholder() {
        let raw = [
            LyricLine(text: "歌词正文", startTime: 15, endTime: 20),
            LyricLine(text: "第二行", startTime: 20, endTime: 25),
        ]
        let (lyrics, firstIdx) = parser.processLyrics(raw)

        // 第一行应该是 "⋯" 前奏占位符
        XCTAssertEqual(lyrics[0].text, "⋯")
        XCTAssertEqual(lyrics[0].startTime, 0)
        XCTAssertEqual(lyrics[0].endTime, 15)
        XCTAssertEqual(firstIdx, 1)
    }

    func testProcessLyrics_filtersMetadata() {
        let raw = [
            LyricLine(text: "作词：某某", startTime: 0, endTime: 5),
            LyricLine(text: "作曲：某某", startTime: 5, endTime: 10),
            LyricLine(text: "歌词正文", startTime: 15, endTime: 20),
        ]
        let (lyrics, _) = parser.processLyrics(raw)

        // 元信息行应被过滤，只保留正文 + 前奏占位符
        XCTAssertEqual(lyrics.count, 2) // "⋯" + "歌词正文"
        XCTAssertEqual(lyrics[1].text, "歌词正文")
    }

    func testProcessLyrics_emptyInput() {
        let (lyrics, idx) = parser.processLyrics([])
        XCTAssertTrue(lyrics.isEmpty)
        XCTAssertEqual(idx, 0)
    }

    func testProcessLyrics_instrumentalDetection() {
        let raw = [
            LyricLine(text: "纯音乐，请欣赏", startTime: 0, endTime: 300),
        ]
        let (lyrics, _) = parser.processLyrics(raw)
        // 纯音乐提示应返回空
        XCTAssertTrue(lyrics.isEmpty)
    }

    func testProcessLyrics_fixesEndTime() {
        // endTime <= startTime 应被修复
        let raw = [
            LyricLine(text: "第一行", startTime: 10, endTime: 5),  // 异常 endTime
            LyricLine(text: "第二行", startTime: 20, endTime: 25),
        ]
        let (lyrics, _) = parser.processLyrics(raw)

        // 修复后 endTime 应 > startTime（取下一行的 startTime）
        let firstLyric = lyrics[1] // 跳过前奏占位符
        XCTAssertGreaterThan(firstLyric.endTime, firstLyric.startTime)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - mergeLyricsWithTranslation
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testMergeLyricsWithTranslation() {
        let original = [
            LyricLine(text: "Stay in the middle", startTime: 10, endTime: 15),
            LyricLine(text: "Like you a little", startTime: 15, endTime: 20),
        ]
        let translated = [
            LyricLine(text: "留在中间", startTime: 10, endTime: 15),
            LyricLine(text: "像你一样", startTime: 15, endTime: 20),
        ]
        let merged = parser.mergeLyricsWithTranslation(original: original, translated: translated)

        XCTAssertEqual(merged[0].text, "Stay in the middle")
        XCTAssertEqual(merged[0].translation, "留在中间")
        XCTAssertEqual(merged[1].translation, "像你一样")
    }

    func testMergeLyricsWithTranslation_emptyTranslation() {
        let original = [LyricLine(text: "你好", startTime: 10, endTime: 15)]
        let merged = parser.mergeLyricsWithTranslation(original: original, translated: [])
        XCTAssertNil(merged[0].translation)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - applyTimeOffset
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testApplyTimeOffset() {
        let lyrics = [
            LyricLine(text: "Test", startTime: 10, endTime: 15,
                       words: [LyricWord(word: "Test", startTime: 10, endTime: 15)])
        ]
        let shifted = parser.applyTimeOffset(to: lyrics, offset: 2.0)

        XCTAssertEqual(shifted[0].startTime, 8.0, accuracy: 0.01)
        XCTAssertEqual(shifted[0].endTime, 13.0, accuracy: 0.01)
        XCTAssertEqual(shifted[0].words[0].startTime, 8.0, accuracy: 0.01)
    }

    func testApplyTimeOffset_clampsToZero() {
        let lyrics = [LyricLine(text: "Test", startTime: 1, endTime: 3)]
        let shifted = parser.applyTimeOffset(to: lyrics, offset: 5.0)

        XCTAssertEqual(shifted[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(shifted[0].endTime, 0, accuracy: 0.01)
    }

    func testApplyTimeOffset_zeroOffset() {
        let lyrics = [LyricLine(text: "Test", startTime: 10, endTime: 15)]
        let shifted = parser.applyTimeOffset(to: lyrics, offset: 0)
        XCTAssertEqual(shifted[0].startTime, 10, accuracy: 0.01)
    }
}
