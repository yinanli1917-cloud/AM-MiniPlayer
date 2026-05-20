/**
 * [INPUT]: 无外部依赖
 * [OUTPUT]: DebugLogger 统一调试日志工具
 * [POS]: Utils 的日志子模块，替代分散的 debugLog 实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 Utils/CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - 调试日志工具
// ============================================================

/// 统一调试日志 - Release 模式完全关闭
public enum DebugLogger {

    // ── 配置 ──

    private static let defaultLogURL = URL(fileURLWithPath: "/tmp/nanopod_debug.log")
    private static let logURLLock = NSLock()
    private static var configuredLogURL = defaultLogURL

    // Opt-in diagnostic logging. Playback and animation paths can call this
    // frequently, so normal app runs must avoid file I/O and date formatting.
    private static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["NANOPOD_DEBUG_LOG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "enableDebugFileLog")
    }()

    // ── 公共接口 ──

    /// 写入调试日志（Release 模式下为空操作）
    @inline(__always)
    public static func log(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        guard enabled else { return }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] [\(fileName):\(line)] \(message())\n"

        writeToFile(logLine)
    }

    /// 写入带标签的日志
    @inline(__always)
    public static func log(_ tag: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }

        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] [\(tag)] \(message())\n"

        writeToFile(logLine)
    }

    public static func setLogURL(_ url: URL) {
        logURLLock.lock()
        configuredLogURL = url
        logURLLock.unlock()
    }

    public static func resetLogURL() {
        setLogURL(defaultLogURL)
    }

    // ── 内部实现 ──

    private static func writeToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = currentLogURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = FileHandle(forWritingAtPath: url.path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data)
        }
    }

    /// 清空日志文件
    public static func clearLog() {
        try? FileManager.default.removeItem(at: currentLogURL())
    }

    private static func currentLogURL() -> URL {
        logURLLock.lock()
        let url = configuredLogURL
        logURLLock.unlock()
        return url
    }
}
