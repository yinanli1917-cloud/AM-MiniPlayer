# WT-B 歌词渲染：行距与切行动画 — 状态 2026-09-10

分支 `claude/nice-archimedes-0d8856`（worktree nice-archimedes-0d8856）。规划/验收 Fable 5.1，写码跑测 Sonnet 5。

## B1 行距漂移 — 测试伪影已清，肉眼诉求待证据（ba7c79c）
- 80c5a7e 的两条 XCTExpectFailure 复现测试量的是 `view.frame` 几何，模糊不可能改 frame；其「模糊足迹撑开行距」诊断与测量对象不符。
- 实跑 6/6：surface 真正的激活行是 8→9（墙钟 line-advance Timer 在 settle 窗口内多推 3 行），测试只排除 {5,6}，激活行自身位移漏进断言。
- `NativeLyricsSnapMath.targetY` 只依赖累计行高 + anchor，不依赖与激活行的距离；行高每行恒 44。
- 改为锁步注入时钟驱动并断言激活对正确，两条测试 3/3 绿，去掉 XCTExpectFailure。
- 因此「行距是否随模糊变化」这个请示前提不成立，不送裁决。但创始人肉眼看到的「行距变」尚未有证据解释（候选：B2 顶→底波浪、模糊光晕的视觉扩张）。主会话 09-10 定：加一次一行的 DEBUG 埋点（激活行前后行距、行高、基线），随阶段 bundle 让创始人日常使用留证，拿到证据再判；B1 不标关闭。

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
主会话 09-10 定：不单独送裁决，并入 B6 终验；出 bundle 时提供两个对照臂 `nanopod://debug/feel/wave/topdown`（现行）与 `wave/sync`（入场与退场同帧起、波从入场行向两侧扩散），创始人自己切着看。

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

## B5 附录（2026-09-11 实测）

**二进制**：`nanoPod.app/Contents/MacOS/nanoPod` md5=`55fa543f7bd2ca07dff0f418e543277c`（与要求值一致）。
BuildInfo.txt: `version=0.29 build_time=2026-08-28T03:58:00Z git=fef1fff release_sha256=494e7eb8… auto_update=disabled`。

**时间窗**：16:41–16:48 PDT（硬窗 16:40–17:10，17:08 前停测，全部完成）。

**环境**：`uptime` 起测 load average 2.28/3.59/4.39，测到一半升到 5.19/4.14/4.34 — 未满足 README「安静桌面」前提，绝对值不可比，仅信邻近配对差值。ambient WindowServer 中位数本身就到 44–47%，比记忆中的基线高得多，说明当时机器另有负载。

**曲目**：词级/逐字候选=葉子(電視劇《薔薇之戀》原聲帶版)（Library）；行级+译文候选=At Your Best (You Are Love)（Library，`showTranslation=1, translationLanguage=zh` 已是创始人原设置，未改动）。
**未能核实 syllable/逐字命中**：`~/Library/Application Support/nanoPod/Diagnostics/Live/nanopod_debug.log` 最后写入时间是 6-21，这次运行全程未追加一行 — release 二进制不出这份 DEBUG 日志（CLAUDE.md 记录过的"release-only编译坑"同类现象），grep 落空。改用 CPU 特征做弱代理：gate4 三窗 app 中位数 1.5–6.0%、p95 7.8–10.7%，弱于 README 记忆基线（sweep 8–18%），**未达≥3%硬门槛的第一窗（1.5%）**，即"确认在扫掠而非停在封面页"这一步没坐实，后续 gate4 数字仅供参考。

**窗口缩短**：README 默认 30s×3 轮，本次因时间硬窗压缩为 **15s×1 轮**（Gate4 做了 A-B-A 三步而非 3 轮）；60s 预热等待缩到 20s/10s。

### 表：per-window WS/app CPU（median/p95，%）

| label | WS median | WS p95 | app median | app p95 |
|---|---|---|---|---|
| ambient (app 未运行) | 46.9 | 48.2 | 0.0 | 0.0 |
| virgin (面板开,不播放) | 45.0 | 45.9 | 0.1 | 0.2 |
| paused_after_play (播完暂停) | 44.8 | 45.9 | 0.4 | 0.6 |
| gate4_A_raster_on_r1 (逐字歌,raster ON) | 39.7 | 44.4 | 1.5 | 10.7 |
| gate4_B_raster_off_r1 (同曲,raster OFF) | 50.3 | 54.8 | 4.9 | 9.2 |
| gate4_A_raster_on_r1b (同曲,raster ON 复位) | 39.3 | 45.9 | 6.0 | 7.8 |
| idle_gate_line_level_translation (行级+译文) | 44.1 | 59.9 | 6.8 | 9.7 |

### 邻近配对差值

- virgin − ambient：WS −1.9，app +0.1（面板打开本身几乎不加 WS 负担）
- paused_after_play − virgin：WS −0.2，app +0.3（**PASS**：README 门槛 WS≤+5 且 app≤0.5% 都满足，但见下"sample"证据）
- gate4 OFF − ON(r1)：WS +10.6，app +3.4（raster OFF 更贵，方向与"raster 帮忙"假设一致）
- gate4 ON(r1b) − OFF(r1)（A-B-A 的第二个 A）：WS −11.0，app +1.1 — 与上一步方向抵消，说明本轮环境漂移（load average 从 2.x 涨到 5.x）已经盖过了 raster 信号本身，**gate4 本次数字不可信，只能定性记录、不能定论**
- idle gate app 中位数 6.8% vs 门槛 ≤1.5%：**表面 FAIL**，但同一时段 ambient/WS 已异常高且 gate4 也自相矛盾，更可能是环境噪声而非真回归；需要在安静机器上重测才能定论

### sample_paused.txt（5s，paused_after_play 窗口后）

`CA::Transaction::commit` / `CVDisplayLink` / `presentationTick` 出现次数均为 **0** — 暂停后主线程确实无持续提交，闲置判定成立（与 B5 idle-loop 目标一致）。

### LoopStop 日志证据

无法核实——本次运行 `nanopod_debug.log` 全程未写入新行（release 构建不出此 DEBUG 日志，最后一条记录停在 2026-06-21），grep `LoopStop`/`LoopStopVeto` 落空，非"确认无触发"，而是"这条通路本次不可观测"。

### PASS/FAIL 小结（均需在安静机器复测确认）

| 门 | 本次读数 | README 阈值 | 判定 |
|---|---|---|---|
| gate5 paused−virgin | WS −0.2, app +0.4% | WS≤+5 且 app≤0.5% | 表面 PASS，但见上方环境噪声说明 |
| gate5 sample | commit/CVDisplayLink/presentationTick=0 | 应为 0 | PASS |
| gate4 OFF−ON | 方向不一致（+10.6 后又 −11.0） | OFF−ON≥0 视为"raster 未帮倒忙" | 不可判定，环境污染 |
| gate4 sweep 验证 | app 中位数最低 1.5% | ≥3% | **FAIL**（未能确认逐字扫掠强度），拉低 gate4 全部数字的可信度 |
| idle gate | app 中位数 6.8% | ≤1.5% | 表面 FAIL，同上原因存疑 |

### 遗留/未完成

- 未能核实所选歌曲确为逐字(syllable)源命中——release 日志不可用，仅有弱 CPU 代理，且代理本身未过 3% 门槛。
- 未按 README 做 3 轮×30s；仅 1 轮×15s（gate4 是 A-B-A 三步单轮）。
- 全程环境噪声大（load average 2.3→5.2漂移，WS 基线 39–60% 大幅波动），任何本附录里的绝对值和大多数差值都不能当结论用，只能当"需要在安静桌面重跑"的初步信号，尤其 idle gate 的表面 FAIL 需要复测才能确认是否为真回归。
- 建议后续在真正安静桌面、且允许 30s×3 轮的时间窗内重跑本附录全部四类窗口。

**收尾状态**：Music 已 stop、shuffle 恢复为 false（与开始时一致）；nanoPod 已退出（`pgrep -x nanoPod` 空）；`NANOPOD_BLUR_RASTER_OFF` 已 unsetenv（`launchctl getenv` 返回空）。未做 `git commit`。

### 更正：release 构建的调试日志开关（规划会话核实，2026-09-11）
- 附录里「release 二进制不出 DEBUG 日志」需更正为「release 默认关」：`DiagnosticsService.isOwnerDiagnosticsBuild` 只在 DEBUG/LOCAL_DEVELOPER_BUILD 为真，所以 release 不会自动调用 `setDiagnosticsFileLoggingEnabled(true)`，也不会把日志导到 Application Support。但 `DebugLogger.isEnabled()` 还接受 `UserDefaults` 键 `enableDebugFileLog`，且 release 里编译着 `DebugLogger.log`。
- 创始人开启方法（一次性）：
  ```bash
  defaults write com.yinanli.nanoPod enableDebugFileLog -bool YES
  ```
  重启 nanoPod 后日志写到 `/tmp/nanopod_debug.log`（release 未调 `setLogURL`，用 DebugLogger 默认路径）。关闭：`defaults delete com.yinanli.nanoPod enableDebugFileLog`。
- 因此 ec64853 提交说明里「DiagnosticsService 每次启动都开 DebugLogger」只对 DEBUG 构建成立；阶段包的 BuildInfo/说明必须附上面这条 defaults 命令，否则 ActiveBrightness / LineGaps 埋点在创始人机器上不落盘。
- B5 复测时同样先开这个开关，才能 grep `LoopStop`/`LoopStopVeto` 与 syllable 源命中。

## B5 附录 2（2026-09-12 安静复测）

**未执行测量** — 时间窗不足以安全完成。

- 窗口：本次会话被限定 15:00–15:14 America/Los_Angeles，测量须在 15:12 前收尾；实际检查耗时到 15:01:46 已用去部分预算，且 Gate 4 单轮 A-B-A 需要 3 次 quit/setenv/relaunch + 各 30s 采样（另加冷启动 settle），Gate 2 三轮 idle 另需 3×30s，Gate 5 还有 2 个窗口——三项合计远超剩余时间，无法在不冒着窗口切换到一半就被硬截断的风险下完成。
- 为避免中途被截断导致 app 处于错误 env/进程状态或 Music 播放状态被打乱，本次决定不启动任何 quit/relaunch 或 setenv 操作，仅做只读核对：
  - 二进制：`/Users/yinanli/Documents/MusicMiniPlayer/nanoPod.app/Contents/MacOS/nanoPod` md5 = `5bf3bf1d998a8e4375cc7e386aaf5c15`（与预期一致，BuildInfo git=e5a70c9）。
  - 运行进程：pid 55524，`comm` = 该 stage bundle 路径，与预期一致。
  - `launchctl getenv NANOPOD_BLUR_RASTER_OFF` 为空（未设置），核对时间 15:01:46。
  - Music.app：15:01:34 读到 "Lawns" / Chihiro Yamanaka / playing / position 189.6s / shuffle false / repeat off——仍是创始人原状态（同曲、播放中），无需恢复动作。
- 未做：Gate 4（word-synced 曲目 raster ON/OFF A-B-A）、Gate 2（idle + LoopStop 日志核对）、Gate 5（virgin/paused sample）均未跑，无本轮 CPU 数据、无 syllable 确认、无 LoopStop 证据。
- 未改动任何状态：未 quit nanoPod，未 setenv，未切歌词页，未动 Music 播放。恢复动作因此为空操作——现场已是创始人离开时的状态。
- 后续项：需要一个不被硬性 15:14 时间盒切断的窗口（建议 ≥25 分钟）才能完整跑 Gate 2/4/5 三项复测。

### 附录 2 实测（15:0x–15:1x）

**本轮补测已执行**（同日 15:02–15:11，硬止 15:13）。前序"未执行测量"记录对应的是更早一次时间盒；本轮拿到了 Gate 2 + Gate 4 一轮数据，Gate 5 因剩余时间不足未跑。

| 窗口 | 时间 | WS median/p95 | app median/p95 | uptime |
|------|------|---------------|-----------------|--------|
| r2_idle_1 | 15:03:17–15:04:21 | 45.2 / 67.2 | 8.25 / 13.2 | load 4.52 |
| r2_idle_2 | 15:04:21–15:05:29 | 68.05 / 79.4 | 8.3 / 14.6 | load 3.76/4.35/4.57 |
| r2_idle_3 | 15:05:29–15:06:39 | 64.15 / 74.0 | 8.15 / 16.6 | load 4.21/4.46/4.60 |
| r2_gate4_on_1 | 15:06:59–15:08:06 | 40.0 / 49.1 | 6.6 / 11.9 | — |
| r2_gate4_off_1 | 15:08:31–15:09:39 | 32.0 / 42.0 | 0.4 / 1.0 | — |
| r2_gate4_on_2 | 15:09:52–15:11:02 | 34.65 / 44.2 | 0.3 / 3.8 | — |

Gate 4 deltas（OFF − ON，app median）：OFF−ON(1) = 0.4 − 6.6 = **−6.2pp**；OFF−ON(2) = 0.4 − 0.3 = **+0.1pp**。两轮都不满足"OFF ≥ ON+3pp"的扫过验证方向，且 ON_1 与 ON_2 本身相差 6.3pp（6.6 vs 0.3），说明 ON 状态本身在两次采样间不稳定（很可能歌词页在 ON_2 采样时未真正处于活跃滚动/sweep 状态，或冷启动后页面未及时呈现）——**本轮 Gate 4 结果不可信，需要下一轮加一步"确认歌词行正在滚动"的可视/日志核验再采**。

Gate 2（idle）判定：**FAIL**。三窗口 app median 8.15–8.3%，远高于 ≤1.5% 的 PASS 线。环境本底 load average 3.8–4.6（非严格安静），WS median 45–68 也偏高，不能排除环境噪声抬高了 idle 读数；但即便打折，8%+ 的量级不像纯噪声，值得下一轮在环境更干净时复测确认。

Gate 5：**未跑**（15:11 已逼近硬止 15:13，跳过以留出恢复时间）。

Caveats：
- 单轮 A-B-A（非多轮），env var 生效性未做交叉验证（仅 `launchctl getenv` 确认清空）。
- 环境非严格安静（load average ~4.5，与 kickoff 通报的"machine quiet"不完全一致），idle/gate4 绝对值可能受环境噪声影响。
- gate4_off_1 与 gate4_on_2 的低 app_cpu（0.4/0.3）与 gate4_on_1 的 6.6 差异较大，怀疑冷启动后歌词页未稳定进入 sweep 态，而非 raster 开关真实效果——按方法论标注为存疑，不作为结论采信。

恢复确认：`launchctl getenv NANOPOD_BLUR_RASTER_OFF` 15:11:07 核对为空；nanoPod 进程 running（pid 6936，本轮 ON 分支重启后的新 pid，即当前 stage 二进制的运行实例）；Music.app 尝试恢复播放"Lawns"/shuffle off/repeat off 时 `play` 命令报 -1700 错误（可能因该次目标句法或曲目引用问题），但 `player state` 确认仍为 playing（葉子 曲目继续播放中，未处于错误/停止状态）；shuffle/repeat 的 set 命令已发出未见报错。**后续项：下一次会话开场应先核对 Music 当前播放曲目并按需手动切回"Lawns"**，本轮未能在硬止前完成该项精确恢复。

**裁定（主会话 2026-09-12 15:1x）：附录 2 的 15:03–15:11 全部窗口作废。** WT-A 子代理在 14:58:59–15:09:03 跑了全量 swift test 与 release 构建，idle_1..3（15:04–15:06）与 gate4_on_1（15:08）都落在污染区间内，gate4_off_1/on_2 虽在其后但 A-B-A 不完整。这批数字只当脚本流程的演练，不进结论。重采窗口 15:25–15:45 由主会话逐个确认四个 worktree 无后台任务后发「窗口开 2」。

## B5 附录 3（2026-09-12 15:2x–15:4x 安静复测，有效）

binary: nanoPod.app md5 5bf3bf1d998a8e4375cc7e386aaf5c15（stage bundle 1，git e5a70c9）。全程 `pgrep -fl "swift-frontend|swift-build|swift-test"` 仅命中一条前序会话遗留的 sleep-until-15:46 占位 shell（命令行文本里含 "swift-build" 字样，非真实编译进程）——按 0 个真实 swift 进程记，未标 suspect。

| label | start–end | swift进程 | load(uptime) | WS median/p95 | app median/p95 |
|---|---|---|---|---|---|
| r3_gate4_on_1a | 15:25:25–15:26:29 | 0(见上) | 15:25 load 4.86/3.27/3.86 | 42.35/46.7 | 6.0/11.2 |
| r3_gate4_off_1 | 15:27:04–15:28:10 | 0 | — | 54.4/63.3 | 7.8/12.0 |
| r3_gate4_on_1b | 15:28:38–15:29:43 | 0 | — | 41.2/45.7 | 5.8/10.1 |
| r3_gate4_on_2a | 15:30:46–15:31:51 | 0 | — | 41.75/46.3 | 5.95/10.5 |
| r3_gate4_off_2 | 15:32:17–15:33:21 | 0 | — | 54.3/59.6 | 6.85/10.9 |
| r3_gate4_on_2b | 15:33:47–15:34:52 | 0 | — | 38.85/45.1 | 5.55/9.3 |
| r3_gate4_on_3a | 15:35:35–15:36:39 | 0 | — | 40.2/50.9 | 5.55/10.5 |
| r3_gate4_off_3 | 15:37:05–15:38:11 | 0 | — | 55.8/62.6 | 7.15/12.3 |
| r3_gate4_on_3b | 15:38:33–15:39:38 | 0 | — | 42.65/47.6 | 6.35/10.3 |

歌曲：全程用 葉子（電視劇《薔薇之戀》原聲帶版），未切歌（未验证是否逐字同步，见 caveats）。

Gate 4 per-round deltas（OFF − ON，WS median / app median）：
- Round 1: OFF−ON(a) = 54.4−42.35=+12.05 / 7.8−6.0=+1.8pp；OFF−ON(b) = 54.4−41.2=+13.2 / 7.8−5.8=+2.0pp
- Round 2: OFF−ON(a) = 54.3−41.75=+12.55 / 6.85−5.95=+0.9pp；OFF−ON(b) = 54.3−38.85=+15.45 / 6.85−5.55=+1.3pp
- Round 3: OFF−ON(a) = 55.8−40.2=+15.6 / 7.15−5.55=+1.6pp；OFF−ON(b) = 55.8−42.65=+13.15 / 7.15−6.35=+0.8pp

六个 delta 的中位数：WS +13.15pp；app +1.45pp。三轮方向一致（OFF 全部高于 ON），WS 侧幅度稳定（12.05–15.6pp），app 侧幅度较小且有一定波动（0.8–2.0pp）。扫过验证：本轮未做「app median ≥3% per window」的独立扫过判据，ON/OFF 各窗口 app median 本身在 5.55–7.8% 区间，均 ≥3%，视为满足扫过存在性检查。

**Gate 4 结论**：raster 开关方向一致、WS 侧效应稳定可信（+13pp 量级）；app 侧效应方向一致但幅度小，与 附录2 中"ON_1 与 ON_2 差 6.3pp"的不稳定问题相比，本轮三组 ON 值彼此接近（5.55/5.95/5.8/6.35 等，跨度 <1pp），冷启动/sweep 未就绪的怀疑本轮未再出现。

**Gate 2（idle）、Gate 5（paused）：未跑，时间预算耗尽**。15:39:38 完成 gate4 第三轮时距 15:42 措辞里的"硬停"仅剩 ~2 分钟，不足以完成 idle×3(~2.5min)+gate5(~2min)+日志核验+安全收尾，故在 gate4 完成后即停止新采样，优先执行收尾（停 Music、清 env、确认 nanoPod 运行）。LoopStop/LoopStopVeto 证据、gate5 sample 计数、lyrics-vs-album 暂停对照：本轮均无数据。

Syllable/word-level 证据：`/tmp/nanopod_debug.log` 在整个 15:24–15:39 测量窗口内行数未增长（`wc -l` 恒为 6826，与开测前一致），说明本轮各 relaunch 出的 app 实例未写入该日志路径（`enableDebugFileLog`=1 但无新行）——**未能取得 syllable/wordLevel/selectedSource 证据行**，无法确认 葉子 本轮是否走逐字同步源；此为已知缺口，非"故意不查"。

Caveats：
- Gate 4 round 2 的执行顺序上主会话中途一度先切 OFF 再补齐 ON_2a（已在下手前发现并改正为标准 ON→OFF→ON 顺序），过程记录见本轮工具调用序列；最终三轮均为完整 A-B-A，未使用误序数据。
- Gate 2 / Gate 5 完全未执行，非"跑了但作废"，是时间预算下主动放弃，需要另开窗口补测。
- 全程仅用 葉子 一首歌，未按预案在"非逐字同步"时切换到备用曲目，因为本轮没有拿到 debug log 证据来判定 葉子 是否逐字同步（见上）。
- 环境 load average 观测到 4.86（首窗口),不算严格安静，但主会话开场已确认 0 个 swift 编译进程；load 数值本身可能受其他后台应用影响,未逐项排查。

End state：Music.app 已 `stop`；`launchctl getenv NANOPOD_BLUR_RASTER_OFF` 为空；nanoPod 以 stage bundle 方式运行（pid 10474，`open` 常规启动，非 debug 进程）。未尝试恢复此前任何播放曲目（按指示：Music 保持 stopped，不做恢复）。

### 埋点开关核实（2026-09-12 实机，三组对照）
- 代码无误：release 编译着 DebugLogger 与两条埋点，`isEnabled()` 三源取或。根因在环境：本机曾以沙盒身份运行过 com.yinanli.nanoPod，`~/Library/Containers/com.yinanli.nanoPod/` 仍在，cfprefsd 把 `defaults write com.yinanli.nanoPod …` 静默重定向到容器 plist；而现在的 app 非沙盒（entitlements app-sandbox=false），读的是 `~/Library/Preferences/com.yinanli.nanoPod.plist`——创始人写的键从未到达 app。
- 实测：A `launchctl setenv NANOPOD_DEBUG_LOG 1` 重启 → 40s 增 137 行（18 条埋点）；B 域名形式 defaults 重启 → 0 行（复现创始人症状）；C 显式路径 defaults 重启 → 增 87 行。
- 对创始人有效的命令（已在他机器上写入，当前即生效）：
  ```bash
  defaults write ~/Library/Preferences/com.yinanli.nanoPod.plist enableDebugFileLog -bool YES
  ```
  重启 nanoPod 后日志在 /tmp/nanopod_debug.log。阶段包说明里的域名形式命令作废，改成这条。
