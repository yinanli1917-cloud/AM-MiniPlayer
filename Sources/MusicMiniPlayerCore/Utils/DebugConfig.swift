//
//  DebugConfig.swift
//  MusicMiniPlayer
//
//  全局调试配置
//

import Foundation

/// 全局调试配置
public enum DebugConfig {
    /// 是否启用 stderr 调试日志输出
    /// 生产环境设为 false，调试时设为 true
    #if DEBUG
    public static let enableStderrLog = true  // 开发时设为 true 启用日志
    #else
    public static let enableStderrLog = false
    #endif

    /// Master switch for the per-frame /tmp/nanopod_*.log probe sinks (sweep/traj/
    /// census/sync/bloom/dim). Each opens a FileHandle on the MAIN THREAD every frame
    /// once its /tmp file exists, and stale files from an old session silently re-arm
    /// them the next time LOCAL_DEVELOPER_BUILD is compiled in; a full set once wrote
    /// hundreds of MB and hung the machine. Default OFF so an instrumented build
    /// measures clean — launch with NANOPOD_PROBES=1 to arm. One-shot dumps
    /// (WindowAnimationCensus) are not gated.
    public static let probeSinksEnabled =
        ProcessInfo.processInfo.environment["NANOPOD_PROBES"] == "1"
}

/// 调试日志输出（仅在 enableStderrLog 为 true 时输出）
@inline(__always)
public func debugPrint(_ message: String) {
    guard DebugConfig.enableStderrLog else { return }
    fputs(message, stderr)
}
