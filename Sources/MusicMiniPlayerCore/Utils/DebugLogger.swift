/**
 * [INPUT]: No external dependencies
 * [OUTPUT]: DebugLogger unified debug logging (log / setLogURL / setDiagnosticsFileLoggingEnabled / resetLogURL / clearLog / flush)
 * [POS]: Logging submodule of Utils; all file writes funnel through one serial queue holding a single O_APPEND handle per log target
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
    private static var diagnosticsFileLoggingEnabled = false
    // Bumped whenever the log target changes so queued writes reopen by path
    // instead of following a renamed or removed inode. Guarded by logURLLock.
    private static var logTargetGeneration = 0

    // Opt-in diagnostic logging. Playback and animation paths can call this
    // frequently, so normal app runs must avoid file I/O and date formatting.
    private static func isEnabled() -> Bool {
        logURLLock.lock()
        let diagnosticsEnabled = diagnosticsFileLoggingEnabled
        logURLLock.unlock()
        if diagnosticsEnabled { return true }
        if ProcessInfo.processInfo.environment["NANOPOD_DEBUG_LOG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "enableDebugFileLog")
    }

    // ── 公共接口 ──

    /// 写入调试日志（Release 模式下为空操作）
    @inline(__always)
    public static func log(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        guard isEnabled() else { return }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] [\(fileName):\(line)] \(message())\n"

        writeToFile(logLine)
    }

    /// 写入带标签的日志
    @inline(__always)
    public static func log(_ tag: String, _ message: @autoclosure () -> String) {
        guard isEnabled() else { return }

        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] [\(tag)] \(message())\n"

        writeToFile(logLine)
    }

    public static func setLogURL(_ url: URL) {
        logURLLock.lock()
        configuredLogURL = url
        // Bump even when the path is unchanged: callers rotate the file
        // underneath us at session start, and the next write must open a
        // fresh inode at this path instead of reusing the stale handle.
        logTargetGeneration += 1
        logURLLock.unlock()
    }

    public static func setDiagnosticsFileLoggingEnabled(_ enabled: Bool) {
        logURLLock.lock()
        diagnosticsFileLoggingEnabled = enabled
        logURLLock.unlock()
    }

    public static func resetLogURL() {
        logURLLock.lock()
        configuredLogURL = defaultLogURL
        diagnosticsFileLoggingEnabled = false
        logTargetGeneration += 1
        logURLLock.unlock()
    }

    /// Block until every queued log line has reached the file.
    public static func flush() {
        writeQueue.sync {}
    }

    /// 清空日志文件
    public static func clearLog() {
        let target = currentLogTarget()
        writeQueue.sync {
            closeWriteHandle()
            try? FileManager.default.removeItem(at: target.url)
        }
    }

    // ── 内部实现 ──

    // Serial queue owning the write handle: concurrent log calls can no
    // longer interleave bytes (torn writes), and render-path callers only
    // pay an async enqueue instead of a per-line open/seek/close.
    private static let writeQueue = DispatchQueue(
        label: "com.nanopod.debug-logger.writes",
        qos: .utility
    )

    // Queue-confined state — touch only from writeQueue.
    private static var writeHandle: FileHandle?
    private static var writeHandleGeneration = -1

    private static func writeToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let target = currentLogTarget()
        writeQueue.async {
            guard let handle = appendHandle(for: target) else { return }
            try? handle.write(contentsOf: data)
        }
    }

    // Reuses one O_APPEND handle for the whole session; O_APPEND keeps each
    // line append atomic even when another process writes to the same file.
    private static func appendHandle(for target: (url: URL, generation: Int)) -> FileHandle? {
        if let handle = writeHandle, writeHandleGeneration == target.generation {
            return handle
        }
        closeWriteHandle()
        try? FileManager.default.createDirectory(
            at: target.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(target.url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return nil }
        writeHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        writeHandleGeneration = target.generation
        return writeHandle
    }

    private static func closeWriteHandle() {
        try? writeHandle?.close()
        writeHandle = nil
    }

    private static func currentLogTarget() -> (url: URL, generation: Int) {
        logURLLock.lock()
        let target = (url: configuredLogURL, generation: logTargetGeneration)
        logURLLock.unlock()
        return target
    }
}
