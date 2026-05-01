/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 LyricLine, LanguageUtils, LyricsFetcher
 * [OUTPUT]: 导出 BenchmarkResult, validateBenchmark(), 本地翻译验证
 * [POS]: LyricsVerifier 的基准测试增强验证器
 */

import Foundation
import MusicMiniPlayerCore
import NaturalLanguage
import Translation

// =========================================================================
// MARK: - 基准测试结果
// =========================================================================

struct BenchmarkResult: Codable {
    let base: VerifyResult
    let region: String
    let expectedLyricsLang: String

    // 翻译验证
    let translationLeakCount: Int       // 泄漏行数
    let sourceTranslationFound: Bool    // 歌词源提供了翻译
    let localTranslationOK: Bool?       // 本地 ML 翻译成功（nil = 未测试）

    // 增强验证
    let benchmarkFailures: [String]
    let benchmarkWarnings: [String]
}

// =========================================================================
// MARK: - 入口：综合验证
// =========================================================================

/// 对 testSong() 结果执行增强验证
func validateBenchmark(
    lyrics: [LyricLine],
    benchmarkCase: BenchmarkCase
) -> (failures: [String], warnings: [String], leakCount: Int) {
    var failures: [String] = []
    var warnings: [String] = []

    // 空歌词直接返回
    guard !lyrics.isEmpty else {
        return (failures, warnings, 0)
    }

    // ── 1. 翻译泄漏检测 ──
    let leakResult = detectTranslationLeak(
        lyrics: lyrics,
        expectedLang: benchmarkCase.expectedLyricsLang
    )
    failures.append(contentsOf: leakResult.failures)
    warnings.append(contentsOf: leakResult.warnings)

    // ── 2. 语言一致性 ──
    let langWarnings = checkLanguageConsistency(
        lyrics: lyrics,
        expectedLang: benchmarkCase.expectedLyricsLang
    )
    warnings.append(contentsOf: langWarnings)

    // ── 3. 源翻译验证 ──
    let transWarnings = checkSourceTranslation(
        lyrics: lyrics,
        expectSourceTranslation: benchmarkCase.expectSourceTranslation
    )
    warnings.append(contentsOf: transWarnings)

    // ── 4. 时间轴检测 ──
    let timeWarnings = checkTimelineSanity(lyrics: lyrics)
    warnings.append(contentsOf: timeWarnings)

    return (failures, warnings, leakResult.leakCount)
}

// =========================================================================
// MARK: - 1. 翻译泄漏检测
// =========================================================================

/// 语言→脚本检测器映射
/// 非拉丁语系：检测 line.text 是否包含期望语言的字符
private let scriptDetectors: [String: (String) -> Bool] = [
    "Korean":   { LanguageUtils.containsKorean($0) },
    "Japanese": { LanguageUtils.containsJapanese($0) || LanguageUtils.containsChinese($0) },
    "Chinese":  { LanguageUtils.containsChinese($0) },
    "Thai":     { LanguageUtils.containsThai($0) },
    "Arabic":   { LanguageUtils.containsArabic($0) },
    "Hindi":    { LanguageUtils.containsDevanagari($0) },
]

/// 常见泄漏语言检测器（用于识别泄漏来源）
private let leakDetectors: [String: (String) -> Bool] = [
    "Chinese":  { LanguageUtils.containsChinese($0) && !LanguageUtils.containsJapanese($0) },
    "Korean":   { LanguageUtils.containsKorean($0) },
    "Japanese": { LanguageUtils.containsJapanese($0) },
]

private func detectTranslationLeak(
    lyrics: [LyricLine],
    expectedLang: String
) -> (failures: [String], warnings: [String], leakCount: Int) {
    // 拉丁语系（English/Spanish/French/Portuguese）不做脚本检测
    guard let expectedDetector = scriptDetectors[expectedLang] else {
        return ([], [], 0)
    }

    var failures: [String] = []
    var warnings: [String] = []

    // 采样前 15 行非空歌词
    let validLines = lyrics.filter {
        let t = $0.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != "..." && t != "…" && t != "⋯"
    }
    let sample = Array(validLines.prefix(15))
    guard sample.count >= 3 else { return ([], [], 0) }

    // 检测每行是否包含期望语言字符
    var leakCount = 0
    var leakSources: [String: Int] = [:]

    for line in sample {
        let hasExpected = expectedDetector(line.text)

        // 不含期望语言字符 → 检查是否含其他非拉丁脚本（泄漏）
        if !hasExpected && !LanguageUtils.isPureASCII(line.text) {
            // 排除：英文部分（K-pop 常有英文副歌）
            let nonASCIIPart = line.text.filter { !$0.isASCII }
            guard !nonASCIIPart.isEmpty else { continue }

            // 确认是哪种语言泄漏
            for (lang, detector) in leakDetectors where lang != expectedLang {
                if detector(line.text) {
                    leakCount += 1
                    leakSources[lang, default: 0] += 1
                    break
                }
            }
        }
    }

    // ≥3 行泄漏 → 硬失败
    if leakCount >= 3 {
        let sources = leakSources.map { "\($0.key):\($0.value)行" }.joined(separator: ", ")
        failures.append("🚨 翻译泄漏: \(leakCount)/\(sample.count) 行含非\(expectedLang)文字 (\(sources))")
    } else if leakCount > 0 {
        warnings.append("⚠️ 疑似翻译泄漏: \(leakCount)/\(sample.count) 行含异常文字")
    }

    return (failures, warnings, leakCount)
}

// =========================================================================
// MARK: - 2. 语言一致性检测
// =========================================================================

/// NLLanguageRecognizer 语言标识 → 期望语言映射
private let nlLangMap: [String: [String]] = [
    "English":    ["en"],
    "Korean":     ["ko"],
    "Japanese":   ["ja"],
    "Chinese":    ["zh-Hans", "zh-Hant", "zh"],
    "Spanish":    ["es"],
    "Hindi":      ["hi"],
    "French":     ["fr"],
    "Portuguese": ["pt"],
    "Thai":       ["th"],
    "Arabic":     ["ar"],
]

private func checkLanguageConsistency(
    lyrics: [LyricLine],
    expectedLang: String
) -> [String] {
    let recognizer = NLLanguageRecognizer()
    var langCount: [String: Int] = [:]

    // 采样前 20 行
    let sample = lyrics.filter {
        let t = $0.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count > 3
    }.prefix(20)

    for line in sample {
        recognizer.reset()
        recognizer.processString(line.text)
        if let lang = recognizer.dominantLanguage {
            langCount[lang.rawValue, default: 0] += 1
        }
    }

    guard !langCount.isEmpty else { return [] }

    // 找到最多的语言
    let dominant = langCount.max(by: { $0.value < $1.value })!
    let expectedCodes = nlLangMap[expectedLang] ?? []

    // 检查主导语言是否匹配期望
    if !expectedCodes.isEmpty && !expectedCodes.contains(dominant.key) {
        let ratio = Double(dominant.value) / Double(sample.count)
        if ratio > 0.5 {
            return ["⚠️ 语言不一致: 期望 \(expectedLang), 检测到 \(dominant.key) (\(Int(ratio * 100))%)"]
        }
    }

    return []
}

// =========================================================================
// MARK: - 3. 源翻译验证
// =========================================================================

private func checkSourceTranslation(
    lyrics: [LyricLine],
    expectSourceTranslation: Bool
) -> [String] {
    let hasTranslation = lyrics.contains { $0.hasTranslation }

    if expectSourceTranslation && !hasTranslation {
        return ["⚠️ 期望歌词源提供翻译，但未找到"]
    }

    // 检查翻译是否与主歌词相同语言（无效翻译）
    if hasTranslation {
        let recognizer = NLLanguageRecognizer()
        var sameLangCount = 0
        var checkedCount = 0

        for line in lyrics where line.hasTranslation {
            guard let translation = line.translation else { continue }
            checkedCount += 1
            if checkedCount > 10 { break }

            recognizer.reset()
            recognizer.processString(line.text)
            let mainLang = recognizer.dominantLanguage?.rawValue

            recognizer.reset()
            recognizer.processString(translation)
            let transLang = recognizer.dominantLanguage?.rawValue

            if let m = mainLang, let t = transLang, m == t {
                sameLangCount += 1
            }
        }

        if checkedCount > 0 && Double(sameLangCount) / Double(checkedCount) > 0.7 {
            return ["⚠️ 翻译与主歌词为同一语言 (\(sameLangCount)/\(checkedCount) 行)"]
        }
    }

    return []
}

// =========================================================================
// MARK: - 4. 本地 ML 翻译验证
// =========================================================================

/// 使用 Apple Translation 框架验证本地 ML 翻译能力
/// macOS 26+: 使用 init(installedSource:target:) 直接创建会话
@available(macOS 26.0, *)
func checkLocalTranslation(
    lyrics: [LyricLine],
    expectedLang: String
) async -> (ok: Bool, warning: String?) {
    // 取前 5 行非空歌词
    let sample = lyrics.filter {
        let t = $0.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count > 3
    }.prefix(5)

    guard !sample.isEmpty else { return (false, "无有效歌词行可翻译") }

    // 确定目标语言：默认中文，中文歌词→英文
    let targetLangCode = expectedLang == "Chinese" ? "en" : "zh-Hans"
    let targetLang = Locale.Language(identifier: targetLangCode)

    // 检测源语言
    let recognizer = NLLanguageRecognizer()
    let combinedText = sample.map { $0.text }.joined(separator: "\n")
    recognizer.processString(combinedText)

    guard let detectedNLLang = recognizer.dominantLanguage else {
        return (false, "无法检测歌词语言")
    }

    let sourceLang = Locale.Language(identifier: detectedNLLang.rawValue)

    // 源语言和目标语言相同→跳过
    if detectedNLLang.rawValue == targetLangCode {
        return (true, nil)
    }

    do {
        let session = TranslationSession(installedSource: sourceLang, target: targetLang)

        let requests = sample.map { TranslationSession.Request(sourceText: $0.text) }
        let responses = try await session.translations(from: requests)

        // 验证：翻译结果非空且与原文不同
        let validCount = zip(sample, responses).filter { (line, resp) in
            !resp.targetText.isEmpty && resp.targetText != line.text
        }.count

        if validCount == 0 {
            return (false, "本地翻译返回空或与原文相同")
        }

        return (true, nil)
    } catch {
        return (false, "本地翻译失败: \(error.localizedDescription)")
    }
}

// =========================================================================
// MARK: - 5. 时间轴检测
// =========================================================================

private func checkTimelineSanity(lyrics: [LyricLine]) -> [String] {
    var warnings: [String] = []

    // 检查负时间戳
    if let negLine = lyrics.first(where: { $0.startTime < 0 }) {
        warnings.append("⚠️ 负时间戳: \(negLine.startTime)s")
    }

    // 检查单调递增 + 异常间隔
    var prevTime: TimeInterval = -1
    var outOfOrderCount = 0

    for (i, line) in lyrics.enumerated() where i > 0 {
        if line.startTime < prevTime && line.startTime > 0 {
            outOfOrderCount += 1
        }

        let gap = line.startTime - prevTime
        if gap > 120 && prevTime > 0 {
            warnings.append("⚠️ 异常间隔: 第\(i)行与前一行差 \(Int(gap))s")
        }

        prevTime = line.startTime
    }

    if outOfOrderCount > 3 {
        warnings.append("⚠️ 时间轴乱序: \(outOfOrderCount) 处")
    }

    return warnings
}

// =========================================================================
// MARK: - 输出工具
// =========================================================================

func printBenchmarkResultLine(_ r: BenchmarkResult) {
    let base = r.base
    let icon = base.passed && r.benchmarkFailures.isEmpty ? "[+]" : "[x]"
    let status = base.passed && r.benchmarkFailures.isEmpty ? "PASS" : "FAIL"

    var line = "\(icon) \(base.id) \(status) \"\(base.title)\" - \(base.artist)"
    if let src = base.selectedSource, let score = base.selectedScore {
        line += "  ->  \(src) (\(String(format: "%.0f", score))pts, \(base.lyricsLineCount)L)"
    } else {
        line += "  ->  NO LYRICS"
    }
    line += "  [\(base.elapsedMs)ms]"
    if base.hasSyllableSync { line += " [syllable]" }
    if base.hasTranslation { line += " [trans]" }
    if r.translationLeakCount > 0 { line += " [LEAK:\(r.translationLeakCount)]" }
    if let ok = r.localTranslationOK { line += ok ? " [ml:ok]" : " [ml:fail]" }
    log(line)

    for f in base.failures + r.benchmarkFailures { log("      ! \(f)") }
    for w in base.warnings + r.benchmarkWarnings { log("      \(w)") }
}

func printBenchmarkSummary(_ results: [BenchmarkResult]) {
    // 按区域分组
    let grouped = Dictionary(grouping: results, by: { $0.region })

    for regionInfo in kSupportedRegions {
        guard let regionResults = grouped[regionInfo.code] else { continue }
        let passed = regionResults.filter { $0.base.passed && $0.benchmarkFailures.isEmpty }.count
        let warned = regionResults.filter { !$0.benchmarkWarnings.isEmpty }.count
        let noLyrics = regionResults.filter { $0.base.lyricsLineCount == 0 }.count
        let leaks = regionResults.filter { $0.translationLeakCount > 0 }.count
        let hasTrans = regionResults.filter { $0.sourceTranslationFound }.count
        let mlOK = regionResults.filter { $0.localTranslationOK == true }.count
        let mlTested = regionResults.filter { $0.localTranslationOK != nil }.count
        let avgMs = regionResults.isEmpty ? 0 : regionResults.reduce(0) { $0 + $1.base.elapsedMs } / regionResults.count

        log("""

        === Region: \(regionInfo.code) - \(regionInfo.name) (\(regionResults.count) songs) ===
          \(passed)/\(regionResults.count) passed   \(warned) warnings   \(noLyrics) no-lyrics
          Source translation: \(hasTrans)/\(regionResults.count)   Translation leaks: \(leaks)
          Local ML: \(mlOK)/\(mlTested) OK   avg \(avgMs)ms
        """)
    }

    // 总览
    let totalPassed = results.filter { $0.base.passed && $0.benchmarkFailures.isEmpty }.count
    let totalWarned = results.filter { !$0.benchmarkWarnings.isEmpty }.count
    let totalNoLyrics = results.filter { $0.base.lyricsLineCount == 0 }.count
    let totalLeaks = results.filter { $0.translationLeakCount > 0 }.count
    let totalMs = results.reduce(0) { $0 + $1.base.elapsedMs }
    let avgMs = results.isEmpty ? 0 : totalMs / results.count

    log("""

    ========================================
      Overall: \(totalPassed)/\(results.count) passed   \(totalWarned) warnings   \(totalNoLyrics) no-lyrics
      Translation leaks: \(totalLeaks)   total \(totalMs)ms   avg \(avgMs)ms
    ========================================
    """)
}
