# 阶段包 3g 逐条复现报告（2026-09-18，全六条已过一轮）

Worktree: `.claude/worktrees/lyrics-render-3g`，分支 `lyrics-render-3g`，基线 main=4f46b47（阶段包 3f）。

## 状态总览

| # | 项目 | 复现了没 | 红测试 | 根因一句话 | 修法一句话 |
|---|------|---------|--------|-----------|-----------|
| 1 | 切行 1-2px（含整屏歌词一起动） | **复现** | `NativeLyricsWrappedRowScaleInvariantTests` | 均匀仿射缩放只能让一个枢轴点不动，换行行的第 2 视觉行必然按距离枢轴的偏移量位移 | 换行到 2 行及以上的行钉死 scale=1.0，不再缩放 |
| 2 | 回跳后整行全亮无遮罩 | **未复现** | `NativeLyricsSeekLandingMaskTests`（真 seek，66+ 穷举点，全绿） | 不明——两条已知分支审计均安全 | 无法修；已加 `recordWordFloatDesync` 类似的生产期证据探针（`brightUnmaskedIncomplete`）等下次现场 |
| 3 | 中文行尾字重影 | **未复现**（且订正了一个误判） | `NativeLyricsCJKTrailingGhostExhaustiveTests` | 不明——dim/bright 瓦片同帧同位置共存是设计内的揭示机制，不是重影；唯一可信的重影信号（位置偏移）没触发 | 无法修；加了 `NativeLyricsMaskTrace.recordWordFloatDesync` 探针盯一个具体的理论 desync 路径（dim/bright 的 floatY 判定分歧） |
| 4 | 三点错位/消失 | **未复现**（命中已知残留） | `test_fourthPreludeEntryPath_manualScrollToTopThenPlayFromStart_matchesOtherPaths` | 复现出的是 3d 就记录在案的已知残留（X 差 0.9pt），不是创始人这次报的「完全不出现/卡在顶部」 | 无需修（残留已知，非本轮症状） |
| 5 | 新回归：切歌 bloom | **未复现** | `NativeLyricsTrackChangeBloomTests`（像素法+位置离散度法） | 不明——像素法结构性看不见 CIFilter 合成器效果（banned-patterns 已记录） | 无法修；没有红测试可供二分，按要求跳过二分而非编造 |
| 6 | 强调词重影/割裂 | **未复现（该子问题）** | `test_allThreeArms_glowSharpTileZeroPositionalDifference_realSurfaceEveryFrame` | amll 臂 glow/sharp 瓦片逐帧零位置差，本身没有重影 | 无需修；对照 app 已构建给创始人肉眼裁决整体手感 |

**总体读法**：六条里真正复现并修复的只有第 1 条。第 2/3/5 条是"哪怕加大穷举力度也复现不了"；第 4 条复现出的是旧已知残留而非新症状；第 6 条测的那个具体子指标（glow/sharp 位置一致性）是干净的，但创始人真正的不满（"跟其他普通歌词太割裂"）是整体观感对比，不是这条单元测试能回答的问题，留给他自己肉眼对照 v0.28/v2.8 构建。

---

## 1. 切行 1-2px（已修，commit f2d438e）

**复现**：dcd7b6a（3f 已交付）把纵向缩放锚点从行几何中心改到"第一行文字基线"，这只让**第一个视觉行**在切行时不动——创始人实测曲目《啟程》几乎每行都换行成两行中文，**第二个视觉行**仍按 `0.05 × 行高 ≈ 1.7pt` 位移，因为单一枢轴点无法让多行文本块的所有行同时保持静止（这是均匀仿射缩放的结构性质，不是参数没调对）。

新测试 `Tests/MusicMiniPlayerTests/NativeLyricsWrappedRowScaleInvariantTests.swift`：用真实 `NativeLyricsSurfaceView` + 确定性时钟，CJK 换行歌词行，测量行内第 0/1/2 视觉行在激活态与稳定非激活态之间的位移。临时把修复代码改回旧行为重跑，测试真红：wrap-line 1 位移 1.10pt、wrap-line 2 位移 2.20pt，`positioningTransform.a` 是 0.95 而非期望的 1.0。恢复修复后转绿。

**根因**：均匀仿射缩放围绕单一枢轴点进行，枢轴点以外的每一点都按 `(该点Y - 枢轴Y) × |Δscale|` 位移——多行文本块的第 2/3 视觉行、翻译行都在枢轴之外，永远会动。

**修法**：新增 `NativeLyricsRowView.mainTextWrapsToMultipleLines`（用 `NativeLyricsTextMeasurement.metrics(...).lineCount` 判断主文本是否换行到 2 行及以上）；`LyricsLayerRendererView.applyFrame` 里，换行行一律钉死 `effectiveScale = 1.0`（永不缩到 0.95），单行行保持原有 0.95↔1.0 弹簧不变。`expectedScale`（frame parity 遥测）也用同一个 `effectiveScale`。

**代价**：换行行不再有激活/非激活的"变大变小"视觉提示——这是方案本身的取舍，不是漏做；单行行不受影响。

**回归**：相关测试 307 条全绿，唯一失败是预存 flaky（见文末）。

---

## 2. 回跳后整行全亮无遮罩（未复现，commit 32563fd）

第一轮只做了只读代码审计（geometryReady 两条分支看起来都安全）。这轮按 coordinator 要求补了穷举测试：`NativeLyricsSeekLandingMaskTests` 用真实 `mc.seek(to:)`（真的 bump `seekGeneration`，与进度条拖动/外部 seek 同一信号，比之前的连续 tick 热身 fuzz 更贴近真实触发路径）驱动三个场景——seek 到词中段、回跳到已唱完行、暂停中 seek——只采样 seek 后的**第一帧落地状态**，另加 66 点（11 行 × 6 个 seek 分数）穷举扫描。全部绿，没有找到"亮层可见但 mask 未生效"的落地帧。

**未复现，如实上报**：按项目铁律不当"没问题"结案。已在 `NativeLyricsMaskTrace`（生产期证据探针，`/tmp/nanopod_mask_trace.jsonl`，默认零 I/O）新增 `brightUnmaskedIncomplete` 字段——用与测试完全相同的判据（亮层可见+mask 未生效+期望进度未完成）在真机记录，弥补创始人报告过的 `wholeLineHighlight` 标志盲区（710 条记录从未翻真，但他亲眼看到过 bug）。下次现场撞见时这个字段应该能留下证据。

---

## 3. 中文行尾字重影（未复现，commit dcd6c2c）

新测试 `NativeLyricsCJKTrailingGhostExhaustiveTests`：word/syllable-synced 的 CJK 行，尾词"旅程"，从行中段一路扫到行结束后 1.5s（跨越激活→非激活边界），每帧检查 dim/bright 瓦片对的位置关系；另用创始人自己的取证工具 `rowDumpLines`（`nanopod://debug/rowdump`）在尾帧枚举所有可见图层。

**第一版测试是误判，已订正**：第一版把"dim 与 bright 瓦片同一帧都可见（hidden=false）"当成重影信号，真跑起来立刻抓到一个"命中"——但仔细看两个图层的 frame 完全相同（位置、尺寸逐位一致），这其实是揭示机制本身（bright 瓦片不透明地精确盖在 dim 瓦片上，靠 mask 揭示进度），不是 bug。订正为"两个可见副本必须位置相同"（呼应 defect1 当初的修复标准："同词同帧 Δy=0.000pt"），订正后测试绿。

**顺带发现一个值得盯的理论风险**（未触发，未确认是根因）：`applyMainWordFloatGlyphLayers` 里，dim 瓦片是否浮动看 `floatingOrders`（源自 `applyActiveMainPhase` 的 `run.baseFloatY`），bright 瓦片却总是套用 `plan.perWordFloatY(at:)`（一个独立算出来的量）——如果这两个来源在某个真机场景下对"这个词是否在浮动"判断不一致，就会出现 bright 瓦片飘走、dim 瓦片没飘、两者都可见的真实位置偏移重影，正好对应创始人截图里的"偏右下"。已加 `NativeLyricsMaskTrace.recordWordFloatDesync` 探针盯这个具体条件，真机测不到，留给下次现场。

---

## 4. 三点错位/消失（未复现，命中已知残留，commit eb3d712）

已有 `test_threePreludeEntryPaths_coldStart_seekBack_manualScrollBack` 覆盖了冷启动/显式 seek 回前奏/手动滚回顶（仍冻结）三条路径，但没有覆盖创始人这次报的**第四条路径**：手动滚回顶（冻结）之后再按"从头播"（一次真正的重启 seek，会释放冻结）。新增 `test_fourthPreludeEntryPath_manualScrollToTopThenPlayFromStart_matchesOtherPaths`，复用同一文件的 `preludeSongRows`/`config`/`host` 辅助函数：滚到冻结态，断言确实冻结，然后真正 `mc.seek(to:)` 重启，对比冷启动基线的三点可见性/透明度/X/Y。

**结果**：绿。冻结正确释放，三点可见，唯一差异是 X 方向 0.9pt——这**正是** 3d 阶段报告里已经记录在案的已知残留("手动滚回顶只差点簇 X 0.9pt（已知残留）")，不是创始人这次说的"三点根本没出现、第 0 行卡在面板顶部"。这次尝试没有复现创始人报的新症状。

---

## 5. 新回归：切歌 bloom（未复现，未做二分，commit 1258286）

先跑了现存的 `NativeLyricsBloomReproductionTests`（fresh mount / 双 surface 叠加 / staged loading storm）——全绿，且它们都没覆盖"已经稳定播放中的 surface 被切到全新一首歌（全新行身份，不只是行内切行）"这个具体转场。

新增 `NativeLyricsTrackChangeBloomTests`：先让 surface 在歌曲 A 上稳定播放一段时间（真实的已结算位置/模糊/透明度，不是刚挂载），再整体换成歌曲 B 的全新行数组（全新 id、currentIndex 归零），同时用像素亮度法（既有 bloom 测试的方法）和行 Y 坐标离散度法（"坍缩到同一原点"的几何信号，独立于亮度）检测切换后第一帧。两个指标都干净。

**没有做commit列出的五个可疑提交的二分**：二分需要一个红测试作为判据，这次没有找到红测试，无从二分——按要求不编造二分结果，直接跳过并如实说明。另外记一笔已知局限（`.claude/rules/banned-patterns.md` 里写过）：`cacheDisplay`/`bitmapImageRepForCachingDisplay` 这条像素捕获路径**结构性看不见 CIFilter**（模糊等效果只有真实渲染服务器才会应用），所以就算真的有模糊/景深引起的 bloom，这个测试手法也天生看不到——这类手感 bug 大概率还是需要创始人的真机录屏才能真复现，这点符合项目"手感类验证不用 computer use/录屏，除非创始人自己提供"的既有规矩。

---

## 6. 强调词重影/割裂 + v0.28/v2.8 对照构建（该子指标未复现；已交付对照构建，commit 2d829d1）

已有 `test_amll_glowLayerPositionMatchesBrightTile_zeroTolerance`（0.05s 步进采样，零容差）覆盖了 coordinator 点名的确切指标。这轮加了 `test_allThreeArms_glowSharpTileZeroPositionalDifference_realSurfaceEveryFrame`：用真实持续 tick 的 `NativeLyricsSurfaceView`（不是每次独立单帧重配置），真 1/60s 帧粒度，三臂（current/v28/amll）统一跑一遍。结果：amll（默认臂）在采样窗口内每一帧 glow/sharp 位置零差，且真的采样到了 glow 可见的窗口（不是空跑）；current 按设计走独立图层池，本就不该套这个不变式；v28 的 glow 是打在 bright 瓦片自身上的 CALayer 阴影，结构上不可能和自己错位。

**这条子指标本身是干净的**。但创始人的真正不满（"以前是像 AMLL 那样的高光模糊，跟其他普通歌词太割裂"）是跟历史版本、跟上游 AMLL 项目的整体观感对比，不是"glow 和 sharp 瓦片是否重叠"这一个几何不变式能回答的问题——这是一次性视觉判断题，交给创始人自己肉眼二分。

**对照构建已完成**：`git worktree` 分别检出 `v0.28`（181fb42）与 `v2.8`（b24b182）两个 tag，各自跑 `./build_app.sh` 编译，产物放在 `builds/nanoPod-v0.28.app` 与 `builds/nanoPod-v2.8.app`（该目录已 `.gitignore`，未提交），临时 worktree 已清理。两个都编译签名成功（v2.8 的 actool 失败自动回落 icns，属已知行为，不影响签名结果）。

---

## 收尾

- `DEVELOPER_DIR=/Applications/Xcode.app swift test` 全量：**1481 通过，1 失败**。唯一失败是 `NativeLyricsRenderChurnTests.test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff`——HANDOFF.md 明确记录的预存 flaky 测试，本轮多次独立重跑（含改动前后对照）均复现同样失败，与本轮任何改动无关。
- 六条 commit：`f2d438e`（第1条，真修复）、`32563fd`（第2条，测试+探针）、`dcd6c2c`（第3条，测试+探针）、`eb3d712`（第4条，测试）、`1258286`（第5条，测试）、`2d829d1`（第6条，测试）。均未 push。

---
*报告人：Claude Fable 5.1（子代理，Sonnet 5 执行层）。第 2/3/5 条的"未复现"不是"没问题"的结论——只是这一轮的穷举力度没有撞见现场；证据探针留在代码里等下次真机撞见。*
