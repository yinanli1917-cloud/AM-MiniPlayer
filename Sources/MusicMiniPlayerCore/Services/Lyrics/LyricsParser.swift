/**
 * [INPUT]: LyricModels 的 LyricLine/LyricWord 结构
 * [OUTPUT]: parseTTML/parseLRC/parseYRC 解析函数 + processLyrics 后处理
 * [POS]: Lyrics 的解析子模块，负责将各种歌词格式转换为统一的 LyricLine 数组
 * [PROTOCOL]: 变更时更新此头部，然后检查 Services/Lyrics/CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - 歌词解析器
// ============================================================

/// 歌词解析工具 - 支持 TTML/LRC/YRC 格式
public final class LyricsParser {

    public static let shared = LyricsParser()

    // MARK: - 正则表达式缓存

    private let ttmlPRegex = try? NSRegularExpression(
        pattern: "<p[^>]*begin=\"([^\"]+)\"[^>]*end=\"([^\"]+)\"[^>]*>(.*?)</p>",
        options: [.dotMatchesLineSeparators]
    )
    private let ttmlTimedSpanRegex = try? NSRegularExpression(
        pattern: "<span[^>]*begin=\"([^\"]+)\"[^>]*end=\"([^\"]+)\"[^>]*>([^<]+)</span>",
        options: []
    )
    private let ttmlTranslationSpanRegex = try? NSRegularExpression(
        pattern: "<span[^>]*ttm:role=\"x-translation\"[^>]*>([^<]+)</span>",
        options: []
    )
    private let ttmlCleanSpanRegex = try? NSRegularExpression(
        pattern: "<span[^>]*>([^<]+)</span>",
        options: []
    )
    private let lrcTimestampRegex = try? NSRegularExpression(
        pattern: "\\[(\\d{2}):(\\d{2})[:.](\\d{2,3})\\]",
        options: []
    )
    private let yrcLineRegex = try? NSRegularExpression(
        pattern: "\\[(\\d+),(\\d+)\\](.+)",
        options: []
    )
    private let yrcWordRegex = try? NSRegularExpression(
        pattern: "\\((\\d+),(\\d+),\\d+\\)([^(]+)",
        options: []
    )

    private init() {}

    // MARK: - TTML 解析 (AMLL 格式)

    /// 解析 TTML 格式歌词（AMLL 格式，支持逐字时间轴）
    public func parseTTML(_ ttmlString: String) -> [LyricLine]? {
        guard let pRegex = ttmlPRegex else { return nil }

        var lines: [LyricLine] = []
        let matches = pRegex.matches(in: ttmlString, range: NSRange(ttmlString.startIndex..., in: ttmlString))

        for match in matches {
            guard match.numberOfRanges >= 4,
                  let beginRange = Range(match.range(at: 1), in: ttmlString),
                  let endRange = Range(match.range(at: 2), in: ttmlString),
                  let contentRange = Range(match.range(at: 3), in: ttmlString) else { continue }

            let beginString = String(ttmlString[beginRange])
            let endString = String(ttmlString[endRange])
            let content = String(ttmlString[contentRange])

            var words: [LyricWord] = []
            var lineText = ""
            var translation: String? = nil

            // 提取翻译
            if let regex = ttmlTranslationSpanRegex {
                let transMatches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
                if let first = transMatches.first,
                   let textRange = Range(first.range(at: 1), in: content) {
                    let transText = String(content[textRange]).trimmingCharacters(in: .whitespaces)
                    if !transText.isEmpty { translation = transText }
                }
            }

            // 提取带时间戳的 span（逐字歌词）
            if let timedRegex = ttmlTimedSpanRegex {
                let spanMatches = timedRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))

                for spanMatch in spanMatches {
                    guard spanMatch.numberOfRanges >= 4,
                          let fullSpanRange = Range(spanMatch.range, in: content) else { continue }
                    let fullSpan = String(content[fullSpanRange])

                    // 过滤罗马音和背景音
                    if fullSpan.contains("ttm:role=\"x-roman") || fullSpan.contains("ttm:role=\"x-bg\"") { continue }

                    guard let spanBeginRange = Range(spanMatch.range(at: 1), in: content),
                          let spanEndRange = Range(spanMatch.range(at: 2), in: content),
                          let spanTextRange = Range(spanMatch.range(at: 3), in: content) else { continue }

                    let spanBegin = String(content[spanBeginRange])
                    let spanEnd = String(content[spanEndRange])
                    let spanText = String(content[spanTextRange])

                    if let wordStart = parseTTMLTime(spanBegin),
                       let wordEnd = parseTTMLTime(spanEnd) {
                        words.append(LyricWord(word: spanText, startTime: wordStart, endTime: wordEnd))
                        lineText += spanText + " "
                    }
                }
            }

            // 回退：普通 span 提取
            if words.isEmpty, let spanRegex = ttmlCleanSpanRegex {
                let spanMatches = spanRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
                for spanMatch in spanMatches {
                    guard let fullSpanRange = Range(spanMatch.range, in: content) else { continue }
                    let fullSpan = String(content[fullSpanRange])
                    if fullSpan.contains("ttm:role") { continue }

                    if spanMatch.numberOfRanges >= 2,
                       let textRange = Range(spanMatch.range(at: 1), in: content) {
                        lineText += String(content[textRange]) + " "
                    }
                }
            }

            // 回退：清理标签
            if lineText.isEmpty {
                lineText = content
                    .replacingOccurrences(of: "<span[^>]*ttm:role=\"x-translation\"[^>]*>[^<]*</span>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "<span[^>]*ttm:role=\"x-roman\"[^>]*>[^<]*</span>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }

            lineText = decodeHTMLEntities(lineText.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !lineText.isEmpty else { continue }

            if let startTime = parseTTMLTime(beginString),
               let endTime = parseTTMLTime(endString) {
                lines.append(LyricLine(text: lineText, startTime: startTime, endTime: endTime, words: words, translation: translation))
            }
        }

        lines.sort { $0.startTime < $1.startTime }
        return lines.isEmpty ? nil : lines
    }

    /// 解析 TTML 时间格式
    private func parseTTMLTime(_ timeString: String) -> TimeInterval? {
        let components = timeString.components(separatedBy: CharacterSet(charactersIn: ":,."))
        guard components.count >= 2 else { return nil }

        if components.count == 2 {
            let minute = Int(components[0]) ?? 0
            let second = Int(components[1]) ?? 0
            return Double(minute * 60 + second)
        } else if components.count == 3 {
            let first = Int(components[0]) ?? 0
            let second = Int(components[1]) ?? 0
            let third = Int(components[2]) ?? 0

            if third > 60 || components[2].count == 3 {
                return Double(first * 60) + Double(second) + Double(third) / 1000.0
            } else {
                return Double(first * 3600) + Double(second * 60) + Double(third)
            }
        } else if components.count >= 4 {
            let hour = Int(components[0]) ?? 0
            let minute = Int(components[1]) ?? 0
            let second = Int(components[2]) ?? 0
            let millisecond = Int(components[3]) ?? 0
            return Double(hour * 3600) + Double(minute * 60) + Double(second) + Double(millisecond) / 1000.0
        }

        return nil
    }

    // MARK: - LRC 解析

    /// 解析 LRC 格式歌词
    public func parseLRC(_ lrcText: String) -> [LyricLine] {
        guard let timestampRegex = lrcTimestampRegex else { return [] }

        var lines: [LyricLine] = []
        let lrcLines = lrcText.components(separatedBy: .newlines)

        for line in lrcLines {
            let matches = timestampRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard !matches.isEmpty else { continue }

            var timestamps: [Double] = []
            var lastMatchEnd = line.startIndex

            for match in matches {
                guard match.numberOfRanges == 4,
                      let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let subsecondRange = Range(match.range(at: 3), in: line),
                      let fullRange = Range(match.range, in: line) else { continue }

                let minute = Int(line[minuteRange]) ?? 0
                let second = Int(line[secondRange]) ?? 0
                let subsecondStr = String(line[subsecondRange])
                let subsecond = Int(subsecondStr) ?? 0

                let subsecondValue = subsecondStr.count == 3 ? Double(subsecond) / 1000.0 : Double(subsecond) / 100.0
                timestamps.append(Double(minute * 60 + second) + subsecondValue)
                lastMatchEnd = fullRange.upperBound
            }

            let text = decodeHTMLEntities(String(line[lastMatchEnd...]).trimmingCharacters(in: .whitespaces))
            guard !text.isEmpty else { continue }

            for startTime in timestamps {
                lines.append(LyricLine(text: text, startTime: startTime, endTime: startTime + 5.0))
            }
        }

        // 修正 endTime
        for i in 0..<lines.count where i < lines.count - 1 {
            lines[i] = LyricLine(text: lines[i].text, startTime: lines[i].startTime, endTime: lines[i + 1].startTime)
        }

        lines.sort { $0.startTime < $1.startTime }
        return lines
    }

    // MARK: - YRC 解析 (NetEase 逐字格式)

    /// 解析 YRC 格式歌词（NetEase 逐字时间轴）
    /// - Parameter timeOffset: 时间偏移（秒），用于补偿 NetEase 时间轴滞后
    public func parseYRC(_ yrcText: String, timeOffset: Double = 0.7) -> [LyricLine]? {
        guard let lineRegex = yrcLineRegex else { return nil }

        var lines: [LyricLine] = []
        let yrcLines = yrcText.components(separatedBy: .newlines)

        for line in yrcLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("{") else { continue }

            let range = NSRange(trimmedLine.startIndex..., in: trimmedLine)
            guard let match = lineRegex.firstMatch(in: trimmedLine, range: range),
                  match.numberOfRanges >= 4,
                  let startRange = Range(match.range(at: 1), in: trimmedLine),
                  let durationRange = Range(match.range(at: 2), in: trimmedLine),
                  let contentRange = Range(match.range(at: 3), in: trimmedLine) else { continue }

            let lineStartMs = Int(trimmedLine[startRange]) ?? 0
            let lineDurationMs = Int(trimmedLine[durationRange]) ?? 0
            let content = String(trimmedLine[contentRange])

            var lineText = ""
            var words: [LyricWord] = []

            if let wordRegex = yrcWordRegex {
                let wordMatches = wordRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
                for wordMatch in wordMatches {
                    guard wordMatch.numberOfRanges >= 4,
                          let wordStartRange = Range(wordMatch.range(at: 1), in: content),
                          let wordDurationRange = Range(wordMatch.range(at: 2), in: content),
                          let charRange = Range(wordMatch.range(at: 3), in: content) else { continue }

                    let wordStartMs = Int(content[wordStartRange]) ?? 0
                    let wordDurationMs = Int(content[wordDurationRange]) ?? 0
                    let wordText = String(content[charRange])

                    lineText += wordText
                    let wordStartTime = max(0, Double(wordStartMs) / 1000.0 - timeOffset)
                    let wordEndTime = max(0, Double(wordStartMs + wordDurationMs) / 1000.0 - timeOffset)
                    words.append(LyricWord(word: wordText, startTime: wordStartTime, endTime: wordEndTime))
                }
            }

            if lineText.isEmpty {
                lineText = content.replacingOccurrences(of: "\\(\\d+,\\d+,\\d+\\)", with: "", options: .regularExpression)
            }

            lineText = decodeHTMLEntities(lineText.trimmingCharacters(in: .whitespaces))
            guard !lineText.isEmpty else { continue }

            let startTime = max(0, Double(lineStartMs) / 1000.0 - timeOffset)
            let endTime = max(0, Double(lineStartMs + lineDurationMs) / 1000.0 - timeOffset)
            lines.append(LyricLine(text: lineText, startTime: startTime, endTime: endTime, words: words))
        }

        lines.sort { $0.startTime < $1.startTime }
        return lines.isEmpty ? nil : lines
    }

    // MARK: - 无时间轴歌词

    /// 为纯文本歌词创建均匀分布的时间轴
    public func createUnsyncedLyrics(_ plainText: String, duration: TimeInterval) -> [LyricLine] {
        let textLines = plainText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !textLines.isEmpty else { return [] }

        let timePerLine = duration / Double(textLines.count)
        return textLines.enumerated().map { index, text in
            LyricLine(
                text: text,
                startTime: Double(index) * timePerLine,
                endTime: Double(index + 1) * timePerLine
            )
        }
    }

    // MARK: - 后处理

    /// 处理原始歌词：移除元信息、修复 endTime、添加前奏占位符
    /// - Parameter rawLyrics: 原始歌词行
    /// - Returns: (处理后的歌词数组, 第一句真正歌词的索引)
    public func processLyrics(_ rawLyrics: [LyricLine]) -> (lyrics: [LyricLine], firstRealLyricIndex: Int) {
        guard !rawLyrics.isEmpty else { return ([], 0) }

        // 如果歌词只有1-2行且包含纯音乐提示，返回空
        if rawLyrics.count <= 2 {
            for line in rawLyrics {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                if kInstrumentalPatterns.contains(where: { text.contains($0) }) {
                    return ([], 0)
                }
            }
        }

        // 过滤元信息行
        var filteredLyrics: [LyricLine] = []
        var firstRealLyricStartTime: TimeInterval = 0
        var foundFirstRealLyric = false
        var consecutiveColonLines = 0
        var colonRegionEndTime: TimeInterval = 0

        // 检测冒号区域
        var colonCountInFirstLines = 0
        for i in 0..<min(5, rawLyrics.count) {
            let trimmed = rawLyrics[i].text.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("：") || trimmed.contains(":") {
                colonCountInFirstLines += 1
            }
        }
        let isColonMetadataRegion = colonCountInFirstLines >= 2

        for line in rawLyrics {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let duration = line.endTime - line.startTime
            let hasColon = trimmed.contains("：") || trimmed.contains(":")
            let hasTitleSeparator = trimmed.contains(" - ") && trimmed.count < 50

            let isPureSymbolLine = isPureSymbols(trimmed)
            let isMetadataKeyword = isMetadataKeywordLine(trimmed)

            if !foundFirstRealLyric && hasColon {
                consecutiveColonLines += 1
                if consecutiveColonLines >= 2 || isColonMetadataRegion {
                    colonRegionEndTime = line.endTime + 5.0
                }
            } else if !foundFirstRealLyric && !hasColon && !hasTitleSeparator {
                consecutiveColonLines = 0
            }

            let isMetadata = !foundFirstRealLyric && (
                trimmed.isEmpty || isPureSymbolLine || hasTitleSeparator || isMetadataKeyword ||
                (hasColon && line.startTime < colonRegionEndTime) ||
                (hasColon && duration < 10.0) ||
                (!hasColon && duration < 2.0 && trimmed.count < 10)
            )

            if isMetadata {
                continue
            } else {
                if !foundFirstRealLyric {
                    foundFirstRealLyric = true
                    firstRealLyricStartTime = line.startTime
                }
                filteredLyrics.append(line)
            }
        }

        if filteredLyrics.isEmpty {
            filteredLyrics = rawLyrics
            firstRealLyricStartTime = rawLyrics.first?.startTime ?? 0
        }

        // 修复 endTime
        for i in 0..<filteredLyrics.count {
            let currentStart = filteredLyrics[i].startTime
            let currentEnd = filteredLyrics[i].endTime

            var nextValidStart = currentStart + 10.0
            for j in (i + 1)..<filteredLyrics.count {
                if filteredLyrics[j].startTime > currentStart {
                    nextValidStart = filteredLyrics[j].startTime
                    break
                }
            }

            let fixedEnd = (currentEnd > currentStart) ? currentEnd : nextValidStart
            filteredLyrics[i] = LyricLine(
                text: filteredLyrics[i].text,
                startTime: currentStart,
                endTime: fixedEnd,
                words: filteredLyrics[i].words,
                translation: filteredLyrics[i].translation
            )
        }

        // 插入前奏占位符
        let loadingLine = LyricLine(text: "⋯", startTime: 0, endTime: firstRealLyricStartTime)
        return ([loadingLine] + filteredLyrics, 1)
    }

    // MARK: - 翻译合并

    /// 合并原文歌词和翻译歌词（O(n) 时间戳索引匹配）
    public func mergeLyricsWithTranslation(original: [LyricLine], translated: [LyricLine]) -> [LyricLine] {
        guard !translated.isEmpty else { return original }

        // 按 startTime 建立索引，O(n) 查找
        let translationMap = Dictionary(
            translated.map { (Int($0.startTime * 10), $0.text) },
            uniquingKeysWith: { first, _ in first }
        )

        return original.map { line in
            let key = Int(line.startTime * 10)
            // 精确匹配（±0.1s 内）或扩展搜索（±1.0s）
            let matchText = translationMap[key]
                ?? translationMap[key - 1] ?? translationMap[key + 1]
                ?? translationMap[key - 5] ?? translationMap[key + 5]

            guard let text = matchText else { return line }
            return LyricLine(
                text: line.text, startTime: line.startTime, endTime: line.endTime,
                words: line.words, translation: text
            )
        }
    }

    /// 应用时间偏移
    public func applyTimeOffset(to lyrics: [LyricLine], offset: Double) -> [LyricLine] {
        guard offset != 0 else { return lyrics }

        return lyrics.map { line in
            let newWords = line.words.map { word in
                LyricWord(
                    word: word.word,
                    startTime: max(0, word.startTime - offset),
                    endTime: max(0, word.endTime - offset)
                )
            }
            return LyricLine(
                text: line.text,
                startTime: max(0, line.startTime - offset),
                endTime: max(0, line.endTime - offset),
                words: newWords,
                translation: line.translation
            )
        }
    }

    // MARK: - 工具函数

    private func decodeHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private func isPureSymbols(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }

        let hasLetters = trimmed.unicodeScalars.contains { scalar in
            let isCJK = (0x4E00...0x9FFF).contains(scalar.value) ||
                        (0x3400...0x4DBF).contains(scalar.value) ||
                        (0x20000...0x2A6DF).contains(scalar.value)
            return isCJK || CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }
        return !hasLetters
    }

    private func isMetadataKeywordLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let keywords = ["词", "曲", "编曲", "作曲", "作词", "翻译", "LRC", "lrc",
                       "Lyrics", "Music", "Arrangement", "Composer", "Lyricist"]
        for keyword in keywords {
            if trimmed.hasPrefix(keyword) || trimmed.contains(keyword + "：") || trimmed.contains(keyword + ":") {
                return true
            }
        }
        return false
    }
}
