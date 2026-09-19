# 2026-09-19 lyrics-render 3k：真机遮罩缺陷 + 尾字重影排查

worktree: `.claude/worktrees/agent-ab3d82dbb5f079637`（分支 `worktree-agent-ab3d82dbb5f079637`，
基线 `main` @ 0d434da，`git merge --ff-only` 后开工）

## 任务 1（已修复+测试+提交）：seek 到更早行后，自然播放回到本行时遮罩不出

### 现场
《啟程》网易逐字版，display idx=5「想爱 就不能害怕会有伤痕」58.16–66.12s。证据：
`/private/tmp/claude-501/.../scratchpad/live/{rowdump.txt,trace.jsonl,debug.log}`。

- 自然播放唱过第 5 行、继续到 idx=14 停留约 30s（第 5 行的 post-line fade 早已把
  `mainPostLineFadeFloor` 压到 0，这是设计内行为）。
- 外部 seek 96.0s→45.3s，落在第 4 行（debug.log `position jump 96.0s→45.3s`）。
- 自然播放（无二次 seek）推进跨过第 4→5 行边界。
- `trace.jsonl`：第 5 行 word 0→10 expected==applied（0→0.909），但
  `mainBrightTextLayer` 全程 opacity=0.0 hidden=true；debug.log
  `[ActiveBrightness] idx=5 rowOp=0.999 bright=0.000 eff=0.000`（对照落地行 idx=4
  `bright=0.789`）。

### 根因
`mainPostLineFadeFloor` 只有两条复位路径：`configure()` 里检测到 row identity 变化、
以及 `updatePlaybackPhase` 里 `configuration.nativeSeekDiscontinuityOccurred == true` 那一帧。
后者是**一帧瞬态**，只有 seek 那一刻真的被 `updatePlaybackPhase` 摸到的 row 才会消费到。
第 5 行在 seek 发生时已经唱完很久、退出渲染窗口，没有在那一帧被驱动——瞬态信号永远够不到它，
之前唱完时压到 0 的地板从此再也没有被复位的机会，哪怕之后自然播放正常唱回第 5 行。

### 修法
`NativeLyricsRowView.updatePlaybackPhase` 改为在**行自身的文本激活边沿**（非激活→激活，
用新增的 `mainWasTextActiveLastPhase` 跟踪）或渲染时钟位于本行开始之前时复位地板到 1——不再
依赖那个瞬态信号。刻意只在“边沿”触发一次而不是每个激活帧都触发，避开 2026-09-17 那次已知回归
（在 `.initialLayout` 这类每帧重复的 snap 原因上复位会让“上一行在正常前进中突然回亮”）。

顺手把 `mainDimCompensationActive`/`translationDimCompensationActive` 也改成每个
`updatePlaybackPhase` 帧都从当前激活状态重算（原先只在 `configure()`/`updateTextLayers()`
里算一次）——核对后发现 `RowRenderKey.isCurrent` 已经覆盖了常见的激活边沿场景，这条是纵深防御，
不是本次真正根因。`NativeLyricsMaskTrace` 新增 `brightHiddenWhileSweeping` 字段专门盯这个形状
（激活行 sweep 进度在 0～1 之间但 `mainBrightTextLayer` 整体隐藏）。`rowDumpLines` 现在同时打印
`layer.presentation()?.opacity` 与 `superlayer`，供下次真机复现时区分「model 值本身错」和
「model 对但 presentation 没追上」。

### 验证
新测试 `Tests/MusicMiniPlayerTests/NativeLyricsPostSeekReactivationMaskTests.swift`（4 条，
直接驱动裸 `NativeLyricsRowView.updatePlaybackPhase`，不经过 surface 的行窗口调度——用全窗口
`renderedIndices` 的 surface 级测试永远摸不到这个 bug，因为它会让每一行每一帧都被驱动，恰好
盖住真机那种「第 5 行早已滚出渲染窗口」的缺口）：
- `test_naturalReentryAfterFarDwellAndUnseenSeek_brightOverlayReactivates`
- `test_naturalReentryTwoLinesAfterUnseenSeek_brightOverlayReactivates`
- `test_consecutiveUnseenSeeksThenNaturalReentry_brightOverlayReactivates`
- `test_dimBaseNeverReadsFullBrightWhileBrightOverlayHidden`

对照：临时 `git stash` 掉修复，4 条里 3 条红（`consecutiveUnseenSeeks`/
`naturalReentryAfterFarDwell`/`naturalReentryTwoLines`），`dimBaseNeverReadsFullBright` 本来就绿
（印证 dim 补偿那部分不是本次真根因，只是加固）。`git stash apply`+`git stash drop` 恢复修复后
4 条全绿。

回归：`NativeLyricsGapHandoffTests`、`NativeLyricsSeekLandingMaskTests`、
`NativeLyricsRealEventScrollTapMaskTests`、`NativeLyricsHandoffClockTests`、
`NativeLyricsDimBaseContinuityTests` 全绿（33 tests, 0 failures）。

commit: `56bb474 fix(lyrics-render): karaoke overlay never re-lights after seek to an earlier line this row never observed`

## 附录：任务 1 现场里「整行纯白 vs rowdump 显示 0.35」矛盾排查（协调者追加）

创始人 02:21 肉眼看到 row 5 整行纯白，同一秒 rowdump 记录 `mainTextLayer(dim-base)
opacity=0.35`、`mainBrightTextLayer opacity=0 hidden=true`，10 个 dim 字块 `opacity=1` 挂在
`mainTextLayer` 下（`addSublayer` 于 `ensureMainWordGlyphLayerCount`）。按模型这行应该是暗的，
但肉眼看到纯白，需要排查四点：

- **(a) dim 字块是否因为父层 `opacity` 不作用于子层（如 `allowsGroupOpacity=false`）而"逃逸"
  0.35 约束** — 排除。`grep -n "allowsGroupOpacity\|compositingFilter"` 在
  `NativeLyricsRowView.swift`/`NativeLyricsLayerSupport.swift` 均无命中；`CALayer` 默认
  `allowsGroupOpacity == true`，祖先 opacity 会作用于整棵子树的合成结果。没有任何代码显式关掉
  分组 opacity，所以 dim 字块理论上必须随 `mainTextLayer.opacity=0.35` 一起变暗——模型层面自洽，
  不是这条路径的解释。
- **(b) rowdump 打印的是 model 层还是 presentation 层的 opacity** — 无法排除，且最可能。
  `rowDumpLines` 原先只读 `layer.opacity`（model 值），从不读 `layer.presentation()?.opacity`
  （渲染服务器实际在合成的值）。已在本次提交里给 `describe()` 加上
  `presentationOpacity=...`/`superlayer=...` 两个字段（任务 1 的一部分，见上）——下次真机复现时
  能直接对比 model 与 presentation 是否一致，而不是靠肉眼报告去猜「model 对但没画上去」还是
  「model 本身就没写对」。这是本轮唯一留到下一次真机证据才能真正验证的部分。
- **(c) 浮动字块是否在激活时被移出 `mainTextLayer` 挂到行根层（脱离 0.35 约束）** —
  排除。`grep -n "addSublayer"` 找到全部 6 处 `addSublayer` 调用，dim 字块只在
  `ensureMainWordGlyphLayerCount`（`mainTextLayer.addSublayer(dimLayer)`）里创建一次，之后
  代码里没有任何 `removeFromSuperlayer`/重新 `addSublayer` 的调用——层级在整个生命周期里固定，
  不存在"浮动时逃出暗底约束"的路径。
- **(d) `mainDimCompensationActive=appliesMainSweep` 为 false 的分支（行级/无 wordRuns 时）
  `mainTextLayer` 直接 opacity=1** — 部分属实，已加固。`appliesMainSweep`/
  `mainDimCompensationActive` 原先只在 `updateTextLayers()`（由 `configure()` 触发）里计算一次；
  而 `configure()` 只在这一帧 `RowRenderKey` 变化（含 `isCurrent`）时才被调用。核对
  `RowRenderKey.isCurrent = row.index == configuration.effectiveTextActiveIndex` 后确认：常见的
  「激活状态改变」场景本身就会让 key 变化、从而触发 `configure()` 重算——所以这条本身不太可能是
  这次真机现场的直接根因，但作为纵深防御，本次已把 `mainDimCompensationActive`/
  `translationDimCompensationActive` 的计算移进 `updatePlaybackPhase`，让它**每帧**都从当前
  `expectsPerRunSweep`/`isActive` 重新推导，不再仅仅依赖 `configure()` 触发的路径，堵死一切
  「本帧只跑了 `updatePlaybackPhase` 没跑 `configure()`」的旁路。

结论：(a)(c) 已用代码证据排除；(d) 已加固（即便不是这次真根因也不该依赖 configure() 才重算）；
(b) 是唯一「模型对但没画上去」假说，已埋好下一次真机复现时能直接读出 presentation 值的探针，
现有证据文件（rowdump 时间戳 09:21:16）读到的是「seek 后已经过了几个可复现 tick，任务 1 的地板
0 bug 已经开始发作」这个窗口，无法回答「founder 肉眼那一刻」与「rowdump 落盘那一刻」是否是同一
渲染帧——这就是为什么(b)必须留给下次真机证据，而不是靠本轮日志倒推。

## 任务 2（排查未完成，未提交代码改动）：「未来的旅程」尾字重影

### 现场
`rowdump_lvcheng.txt`（84.7s，row 9「只有你能带我走向未来的旅程」13 字，网易逐字版，宽
186pt，第一行 8 字第二行 5 字）：
1. row 9 的 `mainTextLayer`/`mainBrightTextLayer`/`mainEmphasisLayer` frame 高度是 54，同样两行
   的 row 10 是 58。
2. row 9 第二行的 dim/bright 字块 y 在 22.07–23.65（浮动中）、「程」静止在 y=24.0；row 10 第二行
   静止字块 y=28.0。

### 已排除的假设
用真实生产函数（`NativeLyricsTextRenderPlan.make` + `NativeLyricsTextSweepLayout.layoutSnapshot`
+ `NativeLyricsTextMeasurement.metrics` + `NativeLyricsRowView.displayWrapped`）对完全相同的 13
字字符串（单字一词、宽 186、字号 24 semibold）做隔离探测：

```
METRICS height=48.0 lineCount=2 usedRect=(0,0,182.8,48.0)
SNAPSHOT lineCount=2 fragmentHeights=[24.0, 24.0] fragmentMinYs=[0.0, 24.0]
WRAPPED = 只有你能带我走向|未来的旅程
```

两套排版（`displayWrapped` 用的 NSLayoutManager 路径 与 `NativeLyricsTextSweepLayout` 用的
NSLayoutManager 路径）在隔离场景下**完全一致**——高度都是 48（2×24），第二行 minY 都是 24，
换行点都是 8+5。这排除了「两套排版天生对不上」这个最初的静态公式假设：问题不在
`displayWrapped`/`NativeLyricsTextSweepLayout` 的参数配置分歧（字号/宽度/段落样式已核对完全
相同）。

进一步用真实 `NativeLyricsSurfaceView` + 真实 word-level 行驱动到激活中段/尾段/完全退出后采样，
写了两条探索性测试：
- 「帧内 applied frame height 是否始终等于 fresh `measuredHeight(width:)`」——在我的测试夹具里
  100% 不等（applied 恒为 54，measured 恒为 64），但差值和真机的 54 vs 58 不是同一现象：我的
  `config()` 夹具里 `onHeightMeasured` 是空实现，从不把测量值喂回 `accumulatedHeights`，这条
  测试测的是我夹具本身缺一层真实 surface 才有的高度回填闭环，不是真根因，已经作废删除。
- 「完全退出激活后，尾字三个字块的 Y 是否互相一致」——ySpread≈0.745pt，非零但很小；追查发现
  `baseFloat()`（`NativeLyricsTextRenderPlan.swift`）的设计是词一旦开始唱就**永久停在 targetY
  (-2pt)**，不会在词结束后弹回 0（这是 v2.8 "float and hold" 的既有设计，不是 bug）；而我采样
  的时间点（尾字完全退出激活 2s 后）此时 `mainDimWordGlyphLayers`/`mainBrightWordGlyphLayers`
  已经被 `applyInactivePlaybackLayerState()` 隐藏——我读到的是隐藏层的陈旧坐标，不是真实渲染中
  的內容，这条测试也作废删除。

### 结论
静态排版层面（NSLayoutManager 参数/字号/宽度/换行点/行高）经隔离验证完全自洽，不是本次真机截
图的根因所在。真正的重影很可能是一个**窄时间窗的瞬态**——发生在「浮动仍在进行 / 刚好跨过
deactivation 边界」附近的一两帧，需要在真机上于**肉眼看到重影的那一刻**重新抓取
`nanopod://debug/rowdump`（这次的两份证据文件时间戳分别是 09:24:40 与 09:24:41，是否精确对上
founder 报告重影的那一帧无法确认）配合本次任务 1 新增的
`layer.presentation()?.opacity`/`superlayer` 字段，或者在真机上开 `NANOPOD_MASK_TRACE=1` 常驻
写 `/tmp/nanopod_mask_trace.jsonl` 后复现一次并标注时间戳。

按项目「先复现再修」铁律：未能在代码层面稳定复现前，不动 `NativeLyricsTextSweepLayout`/
`displayWrapped`/`measuredHeight` 相关代码——本份报告记录已排除的假设与排查方法，留给下一次
真机证据到手时继续。

### 后续建议
- 下次「肉眼看到重影」时，立刻连打两次 `nanopod://debug/rowdump`（间隔尽量短，覆盖前后各一
  帧），并同时截取当时的 `mainPostLineFadeFloor`/`baseFloatY` 相关 debug 日志（若已开
  `NANOPOD_PROBES`）。
- 若下次证据显示 `mainTextLayer.frame.height` 与 `measuredHeight(width:)` 在那一帧确实不等
  （不同于本次静态探测里两者恒等的结论），再回来改 `accumulatedHeights` 回填时序；若显示的是
  浮动字块与已恢复的整行暗底出现瞬时 Y 错位，则要看 `applyInactivePlaybackLayerState`/
  `finalizeDeactivationState` 与浮动动画收尾的时序竞态，而不是排版公式本身。
