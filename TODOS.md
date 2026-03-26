# TODOS

## Visual / Accessibility

### 浅色封面背景对比度问题

**What:** 浅色封面（如 Ella Fitzgerald 白色封面）下，Liquid Glass 背景变浅，白字不可读。需要参考 Apple Music iOS 方案（封面 blur+压暗做背景，不依赖系统透明材质）。

**Why:** 当前 `LiquidBackgroundView` 用 `NSVisualEffectView(.behindWindow)` 透过桌面内容，颜色覆盖层无法控制最终亮度。

**Context:** 已尝试 shadow（太丑）、dominantColor 亮度钳位（无效）、封面 blur+brightness（改歪 UI）。正确方案需要实时调参验证，不适合盲改。Apple Music 用封面 `blur(40) + brightness(-0.3) + saturation(1.5)` 替代系统材质，但需注意对深色封面的影响。

**Effort:** M
**Priority:** P1
**Depends on:** None

## Features

### 逐字高亮歌词

**What:** AMLL-TTML-DB 和 NetEase YRC 已提供逐字时间轴数据，实现逐字高亮渲染。

**Why:** 当前只有行级高亮，逐字高亮是 Apple Music 级体验的核心差异点。

**Effort:** L
**Priority:** P1
**Depends on:** None

### 引导页面（Onboarding）

**What:** 首次启动引导页面，介绍核心功能和权限授予。

**Effort:** M
**Priority:** P2
**Depends on:** None

### 快捷键映射

**What:** 全局快捷键支持（播放/暂停、上/下一首、显示/隐藏窗口等）。

**Effort:** M
**Priority:** P2
**Depends on:** None

### 适配网易云/QQ音乐播放器

**What:** 除 Apple Music 外，适配网易云音乐和 QQ 音乐 macOS 客户端作为播放源。

**Effort:** L
**Priority:** P2
**Depends on:** None

### ~~macOS 26 Menu Bar 深入适配~~ ✅ FIXED

**What:** Added `LSUIElement=true` + `NSPrincipalClass=NSApplication` to Info.plist. Root cause: macOS 26's "Allow in Menu Bar" system only recognizes apps that declare `LSUIElement` — dynamic `setActivationPolicy(.accessory)` alone was insufficient.

## Code Quality

### 小清理: 按钮重复 + Binding 重复 + asyncAfter 竞态

**What:** PlaylistView Shuffle/Repeat 按钮提取为 PlaylistControlButton + SettingsView showInDock Binding 提取 + FloatingWindowModifier 0.1s asyncAfter 改为确定性方案。

**Why:** 小 DRY 违反 + 潜在竞态。

**Context:** 随其他重构顺手解决，不单独开 PR。魔法数字也随重构顺手提取为常量。

**Effort:** S
**Priority:** P2
**Depends on:** None

## Completed

### 拆分 MusicController God Object

**Completed:** 2026-03-21 — 提取 AppleScriptRunner + playerInfoChanged 拆分 + Timer 统一 + artworkFetchGeneration 原子化。746→656 行。

### LyricsView 拆分 body + @State 重组

**Completed:** 2026-03-21 — body 拆为 10+ sub-views，27 @State 分组为 ScrollState/CacheState/WaveState 结构体，删除 80 行死代码。1084→798 行。

### MetadataResolver.fetchChineseMetadata() 拆分

**Completed:** 2026-03-21 — 拆为 fetchChineseMetadata + matchCNResult + promoteSafeTranslatedCandidates，5层→3层嵌套。127→48 行主方法。

### 为 Parser/Scorer/Matching 写单元测试

**Completed:** 2026-03-21 — 77 个 XCTest 用例（LyricsParser 25 + LyricsScorer 22 + MatchingUtils 30），全部通过。

### MiniPlayerView.floatingArtwork() 提取

**Completed:** 2026-03-21 — 3 组重复 Image+mask+gradient 提取为 progressiveBlurLayer() + 清理 4 处 /tmp 调试日志。716→633 行。

### DRY 统一修复

**Completed:** 2026-03-21 — searchAndSelectCandidate() 模板方法 + SearchParams + buildCandidates 泛型 + parseTTML 拆分 + containsColonMetadata + htmlEntityMap。

### DebugLogger #if DEBUG

**Completed:** 2026-03-21 — Release 构建不再写日志。