import Foundation

// =============================================================================
// [INPUT]: MusicController+Playback.swift 现有公开控制方法签名（grep 核对）
// [OUTPUT]: AppleMusicControlSink 协议 + MusicController 的空 conformance
// [POS]: E1 第一步。只声明协议、不改 MusicController 任何方法体 —— 现有公开
//        签名已经满足协议要求，extension 靠既有实现空体通过。
// =============================================================================

/// Apple Music 控制面的协议化：方法签名与 MusicController 现有公开控制方法
/// 一一对应，供 AppleMusicPlaybackSource 转发调用，测试可注入假实现。
public protocol AppleMusicControlSink: AnyObject {
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func seek(to position: Double)
    func toggleShuffle()
    func cycleRepeatMode()
    func setVolume(_ level: Int)
    func toggleStar()
    func playTrack(persistentID: String)
    func fetchUpNextQueue(forceRecent: Bool)
}

extension MusicController: AppleMusicControlSink {}
