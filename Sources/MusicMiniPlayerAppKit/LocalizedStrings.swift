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
        #if DEBUG
        if let languageOverride { return languageOverride }
        #endif
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    #if DEBUG
    /// Test seam: pin the UI language regardless of the machine's locale
    /// (settings render + mixed-language checks run both en and zh).
    nonisolated(unsafe) static var languageOverride: String?
    #endif

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
    static let allStrings: [String: (en: String, zh: String)] = [
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
        "automation":           ("{app} Automation", "{app} 自动化"),
        "automationDesc":       ("Lets nanoPod read what's playing and control {app}.", "让 nanoPod 读取播放状态并控制 {app}。"),
        "automationGrant":      ("Grant Access\u{2026}", "请求访问\u{2026}"),
        "automationOpenSettings": ("Open System Settings\u{2026}", "打开系统设置\u{2026}"),
        "shortcuts":            ("Shortcuts", "快捷键"),
        "shortcutsFooter":      ("Shortcuts work in any app. None are set by default.", "快捷键全局生效；默认未设置。"),
        "tour.settings.title":      ("Getting to know nanoPod", "认识 nanoPod"),
        "tour.settings.keepGoing":  ("Keep getting to know nanoPod", "接着认识 nanoPod"),
        "tour.settings.again":      ("Get to know nanoPod again", "重新认识 nanoPod"),
        // 仍被 automationStatusControl（设置 › 通用）复用，不属于旧向导专属键。
        "onboarding.auth.authorized":   ("Authorized", "已授权"),
        "authDenied":               ("Denied", "已拒绝"),
        "authNotDetermined":        ("Not Determined", "未决定"),

        // ── 设置窗口（v3.2 重做）分组标题 / 行 / 关于页 ──
        "sectionEdge":              ("Edge", "贴边"),
        "sectionLyrics":            ("Lyrics", "歌词"),
        "sectionPermissions":       ("Permissions", "权限"),
        "sectionData":              ("Data", "数据"),
        "stateOn":                  ("On", "开"),
        "stateOff":                 ("Off", "关"),
        "playerFooter":             ("Translations come from the system translator and stay on this Mac.", "译文来自系统翻译，只在本机处理。"),
        "appleMusic":               ("{player}", "{player}"),
        "playbackHistory":          ("Playback History", "播放记录"),
        "clearButton":              ("Clear\u{2026}", "清除\u{2026}"),
        "clearHistoryConfirmTitle": ("Clear playback history?", "清除播放记录？"),
        "clearHistoryConfirmMessage": ("This removes nanoPod's own record of played tracks. It can't be undone.", "这会删除 nanoPod 自己记录的播放历史，无法撤销。"),
        "cancel":                   ("Cancel", "取消"),
        "aboutTagline":             ("A menu bar companion for {player}.", "{player} 的菜单栏伙伴。"),

        // ── 「认识 nanoPod」引导（v3.3，docs/design/2026-09-25-onboarding/proposal.md §9）──
        "tour.stop":                ("Stop here", "先到这里"),
        "tour.skipStep":            ("Skip this one", "这一步先不做"),
        "tour.idleHint":            ("No rush. Stop whenever you like.", "不着急，随时可以停下。"),
        "tour.body.away":           ("Bring your cursor back over the panel.", "鼠标再回到面板上。"),
        "tour.skip.ack":            ("OK, we'll leave that for later.", "好，先放一放。"),

        "tour.welcome.title":       ("Hi, glad you're here", "你好，很高兴见到你"),
        "tour.welcome.body":        ("Over the next couple of minutes I'll walk through nanoPod with you. Small, everyday things. No rush.", "接下来几分钟，我陪你把 nanoPod 走一遍。都是些顺手的小事，不着急。"),
        "tour.welcome.primary":     ("Begin", "开始"),
        "tour.welcome.secondary":   ("Later", "以后再说"),
        "tour.welcome.foot":        ("Stop anytime. You can pick it up again in Settings", "随时可以停下，设置里能接着来"),
        "tour.welcome.chip":        ("Music's connected", "Music 已经连上了"),
        "tour.resume.title":        ("Welcome back", "欢迎回来"),
        "tour.resume.body":         ("We left off here. Let's keep going.", "上次走到这儿，接着来。"),

        "tour.connect.title":       ("Say hi to Music", "先和 Music 打个招呼"),
        "tour.connect.body":        ("nanoPod plays and reads lyrics through Music. One click, and macOS will ask you once.", "nanoPod 靠 Music 放歌、读歌词。点一下，系统会问你一次。"),
        "tour.connect.primary":     ("Connect Music", "连上 Music"),
        "tour.connect.secondary":   ("Later", "稍后"),
        "tour.connect.confirm":     ("Connected.", "连上了。"),
        "tour.connect.denied.title": ("Music isn't on yet", "Music 还没答应"),
        "tour.connect.denied.body": ("In System Settings › Privacy & Security › Automation, turn on Music for nanoPod.", "在 系统设置 › 隐私与安全性 › 自动化 里，给 nanoPod 打开 Music 就好。"),
        "tour.connect.openSettings": ("Show me", "去看看"),
        "tour.connect.continue":    ("Go on for now", "先往下"),

        "tour.reveal.title":        ("Bring your cursor over", "把鼠标挪过来"),
        // Page-neutral: the panel may be on the cover, the lyrics or the queue when this card shows.
        "tour.reveal.body":         ("The controls stay out of the way until you need them.", "控件平时不出来挡着，需要的时候才会出现。"),
        "tour.reveal.bodyArmedPlay": ("The controls are out. Press play.", "控件出来了，按一下播放。"),
        "tour.reveal.bodyArmedPause": ("The controls are out. Press pause.", "控件出来了，按一下暂停。"),
        "tour.reveal.beat1":        ("Hover the panel", "移到面板上"),
        // The second beat asks for whatever the panel offers right now; either toggle finishes it.
        "tour.reveal.beat2":        ("Press play", "按一下播放"),
        "tour.reveal.beat2pause":   ("Press pause", "按一下暂停"),
        "tour.reveal.openingMusic": ("Opening Music…", "正在打开 Music…"),
        "tour.reveal.needAccess":   ("Once Music's connected, you can play from here", "连上 Music 之后，就能从这里放"),
        "tour.reveal.confirm":      ("There's the music.", "有声音了。"),

        "tour.corners.title":       ("The two corners", "专辑页的两个角"),
        "tour.corners.body":        ("Top right picks where the sound comes out. Top left takes you to Music.", "右上角选声音从哪里出，左上角一步到 Music。"),
        "tour.corners.beat1":       ("Top right: where the sound goes", "右上角：声音从哪出"),
        "tour.corners.beat2":       ("Top left: over to Music", "左上角：去 Music"),
        // Begun on the queue page, where neither corner button exists: a leading beat walks the user out.
        "tour.corners.beat0":       ("Step out of the queue first", "先离开播放列表"),
        "tour.corners.bodyQueue":   ("The two corner buttons aren't on the queue page. The speech bubble at the bottom left takes you out of it.", "播放列表里没有这两个角上的按钮。点左下角的小气泡，先从这里出来。"),
        "tour.corners.musicOpened": ("Music's open. Come back whenever you're ready.", "Music 打开了，回来接着来。"),
        "tour.corners.confirm":     ("Both corners, right there.", "两个角都在这儿。"),

        "tour.lyrics.title":        ("The lyrics", "歌词在这儿"),
        "tour.lyrics.body":         ("The little speech bubble at the bottom left, or click the cover.", "左下角的小气泡，或者点一下封面。"),
        "tour.lyrics.beat1":        ("Tap the speech bubble", "点一下左下角的小气泡"),
        "tour.lyrics.hoverBack":    ("Bring your cursor back over", "鼠标再回到面板上"),
        "tour.lyrics.confirm":      ("Here they are.", "到了。"),

        "tour.translate.title":     ("Translation", "翻译"),
        "tour.translate.body":      ("The button at the bottom right. Each line gets one underneath.", "右下角的按钮。译文会跟在每一句下面。"),
        // Begun off the lyrics page, where the translate button does not exist: a leading beat walks the user there.
        "tour.translate.beat0":     ("Go to the lyrics page first", "先到歌词页"),
        "tour.translate.bodyGoLyrics": ("The translate button lives on the lyrics page. Bring your cursor over and tap the speech bubble at the bottom left to get there.", "翻译按钮在歌词页里。鼠标移到面板上，点左下角的小气泡就过去了。"),
        "tour.translate.beat1":     ("Tap the translate button", "点一下翻译按钮"),
        "tour.translate.confirm":   ("Translated.", "译文来了。"),
        "tour.translate.deferred.title": ("This one doesn't need it", "这首不用翻"),
        "tour.translate.deferred.body":  ("When a song in another language comes along, I'll show you where translation is.", "等有一首外文歌的时候，我再来告诉你翻译在哪。"),
        "tour.translate.deferred.confirm": ("Noted.", "记下了。"),
        "tour.later.title":         ("This one can be translated", "这首可以翻译"),
        "tour.later.body":          ("Bring your cursor over and press the button at the bottom right.", "鼠标挪过来，右下角的按钮点一下。"),
        "tour.later.confirm":       ("Translated.", "译文来了。"),

        "tour.move.title":          ("Put it in a corner you like", "放到你喜欢的角落"),
        // Corners work on the cover page only; the lyrics page can only be pushed into a screen edge.
        "tour.move.body":           ("On the cover page, two fingers nudge the panel toward a corner and it settles there. The lyrics page can't be moved around; it only slides into a screen edge.", "在封面页，双指按住面板往一个角轻推，它会自己落好。歌词页不能随意挪，只能往屏幕边上推，让它藏进去。"),
        "tour.move.bodyLyrics":     ("Corners only work on the cover page, so let's go back there first. (On the lyrics page the panel can only be pushed into a screen edge.)", "落角只在封面页能用，我们先回到封面页。（歌词页只能往屏幕边上推，不能挪到角落。）"),
        "tour.move.beat0":          ("Back to the cover page", "先回到封面页"),
        "tour.move.beat1":          ("Nudge it to a corner", "推到一个角落"),
        "tour.move.beat2":          ("Now nudge it into the edge", "再往屏幕边上推一下"),
        "tour.move.bodyTuckRight":  ("Settled. Nudge it right once more and it slips into the edge.", "落好了。往右边再推一下，它会藏进屏幕边。"),
        "tour.move.bodyTuckLeft":   ("Settled. Nudge it left once more and it slips into the edge.", "落好了。往左边再推一下，它会藏进屏幕边。"),
        "tour.move.forMe":          ("Tuck it for me", "替我收起来"),
        "tour.move.tucking":        ("Tucking…", "正在收…"),
        "tour.move.mouseNote":      ("On a mouse, give Hide to Edge a key in Settings › Shortcuts.", "用鼠标的话，在 设置 › 快捷键 给「贴边隐藏」录个键就好。"),
        "tour.move.confirm":        ("Tucked in.", "收好了。"),

        "tour.back.title":          ("It's right here on the edge", "它就在这条边上"),
        "tour.back.beat1":          ("Rest your cursor on it. It peeks out", "鼠标停上去，它会探出来"),
        "tour.back.beat2":          ("Click, and it's back", "点一下，回来"),
        "tour.back.confirm":        ("It's back.", "回来了。"),

        "tour.done.title":          ("That's all", "就这些了"),
        "tour.done.body":           ("From here on it stays quietly to the side, there whenever you want it. I hope the time you spend with music, and with nanoPod, is time you enjoy.", "往后它就安静地待在一边，想听的时候就在。愿有音乐陪着的时候，都是好时光。"),
        "tour.done.bodyDeferred":   ("From here on it stays quietly to the side, there whenever you want it. Translation can wait for a song that needs it; I'll come back then. I hope the time you spend with music, and with nanoPod, is time you enjoy.", "往后它就安静地待在一边，想听的时候就在。翻译那一步，等有外文歌的时候我再来。愿有音乐陪着的时候，都是好时光。"),
        "tour.done.shortcut":       ("Set a shortcut", "录个快捷键"),
        "tour.done.ok":             ("OK", "好"),
        "tour.done.foot":           ("To walk through again: Settings › Get to know nanoPod again", "想再走一遍：设置 › 重新认识 nanoPod"),
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
