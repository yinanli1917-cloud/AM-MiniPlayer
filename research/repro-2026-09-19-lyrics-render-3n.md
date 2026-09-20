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

---

## 追加纠偏（同日）：真机 rowdump 证明上面这条修复不是创始人看到的「往下降」

创始人在真机按 0.2s 连拍了 12 份 rowdump（`rowdump_floatseq.txt`），时间线：
行 9 激活期间 dim/bright 字块一起浮到 y=22.0（静止 24.0）；去激活后一帧（d05）字块
仍在 22.0、暗底整行仍被 blank；再下一帧（d06）字块整体隐藏、暗底整行恢复绘制在
24.0——所有唱过的字硬生生下落 2pt。上面的「0.06pt 时钟回弹」修复是真 bug 但不是这一个。

### 根因（已复现）

两个独立缺陷叠加：

**缺陷 1：dim 字块被拿来跟亮层同步浮动+挖空**。`applyMainWordFloatGlyphLayers`（现
`NativeLyricsRowView.swift`）为「正在浮动」的普通字维护一份浮动的 dim 字块，同时把
整行暗底（`applyUnifiedDimBase`）对应字符挖空（alpha 0）——这是 2026-09-12 那次「重影」
修复留下的机制：dim 与 bright 同步浮动，保证唯一一份完全不透明的拷贝。行一旦去激活，
`applyInactivePlaybackLayerState()` 立刻把暗底挖空还原、把浮动字块隐藏——两件事都是
**瞬间**发生，没有渐变，這就是 d05→d06 的硬下落。

**缺陷 2：去激活的淡出机制根本没管到逐字字块**。真正驱动「行去激活」视觉的不是
`mainPostLineFadeFloor`（那套机制只作用于 `mainBrightTextLayer`，而这一层在逐字模式下
`.string=nil`，本来就不可见），而是 `LyricsLayerRendererView.beginDeferredDeactivation`
→ `NativeLyricsRowView.beginDeactivationFade`/`updateDeactivationFade`/
`finalizeDeactivationState` 这一整套「行从当前变为过去」的渐隐（随行本身的 opacity spring
同步淡出，`updateDeactivationFade(progress:)` 用 `(rowOpacity-0.35)/0.65` 映射）。但这套
机制同样只碰 `mainBrightTextLayer`/`translationBrightTextLayer`，从未管过
`mainBrightWordGlyphLayers`（逐字歌词真正可见的那份亮墨）——于是逐字字块在整个 parking
窗口里保持满亮度不变，直到 `finalizeDeactivationState` 调用
`applyInactivePlaybackLayerState()` 一次性隐藏，产生同样的瞬间下落。

### 修复（泛化，两处）

1. **暗底不再为普通字挖空**（`floatingOrders` 的 `flatMap` 闭包）：普通（非强调）字
   永远返回 `[]`——整行暗底永远完整绘制，不因某个字在浮动就挖空。强调字的挖空逻辑
   （含 09-18 的相邻字 scale>1 溢出挖空）保持不变，`NativeLyricsEmphasisHollowContainmentTests`
   仍绿。代价（创始人拍板接受）：浮动中的亮字下方会露出静止位置的暗底墨迹（同色、
   低 alpha），这是比「硬下落」更小的代价，不再是「两份完全不透明拷贝互相打架」的
   重影，`NativeLyricsSweepGhostTests`/`NativeLyricsDimBaseFloatGateConsistencyTests`
   已按新架构改写不变式（见下）。
2. **逐字亮字块纳入去激活淡出**：新增 `parkedMainWordGlyphOpacity` /
   `mainWordGlyphDeactivationOverlayBaseline`，镜像 `parkedMainBrightOpacity` /
   `mainDeactivationOverlayBaseline` 的既有模式，在 `freezeParkedTextPhaseOpacity`
   / `beginDeactivationFade` / `updateDeactivationFade` / `endDeactivationFade` 四处
   同步管理 `mainBrightWordGlyphLayers` 的 `.opacity`——现在逐字字块跟整行的淡出曲线
   完全同步，`finalizeDeactivationState` 落地时它们早已淡到透明，隐藏动作不可见。
   同时保留（次要）之前提交里 `updatePlaybackPhase` 的 `renderAsActive`/`forceActive`
   分支：对没有走 park 路径的边缘情形（未播放、park 条件不成立）仍是安全网。

### 测试

新增 `Tests/MusicMiniPlayerTests/NativeLyricsDimBaseNeverMovesTests.swift`：真
`NativeLyricsSurfaceView`，两行连续 CJK 语块，从行 A 激活驱动到行 B 接管后 2 秒，断言：
- 暗底挖空签名全程恒为「未挖空」（`debugActiveUnifiedBlankedSignature`）；
- dim 字块 y 全程不变（从未被拿来浮动）；
- 逐字亮字块 opacity（新增 `debugMainBrightWordGlyphOpacities`）必须在 2 秒内真正淡到 0
  （证明淡出确实跑了，不是采样太短）；
- 任意相邻两帧的 opacity 降幅不许超过 0.3（区分「渐变」与「瞬间隐藏」——修复前实测单帧
  掉 0.999，改前跑红确认；修复后最大单帧降幅 <0.3，且期间至少 3 帧处于「正在淡出」
  区间，绿）。

`git stash` 逐项回退验证：只回退「暗底不挖空」→ 挖空签名断言红；只回退
「逐字字块纳入淡出」→ opacity 单帧降幅 0.999、红；两处都在→绿。

### 回归（新增两项后重跑，串行）

`NativeLyricsWordFloatHoldTests`（3）+ `NativeLyricsDimBaseNeverMovesTests`（1）+
`NativeLyricsActiveLineSpacingTests` + `NativeLyricsDimBaseContinuityTests` +
`NativeLyricsCJKTrailingGhostExhaustiveTests` + `NativeLyricsDimBaseFloatGateConsistencyTests`
（改写不变式后重新绿）+ `NativeLyricsPostSeekReactivationMaskTests` +
`NativeLyricsPauseFreezeTests` + `NativeLyricsEmphasisHollowContainmentTests` +
`NativeLyricsBlurEconomyTests` + `NativeLyricsImplicitAnimationTests` +
`NativeLyricsSweepGhostTests`（改写不变式后重新绿）+ `NativeLyricsHandoffClockTests` +
`NativeLyricsMaskExhaustiveHandoffTests` + `NativeLyricsGapHandoffTests` +
`NativeLyricsHandoffDesyncTests` + `NativeLyricsSeekLandingMaskTests` +
`NativeLyricsInactiveBaseRestoreTests` + `NativeLyricsPauseResumeFlutterTests`
共 68 个用例，全绿。

**顺带发现、未修**：`NativeLyricsRenderChurnTests.test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff`
在改动前（commit 48863d5，未含本次任何改动）已经是红的（`git stash` 隔离验证：
`firstOpacityDrop=30 > firstMotion=29`），属预存失败非本次回归，未顺手修（任务范围外）。

### 因架构变更而改写的既有测试（两处，均标注日期与理由）

- `NativeLyricsDimBaseFloatGateConsistencyTests.swift`：旧不变式「dimHidden ⇔ 字在浮动」
  改为「普通字 dimHidden 永远为 true」——旧不变式正是缺陷 1 那套「暗底挖空」机制本身，
  09-19 已废弃。
- `NativeLyricsSweepGhostTests.swift`：旧不变式「dim/bright 必须重合」（2026-09-12 修复
  的产物）改为「dim 字块永不使用（`dimHidden` 恒真）」，测试名同步改
  （`test_cjk/englishSweptGlyph_dimTileNeverUsed`）。两处改写都在文件头注释里说明了
  被谁、何时、因为什么取代。
