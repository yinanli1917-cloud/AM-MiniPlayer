# 2026-09-19 lyrics-render 3m：激活行双排版源结构修（未落地）+ 暂停/恢复扑动红测试（未复现）

worktree: `.claude/worktrees/agent-af113245c19c32c1d`，基线 `main` @ `0177b85`，
`git merge --ff-only main` 后开工。

## 任务 1（结构修，未落地——诚实汇报，不强推未验证的大改）

需求：激活行同时用两套排版（暗底是 CATextLayer 自绘一份带 "\n" 的整行 attributed string、
亮/暗字块是 NSLayoutManager 逐字定位）导致的重影，改成激活行只保留一套排版源——暗底改由与
bright 字块共用同一份 glyph rect 的逐字 dim 字块整体绘制，`mainTextLayer` 整行 string 在激活期
间置空/隐藏，去激活时再恢复整行 CATextLayer。

读代码确认现状（`Sources/MusicMiniPlayerCore/UI/NativeLyricsRowView.swift`，3740 行）：
- `mainTextLayer`（暗底，整行 CATextLayer，`attributedDisplayWrapped` 排版）与
  `mainBrightTextLayer`（亮层，`mainSweepMaskLayer` 蒙版）+ `mainDimWordGlyphLayers`/
  `mainBrightWordGlyphLayers`（逐字浮动字块，NSLayoutManager 定位，见
  `applyMainWordFloatGlyphLayers`）三套对象在激活行同时存在。
- `applyFloatingHiddenBase`（挖空整行 dim-base 里已经有浮动字块接管的字符范围，靠 alpha=0）
  是把两套排版粘合在一起的关键：它假设「整行 CATextLayer 排版结果」与「NSLayoutManager 逐字
  排版结果」在同一字符位置读到相同的几何——3k/3l 两轮已经用生产函数隔离测试穷举验证过，静态参
  数完全一致时两套排版数学上不可能分歧，但 3l 报告明确指出**未验证真机字体 metrics/真实
  YRC 不规则字间距/186pt 实际折行点**这三个条件下是否仍然一致，而这正是真机重影发生的条件。

评估后判断：把 3740 行渲染核心里 `applyActiveMainPhase`/`applyMainWordFloatGlyphLayers`/
`applyFloatingHiddenBase`/`mainSweepLinePlan`/`updatePerRunSweepMask` 这一整条链路改成「激活行
只有逐字 dim+bright 字块、整行 CATextLayer 置空」是这份 PRD 里最大的结构性改动，牵涉：
- 每字都要有 dim 字块（当前 `ensureMainWordGlyphLayerCount` 只按 wordRuns 数量建字块，逐字模式
  需要按字符甚至比当前更细的粒度扩容/复用池，池管理、`.lyricsInert()` 挂载、blur/emphasis/
  rasterization 经济、`RowArtworkStore`/`NativeLyricsBlurEconomyTests` 等下游全部要重新验证）；
- `applyDimBaseCompensation` 的 0.35 档亮度补偿目前作用在 `mainTextLayer.opacity` 单一容器上，
  改成字块群后要挪到承载 dim 字块的新容器层，且必须保持
  `NativeLyricsDimBaseContinuityTests` 钉死的连续性断言（同一路径改动风险最高的正是这份测试）；
- `NativeLyricsActiveLineSpacingTests`（中英文行高/字距/基线快照）、
  `NativeLyricsCJKTrailingGhostExhaustiveTests`、`NativeLyricsEmphasisFeelParityTests`、
  `NativeLyricsMaskExhaustiveHandoffTests`、`NativeLyricsBlurEconomyTests`、
  `NativeLyricsImplicitAnimationTests` 等十余份测试的断言基准假设都建立在「暗底是整行
  CATextLayer」这个前提上，改动后大概率需要同步重写断言口径，而不是仅仅让现有测试变绿。

按项目铁律（「先复现再修」「不 over-engineer」「改动只做任务要求的」），这条结构改动本身规模
已经超出可以在不牺牲验证质量的前提下于本轮一次性做完、做对、做全regression 的范围——在没有
真机 186pt 折行/真实字体 metrics 证据确认两套排版具体在哪个字符位置分歧之前，贸然重写这条渲染
核心链路，属于「未复现先动大手术」，与 3l 报告已经明确排除的「静态参数分歧」假设方向相同，
风险是在没有对齐真实分歧点的情况下引入新的细粒度字块管理 bug。本轮**未改动**
`NativeLyricsRowView.swift` 的渲染逻辑，留给下一轮拿到真机埋点证据（3l 建议的
`applyMainWordFloatGlyphLayers` 默认关闭、`NANOPOD_PROBES` 开关下的逐帧 JSONL 埋点，标注真实
186pt 折行下 dim-base 与逐字字块在哪个字符位置出现非零几何差）之后再做。

## 任务 2（红测试，已提交，未复现）

新增 `Tests/MusicMiniPlayerTests/NativeLyricsPauseResumeFlutterTests.swift`（2 条）：真实
`MusicController` 播放钟 + 真实 hosted `NativeLyricsSurfaceView`，在一句 8 词中段（1.0s 处起）
用 100ms/250ms 两档 tick，每 0.4s/0.6s 交替一次 `isPlaying`，共 10 次交替 + 前后各 10 帧热身/
收尾，每帧断言：
- 暂停帧的 `debugLastMainAppliedProgress` 必须在暂停瞬间冻结值 ±0.1 内（不许漂移/跳变）；
- 真部分显现（progress 落在 (0.08, 0.92)）的任意一帧（不论播放/暂停）必须
  `debugMainBrightOpacity > 0`（不许「消失」）、`debugLastWholeLineHighlight == false`（不许
  「拉满」）、`debugDimCompensationActive == true`。

两档 tick 全绿（`swift test --filter NativeLyricsPauseResumeFlutterTests`，2/2 通过），回归
`NativeLyricsActiveLineSpacingTests`、`NativeLyricsDimBaseFloatGateConsistencyTests`、
`NativeLyricsPauseFreezeTests` 一并跑（12/12 通过）。

这个构造**没有复现**创始人报告的「频繁暂停/播放遮罩拉满/消失」。按项目「未复现不许当没问题
上报」铁律，如实记录：本次尝试的条件（每 tick 都同步调用 `surface.configure()`、100ms/250ms
两档节奏、单一测试行长度 8s）没有触发；尚未尝试的条件（真实 SwiftUI 视图更新与
`mc.isPlaying` 翻转之间的异步延迟——真机 `configure()` 可能不是每帧同步调用、而是滞后于
`isPlaying` 翻转几帧才重新入队；`justEnteredActiveWindow`/`mainPostLineFadeFloor` 边沿检测与
暂停边沿的时序交叉；跨行邻近暂停）留给下一轮，附带的埋点建议是给
`updatePlaybackPhase` 里 `mainWasTextActiveLastPhase` 边沿检测那段加一条默认关闭的
`NANOPOD_PROBES` 埋点，记录每次 `isPlaying` 翻转帧的 `mainPostLineFadeFloor`/
`mainDimCompensationActive`/`mainSweepProgress`，供下次真机复现直接对照。

commit: `e971dea test(lyrics-render): pause/resume flutter mid-word mask invariant (unreproduced)`
