# MusicMiniPlayerApp 模块

App 层：AppDelegate + 窗口管理 + 设置界面 + 本地化

## 成员清单

| 文件 | 职责 |
|------|------|
| MusicMiniPlayerApp.swift | AppDelegate、浮窗/菜单栏/设置窗口创建、主菜单 |
| SettingsView.swift | SettingsWindowView（每个标签一页）、设置窗口状态与调试面板；页面切换用原生工具栏标签页（SettingsTabViewController），已无自绘分段控件 |
| SettingsTabViewController.swift | 设置窗口的原生工具栏标签页（NSTabViewController，tabStyle .toolbar）：每页 SF Symbol 图标 + 标题（10-02 创始人定：Player 标签不用彩色 app 图标，真图标只留在通用页两行），隐藏页离屏预热一次，选中态/强调色/窗口标题由 AppKit 负责，窗口高度随页面 preferredContentSize 变化（宽固定 480，底部 20pt），与 SettingsWindowState 双向同步 |
| LocalizedStrings.swift | L10n（统一本地化）、UserDefaultsBinding（绑定 helper） |
| SettingsDemoStage.swift | 设置页演示台：SettingsDemo（行→演示）、DemoStageModel（谁在动，最多一个 run）、DemoTimelineSchedule（会结束的时钟）、DemoStage 视图（300×169，居中 16:9 圆角） |
| SettingsDemoMotion.swift | 演示台动效层：缓动/sv/bump、各段 timing 表、`frame(at:t)` 纯函数、DemoRun（墙钟上的一次循环/一次回放）；数值逐条来自 docs/design/2026-09-29-motion-prototype |
| SettingsDemoDrawing.swift | 演示台绘制层：Canvas 画壁纸、菜单栏、面板、键帽等（模糊/蒙版/组透明度都在 Canvas 内，离屏截图与真机一致） |
| SettingsDemoSVGPath.swift | SVG path 数据解析（复用原型的图标几何） |
| SettingsDemoWallpaper.swift | 演示台壁纸与台面 chrome 配色（StageWallpaper，默认 ember 暖色，改一行 shipped 换配色；禁止蓝紫色相） |
| SettingsDemoArt.swift | 演示台示例封面/面板/小卡/歌词页配色（StageArt，默认 teal 海面暖色体；歌词页白字 WCAG≥4.5） |
| SettingsDemoAppIcon.swift | 演示里的 nanoPod 图标：运行时取 NSApp.applicationIconImage 按格子像素重绘，无图标进程退回渐变替身 |
| SettingsPlayerApp.swift | 播放器 app 身份进设置：环境值 playerApp、PlayerAppIconView、L10n {player}/{app} 占位替换（为网易云/QQ 版本预留） |
| SettingsPermissionStatus.swift | 自动化/MusicKit 授权状态的后台查询+缓存（窗口创建时预热），避免 body 里同步调系统 API 卡切标签 |
| SettingsHoverIntent.swift | 行悬停意图（即亮 + 停满 150ms/漂移≤4pt 才切演示）+ commitCount |

## 接口

- `AppMain.shared` — 全局单例，窗口操作入口
- `L10n.localized(_:)` — 中英双语本地化，菜单栏短标签用 `mb.` 前缀
- `UserDefaultsBinding.bool(forKey:)` — UserDefaults Bool 双向绑定
