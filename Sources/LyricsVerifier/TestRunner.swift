/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 LyricsFetcher (public API)
 * [OUTPUT]: 导出 VerifyResult, SourceResult, testSong(), 输出工具
 * [POS]: LyricsVerifier 的测试编排核心
 */

import Foundation
import MusicMiniPlayerCore

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
    let elapsedMs: Int
    let failures: [String]
    let warnings: [String]   // 内容验证警告（疑似错配、语言不一致等）
    let allSources: [SourceResult]
    /// Gamma-schema fields: classification straight from the same
    /// LyricsClassifier helper the live app uses. Never re-guessed here.
    let classification: String?  // "synced" | "unsynced" | "none"
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
    album: String = ""
) async -> (result: VerifyResult, lyrics: [LyricLine]) {
    let start = CFAbsoluteTimeGetCurrent()
    let fetcher = LyricsFetcher.shared

    let fetchResults = await fetcher.fetchAllSources(
        title: title, artist: artist,
        duration: duration, translationEnabled: translationEnabled,
        album: album
    )

    let bestLyrics = fetcher.selectBest(from: fetchResults, songDuration: duration)
    let selectedResult = fetchResults.first { result in
        guard let firstBest = bestLyrics?.first,
              let firstResult = result.lyrics.first else { return false }
        return firstBest.id == firstResult.id
    }

    // Shared classifier — same call both the app and the verifier use.
    let classificationKind = LyricsFetcher.LyricsClassifier.classify(result: selectedResult)
    let classificationString: String
    switch classificationKind {
    case .some(.synced):   classificationString = "synced"
    case .some(.unsynced): classificationString = "unsynced"
    case .none:            classificationString = "none"
    }

    let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    let knownSources = ["AppleMusic", "AMLL", "NetEase", "QQ", "LRCLIB", "LRCLIB-Search", "lyrics.ovh", "Genius"]
    let allSources: [SourceResult] = knownSources.map { name in
        if let r = fetchResults.first(where: { $0.source == name }) {
            return SourceResult(name: name, found: true, score: round(r.score * 10) / 10, lines: r.lyrics.count)
        }
        return SourceResult(name: name, found: false, score: 0, lines: 0)
    }

    let rawLyrics = bestLyrics ?? []
    // Rescale + processLyrics (mirrors LyricsService behavior)
    let rescaled = fetcher.rescaleTimestamps(rawLyrics, duration: duration)
    let processed = LyricsParser.shared.processLyrics(rescaled)
    let lyrics = processed.lyrics
    let firstReal = lyrics.dropFirst(processed.firstRealLyricIndex).first {
        let t = $0.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != "..." && t != "…" && t != "⋯"
    }

    var failures: [String] = []
    if let exp = expectation {
        failures = checkExpectation(
            exp, source: selectedResult?.source,
            lyrics: lyrics, firstReal: firstReal
        )
    }

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
    let warnings = contentValidation.warnings
    failures.append(contentsOf: validateCrossSourceIdentity(
        selected: selectedResult,
        allResults: fetchResults
    ))

    // Gamma-schema fields
    let realLines = lyrics.filter {
        let t = $0.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != "..." && t != "…" && t != "⋯"
    }
    let translationCount = lyrics.filter { $0.hasTranslation }.count

    let result = VerifyResult(
        id: id, title: title, artist: artist,
        duration: Int(duration), passed: failures.isEmpty,
        selectedSource: selectedResult?.source,
        selectedScore: selectedResult?.score,
        lyricsLineCount: lyrics.count,
        hasTranslation: lyrics.contains { $0.hasTranslation },
        hasSyllableSync: lyrics.contains { $0.hasSyllableSync },
        firstRealLine: firstReal?.text,
        elapsedMs: elapsed,
        failures: failures,
        warnings: warnings,
        allSources: allSources,
        classification: classificationString,
        realLineCount: realLines.count,
        translationCount: translationCount,
        firstRealLineTimeS: firstReal?.startTime,
        lastLineTimeS: lyrics.last?.startTime
    )

    return (result, lyrics)
}

/// Convenience wrapper when caller doesn't need raw lyrics
func testSong(
    id: String,
    title: String,
    artist: String,
    duration: TimeInterval,
    expectation: TestExpectation?,
    translationEnabled: Bool = false,
    album: String = ""
) async -> VerifyResult {
    await testSongWithLyrics(
        id: id, title: title, artist: artist,
        duration: duration, expectation: expectation,
        translationEnabled: translationEnabled,
        album: album
    ).result
}

// =========================================================================
// MARK: - 期望值校验
// =========================================================================

private func checkExpectation(
    _ exp: TestExpectation,
    source: String?,
    lyrics: [LyricLine],
    firstReal: LyricLine?
) -> [String] {
    var failures: [String] = []

    if exp.shouldFindLyrics {
        guard !lyrics.isEmpty else {
            if exp.allowMissingLyrics == true {
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
        if let keyword = exp.firstLineContains, let line = firstReal,
           !line.text.contains(keyword) {
            failures.append("首行 \"\(line.text)\" 不包含 \"\(keyword)\"")
        }
    } else {
        if !lyrics.isEmpty {
            failures.append("期望无歌词，但找到了 \(source ?? "unknown")")
        }
    }

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

    let validLines = lyrics.filter {
        let t = $0.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != "..." && t != "…" && t != "⋯"
    }
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
    let hasIndependentLyricAgreement = allResults.contains { result in
        result.source != source &&
        result.score > 0 &&
        lyricIdentityTokens(result.lyrics).count >= 6 &&
        lyricSimilarity(lyrics, result.lyrics) >= 0.34
    }
    if source == "lyrics.ovh" && (score ?? 0) < 55 && !hasIndependentLyricAgreement {
        validation.warnings.append("⚠️ 仅 lyrics.ovh 低分命中（高错配风险）")
    }

    // ── 4. Timestamp overshoot detection ──
    // Lyrics extend past song duration = wrong version selected
    if duration > 0, lyrics.count >= 2,
       let last = lyrics.last, last.startTime > duration {
        let overshoot = last.startTime - duration
        validation.warnings.append("⚠️ 时间轴溢出: 末行 \(String(format: "%.1f", last.startTime))s > 歌曲 \(Int(duration))s (溢出\(String(format: "+%.1f", overshoot))s, 版本不匹配)")
    }

    return validation
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

    let candidates = uniqueSourceResults(allResults).filter {
        $0.score > 0 && !$0.lyrics.isEmpty && lyricIdentityTokens($0.lyrics).count >= 6
    }
    guard candidates.count >= 3 else { return [] }

    let threshold = 0.34
    let clusters: [[LyricsFetcher.LyricsFetchResult]] = candidates.map { anchor in
        candidates.filter { lyricSimilarity(anchor.lyrics, $0.lyrics) >= threshold }
    }
    guard let bestCluster = clusters.max(by: { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        let lhsSynced = lhs.filter { $0.kind == .synced }.count
        let rhsSynced = rhs.filter { $0.kind == .synced }.count
        return lhsSynced < rhsSynced
    }) else { return [] }

    guard bestCluster.count >= 2 else { return [] }
    guard !bestCluster.contains(where: { $0.source == selected.source }) else { return [] }
    let clusterHasSynced = bestCluster.contains { $0.kind == .synced }
    if !clusterHasSynced,
       selected.kind == .synced,
       (selected.score >= 75 || hasWordLevelSync(selected)) {
        return []
    }

    let selectedSimilarity = bestCluster
        .map { lyricSimilarity(selected.lyrics, $0.lyrics) }
        .max() ?? 0
    guard selectedSimilarity < 0.18 else { return [] }

    let supporters = bestCluster.map { $0.source }.sorted().joined(separator: ",")
    return ["跨源歌词内容冲突: selected=\(selected.source), consensus=\(supporters)"]
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

private func lyricSimilarity(_ lhs: [LyricLine], _ rhs: [LyricLine]) -> Double {
    let a = lyricIdentityTokens(lhs)
    let b = lyricIdentityTokens(rhs)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    let intersection = a.intersection(b).count
    return Double(intersection) / Double(min(a.count, b.count))
}

private func lyricIdentityTokens(_ lyrics: [LyricLine]) -> Set<String> {
    let lines = lyrics.filter {
        let t = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t != "..." && t != "…" && t != "⋯"
    }.prefix(24)
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
    if let src = r.selectedSource, let score = r.selectedScore {
        line += "  ->  \(src) (\(String(format: "%.0f", score))pts, \(r.lyricsLineCount)L)"
    } else {
        line += "  ->  NO LYRICS"
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
    let passed = results.filter { $0.passed }.count
    let warned = results.filter { !$0.warnings.isEmpty }.count
    let noLyrics = results.filter { $0.lyricsLineCount == 0 }.count
    let totalMs = results.reduce(0) { $0 + $1.elapsedMs }
    let avg = results.isEmpty ? 0 : totalMs / results.count

    log("""

    ========================================
      \(passed)/\(results.count) passed   \(warned) warnings   \(noLyrics) no-lyrics
      total \(totalMs)ms   avg \(avg)ms
    ========================================
    """)
}
