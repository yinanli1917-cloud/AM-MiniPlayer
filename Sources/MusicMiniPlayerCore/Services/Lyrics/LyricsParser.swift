/**
 * [INPUT]: LyricModels 的 LyricLine/LyricWord 结构
 * [OUTPUT]: parseTTML/parseLRC/parseYRC 解析函数 + processLyrics 后处理 + containsColonMetadata 工具
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

            let translation = extractTranslation(from: content)
            var (words, lineText) = extractTimedWords(from: content)

            // 回退：普通 span / 清理标签
            if words.isEmpty { lineText = extractCleanText(from: content) }

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

    // MARK: - TTML 子解析器

    /// 提取翻译 span
    private func extractTranslation(from content: String) -> String? {
        guard let regex = ttmlTranslationSpanRegex else { return nil }
        let transMatches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        guard let first = transMatches.first,
              let textRange = Range(first.range(at: 1), in: content) else { return nil }
        let transText = String(content[textRange]).trimmingCharacters(in: .whitespaces)
        return transText.isEmpty ? nil : transText
    }

    /// 提取带时间戳的 span（逐字歌词）
    private func extractTimedWords(from content: String) -> (words: [LyricWord], text: String) {
        guard let timedRegex = ttmlTimedSpanRegex else { return ([], "") }

        var words: [LyricWord] = []
        var lineText = ""
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

            if let wordStart = parseTTMLTime(String(content[spanBeginRange])),
               let wordEnd = parseTTMLTime(String(content[spanEndRange])) {
                let spanText = String(content[spanTextRange])
                words.append(LyricWord(word: spanText, startTime: wordStart, endTime: wordEnd))
                lineText += spanText + " "
            }
        }

        return (words, lineText)
    }

    /// 回退提取：普通 span → 清理标签
    private func extractCleanText(from content: String) -> String {
        // 尝试普通 span 提取
        if let spanRegex = ttmlCleanSpanRegex {
            var lineText = ""
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
            if !lineText.isEmpty { return lineText }
        }

        // 最终回退：清理所有标签
        return content
            .replacingOccurrences(of: "<span[^>]*ttm:role=\"x-translation\"[^>]*>[^<]*</span>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<span[^>]*ttm:role=\"x-roman\"[^>]*>[^<]*</span>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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

        // 纯音乐检测
        if rawLyrics.count <= 2 {
            for line in rawLyrics {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                if kInstrumentalPatterns.contains(where: { text.contains($0) }) {
                    return ([], 0)
                }
            }
        }

        // 🔑 统一元信息剥离（任意位置，不限开头）
        var filteredLyrics = stripMetadataLines(rawLyrics)
        let firstRealLyricStartTime = filteredLyrics.first?.startTime ?? rawLyrics.first?.startTime ?? 0

        if filteredLyrics.isEmpty {
            filteredLyrics = rawLyrics
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

        // 🔑 Strip translations from vocable lines — source translations (NetEase tlyric)
        // hallucinate meaningful text for "woo woo", "la la la", etc.
        filteredLyrics = filteredLyrics.map { line in
            guard line.hasTranslation, isVocableLine(line.text) else { return line }
            return LyricLine(text: line.text, startTime: line.startTime, endTime: line.endTime,
                             words: line.words, translation: nil)
        }

        // 插入前奏占位符
        let loadingLine = LyricLine(text: "⋯", startTime: 0, endTime: firstRealLyricStartTime)
        return ([loadingLine] + filteredLyrics, 1)
    }

    // MARK: - 元信息剥离（merge 前调用）

    /// 剥离任意位置的元信息行（作词/作曲/编曲/演唱等）
    /// 🔑 必须在 mergeLyricsWithTranslation 之前调用，否则元信息行会吃掉翻译时间戳
    public func stripMetadataLines(_ lines: [LyricLine]) -> [LyricLine] {
        lines.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            // Genius section tags: [Verse 1], [Chorus: Artist], [Bridge], [Outro], [Intro], etc.
            if isSectionTag(trimmed) { return false }
            // 高置信度关键词匹配（任意位置生效）
            if isMetadataKeywordLine(trimmed) { return false }
            // 标题分隔符行（"Song - Artist"，含 " - " 且出现在歌曲开头 ≤1s）
            // QQ/NetEase 常在 0s 放 "Song Title (ver.) - Artist" 的元信息行
            if trimmed.contains(" - ") && line.startTime <= 1.0 { return false }
            // 纯符号行
            if isPureSymbols(trimmed) { return false }
            return true
        }
    }

    /// 检测并提取混排翻译（韩/英+中 交替出现在相邻时间戳）
    /// 将中文行从主歌词移到前一行的 translation 属性，返回 (处理后歌词, 是否检测到混排)
    public func extractInterleavedTranslations(_ lines: [LyricLine]) -> (lyrics: [LyricLine], detected: Bool) {
        guard lines.count > 1 else { return (lines, false) }

        // Pass 1: 标记"纯中文翻译行"（含汉字、无韩文假名、非纯 ASCII）
        var isTranslationLine = Array(repeating: false, count: lines.count)
        var pairCount = 0
        for i in 0..<(lines.count - 1) {
            let gap = abs(lines[i + 1].startTime - lines[i].startTime)
            guard gap < 2.0 else { continue }
            let curChinese = isSolelyChineseLine(lines[i].text)
            let nextChinese = isSolelyChineseLine(lines[i + 1].text)
            // 一行纯中文、另一行非纯中文 → 中文行是翻译
            if curChinese && !nextChinese { isTranslationLine[i] = true; pairCount += 1 }
            else if !curChinese && nextChinese { isTranslationLine[i + 1] = true; pairCount += 1 }
        }

        guard pairCount >= 3 else { return (lines, false) }

        // Pass 2: 中文行附着到最近的非中文行作为 translation
        var result: [LyricLine] = []
        for i in 0..<lines.count {
            if isTranslationLine[i] { continue }
            var line = lines[i]
            // 检查下一行是否是翻译
            if i + 1 < lines.count && isTranslationLine[i + 1] && line.translation == nil {
                line = LyricLine(text: line.text, startTime: line.startTime, endTime: line.endTime,
                                 words: line.words, translation: lines[i + 1].text)
            }
            // 检查前一行是否是未被认领的翻译（中文行在原文行前面的情况）
            if i > 0 && isTranslationLine[i - 1] && line.translation == nil {
                let prevClaimed = (i >= 2 && !isTranslationLine[i - 2])
                if !prevClaimed {
                    line = LyricLine(text: line.text, startTime: line.startTime, endTime: line.endTime,
                                     words: line.words, translation: lines[i - 1].text)
                }
            }
            result.append(line)
        }
        return (result, true)
    }

    /// 判断是否为"纯中文行"（含汉字，无韩文/假名，非纯 ASCII）
    private func isSolelyChineseLine(_ text: String) -> Bool {
        LanguageUtils.containsChinese(text) &&
        !LanguageUtils.containsKorean(text) &&
        !LanguageUtils.containsJapanese(text) &&
        !LanguageUtils.isPureASCII(text)
    }

    /// 通用中文翻译剥离：对非中文歌曲，将主歌词行中的中文内容移到 .translation
    /// 处理三种场景：
    /// 1. 纯中文行 → 附着到相邻非中文行的 .translation
    /// 2. 拉丁/韩/日 + 中文同行 → 拆分，中文部分移到 .translation
    /// 3. 无法配对的纯中文行 → 丢弃（确认为翻译泄漏）
    /// 安全规则：含日文假名的行不拆分（CJK 字符是日文汉字，不是中文翻译）
    public func stripChineseTranslations(_ lines: [LyricLine]) -> [LyricLine] {
        guard lines.count > 3 else { return lines }

        // 统计含中文的行数，≥3 行才触发（避免误伤正常中文歌）
        let chineseLineCount = lines.filter { LanguageUtils.containsChinese($0.text) }.count
        let nonChineseLineCount = lines.filter {
            let t = $0.text.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !LanguageUtils.containsChinese(t)
        }.count

        // 非中文行少于中文行 → 中文歌，不处理
        guard chineseLineCount >= 3 && nonChineseLineCount >= chineseLineCount else { return lines }

        // Pass 1: 标记纯中文行 + 拆分混排行
        var processed: [(line: LyricLine, isPureChinese: Bool)] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, line.translation == nil, LanguageUtils.containsChinese(text) else {
                processed.append((line, false))
                continue
            }

            // Lines with Japanese kana: split at kana→CJK boundary instead of stripping all CJK
            if LanguageUtils.containsJapanese(text) {
                let (jpPart, cnPart) = splitJapaneseAndChinese(text)
                if cnPart.count >= 2 && jpPart.count >= 2 {
                    processed.append((LyricLine(
                        text: jpPart, startTime: line.startTime, endTime: line.endTime,
                        words: line.words, translation: cnPart
                    ), false))
                } else {
                    processed.append((line, false))
                }
                continue
            }

            let nonCN = stripChineseChars(text)
            let cnPart = extractChineseChars(text)

            if nonCN.count >= 2 && cnPart.count >= 2 {
                // Mixed line → split (Korean+Chinese, English+Chinese)
                processed.append((LyricLine(
                    text: nonCN, startTime: line.startTime, endTime: line.endTime,
                    words: line.words, translation: cnPart
                ), false))
            } else if isSolelyChineseLine(text) {
                processed.append((line, true))
            } else {
                processed.append((line, false))
            }
        }

        // Pass 2: pair pure Chinese lines with adjacent non-Chinese lines
        var result: [LyricLine] = []
        var skipIndices = Set<Int>()

        for i in 0..<processed.count {
            if skipIndices.contains(i) { continue }
            let (line, isPureCN) = processed[i]

            if !isPureCN {
                // Non-Chinese line: claim next pure Chinese line as translation
                var finalLine = line
                if finalLine.translation == nil,
                   i + 1 < processed.count, processed[i + 1].isPureChinese {
                    finalLine = LyricLine(
                        text: finalLine.text, startTime: finalLine.startTime,
                        endTime: finalLine.endTime, words: finalLine.words,
                        translation: processed[i + 1].line.text
                    )
                    skipIndices.insert(i + 1)
                }
                result.append(finalLine)
            } else {
                // Pure Chinese line not claimed by previous line → drop it
                // It's a confirmed translation leak (song is non-Chinese, guard passed above)
                continue
            }
        }

        return result
    }

    /// Split at the last kana position: "もう知っている我 都已了然" → ("もう知っている", "我 都已了然")
    private func splitJapaneseAndChinese(_ text: String) -> (japanese: String, chinese: String) {
        let scalars = text.unicodeScalars
        guard let lastKana = scalars.indices.last(where: { LanguageUtils.isJapaneseKana(scalars[$0]) })
        else { return (text, "") }

        let splitIdx = scalars.index(after: lastKana)
        let jp = String(scalars[scalars.startIndex..<splitIdx]).trimmingCharacters(in: .whitespaces)
        let cn = String(scalars[splitIdx...]).trimmingCharacters(in: .whitespaces)
        return (jp, cn)
    }

    /// Extract non-Chinese portion (keeps Latin, Korean, kana, digits, punctuation)
    private func stripChineseChars(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars where !LanguageUtils.isChineseScalar(s) { out.append(s) }
        return String(out).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
    }

    /// Extract Chinese portion (keeps CJK chars + adjacent CJK punctuation)
    private func extractChineseChars(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inChinese = false
        for s in text.unicodeScalars {
            let v = s.value
            let isPunct = (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
                || s == "，" || s == "。" || s == "！" || s == "？"
            if LanguageUtils.isChineseScalar(s) {
                inChinese = true
                out.append(s)
            } else if inChinese && (isPunct || s == " ") {
                out.append(s)
            } else {
                inChinese = false
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 翻译合并

    /// 合并原文歌词和翻译歌词（O(n) 时间戳索引匹配）
    /// 🔑 Rejects tlyric with low content rate (mostly empty lines = partial adaptation, not translation)
    public func mergeLyricsWithTranslation(original: [LyricLine], translated: [LyricLine]) -> [LyricLine] {
        guard !translated.isEmpty else { return original }

        // 🔑 Coverage check: tlyric must cover >= 50% of original lines
        // Partial adaptations (14 lines for 69-line song) are not real translations
        guard Double(translated.count) / Double(max(original.count, 1)) >= 0.5 else {
            DebugLogger.log("LyricsParser", "⚠️ tlyric rejected: only \(translated.count)/\(original.count) lines (partial)")
            return original
        }

        // 按 startTime 建立索引，O(n) 查找
        let translationMap = Dictionary(
            translated.map { (Int($0.startTime * 10), $0.text) },
            uniquingKeysWith: { first, _ in first }
        )

        return original.map { line in
            let key = Int(line.startTime * 10)
            let matchText = translationMap[key]
                ?? translationMap[key - 1] ?? translationMap[key + 1]
                ?? translationMap[key - 5] ?? translationMap[key + 5]

            guard let text = matchText, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
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

    /// 检测冒号元信息（"词：xxx" 或 "Lyrics: xxx"）
    private func containsColonMetadata(_ text: String) -> Bool {
        text.contains("：") || text.contains(":")
    }

    private static let htmlEntityMap: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"),
        ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
    ]

    private func decodeHTMLEntities(_ text: String) -> String {
        Self.htmlEntityMap.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private func isPureSymbols(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }

        let hasLetters = trimmed.unicodeScalars.contains { scalar in
            LanguageUtils.isCJKScalar(scalar) || CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }
        return !hasLetters
    }

    /// 检测 Genius 风格的 section tag: [Verse 1], [Chorus: Artist, Artist], [Bridge], [Outro], etc.
    /// Generalized: any line that is exactly "[…]" where content is short and non-lyrical
    private func isSectionTag(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"),
              trimmed.count >= 3, trimmed.count <= 80 else { return false }
        // Extract content between brackets
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        // Must not be empty; must not look like a timestamp "[00:01.23]"
        guard !inner.isEmpty, inner.first?.isNumber != true else { return false }
        return true
    }

    /// 检测元信息关键词行 或 泛化的信用行格式（"标签：名字/名字"）
    private func isMetadataKeywordLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // 泛化检测：短标签 + 冒号 + 名字分隔符（/ ; ,）
        // 匹配 "Composed by：A/B/C"、"词：无"、"Producer: xxx" 等任意信用格式
        for sep in ["：", ": "] {
            guard let range = trimmed.range(of: sep) else { continue }
            let label = String(trimmed[trimmed.startIndex..<range.lowerBound])
            let value = String(trimmed[range.upperBound...])
            // 标签短（≤15字符）+ 值非空 + 值像信用（含分隔符 或 短标签是 CJK）
            guard label.count <= 15, !value.isEmpty else { continue }
            let labelTrimmed = label.trimmingCharacters(in: .whitespaces)
            let hasSeparators = value.contains("/") || value.contains(";") || value.contains("；")
            let isCJKLabel = LanguageUtils.containsCJK(labelTrimmed) && labelTrimmed.count <= 4
            if hasSeparators || isCJKLabel || value.count <= 20 {
                return true
            }
        }
        return false
    }
}
