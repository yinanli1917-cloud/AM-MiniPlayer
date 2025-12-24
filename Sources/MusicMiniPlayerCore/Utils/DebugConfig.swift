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
    public static let enableStderrLog = false  // 开发时设为 true 启用日志
    #else
    public static let enableStderrLog = false
    #endif
}

/// 调试日志输出（仅在 enableStderrLog 为 true 时输出）
@inline(__always)
public func debugPrint(_ message: String) {
    guard DebugConfig.enableStderrLog else { return }
    fputs(message, stderr)
}
