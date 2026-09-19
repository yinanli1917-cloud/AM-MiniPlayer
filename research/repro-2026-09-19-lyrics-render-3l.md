# 3l — 中文逐字行「尾字重影」（《啟程》"未来的旅程"）

2026-09-19. 创始人报告：《啟程》第二折行行尾出现原文下方偏下几 pt 的模糊副本，主观最明显在
"程"/"旅程" 附近。起点是真机 rowdump（`rowdump_ghost3.txt`，~1s 间隔 4 帧快照，含
`hollowedRanges`/filters/rasterization）。

## 复现尝试与结论：未复现（两层，穷举）

先读真机 dump：4 帧样本里 `mainTextLayer(dim-base)` 的 `hollowedRanges` 与
`mainDimWordGlyphLayers`/`mainBrightWordGlyphLayers` 浮动字的下标集合，帧帧一致（挖空集合 ==
实际位移非零集合），说明 1s 间隔的粗采样本身看不出瞬态——需要逐帧复现。

### 第一步：模型层不变式（60Hz + 100ms + 250ms 全帧）

新增 `Tests/MusicMiniPlayerTests/NativeLyricsDimBaseFloatGateConsistencyTests.swift`，驱动真实
《啟程》13 字行（"只有你能带我走向未来的旅程"，逐字 0.55s 一格，panelWidth=250 复刻真机
ROOT frame 宽度，8+5 折行）过整行 + 结束后 1s，逐帧断言：

> 若某字的 per-glyph DIM 贴片 `isHidden`（即信任整行 dim-base 原样显示该字），则该字的 BRIGHT
> 贴片必须与 DIM 贴片同位置（容差 0.25pt）——否则整行 base 在原地显示一份、BRIGHT 贴片却飘在
> 别处显示第二份，就是重影。

三档时钟（1/60s、100ms、250ms）全绿，0 违例（`swift test --filter
NativeLyricsDimBaseFloatGateConsistencyTests`）。

代码级原因：per-glyph 悬挂门（`floatingOrders`，来自 `run.baseFloatY != 0`）和 BRIGHT 贴片实际
位移（`input.floatY`，来自 `plan.perWordFloatY(at:)`）在纯中文、非强调（`isCJK` 恒 `.inactive`
的强调门，见 `NativeLyricsTextRenderPlan.swift:458`）路径上，读的是**同一个** `run.baseFloatY`
存量值（plan 构建时算一次，两处只读不重算），且 `applyActiveMainPhase` 用同一个 `renderTime`
既建 plan 又调两处消费函数——代数上不可能出现两个门disagree。这与既往 3g/3h/3i/3j/3k 几轮真机
复现失败的结论一致。

### 第二步：presentation() vs model 零差（CALayer 合成滞后）

新增 `NativeLyricsRowView.debugMainWordGlyphPresentationDeltas`（`.lyricsInert()` 之外的最后一道
防线：模型值已经翻篇但合成器还在画上一帧）与配套测试
`test_everyGlyph_everyFrame_60Hz_presentationLayerNeverDriftsFromModel`——每帧 `CATransaction.
flush()` 后比较每个 DIM/BRIGHT 贴片的 `presentation()?.position` 与 `.position`。同样全绿：没有
残留的隐式/显式动画在这条路径上让合成层落后于模型层。

### 结论

在《啟程》这条真实折行 + 生产默认设置（`sweepPathMode = .v28`、`emphasisMode = .amll`，均为
`isRunningTests` 下与线上一致的默认臂）下，模型层与 CA 合成层两道穷举检查都干净——**没有找到
可在代码层复现的重影**。按项目铁律「未复现不许当没问题上报」，这不等于「没有 bug」，只代表：
这次的假设（悬挂门与位移公式脱节 / CA presentation 滞后）在能想到的两个层面都被证伪了。

## 已排除的路径

- **强调（emphasis）双对象幽灵**（3c/3d 那类，`emphasisGlyphLayers` 独立定位）：CJK 强制走
  `NativeLyricsEmphasisPlan.make` 的 `guard !isCJK else { return .inactive }`，纯中文歌词永远不
  进强调管线，`emphasisOrders` 恒空，`tilesOwnEmphasis` 恒 false——与本案（纯中文逐字 YRC/AMLL
  行）无关。
- **悬挂门 vs 位移公式代数脱节**：见上，同一存量值，代数上不可能。
- **CALayer presentation 落后 model**：见上，穷举 60Hz 全绿。

## 未排除 / 下一步建议

1. **真机 DEBUG 埋点**：既然两层穷举都干净，剩下的候选是本次测试没有复刻到的真机条件——真实
   NetEase/QQ YRC 时间轴的不规则字间距（本测试用等距 0.55s 简化）、真实字体 metrics（非测试
   环境的近似字宽）、或者行折算宽度与真机不完全一致导致折行位置差 1 字。按项目「先复现再修」
   铁律，下一步应比照 `NativeLyricsMaskTrace` 的模式，在 `applyMainWordFloatGlyphLayers` 里加一
   条**默认关闭**、`NANOPOD_PROBES` 开关下的逐帧 JSONL 埋点（dim/bright 位置、hidden、
   floatingOrders 成员），让创始人下次日常播放到该曲目时自动落证据，而不是再次盲猜合成一个
   fixture。
2. 复核折行宽度：真机 dump 里 `mainTextLayer(dim-base)` 的 `frame.width=186`，本测试 panelWidth
   250 是照抄 ROOT frame，但未验证 186pt content width 下的真实换行点是否恰好落在「旅」/「程」
   之间——如果真机因为不同字体渲染折行位置和本测试的折行位置有 1 字之差，`floatingOrders`/
   `perWordFloatY` 的按位对齐前提本身就可能对不上（这不是两个测试目前覆盖到的场景）。

## 涉及文件

- `Tests/MusicMiniPlayerTests/NativeLyricsDimBaseFloatGateConsistencyTests.swift`（新增，4 个测试）
- `Sources/MusicMiniPlayerCore/UI/NativeLyricsRowView.swift`
  （新增 `debugMainWordGlyphPresentationDeltas`，纯诊断只读属性，`#if DEBUG`）

## 回归

`NativeLyricsCJKTrailingGhostExhaustiveTests`、`NativeLyricsActiveLineSpacingTests`、
`NativeLyricsDimBaseContinuityTests`、`NativeLyricsEmphasisHollowContainmentTests`、
`NativeLyricsPostSeekReactivationMaskTests`、新增的
`NativeLyricsDimBaseFloatGateConsistencyTests`：22/22 全绿
（`swift test --filter 'NativeLyricsCJKTrailingGhostExhaustiveTests|NativeLyricsActiveLineSpacingTests|NativeLyricsDimBaseContinuityTests|NativeLyricsEmphasisHollowContainmentTests|NativeLyricsPostSeekReactivationMaskTests|NativeLyricsDimBaseFloatGateConsistencyTests'`）。
