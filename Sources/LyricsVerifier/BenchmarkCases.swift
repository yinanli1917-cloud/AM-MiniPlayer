/**
 * [INPUT]: 依赖 docs/lyrics_benchmark_cases.json, TestCases.TestExpectation
 * [OUTPUT]: 导出 BenchmarkCase, loadBenchmarkCases()
 * [POS]: LyricsVerifier 的全球基准测试用例加载器
 */

import Foundation

// =========================================================================
// MARK: - 数据模型
// =========================================================================

struct BenchmarkCase: Codable {
    let id: String
    let title: String
    let artist: String
    let duration: Double
    let region: String                    // "en", "ko", "ja", "zh", "es", "hi", "fr", "pt", "th", "ar"
    let expectedLyricsLang: String        // "English", "Korean", "Japanese", "Chinese" ...
    let allowedLyricsLangs: [String]?     // For code-switched songs; defaults to expectedLyricsLang only
    let expectSourceTranslation: Bool     // 歌词源（NetEase/QQ）是否应提供翻译
    let expectation: TestExpectation      // 复用已有结构

    var acceptedLyricsLangs: Set<String> {
        var langs = Set(allowedLyricsLangs ?? [])
        langs.insert(expectedLyricsLang)
        return langs
    }
}

/// 区域元信息
struct RegionInfo {
    let code: String
    let name: String
    let expectedLang: String
}

/// 所有支持的区域
let kSupportedRegions: [RegionInfo] = [
    RegionInfo(code: "en", name: "English",    expectedLang: "English"),
    RegionInfo(code: "ko", name: "Korean",     expectedLang: "Korean"),
    RegionInfo(code: "ja", name: "Japanese",   expectedLang: "Japanese"),
    RegionInfo(code: "zh", name: "Chinese",    expectedLang: "Chinese"),
    RegionInfo(code: "es", name: "Spanish",    expectedLang: "Spanish"),
    RegionInfo(code: "hi", name: "Hindi",      expectedLang: "Hindi"),
    RegionInfo(code: "fr", name: "French",     expectedLang: "French"),
    RegionInfo(code: "pt", name: "Portuguese", expectedLang: "Portuguese"),
    RegionInfo(code: "th", name: "Thai",       expectedLang: "Thai"),
    RegionInfo(code: "ar", name: "Arabic",     expectedLang: "Arabic"),
]

// =========================================================================
// MARK: - JSON 加载
// =========================================================================

/// 从 docs/lyrics_benchmark_cases.json 加载基准测试用例
func loadBenchmarkCases() -> [BenchmarkCase] {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: fm.currentDirectoryPath)

    for _ in 0..<5 {
        let candidate = dir.appendingPathComponent("docs/lyrics_benchmark_cases.json")
        if fm.fileExists(atPath: candidate.path) {
            return decodeBenchmarkCases(from: candidate)
        }
        dir = dir.deletingLastPathComponent()
    }

    log("找不到 docs/lyrics_benchmark_cases.json")
    return []
}

private func decodeBenchmarkCases(from url: URL) -> [BenchmarkCase] {
    guard let data = try? Data(contentsOf: url) else {
        log("无法读取: \(url.path)")
        return []
    }
    guard let cases = try? JSONDecoder().decode([BenchmarkCase].self, from: data) else {
        log("JSON 解析失败: \(url.path)")
        return []
    }
    return cases
}
