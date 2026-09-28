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
        // ── 菜单栏（v3.2，2026-09-27 定稿：4 项 3 组，零勾选，功能项带图标） ──
        "showPlayer":           ("Show Player", "显示面板"),
        "hidePlayer":           ("Hide Player", "隐藏面板"),
        "translateTo":          ("Translate To", "翻译为"),
        "settings":             ("Settings\u{2026}", "设置\u{2026}"),
        "quitApp":              ("Quit nanoPod", "退出 nanoPod"),
        "openMusic":            ("Open Music", "打开 Music"),
        // ── 设置窗口（v3.2：Player · General · Shortcuts · About，无 sidebar） ──
        "player":               ("Player", "面板"),
        "general":              ("General", "通用"),
        "appearance":           ("Appearance", "外观"),
        "about":                ("About", "关于"),
        "followSystem":         ("Follow System", "跟随系统"),
        "fullscreenCover":      ("Fullscreen Cover", "全屏封面"),
        "fullscreenCoverDesc":  ("Fill the panel with the album cover.", "专辑封面铺满面板。"),
        "edgeShowSongOnTrackChange":     ("Show Song on Track Change", "换歌时显示歌曲"),
        "edgeShowSongOnTrackChangeDesc": ("When tucked into the screen edge, briefly show the new song.", "贴边收起时，短暂显示新歌。"),
        "showTranslation":      ("Show Translation", "显示翻译"),
        "showTranslationDesc":  ("Translated lines appear under the original.", "译文显示在原文下方。"),
        "translationLang":      ("Translate To", "翻译为"),
        "translationLangDesc":  ("Target language for lyrics translation", "歌词翻译的目标语言"),
        "showInDock":           ("Show in Dock", "在 Dock 显示"),
        "showInDockDesc":       ("Show app icon in the Dock", "在 Dock 中显示应用图标"),
        "launchAtLogin":            ("Launch at Login", "登录时启动"),
        "launchAtLoginApprovalNeeded": ("Approval required in System Settings", "需要在系统设置中批准"),
        "launchAtLoginOpenItems":   ("Open Login Items\u{2026}", "打开登录项\u{2026}"),
        "clearPlaybackHistory":     ("Clear Playback History", "清除播放记录"),
        "clearPlaybackHistoryDesc": ("nanoPod's own record of played tracks.", "nanoPod 自己记录的播放历史。"),
        "version":              ("Version", "版本"),
        "developer":            ("Developer", "开发者"),
        "website":              ("Website", "网站"),
        "acknowledgements":     ("Acknowledgements", "鸣谢"),
        "reportIssue":          ("Report an Issue", "反馈问题"),
        "musicKit":             ("Apple Music Access", "Apple Music 访问"),
        "musicKitDesc":         ("Required for album artwork and song info", "用于获取专辑封面和歌曲信息"),
        "musicKitRequest":      ("Request Access", "请求访问"),
        "musicKitOpen":         ("Open Settings", "打开设置"),
        "automation":           ("Music Automation", "Music 自动化"),
        "automationFooter":     ("nanoPod reads what's playing and controls Music through Automation. Apple Music access adds artwork and song info.", "nanoPod 通过自动化读取播放状态并控制 Music；Apple Music 访问用于获取封面和歌曲信息。"),
        "automationGrant":      ("Grant Access\u{2026}", "请求访问\u{2026}"),
        "automationOpenSettings": ("Open System Settings\u{2026}", "打开系统设置\u{2026}"),
        "shortcuts":            ("Shortcuts", "快捷键"),
        "shortcutsFooter":      ("Shortcuts work in any app. None are set by default.", "快捷键全局生效；默认未设置。"),
        "tour.settings.title":      ("Getting to know nanoPod", "认识 nanoPod"),
        "tour.settings.keepGoing":  ("Keep getting to know nanoPod", "接着认识 nanoPod"),
        "tour.settings.again":      ("Get to know nanoPod again", "重新认识 nanoPod"),
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
