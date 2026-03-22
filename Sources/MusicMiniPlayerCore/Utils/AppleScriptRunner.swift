/**
 * [INPUT]: 无外部依赖（纯 Foundation）
 * [OUTPUT]: 导出 AppleScriptRunner（Music.app 状态查询）
 * [POS]: Utils 的 AppleScript 执行器，无状态纯工具
 */

import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - AppleScriptRunner
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// 解析后的播放器状态，值类型，无副作用
struct PlayerStateSnapshot {
    let isPlaying: Bool
    let position: Double
    let shuffle: Bool
    let repeatMode: Int       // 0=off, 1=one, 2=all
    let trackName: String
    let trackArtist: String
    let trackAlbum: String
    let trackDuration: Double
    let persistentID: String
    let bitRate: Int
    let sampleRate: Int
}

enum AppleScriptRunner {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - AppleScript 源码
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private static let playerStateScript = """
    tell application "Music"
        try
            set playerState to player state as string
            set isPlaying to "false"
            if playerState is "playing" then
                set isPlaying to "true"
            end if

            set shuffleState to "false"
            if shuffle enabled then
                set shuffleState to "true"
            end if

            set repeatState to song repeat as string

            if exists current track then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track as string
                set trackID to persistent ID of current track
                set trackPosition to player position as string
                set trackBitRate to bit rate of current track as string
                set trackSampleRate to sample rate of current track as string

                return isPlaying & "|||" & trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackDuration & "|||" & trackID & "|||" & trackPosition & "|||" & trackBitRate & "|||" & trackSampleRate & "|||" & shuffleState & "|||" & repeatState
            else
                return isPlaying & "|||NOT_PLAYING|||||||0||||||0|||0|||0|||" & shuffleState & "|||" & repeatState
            end if
        on error errMsg
            return "ERROR:" & errMsg
        end try
    end tell
    """

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Public API
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// 执行 osascript 获取播放器状态，返回解析后的快照
    /// - Parameter timeout: osascript 超时秒数
    /// - Returns: 解析成功返回 snapshot，失败返回 nil
    static func fetchPlayerState(timeout: TimeInterval = 0.5) -> PlayerStateSnapshot? {
        guard let raw = executeOsascript(playerStateScript, timeout: timeout) else { return nil }
        return parseResponse(raw)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Internals
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// 执行 osascript 并返回 stdout（超时或失败返回 nil）
    private static func executeOsascript(_ script: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            debugPrint("❌ [AppleScriptRunner] Failed to launch osascript: \(error)\n")
            return nil
        }

        // 超时守卫
        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                debugPrint("⏱️ [AppleScriptRunner] Timeout!\n")
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        process.waitUntilExit()
        timeoutWorkItem.cancel()

        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty,
              !result.hasPrefix("ERROR:") else {
            return nil
        }
        return result
    }

    /// 解析 "|||" 分隔的响应字符串
    private static func parseResponse(_ raw: String) -> PlayerStateSnapshot? {
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 11 else { return nil }

        let repeatMode: Int = {
            switch parts[10].trimmingCharacters(in: .whitespacesAndNewlines) {
            case "one": return 1
            case "all": return 2
            default: return 0
            }
        }()

        return PlayerStateSnapshot(
            isPlaying: parts[0] == "true",
            position: Double(parts[6]) ?? 0,
            shuffle: parts[9] == "true",
            repeatMode: repeatMode,
            trackName: parts[1],
            trackArtist: parts[2],
            trackAlbum: parts[3],
            trackDuration: Double(parts[4]) ?? 0,
            persistentID: parts[5],
            bitRate: Int(parts[7]) ?? 0,
            sampleRate: Int(parts[8]) ?? 0
        )
    }
}
