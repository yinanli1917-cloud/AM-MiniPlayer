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

/// 测试单首歌的歌词管线
/// 调用 LyricsFetcher.shared 的 public API，走真实代码路径
func testSong(
    id: String,
    title: String,
    artist: String,
    duration: TimeInterval,
    expectation: TestExpectation?
) async -> VerifyResult {
    let start = CFAbsoluteTimeGetCurrent()
    let fetcher = LyricsFetcher.shared

    // ── 并行查询所有源 ──
    let fetchResults = await fetcher.fetchAllSources(
        title: title, artist: artist,
        duration: duration, translationEnabled: false
    )

    // ── 选择最佳 ──
    let bestLyrics = fetcher.selectBest(from: fetchResults)

    // 通过 LyricLine.id 匹配找到选中的源
    let selectedResult = fetchResults.first { result in
        guard let firstBest = bestLyrics?.first,
              let firstResult = result.lyrics.first else { return false }
        return firstBest.id == firstResult.id
    }

    let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

    // ── 构建每个源的摘要 ──
    let knownSources = ["AMLL", "NetEase", "QQ", "LRCLIB", "LRCLIB-Search", "lyrics.ovh", "Genius"]
    let allSources: [SourceResult] = knownSources.map { name in
        if let r = fetchResults.first(where: { $0.source == name }) {
            return SourceResult(name: name, found: true, score: round(r.score * 10) / 10, lines: r.lyrics.count)
        }
        return SourceResult(name: name, found: false, score: 0, lines: 0)
    }

    // ── 歌词特征 ──
    let lyrics = bestLyrics ?? []
    let firstReal = lyrics.first {
        let t = $0.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != "..." && t != "…" && t != "⋯"
    }
    let hasTranslation = lyrics.contains { $0.hasTranslation }
    let hasSyllable = lyrics.contains { $0.hasSyllableSync }

    // ── 对比期望值 ──
    var failures: [String] = []
    if let exp = expectation {
        failures = checkExpectation(
            exp, source: selectedResult?.source,
            lyrics: lyrics, firstReal: firstReal
        )
    }

    // ── 内容验证（自动检测疑似错配）──
    let warnings = validateContent(
        title: title, artist: artist,
        source: selectedResult?.source,
        score: selectedResult?.score,
        lyrics: lyrics
    )

    return VerifyResult(
        id: id, title: title, artist: artist,
        duration: Int(duration), passed: failures.isEmpty,
        selectedSource: selectedResult?.source,
        selectedScore: selectedResult?.score,
        lyricsLineCount: lyrics.count,
        hasTranslation: hasTranslation,
        hasSyllableSync: hasSyllable,
        firstRealLine: firstReal?.text,
        elapsedMs: elapsed,
        failures: failures,
        warnings: warnings,
        allSources: allSources
    )
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
            failures.append("期望找到歌词，但所有源均无结果")
            return failures
        }
        if let acceptable = exp.acceptableSources, let src = source,
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

/// 三层内容验证：
/// 1. 错配检测：首行是否包含明显错误的歌名/艺术家
/// 2. 语言一致性：歌词语言是否与歌曲语言合理
/// 3. 低质量源标记：lyrics.ovh 单一来源 + 低分 = 高风险
private func validateContent(
    title: String, artist: String,
    source: String?, score: Double?,
    lyrics: [LyricLine]
) -> [String] {
    guard !lyrics.isEmpty, let source = source else { return [] }
    var warnings: [String] = []

    let validLines = lyrics.filter {
        let t = $0.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != "..." && t != "…" && t != "⋯"
    }
    guard !validLines.isEmpty else { return [] }

    // ── 1. 首行错配检测 ──
    // 很多源的首行格式是 "歌名 - 艺术家"，如果歌名不匹配就是错配
    if let firstLine = validLines.first?.text {
        let dashParts = firstLine.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if dashParts.count == 2 {
            let lyricsTitle = dashParts[0].lowercased()
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
                    warnings.append("⚠️ 首行标题不匹配: 歌词=\"\(dashParts[0])\" vs 输入=\"\(title)\"")
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
        warnings.append("⚠️ CJK标题但歌词全是ASCII（可能是拼音垃圾）")
    }

    // 古典/器乐曲不应该有歌词
    let instrumentalKeywords = ["waltz", "sonata", "concerto", "symphony", "étude", "nocturne", "prelude", "fugue"]
    if instrumentalKeywords.contains(where: { title.lowercased().contains($0) }) {
        warnings.append("⚠️ 器乐曲标题但有歌词（可能是错配）")
    }

    // ── 3. 低质量源标记 ──
    if source == "lyrics.ovh" && (score ?? 0) < 55 {
        warnings.append("⚠️ 仅 lyrics.ovh 低分命中（高错配风险）")
    }

    return warnings
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
