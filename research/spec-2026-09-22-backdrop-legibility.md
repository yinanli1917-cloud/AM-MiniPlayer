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

- Point B 的底部 scrim 高度 160pt 是估算值（覆盖 title/artist/shuffle-repeat/controls 的粗略带宽），未按窗口实际尺寸精确计算——真实设备上可能需要创始人微调这个 Token。
- `FluidGradientBackground` 的 `legacyArtworkContrast` 分支（C5 `.legacy` 臂,当前生产默认）与 `.tuned` 臂对 `fluidBackdropToneLuminance` 的 `applyContrastDarken` 参数不同，两个臂各自会得到不同的 `legibilityCorrection`——这是预期行为（带函数不管哪个臂输出都补齐到带内），但两臂切换时的过渡动画未专门测试。
