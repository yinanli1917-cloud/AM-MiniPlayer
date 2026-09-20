# 3n: 逐字浮起后回落根因 + 修复（2026-09-19）

## 任务纠偏

原任务假设「未来的旅程」被错误当成强调词处理。查代码后不成立：
`NativeLyricsEmphasisPlan.make` 的 `guard !isCJK else { return .inactive }`
（`Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift:458`）已经把
所有 CJK 字排除在强调词之外，判定与契约第 70 行（非 CJK、时长 ≥1s、1–7 字符）一致，
不应改动。

协调者纠正后的真实任务：契约第 25/39 行——被扫掠到的字上浮 −2pt，
`max(1.0s, wordDuration)`，ease-out，**然后保持（holds）**，不许回落。创始人看到
「未来的旅程」浮起后又落回，这是「保持」被违反，不是强调词误判。

## 根因（已复现，非猜测）

`NativeLyricsWordRunPlan.baseFloat`（`NativeLyricsTextRenderPlan.swift:367-381`）是
`currentTime - word.startTime` 的纯函数：对严格递增的时钟是单调的，会正确上浮到
−2pt 并保持。但 `NativeLyricsRowView.updatePlaybackPhase` 读的是原始渲染时钟
（`configuration.phaseRenderTime()`），这台时钟会因为轮询重同步 / 漂移修正短暂回退
——这正是 `mainPostLineFadeFloor` 那段注释（`NativeLyricsRowView.swift` 原 282-289 行）
早就点名防过的同一类 bug，只是当时只治了「行末渐隐」这一个读数，没有覆盖「逐字上浮」
这第二个同样吃裸时钟的读数。

时钟一回退，`elapsed` 变小，`baseFloat` 的缓动输出就跟着往 0 走——正在被扫的字肉眼可见
「浮起、掉回去、再继续」。字越长（`wordDuration` 越大，浮动窗口越宽），这个回退落在窗口
中段的概率越高、越显眼；短字几乎瞬间浮完，同样的回退看不出来。这精确对应创始人的描述：
「未来的旅程」这种长语块回落明显，旁边的短字看不出来。

**代码位置**：
- 纯函数本身：`NativeLyricsTextRenderPlan.swift:367-381`（`baseFloat`），
  `NativeLyricsTextRenderPlan.swift:173-175`（`perWordFloatY`，每帧重新取用 `baseFloatY`，
  自身不做单调钳制）。
- 应用点：`NativeLyricsRowView.swift`（原 3020-3072 行区域）`applyMainWordFloatGlyphLayers`
  里 `let floatY = run.order < floats.count ? floats[run.order] : 0` 直接把这个可能回退的值
  写进 `dimLayer.position` / `brightLayer.position`，中间没有任何钳制。

## 修复（泛化，非白名单）

新增 `mainWordFloatFloor: [Int: CGFloat]`（按词序 order 记忆迄今最深的浮动值），
镜像 `mainPostLineFadeFloor` 已有的单调地板模式：

```swift
let rawFloatY = run.order < floats.count ? floats[run.order] : 0
let flooredFloatY = min(rawFloatY, mainWordFloatFloor[run.order] ?? 0)
mainWordFloatFloor[run.order] = flooredFloatY
let floatY = flooredFloatY
```

`min` 因为浮动目标是负值（−2pt）：地板取「迄今最负」，任何一帧想往 0（回落）方向走的
读数都会被钳在地板上，直到时钟真正追上更深的浮动为止——结构上不可能回落。

重置时机与 `mainPostLineFadeFloor` 完全同源（同一段话「行去激活时随整行一起复位」在这三
处都成立）：
1. `configure()` 里 `row.displayLine.id` 真正换了一行（新行/新曲）；
2. `prepareForReuse()`（视图被回收复用）；
3. `updatePlaybackPhase()` 里 `configuration.nativeSeekDiscontinuityOccurred`（显式 seek）；
4. `updatePlaybackPhase()` 里该行「重新进入激活窗口」的边沿（`justEnteredActiveWindow` 或
   `renderTimeBeforeLineStart`）。

这四个触发点只在「整行真的换了 / 真的 seek 了」时清空地板，行内的时钟抖动不会触碰它——
既堵住了回落 bug，又不违反「行去激活时随整行一起复位」这条创始人认可的既有行为。

强调词（非 CJK）路径完全没动：`applyEmphasisGlowOnSharedTile` 的 sin 曲线上升-回落是
设计内的发光效果，契约本身允许它退场归零，本次不在整改范围。

## 测试

新增 `Tests/MusicMiniPlayerTests/NativeLyricsWordFloatHoldTests.swift`（真
`NativeLyricsSurfaceView` + `debugNowOverride`/`syncPlaybackClock` 确定性时钟注入，
非 computer use、非截图）：

- `test_forwardPlayback_floatNeverRecedesOnceStarted`：单行 CJK 长语块「未来的旅程」
  （网易云真实词时长格式：单个 2.2s 词 run，与《啟程》一类真实逐字歌词同形），时钟
  在浮动窗口内注入三次 0.05s 回退，断言字块 Y 位移只朝目标方向走、任何回退 ≤0.01pt。
  **回退前**（临时 `git stash` 掉修复代码验证）：实测回落 0.060pt，测试红；
  **回退后**：绿。
- `test_forwardPlayback_floatNeverRecedes_englishWord`：同形英文词（`future`/`journey`，
  故意把时长压在 1.5s 强调词门槛以下，隔离出「纯扫掠浮动」不叠加强调词自身的发光曲线）。
  同样验证：回退修复前 0.097pt 回落、测试红；回退后绿。
- `test_lineHandoff_resetsFloatFloorForNextActivation`：验证地板只在换行时清零——同一行
  内不清零（真正的 bug），换行后新行的地板必须重新从 0 起步（创始人认可的既有行为，
  不能被这次修复破坏）。

回归（串行、`--filter`，未跑全量）全部绿，共 38 个用例：
`NativeLyricsWordFloatHoldTests`（3）、`NativeLyricsActiveLineSpacingTests`、
`NativeLyricsDimBaseContinuityTests`、`NativeLyricsCJKTrailingGhostExhaustiveTests`、
`NativeLyricsDimBaseFloatGateConsistencyTests`、`NativeLyricsPostSeekReactivationMaskTests`、
`NativeLyricsPauseFreezeTests`、`NativeLyricsEmphasisHollowContainmentTests`、
`NativeLyricsBlurEconomyTests`、`NativeLyricsImplicitAnimationTests`。

`swift build`（全量）无新增错误/警告。

## 强调词判定复核（《啟程》/ 真实网易逐字行，任务原始第 4 点）

沿用现有判定不变：`NativeLyricsEmphasisEligibility.shouldEmphasize` = 非 CJK
（`LanguageUtils.containsCJK`）且 `duration >= 1.5s` 且字符数 1–7。「未来的旅程」
（5 个 CJK 字）在任何时长下都判定为 **非强调词**——因为 CJK 守卫先短路；只走本次修好的
「扫掠 + 上浮 + 保持」路径，永远不会有 scale/lift/glow。这与创始人的期望（中文不进强调词）
一致，本次未改动这条判定。
