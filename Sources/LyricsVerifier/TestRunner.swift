/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 LyricsFetcher (public API)
 * [OUTPUT]: 导出 VerifyResult, SourceResult, testSong(), 输出工具
 * [POS]: LyricsVerifier 的测试编排核心
 */

import Foundation
import MusicMiniPlayerCore
import CryptoKit

// =========================================================================
// MARK: - 结果模型（Codable → JSONL 输出）
// =========================================================================

struct VerifyResult: Codable {
    let id: String
    let title: String
    let artist: String
    let duration: Int
    let passed: Bool
    let selectedSource: String?
    let selectedScore: Double?
    let lyricsLineCount: Int
    let hasTranslation: Bool
    let hasSyllableSync: Bool
    let firstRealLine: String?
    let firstRealLineSHA256: String?
    let elapsedMs: Int
    let failures: [String]
    let warnings: [String]   // 内容验证警告（疑似错配、语言不一致等）
    let allSources: [SourceResult]
    /// Gamma-schema fields: classification straight from the same
    /// LyricsClassifier helper the live app uses. Never re-guessed here.
    let classification: String?  // "synced" | "unsynced" | "instrumental" | "unavailable" | "none"
    let realLineCount: Int
    let translationCount: Int
    let firstRealLineTimeS: Double?
    let lastLineTimeS: Double?
}

struct SourceResult: Codable {
    let name: String
    let found: Bool
    let score: Double
    let lines: Int
}

// =========================================================================
// MARK: - 核心测试函数
// =========================================================================

/// Core test: fetch lyrics and return both result and raw lyrics
func testSongWithLyrics(
    id: String,
    title: String,
    artist: String,
    duration: TimeInterval,
    expectation: TestExpectation?,
    translationEnabled: Bool = false,
    album: String = "",
    enforceExpectationIdentityOracle: Bool = true
) async -> (result: VerifyResult, lyrics: [LyricLine]) {
    let fetcher = LyricsFetcher.shared
    let start = CFAbsoluteTimeGetCurrent()

    var fetchResults = await fetcher.fetchAllSources(
        title: title, artist: artist,
        duration: duration, translationEnabled: translationEnabled,
        album: album
    )

    var selectedResult = fetcher.selectBestResult(from: fetchResults, songDuration: duration)
    let foregroundElapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    var backfillElapsedMs: Int? = nil
    let foregroundTerminalResult: LyricsFetcher.LyricsFetchResult?
    if selectedResult == nil {
        foregroundTerminalResult = fetcher.selectInstrumentalResult(from: fetchResults)
            ?? fetcher.selectUnavailableResult(from: fetchResults)
    } else {
        foregroundTerminalResult = nil
    }
    if (selectedResult == nil || selectedResult?.kind == .unsynced),
       foregroundTerminalResult == nil,
       expectation?.shouldFindLyrics != false {
        if let backfill = await fetcher.backfillAuthoritativeLyrics(
            title: title,
            artist: artist,
            duration: duration,
            translationEnabled: translationEnabled,
            album: album
        ) {
            backfillElapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000) - foregroundElapsedMs
            switch backfill {
            case .lyrics(let backfilled):
                fetchResults.append(backfilled)
                let upgraded = fetcher.selectBestResult(from: fetchResults, songDuration: duration)
                if selectedResult == nil || upgraded?.kind == .synced {
                    selectedResult = upgraded
                }
            case .instrumental(let instrumental):
                fetchResults.append(instrumental)
            case .unavailable(let unavailable):
                fetchResults.append(unavailable)
            }
        } else {
            backfillElapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000) - foregroundElapsedMs
        }
    }
    let instrumentalResult = selectedResult == nil
        ? (foregroundTerminalResult?.kind == .instrumental ? foregroundTerminalResult : fetcher.selectInstrumentalResult(from: fetchResults))
        : nil
    let unavailableResult = selectedResult == nil && instrumentalResult == nil
        ? (foregroundTerminalResult?.kind == .unavailable ? foregroundTerminalResult : fetcher.selectUnavailableResult(from: fetchResults))
        : nil
    let reportResult = selectedResult ?? instrumentalResult ?? unavailableResult
    let bestLyrics = selectedResult?.lyrics

    // Shared classifier — same call both the app and the verifier use.
    let classificationKind = LyricsFetcher.LyricsClassifier.classify(result: reportResult)
    let classificationString: String
    switch classificationKind {
    case .some(.synced):       classificationString = "synced"
    case .some(.unsynced):     classificationString = "unsynced"
    case .some(.instrumental): classificationString = "instrumental"
    case .some(.unavailable):  classificationString = "unavailable"
    case .none:                classificationString = "none"
    }

    let elapsed = foregroundElapsedMs
    let knownSources = ["AppleMusic", "AMLL", "NetEase", "QQ", "LRCLIB", "LRCLIB-Search", "lyrics.ovh", "Genius"]
    var firstResultBySource: [String: LyricsFetcher.LyricsFetchResult] = [:]
    for result in fetchResults where firstResultBySource[result.source] == nil {
        firstResultBySource[result.source] = result
    }
    let allSources: [SourceResult] = knownSources.map { name in
        if let r = firstResultBySource[name] {
            return SourceResult(name: name, found: true, score: round(r.score * 10) / 10, lines: r.lyrics.count)
        }
        return SourceResult(name: name, found: false, score: 0, lines: 0)
    }

    let rawLyrics = bestLyrics ?? []
    // Rescale + processLyrics (mirrors LyricsService behavior)
    let rescaled = fetcher.rescaleTimestamps(rawLyrics, duration: duration)
    let processed = LyricsParser.shared.processLyrics(rescaled)
    let lyrics = processed.lyrics
    let lyricStats = collectLyricStats(lyrics, firstRealIndex: processed.firstRealLyricIndex)
    let firstReal = lyricStats.firstReal

    var failures: [String] = []
    if let exp = expectation {
        failures = checkExpectation(
            exp, source: selectedResult?.source,
            lyrics: lyrics, firstReal: firstReal,
            classification: classificationString,
            duration: duration
        )
    }

    failures.append(contentsOf: validateLiveLyricsContract(
        expectation: expectation,
        lyrics: lyrics,
        classification: classificationString,
        elapsedMs: elapsed,
        duration: duration,
        selectedResult: selectedResult,
        allResults: fetchResults,
        enforceExpectationIdentityOracle: enforceExpectationIdentityOracle
    ))

    // Validate on raw lyrics to detect overshoot before rescaling
    let contentValidation = validateContent(
        title: title, artist: artist,
        source: selectedResult?.source,
        score: selectedResult?.score,
        lyrics: rawLyrics,
        duration: duration,
        allResults: fetchResults
    )
    failures.append(contentsOf: contentValidation.failures)
    var warnings = contentValidation.warnings
    if let backfillElapsedMs, backfillElapsedMs > 3000 {
        warnings.append("⚠️ 后台权威回填耗时 \(backfillElapsedMs)ms；不计入前台交互预算")
    }
    if lyrics.isEmpty && classificationString == "unavailable" {
        warnings.append("⚠️ 来源目录已匹配，但来源未返回歌词正文；不会标记为无歌词")
    } else if lyrics.isEmpty && classificationString == "none" {
        warnings.append("⚠️ 未解析到可信来源；保持未解析状态，不标记为无歌词")
    }
    failures.append(contentsOf: validateCrossSourceIdentity(
        selected: selectedResult,
        allResults: fetchResults
    ))

    let result = VerifyResult(
        id: id, title: title, artist: artist,
        duration: Int(duration), passed: failures.isEmpty,
        selectedSource: reportResult?.source,
        selectedScore: reportResult?.score,
        lyricsLineCount: lyrics.count,
        hasTranslation: lyricStats.hasTranslation,
        hasSyllableSync: lyricStats.hasSyllableSync,
        firstRealLine: firstReal?.text,
        firstRealLineSHA256: firstReal.map { normalizedFirstLineSHA256($0.text) },
        elapsedMs: elapsed,
        failures: failures,
        warnings: warnings,
        allSources: allSources,
        classification: classificationString,
        realLineCount: lyricStats.realLines.count,
        translationCount: lyricStats.translationCount,
        firstRealLineTimeS: firstReal?.startTime,
        lastLineTimeS: lyrics.last?.startTime
    )

    return (result, lyrics)
}

private struct ProcessedLyricStats {
    let realLines: [LyricLine]
    let firstReal: LyricLine?
    let translationCount: Int
    let hasTranslation: Bool
    let hasSyllableSync: Bool
}

private func collectLyricStats(_ lyrics: [LyricLine], firstRealIndex: Int) -> ProcessedLyricStats {
    let firstRealStart = max(0, min(firstRealIndex, lyrics.count))
    var realLines: [LyricLine] = []
    var firstReal: LyricLine?
    var translationCount = 0
    var hasTranslation = false
    var hasSyllableSync = false

    for (index, line) in lyrics.enumerated() {
        if line.hasTranslation {
            hasTranslation = true
            translationCount += 1
        }
        if line.hasSyllableSync {
            hasSyllableSync = true
        }
        if isRealLyricText(line.text) {
            realLines.append(line)
            if index >= firstRealStart && firstReal == nil {
                firstReal = line
            }
        }
    }

    return ProcessedLyricStats(
        realLines: realLines,
        firstReal: firstReal,
        translationCount: translationCount,
        hasTranslation: hasTranslation,
        hasSyllableSync: hasSyllableSync
    )
}

private func isRealLyricText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != "..." && trimmed != "…" && trimmed != "⋯"
}

/// Convenience wrapper when caller doesn't need raw lyrics
func testSong(
    id: String,
    title: String,
    artist: String,
    duration: TimeInterval,
    expectation: TestExpectation?,
    translationEnabled: Bool = false,
    album: String = "",
    enforceExpectationIdentityOracle: Bool = true
) async -> VerifyResult {
    await testSongWithLyrics(
        id: id, title: title, artist: artist,
        duration: duration, expectation: expectation,
        translationEnabled: translationEnabled,
        album: album,
        enforceExpectationIdentityOracle: enforceExpectationIdentityOracle
    ).result
}

// =========================================================================
// MARK: - Expectation Validation
// =========================================================================

private func checkExpectation(
    _ exp: TestExpectation,
    source: String?,
    lyrics: [LyricLine],
    firstReal: LyricLine?,
    classification: String,
    duration: TimeInterval
) -> [String] {
    var failures: [String] = []

    if exp.shouldFindLyrics {
        guard !lyrics.isEmpty else {
            if exp.allowMissingLyrics == true,
               classification == "none" || classification == "unavailable" {
                return failures
            }
            failures.append("期望找到歌词，但所有源均无结果")
            return failures
        }
        if let acceptable = exp.acceptableSources, let src = source,
           src != "AppleMusic",
           !acceptable.contains(src) {
            failures.append("源 \(src) 不在可接受列表 \(acceptable) 中")
        }
        if let keyword = exp.firstLineContains {
            guard let line = firstReal else {
                failures.append("没有可验证的首行，无法匹配 \"\(keyword)\"")
                return failures
            }
            let normalizedLine = LanguageUtils.toSimplifiedChinese(line.text)
                .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            let normalizedKeyword = LanguageUtils.toSimplifiedChinese(keyword)
                .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            if !line.text.contains(keyword) && !normalizedLine.contains(normalizedKeyword) {
                failures.append("首行 \"\(line.text)\" 不包含 \"\(keyword)\"")
            }
        }
        let expectedHashes = ([exp.firstLineSHA256].compactMap { $0 } + (exp.acceptableFirstLineSHA256 ?? []))
        if !expectedHashes.isEmpty {
            guard let line = firstReal else {
                failures.append("没有可验证的首行，无法匹配首行哈希")
                return failures
            }
            let actualHash = normalizedFirstLineSHA256(line.text)
            let normalizedExpected = expectedHashes.map { $0.lowercased() }
            if !normalizedExpected.contains(actualHash) {
                let preview = normalizedExpected.map { String($0.prefix(12)) }.joined(separator: " or ")
                failures.append("首行哈希不匹配: \(actualHash.prefix(12)) != \(preview)")
            }
        }
        if let expected = exp.expectedClassification,
           classification != expected {
            failures.append("分类 \(classification) != 期望 \(expected)")
        }
        if exp.requiresSyllableSync == true,
           !lyrics.contains(where: { $0.hasSyllableSync }) {
            failures.append("期望逐字/逐音节歌词，但选中结果没有 word-level timing")
        }
        if let minRealLineCount = exp.minRealLineCount {
            let realLineCount = lyrics.filter { isRealLyricText($0.text) }.count
            if realLineCount < minRealLineCount {
                failures.append("有效歌词行数 \(realLineCount) 少于期望下限 \(minRealLineCount)")
            }
        }
        if exp.firstLineStartMinS != nil || exp.firstLineStartMaxS != nil {
            guard let line = firstReal else {
                failures.append("没有可验证的首行时间")
                return failures
            }
            if let minStart = exp.firstLineStartMinS,
               line.startTime < minStart {
                failures.append("首行时间 \(String(format: "%.1f", line.startTime))s 早于期望下限 \(String(format: "%.1f", minStart))s")
            }
            if let maxStart = exp.firstLineStartMaxS,
               line.startTime > maxStart {
                failures.append("首行时间 \(String(format: "%.1f", line.startTime))s 晚于期望上限 \(String(format: "%.1f", maxStart))s")
            }
        }
        if let maxTailGap = exp.maxTailGapS,
           classification == "synced",
           let last = lyrics.last {
            let tailGap = duration - last.startTime
            if tailGap > maxTailGap {
                failures.append("尾部时间缺口 \(String(format: "%.1f", tailGap))s 超过 \(String(format: "%.1f", maxTailGap))s")
            }
        }
    } else {
        if !lyrics.isEmpty {
            failures.append("期望无歌词，但找到了 \(source ?? "unknown")")
        }
    }

    return failures
}

private func validateLiveLyricsContract(
    expectation: TestExpectation?,
    lyrics: [LyricLine],
    classification: String,
    elapsedMs: Int,
    duration: TimeInterval,
    selectedResult: LyricsFetcher.LyricsFetchResult?,
    allResults: [LyricsFetcher.LyricsFetchResult],
    enforceExpectationIdentityOracle: Bool
) -> [String] {
    var failures: [String] = []

    if elapsedMs > 3000 {
        failures.append("耗时 \(elapsedMs)ms 超过 3000ms 交互预算")
    }

    guard !lyrics.isEmpty else {
        if expectation?.shouldFindLyrics == true,
           expectation?.allowMissingLyrics == true,
           classification == "none" || classification == "unavailable" {
            return failures
        }
        if (classification == "instrumental" || classification == "unavailable"),
           expectation?.shouldFindLyrics != true {
            return failures
        }
        if expectation?.shouldFindLyrics == true {
            let candidates = allResults
                .filter { !$0.lyrics.isEmpty }
                .sorted { $0.score > $1.score }
                .prefix(3)
                .map { "\($0.source):\(String(format: "%.1f", $0.score))/\($0.lyrics.count)L" }
                .joined(separator: ", ")
            if candidates.isEmpty {
                failures.append("没有返回同步歌词，不能视为通过")
            } else {
                failures.append("候选源存在但没有可信同步歌词（\(candidates)）")
            }
        }
        return failures
    }

    if classification != "synced" && classification != "unsynced" {
        failures.append("选中 \(classification) 歌词；产品只允许同步/可信静态歌词")
    }

    let realLines = lyrics.filter { isRealLyricText($0.text) }
    if realLines.count < 5 {
        failures.append("有效歌词行数不足 5 行")
    }

    if let selected = selectedResult,
       !selected.lyrics.contains(where: { $0.hasSyllableSync }),
       selected.score < 30,
       !hasIndependentLyricAgreement(for: selected, allResults: allResults),
       !hasStrongCatalogIdentity(selected, realLineCount: realLines.count),
       !hasTrustedStaticFallback(selected, realLineCount: realLines.count) {
        failures.append("非 word-level 同步歌词置信度 \(String(format: "%.1f", selected.score)) 分低于 30")
    }

    if let expectation,
       expectation.shouldFindLyrics,
       enforceExpectationIdentityOracle,
       expectation.firstLineContains == nil,
       expectation.firstLineSHA256 == nil,
       expectation.acceptableFirstLineSHA256?.isEmpty != false,
       let selected = selectedResult,
       !hasIndependentLyricAgreement(for: selected, allResults: allResults) {
        failures.append("用例缺少首行关键词/哈希，且没有跨源一致性证据；不能证明是正确歌曲")
    }

    let inlineTimestampPattern = #"<\d{1,2}:\d{2}(?:\.\d{1,3})?>"#
    if realLines.contains(where: { $0.text.range(of: inlineTimestampPattern, options: .regularExpression) != nil }) {
        failures.append("可见歌词包含未解析的行内时间戳")
    }

    failures.append(contentsOf: validateTimelineSanity(lines: realLines, duration: duration))

    return failures
}

// =========================================================================
// MARK: - 内容验证（自动检测疑似问题）
// =========================================================================

/// Four-layer content validation:
/// 1. Title mismatch: first line contains wrong song name
/// 2. Language consistency: lyrics language vs song language
/// 3. Low-quality source flag: lyrics.ovh single source + low score
/// 4. Timestamp overshoot: lyrics extend past song duration (wrong version)
private struct ContentValidation {
    var failures: [String] = []
    var warnings: [String] = []
}

private func validateContent(
    title: String, artist: String,
    source: String?, score: Double?,
    lyrics: [LyricLine],
    duration: TimeInterval = 0,
    allResults: [LyricsFetcher.LyricsFetchResult] = []
) -> ContentValidation {
    guard !lyrics.isEmpty, let source = source else { return ContentValidation() }
    var validation = ContentValidation()

    let validLines = lyrics.filter { isRealLyricText($0.text) }
    guard !validLines.isEmpty else { return validation }

    // ── 1. 首行错配检测 ──
    // 很多源的首行格式是 "歌名 - 艺术家"，如果歌名不匹配就是错配
    if let firstLine = validLines.first?.text {
        // Treat only spaced dashes as metadata separators. Hyphenated lyric
        // words such as "Dites-moi" or repeated syllables like "uh-uh" are
        // normal content and must not become title-card failures.
        if let separator = firstLine.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            let candidateTitle = String(firstLine[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let lyricsTitle = candidateTitle.lowercased()
            let inputTitle = title.lowercased()
                .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            // 跨语言翻译标题：一个纯 ASCII 一个含 CJK，且来自可信源高分命中 → 跳过
            let inputIsASCII = inputTitle.allSatisfy { $0.isASCII }
            let lyricsTitleHasCJK = lyricsTitle.unicodeScalars.contains {
                (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
            }
            let isCrossLanguage = inputIsASCII && lyricsTitleHasCJK
            let isReliableSource = ["NetEase", "QQ", "AMLL"].contains(source) && (score ?? 0) >= 50

            // 🔑 规范化斜杠空格后再比较：" / " → "/"
            let normalizedLyricsTitle = lyricsTitle.replacingOccurrences(of: " / ", with: "/")
            let normalizedInputTitle = inputTitle.replacingOccurrences(of: " / ", with: "/")

            // 首行标题和输入标题完全不搭（跨语言翻译+可信源除外）
            if !normalizedLyricsTitle.contains(normalizedInputTitle) && !normalizedInputTitle.contains(normalizedLyricsTitle) && lyricsTitle.count > 3 {
                if !(isCrossLanguage && isReliableSource) {
                    validation.failures.append("首行标题不匹配: 歌词=\"\(candidateTitle)\" vs 输入=\"\(title)\"")
                }
            }
        }
    }

    // ── 2. 语言一致性检测 ──
    // 歌词全是拼音（纯 ASCII 但不像英文）= 可能是 lyrics.ovh 的垃圾
    let asciiOnlyLines = validLines.filter { $0.text.allSatisfy { $0.isASCII } }
    let hasCJKTitle = title.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            || title.unicodeScalars.contains { $0.value >= 0x3040 && $0.value <= 0x30FF }
    if hasCJKTitle && asciiOnlyLines.count == validLines.count && source == "lyrics.ovh" {
        validation.warnings.append("⚠️ CJK标题但歌词全是ASCII（可能是拼音垃圾）")
    }

    // 古典/器乐曲不应该有歌词
    let instrumentalKeywords = ["waltz", "sonata", "concerto", "symphony", "étude", "nocturne", "prelude", "fugue"]
    if instrumentalKeywords.contains(where: { title.lowercased().contains($0) }) {
        validation.warnings.append("⚠️ 器乐曲标题但有歌词（可能是错配）")
    }

    // ── 3. 低质量源标记 ──
    let sourceTokens = lyricIdentityTokens(lyrics)
    let hasIndependentLyricAgreement = allResults.contains { result in
        guard areIndependentLyricSources(source, result.source), result.score > 0 else { return false }
        let witnessTokens = lyricIdentityTokens(result.lyrics)
        return witnessTokens.count >= 6 && lyricSimilarity(sourceTokens, witnessTokens) >= 0.34
    }
    if source == "lyrics.ovh" && (score ?? 0) < 55 && !hasIndependentLyricAgreement {
        validation.warnings.append("⚠️ 仅 lyrics.ovh 低分命中（高错配风险）")
    }

    // ── 4. Timestamp overshoot detection ──
    // Lyrics extend past song duration = wrong version selected
    if duration > 0, validLines.count >= 2,
       let last = validLines.last, last.startTime > duration {
        let overshoot = last.startTime - duration
        let message = "时间轴溢出: 末行 \(String(format: "%.1f", last.startTime))s > 歌曲 \(Int(duration))s (溢出\(String(format: "+%.1f", overshoot))s, 版本不匹配)"
        let boundedAlternateMaster = allResults.contains { result in
            result.source == source &&
            abs(result.score - (score ?? -1)) < 0.05 &&
            result.titleMatched &&
            result.score >= 65 &&
            (result.matchedDurationDiff ?? .greatestFiniteMagnitude) >= 2.0 &&
            (result.matchedDurationDiff ?? .greatestFiniteMagnitude) < 35.0 &&
            overshoot <= (result.matchedDurationDiff ?? 0) + 5.0
        }
        if boundedAlternateMaster {
            validation.warnings.append("⚠️ \(message)；已按高置信同曲异版重缩放")
        } else if overshoot > max(2.0, duration * 0.01) {
            validation.failures.append(message)
        } else {
            validation.warnings.append("⚠️ \(message)")
        }
    }

    let inlineTimestampPattern = #"<\d{1,2}:\d{2}(?:[:.]\d{1,3})?>"#
    if validLines.contains(where: { $0.text.range(of: inlineTimestampPattern, options: .regularExpression) != nil }) {
        validation.failures.append("歌词文本含未解析内联时间戳")
    }

    return validation
}

private func validateTimelineSanity(lines: [LyricLine], duration: TimeInterval) -> [String] {
    guard duration > 0, lines.count >= 3 else { return [] }
    var failures: [String] = []

    if let negative = lines.first(where: { $0.startTime < -0.05 }) {
        failures.append("负时间戳: \(String(format: "%.2f", negative.startTime))s")
    }

    var outOfOrderCount = 0
    for pair in zip(lines, lines.dropFirst()) where pair.1.startTime + 0.05 < pair.0.startTime {
        outOfOrderCount += 1
    }
    if outOfOrderCount > 0 {
        failures.append("时间轴乱序: \(outOfOrderCount) 处")
    }

    let firstStart = lines[0].startTime
    let firstStartLimit = min(90.0, max(45.0, duration * 0.30))
    if firstStart > firstStartLimit {
        let realLines = lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }
        let lastStart = lines.last?.startTime ?? 0
        let tailGap = duration - lastStart
        let maxGap = zip(lines, lines.dropFirst()).map { $1.startTime - $0.startTime }.max() ?? 0
        let longIntroLimit = min(115.0, max(firstStartLimit, duration * 0.34))
        let boundedLongIntro = duration >= 300
            && firstStart <= longIntroLimit
            && realLines.count >= 12
            && tailGap <= max(65.0, duration * 0.20)
            && maxGap <= max(55.0, duration * 0.16)
        if !boundedLongIntro {
            failures.append("首行时间过晚: \(String(format: "%.1f", firstStart))s > \(String(format: "%.1f", firstStartLimit))s")
        }
    }

    let lastStart = lines.last?.startTime ?? 0
    if lastStart > duration + max(2.0, duration * 0.01) {
        failures.append("时间轴溢出: 末行 \(String(format: "%.1f", lastStart))s > 歌曲 \(Int(duration))s")
    }

    return failures
}

private func normalizedFirstLineSHA256(_ line: String) -> String {
    let normalized = LanguageUtils.toSimplifiedChinese(line)
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let digest = SHA256.hash(data: Data(normalized.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Cross-source identity oracle:
/// If the selected synced result disagrees with an independent consensus
/// cluster, the verifier must fail even when the selected result has good
/// timestamps. This catches "right catalog row, wrong attached lyric" and
/// "same artist + same duration + wrong title" cases without song-specific
/// allowlists.
private func validateCrossSourceIdentity(
    selected: LyricsFetcher.LyricsFetchResult?,
    allResults: [LyricsFetcher.LyricsFetchResult]
) -> [String] {
    guard let selected, !selected.lyrics.isEmpty else { return [] }

    let candidates = uniqueSourceResults(allResults).compactMap { result -> LyricIdentityCandidate? in
        let tokens = lyricIdentityTokens(result.lyrics)
        guard result.score > 0, !result.lyrics.isEmpty, tokens.count >= 6 else { return nil }
        return LyricIdentityCandidate(result: result, tokens: tokens)
    }
    guard candidates.count >= 3 else { return [] }

    let threshold = 0.34
    let clusters: [[LyricIdentityCandidate]] = candidates.map { anchor in
        candidates.filter { lyricSimilarity(anchor.tokens, $0.tokens) >= threshold }
    }
    guard let bestCluster = clusters.max(by: { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        let lhsSynced = lhs.filter { $0.result.kind == .synced }.count
        let rhsSynced = rhs.filter { $0.result.kind == .synced }.count
        return lhsSynced < rhsSynced
    }) else { return [] }

    guard bestCluster.count >= 2 else { return [] }
    guard !bestCluster.contains(where: { $0.result.source == selected.source }) else { return [] }
    let clusterHasSynced = bestCluster.contains { $0.result.kind == .synced }
    let clusterHasStrongSynced = bestCluster.contains { candidate in
        let result = candidate.result
        return result.kind == .synced
            && (result.score >= 65 || hasWordLevelSync(result))
            && (result.albumMatched || (result.matchedDurationDiff ?? .greatestFiniteMagnitude) < 1.0 || result.titleMatched)
    }
    if selected.kind == .synced,
       selected.score >= 70,
       (selected.albumMatched || (selected.matchedDurationDiff ?? .greatestFiniteMagnitude) < 1.0),
       (selected.titleMatched || hasWordLevelSync(selected)),
       !clusterHasStrongSynced {
        return []
    }
    if !clusterHasSynced,
       selected.kind == .synced,
       (selected.score >= 75 || hasWordLevelSync(selected)) {
        return []
    }

    let selectedTokens = lyricIdentityTokens(selected.lyrics)
    let selectedSimilarity = bestCluster
        .map { lyricSimilarity(selectedTokens, $0.tokens) }
        .max() ?? 0
    guard selectedSimilarity < 0.18 else { return [] }

    let supporters = bestCluster.map { $0.result.source }.sorted().joined(separator: ",")
    return ["跨源歌词内容冲突: selected=\(selected.source), consensus=\(supporters)"]
}

private func hasIndependentLyricAgreement(
    for selected: LyricsFetcher.LyricsFetchResult,
    allResults: [LyricsFetcher.LyricsFetchResult]
) -> Bool {
    let selectedTokens = lyricIdentityTokens(selected.lyrics)
    guard selected.kind == .synced,
          selected.titleMatched,
          (selected.matchedDurationDiff ?? .greatestFiniteMagnitude) < 1.0,
          selectedTokens.count >= 6 else { return false }

    return uniqueSourceResults(allResults).contains { witness in
        guard areIndependentLyricSources(selected.source, witness.source),
              witness.score > 0,
              !witness.lyrics.isEmpty else { return false }
        let witnessTokens = lyricIdentityTokens(witness.lyrics)
        return witnessTokens.count >= 6 && lyricSimilarity(selectedTokens, witnessTokens) >= 0.24
    }
}

private func areIndependentLyricSources(_ lhs: String, _ rhs: String) -> Bool {
    guard lhs != rhs else { return false }
    let mirroredLibrarySources: Set<String> = ["LRCLIB", "LRCLIB-Search"]
    if mirroredLibrarySources.contains(lhs), mirroredLibrarySources.contains(rhs) {
        return false
    }
    return true
}

private func hasStrongCatalogIdentity(
    _ selected: LyricsFetcher.LyricsFetchResult,
    realLineCount: Int
) -> Bool {
    guard selected.kind == .synced,
          selected.titleMatched,
          realLineCount >= 8 else { return false }
    if selected.albumMatched { return true }
    if let durationDiff = selected.matchedDurationDiff, durationDiff < 2.0 {
        return true
    }
    return false
}

private func hasTrustedStaticFallback(
    _ selected: LyricsFetcher.LyricsFetchResult,
    realLineCount: Int
) -> Bool {
    selected.kind == .unsynced &&
    ((selected.source == "lyrics.ovh" && selected.score >= 24 && realLineCount >= 16) ||
     (selected.source == "Genius" && selected.score >= 24 && realLineCount >= 12))
}

private func hasWordLevelSync(_ result: LyricsFetcher.LyricsFetchResult) -> Bool {
    guard !result.lyrics.isEmpty else { return false }
    let syllableCount = result.lyrics.filter { $0.hasSyllableSync }.count
    return Double(syllableCount) / Double(result.lyrics.count) >= 0.3
}

private func uniqueSourceResults(_ results: [LyricsFetcher.LyricsFetchResult]) -> [LyricsFetcher.LyricsFetchResult] {
    var bestBySource: [String: LyricsFetcher.LyricsFetchResult] = [:]
    for result in results {
        if let existing = bestBySource[result.source], existing.score >= result.score { continue }
        bestBySource[result.source] = result
    }
    return Array(bestBySource.values)
}

private struct LyricIdentityCandidate {
    let result: LyricsFetcher.LyricsFetchResult
    let tokens: Set<String>
}

private func lyricSimilarity(_ lhs: [LyricLine], _ rhs: [LyricLine]) -> Double {
    lyricSimilarity(lyricIdentityTokens(lhs), lyricIdentityTokens(rhs))
}

private func lyricSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
    guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
    let intersection = lhs.intersection(rhs).count
    return Double(intersection) / Double(min(lhs.count, rhs.count))
}

private func lyricIdentityTokens(_ lyrics: [LyricLine]) -> Set<String> {
    let lines = lyrics.filter { isRealLyricText($0.text) }.prefix(24)
    let raw = lines.map(\.text).joined(separator: " ")
    let folded = LanguageUtils.toSimplifiedChinese(raw)
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()

    var words: [String] = []
    var current = ""
    for scalar in folded.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            current.append(Character(scalar))
        } else {
            if current.count >= 2 { words.append(current) }
            current = ""
        }
    }
    if current.count >= 2 { words.append(current) }

    if words.count >= 8 {
        var tokens = Set<String>()
        for i in 0..<(words.count - 1) {
            tokens.insert(words[i] + " " + words[i + 1])
        }
        return tokens
    }

    let compact = folded.unicodeScalars.filter { scalar in
        !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.punctuationCharacters.contains(scalar)
            && !CharacterSet.symbols.contains(scalar)
    }.map(String.init).joined()
    let chars = Array(compact)
    guard chars.count >= 4 else { return Set(words) }
    var tokens = Set<String>()
    for i in 0..<(chars.count - 1) {
        tokens.insert(String(chars[i...i + 1]))
    }
    return tokens
}

// =========================================================================
// MARK: - 人类可读输出（stderr）
// =========================================================================

/// 写到 stderr，不污染 JSON stdout
func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func printResultLine(_ r: VerifyResult) {
    let icon = r.passed ? "[+]" : "[x]"
    let status = r.passed ? "PASS" : "FAIL"

    var line = "\(icon) \(r.id) \(status) \"\(r.title)\" - \(r.artist)"
    if r.classification == "instrumental" {
        let src = r.selectedSource ?? "provider"
        line += "  ->  INSTRUMENTAL (\(src))"
    } else if r.classification == "unavailable" {
        let src = r.selectedSource ?? "provider"
        line += "  ->  LYRICS UNAVAILABLE (\(src))"
    } else if let src = r.selectedSource, let score = r.selectedScore {
        line += "  ->  \(src) (\(String(format: "%.0f", score))pts, \(r.lyricsLineCount)L)"
    } else {
        line += "  ->  UNRESOLVED"
    }
    line += "  [\(r.elapsedMs)ms]"
    if r.hasSyllableSync { line += " [syllable]" }
    if r.hasTranslation { line += " [trans]" }
    log(line)

    for f in r.failures { log("      ! \(f)") }
    for w in r.warnings { log("      \(w)") }

    // 打印有结果的源
    let found = r.allSources.filter { $0.found }.sorted { $0.score > $1.score }
    if !found.isEmpty {
        let detail = found.map { "\($0.name):\(String(format: "%.0f", $0.score))/\($0.lines)L" }.joined(separator: "  ")
        log("      sources: \(detail)")
    }
}

func printBatchSummary(_ results: [VerifyResult]) {
    var passed = 0
    var warned = 0
    var unresolved = 0
    var unavailable = 0
    var instrumental = 0
    var totalMs = 0

    for result in results {
        if result.passed { passed += 1 }
        if !result.warnings.isEmpty { warned += 1 }
        if result.lyricsLineCount == 0 && result.classification == "none" { unresolved += 1 }
        if result.classification == "unavailable" { unavailable += 1 }
        if result.classification == "instrumental" { instrumental += 1 }
        totalMs += result.elapsedMs
    }

    let avg = results.isEmpty ? 0 : totalMs / results.count

    log("""

    ========================================
      \(passed)/\(results.count) passed   \(warned) warnings   \(unresolved) unresolved   \(unavailable) unavailable   \(instrumental) instrumental
      total \(totalMs)ms   avg \(avg)ms
    ========================================
    """)
}
