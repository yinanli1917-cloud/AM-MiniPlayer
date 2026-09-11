/**
 * [INPUT]: 无外部依赖
 * [OUTPUT]: PlaylistL10n（PlaylistView 专用最小本地化字典）
 * [POS]: MusicMiniPlayerCore 内部；App 层的 L10n 定义在 MusicMiniPlayerApp 模块，
 *        Core 无法反向依赖 App，因此镜像同一模式在 Core 内单独维护一份最小字典。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// PlaylistView 专用本地化字典，镜像 MusicMiniPlayerApp.L10n 的模式
/// （系统语言判定 + en/zh 字典），仅覆盖这个视图用到的 key。
enum PlaylistL10n {
    static func localized(_ key: String) -> String {
        isSystemChinese ? (allStrings[key]?.zh ?? key) : (allStrings[key]?.en ?? key)
    }

    private static var isSystemChinese: Bool {
        (Locale.current.language.languageCode?.identifier ?? "en").hasPrefix("zh")
    }

    private static let allStrings: [String: (en: String, zh: String)] = [
        "history":              ("History", "历史"),
        "nowPlaying":           ("Now Playing", "正在播放"),
        "upNext":               ("Up Next", "接下来播放"),
        "noRecentTracks":       ("No recent tracks", "暂无最近播放"),
        "queueEmpty":           ("Queue is empty", "队列为空"),
        "queueUnavailableForSource": ("Music exposes no queue for this source", "Music 未提供此来源的队列")
    ]
}
