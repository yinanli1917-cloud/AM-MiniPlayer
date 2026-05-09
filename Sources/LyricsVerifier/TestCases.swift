/**
 * [INPUT]: 依赖 docs/lyrics_test_cases.json
 * [OUTPUT]: 导出 TestCase, TestExpectation, loadTestCases(), fetchLibraryTracks()
 * [POS]: LyricsVerifier 的测试用例加载器
 */

import Foundation

// =========================================================================
// MARK: - 数据模型
// =========================================================================

struct TestCase: Codable {
    let id: String
    let title: String
    let artist: String
    let duration: Double
    let album: String?
    let expectation: TestExpectation
}

struct TestExpectation: Codable {
    let shouldFindLyrics: Bool
    let allowMissingLyrics: Bool?
    let acceptableSources: [String]?
    let firstLineContains: String?
    let firstLineSHA256: String?
    let expectedClassification: String?
    let firstLineStartMinS: Double?
    let firstLineStartMaxS: Double?
    let maxTailGapS: Double?
}

struct LibraryTrack {
    let title: String
    let artist: String
    let duration: Double
    let album: String
}

// =========================================================================
// MARK: - JSON 加载
// =========================================================================

/// 从 docs/lyrics_test_cases.json 加载预定义测试用例
func loadTestCases() -> [TestCase] {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: fm.currentDirectoryPath)

    // 向上查找项目根目录（含 Package.swift）
    for _ in 0..<5 {
        let candidate = dir.appendingPathComponent("docs/lyrics_test_cases.json")
        if fm.fileExists(atPath: candidate.path) {
            return decodeTestCases(from: candidate)
        }
        dir = dir.deletingLastPathComponent()
    }

    log("找不到 docs/lyrics_test_cases.json")
    return []
}

private func decodeTestCases(from url: URL) -> [TestCase] {
    guard let data = try? Data(contentsOf: url) else {
        log("无法读取: \(url.path)")
        return []
    }
    guard let cases = try? JSONDecoder().decode([TestCase].self, from: data) else {
        log("JSON 解析失败: \(url.path)")
        return []
    }
    return cases
}

// =========================================================================
// MARK: - AM 资料库（osascript）
// =========================================================================

/// 通过 osascript 从 Apple Music 资料库获取最近添加的歌曲
/// 按 date added 过滤最近 90 天内添加的歌曲（真正的 "最近添加"）
func fetchLibraryTracks(count: Int) -> [LibraryTrack] {
    let script = """
    tell application "Music"
      set cutoffDate to (current date) - 90 * 24 * 60 * 60
      set recentTracks to every track of playlist "Library" whose date added > cutoffDate and media kind is song
      set output to ""
      set collected to 0
      repeat with t in recentTracks
        if collected >= \(count) then exit repeat
        try
          set trackName to name of t
          set trackArtist to artist of t
          set trackAlbum to album of t
          set trackDuration to duration of t
          if trackDuration > 30 and trackArtist is not "" then
            set output to output & trackName & tab & trackArtist & tab & (round trackDuration) & tab & trackAlbum & linefeed
            set collected to collected + 1
          end if
        end try
      end repeat
      return output
    end tell
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()  // 忽略 osascript 的 stderr

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        log("osascript 执行失败: \(error)")
        return []
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    return output
        .split(separator: "\n")
        .compactMap { line -> LibraryTrack? in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let dur = Double(parts[2].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return LibraryTrack(
                title: String(parts[0]),
                artist: String(parts[1]),
                duration: dur,
                album: String(parts[3])
            )
        }
}
