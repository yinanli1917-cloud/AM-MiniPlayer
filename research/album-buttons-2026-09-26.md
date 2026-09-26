# 专辑页 shuffle/repeat 按钮拆解：苹果怎么做的，我们差在哪

2026-09-26. 创始人反馈（转述）：专辑页的随机、循环两个按钮在高光封面下很难看；对照苹果 Music 迷你播放器（`docs/design/2026-09-26-album-buttons/ref-apple-music-miniplayer.webp`，908x908）与我们自己的截图（`ref-ours-album-page.webp`，764x832）。

方法：PIL 逐像素采样两张截图，找按钮圆心（先用高对比度阈值定位图标字形的 bounding box，再从圆心沿一条不穿过字形的直线扫描，找填充色与背景色之间的阶跃）。所有数字都来自这套脚本对两张截图的实测，不是目测估计；换算到 pt 的部分单独标注「推算，非实测」。

## 1. 苹果的星形／「…」按钮实测

取样点：星形按钮圆心 (648, 511)，「…」按钮圆心 (716, 511)（像素坐标，原图 908x908）。

| 量 | 数值 | 取法 |
|---|---|---|
| 圆直径 | 51–52px | 过圆心的竖直扫描线：背景→填充在 y=485→486 一步跳变（+25 亮度单位），填充→背景在 y=537→538 一步跳变（−26）。两次跳变都是 1px 内完成，不是渐变——说明苹果这个圆的边缘是硬边（半透明材质本身在边界处不做羽化），跟我们截图里非常软的边缘（见下）形成对照 |
| 两圆圆心间距 | 68px | 716−648 |
| 星形按钮填充色 | RGB(221,175,150)，亮度≈182/255 | y=486–495 的平顶采样（跳变后紧贴的一段，未混入图标白色描边） |
| 星形按钮局部背景色 | RGB(196,150,124)，亮度≈157/255 | y=480–485，跳变前紧贴的一段（同一列，只隔 1–3px，不是全图平均，是这个按钮正下方本来的颜色） |
| 「…」按钮填充色 | RGB(237,235,233)，亮度≈235/255 | 同法，x=716 列 y=486–495 |
| 「…」按钮局部背景色 | RGB(217,215,213)，亮度≈213/255 | x=716 列 y=480–485 |
| 图标颜色（星形/圆点/底部行全部一致） | RGB≈(254,254,253)，即纯白 | 阈值 248+ 的最亮像素核心均值，三处样本几乎没有色偏 |
| 底部控制行（shuffle/back/pause/forward/repeat，无圆底）的"暗化毛玻璃带"背景 | 亮度≈164/255（RGB≈170,165,158） | y≈705-715 采样 |
| 同一位置、未经暗化的原始封面亮度 | 亮度≈195/255（RGB≈225,198,161） | y≈200-220 高处采样，作对照 |

**换算到 pt（推算，非实测）**：用左上角红黄绿三个 traffic-light 按钮定标——红心 x=185.5，绿心 x=277.7，两档间距 46.1px；按 macOS 系统 traffic-light 惯例间距 20pt 估算，得 ≈2.3px/pt。据此星形/「…」圆直径 51–52px ≈ **22pt**，两圆中心距 68px ≈ **30pt**，边到边间隙 17px ≈ **7pt**。这一换算依赖「traffic-light 间距=20pt」这一常见惯例，未逐版本核实，标记为推算。

### 关键结论 1：填充色不是"全图取一个主色调一次性染色"，是每个按钮各自取它下面那一小块背景

星形按钮填充（221,175,150）与局部背景（196,150,124）的色相几乎没变——R−G、G−B 的差值两边几乎相等（背景 46/26，填充 46/25），只是整体加了约 +25/255 的亮度。「…」按钮同理：背景（217,215,213）中性灰，填充（237,235,233）还是中性灰，只是也加了约 +22/255。两个按钮加的量几乎一样（+22～+25，即全量程的 8.6%～9.8%），但两个按钮的色相完全不同——因为它们下面的背景本来就不同（星形按钮下面是暖色手臂，「…」按钮下面是冷灰高光）。

这正是 macOS 26 Liquid Glass vibrancy 材质的行为：材质对"这个控件正下方的内容"取样、模糊、做固定幅度的增亮，而不是对整张图取一次平均色再统一染色。等价于 SwiftUI 的 `glassEffect(.regular.tint(...))`／AppKit 的 `NSGlassEffectView`：tint 是"就地"起作用的，颜色由局部背景决定,不是全局取色。

### 关键结论 2：苹果自己这套"固定 +9% 增亮"在很亮的背景下也不够——「…」按钮就是弱例

星形按钮：填充亮度 182，纯白图标（255）对它的 APCA |Lc|（下面会算）明显比「…」按钮（填充亮度 235，只比纯白暗 20/255）更高。肉眼对照放大图也能看出「…」的三个白点确实比星形的白色轮廓弱一些。苹果能"混过去"，是因为：(a)「…」是低优先级的次要操作；(b) 真实专辑封面很少有大片纯白刚好落在这个位置；(c) 系统材质大概率还带了额外的高光/内阴影（这不是从静态截图能测出来的）。这一条不是我们要抄的部分——见下面第 3 节。

## 2. 我们自己按钮的实测（同一方法，自己的截图）

取样点：shuffle 圆心 (493, 508)，repeat 圆心 (538, 508)（像素坐标，原图 764x832，与苹果截图不是同一坐标系，不能跨图直接比像素）。

| 量 | 数值 |
|---|---|
| shuffle 填充色（干净采样，避开图标） | RGB(235,227,223)，亮度≈228/255 |
| repeat 填充色 | RGB(205,198,195)，亮度≈199/255（这一侧背景本身更冷更暗一点，见下） |
| 局部背景色（两侧） | 亮度≈211–214/255，RGB≈(219,211,207) |
| shuffle 图标核心色（当前用的是灰，不是白） | RGB(185,163,151)，亮度≈166/255 |
| repeat 图标核心色 | RGB(122,113,109)，亮度≈115/255（明显更暗，接近黑但非纯黑） |
| 边缘软化程度 | 远比苹果软——过圆心的竖直扫描在 30–50px 范围内是连续渐变，找不到 1px 内的硬跳变 |

换算到 pt（推算，非实测，用 `PanelWindowMetrics` 默认面板 250x284pt 与截图像素尺寸 764x832 反推比例，≈3.0px/pt）：圆直径按同一方法估算约 59–60px ≈ **20pt**——跟苹果的 22pt 量级接近，说明**尺寸不是问题**。

### 关键结论 3：我们的填充也在做"局部背景 + 固定幅度增亮"，幅度还跟苹果差不多（+17 到 +29/255），但因为按钮所在的局部背景本来就已经很亮（专辑页封面底部渐隐处，亮度普遍在 210+/255），加上同样的固定幅度增亮后，填充亮度冲到 228、甚至逼近 240+，跟纯白（255）只差 15-27/255——不够撑住白色图标

这就是当前实现（`ButtonIconDecision`/`ButtonIconGraySolve`，见下）改走"把图标调灰"这条路的根本原因：填充本身没有主动变暗的机制，只有±9%量级的轻微增亮，所以背景一亮，填充跟着亮，图标只能往深了调来保对比度——调到 shuffle 亮度 166、repeat 亮度 115（「灰不用黑」，CLAUDE.md 里 2026-09-24 那条规则）。这正是创始人说的"很难看"：iOS/macOS 上白色描边图标是标准语言，灰色/接近黑色的图标在毛玻璃胶囊里看着像"脏了"。

### 关键结论 4：苹果的圆是硬边（1px 内完成阶跃），我们的圆边缘极软（30-50px 渐变）

这与本次任务的"只改按钮自己的外观（填充、描边、图标）"约束一致——本次不动形状/边缘处理，只记录这一差异供之后参考。

## 3. 我们要抄的是什么，不抄的是什么

**抄**：局部取样（不是全局主色）＋轻微 hue-preserving 增亮（材质通透感）＋图标恒定纯白。

**不抄**：苹果"固定 +9% 增亮、不管背景多亮"这一步本身——因为这一步在苹果自己的「…」按钮上已经是临界情况，直接照搬到我们背景更亮的专辑页只会重现同一个弱点。改成：先按苹果的方式增亮，如果增亮后对纯白图标的对比度仍不达标（用项目已有的 APCA 门槛，`ButtonIconDecision.grayThreshold = 45`），才对填充做保色相的整体变暗（RGB 三通道同比例向黑收缩，解到刚好卡在门槛上）——这是"保证"而不是"经验值"，直接复用本仓库 `BackdropLegibilityBand.resolveChannelCorrect` 已经在用的同一种「解二分方程找刚好卡线的系数」手法，以及 `ButtonIconGraySolve` 「解到刚好卡在门槛上、绝不到纯黑」的同一哲学——只是这次解的是"填充该多暗"而不是"图标该多灰"。

## 4. Apple 文档交叉核对

- `mcp__apple-dev-mcp__search_human_interface_guidelines` 搜 "Liquid Glass buttons tint materials"／"materials vibrancy" 命中了真实页面（"Materials & Visual Effects"，`developer.apple.com/design/human-interface-guidelines/materials`；"Buttons"，`.../buttons`），但搜索工具本身只返回一句摘要，不是正文。
- `mcp__apple-dev-mcp__search_technical_documentation` 搜 "Glass" 命中了 "Adopting Liquid Glass"（`developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass`）与 "Landmarks: Building an app with Liquid Glass"（`developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass`）两篇真实文档；搜 "glassEffect regular tint Glass" 无结果。
- 用 WebFetch 分别抓了 `.../materials` 和 `.../adopting-liquid-glass` 这两个真实 URL，两次都只拿到页面 `<title>`，正文没有取到——这两页是 JS 渲染的文档站，WebFetch 的静态抓取过不去这一关。没有找到能绕过这个限制的办法（换页面、换查询词都一样）。**结论：苹果官方文档关于 tint 具体怎么取样/渲染的原文，本次没有取得，标记为未核实**——第 1 节"局部取样、非全局主色"的结论，依据的是对苹果截图的像素实测（可复现、有数字），不是文档。
- 代码层面确认（非文档，是读本仓库现成代码，可信度高于上面两条）：`Sources/MusicMiniPlayerCore/UI/HoverableButtons.swift` 里已经有 `GlassCircle` 这个 ViewModifier，macOS 26 分支就是 `content.glassEffect(.regular.tint(tint), in: .circle)`——即 SwiftUI 原生 API 确实支持"regular glass + 自定义 tint 色"，与本文第 3 节的方案完全对应，只是这个 modifier 之前没有任何调用点（未接入）。本次实现复用了这个已验证可行的 API 形状，但没有直接复用 `GlassCircle` 这个类型本身（它没有"降低透明度/增强对比度→退回实色"的分支，且只服务这一处调用点）。

## 5. 现状代码结构（供实现参照）

- `Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift` 的 `shuffleRepeatCluster`（约 L528-573）：真正渲染这两个圆按钮的地方。未选中态背景是 `Circle().fill(Color.clear)` + `GlassButtonTexture(shape: Circle())`（`.glassEffect(.clear, in: shape)`，不带 tint）；图标色来自 `iconColor(for:)`。
- `Sources/MusicMiniPlayerCore/UI/ButtonIconLegibility.swift`：现有的"图标该白还是该灰"整条异步管线——`ButtonIconRects`（按钮在面板坐标系里的真实位置，24x24）、`ButtonIconCompositeBitmap.dominantColor`（全屏模式下对按钮正下方局部区域做中值取色，已经就是"局部取样"）、`ButtonIconBackdropColor.predictedFluidBackdropColor`（非全屏模式下复用 `FluidGradientBackground` 的解析预测）、`APCAContrast`（APCA 感知对比度）、`ButtonIconDecision`/`ButtonIconGraySolve`（白/灰判定 + 解到刚好卡线的灰阶）、`ButtonIconRefreshCoordinator`（actor，off-main-thread，generation token 防止旧结果覆盖新结果）。这一整套取样管线本次原样复用，只是新增一条"从取样色算填充色"的路径，不复用"算图标该多灰"那条路径。
- `Sources/MusicMiniPlayerCore/UI/MicroInteractionFeel.swift`：本项目所有"新旧行为二选一"开关的统一登记处，模式是 `enum XxxMode: String, CaseIterable` + `<name>DefaultsKey` + `testingXxx`（DEBUG 覆盖）+ `resolve(from:)` + 在 `apply(channel:value:)`/`reset()` 里登记一行。
