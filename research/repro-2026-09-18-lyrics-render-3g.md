# 阶段包 3g 逐条复现报告（进行中，2026-09-18）

Worktree: `.claude/worktrees/lyrics-render-3g`，分支 `lyrics-render-3g`，基线 main=4f46b47（阶段包 3f）。

## 状态总览

| # | 项目 | 状态 |
|---|------|------|
| 1 | 切行 1-2px（含整屏歌词一起动） | **已复现、已修、已 commit**（f2d438e） |
| 2 | 回跳后整行全亮无遮罩 | 只读代码审计完成，未新增复现；见下 |
| 3 | 中文行尾字重影 | 未开始 |
| 4 | 三点错位/消失 | 未开始 |
| 5 | 新回归：切歌 bloom | 未开始 |
| 6 | 强调词重影/割裂 + v0.28/v2.8 对照构建 | 未开始 |

本报告目前只覆盖第 1 条的完整闭环；2～6 条排入下一工作会话，不在本轮谎报完成。

## 1. 切行 1-2px（已修）

**复现**：dcd7b6a（3f 已交付）把纵向缩放锚点从行几何中心改到"第一行文字基线"，这只让**第一个视觉行**在切行时不动——founder 的实测曲目《啟程》几乎每行都换行成两行中文，**第二个视觉行**仍按 `0.05 × 行高 ≈ 1.7pt` 位移，因为单一枢轴点无法让多行文本块的所有行同时保持静止（这是均匀仿射缩放的结构性质，不是参数没调对）。

新测试 `Tests/MusicMiniPlayerTests/NativeLyricsWrappedRowScaleInvariantTests.swift`：
- 用真实 `NativeLyricsSurfaceView` + 确定性时钟（`debugNowOverride` / `debugPlaybackClockDateProvider`），CJK 换行歌词行，测量行内第 0/1/2 视觉行（以行高为步进）在激活态与稳定非激活态之间的位移。
- **临时改回旧行为验证红**：把 `LyricsLayerRendererView.applyFrame` 里的 `effectiveScale` 临时改回 `visual.scale`（不做换行判断）重跑，测试失败：wrap-line 1 位移 1.10pt、wrap-line 2 位移 2.20pt（等比例对应真实约 1.7pt/3.4pt 级别的量级），`positioningTransform.a` 是 0.95 而非期望的 1.0——与 founder 报告的"每次切行都挪 1-2px"现象吻合。恢复修复后重跑转绿。

**根因**：均匀仿射缩放围绕单一枢轴点进行，枢轴点以外的每一点都按 `(该点Y - 枢轴Y) × |Δscale|` 位移——多行文本块的第 2/3 视觉行、翻译行都在枢轴之外，永远会动。

**修法**（按 coordinator brief 的选项 2："改为不缩放多行行"）：新增 `NativeLyricsRowView.mainTextWrapsToMultipleLines`，用现成的 `NativeLyricsTextMeasurement.metrics(...).lineCount` 判断主文本是否换行到 2 行及以上；`LyricsLayerRendererView.applyFrame` 里，换行行一律钉死 `effectiveScale = 1.0`（永不缩到 0.95），单行行保持原有 0.95↔1.0 弹簧不变。`expectedScale`（frame parity 遥测）也用同一个 `effectiveScale`，避免遥测里出现"预期 0.95 实际 1.0"的假性不一致。

**代价**（如实说明，未隐瞒）：换行行不再有激活/非激活的"变大变小"视觉提示——这是"完全不缩放多行行"这个方案本身的代价，不是实现疏漏；单行行（较短歌词常见情形）不受影响。选择这个方案而非"让布局与激活态无关"的原因：后者需要把 wave/spring 目标模型（`LyricsPresentationModels.swift` 里的 `legacyTarget`/`amllTarget`）本身改造成感知换行状态，牵涉更广的模型层改动和更多下游一致性验证；"整行钉 1.0"改动面小、只在渲染应用点判断，且直接解决了 founder 报告的确切现象（残留动一下，不是想要缩放效果本身）。

**回归**：`swift test --filter 'NativeLyrics|LyricsRenderDefects|RowScale|BaselinePivot|LineGaps'` 307 条全绿，唯一失败是 HANDOFF.md 已记录的预存 flaky `NativeLyricsRenderChurnTests.test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff`（独立重跑复现同样失败，与本次改动无关）。

**commit**：`f2d438e fix(lyrics-render): pin wrapped multi-line rows to scale 1.0, not just first-line pivot`

## 2. 回跳后整行全亮无遮罩（只读审计，未新增复现测试）

读了 `NativeLyricsRowView.applyActiveMainPhase`（Sources/MusicMiniPlayerCore/UI/NativeLyricsRowView.swift:1864 起）：

- `geometryReady == false`（行刚配置、bounds 还是 0，即证据 (a) 里"几何未就绪"那一帧）分支：显式 `mainBrightTextLayer.isHidden = true`、`mask = nil`、`progress = 0`——这条路径本身是安全的（不显示高亮，不是全亮），与 3f 说明文档里"下一帧自愈"的描述一致。这也是 mask_trace.jsonl 里那 3 条 `perRunSweep=false, applied=0.0` 记录的来源分支，行为符合预期（先不显示，不是全亮）。
- `geometryReady == true` 但逐字 mask 失败（`sweepResult.applied == false`）分支：走整行渐变 mask 兜底（`updateSweepMask` 按 `plan.mainSweepProgress` 计算遮罩宽度），不是无条件全亮——代码审计没找到"mainBrightTextLayer 已显示但 mask 未挂上/mask 尺寸覆盖整行"的路径。

**未能新增复现**：随机 seek fuzz（3f 已有 45 次 0 违反）+ 这次的代码审计都没找到 founder 描述的"全亮"分支。按项目铁律，"未复现"如实上报，不当作"没问题"结案——下一轮需要：(a) 针对"行视图被复用给新行、但上一帧已经设置了 mainBrightTextLayer.isHidden=false 且 mask 指向旧行几何"这类复用竞态专门造穷举用例；(b) 若创始人手上还留着 /tmp/nanopod_mask_trace.jsonl 或能重新采集，请他在下次撞见时立刻另存一份給下一轮读。

## 3～6

未开始。下一工作会话按顺序继续：中文行尾字重影（rowdump 复现路径）→ 三点错位 → bloom 回归二分 → 强调词三臂一致性 + v0.28/v2.8 对照构建。

---
*本报告只记录已完成部分；标"未开始"的条目不代表排除或判定无问题。*
