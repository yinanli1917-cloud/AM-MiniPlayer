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
    let knownSources = ["AMLL", "NetEase", "QQ", "SimpMusic", "LRCLIB", "LRCLIB-Search", "lyrics.ovh"]
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

    // 打印有结果的源
    let found = r.allSources.filter { $0.found }.sorted { $0.score > $1.score }
    if !found.isEmpty {
        let detail = found.map { "\($0.name):\(String(format: "%.0f", $0.score))/\($0.lines)L" }.joined(separator: "  ")
        log("      sources: \(detail)")
    }
}

func printBatchSummary(_ results: [VerifyResult]) {
    let passed = results.filter { $0.passed }.count
    let totalMs = results.reduce(0) { $0 + $1.elapsedMs }
    let avg = results.isEmpty ? 0 : totalMs / results.count

    log("""

    ========================================
      \(passed)/\(results.count) passed   total \(totalMs)ms   avg \(avg)ms
    ========================================
    """)
}
