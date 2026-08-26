# 崩溃取证 + 压测缺口如实评估（2026-08-25）

## 一、崩溃取证

**现象**：创始人报 nanoPod 今晚终验期间崩溃几次。取到两份崩溃报告：`nanoPod-2026-08-25-144346.ips`（14:43，旧构建）、`nanoPod-2026-08-25-200335.ips`（20:03，构建 cdaefb36）。

**根因（唯一，两次同栈）**：主线程 `EXC_BREAKPOINT / SIGTRAP`，Swift runtime failure **`Range requires lowerBound <= upperBound`**，位于 `LyricsView.makeLayerBackedRows(from:)` 前奏分支，由歌词变更 `onChange → refreshDisplayLineCache` 触发。

那段代码：
```swift
for nextIndex in max(index + 1, firstRealLyricIndex)..<lyricsService.lyrics.count { … }
```
`index` 是 **display 空间**（display 行可因分段多于 source 行；或已发布 `lyrics` 数组在更新窗口内瞬时变短），上界 `lyrics.count` 是 **source 空间**。当 display 索引跑过 source 行数，下界 > 上界 → Range 反转 → 陷阱。20:03 现场是带前奏的日语歌 君は1000%（1986オメガトライブ），applied 29L 后崩。

**定性归因**：
- **既有 bug**，非今日改动：14:43 那次构建**既无 P1 也无今晚任何改动**，栈完全一致 → 纯既有。
- **非 P1**：P1 在 `LyricsService`（发布后冻结显示），只会**减少**发布后 lyrics 变动、降低触发面。
- **非 Phase2 所致**：Phase2（CJK 直查）改的是"取哪条歌词"，不制造反转 range；至多改变了让既有 bug 暴露的数据/时序。崩溃逻辑独立于歌词怎么加载。

**修复（提交 a07fc8a，最小防御）**：把扫描抽成纯函数 `LyricPreludeResolution.preludeEndTime`——`scanStart < count` 与 firstRealIndex 越界双守，永不构造反转 range；越界即回落前奏行自身 endTime（原 fallback）。正常路径行为不变。回归测试 `LyricPreludeResolutionTests`（8 条，含崩溃场景）。全测 902+ 绿、release 编译干净。

## 二、压测缺口（如实答）

**有没有端到端压力测试？没有。** 现有覆盖全是：
- 单元/纯函数测试（评分、匹配、解析、选择记忆化、预算算术…）；
- 确定性时钟渲染测试（切行、模糊经济、handoff——驱真 surface 但**单次、短窗**）；
- `LyricsVerifier` 离线准确率（~82 例，单曲一次，不驱动 UI）；
- `SBTimeoutRunner` 车道隔离（`RapidSwitchTests` 名字像压测，实为超时车道单测）。

**没有**任何测试做：**长时间连播（soak）**、**快速切歌（churn）**、**断网→恢复**，尤其**没有**驱动 `LyricsView.refreshDisplayLineCache → makeLayerBackedRows` 这条**集成路径**。这正是本次崩溃逃逸的原因——纯函数各自测过，但"View 的 onChange 在 lyrics/display 两数组瞬时不一致时跑集成逻辑"从没被压过。crash 类缺陷（反转 range、越界、竞态重入）只在集成 + 高频 + 对抗性数据下暴露。

## 三、最小压测方案（headless + 假时钟优先，不录屏）

按创始人规矩：自验只做代码层，假时钟/确定性回放，不用 computer use/录屏。三条，从"最能拦住本类崩溃"排起：

1. **切歌 churn 集成压测（最高优先，直接对口本次崩溃）**
   把 `makeLayerBackedRows` 的取数逻辑（或整个 `refreshDisplayLineCache`）做成可测入口，喂**对抗性 fixture 序列**：display 行数 > source 行数、前奏在尾部、source 中途变短、空歌词、纯前奏、CJK 前奏、分段行——**每种 × 数百次快速切换**，断言：零崩溃 + display/source 索引不变量（任何 display 索引访问 source 前先证明在界内）。这条能把"反转 range / 越界 / 陈旧数组"整类一次性关死。**成本低、纯确定性、零网络。**

2. **长时连播 soak（假时钟）**
   注入播放钟+墙钟（T0 已有缝 `debugPlaybackClockDateProvider`/`debugNowOverride`/`debugTick`），模拟一个长播放列表连播数百首、每首多次切行、间奏、暂停恢复，断言：零崩溃 + 无无界增长（timer/闭包/缓存条目数封顶）+ loop 该停就停。**确定性、可跑进 CI。**

3. **断网→恢复（注入传输层）**
   fetch 管线已有缝（HTTPClient、NWPathMonitor 离线自恢复）。注入"失败→恢复"传输，断言：离线时不卡死 spinner、恢复后**恰好重取一次**、不振荡、不崩。**headless、零真实网络。**

**建议落地顺序**：先做 #1（本次崩溃的直接护栏，且最便宜），随 T2 收尾一起进；#2/#3 作为 CI 常驻软化后续回归。三条都不需录屏、不需真机，符合手感类验证规矩（它们测的是崩溃/不变量/资源，不是手感）。
