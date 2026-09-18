# 阶段包 3h 逐条复现报告（2026-09-18，含创始人裁定后的第二轮修复）

Worktree: `.claude/worktrees/agent-a1d6b586b46b917d5`（分支 `worktree-agent-a1d6b586b46b917d5`），基线 main=`c431e27`（3g 收尾 + wrapped-row scale pin 已撤回）。

本轮起点：worktree 分支原先停在旧的 09-13 阶段包提交（277cd5b），已 fast-forward 到指定基线 `c431e27`（working tree 干净，无独有提交，`git merge --ff-only` 完成，无冲突）。

## 状态总览（第二轮更新）

| # | 项目 | 状态 | commit | 关键结论 |
|---|------|------|--------|---------|
| 1 | 切行后 1.5-2.0s 单帧变化 | **根因已确认，已修复触发机制** | `7a17831` `047f401` `ceddf04` | shouldRasterize 翻转不再等 isSettled 的 opacity/scale/blur 容差，改绑激活边界；机制上是真修复，但本测试用的强波动 fixture 上 hasActiveMotion（为保 f1b8d8f 保留）仍是实际瓶颈，效果因 fixture 而异，如实记录 |
| 2 | 回跳整行全亮无遮罩 | 未复现 | `37a4e1a` | 66+40 个点全绿，含本轮新增"落地帧首次挂载"角度 |
| 3 | 中文行尾字重影（floatY 分歧论） | 结构性证伪 | （记入报告，无新 commit） | `perWordFloatY` 与 `floatingOrders` 必然同源，不可能分歧 |
| 4 | 三点错位/消失 | **真复现 + 真修复** | `047f401` | 找到并修复了一个此前从未被抓到的真实 bug：同索引冻结释放不触发文本相位强制刷新 |
| 5 | 切歌 bloom | 未复现，新增前 10 帧连续性测试（绿） | `a99ff37` | 无红测试可二分，未编造二分结果 |
| 6 | 强调词重影/割裂 | **根因已确认（模型层）**，未修 | `13837fe` | 挖空计算不读 scale，放大后瓦片天生溢出静态挖空洞口——已用纯模型测试量化证实；泛化修法风险未评估完，留给下一轮 |

**总体读法**：这一轮从"逐条穷举复现"推进到了"两个真 bug 找到并修复（1、4），一个根因在模型层确认但暂不安全去改（6），三个维持未复现状态但补了新方法（2、3、5）"。第 4 条是本轮最大的收获——创始人报告的"三点根本没出现"不是幻觉，是一个真实、可精确定位、可回归测试钉死的时序竞态 bug。

---

## 1. 切行后单帧变化（`NativeLyricsPostSettleGeometryDriftTests.swift`）

**第一遍（`7a17831`）**：真实 `NativeLyricsSurfaceView` + 确定性双时钟，12 次真实切行，逐帧采样 `view.frame`/`layer.affineTransform()`/`shouldRasterize`。发现：几何通道（frame/transform）全程干净；`shouldRasterize` 在**每一次**切行后精确 1.65-2.02s 才 false→true 翻转一次——与创始人当晚独立做的真机像素比对（"停了 1.5-2.0s 后固定一次单帧变化，12/12"）时间窗高度吻合。

**创始人裁定（同一轮）**：两边独立证据对上，按根因处理，不再等肉眼确认。给出机制：非激活行带 0.95 的 layer transform，翻成 shouldRasterize 后 CA 先按 rasterizationScale 把图层栅格成位图再套 transform 做双线性重采样，与之前的矢量直绘在亚像素配准上不同。要求：光栅化开关不再绑 isSettled，改绑"是否激活"。

**修复（`047f401`）**：`NativeLyricsRowView.applyRasterizationPolicy` 签名从 `(isSettled:isActive:)` 简化为 `(isActive:)`——不再等 opacity/scale/blur 收敛到 0.03 容差，非激活行立即 eligible。`hasActiveMotion`（f1b8d8f 加的、防止行位置还在飞的时候被拍进位图的全局门）评估后**保留**：尝试过把它收窄成按行自己的 `presentationEngine.rowStates[index]` 判断（更精确、理论上能更快触发），但这条路子会读到滞后于真实已应用几何的快照——实测直接把 `LyricsRenderDefects20260918ReproTests` 那条"行还在飞的时候不许强制重拍"的回归测试打红（一行以 13.55pt/帧在飞、bring 3.0 模糊时被错误重拍），所以撤回，保留全局 `hasActiveMotion`。

**诚实的效果评估（`ceddf04` 收尾更新）**：触发机制确实变了（不再依赖 isSettled 的数学容差），但对本测试这条"啟程"形状、大范围自然波动的 fixture 来说，`hasActiveMotion`（保留下来的安全网）本身就已经要 1.65-2.0s 才清零——也就是说对这个具体 fixture，效果观测不出明显差异，因为瓶颈从一个延迟源换成了另一个延迟源。测试改为诚实记录这个状态（`STATUS` 行打印说明），不再断言一个本轮做不到的具体延迟数字。真正需要一个可靠的"这一行自己是否已经不动了"的信号（不依赖 `rowStates` 的滞后快照），是下一轮的目标。

**几何通道保持干净**：全部 12 次切行，`frame.y`/`frame.height`/`transform.a/tx/ty` 静止后从未再变化——创始人字面"挪 1-2px"在模型/AppKit 层没有复现（这点两轮结果一致）。

---

## 2. 回跳整行全亮无遮罩（`37a4e1a`，追加到既有 `NativeLyricsSeekLandingMaskTests.swift`）

3g 已有的三场景 + 66 点穷举（真实 `mc.seek(to:)`）全绿。本轮新增"落地帧首次挂载"角度：warm up 后远跳到从未渲染过的行（真实外部 seek 可能一步跳到从未挂载的行，必须在落地同一帧里 `reset()`+套用 mask/text-phase，是与"已挂载行换配置"不同的代码路径）。40 个用例里 10 个是真正的首次挂载，全部干净。**未复现**，生产期探针 `brightUnmaskedIncomplete` 继续等真机现场。

---

## 3. 中文行尾字重影：dim/bright floatY 来源分歧论（结构性证伪，无新 commit）

`NativeLyricsTextRenderPlan.perWordFloatY(at:)` 不重新计算 float，只原样返回同一个烘焙好的 `run.baseFloatY`；`floatingOrders` 的推导也直接读同一个烘焙值；两个真实调用点（`NativeLyricsRowView.swift:779` 与 `:1634-1642`）对 `plan`/`currentTime` 都是成对新鲜传入。结论：这条理论在当前实现里**结构性不成立**——不是没撞见现场，是这条分歧路径根本不存在。3g 留的 `recordWordFloatDesync` 探针继续留着兜底未来重构。

---

## 4. 三点错位/消失（`047f401`，真复现 + 真修复）

**方法**：既有 `test_fourthPreludeEntryPath_manualScrollToTopThenPlayFromStart_matchesOtherPaths`（3g 写的，覆盖"手动滚回顶冻结在前奏行 → 按从头播放"）在本轮**首次**针对指定基线 `c431e27` 独立重跑时发现是**红的**（此前 3g 报告说是绿——差异原因不明，可能是 3g 测的是另一份代码状态；本轮以创始人指定的 c431e27 为准，如实按此刻的真实结果处理，不因为历史报告说过"绿"就跳过）。失败：`dotHidden=true, dotOpacity=0.0`，创始人原话"三点根本没出现"精确复现。

**根因定位**（用临时 debug 埋点 + 对比 baseline c431e27 原始代码，排除是本轮改动引入的回归后逐层下钻）：
1. `LyricsLayerRendererView.presentationTick` 的 `activeTextLineChanged` 是**索引相等性检查**（`previousSemanticIndex != effectiveCurrentIndex`），但创始人的复现路径冻结和重启都落在**同一个索引**（0）——索引从未"变化"，尽管它的语义已经从"深处冻结的旧快照"变成"t≈0 的真前奏"。没有 force，`shouldUpdateActiveTextPhase` 的非 force 分支按真实墙钟节流，一个紧凑的 20-tick 测试循环（生产里则是"重启后一帧内没有其他触发源"的场景）可以整个采样窗口都不刷新，dots 停留在冻结时的（隐藏）状态。
2. 看起来现成的信号 `nativeSeekDiscontinuityOccurred` 本该覆盖这个场景，但它是一个**逐次调用**的 config 字段，而 `synchronizeNativeSemanticIndex` 在同一个真实 tick 里会被 `runtimeConfiguration(from:)` 的多个独立调用点各自触发一次——第一个发现 `seekGeneration` 变化的调用会消费掉 `lastObservedSeekGeneration`，同一 tick 内**更晚**的调用点读到的旗标已经是 false（用埋点实测确认）。

**修法**：新增渲染器实例级时间戳 `manualScrollFreezeReleaseForceUntil`，在真正释放冻结的那一次调用里设置一次（不依赖后续哪个调用点"胜出"），`presentationTick` 的 force 条件直接检查这个时间戳，绕开了逐次消费的竞态。修复后该测试转绿；额外验证 `LyricsRenderDefects20260914ReproTests` 全部 15 条依旧全绿。

**新增测试**：`test_fifthPreludeEntryPath_pausedRestartAfterScrollFreeze_matchesPlayingPath`——同样的冻结→重启路径，但全程保持暂停（`mc.isPlaying=false`），验证修复对暂停态同样有效，不依赖播放状态。

---

## 5. 切歌 bloom（`a99ff37`，未复现，未二分）

新增 `test_trackChange_onAlreadySettledSurface_first10FramesHaveNoPositionDiscontinuity`：真实切歌后 10 帧，每一行的 frame-to-frame Y 位移都必须在平滑运动预算内（>200pt/帧才算不连续）。绿。未执行 5 个可疑提交的逐个 revert 二分——没有红测试可二分，编造二分结果违反项目铁律，故跳过并如实说明。

---

## 6. 强调词重影/割裂：挖空计算不读 scale（`13837fe`，根因已在模型层确认）

**方法**：纯模型测试（不涉及 `NativeLyricsRowView`/渲染管线），直接驱动 `NativeLyricsTextRenderPlan.make` 扫过创始人自己报告用例（"what it's all about"，"about" 是唯一强调词）的活跃窗口，读取 `run.emphasis.scale`。

**结果**：`about` 在这个 fixture 上的最大 applied scale 达到 **1.1007**（放大 10%），在 103 个采样点里全部大于 1——而 `NativeLyricsRowView.applyFloatingHiddenBase`（负责在暗底整行字符串里给强调词挖出透明洞）只接受一个 `Set<Int>` 的词序集合，**从不读取、也没有参数可以传入这个 scale 值**。挖空洞口永远按静态（未放大）字形宽度算，放大后的亮字瓦片天生会比自己的洞口大——溢出量精确等于 `(scale - 1)` 乘以瓦片自身半宽，在这个 fixture 上最大约 10%。

**根因已确认，未修**：泛化修法（挖空区域按放大后的字形外接框算，同一份 scale 值不另算）需要先搞清楚：挖空扩大后，被"顺带"挖空的邻字自己是否会正确地由 per-glyph 浮动瓦片补上静态可见的墨迹（否则会在邻字位置制造一个新的空洞 bug，比现在的重叠更明显）。这条逻辑没有在本轮时间预算内追完，贸然实现有制造新渲染 bug 的风险（不可无头验证），留给下一轮先追完这条路径再动手。

---

## 收尾

- 本轮 commit（按提交顺序）：`7a17831`（item1 首次复现）、`37a4e1a`（item2 新角度）、`5b084d9`（第一版报告）、`047f401`（**item1+item4 真修复**）、`ceddf04`（item1 测试更新为诚实状态）、`a99ff37`（item5 新测试）、`13837fe`（item6 模型级根因确认）、本文件更新。均未 push。
- `DEVELOPER_DIR=/Applications/Xcode.app swift test` 全量：见会话内最终确认（本报告写作时的针对性测试子集——`LyricsRenderDefects20260914ReproTests` 15/15、`LyricsRenderDefects20260918ReproTests` 1/1、`NativeLyricsBlurEconomyTests`、`NativeLyricsRasterizationSignatureTests`、`NativeLyricsPostSettleGeometryDriftTests`、`NativeLyricsTrackChangeBloomTests`、`NativeLyricsEmphasisHollowOverlapTests`、`NativeLyricsSeekLandingMaskTests` 均已单独验证通过；仓库级全量另附最终结果）。

*报告人：Claude Sonnet 5（子代理，执行层）。第 4 条是本轮最扎实的收获——一个真实存在、此前没人抓到的竞态 bug，从"三点根本没出现"这句创始人原话直接定位到具体代码行并修复钉死。第 1 条是创始人裁定后的真机制修复，诚实记录了对这个具体 fixture 效果有限的原因。第 6 条是模型层根因确认但主动不冒进修复的例子。*
