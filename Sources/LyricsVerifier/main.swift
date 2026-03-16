/**
 * [INPUT]: 依赖 TestRunner, TestCases
 * [OUTPUT]: CLI 入口 — run / check / library 三个子命令
 * [POS]: LyricsVerifier 的命令行入口
 *
 * 用法:
 *   swift run LyricsVerifier run [--case ID]
 *   swift run LyricsVerifier check "歌名" "艺术家" 秒数
 *   swift run LyricsVerifier library [--recent N]
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
    case "run":     await runPredefined(args: Array(args.dropFirst()))
    case "check":   await runAdHoc(args: Array(args.dropFirst()))
    case "library": await runLibrary(args: Array(args.dropFirst()))
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
    guard args.count >= 3, let dur = Double(args[2]) else {
        log("用法: LyricsVerifier check \"歌名\" \"艺术家\" 秒数")
        exit(1)
    }

    let title = args[0], artist = args[1]
    log("=== check \"\(title)\" - \(artist) (\(Int(dur))s) ===\n")

    let r = await testSong(
        id: "AD-HOC", title: title,
        artist: artist, duration: dur,
        expectation: nil
    )
    printResultLine(r)
    emitJSON(r)
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

private func printUsage() {
    log("""
    LyricsVerifier - nanoPod 歌词管线测试工具

    用法:
      swift run LyricsVerifier run [--case ID]         跑预定义测试用例
      swift run LyricsVerifier check "歌名" "艺术家" N  临时测试单首歌
      swift run LyricsVerifier library [--recent N]    从 AM 资料库取歌测试
    """)
}
