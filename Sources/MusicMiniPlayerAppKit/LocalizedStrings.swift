/**
 * [INPUT]: 无外部依赖
 * [OUTPUT]: 导出 L10n（本地化工具）、UserDefaultsBinding（绑定 helper）
 * [POS]: MusicMiniPlayerApp 的本地化与 UserDefaults 基础设施
 */

import SwiftUI

// ──────────────────────────────────────────────
// MARK: - L10n 本地化工具
// ──────────────────────────────────────────────

enum L10n {
    /// 系统是否为中文
    static var isSystemChinese: Bool {
        systemLanguageCode.hasPrefix("zh")
    }

    /// 系统语言代码
    static var systemLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// 统一本地化字典
    static func localized(_ key: String) -> String {
        isSystemChinese ? (allStrings[key]?.zh ?? key) : (allStrings[key]?.en ?? key)
    }

    /// 翻译语言选项（菜单栏 + 设置窗口共用）
    static var translationLanguageOptions: [(name: String, code: String)] {
        [
            (localized("followSystem"), "system"),
            ("中文", "zh"),
            ("English", "en"),
            ("日本語", "ja"),
            ("한국어", "ko"),
            ("Français", "fr"),
            ("Deutsch", "de"),
            ("Español", "es")
        ]
    }

    // 菜单栏用短标签，设置窗口用完整标签，分别用不同 key
    private static let allStrings: [String: (en: String, zh: String)] = [
        // ── 菜单栏设置（短标签） ──
        "showWindow":           ("Show Window", "显示浮窗"),
        "playPause":            ("Play/Pause", "播放/暂停"),
        "previous":             ("Previous", "上一首"),
        "next":                 ("Next", "下一首"),
        "mb.translationLang":   ("Translation", "翻译语言"),
        "mb.translation":       ("Lyrics Translation", "歌词翻译"),
        "mb.translationTarget": ("Translate To", "翻译到"),
        "mb.fullscreenCover":   ("Fullscreen Cover", "全屏封面"),
        "mb.followSystem":      ("System", "跟随系统"),
        "showInDock":           ("Show in Dock", "在 Dock 显示"),
        "openMusic":            ("Open Music", "打开 Music"),
        "settings":             ("Settings...", "设置..."),
        "quit":                 ("Quit", "退出"),
        // ── 设置窗口（完整标签） ──
        "general":              ("General", "通用"),
        "playback":             ("Playback", "播放"),
        "appearance":           ("Appearance", "外观"),
        "about":                ("About", "关于"),
        "followSystem":         ("Follow System", "跟随系统"),
        "fullscreenCover":      ("Fullscreen Cover Mode", "全屏封面模式"),
        "fullscreenCoverDesc":  ("Enable immersive album cover display", "启用沉浸式专辑封面显示"),
        "edgeShowSongOnTrackChange":     ("Show Song on Track Change", "换歌时显示歌曲"),
        "edgeShowSongOnTrackChangeDesc": ("When tucked into the screen edge, briefly show the new song. Turn off if your music app already notifies you.", "贴边收起时，换歌会短暂显示新歌曲。音乐 app 已经会弹换歌通知的话可以关掉。"),
        "translationLang":      ("Lyrics Translation", "歌词翻译"),
        "translationLangDesc":  ("Target language for lyrics translation", "歌词翻译的目标语言"),
        "showInDockDesc":       ("Show app icon in the Dock", "在 Dock 中显示应用图标"),
        "clearPlaybackHistory":     ("Clear Playback History", "清除播放记录"),
        "clearPlaybackHistoryDesc": ("Removes nanoPod's own record of played tracks", "移除 nanoPod 自己记录的播放历史"),
        "version":              ("Version", "版本"),
        "developer":            ("Developer", "开发者"),
        "website":              ("Website", "网站"),
        "musicKit":             ("Apple Music Access", "Apple Music 访问"),
        "musicKitDesc":         ("Required for album artwork and song info", "用于获取专辑封面和歌曲信息"),
        "musicKitRequest":      ("Request Access", "请求访问"),
        "musicKitOpen":         ("Open Settings", "打开设置"),
        "shortcuts":            ("Keyboard Shortcuts", "快捷键"),
        "shortcutsFooter":      ("Shortcuts are global and work from any app. Unbound by default.", "快捷键全局生效，在任何 App 下都能触发；默认未绑定。"),
        // ── 引导页 (C6) ──
        "onboarding.welcome.title":     ("Welcome to nanoPod", "欢迎使用 nanoPod"),
        "onboarding.welcome.body":      ("A menu bar mini player for Apple Music.", "一个常驻菜单栏的 Apple Music 迷你播放器。"),
        "onboarding.feature.menubar":   ("Lives in the menu bar", "常驻菜单栏"),
        "onboarding.feature.lyrics":    ("Synced lyrics with translation", "同步歌词，支持翻译"),
        "onboarding.feature.edgehide":  ("Hides to the screen edge, peeks on hover", "可贴边隐藏，悬停即可探出"),
        "onboarding.feature.shortcuts": ("Global keyboard shortcuts", "全局快捷键"),
        "onboarding.auth.title":        ("Grant Access", "授权访问"),
        "onboarding.auth.body":         ("nanoPod needs two permissions to work fully.", "nanoPod 需要以下两项权限才能正常工作。"),
        "onboarding.auth.automation":       ("Music.app Automation", "Music.app 自动化"),
        "onboarding.auth.automationDesc":   ("Lets nanoPod read playback state and control Music.app", "让 nanoPod 读取播放状态并控制 Music.app"),
        "onboarding.auth.request":      ("Grant Access", "授权"),
        "onboarding.auth.authorized":   ("Authorized", "已授权"),
        "onboarding.auth.denied":       ("Denied", "已拒绝"),
        "onboarding.auth.notDetermined": ("Not Determined", "未决定"),
        "onboarding.done.title":        ("All Set", "设置完成"),
        "onboarding.done.body":         ("You're ready to go. You can revisit these settings anytime.", "一切就绪。这些设置随时可以在设置窗口里重新调整。"),
        "onboarding.next":              ("Next", "下一步"),
        "onboarding.back":              ("Back", "上一步"),
        "onboarding.finish":            ("Get Started", "开始使用"),
    ]
}

// ──────────────────────────────────────────────
// MARK: - UserDefaults Binding Helper
// ──────────────────────────────────────────────

enum UserDefaultsBinding {
    /// Bool 类型的 UserDefaults 双向绑定
    static func bool(forKey key: String) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: key) },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
    }
}
