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

### ~~逐字高亮歌词~~ ✅ 核实为已完成 (2026-07-27，本条已过期)

`LyricsParser.parseTTML`/`parseYRC` 早已把逐字时间戳解析进 `LyricLine.words`
（`LyricWord(word:startTime:endTime:)`），`LyricLine.hasSyllableSync` 直接由
`!words.isEmpty` 判定；`LyricsLayerRendererView`/`NativeLyricsRowView`/
`NativeLyricsTextSweepLayout` 已实现逐字扫光渲染，一直是生产路径（非实验开关），
有 `NativeLyricsTextRenderPlanTests`/`NativeLyricsAMLLParityTests` 等大量测试
覆盖。此条目已过期，未新建"behind a feature flag"的平行实现——那会与现有生产
代码重复。

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

### ~~小清理: 按钮重复~~ ✅ DONE (2026-07-27)

PlaylistView Shuffle/Repeat 按钮提取为 `Components/PlaylistControlButton.swift`
（图标内容仍是 `@ViewBuilder` 参数，Shuffle 的 AnimatedShuffleIcon 与 Repeat 的
旋转/缩放 SF Symbol + onChange 动画不变）。

**其余两项核实为过期，未改动**：SettingsView `showInDock` 目前只有一处
get/set 闭包，没有重复可提取；`FloatingWindowModifier` 在当前 Sources/ 下
已不存在（`grep` 零命中），全仓有 8 处不同的 `asyncAfter(deadline: .now() + 0.1)`
——不清楚原 TODO 具体指哪一处，盲猜可能改错代码，留给创建者确认。

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
