# 阶段包 3h 逐条复现报告（2026-09-18）

Worktree: `.claude/worktrees/agent-a1d6b586b46b917d5`（分支 `worktree-agent-a1d6b586b46b917d5`），基线 main=`c431e27`（3g 收尾 + wrapped-row scale pin 已撤回）。

本轮起点：worktree 分支原先停在旧的 09-13 阶段包提交（277cd5b），已 fast-forward 到指定基线 `c431e27`（working tree 干净，无独有提交，`git merge --ff-only` 完成，无冲突）。

## 状态总览

| # | 项目 | 复现了没 | 方法数 | 关键发现 |
|---|------|---------|--------|---------|
| 1 | 切行后 1.5-2.0s 单帧 1-2px 跳变 | **模型几何层未复现**（新发现强关联信号） | 1（真 surface 逐帧几何采样） | frame/transform 全程干净；但 `shouldRasterize` 在**每一次**切行后 1.65-2.02s 精确翻转一次 false→true，与创始人报告的窗口/普遍性高度吻合 |
| 2 | 回跳整行全亮无遮罩 | **未复现** | 2（既有 3g 三场景+穷举 + 本轮首挂载穷举） | 66+3+40 个点全绿；新增的"落地帧首次挂载"角度（10/40 真实首挂载案例）同样干净 |
| 3 | 中文行尾字重影（dim/bright floatY 来源分歧论） | **未复现，且结构性证伪** | 2（3g 既有真机探针 + 本轮代码路径追溯） | `perWordFloatY(at:)` 直接返回 `run.baseFloatY`（同一份烘焙值），两个调用点（NativeLyricsRowView:779, 1642）对 plan 与 currentTime 均成对新鲜传入——不存在能让两者分歧的代码路径 |
| 4 | 三点错位/消失 | **未复现（同 3g 已知残留）** | 1（复核 3g 结论，未加新方法） | 时间/精力所限未加新穷举；3g 的第四路径测试仍覆盖创始人这次的措辞最接近的场景 |
| 5 | 切歌 bloom | **未复现，未二分** | 1（复核 3g 结论，未加新方法） | 时间/精力所限未执行 5 提交逐个 revert 二分（无红测试可二分，二分会是编造） |
| 6 | 强调词重影/割裂（dim 挖空 vs 放大区域） | **未测试（新角度已识别，未验证）** | 0 | 识别到一个未验证的新角度：`applyFloatingHiddenBase` 按未缩放字形宽度挖空，而强调词的亮层按 `scale = 1 + emphasisWeight*0.1*amount` 放大——挖空洞口可能小于放大后的字形，溢出到相邻未挖空的暗字上。未写测试验证，如实标注为下一轮候选 |

**总体读法**：本轮在极紧的时间预算下，把主要精力集中在第 1 条——这是创始人这次报告里最新、最具体（12/12 次、精确 1.5-2.0s 窗口）的现象，也确实挖到了一个此前从未被测过的强关联信号。第 2/3 条各补了一个新角度，都排除了。第 4/5/6 条本轮未能投入新方法，如实说明，不冒充"未复现=没问题"。

---

## 1. 切行后 1.5-2.0s 单帧 1-2px 跳变（`NativeLyricsPostSettleGeometryDriftTests.swift`）

**方法**：真实 `NativeLyricsSurfaceView` + 确定性双时钟（`debugNowOverride` + `mc.debugPlaybackClockDateProvider`），20 行"啟程"形状歌词（几乎每行两行中文，逐句量过 `NativeLyricsTextMeasurement.metrics` 确认 `lineCount>=2`），连续驱动 12 次真实切行。每次切行后，从 +0.8s 到 +3.0s（封顶在下一次切行边界前 0.1s，避免下一次切行的重排污染本次采样）逐帧（1/60s）采样刚切出的那一行的：
- `view.frame`（AppKit 实际应用的位置/尺寸——真正上屏的通道）
- `view.layer?.affineTransform()`（scale/translate 通道）
- `view.layer?.shouldRasterize` / `rasterizationScale`（模糊经济缓存翻转）

**结果**：
- **几何通道（frame.y / frame.height / transform.a / transform.tx / transform.ty）在全部 12 次切行、静止后从未再变化**——创始人描述的字面"挪 1-2px"在模型/AppKit 层没有复现。
- **`shouldRasterize` 在每一次切行后精确地经过 1.65s～2.02s 才从 false 翻成 true**（12/12 次全部落在这个窗口内：1.650, 1.700, 1.733, 1.817, 1.833, 1.867, 1.883, 1.917, 1.950, 2.017, 2.017, 2.017），且这是行进入"已结算+非激活+有模糊"状态后**唯一**发生的一次状态翻转（设计如此：`NativeLyricsRowView.refreshRasterization` 只在 `isSettled` 时才启用光栅化缓存）。

**机制**：翻转门槛是 `NativeLyricsVisualMotionState.isSettled`——opacity/scale/blur 的值与速度都要收敛到极窄容差（blur 用 0.03）。对有一定目标模糊值的行，blur 通道在这个弹簧参数下收敛到 0.03 以内本身就要 1.5-2s，而行的可感知运动（人眼能看出来的位移/模糊变化）远早于这个数学容差就已经停止了——即创始人说的"完全静止"和代码认定的"isSettled"之间有这个延迟差。

**翻转本身是不是那个可见跳变**：无法用无头测试证实或证伪。`.claude/rules/banned-patterns.md` 里"Resident CIGaussianBlur"一条明确记录过：CIFilter 效果只有真实渲染服务器才应用，`cacheDisplay`/`render(in:)` 这类离屏捕获路径结构性看不到它。`shouldRasterize` 触发的是同一类"只有合成器才知道"的行为——把这一帧起，图层从"每帧重新求值 CIGaussianBlur 的实时渲染"切成"缓存位图纹理贴图"，如果两者在那一帧的次像素配准/滤镜插值上有任何差异，屏幕上就会读成"刚停，又跳了一下"。

**未修**：没有改这个翻转的时机或机制。理由：在没有创始人肉眼确认"这个翻转就是那个跳变"之前盲改渲染时序，正是项目"先复现再修"铁律要防的那种"猜模型直接开改"（08-25 前科）。移早触发时机不能证明能消除视觉效果，只会把同一个潜在跳变挪到更早的时间点。

**留给创始人的验证钩子**：`NANOPOD_BLUR_RASTER_OFF` 环境变量（`NativeLyricsRowView.rasterizationDisabledByEnv`）关掉整个光栅化缓存。若创始人在真机上设置这个变量后跳变消失，就实锤了这个机制；若跳变依旧，说明另有它因，本轮的强关联信号是假线索。

**代价**：几何通道本身已确认干净——如果创始人真机复测发现关掉 raster 后跳变仍在，下一轮排查可以放心排除几何/spring 层，专注 raster/CIFilter 合成器细节。

---

## 2. 回跳整行全亮无遮罩（追加到既有 `NativeLyricsSeekLandingMaskTests.swift`）

3g 已有的三场景 + 66 点穷举（真实 `mc.seek(to:)`，命中真实 `seekGeneration` 信号）全绿，覆盖了创始人这次贴的真机 trace 证据（`perRunSweep=false, applied=0.0`，词序 7/8/12）的确切形状。

**本轮新角度**：既有全部场景都是"warm up 到目标附近，目标行的 row view 早就挂载好了"。真实的外部 seek（Music.app 拖动进度条）可能一步跳到从未渲染过的行——那一行必须在落地的同一帧里从复用池里拿出来、`reset()`、并第一次套用 mask/text-phase，这是与"已挂载行换配置"完全不同的代码路径。

新增 `test_exhaustive_seekLandsOnRowThatMustBeFirstMountedOnLandingFrame_...`：在 line 0 warm up 后，远跳到 6/7/8/9/10/11/15/19 行 × 5 个进度分数（40 个用例），记录每个用例目标行是否在 seek 前真的未挂载（因为渲染半径较宽，不是每次都能达成"从未挂载"）。**实测 40 个用例里有 10 个是真正的首次挂载在落地帧**——这 10 个连同其余 30 个全部落地帧都不是"亮且无遮罩"。

**未复现**，无新线索。生产期探针 `brightUnmaskedIncomplete`（3g 已加）继续等真机现场。

---

## 3. 中文行尾字重影：dim/bright floatY 来源分歧论（结构性追溯，未新增测试文件）

3g 记录了一个"值得盯的理论风险"：`applyMainWordFloatGlyphLayers` 里 dim 瓦片浮不浮看 `floatingOrders`（源自 `run.baseFloatY`），bright 瓦片却套用 `plan.perWordFloatY(at:)`——如果两者对"这个词是否在浮动"判断不一致，就会有真实位置偏移的重影。

**本轮方法**：不写合成测试，直接追代码路径证实/证伪这条理论本身是否可能发生。

- `NativeLyricsTextRenderPlan.perWordFloatY(at:)`（`NativeLyricsTextRenderPlan.swift:173-175`）：`wordRuns.map { $0.startTime <= currentTime ? $0.baseFloatY : 0 }`——它**不重新计算** float，只是原样返回同一个 `run.baseFloatY`（这个值在 plan **构建时**就已经烘焙好了），只用传入的 `currentTime` 做一个"是否已开始"的门。
- `floatingOrders` 的推导（`NativeLyricsRowView.swift:1867-1876`）：直接检查同一个烘焙值 `run.baseFloatY != 0`（强调词走另一支路径，检查 `liftY/floatY/scale` 的烘焙值）。
- 两个真实调用点（`NativeLyricsRowView.swift:779` 与 `:1634-1642`）都是"同一个 `plan` 变量 + 同一个 `currentTime`/`renderTime` 变量"成对传入 `textRenderPlan()`（构建 `plan`）和 `applyActiveMainPhase(plan:currentTime:)`（内部调用 `perWordFloatY`），没有"plan 是旧的缓存对象、currentTime 是新鲜值"这种分叉。

**结论**：在当前代码结构下，`floatingOrders` 的门槛和 `perWordFloatY` 返回值**必然**源自同一个烘焙的 `run.baseFloatY`，两者不可能对同一个词给出"floatingOrders 说没浮动、perWordFloatY 说有非零浮动"的矛盾读数——这条理论在现有实现里结构性不成立，不是"没撞见现场"，是"这条路径不存在"。3g 留的生产探针 `recordWordFloatDesync` 可以继续留着（万一未来重构打破这个"成对传入"的不变式，探针能兜底），但本轮认为这条具体理论已可排除。

---

## 4. 三点错位/消失（未加新方法）

时间预算所限，本轮未对 3g 已确认的"已知残留（X 差 0.9pt）"之外的场景补充新的穷举路径。创始人这次的原话——"三点根本没出现、第 0 行卡在面板顶部"——3g 的第四路径测试（手动滚回顶冻结 → 从头播放释放）已经是措辞上最贴近的复现尝试，结果仍是已知的 0.9pt 残留，不是"完全不出现"。如实标注为**本轮未追加方法**，不是"复现不了=没问题"。

## 5. 切歌 bloom（未加新方法，未二分）

同样受限于本轮时间预算。3g 的 `NativeLyricsTrackChangeBloomTests`（像素法 + 行位置离散度法）仍是绿的，本轮未执行创始人建议的"对 5e85f31..HEAD 五个可疑提交逐个 revert 二分"——没有红测试就无法二分，编造二分结果违反项目铁律，故直接跳过并如实说明，与 3g 的处理方式一致。

## 6. 强调词重影/割裂：新角度已识别但未验证

追代码看到一个尚未测试的可能机制：`applyFloatingHiddenBase` 按**未缩放**的字形宽度（`glyph.rect`，来自静态排版）在暗底字符串里挖出透明洞，而强调词的亮层字形按 `scale = 1 + emphasisWeight * 0.1 * amount`（`NativeLyricsTextRenderPlan.swift:476`）放大绘制。如果挖空的洞口宽度小于放大后的字形宽度，放大的亮字会溢出到左右相邻、未被挖空（仍是满不透明暗色）的字符上——这在视觉上会读成"亮字边缘和邻字暗底重叠出模糊/割裂感"，与创始人"跟其他普通歌词太割裂"的描述方向一致，但**本轮未写测试验证这个假说**（时间预算耗尽）。留给下一轮：写一个几何测试，用真实的 `emphasisWeight`/`amount` 取值范围算出最大 scale，对比挖空字符的静态宽度与放大后字形的实际渲染宽度，看是否存在正的重叠量。

---

## 收尾

- 6 条本轮 commit：见下方列表；均未 push。
- `DEVELOPER_DIR=/Applications/Xcode.app swift test` 全量结果：见会话末尾的最终报告（后台跑，本文件写作时尚未完成）。

*报告人：Claude Sonnet 5（子代理，执行层）。第 1 条是本轮最扎实的新发现——不是"证明了 bug"，是"找到一个此前没人测过、时序和普遍性都高度吻合的强关联信号，且诚实标注了无头测试的能力边界"。第 4/5/6 条如实标注为本轮未投入新方法，不冒充穷举。*
