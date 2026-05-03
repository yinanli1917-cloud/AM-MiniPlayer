# Codex Project Instructions

_Migrated from Claude Code `/Users/yinanli/Documents/MusicMiniPlayer/Sources/MusicMiniPlayerApp/CLAUDE.md` on 2026-05-03. The source `CLAUDE.md` was left unchanged._

Codex should follow these instructions when working in this project. Claude-specific commands, hooks, and permission syntax should be interpreted as intent and adapted to Codex tools.

# MusicMiniPlayerApp 模块

App 层：AppDelegate + 窗口管理 + 设置界面 + 本地化

## 成员清单

| 文件 | 职责 |
|------|------|
| MusicMiniPlayerApp.swift | AppDelegate、浮窗/菜单栏/设置窗口创建、主菜单 |
| SettingsView.swift | MenuBarSettingsView、SettingsWindowView、通用行组件 |
| LocalizedStrings.swift | L10n（统一本地化）、UserDefaultsBinding（绑定 helper） |

## 接口

- `AppMain.shared` — 全局单例，窗口操作入口
- `L10n.localized(_:)` — 中英双语本地化，菜单栏短标签用 `mb.` 前缀
- `UserDefaultsBinding.bool(forKey:)` — UserDefaults Bool 双向绑定
