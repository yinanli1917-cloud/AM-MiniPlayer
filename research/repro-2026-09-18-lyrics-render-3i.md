# 阶段包 3i 进度记录（诚实中断点，2026-09-18）

Worktree: `.claude/worktrees/agent-a6961bf3b2bbfdfcf`（分支 `worktree-agent-a6961bf3b2bbfdfcf`）。
起点问题：worktree 分支停在旧的 09-11 提交（277cd5b），已 `git merge --ff-only c25639f` 快进到指定基线（277cd5b 是 c25639f 的祖先，working tree 干净，无冲突）。

## 状态总览

| # | 项目 | 状态 | commit |
|---|------|------|--------|
| 1 | 冷启动三点跑到面板顶部（3h 回归） | **未复现**（两个变体均绿） | `159475b` |
| 2 | 播到一半再从头播：三点顶上+激活行停曲中 | 未开始 | — |
| 3 | 中文行尾字重影（行级歌逐字浮动瓦片） | 未开始 | — |
| 4 | 遮罩拉满/消失（掉帧/回跳） | 未开始 | — |

**如实说明**：受限于本轮时间预算，只完成了第 1 条的两轮复现尝试，2/3/4 完全未动手。按项目「未复现不许当没问题上报」的铁律，第 1 条如实记为「未复现」，不编造修复。

## 第 1 条：冷启动三点跑到顶部

**嫌疑机制**：047f401（`LyricsLayerRendererView.synchronizeNativeSemanticIndex`）把 `seekGenerationChanged` 单独当作 `nativeSeekDiscontinuityOccurred` 的触发条件，用在两处：
- `releasingManualScrollFreeze = seekGenerationChanged && manualScrollState.isActive`
- 快照分支里的 `playbackModeSaysSeek || seekGenerationChanged`

冷启动时如果 `musicController.seekGeneration` 在这个渲染器实例第一次跑之前就已经非零（长驻 MusicController 之前的 track/session 留下的），而这个渲染器自己的 `lastObservedSeekGeneration` 还是初值 0，`seekGenerationChanged` 会读成 true——即使这根本不是一次真正的"释放冻结"。

**已写的两个测试**（`Tests/MusicMiniPlayerTests/ManualScrollSeekReleaseTests.swift`）：
1. `test_coldStartWithPriorSeekHistory_preludeRowAnchoredNotAtPanelTop`——纯冷启动（从未手动滚动过），MusicController 在渲染前已经 `registerSeek()` 三次。
2. `test_newTrackColdStart_whileManualScrollStaleActiveFromPreviousTrack_preludeRowAnchored`——上一首歌留下一个从未正常释放的手动滚动冻结（view 跨曲目不销毁，生产里的真实形状），换新曲目 + 隐式 seek 到 0。

**结果**：代码层面读 `nativeSeekDiscontinuityOccurred` 的消费点只有两处——`NativeLyricsRowView.updatePlaybackPhase` 里重置 post-line fade floor，以及 `presentationTick` 里强制刷新文本/点相位——都不直接决定行的 Y 坐标/是否被当作"当前行"锚定。两个测试跑满弹簧稳定时间后，前奏行都正确落在 anchorY（200），dots 都可见，不是"顶部/隐藏"。中途曾看到一次 168 vs 200 的失败，但补跑稳定时间后消失——那是弹簧还在飞行中的正常过渡帧，不是创始人报的稳态 bug。

**未尽的角度**（下一轮建议按序尝试）：
- 掉帧变体：本轮两个测试仍是纯 1/60s tick；任务明确要求的 100/250/500ms 长 tick、以及 configure() 同一 tick 内被调用两次的情况完全没试。这两个测试要在长 tick 下重跑一遍。
- "冷启动"也可能指真实 app 冷启动（MusicController 也是全新的，seekGeneration=0），此时创始人的复现路径可能包含一次"播放前先跳到某个已保存的播放位置"（PlaybackHistoryStore 的续播）——如果续播走的是 `registerSeek()`,而不是本轮两测试模拟的"渲染器早于其余状态创建"，需要单独建模续播路径。
- `directSnapRequest`/tap-to-line 路径尚未覆盖：`playbackModeSaysSeek` 分支里 `.tapToLine` 一支未单独测过与 seekGenerationChanged 的交互。

## 收尾

- 本轮 commit：`159475b`（两个新测试，均绿，未修复代码）。
- 未 push。
- `swift test` 全量本轮未重跑（范围仅测试文件新增，未改动生产代码，无需要担心的回归）。

*报告人：Claude Sonnet 5。本轮进度远低于任务要求的四条全覆盖，如实记录以便下一轮接手，不编造 2/3/4 条的复现或修复结果。*
