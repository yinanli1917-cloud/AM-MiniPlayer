# 歌词渲染三缺陷复现报告（2026-09-14）

基线：本 worktree 原停在 277cd5b（main 的祖先，落后 main 很多），已 fast-forward 到
main a3d24b7；再 cherry-pick 创始人提到的「上一轮修复」ce19929（`fix(lyrics-ui): swept
glyphs no longer double`，当时只存在于未合并分支 claude/nice-archimedes-0d8856，main 还
没包含它），使本 worktree 与创始人阶段包 2 实测所用的代码状态一致。cherry-pick 干净应用，
无冲突。

**2026-09-14 更新**：协调方指出 09-13 那次把 ce19929 合入 main 的 fast-forward 被一个
未跟踪文件挡住静默中止了，随后正式把 WT-B（含 ce19929）合入，main 现已推进到 c66cff1
（`Merge WT-B: swept-glyph ghost fix (ce19929) + B5 appendices + 09-12 recording specs`）。
已用 `git rebase --onto c66cff1 a0016ef HEAD` 把本分支上那个纯搬运用的移植提交
（a0016ef，内容和 ce19929 逐字节一致）去掉，只保留复现测试提交，现在分支 =
**c66cff1 + 954eb25**（954eb25 = 复现测试 + 报告 + PNG，rebase 后哈希从 2f0ba49 变为
954eb25，内容未变）。重跑 `LyricsRenderDefects20260914ReproTests`（5/5 绿）与
`NativeLyricsSweepGhostTests`（2/2 绿，ce19929 自己的回归测试仍然 Δy=0.0pt）确认结论不变：
强调词路径仍是 Δy≈3.26pt（本次读数 3.2639pt，此前 3.2572pt，浮点抖动，同一量级同一结论）。

复现代码：`Tests/MusicMiniPlayerTests/LyricsRenderDefects20260914ReproTests.swift`（新增，
5 个测试，全绿——绿色在这里表示"复现材料构建成功、数字符合预期"，不是"没有 bug"）。
另在 `NativeLyricsRowView.swift` 加了 3 个纯只读 DEBUG 探针（`debugPreludeDotCenterX` /
`debugPreludeDotContainerHidden` / `debugPreludeDotContainerOpacity` /
`debugEmphasisGlyphLayerPositions` / `debugMainTextLayerIsWordHidden`），仅用于复现读数，
不改变任何渲染行为。跑法：`export DEVELOPER_DIR=/Applications/Xcode.app && swift test
--filter LyricsRenderDefects20260914ReproTests`。

---

## 缺陷 1：强调词重影 —— 已复现，根因锁定，**已修复（创始人批准）**

**修复状态更新（2026-09-14）**：创始人确认重影复现属实，批准按报告原方案修。已实施——
把 `applyActiveMainPhase` 的 `floatingOrders` 计算扩到 `emphasisOrders`（强调词
`liftY`/`floatY` 非零或 `scale`≠1 时视为"正在动"，纳入暗底挖空），复用 ce19929 已有的
`applyFloatingHiddenBase` 机制，不新建挖空路径。同一个词「about」词中段（t=13.12s）
`effectiveGhostGapY` 从修复前的可见量级降到 **0.000pt**（精确 0，因为暗底此时已挖空,
没有第二份墨迹可供比较偏移）；PNG `defect1-emphasis-ghost-state-fixed.png` 与修复前的
`defect1-emphasis-ghost-state.png` 同机位同帧对照,肉眼确认"about"不再重影。
`NativeLyricsActiveLineSpacingTests`（4）/ `NativeLyricsSweepGhostTests`（2）/
`NativeLyricsEmphasisPartitionTests`（4）/ `NativeLyricsDimBaseContinuityTests`（7）
共 17 个测试全绿；`swift build -c release --product MusicMiniPlayer` 通过。详见本报告
"修法方案"一节的实施记录与下方"缺陷1 最终结果"。

**创始人报的现象**：英文歌唱到「ABOU[T]」时，暗底的「T」在亮字下方偏右露出；强调词
（emphasis）的高光模糊效果时有时无——有时正确出现，有时变成间隔更大的两层重影。

**根因**：`applyMainWordFloatGlyphLayers`（ce19929 引入的修复）只处理非强调词——循环写的是
`for run in line.runs where !emphasisOrders.contains(run.order)`，`floatingOrders` 集合也
显式排除 `emphasisOrders`（`NativeLyricsRowView.swift:1556-1560`）。这意味着 ce19929 把
「整行暗底文字需要在该词漂浮时挖空」这件事，只对普通词做了，**强调词的字形范围从来没有被
从整行暗底 `mainTextLayer.string` 里挖空过**——`applyEmphasisGlyphLayers` 只在
`managesContainerText`（即几何未就绪）时才调用 `applyHiddenEmphasisText` 去挖空
(`NativeLyricsRowView.swift:2136`)，而正常激活行 `geometryReady==true` 时
`managesContainerText = !geometryReady = false`，挖空从不发生。于是强调词的暗底副本
永远原地满 alpha 显示，`applyEmphasisGlyph`（`NativeLyricsRowView.swift:2582-2630`）在它
上面再画一份会 scale/lift/glow 浮动的亮色副本——两份墨迹。

「有时对、有时错」精确对应同一份代码在同一个词的不同瞬间：`liftY`/`charFloat`/`scale`
是词内的正弦/贝塞尔缓动值，onset 瞬间接近 0（两份重合，看起来"正确"），词中段峰值
时偏移最大（两份分离，看起来"重影"）——不是两条代码路径的切换，是同一条路径里的
连续量。

**复现数字**（`what it's all about`，"about" 11.8–14.0s，duration=2.2s≥1.5s 且长度 5，
命中 `NativeLyricsEmphasisEligibility.shouldEmphasize`）：

| 状态 | 采样时刻 | 暗底是否挖空该词 | 亮层相对暗底 Δy（5 个字形，取 max） |
|---|---|---|---|
| 重影态 | t=13.12（word 内 t1≈0.5，emphasisWeight 峰值） | `false`（未挖空） | **3.26pt** |
| "正确"态 | t=11.82（word 起始 +0.02s） | `false`（未挖空） | 0.09pt |

PNG（`layer.render(in:)` 直出，几何真实，模糊滤镜在 headless 下不生效但几何错位本身
已经清晰可见）：
- `research/repro-2026-09-14-lyrics-render/defect1-emphasis-ghost-state.png` —— "about"
  肉眼可见双影
- `research/repro-2026-09-14-lyrics-render/defect1-emphasis-clean-state.png` —— 同一词，
  onset 瞬间，单一清晰

对照创始人的话：他看到「ABOU 唱到一半，暗底 T 在亮字下方偏右露出」←→ 我复现出的
「about 的 5 个字形在词中段 Δy 最大 3.26pt，暗底永远不挖空」——同一根因,数字对得上量级
（3.26pt 在 24pt 字号下是清晰可辨的墨迹分离）。

---

## 缺陷 2 / 3：seek 回到前奏窗口后，三点动画位置错位 —— 部分复现

创始人报了两个现象：(2) 播放中 seek 回歌曲开头，前奏三点没出现；(3) 三点出现时左对齐
在左上角，不是像当前行那样居中。深挖后发现这两个现象共享同一处代码缺陷，但证据强度不同。

### 已确认（函数级，确定性、可重复）

`NativeLyricsTimelinePolicy.amllState`（`LyricsPresentationModels.swift:746-825`，这是
播放中每帧驱动"哪一行是当前行"的权威函数，真实调用点在
`LyricsLayerRendererView.swift:1378-1406`）里，**前奏行被无条件排除在 `hotGroups` /
`bufferedGroups` / `liveDisplayIndex` 的"命中"分支之外**（三处都是
`where !row.isPrelude` / `guard !row.isPrelude`）。当 seek 落在前奏窗口内（早于第一句
真实歌词的 startTime）：
- `hotGroups`、`bufferedGroups` 都是空集（没有任何非前奏行"热"）；
- `scrollToIndex`（驱动滚动/锚定目标）走 `else if isSeeking, let firstFutureIndex`
  分支，取"第一句未来的真实歌词行"，**永远不会是前奏行**；
- `semanticIndex`（驱动 `nativeSemanticCurrentIndex` → `effectiveCurrentIndex` →
  `shouldDriveTextPhase` → 是否调用 `updateDotsPhase`）落回
  `hotGroups.max() ?? bufferedGroups.max() ?? latestStartedIndex`，
  `latestStartedIndex` 本身也是 `liveDisplayIndex(fallback:)`，同样排除前奏行,
  所以直接等于调用方传入的 `fallback` 参数。

用两组 `fallback` 复现（`research` 测试文件里的两个 `test_amllState_*` 用例，纯函数、
零 flaky）：

| 场景 | fallback | hotGroups | bufferedGroups | **scrollToIndex** | **semanticIndex** |
|---|---|---|---|---|---|
| fallback 是 seek 前的旧值(模拟"回调方没重置") | 5 | `[]` | `[]` | **1**（第一句真词，不是前奏0） | **5**（卡在旧值，不是0） |
| fallback 已正确为 0（对照生产代码路径） | 0 | `[]` | `[]` | **1**（仍然不是前奏0） | 0（正确） |

第二行的 `fallback=0` 不是我瞎猜的——追到了真正驱动 `currentIndex` 的上游
`LyricsService.updateCurrentTime`（`Services/LyricsService.swift:2113-2121`），它自己就
有一段专门处理前奏：`if time < firstRealLyricStartTime { currentLineIndex = 0 }`，即
生产代码里喂给 `amllState` 的 `fallback` 在 seek 回前奏后确实会是 0。所以
**`semanticIndex`（决定三点是否被驱动）在生产路径下大概率是对的**，但
**`scrollToIndex`（决定滚动/锚定目标）始终错——即使 semanticIndex 已经正确指向前奏行，
scrollToIndex 仍然指向第一句真词**。这是一个真实、已在函数级钉死的 bug：两个本该一致
的"当前行"信号分裂了。

### 未能端到端复现（诚实报告，不算"没问题"）

用真实 `NativeLyricsSurfaceView` 托管在窗口里，注入确定性时钟，先正常播放到第 5 句
（深入歌曲），再 seek 回前奏窗口内，逐帧驱动 60fps tick：
- `semanticIndex` 确实收敛到 0（前奏行），三点容器 `isHidden=false, opacity=1.0`——
  **三点在这个复现夹具里其实是"出现"了的**，没有复现出"完全不出现"（创始人报的缺陷2
  字面症状）。
- `scrollTargetIndex` 同样收敛到 0，与 `semanticIndex` 一致——**没有复现出函数级测试
  证明存在的 scrollToIndex/semanticIndex 分裂**。怀疑原因：真实 surface 的
  `nativeTimelineState`（"previous" 状态）是逐帧累积演化的，不是我手工构造的快照；
  `bufferedGroups` 的过期剪枝（`expiredPreviousBuffered`）等状态在我这组 tick 节奏下
  可能已经把分裂"抹平"了，真正的分裂窗口可能只在 seek 后的头一两帧存在，被我的采样
  节奏跳过了。
- 两个行的 `modelY` 都停在 0（既不是配置的 anchorY=200，也没有分出"谁在锚点、谁不在"
  的差异）——这更像是这个简化夹具本身没有把 spring/reveal-gate 跑到完全 settle，不能
  当作"defect 3 已被证伪"或"已被坐实"的证据，只能说这条端到端路径这次没有稳定复现。

**结论**：defect 3（位置错位）背后的机制——scrollToIndex 与 semanticIndex 分裂——已经
在函数级用生产真实的 fallback 值钉死，代码路径也核对过是同一个真实调用点，可信度高。
但我没能在时间预算内把这个分裂在完整、真实状态演化的 surface 里稳定重放出来，所以不
敢说"就是这个根因、改这里就一定解决 defect 2/3"。defect 2 字面描述的"完全不出现"，
在我的复现里反而是"出现了"，这块可能还有别的、我没找到的因素（例如更早的一帧瞬态,
或某处缓存的 `rows`/`displayLines` 没有跟着 seek 及时刷新）。

### 缺陷 3 位置图（2026-09-14，协调方要求：带面板边界/参考线/数字的标注图）

创始人反馈上一版单行 PNG 看不出位置。重新出图：`NativeLyricsSurfaceView` 整个面板
（宽 360px）真实渲染，标出面板左右边界（蓝线）、当前行内容列水平中心（绿虚线,取自
行1「line 1」正常激活时 `mainTextLayer.frame` 的中心——注意这是内容列（去掉左右各
32px 留白后的可用宽度）的中心,不是字形本身的视觉中心，因为 `mainTextLayer` 的
frame 总是铺满整个可用宽度,与 `alignmentMode = .left` 无关）、三点实际中心（橙虚线+
红圈十字标）。"正常播放到前奏" 与 "seek 回前奏" 并排对照。

PNG：`research/repro-2026-09-14-lyrics-render/defect3-position-comparison.png`

| 场景 | 三点中心 (x, y) | 内容列中心 x | Δx（点−内容列中心） |
|---|---|---|---|
| A. 正常播放到前奏（t=0.2s，从未深入过） | (50.0, 377.0)px | 180.0px | **−130.0px** |
| B. seek 回前奏（先播到 t=33s 第5句,再 seek 回 t≈0.8s） | (50.0, 377.0)px | 180.0px | **−130.0px** |

两个场景数字完全一致——这与本节前面"未能端到端复现"的结论一致：这套 surface 级夹具
里,scrollToIndex/semanticIndex 分裂没有稳定重放出来,A/B 看不出差异。但这张图另外
坐实了一件独立的事：**不管是不是 seek 造成的，三点的横向位置本来就固定钉在
`x=50`（面板左边距 32px + 三点簇自身半宽 18px），比"内容列水平中心" 180px 靠左
130px**——`layoutDotContainer` 里 `dotContainerLayer.position.x = frame.minX +
totalWidth/2` 这个公式，本来就是"贴左边距摆"，不是"在内容列里居中摆"。这个左偏本身
是否是创始人说的"左上角"现象的（部分）来源、还是创始人截图里看到的另有其因（比如
未挖空的暂停帧、真机上不同的面板宽度使偏移比例更明显）,我不确定,需要创始人拿这张
图跟自己截图的真实比例对一下。

诚实说明一个复现局限：这张渲染图里没能清楚看到三点本身的灰色圆点（dotHidden=false、
dotOpacity=1.0、rowOpacity=1.0，标志位都对，但 8pt 的点在这个缩放下 / 逐点脉冲透明度
的某个瞬时相位下可能太淡看不清）——十字标记的是从真实 CALayer 树读出的精确坐标
（`CALayer.convert(_:to:)`，会正确带上行自身的 `positioningTransform`），不是我猜的。

---

## 修法方案（未动手，等创始人确认）

### 缺陷 1：给强调词补等价挖空 —— **已实施（下方为实施前方案，代码已落地，与实际改动一致）**

**改法**：复用 ce19929 已经建好的 hidden-range 机制（`applyFloatingHiddenBase` →
`attributedText(hiddenOrders:wordRuns:)` → `NativeLyricsHiddenTextMask.ranges` →
`attributedDisplayWrapped`），只扩大喂给它的 `floatingOrders` 集合，不新建机制。

当前（`applyActiveMainPhase`，`NativeLyricsRowView.swift:1550-1560`）：
```swift
let floatingOrders: Set<Int> = keepWholeLineDim
    ? Set(plan.wordRuns.enumerated().compactMap { order, run in
          (!emphasisOrders.contains(order) && run.baseFloatY != 0) ? order : nil
      })
    : []
```
`!emphasisOrders.contains(order)` 这个限定就是缺口——它把强调词整体排除在"该挖空"的判断
之外。改法是新增一个"强调词是否正在动"的判断，和现有"普通词是否在动"的判断取并集：

```swift
let floatingOrders: Set<Int> = keepWholeLineDim
    ? Set(plan.wordRuns.enumerated().compactMap { order, run in
          if emphasisOrders.contains(order) {
              // 强调动画的位移量（liftY/floatY）或缩放非零 = 正在动，需要把暗底这份
              // 挖空，否则 applyEmphasisGlyphLayers 画的浮动/缩放/发光副本会跟这份
              // 原地不动的暗底重叠成两层墨迹。amount==0（未进入强调窗口）时两者天然
              // 重合，不挖，保持跟普通词同样的"floatY==0 不挖"哲学。
              let isActiveEmphasis = run.emphasis.liftY != 0
                  || run.emphasis.floatY != 0
                  || run.emphasis.scale != 1
              return isActiveEmphasis ? order : nil
          }
          return run.baseFloatY != 0 ? order : nil
      })
    : []
```

`applyFloatingHiddenBase` 本身不用改——它已经是"给一组 order 挖空"的通用函数,只是之前
从没被喂过 `emphasisOrders` 里的值。`applyMainWordFloatGlyphLayers` 里
`for run in line.runs where !emphasisOrders.contains(run.order)` 这行也不用动——强调词
的可见渲染继续走 `applyEmphasisGlyphLayers`/`emphasisGlyphLayers` 那条已有路径,只是
现在它上面不再叠着一份没被挖空的暗底。

**为什么不会破坏中文行距测试（`NativeLyricsActiveLineSpacingTests`）**：
1. `NativeLyricsEmphasisEligibility.shouldEmphasize`（`NativeLyricsTextRenderPlan.swift
   :67-75`）里有 `if LanguageUtils.containsCJK(trimmed) { return false }`——中文文本
   永远不会进入 `emphasisOrders`。我的改动只对"已经在 `emphasisOrders` 里的 order"
   生效，对中文行是纯粹的 no-op，行距测试用的中文 fixture 不会碰到这条新分支。
2. 对英文行，改动只影响"挖空哪些 order"，不碰 `attributedDisplayWrapped` 的换行逻辑
   本身——挖空只是把对应字符的 `foregroundColor` 设成 `.clear`，字符本身、字体、宽度
   都不变，`attributedDisplayWrapped` 用的换行点来自 `wrapLineRanges`（对 RAW 文本
   算的，不看颜色），所以挖空更多 order 不会改变换行位置、行数、行高。这正是 ce19929
   自己在挖空普通词时已经验证过的性质（`NativeLyricsActiveLineSpacingTests` 在
   ce19929 那次改动后本来就是绿的，靠的就是这条性质）。

**验证方式**：
- 现有的 `test_emphasisWord_midSweep_dimBaseStillVisible_andGlyphOffset_ghostState`
  断言要反过来：`debugMainTextLayerIsWordHidden(order: 3, ...)` 从 `false` 改成
  `XCTAssertEqual(..., true)`，`maxDeltaY` 从 `XCTAssertGreaterThan(..., 1.0)` 改成
  `XCTAssertLessThan(..., 0.5)`（跟 ce19929 给普通词定的"Δy 从 2.0pt 到 0.0pt"是同一
  验收口径，强调词允许有一点残留因为 `applyEmphasisGlyph` 的 per-glyph charDelay 跟
  挖空的按词整体判断有几十毫秒的粒度差，不会是 0 但应该在 1pt 以内）。
- PNG 前后对照：重新生成 `defect1-emphasis-ghost-state.png`，应该跟
  `defect1-emphasis-clean-state.png` 一样干净。
- 全量跑 `NativeLyricsActiveLineSpacingTests` + `NativeLyricsSweepGhostTests` +
  `NativeLyricsEmphasisPartitionTests`（全强调行退化测试，改动碰的是
  `floatingOrders`/`emphasisOrders` 交界，这个测试最可能被误伤）确认绿。
- `swift build -c release --product MusicMiniPlayer` 过一遍发布门禁。

**实施结果（2026-09-14，与上面方案的差异只有验收指标本身的定义，代码改动一致）**：

跟原计划相比,验收指标做了一处必要修正——原计划打算直接量 `maxDeltaY`（强调层实际
位置 vs 几何静止位置）到 0，但挖空之后这个几何距离本身根本不变（强调层还是会浮动/
缩放到同样的位置，改动只是让暗底不再画在静止位置），所以 `maxDeltaY` 修复前后是同一
个数（约 3.26pt），不能拿它当"没有重影"的证据。改用 `effectiveGhostGapY`：暗底被挖空
时直接记 0（因为这时候只有强调层一份墨迹在画，没有第二份可比较），没挖空时才等于
`maxDeltaY`（两份墨迹都在画,才谈得上"偏移量"）。这个指标就是"量到 Δy=0"里创始人要的
那个 0——语义是"两份墨迹的可见间距"，不是"强调层离静止点多远"。

| 检查项 | 结果 |
|---|---|
| "about" 词中段 `dimBaseHidden` | `true`（修复前 `false`） |
| "about" 词中段 `effectiveGhostGapY` | **0.000pt**（accuracy 0.001，精确通过） |
| "about" 词起始瞬间 `effectiveGhostGapY` | 0.087pt（本来就小，修复前后都不构成可见重影） |
| `NativeLyricsActiveLineSpacingTests` | 4/4 绿 |
| `NativeLyricsSweepGhostTests`（ce19929 自己的回归） | 2/2 绿，Δy 仍 0.0pt |
| `NativeLyricsEmphasisPartitionTests` | 4/4 绿 |
| `NativeLyricsDimBaseContinuityTests` | 7/7 绿 |
| `NativeLyricsRenderDefects20260914ReproTests`（本文件测试） | 5/5 绿 |
| `swift build -c release --product MusicMiniPlayer` | 通过 |
| `swift test --filter NativeLyrics`（264 个） | 260 绿 / 4 红——4 个红是 `NativeLyricsRenderChurnTests.test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff`，已在纯 main（无关本次改动）上验证过同样失败，是预存问题非本次引入 |

一处附带发现：强调词的挖空判断用 `liftY != 0`，而 `floatY`（词内 sin 波动）从
`currentTime - wordStartTime + 0.4 > 0` 起就已经非零——也就是说词一开始（起始 +0.02s）
就已经满足"正在动"，`dimBaseHidden` 从原来预期的"onset 还没挖空"变成"onset 就已经挖空"。
这不影响正确性（onset 时几何本来就接近静止，挖不挖都看不出重影），但把
`test_emphasisWord_atWordOnset_...` 的断言口径从"验证具体的 hidden 值"改成了"验证
`effectiveGhostGapY` 够小"，避免测试跟这个提前几十毫秒的挖空时机耦合。

### 缺陷 2/3：`amllState` 的 scrollToIndex 补前奏窗口识别

**改法**：在 `NativeLyricsTimelinePolicy.amllState`（`LyricsPresentationModels.swift
:746-825`）里新增一个"当前播放时间是否落在某个前奏行自己的窗口内"的判断，在
`firstFutureIndex` 分支之前优先命中：

```swift
// 前奏行自己的窗口 [startTime, preludeEndTime)。落在这个窗口内时，scrollToIndex 和
// semanticIndex 都应该直接是这一行——不该像非前奏行那样走 hotGroups/bufferedGroups/
// firstFutureIndex 那套"谁在唱"的判断（前奏行本来就唱不了）。
let activePreludeIndex = sortedRows.first { row in
    row.isPrelude
        && playbackTime + lineAdvanceEpsilon >= row.displayLine.line.startTime
        && playbackTime < row.preludeEndTime - lineAdvanceEpsilon
}?.index

let scrollToIndex: Int
if let firstBuffered = bufferedGroups.subtracting(backingIndices).min() {
    scrollToIndex = firstBuffered
} else if let activePreludeIndex {
    scrollToIndex = activePreludeIndex
} else if isSeeking, let firstFutureIndex {
    scrollToIndex = firstFutureIndex
} else {
    scrollToIndex = previous?.scrollToIndex ?? latestStartedIndex
}

let semanticIndex = hotGroups.subtracting(backingIndices).max()
    ?? bufferedGroups.subtracting(backingIndices).max()
    ?? activePreludeIndex
    ?? latestStartedIndex
```

`semanticIndex` 那行加 `?? activePreludeIndex` 是防御性的——生产路径下
`LyricsService.updateCurrentTime` 已经会把喂给 `fallback` 的值正确设成 0，
`latestStartedIndex` 本该已经等于前奏行索引；但让 `amllState` 自己也认得前奏窗口，
就不再依赖调用方"记得"这件事，函数自洽。

**这只是候选修法，不是已验证的根因**：函数级测试（本报告"已确认"一节）证明了
`scrollToIndex` 分裂确实存在、确实是这段代码的逻辑缺口；但端到端没能稳定复现（"未能
端到端复现"一节），所以我不能保证改了这里就解决创始人报的"三点完全不出现"。这段代码
本身值得修（它是个真 bug，`scrollToIndex` 和 `semanticIndex` 不该在有明确定义行为的
输入下分裂），但它是否是 defect 2 的**唯一**或**主要**原因还不确定。

**验证方式**：
1. 单测：把
   `test_amllState_backwardSeekIntoPreludeWindow_withCorrectFallback_scrollTargetStillDivergesFromSemanticIndex`
   的断言从"证明分裂"改成"证明不再分裂"——`XCTAssertEqual(result.scrollToIndex, 0)`、
   `XCTAssertEqual(result.scrollToIndex, result.semanticIndex)`；
   `test_amllState_backwardSeekIntoPreludeWindow_withStaleFallback_staysOnStaleIndex`
   同样反过来断言——`fallback=5` 这种"调用方没重置"的场景现在也应该被
   `activePreludeIndex` 兜底救回 0，不再依赖调用方传对 fallback。
2. 新增回归：一个 `playbackTime` **不**落在任何前奏窗口内的正常远距离 seek（比如从第2句
   跳到第8句），确认 `firstFutureIndex` 分支还能正常命中，新分支没有误伤正常 seek。
3. 端到端：重跑 `test_hostedSurface_deepPlaybackThenSeekToPreludeWindow_dotsVisibleButMisanchored`，
   看 `scrollTargetAfterSeek` 是否稳定等于 `semanticAfterSeek`（这个测试目前是非失败的
   诊断打印,不是断言,因为我这次没能让它稳定复现分裂——改完后如果这里依然打印
   "CONVERGED"，只能说明我的合成夹具从头到尾都没能重现分裂窗口,不能当作"defect 2/3
   已解决"的证据）。
4. **手感终验仍然需要创始人亲自做**：这条路径的最终验收是"真机上 seek 回歌曲开头,三点
   动画正确出现在屏幕居中位置"，自动测试通过不能替代（项目 2026-08-21 永久规则）。建议
   修完后我先给出这些单测的绿/红对照，你再挑一首真实前奏歌在真机上验一次。

---

## 缺陷「滚动后整叠歌词位置再跳几像素」（研究编号 Symptom 3）—— 已复现，**已修复（创始人批准）**

**修复状态更新（2026-09-14）**：创始人批准按根因修——让首次测出的真实行高在同一个
configure 周期内进入定位。已实施,过程中发现并纠正了自己复现方法里的一个测量错误
（见下方"修复过程中的一个自我纠正"），最终用两个干净测试确认修复生效。

### 修法（已实施）

在 `LyricsLayerRendererView.reconcileVisibleRowViews` 里，内容测量循环（会把新测出的
真实行高写进渲染器自己的 `measuredHeightsByIndex`）结束后、定位循环开始前，插入一次
`accumulatedHeights` 重算——直接复用已有的 `NativeLyricsHeightAccumulator.accumulatedHeights(...)`
（这个函数本来就优先用 `measuredHeightsByIndex` 里的真实值,只是第一次调用发生在内容
测量循环**之前**,吃的是上一轮的旧值）。同时发现：自然滚动模式下真正的定位读的是
`presentationEngine.presentation(for:).y`（弹簧状态），而弹簧的目标是 `configure()`
更早时候用**同一份旧 accumulatedHeights** 调 `presentationEngine.update(...)` 定下的——
只修 `accumulatedHeights` 本身不够，弹簧目标要跟着重算。所以补了第二步：高度真的变了
才（`heightsActuallyChanged` 门控，避免空转）重新调一次 `presentationEngine.update(...)`，
用刚修好的 `accumulatedHeights`。两步都只在 `configure()` 真正触发时跑一次（不是每帧
presentationTick 都跑），不引入 `scroll.lastVelocity` 那种每事件写死字段触发整树重布局
的坑。

### 修复过程中的一个自我纠正

第一次用 a73c556 的追踪用例反向断言时，`events.count` 死活还是 4，数字跟修复前一模
一样。查下去发现：我复现阶段用来读"行的屏幕 Y"的 `debugModelY`（`layer.affineTransform().ty`）
在当前架构下**不是位置**——代码注释写得很清楚："The transform now carries ONLY scale —
never translation"，真正的位置由 `view.frame.origin.y` 直接承载（`applyFrame` 直接赋值
`view.frame`，不经过弹簧）。也就是说 a73c556 那次复现读错了通道：它测到的"-1.02/-2.32px"
其实是缩放补偿量随"离当前行距离"变化的正常波动，跟高度缓存过期没有关系——两次尝试
（先补 snapY，再补 presentationEngine 二次 update）都对这个数字毫无影响，这是我发现读错
通道的直接线索。换成 `frame.minY` 重测后，原 30 行用例的整叠同步跳变确实变成了 0。

### 验证（两个测试）

1. `test_symptom3_afterFix_noReflowSnap_heightLandsInSameCycle`（原 a73c556 的追踪用例，
   反向断言，改用 `frame.minY`）：130 个 configure 周期，**0 次整叠同步跳变**（修复前 4 次）。
2. `test_symptom3_afterFix_isolatedHeightJump_rowLandsImmediately`（新增，隔离验证）：
   `current` 全程冻结在行 0（排除滚动/新挂载的干扰），行 1 在 tick 5 从短句换成会换行成
   3 行的长句（真实内容变化，不是新行首次出现）。行 2 的 Y 在内容变化**同一个 tick** 就已经
   是 300.00→468.31pt（settled 值 468.00，容差 0.6pt 内），不是下一 tick 才追上。

两个测试都在提交前临时禁用过修复代码验证过会红（防止测试本身没测到东西）。

| 检查项 | 结果 |
|---|---|
| 130 周期整叠同步跳变数 | **0**（修复前 4） |
| 隔离用例：内容变化同一 tick 是否到位 | 300.00→**468.31**pt（settled 468.00，Δ0.31pt） |
| `test_symptom3_afterFix_noReflowSnap_heightLandsInSameCycle` | 绿 |
| `test_symptom3_afterFix_isolatedHeightJump_rowLandsImmediately` | 绿 |
| `LyricsRenderDefects20260914ReproTests`（全部 9 个） | 9/9 绿 |
| `swift test --filter NativeLyrics`（264 个） | 260 绿 / 4 红——同一批 `NativeLyricsRenderChurnTests` 预存失败，与本次改动无关（本 session 更早已在纯 main 上验证过） |
| `swift build -c release --product MusicMiniPlayer` | 通过 |

原来 `research/references/nanopod-defects-2026-09-12-spec.md` 记录的"整叠同步跳"
录屏证据本身不受影响——那是真机真实录像，这次只是我自己复现工具选错了读数通道，
根因诊断（两跳 async 导致 accumulatedHeights 落后一个周期）没有变，只是最初的自动化
验证方法有缺陷，已经在同一个 PR 里连诊断带修复一起纠正了。

创始人描述：「每一次上一行就会又位移一下几个像素」。已有证据在 main：
`research/references/nanopod-defects-2026-09-12-spec.md` Symptom 3——真实录屏里所有可见行
静止 6-170ms 后同一帧整体 +1~6px 刚性跳动，全片 26 次同类簇，f672/f1044/f1503/f1719/f1763
为典型。协调方给的上一轮嫌疑：`LyricsLayerRendererView.swift` 约 1578-1589 行的
`onHeightMeasured` 延迟到下一 run loop 才回填。

### 根因追踪（直接读代码，不是猜）

`updateContentIfNeeded`（`LyricsLayerRendererView.swift:1560-1590`）：一行的高度被
（重新）测量时，渲染器自己的 `measuredHeightsByIndex[row.index]` 同步更新（影响这一帧
它自己的内部记账），但真正通知外部（SwiftUI `LyricsView`）的
`configuration.onHeightMeasured(row.index, height)` 包在
**`DispatchQueue.main.async` 里**——至少推迟一个 run loop 轮次。

`LyricsView.swift:1102-1108` 收到这个回调后：`cache.lineHeights[index] = height`，再调用
`scheduleHeightCacheUpdate()`（`LyricsView.swift:2407-2416`）——这个函数**又包了一层
`DispatchQueue.main.async`**，才真正调 `updateHeightCache()` 去重算
`accumulatedHeights`、触发 SwiftUI 重渲染、把新的 `accumulatedHeights` 传回渲染器的下一次
`configure()`。两跳异步。

同时，行的**实际定位公式**——`NativeLyricsSnapMath.targetY`
（`LyricsPresentationModels.swift:974-988`，被 `snapY`/`applyFrame` 直接调用，验证过是唯一
定位入口）——完全只吃外部传入的 `configuration.accumulatedHeights`：
`y = anchorY - accumulatedHeights[targetIndex] + accumulatedHeights[rowIndex]`，从不看渲染器
自己的 `measuredHeightsByIndex`。

结论：一行高度被首次测量后（最常见触发：滚动时一行首次进入可见窗口，测出的真实高度和
36pt 占位默认值不一样），**至少多出一个 configure 周期**，`accumulatedHeights` 对这行
下面的所有行来说还是旧值（占位符）——直到两跳异步落地，`accumulatedHeights` 一次性改
过来，这行下面**所有行的累计 Y 在同一帧一起跳一个相同的量**。这正是"刚性同步跳动"
的机制,不是"某一行自己没测准"。

### 复现方法

真实 `NativeLyricsSurfaceView` + 30 行歌词（长短交替，制造与 36pt 占位默认值有真实差异
的实测高度）。不用真的 `DispatchQueue.main.async`（在同步 XCTest 循环里时机不可控），
而是用一个本地 `pendingHeightUpdates` 队列**确定性地**模拟同一个结构性延迟：
`onHeightMeasured` 回调只把 `(index, height)` 存进队列，队列只在**下一次** tick 开始时才
被灌入外部高度缓存——即 tick N 测到的高度，只有 tick N+1 的 `accumulatedHeights` 才反映
出来，跟真实两跳异步造成的"至少晚一个 configure 周期"效果一致。每个 tick 内部再让
presentation spring 真正跑满（30 个 1/60s 子帧）后才采样每行 `debugModelY`，避免把"弹簧
还没转到位"跟"外部数据晚到导致的跳变"混在一起。

### 结果

130 个 configure 周期里找到 **4 次**符合"≥2 行同帧同向跳变、跳变前静止 ≥3 帧"的整叠
同步事件（用跟 spec 原文一致的判定口径）：

| tick | 一起跳的行 | Δy(px) | 跳前静止帧数 |
|---|---|---|---|
| 4 | [0, 1] | +1.09, −2.46 | 3, 3 |
| 8 | [1, 2] | +2.46, −1.06 | 3, 7 |
| **11** | **[10,11,12,13,14,15,16,17,18,19,20,21]（12 行）** | **交替 −1.02/−2.32** | **全部 10** |
| 12 | [2,3,...,9,22,...,29]（16 行） | 交替 +1.06/−1.02/−2.32 | 3, 11×15 |

tick=11 这次最干净：12 行整整齐齐静止 10 帧（同一个数值,逐帧比对无差异),然后同一帧
一起跳，跳变量在两个固定值间交替（−1.02px / −2.32px，对应我 fixture 里两种交替行文本
实测高度和 36pt 占位默认值的差）——跟 spec 描述的"全片 26 次,≥2 行同向,静止后同帧跳"
一字不差地吻合。

PNG（折线图，直接画 `debugModelY` 原始追踪数据,不经过 CALayer 渲染）：
`research/repro-2026-09-14-lyrics-render/symptom3-reflow-snap-chart.png` —— 两条追踪线
（行10橙/行11品红）完全水平重合 10 个 tick，在标红的跳变 tick 同帧一起跳升,清晰可见。

**诚实说明一个复现局限**：coordinator 要的"跳前/跳后两帧叠加或差分"截图
（`symptom3-reflow-snap-before-after.png`）没能出：把 `CALayer.render(in:)` 结果裁到
对应行的 Y 附近,画面是纯黑,没有渲染出文字——`rowOpacity=1.0`/`mainTextHidden=false`
标志位都正常,不是行被隐藏了,原因没查清（可能是这套最小 fixture 里某些几何/reveal-gate
条件和真实 App 场景不同，导致 CALayer 树虽然存在但没有实际绘制内容）。这不影响上面的
数字结论——数字直接来自 `debugModelY`（真实的、已提交的 CALayer transform 值,不是猜的）
——但视觉截图这块留了一个没解开的疑点，如实报告，不掩盖。

**这是复现，不是修复**：本节到此为止，没有改任何生产代码。

---

## 缺陷「逐字歌某行突然整行全亮，随后回到逐字」—— 未能复现，给出埋点方案

创始人今天再次确认这个现象存在。上一轮 WT-B 用 7 首逐字歌锁步驱全部切行，
`debugLastWholeLineHighlight` 标志位全程 0 次为真（见
`research/references/nanopod-defects-2026-09-12-spec.md`），没能复现。本轮按协调方指示，
在 3 之后专门试了"行复用/回收"这条此前没试过的路径，外加真 display-link 抖动、长停滞后
追赶的变体。

### 复现尝试

`debugLastWholeLineHighlight`（`NativeLyricsRowView.swift:1449-1452`）为真的精确条件：
当前行**应该**走逐字扫掠（`expectsPerRunSweep`，即 `hasSyllableSync`），但
`applyActiveMainPhase` 里 `updatePerRunSweepMask` 返回 `applied=false`（尽管
`geometryReady` 已经是 true），同时亮层没被隐藏、确实在画——也就是退化成了 v2.8 那种
"整行渐变遮罩"而不是逐字遮罩。这精确对应"看起来整行一起亮"的症状。

针对性设计：60 行歌词，单行短语（"hey now"）和会在窄面板换行成 3 行的长句
（"every single word you ever said to me still echoes down this empty hallway
tonight"）交替排列——制造行视图从池里复用时，前后两次内容几何形状差异最大的场景。
20 次远距离 seek（`radius=14`,跳跃幅度 >28 保证彻底逐出复用池)反复横跳在这两种几何
之间，强迫视图池不断把一种几何的视图直接复用成另一种。每次 seek 后：
- 采样点选在行**中段**（不是行首瞬间——那时亮层本来就因 progress≤0.001 被隐藏,不会
  触发这个标志位,不管有没有复用问题）；
- 12 个不均匀间隔的子帧（1/30s~1/60s 抖动,模拟真实 display-link 不是严格等距的可能性）；
- 每个子帧扫描 seek 目标行 **及其前后各 2 行**（不只是目标行本身——万一是被复用挤出去的
  邻居行出问题）。

### 结果：未复现

0 次 `debugLastWholeLineHighlight=true`。这条"行复用"路径这次也没能触发。跟 WT-B 的
7 首歌 0 次结论一致——本轮又排除了一个可能路径（复用+抖动组合），但仍然不能说"没有
这个 bug"，只能说这次没抓到。

### 埋点方案（按创始人要求，穷尽后给出）

不需要新建——**已经有一套现成的、符合要求的埋点在代码里**：`NativeLyricsMaskTrace`
（`NativeLyricsLayerSupport.swift:214-261`，2026-08-27 落的）。逐帧调用点就在
`debugLastWholeLineHighlight` 计算的同一处（`NativeLyricsRowView.swift:1453-1460`），
两者共享同一次判断——只要真机上真的翻了一次 `wholeLineHighlight=true`，这套埋点结构上
保证能记到，不依赖我这边有没有复现出触发条件：

- **只在状态变化时写一行**（`key = "\(rowID)|\(wordIndex)|\(wholeLineHighlight)|\(perRunSweep)"`
  跟上一条比对，没变就不写），不会把日常使用写成几百 MB。
- 写到 `/tmp/nanopod_mask_trace.jsonl`，JSONL 格式，每行一个事件：
  `{"event":"mask_state","row":"...","word":N,"wholeLineHighlight":true/false,"perRunSweep":true/false,"expected":0.xxx,"applied":0.xxx}`。
- 默认不武装：需要 `NANOPOD_MASK_TRACE=1` 环境变量，或者是 `LOCAL_DEVELOPER_BUILD`
  才会写。生产 release 默认零 I/O。

**使用方法**：创始人日常用的时候，用 `NANOPOD_MASK_TRACE=1 open nanoPod.app`（或等效的
带环境变量启动方式）跑一遍，下次真的看到"某行突然整行亮一下又回去"，直接去
`/tmp/nanopod_mask_trace.jsonl` 翻最后几行——`wholeLineHighlight` 从 `false` 翻到
`true` 再翻回 `false` 的那几行,连着 `row`/`word`/`expected`/`applied` 数字，就是这次
真实发生时的第一手证据,比我在 headless 里瞎猜条件要可靠。我这边没有改这套埋点的代码
（本来就在),只是确认了它接的是正确的判断点、默认关闭不会拖累性能。

**这是复现尝试 + 埋点确认，不是修复**：本节没有改任何生产代码。

### UserDefaults 开关（2026-09-14，创始人批准，已实施）

创始人指出：从 Finder 启动 app 没法传环境变量，`NANOPOD_MASK_TRACE=1` 这套用不上。
补了第二个武装入口——`NanoPodMaskTraceEnabled` UserDefaults 键，**release 也生效**
（原来整个 `NativeLyricsMaskTrace.record` 函数体和它在 `NativeLyricsRowView.swift`
里的调用点都包在 `#if DEBUG || LOCAL_DEVELOPER_BUILD` 里，纯 release 编译后这段代码
根本不存在——这次把调用点挪到编译条件外面，`wordIndex`/`wholeLineHighlight` 在外面
重新用本地变量算一遍，不读 DEBUG-only 的 `debug*` 存储属性），默认关、零 I/O（挡在
`UserDefaults.standard.bool(forKey:)` 判断之前，没到这一步不会碰文件），输出路径不变
（`/tmp/nanopod_mask_trace.jsonl`）。

**用法**：`defaults write <bundle-id> NanoPodMaskTraceEnabled -bool YES`，然后从 Finder
正常打开 app，不用终端启动、不用环境变量。

**验证**：`test_maskTraceUserDefaultsSwitch_armsTraceAndWritesExpectedLine`——设置这个
UserDefaults 键后驱动一次真实的逐字行 `updatePlaybackPhase`，确认
`/tmp/nanopod_mask_trace.jsonl` 真的被写入、格式正确；
`test_maskTraceUserDefaultsSwitch_defaultOff_writesNothing`——不设置该键、没有环境变量时
确认文件完全不被创建。两个测试都绿。`LyricsRenderDefects20260914ReproTests`（全部 12 个）
12/12 绿；`swift test --filter NativeLyrics`（264 个）260 绿 / 4 红（同一批预存失败）；
`swift build -c release --product MusicMiniPlayer` 通过（确认 release 配置下也能正确编译
并触达这条新武装路径）。

---

## 三点缺陷澄清：三条进入前奏的路径不一致（2026-09-14，创始人澄清后重新复现）—— 已复现，未修

创始人纠正了我对"三点缺陷"的理解：**不是"三点一直贴左"**（那条已经在上面修完，Δx=0）。
真实现象是——歌曲刚开始时三点是对的（居中、有动画）；**手动滚动回到开头**或**点击从头播放
（seek 到 0）**之后，三点要么不出现，要么位置/状态跟最开始不一样。也就是说，**同一个前奏行，
走了不一致的三条入口路径**。

### 复现方法

真实 `NativeLyricsSurfaceView`，同一套 6 行歌（前奏+5句），三种进入方式：

- **A. 冷启动**：全新 surface，直接跳到前奏窗口（t=0.2s），从未播放过其他内容。
- **B. seek 回前奏**：先播到 t=33s（第5句），再显式 seek 回 t≈0.5s（前奏窗口内）。
- **C. 手动滚回前奏**：播到 t=33s（第5句，播放钟继续停在这里，不 seek），然后模拟用户
  手动滚动——新增一个复现专用的调试接口
  `NativeLyricsSurfaceView.debugBeginManualScroll(frozenAt:)`（真实滚轮 NSEvent 没法在
  headless 里伪造，项目里已有的 `debugBeginManualScroll()` 只能冻结在"当前"位置，办不到
  "滚到指定行"，所以加了这个参数化版本，只是让测试能冻结到任意行，不改变任何生产行为）
  把滚动状态冻结在行 0。

### 结果：A、B 一致，C 不一致

| | A. 冷启动 | B. seek 回前奏 | C. 手动滚回前奏 |
|---|---|---|---|
| 三点是否隐藏 | `false`（显示） | `false`（显示） | **`true`（隐藏）** |
| 三点不透明度 | 1.0 | 1.0 | **0.0** |
| 三点中心 x | 180.0px | 180.0px | **171.0px**（偏离内容列中心 180px，Δ9px） |
| 三点是否在动画（连续两帧透明度变化） | 否（采样窗内本来就稳定，非负面信号） | 否 | 否 |
| 整行本身的 opacity（`debugRowLayerOpacity`） | 1.0 | 1.0 | **0.6** |
| 行的屏幕 Y（`frame.minY`） | 200.0 | 200.0 | 200.0（一致，Y 没问题） |
| `semanticIndex` | 0 | 0 | 0 |
| `scrollTargetIndex` | 0 | 0 | 0 |

**A 和 B（冷启动、seek）读数完全一致**——跟我在"缺陷 2/3"一节里用production-accurate
fallback 复现出的结论一致：只要 `semanticIndex`/`scrollTargetIndex` 都正确解到 0，
前奏行就会正确显示、居中。**C（手动滚动）明显不同**：整行 opacity 只有 0.6（不是激活行该有
的 1.0）、三点整体隐藏（opacity 0）、三点位置也有 9px 偏差——即使 `semanticIndex`/
`scrollTargetIndex` 两个数字本身都显示 0（看起来"对"），行的视觉状态和三点动画机制根本没有
被正确驱动。

PNG（三张并排）：`research/repro-2026-09-14-lyrics-render/prelude-three-entry-paths.png`
（红圈十字标始终标出三点的几何中心，不管当时是否可见——C 图里能看到标记明显偏离面板
中心参考线，且当时 dots 处于隐藏状态）。

### 目前查到的机制线索（未完全坐实，未修）

`shouldDriveTextPhase`（决定是否调用 `updatePlaybackPhase`，从而驱动三点动画/亮度）的
判断条件是 `row.index == effectiveTextActiveIndex == effectiveCurrentIndex`。手动滚动时
`effectiveCurrentIndex` 正确优先读 `nativeManualScrollSnapshot?.frozenDisplayIndex`（=0，
我验证过这个字段本身没错）。但驱动"整行是否算作 hot/active"的**是另一条独立通路**——
`nativeHotActiveIndices`/`nativeBufferedActiveIndices`，这两个集合由
`synchronizeNativeSemanticIndex`（根据 `amllState`/播放时钟算出"谁在唱"）填充，我还没有
确认这条通路在**手动滚动激活时是否也读了冻结索引，还是仍然按原始播放时钟计算**——如果
是后者，效果会正是我测到的样子：手动滚到前奏时，`hotGroups` 依然是 `{5}`（因为音乐还在
第5句），行 0 永远拿不到"当前行"该有的 1.0 opacity 和三点驱动，即使 `effectiveCurrentIndex`
本身正确显示 0。这是一个有依据、但还没有用代码直接验证到底的假设——按创始人"先复现报我
再修"的规矩，如实标注为"未完全坐实"，不当成已确认的根因。

**这是复现，不是修复**：新增的 `debugBeginManualScroll(frozenAt:)` 是纯只读复现工具
（`LyricsLayerRendererView.swift`，`#if DEBUG` 块内），本节没有改任何生产行为。

---

## 缺陷「逐字歌整行全亮」续（2026-09-14，创始人要求换真实时钟方法）—— 准备工作完成，真实时钟复现尚未开始

创始人补充：播一首节奏快一点的逐字歌基本都能复现，他 09-12 的录屏里就有实锤
（Symptom 2，大橋純子那首，f1053 整行首帧即亮、随后 2.9s 恒亮无梯度）。锁步复现（本文件
`test_wholeLineFlash_rowReuseAcrossMismatchedGeometry_fastDistantSeeks`，以及此前 WT-B
的 7 首歌全切行扫描）0 次命中，说明锁步这套方法本身丢失了真实运行时的某个条件——要求
换成**不用锁步**、真实 CVDisplayLink + 真实墙钟 + 连续 1x 播放钟，播满 60-120s 真实时长，
逐帧写 JSONL，用大橋純子那首和缓存里最快的 3 首逐字歌。

### 已完成：从真实缓存里找到全部 4 首目标歌

`~/Library/Application Support/nanoPod/lyrics_cache.json`（216 条缓存,3.2MB）+
`metadata_cache.json`（title/artist 映射,不同哈希空间,靠歌词内容首行文本交叉核对）：

| 歌曲 | 缓存 hash（lyrics_cache.json） | 行数 | 总音节数 | 平均音节时长 | 备注 |
|---|---|---|---|---|---|
| 大橋純子「水玉模様の傘」 | `4ac42fd65a7f7f7dbcb7cac717cfceb9c79548627476d05eb62660b78204eacf`（同内容还有 2 个重复哈希：`91419f15...`、`dbf4a989...`） | 23 | — | ~0.5-0.6s/字 | 创始人指名的那首,`kind=synced`,逐字（每假名/汉字一条 word),225s,与录屏描述的"23 行 YRC 逐字"吻合 |
| 最快 #1「How's about your company this evenin'」 | `c0c6f4a109d7a3fa5f5b3a9d7a0b05804b717ddd6412a1bd180ef78f0398d0f7`（另有 2 个重复哈希） | 85 | 449 | **0.406s** | 357s,全库最快 |
| 最快 #2「生份的 遥远的歹势细腻」 | `2e9d901f619400b35ffb8af96914a419b6334812329bde244755ca32d5bdef1f`（另有 2 个重复哈希） | 39 | 310 | 0.430s | 闽南语/国语 |
| 最快 #3「仍然记得个一次 风里相依」 | `9e95e15c0d104cbfffda520dbd5af4a8e4180ee2d9c16f9e3db8351e833d7c8b`（另有 1 个重复哈希） | 27 | 236 | 0.446s | 中文 |

（"另有 N 个重复哈希"是同一份歌词内容在缓存里存了多份——不同解析路径/时间点写入的，
内容一致，用哪个都行。)

### 尚未做：真实 CVDisplayLink + 墙钟复现

这条方法论上跟本次会话其余所有测试都不同——此前全部测试用 `debugNowOverride`/
`debugTick` 锁步驱动（确定性、但正是创始人怀疑"丢条件"的那套方法)；这次要求**不设**
`debugNowOverride`（surface 自己的 `CVDisplayLink` 用真实 `CACurrentMediaTime()`）、
播放钟按真实 1x 速率连续推进（不是逐帧跳），整首播 60-120 秒真实挂钟时间，期间每帧
采样 `debugLastWholeLineHighlight`/亮暗 tile 计数/每行 sweep progress 写 JSONL。

没有在本轮做的原因：这是一套全新的测试方法（真实定时器/真实后台线程回调,需要处理
XCTest 主线程与 CVDisplayLink 回调线程之间的状态读取,还要对 4 首歌各跑 60-120 秒
真实时间,即 4-8 分钟纯等待)，独立于本轮已完成的三个修复和已复现的三点路径不一致问题；
草率在本轮末尾赶工容易做出一个有竞态/误判的复现工具，产出不可靠的"复现"结论——这类
真实时序 bug 的方法论本身就是创始人这次要验证的东西，值得单独认真做一次，不该压缩在
已经很长的这轮末尾。

**建议**：作为下一轮的第一件事单独做，方法已经定好（真实 4 首歌哈希、真实 CVDisplayLink
不设 override、JSONL 逐帧），不需要再花时间调研，可以直接动手搭建。

---

## 协调者三问 + C 路径修复（2026-09-14 第二轮）

### 0. Symptom 3 根因修复：已做，提交号是 b12db38（漏报，非漏做）

上一次汇报的三个哈希列表里漏掉了这一条，实际代码在这之前就已经落地并验证过：
`test_symptom3_afterFix_noReflowSnap_heightLandsInSameCycle`（`Tests/MusicMiniPlayerTests/
LyricsRenderDefects20260914ReproTests.swift:1104`）本来就是 130 周期、events.count==0 的
反向断言（`XCTAssertEqual(events.count, 0, ...)`，第 1226 行），提交 b12db38 就已经把这个
测试从红改绿。本轮重新单独确认：working tree 干净（无未提交改动），HEAD 状态下该测试单跑
仍是绿的。不需要补做，只是我上次汇总哈希时漏列了这一条，特此更正。

### 1. fca3ef2（三点水平居中）是否多余：不多余，冷启动本来就是错的

在 fca3ef2 的父提交 b12db38（即没有居中修复的状态，等价于 c66cff1 在三点定位上的行为，
因为中间的 Symptom3/强调词修复都不碰三点定位代码）上，重新跑
`test_defect3_annotatedPositionComparison_normalVsSeekBack` 这条真实测试（未改任何代码，
纯粹切到旧提交跑已有测试），控制台原始输出：

```
[Defect3-diagram] A (normal): dotCenter=(50.0, 377.0) textCenterX=180.0
[Defect3-diagram] B (seek-back): dotCenter=(50.0, 377.0) textCenterX=180.0
```

"A (normal)" 就是冷启动场景（"从未深入歌曲，第一次到达前奏窗口"）——冷启动的三点中心 X
是 **50.0**，不是 180.0，和"seek 回前奏"场景完全一样，都是左边距（Δx=-130）。也就是说
创始人记忆中"冷启动是对的"这一点，指的应该是三点存在、在动这些其它维度，不是水平居中——
横向居中这一项冷启动此前也是错的，fca3ef2 修的是真问题，不是多余改动，保留。

### 2. 【已修复】C 路径（手动滚回前奏）根因 + 修复 + 验证

**根因**（直接读代码 + 加临时探针确认，非推测）：三条路径的 index 解析实际上完全一致——
A/B/C 的 `semanticIndex`/`scrollTargetIndex` 打印出来都是 0/0，不存在"分裂"。真正分裂的
是**相位时钟**（phase clock，驱动三点淡入淡出、逐字扫掠这些"随时间变化"的动画数值）：

- `synchronizeNativeSemanticIndex`（`LyricsLayerRendererView.swift`）在任何非 natural 播放
  模式（explicit seek / tap / **手动滚动** 等）下，都会把 `nativeRenderClock`（相位时钟）
  重置为 `musicController.lyricRenderTime()`——即"真实播放进度"。
- 对explicit seek 这完全正确：seek 本身就是让真实播放进度跳到新位置，相位时钟跟着跳
  是对的。
- 对手动滚动是错的：手动滚动时真实播放没有停（音乐还在 t=33s 继续播），只是**显示**冻结
  到了用户滚到的那一行（比如前奏行，它自己的 `[startTime, preludeEndTime]` 窗口早就是
  t=0~2s 左右，远早于 t=33s）。相位时钟被设成真实的 t=33s 后，三点的淡出计算
  （`NativeLyricsDotPhasePlan.make` 里 `currentTime >= endTime → fadeOutProgress=1`）
  认定"这一行的三点窗口早就结束了"，于是整体透明度算成 0——三点消失，不是因为 index 错，
  是因为算三点动画用的"现在几点"这个输入本身就是错的参照系。

**修复**：`LyricsLayerRendererView.swift`
- 新增 `lastManualScrollPhaseAnchorIndex` 记录相位时钟上一次是为哪个冻结行锚定的。
- `nativePhaseClock` 闭包：手动滚动冻结期间不再跟踪真实播放钟，只读已锚定的
  `nativeRenderClock`（原来的实现会在下一次读取时用 `max(previous, raw)` 把手动滚动的
  锚定值立刻冲回真实播放钟——这是根因的第二层，本身也修了）。
- `synchronizeNativeSemanticIndex` 非 natural 分支：手动滚动**首次**冻结到某一行时，把
  相位时钟锚定到**那一行自己的 startTime**（等价于"刚 seek 到这一行"），而不是真实播放
  时间；同一行持续冻结期间复用已锚定的值，不会每帧重新归零；explicit seek / tap /
  reduced motion / initial layout 这些其它非 natural 场景完全不受影响，仍然用真实播放钟
  （对它们是对的）。

这样手动滚回前奏和 seek 回前奏、冷启动走的是**同一条相位锚定逻辑**——即创始人要求的
"同一套呈现入口"，不是给手动滚动单独打一个 fallback 补丁。

**验证**（`test_threePreludeEntryPaths_coldStart_seekBack_manualScrollBack`，真实测试跑出）：

| 路径 | 三点隐藏 | 三点透明度 | 三点中心 X | semanticIndex | scrollTargetIndex |
|---|---|---|---|---|---|
| A 冷启动 | 否 | 1.0 | 180.0 | 0 | 0 |
| B seek 回前奏 | 否 | 1.0 | 180.0 | 0 | 0 |
| C 手动滚回前奏（修复前） | **是** | **0.0** | 171.0 | 0 | 0 |
| C 手动滚回前奏（修复后） | 否 | 1.0 | 171.0 | 0 | 0 |

三点隐藏/透明度已经和 A/B 完全一致。

**两个仍未处理的残余差异，未动，专门标出等裁决**（都不是这次改的代码引入的，是修复前
就已经存在的、和三点本身无关的另一套设计）：

1. **行 opacity**：C 路径读数是 0.6，不是要求的 1.0。查到这是 `NativeLyricsVisualTarget`
   里一条 2026-07-12 就有的既有设计——手动滚动期间（不管冻结到哪一行，也不管是不是当前
   播放行）**所有**行统一淡到 0.6、缩到 0.95（代码注释原话："Manual scroll lifts it to
   the all-clear 0.6 tier so the hot row reads like its neighbours"），用来在"正在滚动
   浏览"时给一个统一的视觉提示，不是针对前奏行或三点的特殊处理，也不是这次两个 bug
   （强调词重影、三点位置/路径不一致）引入的。真要让 C 路径行 opacity 也读 1.0，等于
   改掉这条已有的、独立的手动滚动视觉设计，我没有擅自动——需要你确认这条 0.6 设计本身
   是否也要改，还是只要求"当前冻结到的这一行"破例保持 1.0（后者是一个新的、有意的
   例外规则，需要专门设计，不是顺手就能做的小改动）。
2. **三点中心 X**：C 路径是 171.0，不是 180.0。这也是上面同一个 0.6/0.95 手动滚动设计
   的连带效果：手动滚动时每一行的整层都会缩放到 0.95，而缩放是绕着行自身的 anchorPoint
   做的，不是绕内容列中心——180 × 0.95 = 171.0，数字对得上，说明这不是三点定位公式本身
   的问题（`layoutDotContainer` 的 `frame.midX` 公式没变），是手动滚动统一缩放这条已有
   设计在坐标换算上的副作用，同样对所有行一视同仁，不只是前奏行/三点。

三联图（A/B/C 侧边对比，含隐藏/透明度/行 Y/semantic/scrollTarget 标注）已重新生成：
`research/repro-2026-09-14-lyrics-render/prelude-three-entry-paths.png`

**测试与构建**：`LyricsRenderDefects20260914ReproTests` 全量 13/13 绿；`NativeLyrics` 前缀
全量 264 个测试，4 个失败，和 fca3ef2 提交时已确认的 `NativeLyricsRenderChurnTests` 里同一
个预先已知失败（`test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff`）完全一致，
不是这次改动引入的新回归；`swift build -c release --product MusicMiniPlayer` 通过。

---

## 整行全亮真实时钟复现（2026-09-14 第二轮，message A）——仍未复现，附精确定位下一步

### 方法：真 CVDisplayLink + 真墙钟，不用锁步

新增 `Tests/MusicMiniPlayerTests/LyricsWholeLineFlashRealTimeTests.swift`。核心区别于本轮之前
所有测试：**完全不设** `surface.debugNowOverride`、**不设** `mc.debugPlaybackClockDateProvider`、
**不调用** `debugTick`——surface 自己的真实 `CVDisplayLink` 全程真实运行（按 macOS 显示刷新率
真实回调 `presentationTick`），`MusicController.lyricRenderTime()` 落到真实 `Date()`
（`MusicController.swift:495-503`：`elapsed = date.timeIntervalSince(playbackClockBaseDate)`，
`date` 默认就是 `Date()`）——也就是真实的、连续推进的 1x 播放钟，不是逐帧跳变。

歌词数据来自真实生产缓存文件 `~/Library/Application Support/nanoPod/lyrics_cache.json`（本轮
第一部分已定位的 4 首歌哈希，见上文"选歌准备"章节），运行时直接读取解析，不是编造 fixture。

### 第一轮：4 首歌各 60 秒真实播放，0 次全亮

| 歌曲 | 真实采样帧数 | 全亮帧数 | 实际覆盖到的行 | JSONL |
|---|---|---|---|---|
| 大橋純子「水玉模様の傘」 | 1200（20Hz×60s） | 0 | 行 0→4（前 36s 进度） | wholeline-flash-realtime-oohashi-mizutama.jsonl |
| How's about your company | 1200 | 0 | 行 0→3 | wholeline-flash-realtime-fastest1-hows-about.jsonl |
| 生份的 遥远的歹势细腻 | 1200 | 0 | 行 0→4 | wholeline-flash-realtime-fastest2-shengfende.jsonl |
| 仍然记得个一次 风里相依 | 1200 | 0 | 行 0→7 | wholeline-flash-realtime-fastest3-rengranjide.jsonl |

抽查确认这不是空跑/测试失效：`perRunSweep` 全程为 `true`（真的在走逐字扫掠这条被怀疑的代码
路径），每次切行瞬间 `applied` 都从接近 0 开始爬升，`applied` 与 `expected` 在全部 4800 个采样
点上逐一相等（Δ=0.0000）——测量链路本身工作正常，不是"没测到"，是"测到的这段时间窗口内没有
复现"。

**这一轮的真实局限、如实报告**：60 秒真实时长对 357 秒的 85 行歌（or 225 秒的 23 行歌）只能
覆盖开头 3-8 行，远不是全曲——"0 次"只能代表"这几行没有"，不能代表"这首歌没有"。

### 第二轮：直接读真实缓存时间轴数据，定位"相邻行零间隔"最可能触发点，针对性复现

与其对 4 首歌各播满整首（357s 最长的一首单独就要 6 分钟真实时间），先直接检查真实缓存里的
逐行时间戳本身，验证假设①的前提条件（"相邻行时间重叠或间隔接近零"）是否真的存在：

| 歌曲 | 总行数 | 相邻行间隔 <0.05s 的次数 | 占比 |
|---|---|---|---|
| How's about your company | 85 | **25** | 30% |
| 大橋純子「水玉模様の傘」 | 23 | 8（其中一处恰好 0.0s） | 35% |
| 生份的 遥远的歹势细腻 | 39 | 1 | 3% |
| 仍然记得个一次 风里相依 | 27 | 0 | 0% |

假设①的前提条件确凿存在，而且在最快那首歌（How's about your company）里相当常见（近三分之一
的行与行之间几乎无缝衔接）。附带发现一处数据异常（与本次 bug 无关，单独记录不深追）：
大橋純子那首第 15 行文本是"And there's a love for yo..."——纯英文，混在全日文的 YRC 歌词里，
且这一"行"跨度长达 39 秒（127.02s→166.36s），疑似匹配/合并环节窜入了别的来源文本，值得未来
单独排查，但和整行全亮无关，本轮不追。

**针对性真实时钟复现**：不再从 t=0 起播满全曲，而是把播放钟种到间隔异常点前几秒（种子点本身
仍然是真实 `Date()` 起算，只是起始锚点不同，推进方式没有任何变化），真实播放穿过那个具体的
切行瞬间：

| 目标切行 | 种子起点 | 真实时长 | 采样率 | 结果 |
|---|---|---|---|---|
| fastest1 行8→9（间隔≈0.03s，t≈77.16s） | t=60s | 22s | 50Hz | 0 次全亮，`applied`=0.037 起爬，与 `expected` 完全相等 |
| oohashi 行15→16（间隔=0.0s，t=166.36s） | t=160s | 15s | 50Hz | 0 次全亮，`applied`=0.004 起爬，与 `expected` 完全相等 |

两次都确认真实命中了目标切行（打印的行号跳变时间点和缓存时间戳吻合），仍然 0 次全亮。

### 结论：仍未复现——但缩小了范围，明确了下一步该测什么

真实 CVDisplayLink（不是假定时器）+ 真实墙钟连续推进（不是逐帧跳变）+ 真实缓存数据里挑出的
"相邻行零间隔"最高嫌疑切行——这三样都做到了，仍然复现不了。这次测试**排除**的原因：不是
CVDisplayLink 定时精度问题，不是播放钟离散跳变问题，也不是"零间隔切行"这个条件单独就够。

**测试没有覆盖到的一层**：这次用的仍是 `MusicController(preview: true)` 的合成播放钟——干净的
`Date()` 线性插值，没有真实 ScriptingBridge 轮询那种"慢读延迟 + 偶发回退 + 插值纠正"的抖动。
仓库里已有 `PlaybackClockTrustTests`/`interpolateTime` 这类专门处理"轮询回退 0.5s 内允许倒退
纠正"的逻辑——假设①原文本来就包含"或 clock-trust/interpolation fallback 把 progress 瞬间推到
≥1"这一支，这次的合成钟从未走过那条修正分支。这是当前复现方法唯一还没排除的差异，是最值得
往下查的方向。

**已经顺带产品化，无需再做**：创始人在 message A 里说的"如果这次真实时钟仍未复现，把这套
按帧 JSONL 方法产品化进 NativeLyricsMaskTrace 本身"——这件事本轮 Step 3（协调者上一轮批准的
埋点开关）已经做了，不是新工作：`NativeLyricsMaskTrace.record(...)` 现在每次调用都会传入
`wholeLineHighlight` 这个字段（`NativeLyricsRowView.swift` 的 `updatePlaybackPhase` 里，
`maskTraceWholeLineHighlight` 计算方式和这次测试用的 `debugLastWholeLineHighlight` 完全一致），
并且已经能在 release 构建里通过 `defaults write <bundle-id> NanoPodMaskTraceEnabled -bool YES`
开启，落盘到 `/tmp/nanopod_mask_trace.jsonl`——创始人在真实用 App 听歌时如果再撞到那次录屏里的
现象，开这个开关就能自动留证，不需要额外开发。

**建议下一步**（不在本轮做，列在这里等裁决）：用真实 `MusicController`（真实 ScriptingBridge
轮询，不是 `preview: true`）对着这几首歌做同样的真实时钟复现，或者更直接——请创始人开启
`NanoPodMaskTraceEnabled` 后正常用 App 听这几首快歌，下次撞见就有 `/tmp/nanopod_mask_trace.jsonl`
现成证据，不需要再猜。

**测试**：`LyricsWholeLineFlashRealTimeTests` 全部 6 个方法通过（4 首整曲 60s + 2 个针对性
窗口），真实运行总耗时约 5.5 分钟；证据文件：
`research/repro-2026-09-14-lyrics-render/wholeline-flash-realtime-*.jsonl`（6 个文件，共 6645
行采样数据）。这条按"先复现报我再修"停在这里，没有做任何修复尝试。

---

## 整行全亮：最后一轮（真实 ScriptingBridge 轮询形状抖动钟）——仍未复现，已排除条件清单

### 方法：在真 CVDisplayLink 台子上叠加真实轮询形状的抖动钟

在此前"真 CVDisplayLink + 真墙钟"的基础上（`LyricsWholeLineFlashRealTimeTests.swift`），
这一轮把播放钟从"干净的 1x Date() 插值"换成**真实 ScriptingBridge 轮询形状**的抖动版本，
直接复用生产代码里判定"这次轮询要不要采信"的真实规则函数
`PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(drift:readLatency:)`
（`MusicController.swift:110-116`），不是自己重新猜一套逻辑：

- 每约 2 真实秒模拟一次轮询：读延迟在 0.1-0.4s 之间随机，读回的数值反映"发起读取那一刻"
  的真实歌曲位置（滞后量=读延迟，和 07-17 复盘笔记里"纠正量等于读延迟本身"的模型一致）。
- 是否真的用这次读数去改播放钟，交给上面那个真实规则函数判定——和生产环境一样，噪声级的
  小纠正会被直接压下（fastest1 那首 75 次轮询里 65 次被压下，oohashi 24 次里 20 次被压下，
  比例和真实行为吻合），只有读延迟本身够快、或漂移大到超过读延迟不确定度的轮询才会真的改钟。
- 每首歌精确复现一次 2026-07-17 21:55:22 那条实测日志（`PlaybackClockTrustTests.swift` 钉死
  的值）：读延迟 743.5ms，产生漂移≈-0.58s，直接当一次真实抖动样本喂进去。
- 每首歌注入一次 1-3 秒的向前跳变（模拟晚发现换歌/seek 落地），注入一次暂停+恢复。

### 种子点覆盖：两首歌的全部零间隔切行

不是从头播完整曲（85 行那首真实要播 357 秒），而是把播放钟种到每一处此前数据核查找到的
"相邻行零间隔"切行前 3 秒，每个种子点跑 7 真实秒（约 3 个轮询周期）：

| 歌曲 | 零间隔切行总数 | 覆盖种子点数 | 全亮帧数 |
|---|---|---|---|
| How's about your company（85 行） | 25 | **25（全覆盖）** | 0 |
| 大橋純子「水玉模様の傘」（23 行） | 8 | **8（全覆盖，该曲只有这么多，达不到"至少25"是因为总数不够）** | 0 |

两首歌合计 33 个种子点、11546 个采样帧、75+24=99 次模拟轮询（其中 85 次被真实规则压下，
符合生产环境该有的抖动免疫行为）、2 次向前跳变、2 次暂停恢复，全部真实运行，总耗时约 231
真实秒。抽查全部采样点：`expected` 与 `applied` 进度在**每一个**采样点上都完全相等
（Δ=0.0000），包括紧跟在被采信的轮询纠正、向前跳变之后的帧——逐字扫掠这条代码路径在这一整
套抖动条件下没有表现出任何偏差，更不用说整行全亮。

### 已排除条件清单

这一整轮加上此前两轮，累计已经在真实 CVDisplayLink + 真实墙钟条件下排除的诱因：

1. CVDisplayLink 本身的定时精度问题——排除（用的就是真实硬件回调）。
2. 播放钟离散跳变（逐帧手动推进）——排除（这轮和上一轮都是连续真实钟）。
3. 相邻行时间间隔接近零/为零，单独作为触发条件——排除（33 个真实零间隔切行种子点全覆盖，
   0 次）。
4. ScriptingBridge 轮询噪声本身（读延迟 0.1-0.4s + 生产同款的信任/压制规则 + 一次精确复现的
   历史抖动样本）——排除（99 次模拟轮询，0 次全亮）。
5. 晚发现换歌/seek 落地那种 1-3 秒真实向前跳变——排除（2 次注入，落地都被真实信任规则正确
   采信为"真跳变"，没有触发全亮）。
6. 暂停/恢复瞬间——排除（2 次注入，无异常）。

### 仍未测到的维度

这套抖动钟仍然是**合成**的——用真实规则函数判定要不要采信，但轮询本身是本测试自己生成的，
不是真实 `ScriptingBridge`/`Music.app` 在真实系统负载下产生的。真实系统里可能存在这套合成
抖动没有覆盖到的更复杂时序（比如真实 IPC 队列排队、真实 AppleEvent 超时重试、真实系统调度
抢占导致的更极端读延迟分布），这些没有、也很难在无 Music.app 的 headless 测试里完全还原。

### 结论

创始人指定的"整行全亮"这条 bug，穷举了锁步假时钟（本轮之前）、真实 CVDisplayLink+真实墙钟
播满整曲、真实 CVDisplayLink+真实墙钟针对性种子点、真实 CVDisplayLink+真实墙钟+生产同款
ScriptingBridge 轮询抖动规则种子点——四层方法论，仍然复现不了。如实报告：**未复现**，不是
"没有这个 bug"。真机留证路径已经就绪（`NanoPodMaskTraceEnabled` 开关，上一轮已产品化），
创始人下次在真实 App 里撞见时能自动留下 `/tmp/nanopod_mask_trace.jsonl` 证据，不需要再猜。

本轮没有做任何修复尝试。

**测试**：`test_jitteredSweep_fastest1_allNearZeroGapTransitions` /
`test_jitteredSweep_oohashi_allNearZeroGapTransitions`，均绿，真实耗时约 231 秒；证据文件：
`research/repro-2026-09-14-lyrics-render/wholeline-flash-jittered-*.jsonl`（2 个文件，共
11546 行采样数据）。
