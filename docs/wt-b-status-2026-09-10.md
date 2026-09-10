# WT-B 歌词渲染：行距与切行动画 — 状态 2026-09-10

分支 `claude/nice-archimedes-0d8856`（worktree nice-archimedes-0d8856）。规划/验收 Fable 5.1，写码跑测 Sonnet 5。

## B1 行距漂移 — 结论：harness 伪影，已收口（ba7c79c）
- 80c5a7e 的两条 XCTExpectFailure 复现测试量的是 `view.frame` 几何，模糊不可能改 frame；其「模糊足迹撑开行距」诊断与测量对象不符。
- 实跑 6/6：surface 真正的激活行是 8→9（墙钟 line-advance Timer 在 settle 窗口内多推 3 行），测试只排除 {5,6}，激活行自身位移漏进断言。
- `NativeLyricsSnapMath.targetY` 只依赖累计行高 + anchor，不依赖与激活行的距离；行高每行恒 44。
- 改为锁步注入时钟驱动并断言激活对正确，两条测试 3/3 绿，去掉 XCTExpectFailure。
- 因此「行距是否随模糊变化」这个请示前提不成立，不送裁决。创始人感受到的「行距变」最可能是 B2 的顶→底波浪（下文）或模糊光晕的视觉扩张，后者不改几何。

## B2 退场/入场时钟不同步 — 结论：契约规定的 AMLL 波浪，非 bug（5c332d2）
锁步时钟下八行起始时刻（`NativeLyricsWaveOnsetTableTests`）与 `LyricWaveTiming.staggerSchedule` 逐行吻合：

| 行 | 设计 | 实测 | 07-27 录屏（41.6fps） |
|---|---|---|---|
| 退场行 i | 160ms | 150ms | 0（基准） |
| 入场行 i+1 | 240ms | 233ms | +96ms |
| i+2 | 320ms | 317ms | +120ms |
| i+3 | 396ms | 383ms | +120ms |
| i+4 | 469ms | 467ms | +216ms |

入场行 opacity 与位移同帧起。staggerSchedule 自 07-20 至今无改动。08-27 的 damping 20 只改视觉弹簧阻尼，不改错峰。
**待创始人裁决（一条）**：是否保留「入场行比退场行晚一拍（80ms）、下方逐行再晚一拍」的顶→底波浪；若要改，方向是入场与退场同帧起、波从入场行向两侧扩散。这是手感取舍，合并到 B6 终验一起看。

## B3 激活行亮度封顶 162 — 部分复现，修复中
- 复现到同类缺陷：窗口被遮挡时 `presentationTick` 直接返回、loop 停摆，入场行 opacity 冻在 0.35，解除遮挡后不追赶、从头收敛；1s 遮挡把亮度达标推迟到边界后 ~1.9s（`NativeLyricsOcclusionBrightnessTests` S4 红）。
- 录屏形状（遮挡解除 7s 后激活、整段稳定 0.65）尚未复现。按铁律：修已复现的 S4（解除遮挡时弹簧直达目标），并加一次一行的 DEBUG 埋点 `ActiveBrightness`（每次切行后 1s 记一行 rowOp/bright/dimTier/eff/deferred/occluded）。
- 顺带核实：`NativeLyricsRenderChurnTests/test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff` 在 HEAD 基线安静机器上 2/3 红，墙钟节奏型旧 flaky，非本分支引入；列为后续项（改锁步时钟）。

## B4 点=真行 — 已出代码地图，未动手（排 W3）
- 修正任务描述：`LyricDisplaySegmenter` 只做换行分段，不含间奏逻辑。真正要动的是 LyricsService（`interludeAfterIndex` 源头 :106/:706/:1899/:1902-1917）、LyricLayerRowBuilder（isPrelude 标志）、LyricsPresentationModels + NativeLyricsUXMetrics（blend/anchorAdvance 数学）、LyricsLayerRendererView（渲染时消费，22 处）。Sources 约 55 处，Tests 约 40 处/34 文件。
- 现无「configure 中段→settle→同轨从头→激活行应在 anchor」的复现测试，这是 B4 第一步。
- 已与 WT-A 约定：删 LyricsService 那四处前先发消息。

## B5 性能收口 — 脚本就位，待实测时机
- 采样脚本与操作手册在 scratchpad `b5/`（`b5_cpu_ab.py`：ambient / window / pair / gate4 / gate5 / idle-gate，`top -l 2` 取区间 CPU，紧邻配对差值，dry-run 六条全通）。
- 实测要占创始人机器 + 播放音乐，需安静桌面（关 TRAE/Chrome/录屏），约 3 轮 × 30s × 3 个门。请主会话安排时机。

## B6 切行手感终验 — 归创始人
出阶段包时提醒：看一次普通切行（上一行 ~0.15s 内不动，然后位移/变暗/亮层同起）、看 B2 波浪要不要改。
