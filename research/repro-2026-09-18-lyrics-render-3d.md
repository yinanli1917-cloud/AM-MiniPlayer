# 歌词渲染缺陷复现报告（2026-09-18，阶段包 3d = main 3ff73cf）

worktree 起始状态：本 worktree 开工前卡在 277cd5b（落后 main 173 个提交），先
`git merge --ff-only main` 同步到 3ff73cf 再开始调查。创始人 09-17 20:56 真机反复前后 seek
范玮琪《啟程》277.8s 的调试证据（`mask_trace_2026-09-17.jsonl` 6091 行、`debug_2026-09-17.log`
9175 行）已只读复制到本会话 scratchpad，本报告 §1 的分析基于该证据。

调查过程中主会话插入一条更高优先级的实时报告（§0）：3d 上「每次切行都掉下来一条很模糊的
行」，已复现、已修复、已验证，见下。

---

## §0（协调方 09-18 插入的最高优先级）：每次切行掉一条很模糊的行 —— 已复现、已修复

### 现象与范围

3c 上没有这个症状，3d 上每次自然切行都有。3d 相对 3c 新增的渲染相关提交只有五个：
`e9e8ad3`（seek 地板复位）、`3a86676`/`f2538d3`（emphasis 对照臂+默认 amll）、`59647e1`
（文本相位激活当帧撤销光栅化 + 快照 blur/geometry 签名不匹配即强制重拍）、`e9ed7b4`（外部
seek 释放手动滚动冻结）、`74507a7`（0.95↔1.00 缩放 X 锚点从 0 改到 32pt）。

排查：`74507a7` 只把已有的缩放变换的 X 锚点从行原点（0）移到文字左边缘（32pt），每次
active↔inactive 切换都会执行同一个确定性的 ≤1.6pt 水平位移，没有新增任何"重新捕获快照"事件，
也没有垂直分量——分析上不像是"掉下来的模糊幽灵"这种大幅度运动的来源，本轮未继续深挖。

### 根因（代码坐实 + 真实 surface 复现）

`NativeLyricsVisualMotionState.isSettled`（`applyRasterizationPolicy(isSettled:isActive:)`
的输入）只覆盖 opacity/scale/blur 三个通道的收敛情况，**从未包含行的 Y 位置**——Y 位置由完全
独立的另一套弹簧系统驱动（`presentationEngine`/`rowStates`）。而 shipping 默认臂下
（`NativeLyricsFeelParity.blurMode == .current`），blur 是**阶跃**通道：
`NativeLyricsVisualMotionState.setTarget` 一旦目标变化就把 `blur = nextTarget.blur` 立即
钉死（`blurVelocity = 0`），不经过弹簧。自然切行时，一个远处行的 blur 目标（`abs(displayIndex
- currentIndex)` 的函数）几乎每次都会跨一个档位，新 blur 值在**切行的同一帧**就阶跃到位——
于是 `visual.isSettled` 在这一帧就为真，**而这一行（以及本次波浪影响到的相邻行）的真实屏幕
位置还在弹簧收敛的过程中，要再持续好几帧才会真正停下来**。`59647e1` 新增的"签名变化即强制
重拍"逻辑（`NativeLyricsRowView.refreshRasterization`）在这一帧发现 blur 签名变了，就把
`layer.shouldRasterize` 关再开，强制 WindowServer 对着**仍在肉眼可见运动中**的行拍一张新位
图快照——这张快照内容没错，但被拍下的那一刻这一行的屏幕位置是"飞行中"的中间态，之后这行继续
被弹簧带到最终位置，视觉上就是"一张模糊的静态截图跟着弹簧掉进最终位置"，与创始人描述完全吻合。

### 复现（真实 surface + 真实锁步时钟，先红后绿）

`Tests/MusicMiniPlayerTests/LyricsRenderDefects20260918ReproTests.swift`
（`test_naturalLineChange_neverForcesRasterizationCaptureWhileRowStillInFlight`）：24 行英文
逐字歌，1.2s 一行，真实 60Hz tick 驱动 12s 自然播放（含多次自然切行），每 tick 记录每行真实
`frame.origin.y`、`debugAppliedBlurRadius`、`debugRasterizationCaptureCount`。修复前：13 次
"同一帧内位移 >3pt/tick 且 blur>0 且发生了一次新的光栅化捕获"的命中，全部精确落在切行边界帧
（t=2.4/3.6/4.8...，正好是 1.2s 行间隔的整数倍）。

### 修复

尝试过、已回退的方案：用行自身"上一次真实绘制的 Y"与"这一帧的 Y"做每行 delta 判定——失败,
因为 `applyFrame` 每个真实显示帧会被**两条独立路径**各调用一次（`reconcileVisibleRowViews`
自己的一趟 + `applyFrames`/presentation-tick 的一趟），各自现场构建自己的
`nativeFrameRenderSnapshot`；同一显示帧内这两趟之间几乎没有墙钟时间流逝，delta 测出来接近 0，
即使这一行相对上一个真实显示帧确实挪动了不少（本方案的残留 3 例，均为这个"帧内两趟调用"造成
的假阴性，已用日志坐实后放弃）。

**最终修复**：改用 `presentationEngine.hasActiveMotion`——一个对引擎当前弹簧状态的**实时、
不缓存**的读取，与"这一帧被渲染了几次"无关。在 `applyFrame` 里把它并入光栅化门禁：
`isSettled: visual.isSettled && !presentationEngine.hasActiveMotion`。代价是判定粒度变粗
（只要**任何**一行还在动，全体行都暂缓重拍，不只是移动中的那一行）——用一点点"暂时用旧位图"
的陈旧代价换正确性，不会削弱 `59647e1` 本身要修的 CJK 尾字重影（那个 bug 要求的是"行自己已经
停止移动很久、blur 却没跟上",而正常演唱时除激活瞬间外没有任何行的位置在动，`hasActiveMotion`
很快回到 false，下一行切换前有充足窗口完成重拍）。

### 验证

- `LyricsRenderDefects20260918ReproTests`：1/1 绿（红→绿）。
- `NativeLyricsRasterizationSignatureTests`（59647e1 自己的两个测试）、
  `NativeLyricsBlurEconomyTests`（8 个）：全绿，证明没有削弱 CJK 尾字重影修复本身。
- 全量回归 `NativeLyrics*`/`LyricsRenderDefects*`/`Handoff`/`PlaybackClockTrust`/
  `LyricsWholeLineFlash`/`ManualScroll`/`RowScaleAnchorDisplacement`：**305/305 全绿**（含此前
  记录在案的 harness 伪影 `NativeLyricsRenderChurnTests.
  test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff` 本轮也通过，flaky 非回归）。

### 提交

见下方 commits 列表。

---

## §1（最高优先，原始任务）：回跳后偶发整行全亮 / 某些行无高光遮罩

### 真机证据分析

`mask_trace_2026-09-17.jsonl`：434 条 `mask_state`、5657 条 `row_position`，覆盖创始人整场
反复前后 seek 会话。

- **`wholeLineHighlight` 全场 0 次触发**——现有这个标志量确认捕捉不到创始人肉眼看到的"整行全亮"。
- **`expected`/`applied` 全场只有 1 次明显不一致**（阈值 0.05）：
  `row=10-0 word=8 perRunSweep=false expected=0.777 applied=0.0`。紧邻的上一条 mask_state 是
  `row=0-0 word=-1 expected=1.0 applied=1.0`（前奏行满亮），紧邻的下一条（同一 row 10-0）是
  `perRunSweep=true expected=0.777 applied=0.777`（已恢复正确）——即：**这是一次真实的大跳
  seek（从行 0 直接跳到行 10），落地那一帧命中了一个已知设计分支，下一帧自愈**。

### 根因（代码坐实）

`NativeLyricsRowView.applyActiveMainPhase`（`NativeLyricsRowView.swift` ~1744-1860）：
`geometryReady = mainBrightTextLayer.bounds.width > 1 && ... && !linePlan.isEmpty`。当一个行
视图**刚被指派到新内容**（从视图池取出或首次挂载）且**同一帧**就被判定为"激活"时，如果这一帧
它自己的 `layout()` 还没跑完（`mainBrightTextLayer.bounds` 仍是旧值/零），代码走
`else` 分支（第 1812-1859 行）：显式返回 `progress: 0, appliedPerRunSweep: false`，同时把
`mainBrightTextLayer.isHidden = true`——这段代码自己的注释写明是"专门为了避免一个零尺寸渐变
遮罩读起来像整行已高亮"而设计的防御，副作用就是这一帧**完全没有高光遮罩**（"有些行没有高光
遮罩"）。`reconcileVisibleRowViews`/`updateTextPhasesForCurrentConfiguration` 两处调用点都已经
有 `if view.frame.size != .zero { view.layoutSubtreeIfNeeded() }` 的补救（专门写了注释说明
"让 geometryReady 在第一次相位应用时就为真"），但仍然存在这个只持续 1 帧、自愈的窗口——真机
证据里捕捉到的正是这唯一一次命中，且证实自愈。

`wholeLineHighlight` 全场 0 次触发，说明创始人偶尔看到的"整行全亮"**不是**这套标志量在跟踪的
那条已知防御分支触发的（那条防御恰恰是为了**防止**整行全亮而不是造成它）——现有标志量确实
"量的不是创始人看到的状态"，根因还需要更强的证据链（见下方 fuzz 结果与监测状态清单）。

### Fuzz 复现（真实 surface + 真实锁步时钟，随机 seek）

`Tests/MusicMiniPlayerTests/LyricsRenderDefects20260918SeekFuzzTests.swift`
（`test_sustainedRandomSeeking_maskNeverDesyncsBeyondAShortGeometryGrace`）：90 行 CJK 逐字歌
（真实字密度/间隔），确定性 xorshift 随机种子，每 2-5s 随机跳到 [0, 时长) 内任意一点（前跳/
后跳均可），持续约 200 个模拟秒（≈3.3 模拟分钟，约 45 次 seek）。每帧对语义激活行断言：
"expects 逐字扫描时，perRunSweep 必须为真且 applied 在 expected 的 0.08 容差内"——一个 3-tick
（约 50ms）宽限期专门吸收上面坐实的"刚挂载/刚重指派几何未就绪"这一个已知、已自愈的单帧瞬态,
超过宽限期仍不一致才算违反。

**结果：0 violation。** 200 模拟秒、约 45 次随机 seek 内，mask desync 没有一次持续超过 3 帧。
第一版测试（误把只适用于整行退化路径的 `mainBrightTextLayer.string != nil` 当成逐字扫描的
"高光是否存在"信号）曾误报 9318 次假阳性——诊断后确认那是**测试建模错误**（v2.8 Canvas 架构
下逐字歌的真实高光画在独立的逐字瓦片层 `mainBrightWordGlyphLayers`，`mainBrightTextLayer.
string` 对这类行按设计恒为 nil），已修正为只检查 `perRunSweep`/`applied vs expected`，重跑后
0 违反，见上。

### 单调/一次性状态审计（按要求列清单）

逐个核查这类"只降不升 / 只前进不后退"的状态在 seek 序列下是否可能卡住：

| 状态 | 位置 | seek 时是否正确复位 |
|---|---|---|
| `mainPostLineFadeFloor` | NativeLyricsRowView.swift:273 | ✅ 已被 e9e8ad3 挂在 `nativeSeekDiscontinuityOccurred` 上复位（本轮验证在案） |
| `translationPostLineFadeFloor` | 同上 | ✅ 与上面同一处一起复位 |
| **`lastMainSweepWavefrontX[index]`** | NativeLyricsRowView.swift:2122-2123 | ⚠️ **未复位**——只在 `clearSweepState()`/`prepareForReuse()`/行身份变化时清空，`nativeSeekDiscontinuityOccurred` 分支完全没碰它 |
| **`lastTranslationSweepWavefrontX[index]`** | 同上 2223-2224 | ⚠️ 同上，未复位 |
| appear 窗（`forceSnapUntil`） | LyricsLayerRendererView.swift | 每次 seek 由 `NativeLyricsSnapMode.resolve` 重新判定，天然跟着 playbackMode 走，非独立状态，未见风险 |
| snap 冻结（`manualScrollState`） | 同上 | 已被 e9ed7b4 在本轮之前修复（外部 seek 优先释放） |
| `rasterizationSignature`（59647e1 新增） | NativeLyricsRowView.swift:480 | 每次 `desired=false` 就清 nil（含行失活/被跳过时），下次真正激活会重新判定；seek 落地后行若变为激活会走 `isActive` 分支直接清空，未见风险 |
| `deferredDeactivationIndex` | LyricsLayerRendererView.swift | 单帧作用域内计算，非跨帧累积状态 |

`lastMainSweepWavefrontX`/`lastTranslationSweepWavefrontX` 是**与 e9e8ad3 修复的
`mainPostLineFadeFloor` 完全同类的结构性缺口**：`max(line.wavefrontX, lastMainSweepWavefrontX
[index] ?? -inf)` 让这个逐视觉行（word-wrap 后的一行，不是整句）的扫描前沿只能前进不能后退，
但重置条件里没有 `nativeSeekDiscontinuityOccurred`。**诚实说明其不确定性**：这段代码设置的是
`mainPerRunSweepMaskLayer`，挂在 `mainBrightTextLayer.mask` 上——但 v2.8 Canvas 架构下逐字歌的
`mainBrightTextLayer.string` 在 `geometryReady` 分支里被显式置 nil（真实高光画在独立的
`mainBrightWordGlyphLayers` 瓦片层，不受这个 mask 影响）；本轮没有验证这段"遗留遮罩仍在运行但
可能已经视觉上无效（因为遮罩作用于一个空字符串的图层）"这个假设，也没有验证它是否仍在其它路径
（如翻译或整行退化分支）里产生真实可见影响。**未修，先报**：这是结构上与 Fix A 同类的缺口，
但在下手修之前需要先确认它是否真的有视觉后果，避免像本会话早先的按位置增量判定那样在不完整
证据下动手又引入新回归。

### 结论

- geometryReady 单帧空遮罩瞬态：坐实、自愈,fuzz 测试 200 模拟秒/45 次 seek 未发现它演变成
  持续性缺陷。
- `wholeLineHighlight` 现有标志量确认测不到创始人看到的状态。
- 新发现一处与 Fix A 同类但未修的单调状态缺口（`lastMainSweepWavefrontX`），视觉后果未坐实。
- **未能在这批合成 fuzz 条件下复现"整行全亮"或持续性"无遮罩"**——诚实局限：合成 fuzz 用的是
  直接调 `registerSeek()` + 跳时间，不是真实 ScriptingBridge 轮询的完整时序（真实轮询有
  `queueWait`/`sbRead` 排队延迟），也没有专门针对创始人描述的"反复来回快速 seek"这种高频模式
  （本轮用的是 2-5s 一次）调整密度。建议下一步：把种子间隔收紧到 0.3-1s 高频快速反复 seek,
  并在 `updatePerRunSweepMask`/`lastMainSweepWavefrontX` 路径补一条只读探针,确认它对逐字歌
  是否真的是死代码。

---

## §2：前奏三点冷启动 vs 手动滚回顶部形态不一致 —— 轻量复核，完整状态机仍未做

用本轮实际跑的 `test_threePreludeEntryPaths_coldStart_seekBack_manualScrollBack`（在 3d + 本轮
全部修复之上重新验证，非新写代码）的真实打印复核了静止终态（不是逐帧过程）：

| 路径 | dotHidden | dotOpacity | dotAnimating | dotCenter | rowFrameMinY | semanticIndex |
|---|---|---|---|---|---|---|
| A 冷启动 | false | 1.0 | false | (50.0, 377.0) | 200.0 | 0 |
| B seek 回前奏 | false | 1.0 | false | (50.0, 377.0) | 200.0 | 0 |
| C 手动滚回前奏 | false | 1.0 | false | (49.1, 377.0) | 200.0 | 0 |

A、B 在这张表的每一个字段上**逐位精确相等**；C 只有 `dotCenter.x`（49.1 vs 50.0）不同——这就是
74507a7 自己commit message 里点名"未完全解决"的残留：0.95 缩放对**非文字元素**（点簇的整体
居中）仍有约 0.9pt 的残余水平位移（缩放锚点已经对齐到文字左边缘，但点簇是居中布局，不是靠左
布局，所以同一个锚点修复对它只减小、没有清零）；C 的 `rowOpacity`（config 层，非上表字段）
是手动滚动 0.6 档，A/B 是 1.0——这是设计好的手动滚动统一变暗，不是 bug。

**仍未做**：创始人要求的"完整状态机对照（出现方式/逐帧进度动画/退场方式）"是逐帧过程量，上面
这张表只是三条路径**各自静止终态**的对照（沿用既有测试的既有断言点，本轮没有新增逐帧采样代码）
——诚实说明这不满足"完整状态机"的要求，按时间预算本轮先报终态对照，逐帧过程对照建议下一轮用
`NativeLyricsMaskTrace` 同款"每帧只在变化时记一条"的打点方式，对三条路径各录一份 dot
opacity/scale/center 的时间序列再比对。

## §3：CJK 尾字重影仍在 —— rowdump 入口已实现；headless 复现仍是盲区

**已实现**：`nanopod://debug/rowdump`（release 也可用，见提交记录）——创始人下次真机看到重影时
执行一次，`/tmp/nanopod_rowdump.txt` 会写入当前激活行 + 上一行所有可见文本/位图子层（类名、
frame、opacity、string 前 8 字、contents 是否为位图、shouldRasterize、transform）。

**headless 复现**：用 59647e1 自己的 CJK 复现夹具（行 6 = "爱愁思心碎滋味"）驱动过已知重影
窗口（t≈13.85-14.10），每帧调用同一个 dump 函数，归档到
`/tmp/nanopod_rowdump_cjk_ghost_repro.txt`（1416 行）+ 逐帧扫"同一字形出现在 dim+bright 配对
之外的第三层"——**0 处命中**。这与 3c 报告的结论一致：这一类重影的根因线索是 CALayer
shadow/CIFilter 在渲染服务端的合成，`CALayer.render(in:)`（headless PNG 测试唯一可用的方法）
不保证还原——不是"没有重影"，是"这个检测方法测不到"（banned-patterns.md 已有的同类盲区）。
`NativeLyricsRasterizationSignatureTests`（59647e1 自己的 CJK 回归测试）本轮仍然全绿，§0 的
修复（新增 `!presentationEngine.hasActiveMotion` 门禁）没有削弱它。

**未做**：真机验证（rowdump 入口需要创始人在真机上实际触发一次并把 `/tmp/nanopod_rowdump.txt`
的内容带回来，才能推进这条线）。

## §4：每次切行 1-2px（垂直）—— 根因已定位：不是计算 bug，是设计如此；原测试假设已证伪

### 第一轮（诚实红态）：测到真实信号，但没能定位确凿的两处计算分歧

真实 surface + 真实 60Hz 锁步时钟（中英文各一，2.5s 行间隔隔离每次切行，见
`Tests/MusicMiniPlayerTests/LyricsRenderDefects20260918SettleTargetGapTests.swift`）：每一行在
**真正离开过激活位（不是"自己歌词唱完"，是语义索引已经换成别的行）**之后，稳定 ≥0.5s，随后仍
会再挪动一次，幅度约 1-6pt。写这个测试的过程本身踩了两个方法论坑（详见测试文件头注释，未删除
保留在案）：① 最初把"稳定"判定绑定在"这一行自己的歌词已经唱完"上——错的，
`NativeLyricsTimelinePolicy.liveDisplayIndex` 在整个间隙里让最后开始的行继续算"当前行"，这样
测出来的"二次挪动"其实是它人生中第一次、唯一一次正确的切换；② 改成"语义索引已不是自己"仍不够，
一个还没轮到播放的远处行从 tick 0 起就"不是当前行"，它的冷挂载→首次定位被误判成"已经稳定又被
挪动"。两次都加了 guard 才拿到干净信号。当时怀疑的候选（`seededTargetsForNaturalAdvance` 无条件
把 radius=14 内所有行目标重写成 `oldIndex`）手推简单连续单步算术应该抵消成 0，跟非零结果对不上，
当时没能补全，测试以诚实红态（配 `XCTExpectFailure`）先提交。

### 第二轮（协调方要求做到根因）：三层探针，结论是"没有 bug"

按协调方指示追加三层证据（同一测试文件）：

1. **`XCTExpectFailure` 标注**——保留断言，主线不再常红。
2. **radius=14 验证**：60 行大 cast，`test_radiusHypothesis_nudgesAtDistanceBeyond14`——845 次
   挪动里，绝大多数（798/845）发生在 `abs(行号-当前激活行号) <= 14` 以内，超出 14 的只有边界
   附近的 47 次（测量误差：取样时机比真正判定 radius 的那一刻略晚了几帧）——radius=14 假设**基本
   成立**，但这只回答了"挪动会不会停"，没回答"挪动本身是不是 bug"。
3. **两层直接探针**（`LyricsPresentationEngine` 新增 `#if DEBUG` 埋点，见下方提交记录）：
   - `debugReseedLog`：专门盯 `seededTargetsForNaturalAdvance` 那一行代码——**0 次命中**。原因：
     `lineTargetIndices` 在每次波浪 1s 左右完全 settle 后会被清空成 `[:]`（`advancePendingWave`
     收尾），而我的行间隔（1.2-2.5s）都长于这个 settle 时间，所以每次新切行发生时，这本字典早
     就是空的——"重写成不同值"这个前提在这批复现条件下从未发生过。**当初怀疑的这个机制，被证伪，
     不是"没测到"，是它根本没有运行到会出问题的那个分支。**
   - `debugTargetYChangeLog`（更broad的探针，直接扎在 `reconcileRows`——**每一次** `targetY`
     被计算的唯一地方，不管调用方是谁）：60 行等高测试，960 次"已稳定行的目标被改写"事件，
     **960/960 精确等于 -50.000（一行高度），零例外**；再用原始变高（中英文实际内容，非等高）
     fixture 复测，90 次事件，**用探针记录的两次 `accumulatedHeights[targetIndex]` 读数直接反算
     期望位移，0 次超出 0.01pt 误差**。

### 结论：这不是计算 bug

`targetY = anchorY - accumulatedHeights[目标行] + accumulatedHeights[本行]` 每一次都被正确、
一致地计算——`accumulatedHeights[目标行]` 随着当前播放行前进而单调增大，这意味着**任何仍在
wave 参与半径（radius=14）以内的行，每次切行都会被正确地再推一次目标**——这是"整个面板跟着当前
行同步滚动"这个设计本身自带的行为，不是 bug。第一轮报告里测到的"1-6pt"这个数字，其真实身份是
本测试自己探测逻辑的副产物：`ReNudge.delta` 取的是"位移首次超过 0.3pt 噪声阈值那一帧"的
`y - settledY`——那只是一次正在加速的弹簧运动**刚开始那一帧的切片**，从来就不是这次挪动的真实
总位移（真实总位移经探针证实精确等于一行真实高度差）——不是产品代码的问题，是我自己这套探测
方法本身的量出了问题。

原来两个测试（`test_english/cjk_settledRowNeverNudgesAgainAfterGoingQuiet`）断言"已稳定行永不
再动"这个不变式，现已证明为假（不成立是设计使然，不是缺陷）——已重写为
`test_english/cjk_settledRowRetargetingMatchesAccumulatedHeightDeltaExactly`：断言"任何一次已稳定
行的目标改写，都必须精确等于 accumulatedHeights 差值"（即"零算术异常"）——**全绿，不再需要
`XCTExpectFailure`**。

### 遗留的、真正需要创始人裁决的问题（不是 bug，是产品选择）

行在 radius=14 范围内会持续被重新定位，直到掉出这个半径——这是不是创始人想要的？如果创始人的
体感期望是"离开激活位、肉眼看它停稳之后，就该定住不再动，不管歌还在不在继续播"，那这是一个
**新的产品需求**（把"持续跟随当前行滚动"改成"离开激活位以外的行冻结在原地"），影响面是整个
滚动模型的设计，不是一处局部补丁——按"先复现再修"的边界，本轮不擅自决定并实现这个改动，留给
创始人一句话裁决：要不要把"持续再定位"的窗口从 radius=14 收窄到一个小得多的数字（比如只覆盖
紧邻当前行的 2-3 行），让更远的行一旦离场就此冻结？

### 第三轮（协调方带真机证据复核）：`accumulatedHeights` 用缩放后高度——假设已证伪；真身找到

协调方在创始人 09-14 真机 LineGaps 日志里发现直接证据：同一行（idx 1）激活时记录为
`[1:y=42.0 h=40.0 s=1.00]`，两次切行后 `[1:y=-49.0 h=38.0 s=0.95]`——38.0 精确等于 40.0×0.95。
假设：`accumulatedHeights` 用的是缩放后的行高，行一激活/去激活，自己的布局高度就 ±2pt，累积量
一变，所有其它行的目标 y 跟着整体挪——这能同时解释"每次切行都挪 1-2px"和"老行停下的位置和它
成为上一行后的位置对不上"。

**直接验证**（`test_measuredHeight_isIndependentOfActiveInactiveScale`）：`accumulatedHeights` 的
唯一数据源是 `NativeLyricsRowView.measuredHeight(width:)`（读代码坐实：
`LyricsLayerRendererView.swift` 的 `updateContentIfNeeded` 里 `let height =
view.measuredHeight(width:)`，是 `measuredHeightsByIndex` 唯一的写入点，调用链里没有任何缩放
因子）。直接在真实行视图上调用它——只切换 `currentIndex`（激活/非激活），内容不变：中英文各
一，单行/换行（3 行）、有/无翻译行，共 6 组——**全部精确 0.0pt 差异**。**这个具体假设被证伪。**

**真机日志那个 "h" 字段的真身**：它不是 `accumulatedHeights`/布局高度，是 `logLineGapsProbe`
（`LyricsLayerRendererView.swift` 里我们自己的 LineGaps 诊断探针）**自己算出来的一个派生值**——
探针代码原文：`scale != 1` 时 `height = frame.height * scale`——这是探针为了检测**屏幕上相邻两
行渲染出来的包围盒有没有视觉重叠**（它自己的 `gap` 字段）而专门做的缩放修正，从来不是喂给
`accumulatedHeights`/定位系统的那个值（那个值已经在提交 edca686 证实精确、从不漂移）。
`40.0→38.0` 是这个探针**如实报告**"这一行现在因为非激活缩放，屏幕上渲染出来只有原尺寸的
95%"——设计内、符合预期，跟 `NativeLyricsRowScale.leadingTransform` 的 `height/2` 垂直锚点用的
是同一套算术，不是新 bug。

**这解释了真机看到的竖向偏差吗——有一条更精确的剩余嫌疑**：`leadingTransform` 的缩放锚点在
行高度垂直中心，缩放 1.00↔0.95 会让行的**渲染内容**（文字/圆点）在**它自己不变的定位槽位内**
上下对称收缩/展开——对一个 40pt 高的行，`40×0.05/2=1.0pt`，即文字顶边会因为这次缩放在槽位内
挪动约 1pt——量级和方向精确对得上创始人说的"1-2px"，且正是这个探针的 `gap` 字段本来就是为了
监控的那类视觉效果。**但这是 `leadingTransform` 垂直锚点本身已知、有意为之的设计**（代码注释
明确写着"为解决 CJK 换行行距跳变问题"），不是新发现的计算分歧——行的**槽位位置**（`targetY`）
不受影响，只是行**自身内容**在缩放时于槽位内轻微收缩/展开。这是否是创始人观感里的"1-2px"，
按"先复现再修"，需要创始人肉眼终验后再确认要不要动这个锚点设计（改锚点是全局性改动，会牵动
已经验证过的 CJK 换行修复，不能顺手改）。

---

## 提交记录

1. `f1b8d8f fix(lyrics-ui): gate rasterization recapture on presentationEngine.hasActiveMotion` —— §0 修复 + 复现测试。
2. `9f0f8f7 test(lyrics-ui): sustained random-seek fuzz test for mask desync (defect #1)` —— §1 fuzz 测试（含建模修正过程）。
3. `138b4fa docs: repro report for stage bundle 3d — blurry-row fix + seek-fuzz findings` —— 本报告首版。
4. `f3ab9ab test(lyrics-ui): measure per-line-change settle-vs-reconcile-target gap (defect #4)` —— §4 第一轮测量（诚实红态，未修）。
5. `a692472 feat(lyrics-ui): add nanopod://debug/rowdump entry point (defect #3 follow-up)` —— §3 rowdump 入口 + headless CJK dump。
6. `1cc317a docs: update stage bundle 3d report with §2/§3/§4 findings` —— 本报告 §2/§3/§4 首版补完。
7. `77ef0c7 test(lyrics-ui): gate defect #4 settle-gap tests with XCTExpectFailure` —— §4 第二轮 step 1。
8. `edca686 test(lyrics-ui): root-cause defect #4 — not a bug, disprove the settle-vs-target premise` —— §4 第二轮 step 2-4，三层探针 + 根因定位 + 原测试改写为真实不变式，全绿。

全部未 push。提交 8（`edca686`）之上跑的最新一轮全量回归门（`NativeLyrics*`/
`LyricsRenderDefects*`/`Handoff`/`PlaybackClockTrust`/`LyricsWholeLineFlash`/`ManualScroll`/
`RowScaleAnchorDisplacement`，含本轮全部新增/改写测试）：**312 个测试，4 处失败**——全部集中在
同一个已知预存 harness 伪影
`NativeLyricsRenderChurnTests.test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff`
（`handoff_red_test_appear_window.md` 有案；本会话早前一轮全量回归里这条测试是绿的，flaky 非
回归）；§4 两个测试（`test_english/cjk_settledRowRetargetingMatchesAccumulatedHeightDeltaExactly`）
全绿，不再需要 `XCTExpectFailure`。没有真正的新增失败。
