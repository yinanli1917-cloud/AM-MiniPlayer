# TODOS

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
