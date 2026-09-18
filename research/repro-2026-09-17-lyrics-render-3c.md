# 歌词渲染缺陷复现报告（2026-09-17，阶段包 3c = main 4b159b9）

worktree 起始状态说明：本 worktree 开工前实际卡在 277cd5b（落后 main 173 个提交），先
`git merge --ff-only main` 同步到 4b159b9 再开始调查（提交 ecfc4ae）。创始人的实时调试日志
`/tmp/nanopod_debug.log`、`/tmp/nanopod_mask_trace.jsonl`（09-17 真机会话）已只读复制到
`research/nanopod_debug_2026-09-17.log`、`research/nanopod_mask_trace_2026-09-17.jsonl`。

---

## A（最高优先）：seek 回已唱完的逐字行，高光遮罩永久丢失 —— 已复现，已修复

**创始人报的现象**：播放中某一行唱完（整行 sweep 扫完、变为非激活）后，手动往回 seek 到
这一行，遮罩全部没有了，只剩逐字浮动，整行保持未激活颜色。任何逐字歌都能复现（创始人用
Meiko Nakahara《Private Beach》，336s，日文逐字）。

### 根因（代码证据，非推测）

`NativeLyricsRowView.mainPostLineFadeFloor`（`Sources/MusicMiniPlayerCore/UI/
NativeLyricsRowView.swift`）是一个**单调递减地板**：

```swift
mainPostLineFadeFloor = min(mainPostLineFadeFloor, plan.mainPostLineFade)
mainBrightTextLayer.opacity = Float(mainPostLineFadeFloor)
mainBrightTextLayer.isHidden = plan.mainSweepProgress <= 0.001 || mainPostLineFadeFloor <= 0.001
```

这个地板只在两处重置为 1：① `configure()` 里判定"这个 NSView 被指派到了一条不同的行"
（`self.row?.displayLine.id != row.displayLine.id`）；② `prepareForReuse()`（视图池回收）。
**从未**在"同一行发生了一次真实的、显式的 seek"这个场景下重置。

而附近可见范围内的行视图（`nativeLyricAutoVisibleRowRadius = 12`）在正常播放中**根本不会
被回收**——同一条行始终由同一个 `NSView` 承载，`row.displayLine.id` 也从未改变。于是：

1. 行唱完后继续播放（该行在"唱完但下一行还没开始"的间隙里，依 `NativeLyricsTimelinePolicy.
   liveDisplayIndex`/`amllState` 的"最后开始的行在下一行开始前一直算作当前行"规则，会继续
   收到 `updatePlaybackPhase` 调用），`plan.mainPostLineFade`（`NativeLyricsTextRenderPlan.
   postLineFadeOut`，1.5s 衰减曲线）随时间真实跌到 0，`min()` 把地板也钉死在 0。
2. 用户往回 seek 到这条行自己的 `[startTime, endTime)` 区间内——`postLineFadeOut` 的新鲜计算
   结果是 1（其 guard：`timeSinceLineEnd > 0 else { return 1 }`），逐字扫描的 mask/progress
   （`updatePerRunSweepMask`）也正确地重新算出该有的进度——但 `min(0, 1)` 仍然是 0：
   `mainBrightTextLayer`（承载高光遮罩的亮层）永远停在 `isHidden = true`，直到这个 NSView
   某天被指派到别的行或被回收。
3. 暗底文字层（`mainTextLayer`，整行常驻可见）继续显示这一行，读起来就是"未激活颜色"；
   而逐字强调/浮动字形是**另一套独立的 CALayer**（不受 `mainBrightTextLayer.isHidden` 影响），
   继续正常动画——精确对应"整行保持未激活颜色，只剩逐字浮动"。

### 复现（真实 surface + 真实确定性时钟，非猜测）

`Tests/MusicMiniPlayerTests/LyricsRenderDefects20260917ReproTests.swift`
（`test_seekBackIntoCompletedSweptLine_restoresKaraokeMask`）：真实 `NativeLyricsSurfaceView`
托管在窗口里，`debugNowOverride`/`debugTick`/`MusicController.debugPlaybackClockDateProvider`
锁定确定性时钟；6 行逐字歌，行 0 = `[0, 1.0)`，之后是 5 秒间隙（行 0 在间隙内持续保持"当前行"
地位，让地板有机会通过重复的 `min()` 调用真实衰减到 0——用短间隙复现会因为行 0 过早失活、
地板从未真正跌破 1 而假阴性，已在开发过程中亲手踩过这个坑，写进了测试注释）。

修复前实测（打印，已从最终测试删除，留档于此）：

| t | mainBrightOpacity（真实读数） |
|---|---|
| 1.0（行 0 刚唱完） | 1.0 |
| 1.5 | 0.8889 |
| 2.0 | 0.5556 |
| 2.5 及之后（间隙内持续） | 0.0（精确匹配 `1-(1.5/1.5)²`） |
| seek 回 0.5（行 0 自己的区间内）后，20 帧 | **仍是 0.0**（appliedProgress 已正确变成 0.5，
  证明遮罩计算本身没错，只是亮层被地板锁死不显示）|

红测试机制确认：地板衰减曲线与 `postLineFadeOut` 的 `1 - t²` 公式逐点吻合，不是巧合。

### 修复

在渲染器每帧发现"这是一次真实的播放不连续（显式 seek / 点击跳行 / direct-snap 落地，
不含手动滚动落地——手动滚动锚定到冻结行自身 startTime 是另一条已有的、有意的特殊处理，
不动它，避免越界碰缺陷 C 的调查范围）"时，设置新字段
`LyricsLayerRendererConfiguration.nativeSeekDiscontinuityOccurred`
（`LyricsLayerRendererView.swift`，`synchronizeNativeSemanticIndex` 的两个出口：snap-mode
早退分支 + natural 模式 `isSeek` 分支）。`NativeLyricsRowView.updatePlaybackPhase` 读到这个
标志时，把 `mainPostLineFadeFloor`/`translationPostLineFadeFloor` 重置为 1——和 `configure()`
已有的"行身份变化即重置"是同一类"真实不连续"待遇，不是新发明一套机制。

修复后同一测试：seek 回行 0 自己的区间后，`debugMainBrightOpacity` 恢复到 1.0，
`debugLastAppliedActivePerRunSweep == true`（逐字扫描正确接管）。

### 验证

- `LyricsRenderDefects20260917ReproTests`：1/1 绿（红→绿，先在未修复代码上跑出红，见上表）。
- **第一版修复有回归，已发现并收窄**：最初把触发信号定为渲染器更宽的 `isSeek`/任意
  `directSnap`（含 `.initialLayout`），跑 `NativeLyricsGapHandoffTests` 时炸出 2 个真回归——
  `test_overlayDoesNotRelightOnBackwardJitterAcrossLineEnd`（非显式的小幅倒退不该重新点亮）、
  `test_overlayRelightsWhenClockStepsBackwardInGap`（同类）。加打点定位到真凶：合成测试夹具下
  `configuration.playbackMode` 持续报 `.directSnap(.initialLayout)`（不是一次性事件，只要夹具
  没有真正走完整布局收敛条件就会每个 `configure()` 周期反复出现），把地板每帧打回 1，正好
  复刻了这些测试要防的"间隙里回跳一点点，上一行又亮回满"那个老 bug。收窄为只在
  `explicitSeek`（`MusicController.seek(to:)` → `registerSeek()` 真实产生的信号）和
  snap 分支里精确匹配 `.seek`/`.tapToLine` 两种原因时才置位，`.initialLayout`/
  `.reducedMotion`/`.occlusionResume`/`.manualScroll`/`.trackReset` 都不触发。收窄后两个
  测试转绿。
- 回归门（`NativeLyricsGapHandoffTests` + `LyricsRenderDefects20260914/20260917ReproTests` +
  `NativeLyrics*` 前缀全量 + `Handoff`/`PlaybackClockTrust`/`LyricsWholeLineFlash` 全量
  298 个测试）：**全绿，仅 1 个已知预存 harness 缺陷**
  （`NativeLyricsRenderChurnTests.test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff`，
  见 `~/.claude/projects/.../memory/handoff_red_test_appear_window.md`，2026-08-21 已裁定为
  harness 伪影非真回归，在我改任何代码之前的第一轮全量回归里就已经是这个状态）。
- `swift build`（debug，含 release target 的 link 阶段一并验证）：通过，无编译错误。

### 提交

`e9e8ad3` — `fix(lyrics-ui): release the post-line karaoke fade floor on a genuine seek`

---

## B：强调词重影 —— 根因已定位，对照臂已实现（创始人已批准并裁决）

### 调查结论（子代理只读调研，创始人已审阅并裁决）

现有实现把强调词拆成**两个独立定位的对象**：暗底整行字符串（`mainTextLayer`，把强调词的字符
范围挖空）+ 一个**完全独立的** `emphasisGlyphLayers` 池（每字形一层，自己的位置公式
`expectedEmphasisGlyphMetrics`，自己的真实 `CALayer.shadow*` 发光）。09-14 那次修复堵上的是
"暗底没挖空"这个几何重影；没堵上的是：这层独立发光对象用的是**真实 CALayer 阴影**，
`CALayer.render(in:)`（仓库里所有 headless PNG 测试都用这个方法）不可靠还原阴影合成——这类
bug 对现有测试是盲区。根因分岔点：`NativeLyricsRowView.swift:2510`，
`applyMainWordFloatGlyphLayers` 用 `where !emphasisOrders.contains(run.order)` 把强调词整体
排除在"普通字浮动瓦片"流水线之外。

创始人的"滋味"截图额外指出：CJK 三处强调判定门（`shouldEmphasize`/`NativeLyricsEmphasisPlan.
make`/`mainBrightTextLayer` 兜底发光）全部排除 CJK，"滋味"**不可能**走强调词这条路径——这是
另一个 bug，见下方"CJK 尾字重影追加调查"一节。

### 已实现、已批准的对照臂：`nanopod://debug/feel/emphasis/<current|v28|amll>`

创始人裁决：批准实现，默认臂改为收纳到与普通字**同一条**瓦片流水线（不再有第二个独立定位
对象），强度随 `emphasisWeight` 连续进出；光晕用离线预渲染的模糊位图层，不挂 live CIFilter、
不用常驻 shadow；窗口外卸载。

- **current**（默认，行为不变）：保留旧的两对象分岔，作为对照组。
- **v28**：强调词并入 `applyMainWordFloatGlyphLayers` 的瓦片（同一个 `mainBrightWordGlyphLayers`
  对象），额外叠加 `CGAffineTransform` 缩放；光晕是这**同一个对象**上的真实
  `shadowOpacity`/`shadowRadius`——阴影不可能跟自己所在的层错位。
- **amll**：同样并入瓦片流水线；光晕用一个**离线预渲染、缓存的模糊位图**兄弟层
  （`emphasisGlowBitmap`：`NSAttributedString` 画到 `CGContext` → `CIFilter.gaussianBlur`
  一次性渲染出 `CGImage`，装进 `layer.contents`，绝不挂 `layer.filters`），
  position/transform 在**同一次调用**里从亮字瓦片直接复制过去（`applyEmphasisGlowOnSharedTile`）
  ——结构上不可能独立算错。窗口外 `isHidden=true`。

测试：`Tests/MusicMiniPlayerTests/NativeLyricsEmphasisFeelParityTests.swift`（6 个，全绿）——
(a) v28/amll 从不populate 旧的 `emphasisGlyphLayers` 池；(b) amll 光晕位图与亮字瓦片
position/scale **零容差**相等（`accuracy: 0`）；(c) current 不变（仍 populate 旧池）；
另加 v28 阴影确实生效、amll 从不挂 live CIFilter 两条契约测试。`NativeLyricsActiveLineSpacingTests`
（中文行距）不受影响（强调判定门本身排除 CJK，新代码路径对中文行是 no-op）。

### 提交

`3a86676` — `feat(lyrics-ui): add feel/emphasis v28/amll contrast arm for the emphasis ghost`

### 性能 A-B-A（B5 方法论）——本轮未做，说明原因

创始人要求按项目既有 "B5" 方法（`docs/wt-b-status-2026-09-10.md`）测一首含强调词英文逐字歌的
WindowServer/app CPU A-B-A。**这个方法论要求创始人自己的机器处于安静桌面、真实 Music.app
播放、反复 quit/relaunch 真实签名 app**——不是这个 headless worktree 会话能做的事：这个
worktree 没有权限、也不应该在没有明确许可的情况下 quit 创始人正在跑的 nanoPod.app 或打断他
当前的 Music 播放。既有记录（`docs/wt-b-status-2026-09-10.md` 的 "B5 附录" 系列）本身也反复
栽在"环境有负载、数字不可信"上，需要专门安排的安静窗口。**未做**，需要创始人明确安排一个
真机窗口（或亲自跑）。定性判断（见调查报告差异表）：amll 臂只在强调窗口内挂载一个位图层，
非常驻，预期成本远小于 banned-patterns.md 记录的"常驻 CIGaussianBlur 在 12-25 个静态行上
+38 WS 点"那个量级——但这是推理不是实测，不冒充数字。

---

## CJK 尾字重影追加调查（"滋味"截图，创始人 2026-09-17 指出不是强调词路径）

### 复现（真实 surface，确定性时钟）

8 行 CJK 逐字歌，第 6 行是"爱愁思心碎滋味"（每字一个 `LyricWord`）。播放经过前几行，让第 6 行
在距离较远时进入 `isSettled && !isActive`（模糊、光栅化）状态，再连续推进播放靠近它，逐帧采样
`shouldRasterize`/`debugLastAppliedActivePerRunSweep`/`debugMainBrightOpacity`。

**坐实的证据**（多帧连续命中，非孤例）：

```
t=13.85~14.10（6 帧连续）: shouldRasterize=true sweepApplied=true brightOpacity=1.0 blur=0.5
```

即：这一行在 `shouldRasterize` 仍为 `true`（WindowServer 用的是之前缓存的位图快照）的同时，
**文本相位已经判定为激活**并开始真实驱动逐字扫描（`sweepApplied=true`，亮层已 1.0 不透明）
——快照和实时内容同时在写。

### 机制（读代码坐实，非猜测）

`applyRasterizationPolicy(isSettled:isActive:)`（`LyricsLayerRendererView.swift`，在
`applyFrame` 里用 `visual.target.isActive` 调用）用的是**视觉目标**的激活标志（呈现引擎的
wave/spring 系统），而 `sweepApplied` 依赖的是**文本相位**的激活标志
（`NativeLyricsTextActivation.isLineTextActive`，读 `effectiveTextActiveIndex`）——这两条
"是否激活"的判定路径本来就是刻意解耦的（见 `configurationForTextPhase` 的代码注释：
"ACTIVE-text PHASE... follows the SEMANTIC singing line — NOT the scroll wave's per-row visual
target"，是为了修另一个 bug 才拆开的）。结果是：文本相位可以先于视觉目标"激活"，在视觉
目标还没追上、`isSettled && !isActive` 仍然成立、`shouldRasterize` 还没来得及翻回 `false`
的这几帧窗口里，行仍然显示 WindowServer 缓存的旧位图（捕获于该行还模糊、字形还在旧浮动
位置时），而 CALayer 树里的字形已经被实时写到了新位置——**两份内容同时参与合成**：一份是
旧的、模糊的（缓存时 blur 还没退到 0）、位置滞后的快照，一份是新的、清晰的、位置已更新的
实时内容。这与创始人截图描述的"一份模糊的亮色副本错位在旁边"在机制上完全吻合：模糊（快照
捕获时 blur>0）+ 错位（快照位置是捕获那一刻的旧浮动相位，实时内容已经继续浮动到新相位）。

对 dim/bright 瓦片本身做了逐层 dump：两者的 position 在任一采样帧上都精确相等（`applyMain
WordFloatGlyphLayers` 里 dim/bright 的 position 是同一次调用里从同一个 `input.floatY` 写的，
结构上不可能独立漂移）——**这不是瓦片之间的偏移问题**，问题在光栅化缓存与实时内容之间。

### 状态：已复现、根因已定位、**未修**（按要求先报证据）

未做的原因：这条根因指向的修复面（让 `applyRasterizationPolicy` 的 `isActive` 输入改用
文本相位而非视觉目标，或者在两者不一致时暂缓置位 `shouldRasterize`）会同时影响模糊经济
（blur economy）系统的既有行为和已有测试（`NativeLyricsBlurEconomyTests`），需要专门验证
不引入新的常驻-filter 性能回归——按创始人"先报后修"的要求，本轮只报证据。复现脚本保留在
`/private/tmp/.../scratchpad/CJKGhostRepro.swift`（未提交，纯 headless 调查用，未改任何生产
代码）。

---

## C：切行后仍跳变 1-2px —— 已调查（子代理只读调研 + 一条已授权埋点），未修

### 创始人真机日志结论

`research/nanopod_debug_2026-09-17.log` 的 141 条 `LineGaps` 记录、106 对连续切行比对：
用探针本身已经做的"scale 修正后 minY"字段（不是天真直接比较原始 y），残差落在 −0.15px 到
+0.10px、均值约 −0.02~−0.04px——统计上等于零，在探针 1 位小数的取整误差范围内。**这条日志
本身没有测到二次跳变**，但这条探针结构上每次 `activeTextLineChanged` 后只武装、只记一次
（切行后 1.0-1.2s），天生测不到"已经看起来停了、隔 1-3 秒后的二次挪动"这种时序——不是
"没有问题"，是"这条埋点的粒度回答不了这个问题"。

### 新埋点（已实现，随 C 的 commit 一起落地，见上）

`NativeLyricsMaskTrace.recordRowPosition`：记录当前激活行 + 刚失活行的真实 `frame.origin.y`
（不是 layer transform ty——AppKit 每次 commit 都会把 layer-backed view 的 transform 平移
重置，`applyFrame` 本来就是靠 view.frame 而非 transform 带位置的，这也是这条埋点特意选
`frame.origin.y` 的原因）+ `isSettled`/`shouldRasterize`，只在变化时写，复用既有开关（默认关，
`NanoPodMaskTraceEnabled`）。创始人下次真机听歌撞到时能自动留证。

### Headless 真实墙钟复现

在一首几何统一、时间轴干净的合成歌上，用真实 `CVDisplayLink` 节奏（非锁步）连续追踪一行从
激活到失活的 `frame.origin.y`，关联 `shouldRasterize` 翻转帧——**未复现**：弹簧收敛平滑
（振幅 ≤0.02px），光栅化翻转帧前后位移量级和翻转前后完全一致，看不出独立于弹簧运动本身的
二次跳变。**已排除的原因**：干净的合成夹具直接喂固定高度，绕开了生产环境里两跳异步 SwiftUI
高度缓存的滞后（`b12db38` 机制，此前调查已点名"可能在飞行中重新用旧高度触发
`presentationEngine.update()`"）——这条路径没有在这次复现里被测到，也没有被排除。

### 结论与下一步

未复现≠没问题。埋点已就位，等创始人下次真机撞见即可拿到第一手证据。**一眼判断问题**：
你看到"已经停了的行又挪了一下"，这第二次挪动，是不是**正好**发生在下一句歌词真正开始唱的
那一刻（如果是，大概率是我复现里测到的"继续正常退场"，不是 bug；如果是在两句之间的安静
间隙里发生的，那才是需要继续追的真异常）？

---

## D：前奏三点冷启动 vs 手动滚回顶部位置不一致 —— 已调查（子代理只读调研），非坐标 bug

### 结论：Y 轴坐标三条路径完全一致，问题是手动滚动路径的一个悬停高亮胶囊副作用

用现有测试 `test_threePreludeEntryPaths_coldStart_seekBack_manualScrollBack` 实测三条路径
（冷启动 / seek 回前奏 / 手动滚回顶部）：三点容器中心 Y **逐位精确相等**（377.0/377.0/377.0），
行自身 `frame.minY` 也完全一致（200.0，三条路径 `semanticIndex`/`scrollTargetIndex` 都正确
解到 0）。X 轴的 50.0 vs 47.5 差异是已知的手动滚动 0.95 缩放效果（缩放轴心恰好落在点容器的
Y 坐标上，所以 Y 完全不受影响，X 受影响——不是新 bug，是已有设计的已知副作用）。

**真正的机制**：手动滚动路径下，鼠标指针停留在原地不动，而歌词行在指针下方滑动——两处代码
（`handleNativeScrollWheel` 每次滚轮事件、`configure()` 收尾的 `reresolveHoverAfterLayout()`）
会重新对"指针最后位置"做几何 hit-test 来判断该给哪一行显示悬停高亮背景（`backgroundLayer`，
白色 8% 透明度圆角胶囊）——这个机制本身是有意为之（防止行滑走后悬停状态卡在旧行不消失），
但手动滚动这个场景恰恰要求"浏览时所有行统一按 0.6/0.95 档变暗，没有哪一行应该被特别点亮"
（`NativeLyricsVisualTarget.legacyTarget` 的既有设计注释原话）。没有任何代码在
`manualScrollState.isActive` 时特别抑制这条悬停重解析——如果创始人手动滚动停下时鼠标恰好
停在第一行歌词上，那一行就会意外点亮胶囊。这不是前奏专属，是任何行都可能撞上的通用副作用，
只是创始人这次恰好停在了第一行。

### 状态：未修（按要求先报），推荐的埋点（09-15 报告建议的 `layoutDotContainer` y 值日志）
仍未落地，本轮不需要它就能解释这个现象。

**一眼判断问题**：手动滚回开头看到那个高亮胶囊时，你的鼠标/触控板指针是不是刚好停在那一行
歌词上（不用特意去动它——滚轮本身不会移动指针，它就停在你开始滚动前所在的位置）？
