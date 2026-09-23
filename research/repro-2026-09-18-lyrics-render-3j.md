# 阶段包 3j 报告（2026-09-18）：真事件驱动的遮罩「全亮/丢失」复现尝试

Worktree: `.claude/worktrees/mask-repro-3j`（分支 `lyrics-render-3j-mask-repro`），基线 main=`1aab85f`（阶段包 3i）。

起点：本任务最初在另一个 worktree（`agent-adda5ee0aef1f7b0e`，停在 09-11 旧提交 `277cd5b`）里进行，协调者指出该分支落后，执行 `git merge --ff-only main`（`277cd5b` 是 `1aab85f` 的祖先，working tree 干净，无冲突）后，环境把工作目录切回了主 checkout（不再是 worktree）。为遵守项目"主对话不进 worktree、一个项目一个 worktree"的规矩，随后新建了本 worktree 继续任务。

## 任务动机

创始人的真实操作路径：**自己的歌词页**，播放中用触控板手动滚动回到已唱过的行，再点击某一行跳过去，高频重复，机器负载高时更容易出"遮罩要么拉满、要么没有"。此前所有复现（3f 的 45 组随机 seek fuzz、3i 第 4 条的 (a)-(d) 四个变体）都是用 `debugBeginManualScroll`/`debugTapLine` 这类**测试缝**驱动的——代码里现成的注释断言"真实的、带 phase 标记的 NSScrollWheel 事件在无头环境下无法伪造"。

## 关键发现：那条注释里的前提是错的

用一个独立脚本先验证：

```swift
let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0)
ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)      // began
ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
let nsEvent = NSEvent(cgEvent: ev)
// nsEvent.phase.rawValue == 1, nsEvent.momentumPhase.rawValue == 0, scrollingDeltaY == -20.0
```

`CGEventField.scrollWheelEventScrollPhase`（99）/`.scrollWheelEventMomentumPhase`（123）是 CoreGraphics 里普通的公开整数字段，`NSEvent(cgEvent:)` 能正确解码出 `.phase`/`.momentumPhase`。`NSEvent.mouseEvent(with:.leftMouseDown, location:, windowNumber:, ...)` 的 `location` 参数直接就是窗口坐标系（不需要转换），也验证过。这两条合起来，意味着可以在无头单元测试里，用真实事件直接喂给 `NativeLyricsSurfaceView` 生产环境的 `scrollWheel(with:)`/`mouseDown(with:)` 覆写方法——不经过任何 `#if DEBUG` 测试缝。

唯一的坑：`CGEvent.location` 是 Quartz 全局显示坐标（左上角原点、y 向下），必须经过 `view.convert(_, to: nil)`（窗口坐标，左下角原点）→ `window.convertPoint(toScreen:)`（Cocoa 屏幕坐标，左下角原点）→ 用主屏高度翻转成 Quartz 坐标 三步转换，否则 `handleNativeScrollWheel` 里的 `isInsideSurface` 命中测试会因为点落在窗口外而静默失败（这也是我在这轮里第一次踩的坑，调试后修正）。

## 新测试文件

`Tests/MusicMiniPlayerTests/NativeLyricsRealEventScrollTapMaskTests.swift`，4 个测试方法：

| # | 测试方法 | 覆盖维度 | 结果 |
|---|---------|---------|------|
| 1 | `test_realScrollBackThenRealTap_matrix_noLandingFrameIsBrightAndUnmasked` | 逐字/CJK 整行折行 × 3 个点击时机（手势 changed 中点击 / ended 后 0.3s 宽限内点击 / momentum 期间点击）× 4 档 tick（1/60s、100ms、250ms、500ms）× 3 个目标行 × 3 个落点比例 = 216 个用例 | **全绿，0 违规** |
| 2 | `test_repeatedRealScrollBackThenTap_fiveTimesUnderOneSecond_...` | 连续 5 次真实滚动回跳+点击，每次间隔 ~0.12s（<1s，对应"高频重复"） | **全绿，0 违规** |
| 3 | `test_realScrollFarThenTapNeverMountedRow_...` | 从中段（行 9）向两端各滚 40 tick 后点击行 0/1/2/16/17/18 | **全绿，0 违规**（但 firstMountCases=0/6——见下方"已知覆盖缺口"） |
| 4 | `test_interludeAnchorAdvance_doesNotJumpAcrossManualScrollStart` | 间奏正在进行时开始真实滚动手势，钉住 row 4 的 Y 在"稳态帧"与"手动滚动开始帧"之间跳变 < 6pt（对照真机证据 anchor=-26 vs 42 的量级） | **绿**（实测跳变远小于 6pt 阈值） |

跑法：`DEVELOPER_DIR=/Applications/Xcode.app swift test --filter NativeLyricsRealEventScrollTapMaskTests`。四个方法单独跑和一起跑结果一致，均为 0 failures。

## 如实结论：未复现，不是没有这个 bug

按项目铁律，这不等于"没有 bug"。真机证据（/tmp/nanopod_debug.log 14:57:14 的 anchor=-26 帧、以及创始人报告的遮罩视觉现象）仍然是最强证据。这一轮换了一个此前从未验证过的角度（真实 CGEvent/NSEvent 而非测试缝）复现，依然 0 违规——说明真事件路径本身（相对测试缝路径）不是触发条件的关键变量。

## 已知覆盖缺口（写实记录，不是借口）

- `test_realScrollFarThenTapNeverMountedRow` 的 `firstMountCases=0/6`：20 行的 fixture 加上现有渲染半径，20 tick 热身后所有行其实都已经挂载过，没有真正触发"目标行在点击那一刻才首次挂载"的场景——这条维度**没有被真正覆盖**，需要更大的行数或更窄的渲染半径才能逼出真正的首次挂载。
- 矩阵没有覆盖：点击时机从手势 ended 起细粒度扫描（当前只在 ended 后固定 0.3s 一个点）、更长的 tick（当前最大 500ms）、更大范围的滚动距离（固定 4/3 行）、点击落在真实切行边界附近、以及间奏行紧邻点击目标行这几种组合——下一节按协调者指示补齐。

## 后续维度扩展（协调者 2026-09-18 追加要求）

在不重跑整套回归的前提下，逐维度扩展本测试文件并单独跑该文件：
1. 点击时机从手势 `ended` 起，每 16ms 扫到 3s。
2. tick 加 1000ms 档。
3. 滚动距离扫 1–15 行。
4. 播放中同时切行——点击落在切行边界 ±1 帧。
5. 间奏歌：`interludeAfterIndex` 紧邻目标点击行（不是间奏行本身）。
6. anchor 测试改为直接断言 `anchorY == 42`（若能在 fixture 里稳定复现这个具体数值），而不仅仅看行位移连续性。

（本节在下一次提交时随结果更新；每加一维只跑本文件，不跑 `NativeLyrics*` 全量回归。）

---
报告人：Claude Sonnet 5。
