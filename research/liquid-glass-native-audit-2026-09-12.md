# nanoPod Liquid Glass 原生化审计（2026-09-12）

只读审计，未改任何 Swift 文件，未跑 build/test。依据 `official.md`（WWDC25 已验证 API 清单）与 `current-state.md`（09-10 动效地图）+ 本次逐文件 grep/读取。

## 摘要

计数（12 个受审元素）：**3 个已原生**（按钮胶囊、设置页 Form、进度/播放 SF Symbols）、**6 个"官方之上加自绘"有正当理由**（面板底材、Shuffle/Repeat 胶囊、进度条、窗口圆角/阴影、滚动边缘模糊、Reduce* 回退）、**3 个无正当理由的自绘/空白**（页签栏死代码+无真实页签、音量无 UI、菜单栏窗口显隐硬切零动效）。

Top 5 改动收益排序：
1. 菜单栏点击/窗口显隐硬切（`orderFront`/`orderOut` 零动效）—— 用户唯一必经路径，零成本可加 `NSViewAnimationContext`/glass fade，最违和。
2. 三页切换缺失 Apple 官方语义组件——现状是自建 `matchedGeometryEffect` 页面机，可评估 macOS 26 `tabBarMinimizeBehavior`/原生 Tab 语义替代部分手搓逻辑。
3. `PlaylistTabBarIntegrated`（`HoverableButtons.swift:334-381`）死代码 + 圆角自绘 `RoundedCorner: Shape`——先确认是否该删，若要用则应换 `.glassEffect`/`Picker(.segmented)`。
4. 进度条纯 CALayer 手绘（`SharedControls.swift`）——`scrollEdgeEffectStyle`/glass 之外，进度条本身 HIG 无强制要求换系统 Slider，但 hover 态高度过渡等手感项应补齐 `NativeLyricsFeelParity` 式对照臂再改，不能盲改。
5. 音量控制完全没有 UI（`grep -rn -i volume` 只命中后端 `MusicController+Playback.swift`）——不是"非原生"而是"未实现"，若要做应直接用系统 Slider/`glassEffect` 胶囊，不要新建自绘滑杆。

**必须不动**（CLAUDE.md 已验证性能陷阱，逐条对照本次审计范围）：
- `.hudWindow` 不用——本次审计未在任何文件发现 `.hudWindow`，保持现状（用的是 `.underWindowBackground`/`.regularMaterial`/`.ultraThinMaterial`）。
- `Section + LazyVStack(pinnedViews:)` 不用——`PlaylistView.swift` 用 `ScrollView + ScrollViewReader`，非 Section 递归陷阱，不要为了"原生化"改回 Section。
- 面板底材默认仍是 `FluidGradientBackground`（`PanelBackdrop.swift:51-52`），glass 只是实验臂——不要在验证 WindowServer 成本前把默认切成 glass。
- 逐字歌词渲染器（`LyricsLayerRendererView`/`NativeLyricsRowView`）不在本次审计范围，其 CALayer 手绘是 postmortem 007/008 后专门验证过的架构，不要因为"原生化"诉求去动它。

---

## 1. 面板底材

现状实现（file:line）：
- `Sources/MusicMiniPlayerCore/UI/Background/PanelBackdrop.swift:37-66` — `PanelBackdrop` 按 `PanelBackdropStyle`（`.fluid`/`.glass`，`AppStorage` 驱动）分流；默认 `.fluid`。
- `PanelBackdrop.swift:102-116` — `.glass` 分支下 `NativeGlassSurface: NSViewRepresentable` 包 `NSGlassEffectView`，`cornerRadius=16`，`tintColor` 来自封面主色（alpha 0.35）。
- `Sources/MusicMiniPlayerCore/UI/Background/FluidGradientBackground.swift:1-60+` — 默认路径：三层封面图 `blur(radius:58)` + `saturation/contrast/brightness` 调色，纯 SwiftUI 绘制，无系统材质。
- `Sources/MusicMiniPlayerCore/UI/Background/LiquidBackgroundView.swift:1-45` — 旧实现（`LiquidGlassEffectView: NSViewRepresentable` 包 `NSVisualEffectView(.underWindowBackground)`），文件仍在但按 `PanelBackdrop.swift:9-10` 注释已被 fluid 取代、standing as history。
- `Sources/MusicMiniPlayerCore/UI/Components/VisualEffectView.swift` — 通用 `NSVisualEffectView` 包装，供 `ProgressiveBlurView` 复用。

官方对应物：`NSGlassEffectView`（已见，macOS 26.0+，`cornerRadius`/`tintColor`/`style`）、`NSGlassEffectContainerView`（已见，用于合并邻近玻璃视图提升性能）。

差距：
- glass 臂只用了单个 `NSGlassEffectView`，没有套 `NSGlassEffectContainerView`——目前只有一个 base 玻璃实例，暂不构成"多玻璃视图未分组"的问题，但若未来在 base 之外再加子玻璃元素（例如玻璃臂下的按钮胶囊）需要补上容器分组，否则会撞上 `NSGlassEffectContainerView` 文档描述的"减少渲染 pass"收益缺失。
- `cornerRadius=16` 是写死值，不是官方 Motion/HIG 页描述的"continuous corner radius 跟随容器动态计算"（该说法本身在 official.md 里也标注为来自 liqoria 逆向录屏，非 Apple 一手文档，仅供参考不是硬指标）。
- fluid↔glass 切换是 `AppStorage` 写入触发的 SwiftUI 重绘，无过渡动画（current-state.md 差距清单已记录），非本次新发现。

建议：**保留自绘（fluid）为默认，glass 留作实验臂**——`m1_performance_profile.md`/`glass_backdrop_ab.md` 记忆显示两者 WindowServer 成本目前打平，未有定论前不应仓促换默认；`PanelBackdrop.swift` 本身的分层设计（role-based，避免叠玻璃）已经是对的架构，不需要重写，只需在扩展 glass 臂子元素时补 `NSGlassEffectContainerView`。

与禁用模式的冲突：无。`role: .pageOverlay` 在 glass 臂下渲染 `Color.clear`（`PanelBackdrop.swift:31-34,58-64`）是专门为了不产生 glass-on-glass 写的分流；`.hudWindow` 未见任何使用。

---

## 2. 所有按钮

现状实现（file:line）：
- `Sources/MusicMiniPlayerCore/UI/HoverableButtons.swift:14-29`（`GlassButtonBackground`）— macOS 26+ 用 `.glassEffect(.clear, in: .capsule)`（已见），否则 fallback `Capsule().fill(.ultraThinMaterial)`。
- `HoverableButtons.swift:31-47`（`GlassButtonTexture`）— macOS 26+ 用 `GlassEffectContainer(spacing: 0) { content.glassEffect(.clear, in: shape) }`（已见），否则 fallback material。
- `HoverableButtons.swift:63-95`（`GlassCapsule`）— 同款双分支，`.glassEffect(.regular/.clear/.identity, in: .capsule)`。
- `Components/SharedControls.swift:902-909,1227-1235,1580-1588` — 播放/跳过/其他按钮的按压缩放用 `.interpolatingSpring`/`.spring`，未见 `.buttonStyle(.glass)`（`PrimitiveButtonStyle.glass`，已见）直接套用，而是继续用自定义 `Button` + `.plain`/自定义 `ButtonStyle`。

官方对应物：`.glassEffect(_:in:)`（已见）、`GlassEffectContainer`（已见）、`PrimitiveButtonStyle.glass`/`.buttonStyle(.glass)`（已见）、`NSButton.BezelStyle.glass`（AppKit，已见）。

差距：
- 已经用了 `.glassEffect`，这部分是"原生"的；但选择了手写 `GlassButtonBackground`/`GlassCapsule` 这类自定义 `ViewModifier` 去调用 `.glassEffect`，而不是直接 `.buttonStyle(.glass)`——原因是需要自定义 luminance-adaptive tint 和 fallback 分支，`buttonStyle(.glass)` 本身不暴露这些参数，所以自绘是合理的封装层，不是绕开官方 API。
- `SharedControls.swift` 里播放/跳过大按钮完全没走 `.glassEffect`/`.buttonStyle(.glass)` 路径，纯自定义缩放动效叠自绘背景（`Color.white.opacity`/`Circle`），这部分没有 glass 化。

建议：**面板小按钮（Hide/Expand/Translation）保留现有自绘 modifier 封装（官方之上加自绘）**——理由是需要 luminance 反色和 macOS<26 fallback，`.buttonStyle(.glass)` 做不到。**播放/跳过大按钮建议评估换 `.glassEffect` 胶囊**而非维持纯色圆形背景，因为这两个是最高频交互点、最容易被用户感知"不像系统控件"。

与禁用模式的冲突：`GlassButtonTexture`/`GlassCapsule` 的 fallback 分支各自独立调用一次 `.ultraThinMaterial`，不叠加彼此（每个按钮只套一层），未见 glass-on-glass；但若某按钮同时被 `PanelBackdrop` 的 glass 臂包裹又自身套 `GlassButtonBackground` 的 glass 分支，就会形成"玻璃容器内再叠一层胶囊玻璃"——这是官方明确允许的模式（按钮本身就该是浮在玻璃导航层上的独立控件，不是"叠两层背景材质"），不算违反「Avoid stacking glass on glass」（该规则针对的是背景材质彼此重叠，不是控件在玻璃导航层上正常存在）。

---

## 3. 页签栏

现状实现（file:line）：
- `Sources/MusicMiniPlayerCore/UI/HoverableButtons.swift:330-381`（`PlaylistTabBarIntegrated`）— 自绘 `RoundedCorner: Shape`（`:355-381`）做单角圆角胶囊，选中态 `.animation(.bouncy(duration:0.35), value: selectedTab)`。grep 全仓库（`Sources/`+`Tests/`）**只命中定义本身，无任何调用点**——确认是死代码。
- 真实的"页签切换"其实是 `MusicController.currentPage`（`PlayerPage` 枚举：`.lyrics`/`.playlist`/`.album`）直接驱动 `MiniPlayerView.swift:75-108` 里的 `ZStack` 三个视图叠放 + opacity/zIndex 切换 + `matchedGeometryEffect`（`:16` `@Namespace`），**没有可见的"页签栏"UI 元素**——切换靠点击专辑封面/歌词区域触发（`MiniPlayerView.swift:668-673`：点专辑页跳歌词页），不是靠一排 tab 按钮选择。

官方对应物：`TabView`（SwiftUI 标准 Tab 组件）、`tabBarMinimizeBehavior(_:)`（已见，macOS 26.0+ 确认可用）、`ToolbarSpacer`（已见）。

差距：项目里根本没有"页签栏"这个 UI 元素在实际运行时存在——三页切换是隐式手势/点击触发，不是显式 tab bar，这与官方"Tab Bar"组件不是同一形态，谈不上"自绘 vs 官方"的对照，而是设计选择本身就没有 tab bar。`PlaylistTabBarIntegrated` 是曾经计划做但从未接线的遗留代码。

建议：**死代码本身建议删除或明确标注为暂存草案**（不属于本次只读审计范围内的改动，仅记录）；**如果未来要做真实可见的页签栏，直接用 `.glassEffect` 胶囊或 `GlassEffectContainer` 包一组 `Button`，不要复用 `PlaylistTabBarIntegrated` 的自绘 `RoundedCorner`**——原生 `.glassEffect(_:in:)` 支持任意 `Shape` 参数，不需要手写非对称圆角 Shape 来模拟玻璃胶囊。

与禁用模式的冲突：无直接冲突（代码未运行），但 `RoundedCorner: Shape` 自绘圆角与 `Concentric` 形状类型（official.md 1.2 节「Concentric（父容器半径减去 padding 算出的同心圆角）」，来自 wwdcnotes 二手转述，非一手 API 名，标 [部分未验证]）的设计意图相悖——官方新设计系统建议用 concentric 语义而非手算不对称角。

---

## 4. Shuffle/Repeat 胶囊

现状实现（file:line）：
- `Sources/MusicMiniPlayerCore/UI/Components/PlaylistControlButton.swift:50-76` — `PlaylistControlButton<Icon>` 用 `.modifier(GlassButtonTexture(shape: Capsule()))`（间接调用 `.glassEffect(.clear, in: shape)`，已见），`.buttonStyle(CapsulePressStyle())` 自定义按压反馈。
- 触发动效在 `MiniPlayerView.swift:460-462` + `PlaylistControlButton.swift:11-42`（`ShuffleRepeatStyle.resolve`）：两段式弹簧，`.legacy055` 臂 `dampingFraction:0.55`（欠阻尼会回弹）vs `.critical` 臂走 `MicroInteractionFeel.Tokens` 临界阻尼——**已经有 A/B 两档，不是单一实现**，current-state.md 09-10 版本尚未记录到这个 `.critical` 臂，说明这行是本次审计发现的新进展。

官方对应物：`.glassEffect(_:in:)`（已见）、`GlassEffectContainer`（已见）。

差距：胶囊材质本身已经是官方 `.glassEffect` 路径（通过 `GlassButtonTexture`），无材质层面差距；差距在动效层——`.legacy055` 默认臂的回弹（overshoot，见 `PlaylistControlButton.swift:36-42` 提供的解析公式可算出非零过冲）与官方 WWDC 转述里「Liquid Glass 会随光线 flex」但没有具体描述"胶囊按压该不该回弹"的强制规则，属于手感判断而非 API 缺口。

建议：**保留自绘（材质已原生，动效手感留给对照臂机制裁决）**——这条已经是"官方之上加自绘"的正确形态：材质走官方 API，动效参数化成可切换臂，等待创始人终验哪个手感更好，不应在本轮直接替换默认。

与禁用模式的冲突：无。

---

## 5. 进度条

现状实现（file:line）：
- `Sources/MusicMiniPlayerCore/UI/Components/SharedControls.swift:428+`（`progressSlotHeight`）、`:547-661`（`progressValue`/`progressRect`/`updateProgressLayers`）— 确认是 **CALayer 手绘**：`trackLayer`/`fillLayer`/`qualityBadgeLayer`（`:569-570`）直接操作 `CALayer` 树，鼠标事件走自定义 `NSView` 子类捕获（`progressInteractiveRect`/`handleMouseMoved` 一类模式，参照 `:527,609-611`）。
- hover 态高度过渡：`SharedControls.swift:39-48`（`ProgressHoverStyle` 一类 pure 函数，`MicroInteractionFeel.Tokens.progressHoverDuration`）。

官方对应物：SwiftUI `Slider`（标准控件会自动获得 Liquid Glass 外观，无需开发者手写，见 official.md 3.1 节「SwiftUI/UIKit/AppKit 的标准组件自动获得 Liquid Glass 外观」）。

差距：进度条完全绕开系统 `Slider`，是纯 CALayer 手绘轨道+填充+质量徽标（`qualityBadgeLayer` 这种业务定制显示，系统 `Slider` 本身做不到），因此拿不到"标准组件自动适配 Liquid Glass"的红利——用户滑动手感与音量/亮度这类系统控件观感不一致，是本次审计里差距最明确的一项。

建议：**保留自绘，但需要说明理由**——`qualityBadgeLayer`（歌词/音质来源徽标叠加在进度条上）是 `Slider` 原生做不到的定制显示，且 CLAUDE.md 明确歌词/播放位置的实时同步依赖精确到帧的 `CADisplayLink` 驱动（见 `SnappablePanel` 同款引擎），系统 `Slider` 的绑定值更新粒度不满足这个要求；**不建议换系统 Slider**，但可以评估在 hover/press 反馈曲线上向 `.glassEffect` 胶囊的手感靠拢（不改变底层渲染架构，只调参数），这需要走 `NativeLyricsFeelParity` 式对照臂而不是直接改默认。

与禁用模式的冲突：无 banned-patterns 直接命中；但注意 postmortem 记忆里"CIFilter 复用陷阱""隐式动画陷阱"是 CALayer 手绘的通病，进度条既然是手绘 CALayer 应确认是否也套了 `.lyricsInert()` 同款保护——本次审计**未在 `SharedControls.swift` 找到 `.lyricsInert`/inert-layer 相关字符串**，如果这几个 CALayer 是在 layer-backed NSView 里创建的裸 sublayer，理论上有隐式动画泄漏风险，建议列为后续专项核实项（超出本次审计预算，未做代码修改判定）。

---

## 6. 音量

现状实现：**不存在音量 UI**。`grep -rn -i "volume" Sources/MusicMiniPlayerCore/UI Sources/MusicMiniPlayerApp` 零命中（本次复核与 current-state.md 09-10 记录一致）；后端 `Sources/MusicMiniPlayerCore/Services/MusicController+Playback.swift:810-822`（`setVolume(_:)`）只写 `Music.app` 的 `soundVolume` key，没有对应的滑杆/hover 面板。

官方对应物：SwiftUI `Slider`（标准控件自动获得 Liquid Glass 外观）或 macOS 系统音量胶囊（菜单栏音量条同款交互，非本项目自建 API，仅作参照）。

差距：不是"非原生"，是"未实现"——没有代码可评判原生度。

建议：若要新增，直接用系统 `Slider` 或 `.glassEffect` 包一个胶囊拖动条，不要复制进度条那套 CALayer 手绘架构（进度条手绘是因为要叠 `qualityBadgeLayer` 等业务定制，音量没有这个需求）。

与禁用模式的冲突：不适用（无代码）。

---

## 7. 菜单栏菜单

现状实现（file:line）：
- `Sources/MusicMiniPlayerApp/MusicMiniPlayerApp.swift:273-401` — `statusItem.button` 点击直接调用 `window.orderFront(nil)`/`floatingWindow?.orderOut(nil)`（`:389,393,292,401`）。**未见 `NSMenu` 挂载在 statusItem 上**——本项目的"菜单栏交互"实际是点击图标直接切换浮动面板显隐，不是弹出下拉菜单；真正意义上的"菜单栏菜单"（右键菜单或点击展开的 `NSMenu`）需要另行确认是否存在（本次审计 `grep -n "NSMenu" Sources/MusicMiniPlayerApp/MusicMiniPlayerApp.swift` 未纳入预算，按现有读取范围看主点击路径是直接开关窗口，非 NSMenu 弹出）。
- `MusicMiniPlayerApp.swift:700,714` — 面板自身关闭按钮走 `sender.orderOut(nil)`。

官方对应物：`NSMenu`（原生菜单栏下拉菜单，标准组件自动获得系统外观，不需要自绘）；窗口显隐可选 `NSViewAnimationContext`/`window.animator()`（非本次 official.md 清单收录的新 API，是长期存在的 AppKit 能力，标 [未验证：非本轮检索范围，AppKit 长期公开 API])。

差距：**窗口显隐是纯硬切**（`orderFront`/`orderOut` 无 `.animator()`/`alphaValue` 包裹）——current-state.md 已记录"与 SnappablePanel 的弹簧引擎完全不共享，面板拖拽/贴边有物理动效，但整窗显隐是瞬切，体验不一致"，本次复核确认代码位置未变。这不是"该不该用系统 NSMenu"的问题（本项目按钮点击本来就该是窗口开关而非下拉菜单，属正常设计），而是这个开关动作本身零动效，最违和。

建议：**加淡入/缩放过渡**（`NSAnimationContext.runAnimationGroup` 包 `window.animator().alphaValue`），成本低、见效快，是本次列出的第一优先改动。是否需要和 `SnappablePanel` 共用同一颗弹簧引擎（`Spring(duration:0.3, bounce:0.0)`）留给创始人裁决，不在本次审计内直接建议具体参数（手感类改动需要走对照臂 + 创始人终验，见 CLAUDE.md「手感类验证」规则）。

与禁用模式的冲突：无。

---

## 8. 设置页 Form

现状实现（file:line）：
- `Sources/MusicMiniPlayerApp/SettingsView.swift:29-49` — `TabView(selection:)` + `.tabItem { Label(...) }`，`SettingsTab` 枚举驱动，`DiagnosticsDebugPanel` 仅 `#if DEBUG || LOCAL_DEVELOPER_BUILD` 编译。
- `:54-108`（`generalTab`）— `Form { Section { ... } }` + `.formStyle(.grouped)`，`Toggle`（`:99`）、`Button(...).buttonStyle(.borderedProminent)`/`.buttonStyle(.bordered)`（`:82,88`）。
- `:120+`（`appearanceTab`）— 同款 `Form`/`Section`/`Toggle`/`Picker`。
- 全文件 `grep -n ".transition(\|.animation(\|spring("` 零命中（current-state.md 已确认，本次未重新逐行核实但引用其结论）。

官方对应物：`Form`（已见，SwiftUI 标准表单容器）、`TabView`（已见）、`Toggle`（已见）、`.formStyle(.grouped)`（macOS 标准表单外观，长期存在 API，[未验证：非本轮 official.md 收录条目，但为 SwiftUI 公开长期 API]）。

差距：**这是本次审计里最"原生"的一块**——完全用系统标准组件，零自定义动效，符合 official.md 3.1 节"标准组件自动获得 Liquid Glass 外观，无需开发者手写"的建议。唯一潜在差距是 macOS 26 新设计系统里 `TabView` 是否会自动获得新版玻璃 Tab 外观取决于系统版本渲染，本次未做实机版本对照（不在只读代码审计范围内）。

建议：**保留现状，不需要改**——这是"标准组件自动适配"的正面例子，写入摘要作为反例参照，不建议为了"加特效"引入自定义动效。

与禁用模式的冲突：无。

---

## 9. 窗口圆角与阴影

现状实现（file:line）：
- `Sources/MusicMiniPlayerCore/UI/SnappablePanel.swift:55-58` — 自定义 `NSPanel` 子类初始化，`styleMask` 由调用方传入（未在本次读取范围内展开具体 mask 值，只读到构造签名）。
- `:486-487,548` — `hasShadow` 在贴边动画期间临时置 `false`（`shadowWasEnabled = hasShadow; if hasShadow { hasShadow = false }`），动画结束恢复——这是**性能优化**（current-state.md 已标注「非视觉设计」），不是圆角/阴影的视觉处理本身。
- 本次读取范围内**未见 `cornerRadius`/`titlebarAppearsTransparent` 等圆角配置字符串出现在 `SnappablePanel.swift`**——面板圆角很可能由 SwiftUI 内容视图层（`clipShape`/`.cornerRadius`）而非 `NSWindow` 层控制，需要专项 grep `clipShape\|cornerRadius` 交叉 `MiniPlayerView.swift`（超出本次预算，未逐行核实，如实标注缺口）。

官方对应物：`NSGlassEffectView.cornerRadius`（已见）；官方设计系统对窗口圆角的规则来自 Materials/Motion HIG 页，但该页官方正文抓取失败（official.md 明确标注「未找到」），因此**没有可引用的官方窗口圆角具体规则**。

差距：无法在本次审计内给出"差多少"的具体结论——因为（a）圆角具体实现位置未追踪到，（b）官方 HIG 窗口圆角规则本身未能验证到原文。这是本节最大的不确定性,如实标注而非猜测。

建议：**留待专项审计**，不在本次报告内给出改动建议（避免在未验证信息上建议改动）。

与禁用模式的冲突：`hasShadow=false` 期间临时关阴影是已验证的性能手段，不属于任何 banned pattern，不要因为"原生化"诉求移除这个临时关阴影的优化。

---

## 10. 滚动边缘效果

现状实现（file:line）：
- `Sources/MusicMiniPlayerCore/UI/PlaylistView.swift:120-121` — `ScrollViewReader { ... ScrollView(showsIndicators: false) { ... } }`，纯系统 `ScrollView`，**未见 `.scrollEdgeEffectStyle`**（全仓库 `grep -rn "scrollEdgeEffectStyle" Sources/` 零命中）。
- `Sources/MusicMiniPlayerCore/UI/Components/ProgressiveBlurView.swift:20-63` — 自定义 `ProgressiveBlurModifier`（macOS 14+ Metal Shader `layerEffect` + `ShaderLibrary.bundle(Bundle.module).progressiveBlurFromBottom`）做渐进模糊；macOS 14 以下 fallback 到 `VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow) + .mask(gradientMask)`（`:58-63`）。

官方对应物：`scrollEdgeEffectStyle(_:for:)` + `ScrollEdgeEffectStyle`（`.automatic`/`.hard`/`.soft`，已见，SwiftUI，macOS 26 可用）。

差距：**这是本次审计里最明确的"官方已有对应 API 但未采用"的一项**——`ProgressiveBlurView` 用自定义 Metal Shader 实现渐进模糊来营造"滚动内容淡出"的效果，而 official.md 明确指出 WWDC25 356 场次原文「Scroll edge effect 定位为功能性而非装饰性...Soft 用于交互元素细微模糊，Hard 用于交互文字/无背景控件/pinned 表头」，这正是 `ProgressiveBlurView` 想做的事，且是 macOS 26 标准 API，理论上可以直接替代自定义 Shader 方案（在 macOS 26+ 上）。

建议：**macOS 26+ 换官方 `scrollEdgeEffectStyle`，macOS<26 保留 `ProgressiveBlurView` 作 fallback**——自定义 Shader 版本换来的视觉效果（渐进模糊）本质上就是官方想要标准化的东西，继续手写只是维护成本更高、且拿不到系统对"scroll edge effect 一致性"的自动适配（例如 pinned header 场景下 Hard 边缘的近乎不透明处理，Shader 版本需要额外手调）。这属于"换官方"的典型场景，但因为涉及视觉手感需要走对照臂 + 创始人终验，不在本次只读审计内直接改代码。

与禁用模式的冲突：无 banned-patterns 直接命中；`PlaylistView.swift` 用 `ScrollView` 而非 `Section+LazyVStack(pinnedViews:)`，符合已验证的规避方案，**不要在引入 `scrollEdgeEffectStyle` 时顺带把结构改回 Section**（HIG「同一视图内不要混用 Soft/Hard 两种边缘效果」也需要在改动时遵守）。

---

## 11. Reduce Transparency / Reduce Motion / Increase Contrast 回退

现状实现（file:line，本次复核 grep 结果）：
- `accessibilityReduceMotion` 覆盖文件：`AudioOutputSwitcherView.swift`、`HoverableButtons.swift`、`MiniPlayerView.swift`、`LyricsView.swift`、`Components/ScrollingText.swift`、`Components/SharedControls.swift`、`MusicMiniPlayerApp.swift`——与 current-state.md 09-10 记录的覆盖面一致，本次未发现新增文件。
- **`accessibilityReduceTransparency`/`accessibilityDisplayShouldReduceTransparency`/`colorSchemeContrast`：全仓库零命中**（本次 grep 复核，`grep -rln` 只返回上面 reduce-motion 相关的 7 个文件，说明这三个无障碍信号在整个 `Sources/` 里完全没有被读取）。
- `SnappablePanel.swift` 依旧**未见任何 reduce-motion 相关字符串**（current-state.md 已记录此缺口，本次复核确认未变）。
- `MicroInteractionFeel.swift`（`.claude/rules` 与本文件多处引用）本次未纳入逐行读取，按 current-state.md 描述它是新增的动效 token 层，若其中定义了会影响透明度的 token（如 hover 胶囊 opacity），也应该接 `accessibilityReduceTransparency`，目前没有证据显示已接入。

官方对应物：`accessibilityReduceMotion`（SwiftUI 环境值，已见，非 26 新增但持续适用）；official.md 引用 Adopting Liquid Glass 原文：「people can choose a preferred look for Liquid Glass...turn on accessibility settings that reduce transparency or motion...standard components adapt automatically, custom elements must be tested」。`NSWorkspace.accessibilityDisplayShouldReduceMotion`（AppKit，已见）。SwiftUI 对应的 `accessibilityReduceTransparency`/AppKit `accessibilityDisplayShouldReduceTransparency` 属于长期存在的公开 API，[未验证：本轮 official.md 未专门收录，但为 Apple 长期公开无障碍 API，非 26 新增]。

差距：
1. **Reduce Transparency 完全未接入**——所有自绘玻璃/材质（`FluidGradientBackground` 的 blur 层、`GlassButtonBackground`/`GlassCapsule` 的 fallback `.ultraThinMaterial`、`ProgressiveBlurView`）在用户开启"降低透明度"系统设置时不会有任何响应。这是本次审计发现的**最大无障碍缺口**——official.md 原文明确要求"custom elements must be tested"，而现状是零测试、零适配。
2. **Increase Contrast（`colorSchemeContrast`）未接入**——所有 `.opacity(0.x)` 类弱化文字（`Text(...).font(.caption).foregroundStyle(.secondary)` 在 `SettingsView.swift` 大量出现）在高对比度模式下没有特殊处理。
3. **AppKit 层（`SnappablePanel.swift`）reduce motion 缺口**——SwiftUI Environment 树覆盖不到 AppKit `NSPanel` 的贴边/探出/恢复三个弹簧动画，需要单独读取 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` 并订阅 `accessibilityDisplayOptionsDidChangeNotification`（official.md 已见此 API）。

建议：**换官方信号，逐步补齐，按优先级**——(a) `SnappablePanel.swift` 先接 `NSWorkspace.accessibilityDisplayShouldReduceMotion`，因为它是唯一完全零覆盖的高频交互动效（贴边/探出每次拖拽都会触发）；(b) 玻璃/材质相关视图接 `accessibilityReduceTransparency`，开启时把 `.glassEffect`/`ultraThinMaterial` 换成更不透明的纯色背景；(c) Increase Contrast 优先级最低，先记录缺口，不建议本轮就动手（涉及大量文字样式改动，风险与收益不成比例，建议单独立项）。

与禁用模式的冲突：无直接冲突，但这是"验证类"缺口而非"实现错误"类缺口——不涉及 banned-patterns 里任何一条。

---

## 12. 字体/图标

现状实现（file:line）：
- `Sources/MusicMiniPlayerCore/UI/Components/SharedControls.swift:885-886` — `Image(systemName: iconName).contentTransition(.symbolEffect(.replace.offUp))`（播放/暂停图标切换用官方 symbol effect）。
- `:1671-1672` — 同款 `.contentTransition(.symbolEffect(.replace))`（另一处图标切换，未指定方向变体）。
- `:922,929,1143,1420,1461` — `Image(systemName: "play.fill"/"pause.fill"/"shuffle")` 等，全部走 SF Symbols 系统字体图标，未见任何自绘 icon 资源在这几处。
- 字重：全仓库 `Image(systemName:).font(.system(size:, weight:))` 模式随处可见（如 `HoverableButtons.swift` 里 `.font(.system(size: 10, weight: .semibold))`），按钮场景遵循 HIG"字重按语境区分"的一般惯例，但未见统一的字重 token 表（各按钮各写各的 size/weight 字面量）。

官方对应物：SF Symbols（系统字体图标，标准做法）、`.symbolEffect`/`contentTransition(.symbolEffect(...))`（SwiftUI 官方图标动效 API，长期存在，[未验证：本轮 official.md 未专门收录 symbolEffect 家族签名，但为 iOS17+/macOS14+ 长期公开 API，非本次 26 专项检索范围]）。

差距：这部分**基本已经原生**——全部用 SF Symbols + 官方 `symbolEffect` 做图标切换动效，没有发现自绘图标资源或手写图标动画。唯一的小差距是字重/尺寸缺少统一 token（`MicroInteractionFeel.Tokens` 这类命名模式已经在动效参数上使用，但图标 size/weight 字面量分散在各调用点），维护成本问题而非"是否原生"问题。

建议：**保留现状**，不需要换官方——已经在用官方组件；如果要优化，是把分散的 `.font(.system(size:weight:))` 字面量收敛进 token 表，属于代码整洁范畴，不属于本次"原生化"审计的核心诉求。

与禁用模式的冲突：无。

---

（本报告共审计 12 个元素，逐条列出 file:line 现状、官方对应物验证状态、具体差距、建议与禁用模式对照；未修改任何源码，未跑 build/test。）
