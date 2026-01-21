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

    private static let logPath = "/tmp/nanopod_debug.log"

    #if DEBUG
    private static var enabled = false  // 开发时手动改为 true 启用
    #else
    private static let enabled = false  // Release 始终关闭
    #endif

    // ── 公共接口 ──

    /// 写入调试日志（Release 模式下为空操作）
    @inline(__always)
    public static func log(_ message: String, file: String = #file, line: Int = #line) {
        guard enabled else { return }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        writeToFile(logLine)
    }

    /// 写入带标签的日志
    @inline(__always)
    public static func log(_ tag: String, _ message: String) {
        guard enabled else { return }

        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] [\(tag)] \(message)\n"

        writeToFile(logLine)
    }

    // ── 内部实现 ──

    private static func writeToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }

    /// 清空日志文件
    public static func clearLog() {
        try? FileManager.default.removeItem(atPath: logPath)
    }
}
