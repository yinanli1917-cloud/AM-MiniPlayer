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

    func testParseLRC_stripsEnhancedInlineTimestamps() {
        let lrc = "[00:10.00]<00:10.000>青<00:10.360>花<00:10.720>瓷"
        let lines = parser.parseLRC(lrc)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "青花瓷")
        XCTAssertEqual(lines[0].startTime, 10.0, accuracy: 0.001)
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
        // 8% intro margin (7.2s) + 5% outro margin (4.5s) → active span 78.3s → 26.1s/line
        let intro = 90 * 0.08  // 7.2
        let active = 90 * 0.87 // 78.3
        let perLine = active / 3 // 26.1
        XCTAssertEqual(lines[0].startTime, intro, accuracy: 0.01)
        XCTAssertEqual(lines[0].endTime, intro + perLine, accuracy: 0.01)
        XCTAssertEqual(lines[1].startTime, intro + perLine, accuracy: 0.01)
        XCTAssertEqual(lines[2].startTime, intro + 2 * perLine, accuracy: 0.01)
        XCTAssertEqual(lines[2].endTime, intro + 3 * perLine, accuracy: 0.01)
        // Last line ends before song end (outro margin preserved)
        XCTAssertLessThan(lines[2].endTime, 90)
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

    func testParseYRC_capsHeldNoteWordDuration() {
        // Real data: "漏" has 42.6s duration in YRC (held note to end of song)
        let yrc = "[250900,43000](250900,300,0)看(251200,42600,0)漏(293800,100,0)眼"
        guard let lines = parser.parseYRC(yrc, timeOffset: 0) else {
            XCTFail("parseYRC returned nil")
            return
        }
        let line = lines[0]
        // Word "漏" must be capped to 3s, not 42.6s
        let lou = line.words[1]
        XCTAssertEqual(lou.word, "漏")
        XCTAssertLessThanOrEqual(lou.endTime - lou.startTime, 3.0,
                                  "Held note word duration should be capped to 3s")
        // Line endTime must be clamped to last word's (capped) endTime
        XCTAssertLessThanOrEqual(line.endTime, line.words.last!.endTime,
                                  "Line endTime should not exceed last word's endTime")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - YRC + tlyric Translation Pipeline (Real Data)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Exercises the exact code path from fetchNetEaseLyrics:
    /// YRC parse → stripMetadata → merge tlyric → applyOffset → processLyrics
    /// Verifies that BOTH word-level sync AND translations survive the full pipeline.
    func testYRCPlusTlyric_fullPipeline() {
        // Real data: エスケイプ by EPO (NetEase ID 1422446388)
        let yrcText = """
        [0,1000](0,1000,0) 作词 : EPO
        [1000,1000](1000,1000,0) 作曲 : EPO
        [21200,3400](21200,540,0)か(21740,360,0)ら(22100,150,0)っ(22250,420,0)ぽ(22670,480,0)の(23150,960,0)ベ(24110,100,0)ッ(24210,80,0)ド(24290,310,0)と
        [24670,3940](24670,200,0)書(24870,340,0)き(25210,360,0)置(25570,310,0)き(25880,140,0)に(26020,990,0)今(27010,520,0)気(27530,260,0)づ(27790,820,0)き
        [29250,3000](29250,230,0)お(29480,250,0)ろ(29730,180,0)お(29910,560,0)ろ(30470,490,0)と(30960,670,0)方(31630,620,0)々
        [32350,3580](32350,330,0)行(32680,260,0)く(32940,390,0)え(33330,510,0)探(33840,570,0)し(34410,470,0)て(34880,440,0)る(35320,200,0)は(35520,410,0)ず
        [35960,7600](35960,350,0)目(36310,290,0)に(36600,440,0)余(37040,760,0)る(37800,480,0)束(38280,420,0)縛(38700,1260,0)に (39960,430,0)た(40390,520,0)く(40910,460,0)ら(41370,300,0)ん(41670,220,0)だ(41890,680,0)家(42570,990,0)出
        [43800,12500](43800,520,0)朝(44320,170,0)も(44490,290,0)や(44780,1160,0)に(45940,340,0)ま(46280,240,0)ぎ(46520,810,0)れ(47330,8970,0)･･･
        """

        let tlyricText = """
        [by:崎玖六]
        [00:21.330]那张纸条在空荡荡的床上
        [00:24.760]我现在才注意到
        [00:29.330]茫然的人群中
        [00:32.530]你应该在到处寻找我吧
        [00:36.150]不堪忍受的束缚的我走出家门
        [00:43.930]夹杂在这晨雾里...
        """

        // Step 1: Parse YRC (same as fetchNetEaseLyrics: timeOffset: 0)
        guard let yrcLines = parser.parseYRC(yrcText, timeOffset: 0) else {
            XCTFail("YRC parse returned nil")
            return
        }
        var lyrics = parser.stripMetadataLines(yrcLines)

        // Verify YRC parsed with word-level sync
        XCTAssertEqual(lyrics.count, 6, "Expected 6 lines after metadata stripping")
        for (i, line) in lyrics.enumerated() {
            XCTAssertTrue(line.hasSyllableSync, "Line \(i) '\(line.text)' should have syllable sync")
        }

        // Step 2: Parse and merge tlyric
        let translatedLyrics = parser.stripMetadataLines(parser.parseLRC(tlyricText))
        XCTAssertEqual(translatedLyrics.count, 6, "Expected 6 tlyric lines")
        lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)

        // Check that ALL lines got translations
        for (i, line) in lyrics.enumerated() {
            XCTAssertNotNil(line.translation, "Line \(i) '\(line.text)' missing translation after merge")
            XCTAssertTrue(line.hasSyllableSync, "Line \(i) '\(line.text)' lost word sync after merge")
        }

        // Step 3: Apply time offset
        lyrics = parser.applyTimeOffset(to: lyrics, offset: 0.7)

        // Translations and words must survive offset
        for (i, line) in lyrics.enumerated() {
            XCTAssertNotNil(line.translation, "Line \(i) lost translation after applyTimeOffset")
            XCTAssertTrue(line.hasSyllableSync, "Line \(i) lost word sync after applyTimeOffset")
        }

        // Step 4: processLyrics
        let (processed, _) = parser.processLyrics(lyrics)

        // Skip the "⋯" placeholder at index 0
        let realLines = Array(processed.dropFirst())
        XCTAssertEqual(realLines.count, 6)
        for (i, line) in realLines.enumerated() {
            XCTAssertNotNil(line.translation, "Line \(i) '\(line.text)' lost translation after processLyrics")
            XCTAssertTrue(line.hasSyllableSync, "Line \(i) '\(line.text)' lost word sync after processLyrics")
        }

        // Spot check specific translations
        XCTAssertEqual(realLines[2].text.replacingOccurrences(of: " ", with: ""), "おろおろと方々")
        XCTAssertEqual(realLines[2].translation, "茫然的人群中")
        XCTAssertEqual(realLines[3].text.replacingOccurrences(of: " ", with: ""), "行くえ探してるはず")
        XCTAssertEqual(realLines[3].translation, "你应该在到处寻找我吧")
    }

    /// Tests that TTML word-level lyrics + inline translations both survive the pipeline.
    func testTTML_wordLevelWithTranslation_fullPipeline() {
        // Real AMLL format (based on フォニイ by 可不)
        let ttml = """
        <p begin="00:00.719" end="00:05.768" ttm:agent="v1"><span begin="00:00.719" end="00:01.146">こ</span><span begin="00:01.146" end="00:01.482">の</span><span begin="00:01.549" end="00:01.873">世で</span><span begin="00:01.873" end="00:02.401">造花</span><span begin="00:02.401" end="00:02.805">より</span><span begin="00:02.873" end="00:03.263">綺</span><span begin="00:03.263" end="00:03.956">麗</span><span begin="00:03.956" end="00:04.272">な</span><span begin="00:04.272" end="00:04.858">花</span><span begin="00:04.858" end="00:05.016">は</span><span begin="00:05.016" end="00:05.388">無い</span><span begin="00:05.388" end="00:05.768">わ</span><span ttm:role="x-translation" xml:lang="zh-CN">这世上 没有比假花更艳丽的花朵</span></p>
        <p begin="00:05.798" end="00:09.821" ttm:agent="v1"><span begin="00:05.798" end="00:06.249">何故</span><span begin="00:06.249" end="00:06.785">ならば</span><span begin="00:06.785" end="00:07.326">総</span><span begin="00:07.326" end="00:07.512">て</span><span begin="00:07.512" end="00:07.845">は</span><span begin="00:07.882" end="00:08.220">嘘</span><span begin="00:08.220" end="00:08.531">で</span><span begin="00:08.568" end="00:09.246">出来</span><span begin="00:09.246" end="00:09.608">てい</span><span begin="00:09.608" end="00:09.821">る</span><span ttm:role="x-translation" xml:lang="zh-CN">究其原因都是因其由谎言构成</span></p>
        """

        guard let lines = parser.parseTTML(ttml) else {
            XCTFail("TTML parse returned nil")
            return
        }

        XCTAssertEqual(lines.count, 2)

        // Line 1: word-level + translation
        XCTAssertTrue(lines[0].hasSyllableSync, "TTML line 0 should have syllable sync")
        XCTAssertEqual(lines[0].words.count, 12)
        XCTAssertEqual(lines[0].translation, "这世上 没有比假花更艳丽的花朵")

        // Line 2: word-level + translation
        XCTAssertTrue(lines[1].hasSyllableSync, "TTML line 1 should have syllable sync")
        XCTAssertEqual(lines[1].translation, "究其原因都是因其由谎言构成")

        // processLyrics must preserve both
        let (processed, _) = parser.processLyrics(lines)
        let realLines = Array(processed.dropFirst())
        for (i, line) in realLines.enumerated() {
            XCTAssertTrue(line.hasSyllableSync, "Processed line \(i) lost word sync")
            XCTAssertNotNil(line.translation, "Processed line \(i) lost translation")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Title Card Stripping
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// YRC with title/credits line at ~1.3s that survived old stripMetadataLines.
    /// Real data: "You Belong To Me" by Jo Stafford (NetEase 22544885).
    /// The title card "You Belong to Me -Norman Wisdom Jo Stafford..." at 1.35s
    /// pushes all lyrics display one line late for the entire song.
    func testStripMetadataLines_titleCardAtSongStart() {
        let yrcText = """
        [0,680](0,680,0) 作词 : KING/Price/Stewart
        [680,670](680,670,0) 作曲 : KING/Price/Stewart
        [1350,13230](1350,2900,0)You (4250,1230,0)Belong (5480,490,0)to (5970,680,0)Me (6650,160,0)-(6810,1250,0)Norman (8060,1650,0)Wisdom (9710,610,0)Jo  (10320,2640,0)Stafford (12960,1170,0)Stewart  (14130,450,0)King
        [14580,6720](14580,560,0)See (15140,360,0)the (15500,1020,0)pyramids (16520,560,0)a(17080,290,0)long (17370,430,0)the (17800,1500,0)Nile
        [21300,6980](21300,520,0)Watch (21820,340,0)the (22160,990,0)sunrise (23150,520,0)from (23670,200,0)a (23870,1020,0)tropic (24890,3390,0)isle
        """

        guard let yrcLines = parser.parseYRC(yrcText, timeOffset: 0) else {
            XCTFail("YRC parse returned nil")
            return
        }
        let stripped = parser.stripMetadataLines(yrcLines)

        // Title card "You Belong to Me -Norman Wisdom..." must be stripped.
        // First real lyric should be "See the pyramids along the Nile".
        XCTAssertEqual(stripped.count, 2, "Expected 2 lines: title card + 2 metadata stripped")
        XCTAssertTrue(stripped[0].text.contains("pyramids"),
                      "First line after stripping should be 'pyramids', got '\(stripped[0].text)'")
    }

    /// Title card with different format: "Song Title / Artist" at 2s.
    /// Must also be stripped — generalizes beyond " - " separator.
    func testStripMetadataLines_titleCardDashNoTrailingSpace() {
        let lines = [
            LyricLine(text: "作词 : Test Writer", startTime: 0, endTime: 0.5),
            LyricLine(text: "My Song Title -Artist Name Producer", startTime: 1.5, endTime: 15.0),
            LyricLine(text: "First real lyric line here", startTime: 15.0, endTime: 22.0),
            LyricLine(text: "Second real lyric line", startTime: 22.0, endTime: 28.0),
        ]
        let stripped = parser.stripMetadataLines(lines)

        XCTAssertEqual(stripped.count, 2, "Expected 2 lines after stripping metadata + title card")
        XCTAssertEqual(stripped[0].text, "First real lyric line here")
    }

    /// Real data: 明明他已離開妳 by Hins Cheung — NE lyrics include credit
    /// lines with long labels ("Background Vocals and arrangement"), values
    /// with "@location" markers, and credit lines WITHOUT colons
    /// ("Mastering by X @ Studio HK"). All three survived old stripping.
    func testStripMetadataLines_longLabelsAndByCredits() {
        let lines = [
            LyricLine(text: "Background Vocals and arrangement : Cousin Fung", startTime: 12.3, endTime: 14.0),
            LyricLine(text: "Recorded/Mixed by : 铭 @Avon Studio, Hong Kong", startTime: 14.2, endTime: 17.0),
            LyricLine(text: "Mastering by Frankie Hung @ Air Studio HK", startTime: 17.4, endTime: 19.0),
            LyricLine(text: "他都一走了之", startTime: 19.5, endTime: 22.0),
            LyricLine(text: "妳会否哭诉后找我做靠倚", startTime: 22.0, endTime: 28.0),
        ]
        let stripped = parser.stripMetadataLines(lines)

        XCTAssertEqual(stripped.count, 2, "Expected 2 real lyric lines, got \(stripped.count): \(stripped.map(\.text))")
        XCTAssertEqual(stripped[0].text, "他都一走了之")
        XCTAssertEqual(stripped[1].text, "妳会否哭诉后找我做靠倚")
    }

    /// Real verifier data: 起风了 / Strange Weather exposed credits with
    /// compact labels ("鼓：...", "SP: ...") as the rendered first lyric.
    func testStripMetadataLines_instrumentAndPublisherCredits() {
        let lines = [
            LyricLine(text: "鼓：吉田佳史 (TRICERATOPS) (Yoshifumi Yoshida(TRICERATOPS))", startTime: 9.1, endTime: 12.0),
            LyricLine(text: "SP: Warner Chappell Music, Hong Kong Limited Taiwan Branch", startTime: 8.0, endTime: 11.0),
            LyricLine(text: "一路上走走停停", startTime: 24.0, endTime: 28.0),
            LyricLine(text: "Good at breaking hearts", startTime: 5.2, endTime: 8.0),
        ]
        let stripped = parser.stripMetadataLines(lines)

        XCTAssertEqual(stripped.count, 2, "Expected only real lyrics, got: \(stripped.map(\.text))")
        XCTAssertEqual(stripped[0].text, "一路上走走停停")
        XCTAssertEqual(stripped[1].text, "Good at breaking hearts")
    }

    /// Real data: Not Worth by Dreamz FM — last "line" is a decorative
    /// "——=END=——" marker that survived stripping.
    /// Also covers variants: "=== END ===", "---END---", "***".
    func testStripMetadataLines_decorativeMarkers() {
        let lines = [
            LyricLine(text: "first real lyric", startTime: 10, endTime: 15),
            LyricLine(text: "second real lyric", startTime: 15, endTime: 20),
            LyricLine(text: "——=END=——", startTime: 200, endTime: 210),
        ]
        let stripped = parser.stripMetadataLines(lines)

        XCTAssertEqual(stripped.count, 2, "Decorative END marker must be stripped, got: \(stripped.map(\.text))")
        XCTAssertFalse(stripped.contains(where: { $0.text.contains("END") }))
    }

    /// Real data: Monologue From One Soul by Eason Chan — Genius returns
    /// structural section markers like "[副歌]" that shouldn't render as
    /// lyrics. Must strip "[Chorus]", "[Verse]", "[Bridge]", "[副歌]",
    /// "[间奏]", etc.
    func testStripMetadataLines_structuralSectionTags() {
        let lines = [
            LyricLine(text: "[副歌]", startTime: 24.5, endTime: 30),
            LyricLine(text: "過去我對與不對 再要計較太瑣碎", startTime: 51.1, endTime: 55),
            LyricLine(text: "[Chorus]", startTime: 60, endTime: 65),
            LyricLine(text: "regular lyric line", startTime: 66, endTime: 70),
            LyricLine(text: "[Verse 2]", startTime: 75, endTime: 80),
            LyricLine(text: "另一句歌词", startTime: 81, endTime: 85),
        ]
        let stripped = parser.stripMetadataLines(lines)

        XCTAssertEqual(stripped.count, 3, "Section tags must be stripped, got: \(stripped.map(\.text))")
        XCTAssertFalse(stripped.contains(where: { $0.text.contains("[") }))
    }

    /// Real data: 戀愛預告 by Sandy Lamb (NetEase id=5258725) — the title card
    /// at 0s is `戀愛預告（《開心鬼》電影插曲-林姍姍（SandyLim` which uses:
    /// - CJK fullwidth open paren `（` inside
    /// - CJK guillemets `《》`
    /// - Dash followed DIRECTLY by CJK characters `-林`
    /// None of these match the old " - " / " -[A-Z]" rules.
    /// User symptom: "one line ahead" — title card occupies intro window,
    /// making every later line feel off even though timestamps are correct.
    func testStripMetadataLines_cjkTitleCardAtSongStart() {
        let lines = [
            LyricLine(text: "戀愛預告（《開心鬼》電影插曲-林姍姍（SandyLim", startTime: 0.0, endTime: 18.9),
            LyricLine(text: "愛神也有苦惱", startTime: 18.9, endTime: 24.6),
            LyricLine(text: "問他可知道", startTime: 24.6, endTime: 30.0),
        ]
        let stripped = parser.stripMetadataLines(lines)
        XCTAssertEqual(stripped.count, 2, "CJK title card must be stripped, got: \(stripped.map(\.text))")
        XCTAssertEqual(stripped[0].text, "愛神也有苦惱")
    }

    /// Simpler CJK title card: `歌名-歌手` (dash directly followed by CJK).
    func testStripMetadataLines_dashFollowedByCJK() {
        let lines = [
            LyricLine(text: "戀愛預告-林姍姍", startTime: 0.5, endTime: 10.0),
            LyricLine(text: "愛神也有苦惱", startTime: 10.0, endTime: 16.0),
        ]
        let stripped = parser.stripMetadataLines(lines)
        XCTAssertEqual(stripped.count, 1)
        XCTAssertEqual(stripped[0].text, "愛神也有苦惱")
    }

    /// Title card marker: line in first 5s containing CJK fullwidth open paren
    /// `（` indicates a title card with annotations (movie/show reference).
    func testStripMetadataLines_cjkFullwidthParenthesisTitleCard() {
        let lines = [
            LyricLine(text: "愛神也有苦惱", startTime: 18.9, endTime: 24.6),
            LyricLine(text: "某歌名（電影主題曲）", startTime: 1.0, endTime: 18.9),
        ]
        let stripped = parser.stripMetadataLines(lines)
        XCTAssertEqual(stripped.count, 1)
        XCTAssertEqual(stripped[0].text, "愛神也有苦惱")
    }

    /// Real data: NewJeans - Supernatural from NetEase can append Chinese
    /// translation fragments directly to non-Chinese lyric text even when a
    /// tlyric translation is also present. The displayed original line must
    /// stay source-language only.
    func testStripChineseTranslations_removesInlineChineseEvenWithExistingTranslation() {
        let lines = [
            LyricLine(text: "Stormy night", startTime: 26.9, endTime: 29.0, translation: "暴风雨夜"),
            LyricLine(text: "Cloudy sky", startTime: 29.6, endTime: 31.0, translation: "乌云密布天际"),
            LyricLine(text: "向着彼此 不断靠近", startTime: 42.1, endTime: 44.0, translation: "无可奈何"),
            LyricLine(text: "내 심박수를 믿어 我相信 自己的心跳声", startTime: 51.0, endTime: 55.0, translation: "相信心跳"),
            LyricLine(text: "もう知っている我 都已了然", startTime: 66.2, endTime: 70.0, translation: "我都已了然"),
            LyricLine(text: "So it's sure这是可以肯定的", startTime: 77.4, endTime: 80.0, translation: "这可以肯定"),
        ]

        let stripped = parser.stripChineseTranslations(lines)

        XCTAssertEqual(stripped.map(\.text), [
            "Stormy night",
            "Cloudy sky",
            "내 심박수를 믿어",
            "もう知っている",
            "So it's sure",
        ])
        XCTAssertEqual(stripped[2].translation, "相信心跳")
        XCTAssertEqual(stripped[3].translation, "我都已了然")
        XCTAssertEqual(stripped[4].translation, "这可以肯定")
    }
}
