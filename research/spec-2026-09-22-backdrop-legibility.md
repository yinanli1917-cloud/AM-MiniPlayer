# Spec: 背景明度带（Backdrop luminance band）— 2026-09-22

## 创始人报告的两个症状
1. 封面很亮（例：CinCin Lee《Story Island》白底封面，全屏封面模式 fullscreenAlbumCover=true）时，专辑页底部的随机/循环圆按钮（`MiniPlayerView.shuffleRepeatCluster`，白色图标 + `.clear` glass）几乎看不见；同区的标题、艺人、进度条、时间、播放控件也是白色，同样对比度不足（截图里底部背景约是浅灰）。
2. 封面很暗时，进入歌词页，背景（`FluidGradientBackground`，经 `PanelBackdrop` 挂在面板底层，歌词页/歌单页/非全屏专辑页共用）被压得接近纯黑，白色歌词对比度过高、不柔和。

顶部两个按钮（Music 返回、AirPlay）已经用分区亮度 `topLeftArtworkLuminance/topRightArtworkLuminance` 翻转黑白前景（`GlassButtonBackground`），本次不改它们。

## 方案：一条通用规则，不给单个控件打补丁
所有「白色前景叠在封面衍生背景上」的区域，都用同一个纯函数把背景的实际明度夹进一个带里：
- 上限（ceiling）：保证白色前景对背景的 WCAG 对比度 ≥ 4.5:1（正文文字标准）。超过上限 → 加黑色 scrim 压暗到上限。
- 下限（floor）：白色前景对背景的对比度 ≤ 约 12:1。低于下限 → 提亮到下限（优先用保色相的方式，例如给 texture 的 `.brightness` 加量，而不是 screen 白色蒙层把颜色洗灰；实现者按实测挑一种并说明理由）。
- 带内 → 不做任何改动（中间亮度的封面外观字节级不变）。
- 对比度按 WCAG relative luminance 计算（sRGB 先线性化），不要直接用 gamma 值。4.5 与 12 做成 `MicroInteractionFeel.Tokens` 里的常量，便于创始人后调。
- 纯函数：输入「修正前的背景实测/预测明度」，输出「需要叠加的 darken opacity / lift 量」。无 SwiftUI、无 I/O，放在一个新文件或 `FluidGradientBackground.swift` 旁边，命名如 `BackdropLegibilityBand`。

应用点（同一个函数，两处调用）：
A. `FluidGradientBackground`：按每次换封面算一次（与现有 `tone`/`contrastResolution` 同节拍，不是每帧），修正前明度 = 现有 tone map（及 C5 如开启）作用后的背景平均明度。它覆盖歌词页、歌单页、非全屏专辑页的 hover 状态控件背景。
B. 全屏封面模式专辑页底部控件区（标题/艺人/随机循环/进度/时间/播放控件所在的底部带）：这里的背景是 hero 封面底部 100pt 渐隐区 + Layer 1 模糊底图（只用了 `textureBrightness` 与 `textureDimmingOpacity`，没有 shade）。修正前明度取该底部带的实际明度（封面底部行的亮度与底图预测亮度按渐隐合成；保守起见可取底部分列取样的最大值，已有未使用的 `NSImage.controlAreaMaxLuminance`）。修正方式：在控件区下方加一层从透明渐变到 darken opacity 的底部 scrim（渐变，不是硬边），仅在超上限时出现。

不在本次范围：顶部按钮、Reduce Transparency/Increase Contrast 的新分支（现有 Reduce Transparency 行为保持）、C5 `.tuned` 臂的去留（带函数排在所有现有层之后计算，只补差额，不与 C5 叠加重复压暗）。

## 先复现再修（项目铁律）
改代码之前，先写失败测试把两个症状在代码层面复现：
- 用 `ImageRenderer`（或项目里已有的离屏渲染手段）真实渲染 `FluidGradientBackground`，喂合成封面（纯白、近黑 #0A0A0A、纯中灰、一张上白下黑的双色图），测渲染结果平均 relative luminance，算白色前景对比度。当前代码下：近黑封面对比度 > 12（症状 2），纯白封面对比度 < 4.5（症状 1 的同类）。如果 `ImageRenderer` 渲不出 blur/brightness 等效果，改用解析模型（SwiftUI `.contrast(c)`: (x−0.5)·c+0.5；`.brightness(b)`: x+b；黑蒙层 α: x·(1−α)；screen 白 α: x+α(1−x)），并在报告里明说用的是哪种、为什么。
- 全屏封面底部控件带：同样对纯白封面测底部带明度 → 当前对比度 < 4.5（症状 1）。
- 测试放 `Tests/MusicMiniPlayerTests/BackdropLegibilityBandTests.swift`，大小对齐邻近的 `ArtworkContrastFeelTests.swift`。

修完后同一批测试转绿，另加：带内封面（中灰）修正量为 0（外观不变）；纯函数在带边界两侧连续（不许硬跳）。

## 验证约束
- 只跑相关测试类，串行：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BackdropLegibilityBandTests`，以及 `ArtworkContrastFeelTests`。禁止跑全量、禁止并行 swift test。
- 不用 computer use、不截图、不录屏、不启动 app 看屏幕。
- `swift build` 必须通过。
- 手感/视觉最终由创始人亲自验收，报告里写明这一点。

---

## 结果（2026-09-22 实现完成）

### 用了 analytic model，没用 ImageRenderer

`NSImage.artworkVisualMetrics()` / `.controlAreaMaxLuminance()` 是真实调用（纯 CGContext 像素运算，无需窗口，headless 确定性强），但 `FluidGradientBackground` 的 `GeometryReader` + 大半径 `.blur()` + blend-mode 合成链没有用 `ImageRenderer` 离屏渲染 —— 原因：
1. 项目已有文档记录的 flaky 渲染测试教训（`lyrics_disk_preflight_and_flaky_tests.md`：`cacheDisplay` 类 headless 渲染测试在重负载下会 capture-blank），`ImageRenderer` 渲染大半径 blur + blend mode 的可靠性没有先例验证，风险不可控。
2. spec 本身给出的解析公式（`.contrast(c)`: (x−0.5)·c+0.5；`.brightness(b)`: x+b；黑蒙层 α: x·(1−α)；screen 白 α: x+α(1−x)）已经精确描述了这条合成链的每一步，用它们做纯函数比截图渲染更快、更确定、也更符合项目「手感类验证只做代码层面：确定性回放」的既有约定（`ArtworkContrastFeelTests` 本身也是纯模型测试，无 view hosting）。
3 个中间步骤（`.contrast` → `.brightness`）**不做**夹紧（模拟合成器扩展色域，只在最终返回值夹紧到 0...1）——这个假设直接决定纯白封面的复现数值(见下表)，如果中间步骤夹紧会得到不同（更保守）的数字。

### 复现（红）→ 修复（绿）对比表

先复现：只用 `fluidBackdropToneLuminance` / `fullscreenBottomBandToneLuminance`（现有 tone-map/C5 数学的解析复刻，**不经过**新写的 `resolve()`），对目标对比度断言，全部按预期失败：

| 场景 | 修正前明度 (gamma) | 修正前对比度 | 断言 | 结果 |
|---|---|---|---|---|
| Point A 纯白封面 | 0.5082 | 3.864 | ≥4.5 | 红（症状1同类，超上限） |
| Point A 近黑封面 #0A0A0A | 0.00376 | 20.878 | ≤12 | 红（症状2，超下限） |
| Point B 全屏底部带·纯白封面 | 1.0（封面本体，未模糊未压暗） | 1.0 | ≥4.5 | 红（症状1本体） |

再接入 `resolve()`+`apply()`（步骤2：纯函数），同一批断言转绿：

| 场景 | 修正前明度 | 修正 | 修正后明度 | 修正后对比度 |
|---|---|---|---|---|
| Point A 纯白封面 | 0.5082 | darkenOpacity=0.0844 | 0.4653 | **4.500**（=ceiling） |
| Point A 近黑封面 | 0.00376 | liftAmount=0.2098 | 0.2136 | **12.000**（=floor） |
| Point B 纯白封面底部带 | 1.0 | darkenOpacity=0.5347 | 0.4653 | **4.500**（=ceiling） |

带内不动 + 边界连续性（新增测试，非复现测试）：

| 场景 | 修正前明度 | 修正前对比度 | 修正 |
|---|---|---|---|
| 中灰 (0.5 gamma) | 0.31647 | 7.975 | darken=0, lift=0（带内，字节级不变） |
| 双色（上白下黑，avgLum=0.5） | 0.21271 | 12.041 | 记录用，紧贴 floor 边界，未强断言（真实抽样噪声可能使其略高或略低于 12） |
| ceiling 边界±0.01 | — | — | 边界处=0，越界侧 <0.05（连续，无硬跳变） |
| floor 边界±0.01 | — | — | 同上 |

以上「修正前明度」「对比度」全部来自 2026-09-22 实际 `swift test --filter BackdropLegibilityBandTests` 输出（XCTAssert 失败信息 + 临时 print 探针，探针已移除，不留在最终测试文件里）。

### 提亮技术选型：加性 `.brightness`，不用 screen 白

Point A 的下限修正用 `.brightness(legibilityCorrection.liftAmount)`（加到整个已合成 ZStack 上），不用 `Color.white.opacity(a).blendMode(.screen)`：screen 白会把纹理颜色向灰洗（越亮的通道洗得越少、越暗的通道洗得越多，破坏色相比例），而 `.brightness` 对 RGB 三通道等量加，保色相。这与 spec 建议的方向一致（"优先用保色相的方式，例如给 texture 的 .brightness 加量"）。Point B 的观测数据里 `resolve()` 只产生过 darken（没有 lift 场景），所以 Point B 未走到提亮分支，但函数本身两点通用。

### Token 值（`MicroInteractionFeel.Tokens`，新增）

```
backdropLegibilityCeilingContrast: Double = 4.5
backdropLegibilityFloorContrast: Double = 12.0
backdropLegibilityBottomBandHeight: CGFloat = 160   // point B 底部 scrim 渐变高度，视觉手感项，创始人可后调
```

### 改动文件

- 新增 `Sources/MusicMiniPlayerCore/UI/Background/BackdropLegibilityBand.swift`：WCAG 线性化/对比度纯函数、`resolve()`（带函数本体）、`apply()`、`fluidBackdropToneLuminance`（point A 解析复刻）、`fullscreenBottomBandToneLuminance`（point B 解析复刻）。
- 新增 `Tests/MusicMiniPlayerTests/BackdropLegibilityBandTests.swift`：11 个测试（3 个复现→修复 + 1 个中灰零修正 + 1 个双色记录 + 6 个 `resolve()` 自身契约：边界为零、边界连续、精确夹到 ceiling/floor）。
- 改 `Sources/MusicMiniPlayerCore/UI/MicroInteractionFeel.swift`：加 3 个 Token。
- 改 `Sources/MusicMiniPlayerCore/UI/Background/FluidGradientBackground.swift`（point A 应用点）：`updateTone()` 新增 `legibilityCorrection` 计算（不改 `tone`/`contrastResolution` 原有数值，只追加）；body 里 C5 层之后追加一层「仅超上限出现」的黑色 scrim，整个合成 ZStack 追加 `.brightness(legibilityCorrection.liftAmount)`。
- 改 `Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift`（point B 应用点）：新增 `artworkAverageLuminance`/`artworkBottomRowLuminance` 两个 `@State`（复用已有的 `artwork.artworkVisualMetrics()` 调用点，未新增图像处理调用），新增 `bottomBandLegibilityCorrection` 计算属性，`albumOverlayContent` 的 ZStack 首位追加一个仅全屏专辑页模式、仅超上限出现的底部渐变 scrim。

### 验证结果

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BackdropLegibilityBandTests` → 11/11 通过。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ArtworkContrastFeelTests` → 21/21 通过（C5 原有策略表无回归）。
- `swift build` → 编译通过（仅有与本次改动无关的既存 warning）。
- 未跑全量测试、未跑并行 swift test、未用 computer use/截图/录屏/启动 app。

### 创始人终验提醒

本次改动含视觉/手感层（底部 scrim 渐变高度 160pt、动画时长复用 `artworkContrastDarkenAnimationDuration` 0.31s）——按 CLAUDE.md「手感类验证」永久规则，自动测试通过不能替代终验，需要创始人拿真实白色/近黑封面在全屏专辑页、歌词页、歌单页肉眼过一遍。

### 顺手发现但未处理的问题（按任务范围铁律，未修）

- `FluidGradientBackground` 的 `legacyArtworkContrast` 分支（C5 `.legacy` 臂,当前生产默认）与 `.tuned` 臂对 `fluidBackdropToneLuminance` 的 `applyContrastDarken` 参数不同，两个臂各自会得到不同的 `legibilityCorrection`——这是预期行为（带函数不管哪个臂输出都补齐到带内），但两臂切换时的过渡动画未专门测试。

---

## 复核修正（2026-09-22，协调者二审两处必改）

### 问题1：Point B scrim 在控件实际所在高度没有交付建模的对比度

原实现是 160pt 单段线性渐变（0→darkenOpacity），协调者指出真实前景元素（hover 标题、shuffle/repeat 行、非 hover 标题）都不在最底部像素，而是落在渐变的 30%~70% 高度处，那里的不透明度只有 `darkenOpacity` 的一部分——对比度远达不到测试断言的 4.5。用旧渐变实测三个真实位置：

| 位置（距底边） | 旧渐变 opacity 分数 | 旧渐变最终对比度 | 新方案 opacity | 新方案最终对比度 |
|---|---|---|---|---|
| hover 标题顶部 ≈107pt | 35.8% | **2.50** | 100%（平台区） | **4.50** |
| shuffle/repeat 行顶部 ≈108pt | 36.1% | **2.52** | 100%（平台区） | **4.50** |
| 非 hover 标题 ≈44pt | 14.7% | **1.41** | 100%（平台区） | **4.50** |

修复：scrim 改为「平台区（distance ≤ flatHeight）恒为满 darkenOpacity + 渐隐区（flatHeight~flatHeight+fadeHeight）线性降到 0」的两段式，纯函数 `BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom:darkenOpacity:)`；`MiniPlayerView` 的 `LinearGradient` 改成 3-stop（`0→clear`, `fadeFraction→darken`, `1.0→darken`）对应同一形状。

`flatHeight` 推导（新 Token `backdropLegibilityBottomBandFlatHeight = 80 + 4 + 24 + 8 = 116`）：
- `controlsHeight`(80，与 `albumOverlayContent` 本地常量同值) + shuffle/repeat 行 `.padding(.bottom, 4)` + 行自身高度（按钮 24×24）= 108pt，即两个最高前景元素（hover 标题顶 ≈107pt、shuffle 行顶 108pt）的天然位置。
- +8pt 安全边距（文本行高/ascent 不是一个可引用的现成常量，显式留白）。
- `fadeHeight`（新 Token `backdropLegibilityBottomBandFadeHeight = 44`）延续原 160pt 总高度（116+44=160），保持视觉「触达范围」与创始人已认可的旧尺度一致，只改内部分布。

新增测试：`test_pointB_scrimAtHoverTitleTop_isFullOpacity`、`test_pointB_scrimAtShuffleRepeatRowTop_isFullOpacity`（在真实计算出的 y 位置采样 `bottomBandScrimOpacity`，用同一个 `apply()` 验证该点对比度 ≥4.5）、`test_bottomBandScrimOpacity_fadesToClearAboveTheFlatZone`（平台区/边界/渐隐区/渐隐区外四点）、`test_bottomBandScrimOpacity_zeroDarkenIsAlwaysZero`。

### 问题2：常驻 `.brightness(liftAmount)` 是一个 resident CIFilter，即使值为 0 也会被合成器每帧重新求值

原实现在整个已合成的 ZStack 外层加了一层 `.brightness(legibilityCorrection.liftAmount)`。协调者指出：项目已实测「合成器对每个常驻 filter 每次 recomposite 都重新求值」（CLAUDE.md Performance Traps「Resident CIGaussianBlur」+ blur economy 记忆），这层 `.brightness()` 无论 `liftAmount` 是不是 0 都会常驻存在，等于凭空加一个 WindowServer 成本。

修复：删掉这层外层 `.brightness()`，把 lift 折进已经存在的内层 `.brightness(tone.textureBrightness)`。推导（`BackdropLegibilityBand.innerBrightnessDelta`）：内层 brightness 之后的链路对内层输出 x2 是仿射的——

```
final = (a + (1-a)·x2) · (1-s) · (1-d)
  a = tone.liftOpacity（白色 screen 混合）
  s = tone.shadeOpacity（黑色叠加）
  d = C5 darken（未启用则为 0）
```

要把 `final` 抬高 `liftAmount`，只需把 x2 抬高 `liftAmount / ((1-a)(1-s)(1-d))`，即把这个增量直接加到 `tone.textureBrightness` 上（同一个 `.brightness()` 调用点，零新增 filter）。生产代码新增 `@State legibilityInnerBrightnessDelta`，`.brightness(tone.textureBrightness)` 改成 `.brightness(tone.textureBrightness + legibilityInnerBrightnessDelta)`；`updateTone()` 用 `innerBrightnessDelta` 算出这个增量。

验证：新增 `test_pointA_nearBlackArtwork_foldedInnerBrightness_reachesExactFloor`——用折叠后的增量重跑整条解析管线，确认与 `apply()` 抽象结果数值一致（accuracy 0.0005）且仍精确落在 12.000（floor）；`test_innerBrightnessDelta_zeroWhenNoLiftNeeded` 确认无需修正时增量为 0（不改变现有 `.brightness()` 数值，字节级不变）。

近黑封面数据（折叠前后一致，只是产生机制不同）：

| 场景 | 修正前明度 | liftAmount | innerBrightnessDelta | 折叠后明度 | 折叠后对比度 |
|---|---|---|---|---|---|
| Point A 近黑封面 | 0.00376 | 0.2098 | ≈0.2098/((1-a)(1-s)(1-d)) | 0.2136 | **12.000** |

### 改动文件（本次复核追加）

- `Sources/MusicMiniPlayerCore/UI/Background/BackdropLegibilityBand.swift`：`fluidBackdropToneLuminance` 加 `textureBrightnessOverride` 参数；新增 `innerBrightnessDelta`、`bottomBandScrimOpacity`。
- `Sources/MusicMiniPlayerCore/UI/MicroInteractionFeel.swift`：`backdropLegibilityBottomBandHeight` 拆成 `backdropLegibilityBottomBandFlatHeight`(116) + `backdropLegibilityBottomBandFadeHeight`(44)。
- `Sources/MusicMiniPlayerCore/UI/Background/FluidGradientBackground.swift`：删除外层 `.brightness(legibilityCorrection.liftAmount)`；`legibilityInnerBrightnessDelta` 折进内层 `.brightness()`。
- `Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift`：底部 scrim 改 3-stop 渐变（平台区+渐隐区）。
- `Tests/MusicMiniPlayerTests/BackdropLegibilityBandTests.swift`：新增 6 个测试（17 个，原 11 个）。

### 验证结果（复核后）

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BackdropLegibilityBandTests` → 17/17 通过。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ArtworkContrastFeelTests` → 21/21 通过。
- `swift build` → 编译通过。
- 手感/视觉终验提醒同前：本次两处修正都改变了实际渲染像素（scrim 分布、brightness 数值来源），创始人仍需亲自过一遍真实全屏专辑页与歌词页。

---

## 暴力扫描复核（2026-09-22，协调者三审）

一个测试 `test_bruteForceSweep_grayscaleSaturatedHighVariance` 覆盖三类夹具，全部经真实 `artworkVisualMetrics()` / `controlAreaMaxColor()`（或高方差夹具用 `controlAreaMaxLuminance()`）+ tone map + band 全链路，不手喂 metrics。

### 发现：饱和色下旧标量模型（gamma 混合后再当灰度处理）严重失真

`averageLuminance` 是「先按 Rec.709 权重混合 R/G/B（gamma 空间）,再线性化」，这对灰色（R=G=B）精确无误，但对饱和色是错的——正确做法是「先线性化每个通道，再混合」（WCAG 定义本身）。两者对饱和色可以差一个数量级。实测（Point A，`.legacy` 臂）：

| 颜色 | 旧模型宣称对比度 | 真实（channel-correct）对比度 | 偏差 |
|---|---|---|---|
| 纯红 | 12.000（宣称已在 floor，安全） | **6.518** | −5.482 |
| 纯品红 | 12.000（宣称安全） | **5.436** | −6.564 |
| 纯蓝 | 12.000 | 11.320 | −0.680 |
| 纯绿 | 5.562 | 4.500 | −1.062 |
| 青色 | 5.259 | 4.500 | −0.759 |
| 黄色 | 4.815 | 4.500 | −0.315 |
| 深藏青 | 12.000 | 12.000 | 0.000 |
| 淡粉彩 | 4.500 | 4.500 | −0.000 |

8 种色板里 6 种偏差 > 0.3（红、品红、蓝、绿、青、黄），最严重的红/品红偏差超过 5–6.5 个对比度单位——旧模型会把「实际只有 5.4:1」的品红背景误判成「已经在 12:1 floor，安全」，即错误地不去修正一个本该继续压暗/提亮的背景。这是会影响真实彩色专辑封面（远比灰阶封面常见）的真实缺陷，按协调者指示做了通用修复（非按颜色分支）。

### 修复：`BackdropLegibilityBand` 新增 channel-correct 路径，通用适用于任意色相

- `NSImage+AverageColor.swift`：`artworkVisualMetrics()` 顺带累加 R/G/B 均值，`ArtworkVisualMetrics` 新增 `averageRed/averageGreen/averageBlue`（默认值 0.5，纯加法，不影响任何既有调用点）；新增 `controlAreaMaxColor()`（与 `controlAreaMaxLuminance()` 同一套列扫描，返回胜出列的真实 RGB 而非单一标量）。
- `BackdropLegibilityBand.swift` 新增：
  - `RGBColor`、`relativeLuminance(_:)`（真 WCAG：先线性化每通道再按 Rec.709 权重混合）、`whiteContrastRatio(relativeLuminance:)`。
  - `resolveChannelCorrect(preCorrection:)`：对三通道统一施加的 darken/lift（黑色蒙层乘法、brightness 加法在真实合成器里本来就是逐通道且系数对三通道相同），用二分法解出让「真实 relative luminance」精确落在 ceiling/floor 边界所需的 alpha/delta——三通道混合后没有闭式解，二分法通用适配任意色相，无按颜色分支。
  - `fluidBackdropToneColor` / `fullscreenBottomBandToneColor`：把已有的 `fluidBackdropToneLuminance` / `fullscreenBottomBandToneLuminance` 逐通道复用（同一套 contrast/brightness/screen/shade/C5 公式，只是分别喂 R、G、B）。
- 保留原有标量 API（`resolve`/`fluidBackdropToneLuminance`/`fullscreenBottomBandToneLuminance`/`apply(Double,...)`）不变——对灰度输入两条路径数值完全一致（灰度时 `relativeLuminance` 退化成 `srgbToLinear(x)`，与旧公式恒等），17 个既有测试全部原样通过，无需改动。
- 生产改线：`FluidGradientBackground.updateTone()` 与 `MiniPlayerView` 的 point B correction 改喂 `metrics.averageRed/averageGreen/averageBlue`（或 `controlAreaMaxColor()`）到 channel-correct 路径；`tone`/`contrastResolution` 本身（决定纹理明暗风格的、已经独立调好参的系统）仍然吃旧的 `averageLuminance` 标量——只有「legibility 修正量」本身需要 WCAG 精确，纹理风格决策不在本次修复范围内。
- `innerBrightnessDelta`（fold 进内层 `.brightness()`）公式不变仍然成立：链路里 `a`(liftOpacity)/`s`(shadeOpacity)/`d`(C5 darken) 对三通道是同一组标量系数，所以「往三通道均匀加 delta」这件事，无论 delta 来自闭式解还是二分法，折算成内层 brightness 增量的公式完全一样，代数上可推导验证（无需改这个函数）。

### 三类夹具的扫描结果（表格节选，完整表在测试输出里，`swift test` 跑一次即可复现）

**Part 1 灰度扫描**（0.00→1.00，step 0.02，51 点，Point A 断言落在 [4.5,12.0]±0.01，Point B 在 hover 标题顶/shuffle 行顶 断言 ≥4.5）——51 点全部通过；灰度 0.60 起 Point B 已在 ceiling（4.500）钉住，灰度 0.78 起 Point A 也钉在 4.500；极暗灰度（≤0.38）Point B 天然对比度 11–21（生产从不对 Point B 做提亮，只做压暗，暗封面本就高对比，不违反 ≥4.5 要求）。

**Part 2 饱和色**（见上表 8 种，全部通过 Point A 在带内 + Point B ≥4.5 的断言；divergence 报告见上）。

**Part 3 高方差**（5 种：垂直/水平对半黑白、白底黑下四分之一、黑底白下四分之一、棋盘格）——Point B 用标量 `controlAreaMaxLuminance()`（按指示），5/5 全部 ≥4.5（`black_white_bottomQ` 底部四分之一是纯白，`controlAreaMaxColor`/`controlAreaMaxLuminance` 精确捕到它，触发压暗，最终仍钉在 4.500）；Point A mean-based 与 p90-highlight-based 对比度仅打印记录，不断言（例如 `white_black_bottomQ`：mean 对比度 6.330 vs p90 对比度 4.500——p90 更保守，因为它把最亮 10% 像素当代表值）。

### 改动文件（本次暴力扫描复核追加）

- `Sources/MusicMiniPlayerCore/Utils/NSImage+AverageColor.swift`：`artworkVisualMetrics()` 加 R/G/B 均值累加；新增 `controlAreaMaxColor()`。
- `Sources/MusicMiniPlayerCore/UI/Background/FluidGradientBackground.swift`：`ArtworkVisualMetrics` 加 `averageRed/averageGreen/averageBlue` 字段（自定义 init 给默认值，保持所有既有调用点不变）；`updateTone()` 改用 channel-correct 路径。
- `Sources/MusicMiniPlayerCore/UI/Background/BackdropLegibilityBand.swift`：新增 `RGBColor`、`relativeLuminance`、`whiteContrastRatio(relativeLuminance:)`、`resolveChannelCorrect`、`fluidBackdropToneColor`、`fullscreenBottomBandToneColor`、`bisectRoot`。
- `Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift`：point B 状态从标量 `artworkAverageLuminance`/`artworkBottomRowLuminance` 改成 `BackdropLegibilityBand.RGBColor`；`bottomBandLegibilityCorrection` 改走 `resolveChannelCorrect`。
- `Tests/MusicMiniPlayerTests/BackdropLegibilityBandTests.swift`：新增 6 个夹具构造器（纯色、垂直/水平对半、下四分之一、棋盘格）+ 1 个综合暴力扫描测试（18 个测试，原 17 个）。

### 验证结果（暴力扫描复核后）

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BackdropLegibilityBandTests` → 18/18 通过。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ArtworkContrastFeelTests` → 21/21 通过（无回归）。
- `swift build` → 编译通过。
- 手感/视觉终验提醒同前：本次改动进一步改变了彩色封面下的实际压暗/提亮量，创始人仍需亲自用几张高饱和度真实专辑封面（不只是灰阶测试图）在全屏专辑页与歌词页过一遍。
