# nanoPod 动效现状地图（2026-09-10）

工作树：`compassionate-goldstine-0612ff`。只读审计，未改任何源码。

## 1. 现状清单表

| 动作 | 文件:行 | 今日实现（API / 参数） | 是否已有对照臂 | 备注 |
|---|---|---|---|---|
| 贴边隐藏 hideToEdge | `Sources/MusicMiniPlayerCore/UI/SnappablePanel.swift:354-375` | `NSPanel.setFrameOrigin` 驱动真实窗口 frame；`Spring(duration: 0.5, bounce: 0.15)`（WWDC23 手势吸附推荐值），`CADisplayLink` 60-120Hz 解析解逐帧求值（`SnappablePanel.swift:458,466-469,514-535`） | 无 | 释放速度清零后再贴边，避免过冲；动画期间 `hasShadow=false` + `disableScreenUpdatesUntilFlush()`（性能优化，非视觉设计） |
| 探出 peek（hover） | `SnappablePanel.swift:398-434` | 同一弹簧引擎，`Spring(duration: 0.3, bounce: 0.0)`（临界阻尼，无回弹），`peekAmount=30pt`；`NSEvent` 原生 mouse-moved 经 `sendEvent` 拦截判定（`handleMouseMoved` `SnappablePanel.swift:403-420`），非 `NSTrackingArea` | 无 | 触发条件 `frame.contains(NSEvent.mouseLocation)`；退出时 `hideBackToEdge()` 回落，同一 0.3/0.0 弹簧 |
| 点击恢复 restoreFromEdge | `SnappablePanel.swift:377-396` | 同 `Spring(duration:0.5, bounce:0.15)`，目标为角落安全位（`cornerMargin=16`） | 无 | 由 `handleMouseDown` 触发（`SnappablePanel.swift:158-160`） |
| 三页切换（迷你/专辑/歌单，实为 `PlayerPage` 枚举驱动） | `Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift:86,93,99,109` | `.animation(reduceMotion ? .linear(0.1) : .spring(response:0.25, dampingFraction:0.9), value: musicController.currentPage)`；`@Namespace private var animation`（`MiniPlayerView.swift:16`），`matchedGeometryEffect(id:"trackTitle"/"artistName"/"album-placeholder", in: animation)` 跨页共享同一 ID 实现封面/标题跟手位移 | 无（Reduce Motion 算退化分支，非并排对照臂） | Pages 全部常驻挂载（stacked，非条件渲染），符合已验证坑「条件渲染销毁 ScrollView」的教训 |
| 按钮 hover | `Sources/MusicMiniPlayerCore/UI/HoverableButtons.swift:148-153`（`HoverableActionButton`）、`:269-274`（`TranslationButtonView`） | 原生 SwiftUI `.onHover`，`isHovering` 状态位驱动外层 `.animation`（各按钮自带，无统一弹簧值） | 无 | 无 `NSTrackingArea` 手写实现，全走 SwiftUI |
| 按压缩放 | `Sources/MusicMiniPlayerCore/UI/Components/SharedControls.swift:902-909`（Play/Pause `.interpolatingSpring(mass:0.75, stiffness:560, damping:22)` 缩至 0.86）、`:1227-1235`（Skip `.interpolatingSpring(mass:1.0, stiffness:400, damping:28)` 缩至 0.90）、`:1580-1588`（另一按钮 `.spring(response:0.1, dampingFraction:0.7)` 缩至 0.93） | 无；仅 `reduceMotion` 时整体关闭（`nil`，非渐进退化） | 三处按钮各自不同弹簧参数，未统一 token 化 |
| 进度条 hover | `SharedControls.swift`（`ScrollingText`/进度条组件未见独立 hover 放大，进度条交互在 `Components/SharedControls.swift` 内以 `.animation(reduceMotion ? nil : .smooth(duration:0.18), value:isPlaying)` 等驱动播放态图标，`:887`） | — | 无 | 未找到进度条本身的 hover 专属动效代码块，可能仅靠系统 slider 默认反馈 |
| Shuffle/Repeat | `Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift:460-462` + `Components/PlaylistControlButton.swift` | `withAnimation(.spring(response:0.12, dampingFraction:0.9)) { repeatFlow = 1 }` 触发后 `.spring(response:0.35, dampingFraction:0.55)` 回落到 0（"flow" 双段弹簧，模拟按下-回弹两段式） | 无 | `PlaylistControlButton.swift`（34 行）只是共享 capsule chrome，具体图标内容由调用方传入 `@ViewBuilder` |
| 音量 | 未在读取范围内单独定位到专属文件；`SharedControls.swift` 1621 行内混有音量控件，未见独立弹簧参数（未逐行核实，超出本次预算） | — | 无 | 需要后续单独 grep `volume` 确认 |
| 收藏 | `HoverableButtons.swift:225-277`（`TranslationButtonView` 命名疑似复用组件做收藏/翻译双用途，`toggleBounce` 状态） | `.spring(response:0.12, dampingFraction:0.9)` 触发 bounce=1，叠加 `scaleEffect(1 + toggleBounce*0.15)` | 无 | 命名与实际用途（翻译按钮 vs 收藏）需与调用点交叉确认，本次未追踪调用方 |
| 页签 Tab Bar（歌单内） | `HoverableButtons.swift:295-350`（`PlaylistTabBarIntegrated`） | 内含 `cornerRadius(_:corners:)` 自定义 `RoundedCorner: Shape`（`:355-381`）做单角圆角；具体切换动画参数未在本次 grep 摘录中单独确认 | 无 | — |
| 设置页 Tab 切换 | `Sources/MusicMiniPlayerApp/SettingsView.swift:34` | 原生 `TabView(selection: $state.selectedTab)`，全文件未 grep 到任何 `.transition(`/`.animation(`/`spring(` | 无 | 完全依赖 AppKit/SwiftUI 系统默认切换动画，零自定义 |
| 设置页开关反馈 | `SettingsView.swift:99,120,236`（`Toggle`） | 原生 `Toggle` + `UserDefaultsBinding.bool`，无自定义动效包裹 | 无 | 同上，零自定义 |
| 菜单栏图标点击 | `Sources/MusicMiniPlayerApp/MusicMiniPlayerApp.swift:273-401` | `statusItem.button` 点击直接 `window.orderFront(nil)` / `floatingWindow?.orderOut(nil)`（`:389,393,292,401`），**未见 `.animator()`、`alphaValue` 淡入淡出或任何窗口出现动画包裹** | 无 | 窗口出现/消失是硬切，无 fade/scale |
| 窗口出现/消失 | 同上 `MusicMiniPlayerApp.swift:389-401,700,714` | 纯 `orderFront(nil)` / `orderOut(nil)`，`sender.orderOut(nil)` 两处（`:700,714`）用于面板自身关闭按钮 | 无 | 与 SnappablePanel 的弹簧引擎完全不共享——面板拖拽/贴边有物理动效，但整窗显隐是瞬切，体验不一致 |
| 封面切歌 crossfade | `MiniPlayerView.swift:78,133,142,150` + `Services/MusicController+Artwork.swift:933,1113` | SwiftUI `.transition(.opacity)`（四处），底层由 `MusicController+Artwork.swift` 的"pointer-keyed background crossfade"驱动图像替换时机（"mid-song 整页刷新"注释），具体淡入淡出时长未在 `.transition(.opacity)` 处显式声明（走默认 `withAnimation` 外层包裹时长） | 无 | 艺术图层本身还叠加 `matchedGeometryEffect`（见页面切换行），crossfade 和跨页 morph 是两套并存机制 |
| 音量（2026-09-10 补充核实） | `Sources/MusicMiniPlayerCore/Services/MusicController+Playback.swift:810-822`（`setVolume(_:)`） | 仅后端：`app.setValue(clamped, forKey:"soundVolume")` 写 Music.app；`grep -rn -i "volume" Sources/MusicMiniPlayerCore/UI Sources/MusicMiniPlayerApp` 零命中——**不存在任何音量 UI 视图**（无滑杆、无 hover-reveal），自然也没有 `.animation`/`.spring` | 无 | 之前"未逐行核实"的口径已补齐：不是遗漏代码，是这个动效在 UI 层根本不存在，需从零设计再谈参数 |
| 收藏（2026-09-10 补充核实） | 无对应 UI 视图；后端 `Sources/MusicMiniPlayerCore/Services/MusicController+Playback.swift:874-887`（`toggleStar()`，读写 Music.app `loved` 字段） | `grep -rn "toggleStar" Sources/` 只命中定义本身（`:874`），无任何调用点；`grep -rn -i "heart|star" Sources/MusicMiniPlayerCore/UI Sources/MusicMiniPlayerApp` 零命中——收藏按钮在 UI 层未接线 | 无 | `HoverableButtons.swift:224`（`// MARK: - TranslationButtonView` 及其上方注释「翻译按钮 - 显示/隐藏歌词翻译（直接toggle，无二级菜单）」）证实该组件就是翻译开关，不服务收藏；命名疑点已解除，不是收藏按钮 |
| 页签 Tab Bar（2026-09-10 补充核实） | `HoverableButtons.swift:295-338`（`PlaylistTabBarIntegrated`） | 选中胶囊：`.animation(.bouncy(duration: 0.35), value: selectedTab)`（`:307`）；`grep -n "PlaylistTabBarIntegrated" Sources/ Tests/` 只命中同文件内的定义（`:3,291,295`），**仓库内无任何调用点**，是未接线的死代码 | 无 | 对比同文件内 `HoverableActionButton`/`TranslationButtonView` 均有 `@Environment(\.accessibilityReduceMotion)`（`:136,230`），`PlaylistTabBarIntegrated` 结构体内全文 0 处 reduceMotion 读取 |

## 2. 玻璃臂现状（PanelBackdrop）

`Sources/MusicMiniPlayerCore/UI/Background/PanelBackdrop.swift`（116 行）。

结构：
```
PanelBackdrop(artwork, role: .base | .pageOverlay)
  ├─ style == .fluid  → FluidGradientBackground(artwork)              [默认，全平台]
  └─ style == .glass  → macOS 26+: role==.base → GlassBackdropView → NativeGlassSurface (NSGlassEffectView, cornerRadius=16, tintColor=主色调×0.35 alpha)
                                    role==.pageOverlay → Color.clear   [不重复铺材质]
                         macOS <26 → 回落 FluidGradientBackground
```

- 切换方式：`nanopod://debug/backdrop/<fluid|glass>` → `MusicMiniPlayerApp.swift:151-155` 写 `UserDefaults` key `panelBackdropStyle`；未知值 `PanelBackdropStyle.resolve` 钳回 `.fluid`（`PanelBackdrop.swift:24-27`，`PanelBackdropStyleTests` 已钉死此回落）。
- 玻璃叠玻璃风险：文件顶部注释已明确设计意图——`role: .pageOverlay` 在 glass 臂下渲染 `Color.clear`，就是为了不在 base glass 之上再叠一层材质（`PanelBackdrop.swift:31-34,58-64` 注释「page overlays (playlist) render nothing in the glass arm so the base glass shows through instead of stacking a second material on top of it」）。**本次审计未在 `MiniPlayerView.swift`/`PlaylistView.swift` 中逐一确认所有子视图是否严格只用 `.pageOverlay` 角色**——若某处仍直接用了 `VisualEffectView`/`.background(.ultraThinMaterial)` 等独立材质而不经过 `PanelBackdrop`，会绕开这道防线形成玻璃叠玻璃，需要专项 grep `ultraThinMaterial|regularMaterial|VisualEffectView` 交叉核实（未纳入本次预算）。

## 3. 对照臂模板（NativeLyricsFeelParity）

`Sources/MusicMiniPlayerCore/UI/NativeLyricsFeelParity.swift`（207 行）机制：

1. **枚举频道**：每个动效维度是一个独立 enum（`AppearWindowMode`、`BlurMode`、`SweepPathMode`），每个 enum 恰好两档——今日实现 default 档 + 对照档（v28 旧版 或 layer 备选路径），`resolve(from:)` 对未知/nil 值统一钳回 default，绝不因拼写错误跑到非预期分支（`:23-26,33-36,45-50`）。
2. **持久化**：三个独立 `UserDefaults` key（`nanoPodFeelAppearWindow`/`nanoPodFeelBlur`/`nanoPodFeelSweep`），运行时读取用 `AppStorage` 同款字符串裸值模式（与 `PanelBackdropStyle` 一致）。
3. **路由**：URL scheme `nanopod://debug/feel/<channel>/<arm>`（`reset` 清空三键）由 `MusicMiniPlayerApp.swift:172-186` 解析路径 `feel/<channel>/<arm>` 后调用 `NativeLyricsFeelParity.apply(channel:value:)`（`NativeLyricsFeelParity.swift:121-147`）。
4. **测试期覆盖**：`#if DEBUG` 下提供 `testingAppear/testingBlur/testingSweep` 静态变量 + `resetTestingOverrides()`，供 `NativeLyricsFeelParityTests.swift` 直接注入，不经 UserDefaults 往返；`isRunningTests`（检测 `XCTestConfigurationFilePath`）保证 XCTest 跑批时强制落到已知档位，不被开发机残留 UserDefaults 污染（`:65-97`）。
5. **量化**：`NativeLyricsSpringSampler.sample(from:to:times:spring:monotonic:)`（`:177-206`）用与真实渲染同一颗 `NativeLyricsVisualMotionState.advanceScalarForSampling` 逐帧步进（60Hz 定步长），产出两臂在同一组采样时间点上的数值序列——即"表格化对照"，而非重新写一条独立贝塞尔近似（避免"测试值"和"渲染值"来自两套公式而失真）。测试文件 `Tests/MusicMiniPlayerTests/NativeLyricsFeelParityTests.swift`（148 行）即是消费这张表做断言的地方。

**新增一个动效频道需要碰的文件**：
- `NativeLyricsFeelParity.swift`：加一个 `XxxMode` enum + defaults key + `apply()` 分支
- `MusicMiniPlayerApp.swift` 的 `handleAppURL` `case "debug"` 分支：一般不用改，因为已经是通用 `parts[1]=channel, parts[2]=value` 转发，新频道自动可路由
- 渲染代码内读取该 enum 的地方（例如 `LyricsLayerRendererView.swift` 里 `reduceMotion`/`forceSnapActive` 那种调用点）——需要新加一处 `switch NativeLyricsFeelParity.xxxMode`
- 对应 `Tests/MusicMiniPlayerTests/NativeLyricsFeelParityTests.swift` 或同类专属测试文件新增用例，复用 `NativeLyricsSpringSampler.sample`

## 4. Reduce Motion 现状

**已大范围接入**，并非空白（与任务描述"or say none"相反，实测覆盖面很广）：

- `MiniPlayerView.swift`：`@Environment(\.accessibilityReduceMotion)`（`:8`），几乎每个 `.spring(...)` 处都写成 `reduceMotion ? .linear(duration:0.1) : .spring(...)` 三元式退化（`:86,93,99,100,109,110,159,160,173,174,189,215,261,349,380,415,416`），以及 `guard !reduceMotion else { return }` 直接短路弹跳触发（`:459`）。
- `AudioOutputSwitcherView.swift`：同款三元式退化 + `guard !reduceMotion else { return }`（`:54,166,218,222,232,242,263,270,433`）。
- `HoverableButtons.swift`：`:136,149,230,248,270,275`。
- `Components/ScrollingText.swift`：`:16,20`，`reduceMotion` 时直接不做跑马灯滚动。
- `LyricsView.swift`：`:437,509,962,1552,1562,2382`。
- `Components/SharedControls.swift`：大量出现，`:77,102,149,214,290,299,314,320,322,338,825,830,850,864,887,892,894,902,906,908,928,938,941,1029,1227,1231,1234,1254,1284,1299,1333,1580,1584,1587,1600,1616`——按钮按压缩放、播放态图标切换、音量/进度条相关动画均已接 reduceMotion。
- `LyricsLayerRendererView.swift`：`reduceMotion: Bool` 作为参数传入原生渲染层（`:32,78,141`），`:217` `if reduceMotion { return .directSnap(.reducedMotion) }`——原生歌词渲染管线也接入了。

**缺口**：`SnappablePanel.swift`（贴边/探出/恢复三个动作）**未见任何 `accessibilityReduceMotion` 读取**——AppKit `NSPanel` 层不在 SwiftUI Environment 树内，理论上需要读取 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` 才能生效，本次未在该文件找到任何相关字符串。`PanelBackdrop.swift` / `FluidGradientBackground.swift` / `SettingsView.swift`（TabView/Toggle 本身零自定义动效，reduce motion 与否无差异，非缺口）同样未见。

## 5. 目标动效词汇（来自 liqoria 双规格）

综合 `research/references/liqoria-demo-animation-spec.md`（YouTube 录屏分析）与 `research/references/liqoria-liquid-glass-spec.md`（自录高帧率复核）：

- **三条解耦时钟**（liquid-glass-spec.md:112-118,356）：
  1. **几何 clock**：形状/宽高比收敛到位，实测 ~125–150ms（f955→f958-962，20.055→20.18-20.2s）。
  2. **内容 clock**：文字/封面内容更新，**滞后几何 20-80ms**（缩略图占位符 20ms 先于几何变化淡入做"预埋"，真实图案再等约 147ms 后替换占位符）。
  3. **材质 settle clock**：半透明度/材质收敛最慢，~270–350ms，明显晚于外轮廓停止变化后仍在继续变淡变透。
  三者互不等待、各自独立跑表，不是一条统一时间轴上的顺序阶段。
- **目的地元素预埋（destination-element pre-seed）**：resize 开始前 ~20ms，未来形态的占位图标已经在目标位置/尺寸淡入（liquid-glass-spec.md:33,102,280,342）——即先埋点位再动几何，而不是几何动完才生成目标内容。
- **连续圆角（continuous corner radius）**：整个中间过渡形态圆角始终保持连续弧形，不出现任何直角矩形中间帧（liquid-glass-spec.md:105,236；demo-spec.md:185-206"genuine continuous-corner treatment maintained through the resize"）。
- **无回弹（critically damped，non-bouncy）**：demo-spec.md:69-73 明确"能排除欠阻尼/带回弹的弹簧，形状不会长过头再弹回"，但作者承认无法在"临界阻尼"与"另外两种阻尼曲线"之间精确区分——即目标观感是"不过冲"，但并非确认为某个精确的 `Spring(duration:, bounce:)` 数值组合，需要自行调参逼近。
- **Hover 高亮胶囊**：demo-spec.md:83-86,278 与 liquid-glass-spec.md:278 两份规格都独立观察到同一机制——transport 按钮/菜单项 hover 时出现柔和圆角矩形高亮"capsule"，覆盖时长跟随 hover 持续，进入时约 200-300ms 渐显。
- **无折射/透镜畸变**（liquid-glass-spec.md 未直接引用行号但 demo-spec.md:185-186 提及）：圆角边缘对比未见折射失真，材质效果是"看起来"的玻璃观感（模糊、半透明、圆角），不是几何透镜形变。
- **Crossfade 独立于 morph**：track 切换时标题/艺人文字先淡出淡入（~100-200ms），封面图另走约 500ms 的独立 crossfade/slide 收尾，与卡片↔胶囊形态 morph 是两条不同的动画（demo-spec.md:160-172）。

## 6. 差距清单

| 现状动作 | 距目标词汇的差距 |
|---|---|
| 三页切换（matchedGeometryEffect + spring 0.25/0.9） | 今日是单一弹簧同时驱动几何和内容，未拆分三条独立时钟；无"目标位置预埋"（新页面内容是随几何一起显现，不是提前 20ms 淡入占位符） |
| 贴边隐藏/探出/恢复（Spring 0.5/0.15、0.3/0.0） | 只动窗口 frame（几何一条通道），没有材质通道（`hasShadow` 只是开关不是渐变）；0.15 bounce 有轻微回弹，与目标"无回弹"不完全一致，需验证是否可感知 |
| 封面切歌 crossfade（`.transition(.opacity)` ×4 处 + pointer-keyed background crossfade） | 已经是独立通道（不跟几何绑定），方向对；但目标规格里内容 resolve 滞后几何 20-80ms 是"占位符→真实图"两级淡入，现状只见一次 opacity transition，没有"预埋占位符"这一级 |
| 玻璃臂 PanelBackdrop（NSGlassEffectView cornerRadius=16） | 圆角是固定值非"continuous corner"跟随形状变化；backdrop 切换本身（fluid↔glass）是瞬时 UserDefaults 写入即重绘，没有过渡动画 |
| 按钮 hover（`.onHover` + 各自 `.animation`） | 未见统一的"hover 高亮胶囊"实现模式（demo-spec 重复观察到的关键交互），现状各按钮独立处理 scale/opacity，没有胶囊背景高亮层 |
| 按压缩放（三套不同 interpolatingSpring 参数） | 参数未统一，无法判断哪一套更接近目标"无回弹"；且都是纯几何缩放，没有材质通道联动 |
| Shuffle/Repeat 双段弹簧（0.12/0.9 触发 + 0.35/0.55 回落） | 0.55 dampingFraction 明显欠阻尼会回弹，和目标"无过冲"刚好相反，是最值得先对照测量的一项 |
| 设置页 Tab 切换（原生 TabView，零自定义） | 完全没有自定义动效，谈不上贴近三时钟模型；如果要做，需要新增一整套（今日是空白，不是"有差距"而是"未实现"） |
| 菜单栏点击 / 窗口出现消失（`orderFront`/`orderOut` 硬切） | 同上，零动效；与 SnappablePanel 的物理引擎完全脱节，是本次清单里最大的单点缺口——用户从菜单栏唤出面板全程无过渡 |
| 对照臂覆盖面 | 目前只有歌词渲染（`NativeLyricsFeelParity`）一个域接了 A/B 模板；SnappablePanel/MiniPlayerView/PanelBackdrop/HoverableButtons/SharedControls 的动效改动若要走"新旧对照"流程，需要为每个域各自新增一份同构的 channel/arm/defaults/URL 路由/测试表，工程量集中在第 3 节列出的四类文件 |

---
（本文件仅做只读盘点，未修改任何源码；「音量」「Shuffle/Repeat 调用点归属」「玻璃叠玻璃逐处核实」三项因预算限制未做到逐行确认，已在对应行标注为需后续专项核实。）
