/**
 * [INPUT]: 依赖 TestRunner, TestCases, BenchmarkCases, BenchmarkValidator
 * [OUTPUT]: CLI 入口 — run / check / library / benchmark 四个子命令
 * [POS]: LyricsVerifier 的命令行入口
 *
 * 用法:
 *   swift run LyricsVerifier run [--case ID]
 *   swift run LyricsVerifier check "歌名" "艺术家" [秒数]  (秒数省略自动查询)
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
    // --json-out <path>: write a gamma-schema summary file after the run.
    var jsonOutPath: String? = nil
    if let idx = args.firstIndex(of: "--json-out"), idx + 1 < args.count {
        jsonOutPath = args[idx + 1]
    }
    // --inter-song-delay <seconds>: sleep between songs to avoid rate-limit
    // throttling. Defaults to 1.0s — matches the gamma acceptance spec.
    var interSongDelay: Double = 1.0
    if let idx = args.firstIndex(of: "--inter-song-delay"), idx + 1 < args.count,
       let v = Double(args[idx + 1]) {
        interSongDelay = v
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

    log("=== LyricsVerifier: \(cases.count) 个预定义用例 (delay=\(interSongDelay)s) ===\n")

    var results: [VerifyResult] = []
    for (idx, tc) in cases.enumerated() {
        let r = await testSong(
            id: tc.id, title: tc.title,
            artist: tc.artist, duration: tc.duration,
            expectation: tc.expectation,
            album: tc.album ?? ""
        )
        results.append(r)
        printResultLine(r)
        emitJSON(r)

        // Throttle guard between songs (skip after the last one).
        if idx < cases.count - 1 && interSongDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(interSongDelay * 1_000_000_000))
        }
    }
    printBatchSummary(results)

    if let path = jsonOutPath {
        writeGammaJSON(results: results, path: path, interSongDelay: interSongDelay)
    }
}

// =========================================================================
// MARK: - Gamma JSON output (exact schema per spec)
// =========================================================================

private func writeGammaJSON(results: [VerifyResult], path: String, interSongDelay: Double) {
    // Branch name + short hash via shell — no parsing, just capture.
    let branch = shellOutput("git rev-parse --abbrev-ref HEAD") ?? "unknown"
    let commit = shellOutput("git rev-parse --short HEAD") ?? "unknown"
    let timestamp = ISO8601DateFormatter().string(from: Date())

    var songsJSON: [[String: Any]] = []
    for r in results {
        let pass = r.elapsedMs <= 3000
            && r.classification == "synced"
            && r.lyricsLineCount >= 5
            && (r.selectedSource ?? "none") != "none"
            && r.passed
        var failReasons: [String] = []
        if r.elapsedMs > 3000 { failReasons.append("latency_\(r.elapsedMs)ms_over_3000") }
        if r.classification != "synced" { failReasons.append("classification_\(r.classification ?? "nil")") }
        if r.lyricsLineCount < 5 { failReasons.append("line_count_\(r.lyricsLineCount)_under_5") }
        if r.selectedSource == nil { failReasons.append("no_source") }
        if !r.failures.isEmpty { failReasons.append(contentsOf: r.failures.map { "content_\($0)" }) }

        songsJSON.append([
            "title": r.title,
            "artist": r.artist,
            "duration_s": Double(r.duration),
            "latency_ms": r.elapsedMs,
            "fetched_source": r.selectedSource ?? "none",
            "score": r.selectedScore ?? 0,
            "line_count": r.lyricsLineCount,
            "real_line_count": r.realLineCount,
            "translation_count": r.translationCount,
            "classification": r.classification ?? "none",
            "first_real_line_text": r.firstRealLine ?? "",
            "first_real_line_time_s": r.firstRealLineTimeS ?? 0,
            "last_line_time_s": r.lastLineTimeS ?? 0,
            "expected_synced": true,
            "pass": pass,
            "fail_reasons": failReasons
        ])
    }

    let latencies = results.map { $0.elapsedMs }.sorted()
    let median = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
    let p95Index = latencies.isEmpty ? 0 : Int(Double(latencies.count - 1) * 0.95)
    let p95 = latencies.isEmpty ? 0 : latencies[p95Index]
    let passCount = songsJSON.filter { ($0["pass"] as? Bool) == true }.count
    let overBudget = results.filter { $0.elapsedMs > 3000 }.count
    let syncedCount = results.filter { $0.classification == "synced" }.count
    let unsyncedCount = results.filter { $0.classification == "unsynced" }.count

    let summary: [String: Any] = [
        "total": results.count,
        "pass": passCount,
        "fail": results.count - passCount,
        "over_budget_3s": overBudget,
        "median_latency_ms": median,
        "p95_latency_ms": p95,
        "synced_count": syncedCount,
        "unsynced_count": unsyncedCount
    ]

    let root: [String: Any] = [
        "approach": "gamma",
        "branch": branch,
        "commit": commit,
        "timestamp": timestamp,
        "config": ["inter_song_delay_s": interSongDelay],
        "songs": songsJSON,
        "summary": summary
    ]

    guard let data = try? JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .sortedKeys]
    ) else {
        log("⚠️ Failed to encode gamma JSON")
        return
    }
    try? data.write(to: URL(fileURLWithPath: path))
    log("📝 Wrote gamma JSON → \(path)")
}

/// Run a shell command and capture trimmed stdout.
private func shellOutput(_ cmd: String) -> String? {
    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = ["-c", cmd]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    } catch {
        return nil
    }
}

// =========================================================================
// MARK: - check: 临时测试单首歌
// =========================================================================

private func runAdHoc(args: [String]) async {
    let dumpMode = args.contains("--dump")
    // --album "专辑" 供候选选择时匹配版本 (可选, 用于多版本歧义消解)
    var albumArg = ""
    var filtered = args.filter { $0 != "--dump" }
    if let idx = filtered.firstIndex(of: "--album"), idx + 1 < filtered.count {
        albumArg = filtered[idx + 1]
        filtered.remove(at: idx + 1)
        filtered.remove(at: idx)
    }
    guard filtered.count >= 2 else {
        log("用法: LyricsVerifier check \"歌名\" \"艺术家\" [秒数] [--album \"专辑\"] [--dump]")
        log("  秒数省略时自动从 iTunes API 查询")
        exit(1)
    }

    let title = filtered[0], artist = filtered[1]
    let dur: Double
    if filtered.count >= 3, let explicit = Double(filtered[2]) {
        dur = explicit
    } else {
        log("⏳ 未指定时长，从 iTunes API 自动查询...")
        dur = await lookupDuration(title: title, artist: artist)
        guard dur > 0 else {
            log("❌ iTunes API 未找到 \"\(title)\" - \(artist)，请手动指定秒数")
            exit(1)
        }
        log("✅ 自动检测时长: \(Int(dur))s")
    }

    log("=== check \"\(title)\" - \(artist) (\(Int(dur))s) ===\n")

    let (r, lyrics) = await testSongWithLyrics(
        id: "AD-HOC", title: title,
        artist: artist, duration: dur,
        expectation: nil,
        translationEnabled: true,
        album: albumArg
    )
    printResultLine(r)
    emitJSON(r)

    if dumpMode {
        log("\n=== LYRICS DUMP (\(lyrics.count) lines) ===")
        for (i, line) in lyrics.enumerated() {
            let hasCJK = LanguageUtils.containsChinese(line.text)
            let hasKana = LanguageUtils.containsJapanese(line.text)
            let hasKorean = LanguageUtils.containsKorean(line.text)
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

    let fixtureCases = loadTestCases()
    var results: [VerifyResult] = []
    for (i, track) in tracks.enumerated() {
        let fixture = matchingFixture(for: track, cases: fixtureCases)
        let r = await testSong(
            id: "LIB-\(String(format: "%02d", i + 1))",
            title: track.title, artist: track.artist,
            duration: track.duration, expectation: fixture?.expectation,
            album: track.album
        )
        results.append(r)
        printResultLine(r)
        emitJSON(r)
    }
    printBatchSummary(results)
}

private func matchingFixture(for track: LibraryTrack, cases: [TestCase]) -> TestCase? {
    let title = fixtureKey(track.title)
    let artist = fixtureKey(track.artist)
    return cases.first { tc in
        fixtureKey(tc.title) == title &&
        fixtureKey(tc.artist) == artist &&
        (tc.expectation.shouldFindLyrics == false || abs(tc.duration - track.duration) <= 3.0)
    }
}

private func fixtureKey(_ value: String) -> String {
    LanguageUtils.toSimplifiedChinese(value)
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
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
            translationEnabled: true,
            enforceExpectationIdentityOracle: false
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
            expectedShouldFindLyrics: bc.expectation.shouldFindLyrics,
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

// =========================================================================
// MARK: - iTunes API Duration Lookup
// =========================================================================

/// Query iTunes Search API to find the correct duration for a song.
/// Returns the best-matching track's duration in seconds, or 0 if not found.
private func lookupDuration(title: String, artist: String) async -> Double {
    let query = "\(title) \(artist)"
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=10") else { return 0 }

    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return 0 }

        let titleLower = title.lowercased()
        let artistLower = artist.lowercased()

        // Find best match: exact title + artist match, closest to first result
        for result in results {
            guard let trackName = result["trackName"] as? String,
                  let artistName = result["artistName"] as? String,
                  let millis = result["trackTimeMillis"] as? Int else { continue }
            if trackName.lowercased() == titleLower &&
               artistName.lowercased().contains(artistLower) {
                return Double(millis) / 1000.0
            }
        }
        // Fallback: first result with matching artist
        for result in results {
            guard let artistName = result["artistName"] as? String,
                  let millis = result["trackTimeMillis"] as? Int else { continue }
            if artistName.lowercased().contains(artistLower) {
                return Double(millis) / 1000.0
            }
        }
    } catch {}
    return 0
}

private func printUsage() {
    log("""
    LyricsVerifier - nanoPod 歌词管线测试工具

    用法:
      swift run LyricsVerifier run [--case ID]                           跑预定义测试用例
      swift run LyricsVerifier check "歌名" "艺术家" [秒数]               临时测试（秒数可省略，自动查询）
      swift run LyricsVerifier library [--recent N]                      从 AM 资料库取歌测试
      swift run LyricsVerifier benchmark [--region CODE] [--no-local-translation]  全球基准测试
    """)
}
