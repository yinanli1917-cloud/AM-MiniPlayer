# 歌词渲染三缺陷复现报告（2026-09-14）

基线：本 worktree 原停在 277cd5b（main 的祖先，落后 main 很多），已 fast-forward 到
main a3d24b7；再 cherry-pick 创始人提到的「上一轮修复」ce19929（`fix(lyrics-ui): swept
glyphs no longer double`，原只存在于未合并分支 claude/nice-archimedes-0d8856，main 从未
包含它），使本 worktree 与创始人阶段包 2 实测所用的代码状态一致。cherry-pick 干净应用，
无冲突。

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

## 需要创始人裁决的点

1. **defect 1 的修法方向**：需要给强调词补一套和普通词一样的"从暗底挖空该词范围"逻辑
   （即 `applyMainWordFloatGlyphLayers` 的 `floatingOrders` 机制要覆盖到
   `emphasisOrders`，或者 `applyEmphasisGlyphLayers` 自己在 `geometryReady` 时也调用等价
   的挖空）。这跟 ce19929 的思路一致，只是把"非强调词"这个限定去掉、让两套word-partition
   都做同一件事。我还没写这个修复，等你确认要不要按这个方向来。
2. **defect 2/3**：我倾向于先把 `amllState` 的 `scrollToIndex` 分支也纳入"落在前奏窗口
   内"的判断（类似 `firstFutureIndex` 逻辑那样，专门检查 seek 时间是否落在某个前奏行的
   `[startTime, preludeEndTime)` 内，命中就直接把 scrollToIndex 定为那一行），但这只是
   candidate fix，还没有端到端证据支撑它就是 defect 2 报的"完全不出现"的真正原因——需要
   你要么允许我用更细的单帧 DEBUG 埋点在真机上再抓一次，要么接受"先按 scrollToIndex 分裂
   这个已钉死的 bug 修，再看效果"。
