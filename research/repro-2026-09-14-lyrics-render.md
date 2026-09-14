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

## 缺陷 1：强调词重影 —— 已复现，根因锁定

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

---

## 修法方案（未动手，等创始人确认）

### 缺陷 1：给强调词补等价挖空

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
