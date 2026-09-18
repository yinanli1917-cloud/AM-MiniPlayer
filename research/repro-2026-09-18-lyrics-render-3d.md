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

## §2：前奏三点冷启动 vs 手动滚回顶部形态不一致 —— 未动手,按要求先报

本轮未新增调查（时间分配给了协调方插入的更高优先级 §0 与原定 §1/§4）。上一轮
（`research/repro-2026-09-17-lyrics-render-3c.md` §D）已把 Y 轴坐标三条路径的一致性坐实
（377.0/377.0/377.0 精确相等）并修复了一个失同步 bug（e9ed7b4）；创始人要求的"完整状态机对照
（出现方式/逐帧进度动画/退场方式）"仍未做，按 09-17 报告结尾"先报你"的约定保持未动。

## §3：CJK 尾字重影仍在 —— 未动手，按要求先报

同上，上一轮（3c 报告 §CJK）已经把机制定位到光栅化缓存与文本相位解耦的窗口期
（`applyRasterizationPolicy` 用视觉目标而非文本相位的激活标志），本轮 §0 的修复顺带触碰了
同一个函数（新增了 `!presentationEngine.hasActiveMotion` 门禁），但没有改变 3c 报告里那条
CJK 根因链路本身——`NativeLyricsRasterizationSignatureTests`（59647e1 自己的 CJK 复现测试）
本轮全绿，说明这条修复仍然有效。创始人要求的按需 dump 入口 `nanopod://debug/rowdump` 本轮
未实现，按"先报"约定保持未动。

## §4：每次切行 1-2px —— 未触及

时间/精力分配给了协调方插入的更高优先级 §0（已完整解决）与原定 §1（fuzz 测试 + 单调状态
审计），本轮没有余力再开新的调查线。上一轮（3c 报告 §C1）已经把"每次都有"的 1.6pt 水平位移
坐实并修复（74507a7，缩放锚点从行原点移到文字左边缘）；创始人这次问的是**垂直方向**、"波浪
结束 settle 的 frame.y 与下一次 reconcile 给它的目标 y 是否一致"，这是一个新的、独立的测量
任务，建议作为下一轮的第一优先级（方法已经很清楚：真实 surface，记录行 N 波浪 settle 时刻的
`frame.origin.y`，与行 N+1 激活那一帧 `presentationEngine.presentation(for: N)?.targetY` 逐帧
比较，非零则继续深挖 accumulatedHeights/弹簧目标来源分叉点）。

---

## 提交记录

1. `fix(lyrics-ui): gate rasterization recapture on presentationEngine.hasActiveMotion, not just opacity/scale/blur` —— §0 修复。
2. `test(lyrics-ui): repro the blurry-row-falls regression from 59647e1 on natural line change` —— §0 复现测试。
3. `test(lyrics-ui): sustained random-seek fuzz for mask desync (defect #1)` —— §1 fuzz 测试（含建模修正）。

全部未 push。
