/**
 * [INPUT]: 依赖 TestRunner, TestCases, BenchmarkCases, BenchmarkValidator
 * [OUTPUT]: CLI 入口 — run / check / library / benchmark 四个子命令
 * [POS]: LyricsVerifier 的命令行入口
 *
 * 用法:
 *   swift run LyricsVerifier run [--case ID]
 *   swift run LyricsVerifier check "歌名" "艺术家" 秒数
 *   swift run LyricsVerifier library [--recent N]
 *   swift run LyricsVerifier benchmark [--region CODE] [--no-local-translation]
 */

import Foundation
import MusicMiniPlayerCore

// =========================================================================
// MARK: - 异步入口
// =========================================================================

/// Task + dispatchMain 避免 Semaphore 阻塞协程线程池
Task {
    let args = Array(CommandLine.arguments.dropFirst())

    guard let subcommand = args.first else {
        printUsage()
        exit(1)
    }

    switch subcommand {
    case "run":       await runPredefined(args: Array(args.dropFirst()))
    case "check":     await runAdHoc(args: Array(args.dropFirst()))
    case "library":   await runLibrary(args: Array(args.dropFirst()))
    case "benchmark": await runBenchmark(args: Array(args.dropFirst()))
    default:
        log("未知子命令: \(subcommand)")
        printUsage()
        exit(1)
    }

    exit(0)
}

dispatchMain()

// =========================================================================
// MARK: - run: 跑预定义测试用例
// =========================================================================

private func runPredefined(args: [String]) async {
    var filterID: String? = nil
    if let idx = args.firstIndex(of: "--case"), idx + 1 < args.count {
        filterID = args[idx + 1]
    }

    var cases = loadTestCases()
    guard !cases.isEmpty else {
        log("没有加载到测试用例，请检查 docs/lyrics_test_cases.json")
        exit(1)
    }

    if let id = filterID {
        cases = cases.filter { $0.id == id }
        guard !cases.isEmpty else {
            log("未找到 ID=\(id) 的测试用例")
            exit(1)
        }
    }

    log("=== LyricsVerifier: \(cases.count) 个预定义用例 ===\n")

    var results: [VerifyResult] = []
    for tc in cases {
        let r = await testSong(
            id: tc.id, title: tc.title,
            artist: tc.artist, duration: tc.duration,
            expectation: tc.expectation
        )
        results.append(r)
        printResultLine(r)
        emitJSON(r)
    }
    printBatchSummary(results)
}

// =========================================================================
// MARK: - check: 临时测试单首歌
// =========================================================================

private func runAdHoc(args: [String]) async {
    let dumpMode = args.contains("--dump")
    let filtered = args.filter { $0 != "--dump" }
    guard filtered.count >= 3, let dur = Double(filtered[2]) else {
        log("用法: LyricsVerifier check \"歌名\" \"艺术家\" 秒数 [--dump]")
        exit(1)
    }

    let title = filtered[0], artist = filtered[1]
    log("=== check \"\(title)\" - \(artist) (\(Int(dur))s) ===\n")

    let (r, lyrics) = await testSongWithLyrics(
        id: "AD-HOC", title: title,
        artist: artist, duration: dur,
        expectation: nil,
        translationEnabled: true
    )
    printResultLine(r)
    emitJSON(r)

    if dumpMode {
        log("\n=== LYRICS DUMP (\(lyrics.count) lines) ===")
        for (i, line) in lyrics.enumerated() {
            let hasCJK = line.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let hasKana = line.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
            let hasKorean = line.text.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }
            let cnFlag = (hasCJK && !hasKana && !hasKorean) ? " 🚨CN" : ""
            log("  [\(String(format: "%02d", i))] \(String(format: "%6.1f", line.startTime))s  \(line.text)\(cnFlag)")
            if let trans = line.translation {
                log("       ↳ trans: \(trans)")
            }
        }
    }
}

// =========================================================================
// MARK: - library: 从 AM 资料库取歌测试
// =========================================================================

private func runLibrary(args: [String]) async {
    var count = 10
    if let idx = args.firstIndex(of: "--recent"), idx + 1 < args.count,
       let n = Int(args[idx + 1]) {
        count = n
    }

    log("=== 从 Apple Music 资料库取最近 \(count) 首 ===\n")

    let tracks = fetchLibraryTracks(count: count)
    guard !tracks.isEmpty else {
        log("未能从 Apple Music 获取歌曲（确认 Music.app 已打开）")
        exit(1)
    }
    log("获取到 \(tracks.count) 首歌曲\n")

    var results: [VerifyResult] = []
    for (i, track) in tracks.enumerated() {
        let r = await testSong(
            id: "LIB-\(String(format: "%02d", i + 1))",
            title: track.title, artist: track.artist,
            duration: track.duration, expectation: nil
        )
        results.append(r)
        printResultLine(r)
        emitJSON(r)
    }
    printBatchSummary(results)
}

// =========================================================================
// MARK: - benchmark: 全球基准测试
// =========================================================================

private func runBenchmark(args: [String]) async {
    // 解析参数
    var filterRegion: String? = nil
    var enableLocalTranslation = true

    if let idx = args.firstIndex(of: "--region"), idx + 1 < args.count {
        filterRegion = args[idx + 1]
    }
    if args.contains("--no-local-translation") {
        enableLocalTranslation = false
    }

    // 加载用例
    var cases = loadBenchmarkCases()
    guard !cases.isEmpty else {
        log("没有加载到基准测试用例，请检查 docs/lyrics_benchmark_cases.json")
        exit(1)
    }

    if let region = filterRegion {
        cases = cases.filter { $0.region == region }
        guard !cases.isEmpty else {
            let validRegions = kSupportedRegions.map { $0.code }.joined(separator: ", ")
            log("未找到区域 '\(region)' 的测试用例。支持: \(validRegions)")
            exit(1)
        }
    }

    let regionName = filterRegion.flatMap { code in
        kSupportedRegions.first { $0.code == code }?.name
    }
    log("=== Lyrics Benchmark: \(cases.count) songs \(regionName.map { "(\($0))" } ?? "(all regions)") ===\n")

    // 逐首测试
    var results: [BenchmarkResult] = []
    for bc in cases {
        // 1. 基础歌词获取 + 返回歌词（避免重复请求）
        let (baseResult, lyrics) = await testSongWithLyrics(
            id: bc.id, title: bc.title,
            artist: bc.artist, duration: bc.duration,
            expectation: bc.expectation,
            translationEnabled: true
        )

        // 2. 增强验证
        let (bmFailures, bmWarnings, leakCount) = validateBenchmark(
            lyrics: lyrics, benchmarkCase: bc
        )

        // 3. 本地 ML 翻译验证（可选）
        var localOK: Bool? = nil
        var localWarning: String? = nil
        if enableLocalTranslation && !lyrics.isEmpty {
            if #available(macOS 26.0, *) {
                let (ok, warn) = await checkLocalTranslation(
                    lyrics: lyrics, expectedLang: bc.expectedLyricsLang
                )
                localOK = ok
                localWarning = warn
            }
        }

        var allBmWarnings = bmWarnings
        if let w = localWarning { allBmWarnings.append("⚠️ ML翻译: \(w)") }

        let bmResult = BenchmarkResult(
            base: baseResult,
            region: bc.region,
            expectedLyricsLang: bc.expectedLyricsLang,
            translationLeakCount: leakCount,
            sourceTranslationFound: baseResult.hasTranslation,
            localTranslationOK: localOK,
            benchmarkFailures: bmFailures,
            benchmarkWarnings: allBmWarnings
        )
        results.append(bmResult)
        printBenchmarkResultLine(bmResult)
        emitBenchmarkJSON(bmResult)
    }

    printBenchmarkSummary(results)
}

// =========================================================================
// MARK: - 输出工具
// =========================================================================

/// JSONL → stdout（Claude 可解析）
private func emitJSON(_ result: VerifyResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(result),
          let json = String(data: data, encoding: .utf8) else { return }
    print(json)
}

private func emitBenchmarkJSON(_ result: BenchmarkResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(result),
          let json = String(data: data, encoding: .utf8) else { return }
    print(json)
}

private func printUsage() {
    log("""
    LyricsVerifier - nanoPod 歌词管线测试工具

    用法:
      swift run LyricsVerifier run [--case ID]                           跑预定义测试用例
      swift run LyricsVerifier check "歌名" "艺术家" N                    临时测试单首歌
      swift run LyricsVerifier library [--recent N]                      从 AM 资料库取歌测试
      swift run LyricsVerifier benchmark [--region CODE] [--no-local-translation]  全球基准测试
    """)
}
