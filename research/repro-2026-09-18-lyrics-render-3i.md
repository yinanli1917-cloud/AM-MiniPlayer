# 阶段包 3i 逐条报告（2026-09-18，创始人裁定顺序 2→1→3→4）

Worktree: `.claude/worktrees/agent-a6961bf3b2bbfdfcf`（分支 `worktree-agent-a6961bf3b2bbfdfcf`），基线 main=`c25639f`（阶段包 3h）。

起点问题：worktree 分支停在旧的 09-11 提交（277cd5b），已 `git merge --ff-only c25639f` 快进到指定基线（277cd5b 是 c25639f 的祖先，working tree 干净，无冲突，无独有提交丢失）。

## 状态总览

| # | 项目 | 状态 | commit |
|---|------|------|--------|
| 2 | 播到一半从头播：三点顶上+激活行停曲中+误判暂停 | **真复现 + 真修复** | `fcb5004` |
| 1 | 冷启动三点跑到面板顶部 | **真复现 + 真修复**（根因与创始人猜测不同，是独立的 amllState 长期 bug） | `dbfcabc` |
| 3 | 中文行尾字重影（模糊副本） | **真复现 + 真修复** | `12194c4` |
| 4 | 遮罩拉满/消失（掉帧/回跳/连击/双 configure） | 四个变体均**未复现** | `28a3d45`（测试覆盖，无修复） |

四条：三条真复现+真修复，一条穷举未复现（如实记录，未编造）。`swift test` 全量结果见文末。

---

## 第 2 条：播到一半从头播（真机日志硬证据）

**证据**：/tmp/nanopod_debug.log 15:01:38 起，Music 位置 83.2→0.0（从头播），日志自己记录 `reason: position jump 83.2s→0.0s`（`positionJumpedBack` 检测器已经识别出这是真实跳变），但同一次 poll 里另外两个独立判断——`shouldDeferTransientReset`（读同一组 position/duration 数字）和基于速度差的暂停推断——各自得出相反结论：前者连续 3 次 `TRANSIENT POSITION RESET: ignored`，后者 `VELOCITY PAUSE ... inferring pause` 把 `isPlaying` 错误打成 false。

**根因**：`MusicController.pollPositionViaSB` 里三个检测器读同一次 poll 的原始数字，但彼此不通气。`positionJumpedBack`（连接跳变>=3s、非 seeking）已经确认这是真实的位置跳变，但 `shouldDeferTransientReset`（backward jump>8s 的独立判定）和速度差暂停推断完全不知道这件事，各自重新推导，结论互相矛盾。

**修复**（`Sources/MusicMiniPlayerCore/Services/MusicController.swift`）：
1. `PlaybackPositionCorrectionPolicy.shouldDeferTransientReset` 新增 `positionJumpedBack: Bool` 参数，为 true 时无条件返回 false（不再 defer，不受 deferral cap/duration-near-end 例外影响）。
2. 新增纯函数 `shouldInferPauseFromVelocityDeficit(deficit:positionJumpedBack:)`，同样在 `positionJumpedBack=true` 时不推断暂停。
3. `pollPositionViaSB` 里已经计算好的本地 `positionJumpedBack`（同一个闭包作用域内，无需跨线程传递）直接传给上面两处调用点。

**测试**：`PlaybackClockTrustTests.swift` 新增 `test_confirmedPositionJump_isNeverDeferred_evenWithinDeferralCap`、`test_velocityPauseInference_suppressedByConfirmedPositionJump`，用真机日志的确切数值（83.2→0.0，deficit=83.2）钉死；改前红改后绿。

**附带排查**：日志里还有一条"无人操作的 `phase=manualStart idx=1`"。逐一核对 `NativeLyricsManualScrollState.begin(...)` 的所有调用点：生产代码里只有一处（`handleNativeScrollWheel`），且严格挂在真实 NSEvent 滚动增量上（非 momentum 的 `event.phase==.began`，或已持有手势所有权时的持续增量）——没有任何代码路径能在没有真实滚动事件的情况下进入这个状态。记为**结构性排除**，不是本条修复范围内的独立 bug，更可能是那几秒困惑窗口期间创始人真的做了一次意外触控（本身是上面这个 bug 造成的连锁反应，不是新 bug）。

---

## 第 1 条：冷启动三点跑到顶部

**创始人猜测**：3h 是 047f401（`seekGenerationChanged` 被当成 `nativeSeekDiscontinuityOccurred` 触发条件）引入的回归，且很可能与第 2 条同根。

**实测结果**：两者都不完全对，但排查方向对——本条最终定位到一个完全独立、比 3h 更早就存在的 bug。

排查过程：
1. 先写了两个测试复现"seekGenerationChanged 误判"猜测（`test_coldStartWithPriorSeekHistory_...`、`test_newTrackColdStart_whileManualScrollStaleActiveFromPreviousTrack_...`）——都是绿的。代码读证实 `nativeSeekDiscontinuityOccurred` 唯一的两个消费点（post-line fade floor 重置、强制刷新文本/点相位）都不直接决定行的 Y 坐标，047f401 这部分改动是无辜的。
2. 按创始人建议的"app 启动时 Music 已在播放中段，然后从头播"复现路径（`test_coldStartWhileMusicMidSong_thenRestartToZero_droppedFrameVariants_preludeRowAnchored`，覆盖 100/250/500ms 掉帧变体）——**真红了**：`scrollTargetIndex` 卡在 1（第一条真歌词行），`semanticIndex` 却正确落在 0（前奏行），前奏行渲染在 y=148 而非锚点 200。三档掉帧变体结果完全一致（148.0），排除是弹簧未稳定的过渡帧。

**根因**：`NativeLyricsTimelinePolicy.amllState`（与第 2 条、与 047f401 都无关，是一个更早就存在、且已经被 3h 自己的测试当作"已知未修复缺陷"钉住的 bug——`LyricsRenderDefects20260914ReproTests.test_amllState_backwardSeekIntoPreludeWindow_withCorrectFallback_scrollTargetStillDivergesFromSemanticIndex`，2026-09-14 就写了，当时的断言是"BUG reproduced"）：一次 seek 落在"还没有任何真实歌词行开始过"的窗口（前奏/intro）时，`scrollToIndex` 在 `bufferedGroups` 为空时无条件偏向 `firstFutureIndex`（下一条真实行），完全不检查是否真的有过任何行开始——而 `semanticIndex` 自己有一条经过 `latestStartedIndex` 的回退链，正确落在前奏行。两个值就此分裂。

**修复**：新增 `anyRealRowStarted` 判断，"没有任何真实行开始过"这个分支改为走 `semanticIndex` 自己信任的同一条 `latestStartedIndex` 回退链（不再信任可能过期的 `previous.scrollToIndex`）；`firstFutureIndex` 分支保留给它真正该覆盖的场景——歌曲已经在播、seek 落在两条真实行之间的空档。

**测试**：`test_amllState_backwardSeekIntoPreludeWindow_withCorrectFallback_scrollTargetStillDivergesFromSemanticIndex` 改名为 `..._scrollTargetMatchesSemanticIndex`，断言从"必须不相等"改为"必须相等"（真实反映修复后的契约，不是删测试逃避）；配套的 stale-fallback 姊妹测试断言不受影响（本来就不是 0）。`ManualScrollSeekReleaseTests` 三个新测试 + 掉帧变体全绿。

---

## 第 3 条：中文行尾字重影

**方法**：先整份读完三份 rowdump 证据（`rowdump_1/2/3.txt`），再动手，按吩咐的顺序。

**先排除一个错误理论**：dump 里"非激活行的 dim-base string 只显示第一视觉行 7 个字"看起来像是"dim-base 没有第二行文本"，但读 `NativeLyricsRowView.rowDumpLines` 代码发现 `string.prefix(8)`——dump 本身把每层的字符串截到前 8 个字显示，这是**展示层的截断**，不是层的真实内容缺失。这条理论在读到这行代码后就站不住了，没有继续往这个方向修。

**真根因**：对比两套独立的换行宽度来源——
- dim-base（`applyFloatingHiddenBase`）用 `contentTextWidth(configuration)`（`configuration.rowWidth` 减边距，配置时刻已知，其自己的文档注释写明"唯一权威来源，绝不用 bounds.width，因为它在新建/复用视图完成 layout() 前可能是陈旧值或 0"）。
- 亮字逐字扫描布局（`applyActiveMainPhase` → `mainSweepLinePlan`）却在用 `mainBrightTextLayer.bounds.width`——恰好是上面那条注释警告不能用的量。`bounds` 由 `layout()`（AppKit 布局通道）维护，`layout()` 自己还有记忆化门槛，是与 `configure()` **不同的调用**。掉帧/延迟布局时，一次新宽度的 `configure()` 落地后、布局通道还没追上之前，播放相位更新就可能已经用旧 bounds 跑了亮字布局。

**直接复现**：真实 `NativeLyricsRowView`，先在宽面板（单行）稳定配置，再改窄面板（强制两行/三行换行）但**不给 AppKit 一次布局机会**（不调 `layoutSubtreeIfNeeded()`）就触发播放相位更新——dim-base 正确按新窄宽度换行（3 行），亮字逐字瓦片仍按旧宽度铺（单行范围）。dim-base 新出现的第二三行文字完全没有对应的亮字瓦片盖在上面——纯 dim（0.35 不透明度）的墨迹，正是"模糊副本"的形状。

**修复**：`applyActiveMainPhase` 改用 `contentTextWidth(configuration)`（配置存在时）作为亮字扫描布局的宽度来源，与 dim-base 统一；`geometryReady` 的宽度检查保留读真实 `bounds`（它问的是"这行有没有被布局过"，不是"该用什么宽度换行"，两者含义不同不能混）。

**测试**：`NativeLyricsTrailingLineWidthRaceTests.test_reconfigureAtNarrowerWidthWithoutLayoutPass_dimBaseWrapsButBrightGlyphsDoNot`——改前红（亮字 Y 带数=1，dim-base 换行数=3），改后绿（两者一致=3，用真实 Y 坐标验证三个视觉行都对齐：13pt/39pt/63pt）。

**回归检查**：单独跑 `NativeLyrics*`/`LyricsRenderDefects*`/`GlyphLayout*`（323 个测试）发现 4 个失败，逐个确认为 `NativeLyricsRenderChurnTests.test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff` 的既有失败——临时把本条修复的文件回退到上一个 commit 重跑，同样失败，证实是**基线本就存在的失败**，与本条改动无关，未去动它（不属于本次任务范围）。

---

## 第 4 条：遮罩拉满/消失

按创始人给的 (a)(b)(c)(d) 四个变体逐条实现，全部基于既有 `NativeLyricsSeekLandingMaskTests` 的落地帧采样框架：

- (a) 掉帧变体：落地那一帧本身用 100/250/500ms 而非理想 1/60s，4 行 × 3 个 seek 位置 × 3 档帧长 = 36 个用例。
- (b) 手动滚动→tapToLine：冻结在一行后，直接点击另一行——这条路径走 `semanticSpringRetarget(reason: .tapToLine)`，完全不经过 `mc.seek(to:)`/`seekGeneration`，是结构上独立的入口。新增 `debugTapLine(index:line:)` 测试缝（暴露生产的 `handleNativeLineTap`，理由与既有的滚轮缝一致——真实点击是无法在无头环境伪造的 NSEvent）。
- (c) 连续 5 次间隔 <1s 的回跳。
- (d) 同一落地帧内 `configure()` 被调用两次（对应 HANDOFF 提到的 `applyFrame` 两个调用点）。

**结果**：四个变体全部通过（0 违规）。按项目铁律，如实记为**未复现**，不是"没有这个 bug"——创始人的真机证据仍然是最强证据，只是这四个合成角度没抓到触发条件。现有的 `brightUnmaskedIncomplete` 生产探针继续留着等真实触发条件出现时自动留证。

---

## 收尾

commit 列表（按提交顺序）：
- `159475b` test — 第 1 条最初两个复现尝试（当时未复现）
- `b559eba` docs — 中途诚实进度报告（已被本文件取代）
- `fcb5004` fix — **第 2 条真修复**
- `dbfcabc` fix — **第 1 条真修复**（amllState scrollToIndex）
- `12194c4` fix — **第 3 条真修复**（亮字/dim-base 换行宽度统一）
- `28a3d45` test — 第 4 条四变体覆盖（未复现）

均未 push。

`swift test` 全量结果：见本次任务末尾的执行输出（本文件写就时后台仍在跑，最终数字以任务完成汇报为准）。

*报告人：Claude Sonnet 5。第 1/2/3 条都是真实、此前未被抓到（或虽被抓到但未被认领）的根因+修复；第 2 条根因最扎实（真机日志逐行对应）；第 1 条推翻了创始人最初的猜测但仍然是真 bug；第 3 条率先证伪了最直觉的理论（截断误读）才找到真根因；第 4 条如实记录未复现，没有为了"完成任务"编造修复。*
