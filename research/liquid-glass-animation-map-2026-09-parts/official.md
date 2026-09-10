# Liquid Glass 官方资料研究（2026-09-10）

方法说明：`developer.apple.com/documentation/...` 页面是 JS 渲染的 SPA，WebFetch 直抓只拿到 `<title>`。改用 Apple 文档页背后的 JSON 数据端点 `developer.apple.com/tutorials/data/documentation/<path>.json`，可稳定拿到签名、availability、discussion 全文——本文档大部分 API 条目都来自这个端点，已在表格标注「已见」。WWDC 会话官方 transcript 页同样是 SPA，改用 wwdcnotes.com 的会话笔记页作为转述来源，并标注为二手（非 Apple 原文）。HIG 的 Materials / Motion 页始终未能拿到正文（见「未找到」）。

---

## 1. WWDC25 四场会议

### 1.1 Meet Liquid Glass (219)
URL: https://developer.apple.com/videos/play/wwdc2025/219/
来源：wwdcnotes.com 二手转述（Apple 官方 transcript 页未能抓取正文）https://wwdcnotes.com/documentation/wwdc25-219-meet-liquid-glass/

- 材质本质：Liquid Glass 是会「弯曲和塑形光线」（bends and shapes light）的材质，具有凝胶般的流动性；不同于旧材质靠散射光线，这个材质优先做折射（refraction）。
- 自适应（adaptivity）：内容在下方滚动时阴影会加深以维持视觉分离；组件可独立在浅色/深色间切换；附近的彩色内容会让光「溢到玻璃表面」；元素越大玻璃显得越厚，阴影和散光越明显。
- 交互反馈：用户交互时「Liquid Glass 会随光线 flex 和 energize」，交互中元素可以短暂「抬升进玻璃表面」形成触感反馈——这是自动行为，非开发者手写动画。
- 玻璃层级规则：Liquid Glass 是「浮在 app 内容之上的导航层」（the navigation layer that floats above the content of an app），不该嵌入内容本身。
- 玻璃不能叠玻璃：原文明确「Avoid stacking glass on glass」，层与层之间用填充色和透明度做视觉分隔，而非再叠一层玻璃。
- Tint 使用约束：着色「只应该用来强调主要元素」，不是装饰性用途。
- 两个变体：Regular 与 Clear「不应混用」；Clear 变体没有自适应行为，需要大胆、媒体丰富的背景才能起效。
- [未验证] 具体动画时长数字（如多少毫秒/秒）：本次检索到的转述未包含精确 timing 数字，Apple 公开资料似乎不给出具体动效时长，只给行为描述。

### 1.2 Get to know the new design system (356)
URL: https://developer.apple.com/videos/play/wwdc2025/356/
来源：wwdcnotes.com 二手转述 https://wwdcnotes.com/documentation/wwdc25-356-get-to-know-the-new-design-system/

- 三种形状类型：Fixed（固定圆角半径）、Capsule（半径=容器尺寸的一半）、Concentric（父容器半径减去 padding 算出的同心圆角）。原文：「Capsule is used a lot in system, because it supports concentricity」。
- 玻璃层级/分层原则：控件和导航依靠「Liquid Glass 的抬升」获得强调，而不是靠颜色装饰——原文「Don't rely on (color) decoration, but on grouping and layout」。
- Modality（模态）指示：打断性任务（如 sheet）用「dimming layer」表示模态；并行任务（parallel tasks）则「用不带 dimming layer 的 Liquid Glass」表示非阻断。
- 应用材质的位置规则：「apply material directly to the control, not inner views」——material 要直接加在控件本体上，不要加在控件内部的子视图上。
- Scroll edge effect 定位为功能性而非装饰性：「clarify where UI and content meet」，「are not decorative」；Soft 用于「交互元素」（细微模糊），Hard 用于「交互文字/无背景控件/pinned 表头」；同一视图内不要混用两种边缘效果。
- 跨设备一致性：要求「one layout, hierarchy or interaction」贯穿设备；「a label is always better than an icon」。
- [未验证] 本页转述未直接给出 Reduce Transparency / Reduce Motion / Increase Contrast 在此场次的具体措辞（这部分内容来自 Adopting Liquid Glass 技术文章，见第 3/6 节）。

### 1.3 Build a SwiftUI app with the new design (323)
URL: https://developer.apple.com/videos/play/wwdc2025/323/
来源：wwdcnotes.com 二手转述 https://wwdcnotes.com/documentation/wwdc25-323-build-a-swiftui-app-with-the-new-design/

- 「Use `.glassEffect()` to manually add Liquid Glass to any view」——默认 capsule 形状，自动套用有辨识度的文字着色。
- 多个玻璃元素要放进 `GlassEffectContainer` 以获得正确的视觉合一与协同效果。
- 「Use `.glassEffectID` modifier on child views for transitions or morphing of glass views」——配合 `@Namespace` 做 matched geometry。
- Toolbar：`ToolbarSpacer(.fixed)` 分隔工具栏组，`ToolbarSpacer(.flexible)` 撑开底部项间距；`.sharedBackgroundVisibility(.hidden)` 可以隐藏某组的玻璃容器背景；工具栏项默认会自动分组进 Liquid Glass 容器。
- `tabBarMinimizeBehavior()` 滚动时收起 Tab Bar；`tabViewBottomAccessory` 在 Tab Bar 上方加辅助视图，带 `tabViewBottomAccessoryPlacement` 环境值响应式布局。
- ScrollView：`.scrollEdgeEffectStyle(.hard, for: .top)` 用于硬边缘效果，会去掉背景条。

### 1.4 Build an AppKit app with the new design (310)
URL: https://developer.apple.com/videos/play/wwdc2025/310/
来源：wwdcnotes.com 二手转述 https://wwdcnotes.com/documentation/wwdc25-310-build-an-appkit-app-with-the-new-design/（章节列表由 WebSearch 摘要给出：0:00 Introduction / 1:23 App structure / 9:27 Scroll edge effect / 11:10 Controls / 17:30 Glass / 21:30 Next steps）

- 「Use `NSGlassEffectView` to place your `contentView` on glass」；可调 `cornerRadius`、`tintColor`。
- 多个玻璃形状靠近时：「Group them together using `NSGlassEffectContainerView` to avoid visual artifacts and improve performance」；且「adaptive appearance is also shared within groups」——组内玻璃对周围环境的自适应表现是共享的。
- Scroll edge effect 两种：Soft-edge 用「progressive (or variable) blur」，Hard-edge 用「more opaque backing」；split view 的 item accessory 会自动在浮动 sidebar 内容下方套用这些效果。
- Controls 新增 extra-large 尺寸，用于「app 中最突出的操作」；新增 `NSTintProminence` 枚举与 `tintProminence` 属性控制强调程度。
- [未验证] 本转述未提及 AppKit 侧是否有独立的「morph transition」API 名字（对照 SwiftUI 的 `GlassEffectTransition`）；结合第 5 节对 `NSGlassEffectContainerView` API 文档的直接抓取结果看，官方文档只描述它做「渲染合并（merge）以提升性能」，未描述帧动画式的「形状融合过渡」；因此判断 AppKit 没有对应 SwiftUI `glassEffectID`/`GlassEffectTransition` 的显式 morph-transition API。

---

## 2. HIG：Materials 与 Motion

- Materials 页 URL：https://developer.apple.com/design/human-interface-guidelines/materials — **正文抓取失败**（WebFetch 与 apple-dev-mcp 都只返回标题/一句摘要「Use system materials and visual effects thoughtfully to create depth and hierarchy while maintaining clarity and performance.」），标记 [未验证，仅有摘要]。
- Motion 页 URL：https://developer.apple.com/design/human-interface-guidelines/motion — **正文抓取失败**，apple-dev-mcp 搜索无结果，标记 [未找到]。
- 玻璃不叠玻璃、导航层浮于内容之上、Reduce Transparency 让玻璃「更霜化」等结论均来自 WWDC 会话转述与 Adopting Liquid Glass 技术文章（见 1.1、3、6 节），不是直接引自 HIG Materials/Motion 正文，这里如实标注来源差异。

---

## 3. 技术总览文章

### 3.1 Liquid Glass（概览）
URL: https://developer.apple.com/documentation/technologyoverviews/liquid-glass
来源：JSON 数据端点已见（`tutorials/data/documentation/technologyoverviews/liquid-glass.json`）

- 定义：结合玻璃的光学属性与流动感的新动态材质，统一 Apple 各平台设计语言。
- Lensing：材质形成透明/半透明层，让彩色元素和下方内容透出；建立深度与层级。
- SwiftUI / UIKit / AppKit 的标准组件（控件、导航元素）自动获得 Liquid Glass 外观与行为；自定义元素需要主动实现。
- 设计原则五条：视觉层级优先；颜色克制、保证控件/导航可读且让内容透出；App 图标要用简单、大胆的分层设计；跨设备一致性；标准图标与可预期的操作位置。
- 建议：用最新 Xcode 构建即可自动获得视觉更新；窗口/弹窗/菜单/工具栏都要按新最佳实践适配；跨平台充分测试。

### 3.2 Adopting Liquid Glass（采用指南）
URL: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
来源：JSON 数据端点已见（`tutorials/data/documentation/technologyoverviews/adopting-liquid-glass.json`）

- 无障碍自适应原文：「Translucency and fluid morphing animations contribute to the look and feel of Liquid Glass, but can adapt to people's needs. For example, people can choose a preferred look for Liquid Glass in their device's settings, or turn on accessibility settings that reduce transparency or motion in the interface. These settings can remove or modify certain effects.」
- 「If you use standard components from system frameworks, this experience adapts automatically. Ensure you test your app's custom elements, colors, and animations with different configurations of these settings.」——标准组件自动适配，自定义元素必须自己在这些设置下测试。
- 平台指南：watchOS 变化很小，用 watchOS 10+ 的标准按钮样式/工具栏 API 即可自动获得；tvOS 标准控件在 focus 时获得 Liquid Glass 外观（需 Apple TV 4K 二代或更新），自定义控件要用 `View.focusable(_:)` / `EnvironmentValues.isFocused`；iOS/iPadOS/macOS 用最新 SDK + 标准组件自动获得。
- Sidebar/Inspector 下内容延伸：「A background extension effect creates a sense of extending a background under a sidebar or inspector, without actually scrolling or placing content under it. A background extension effect mirrors the adjacent content to give the impression of stretching it under the sidebar, and applies a blur to maintain legibility of the sidebar or inspector.」对应 API：SwiftUI `View.backgroundExtensionEffect()`、UIKit `UIBackgroundExtensionView`、AppKit `NSBackgroundExtensionView`。

### 3.3 Applying Liquid Glass to custom views（关键文章，逐字摘录）
URL: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
来源：JSON 数据端点已见（`tutorials/data/documentation/swiftui/applying-liquid-glass-to-custom-views.json`），全文见第 5 节引用。

---

## 4. SwiftUI API 逐条（均来自 JSON 数据端点直接抓取，已见）

见文末「API 清单」表。要点摘录：

- `glassEffect(_:in:isEnabled:)` 实际签名是 `glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View`（未见到 `isEnabled:` 重载被抓到，可能是文档站点渲染的默认重载版本；标记 [部分未验证：isEnabled 重载未直接见到签名文本，但 HIG/文章多处暗示存在 disabled 状态玻璃，不改变整体结论）。
- `GlassEffectContainer(spacing: CGFloat?, content: () -> Content)`：「combines multiple Liquid Glass shapes into a single shape that can morph individual shapes into one another」；spacing 越大，形状越早开始融合（blend）。
- `glassEffectID(_:in:)`：「When used together, SwiftUI uses the identifier to animate shapes to and from each other during transitions.」
- `glassEffectUnion(id:namespace:)`：把多个视图的几何形状汇成一个统一玻璃形状，即使静止状态下也生效（不只是过渡瞬间）。
- `GlassEffectTransition`：`.identity`（无变化）、`.matchedGeometry`（几何匹配过渡，容器内默认过渡类型）、`.materialize`（淡入淡出+玻璃材质渐入渐出，不尝试匹配其他玻璃效果的几何形状，用于间距超出容器 spacing 的场景）。
- `Glass` 结构：`.regular`、`.clear`、`.identity`（应用后内容表现得像完全没加玻璃）；实例方法 `.tint(_:)`、`.interactive(_:)`。
- `PrimitiveButtonStyle.glass`（即 `.buttonStyle(.glass)`）：「applies a Liquid Glass effect based on the button's context」；`glassProminent` 是更突出的变体（本次仅通过 WebSearch 摘要确认存在，未直接抓到 JSON 签名，标记 [未验证：仅二手摘要]）。
- `backgroundExtensionEffect()`：视图被镜像复制到安全区域边缘周围充当背景，并加模糊；官方提示「clip 视图防止副本互相重叠」，「应谨慎使用，通常只用一个背景内容实例」。
- `scrollEdgeEffectStyle(_:for:)` + `ScrollEdgeEffectStyle`：`.automatic` / `.hard`（近乎不透明的硬边界）/ `.soft`（细微模糊边界）。
- `tabBarMinimizeBehavior(_:)`：**确认 macOS 26.0+ 可用**（与 iOS/iPadOS/Mac Catalyst/tvOS/visionOS/watchOS 并列，JSON 端点原文含 macOS）。
- `ToolbarSpacer(_:placement:)`：availability 只列到 iOS/iPadOS/Mac Catalyst/macOS 26.0+（未见 watchOS/tvOS/visionOS，符合它是工具栏专属组件的预期）。

---

## 5. AppKit API 逐条（均来自 JSON 数据端点直接抓取，已见）

- `NSGlassEffectView`（macOS 26.0+，继承 `NSView`）：
  - `contentView: NSView?` — 嵌入玻璃的内容视图
  - `cornerRadius: CGFloat` — 玻璃四角曲率
  - `tintColor: NSColor?` — 玻璃背景/效果的着色目标色
  - `style: NSGlassEffectView.Style` — `.regular` / `.clear`
  - `effectIsInteractive: Bool`（默认 `false`）—— **注意：JSON 端点显示这个属性的 availability 是 macOS 27.0+，不是 26.0**，即当前 macOS 26 时代可能还不可用/是未来 API，需要用 Xcode 实测验证；官方描述「应该在玻璃作为交互控件的背景或容器时启用，启用后交互时会有视觉反馈」。
- `NSGlassEffectContainerView`（macOS 26.0+）：
  - `contentView: NSView?`
  - `spacing: CGFloat` — 「容器开始合并相邻可合并玻璃视图的邻近阈值」
  - 官方定性为**性能优化机制**：「Using a glass effect container view can improve performance by reducing the number of passes required to render similar glass effect views.」自动监测子孙 `NSGlassEffectView`，进入 spacing 范围内的会合并进同一次渲染 pass。**文档原文只讲渲染合并/性能，没有像 SwiftUI 那样明确描述「形状融合的动画过渡」这个视觉行为**（对照第 4 节 `GlassEffectContainer`「combines...into a single shape that can morph」的措辞，AppKit 版本文档没有出现「morph」这个词）。
- `NSGlassEffectView.Style`：`.regular`、`.clear`（macOS 26.0+）。
- `NSButton.BezelStyle.glass`（Swift `case glass` / ObjC `NSBezelStyleGlass`，macOS 26.0+）：「A bezel style with a glass effect」。[未验证] `.prominentGlass` 未在本次检索中直接确认存在，未抓到对应文档页，标记未验证，不写入清单。
- `NSVisualEffectView`：本次未专门抓取其新规则页面，暂不下结论；[未验证]。

---

## 6. 自动 morph 触发条件（原文引用为准）

**触发机制（SwiftUI，已验证/已见原文）**：
1. 多个视图各自套用 `glassEffect(_:in:)`，都被包在同一个 `GlassEffectContainer` 里。
2. 需要参与 morph 的那组视图，各自打上同一个 `Namespace` 下的 `glassEffectID(_:in:)`（不同的 id 代表不同形状，相同 id 代表同一形状在跨状态间的身份延续）。
3. 视图在层级中「出现/消失/被添加或移除」，并且这个变化被包在 `withAnimation` 里驱动。

原文引用（`applying-liquid-glass-to-custom-views` JSON 数据端点，已见）：

> "GlassEffectContainer is a view that combines multiple Liquid Glass shapes into a single shape that can morph individual shapes into one another."

> "Customize the spacing on the container to control how the Liquid Glass effects behind views interact with one another. The larger the spacing value on the container, the sooner the Liquid Glass effects behind views blend together and merge the shapes during a transition. A spacing value on the container that's larger than the spacing of an interior HStack, VStack, or other layout container causes Liquid Glass effects to blend together at rest because the views are too close to each other. Animating views in or out causes the shapes to morph apart or together as the space in the container changes."

> "Morphing effects occur during transitions or animations between views with Liquid Glass effects. Coordinate transitions between views with effects in a container by using the glassEffectID(_:in:) modifier. GlassEffectTransition allows you to specify the type of transition to use when you want to add or remove effects within a container. For effects you want to add or remove that are positioned within the container's assigned spacing, the default transition type is matchedGeometry."

> "Associate each Liquid Glass effect with a unique identifier within a namespace that the Namespace property wrapper provides. These IDs ensure SwiftUI animates the same shapes correctly when a shape appears or disappears due to view hierarchy changes. SwiftUI uses the spacing provided to the effect container along with the geometry of the shapes themselves to determine when and which appropriate shapes to morph into and out of."

> "The glassEffectID(_:in:) and glassEffectTransition(_:) modifiers only affect their content during view hierarchy transitions or animations."

结论：**spacing 是判定"多近才融合"的几何阈值**（越大越容易融合），而**是否触发 morph 动画取决于 withAnimation 包裹的视图层级变化（出现/消失/移动）+ 相同 Namespace 下相同/不同 glassEffectID**——静止状态下（未发生 hierarchy 变化）如果几何距离小于 spacing，两个玻璃形状也会直接在视觉上"融合"（blend at rest），这与"过渡动画中的 morph"是两回事：前者是静态渲染合并，后者才是动画意义上的 morph。

**关于动画时长/曲线的官方控制方式**：文档中没有出现任何独立于 `withAnimation` 的「morph duration」参数——`glassEffectID`/`glassEffectTransition` 本身「only affect their content during view hierarchy transitions or animations」，即它们只是标注参与哪次过渡、用什么过渡类型（`.matchedGeometry` / `.materialize` / `.identity`），实际时长/缓动曲线仍由外层包裹的 `withAnimation(_:_:)` 决定。**没有找到与 morph 时长相关的专属 API**，标记 [未找到独立 duration 控制 API]。

**AppKit 侧（已见 `NSGlassEffectContainerView` 官方文档原文，未见 morph 措辞）**：
`NSGlassEffectContainerView` 的官方描述通篇只谈「合并渲染 pass 以提升性能」（"reducing the number of passes required to render similar glass effect views"），完整文档没有出现"morph"这个词，也没有提到任何配合 `withAnimation`/显式过渡 API 的动画融合机制。**结论：没有找到 AppKit 侧对应 SwiftUI `glassEffectID`/`GlassEffectTransition` 的显式 morph-transition API**——这与 WWDC25 310 场次转述（wwdcnotes 二手来源）里也没提到对应 API 一致。这是本次研究认为最值得注意的一处平台差异，写入下方"未找到"清单。

**关于 NSPanel / 透明背景浮动窗口能否用 glassEffect，以及"玻璃需要背景内容"的说法**：
本次检索**没有找到**官方文档中专门针对"NSPanel/NSWindow 透明背景 + glassEffect"组合的明确说明或禁止性描述。可确认的相关事实：
- `NSGlassEffectView`/`NSGlassEffectContainerView` 是 `NSView` 子类，其官方 API 文档没有限定宿主窗口必须是不透明背景；文档也没有说"glass 必须有内容在背后才能工作"这句话——这是我在会话前被给的假设，**未在本次抓取的任何官方原文中验证到**，标记 [未验证/未找到对应官方原文]。
- 相关但不完全等价的官方立场：「Liquid Glass 是浮在内容之上的导航层」（1.1 节），暗示设计意图上玻璃下方应该有真实内容可供透光/折射，但这是设计原则表述，不是技术上的"无内容就不工作"限制声明。
- 建议：如果 nanoPod 要验证"透明背景浮动面板 + glassEffect"的实际渲染表现，需要用 Xcode 26 SDK 实机截图验证，官方文档本身在这一点上没有给出可引用的明确规则。

---

## API 清单

| API | 框架 | macOS 26 可用 | 语义一句话 | 出处 URL | 验证状态 |
|---|---|---|---|---|---|
| `glassEffect(_ glass:in:)` | SwiftUI | 是 | 给视图加 Liquid Glass 材质背景（默认 regular + Capsule） | https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:) | 已见 |
| `GlassEffectContainer(spacing:content:)` | SwiftUI | 是 | 合并多个玻璃形状为一个可互相 morph 的整体 | https://developer.apple.com/documentation/swiftui/glasseffectcontainer/ | 已见 |
| `glassEffectID(_:in:)` | SwiftUI | 是 | 给玻璃效果打身份标识，驱动过渡时的形状动画匹配 | https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:) | 已见 |
| `glassEffectUnion(id:namespace:)` | SwiftUI | 是 | 把多个视图的几何汇聚成一个统一玻璃形状（含静止态） | https://developer.apple.com/documentation/swiftui/view/glasseffectunion(id:namespace:) | 已见 |
| `GlassEffectTransition` (`.identity`/`.matchedGeometry`/`.materialize`) | SwiftUI | 是 | 指定玻璃效果增删时用哪种过渡（几何匹配 or 淡入淡出材质化） | https://developer.apple.com/documentation/swiftui/glasseffecttransition | 已见 |
| `Glass` (`.regular`/`.clear`/`.identity`/`.tint(_:)`/`.interactive(_:)`) | SwiftUI | 是 | 玻璃材质配置结构体：变体、着色、是否交互响应 | https://developer.apple.com/documentation/swiftui/glass | 已见 |
| `PrimitiveButtonStyle.glass`（`.buttonStyle(.glass)`） | SwiftUI | 是 | 按钮套用基于上下文的 Liquid Glass 样式 | https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass | 已见 |
| `glassProminent`（`.buttonStyle(.glassProminent)`） | SwiftUI | 是（推断） | 更突出的玻璃按钮样式 | https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glassprominent | 未验证（仅二手摘要，未见 JSON 原文） |
| `backgroundExtensionEffect()` | SwiftUI | 是 | 把视图镜像延伸到安全区外并模糊，制造内容延伸到玻璃下方的错觉 | https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect() | 已见 |
| `scrollEdgeEffectStyle(_:for:)` / `ScrollEdgeEffectStyle` | SwiftUI | 是 | 配置滚动内容与固定控件交界处的模糊/硬边过渡风格 | https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:) | 已见 |
| `tabBarMinimizeBehavior(_:)` | SwiftUI | 是（JSON 原文明确含 macOS 26.0+） | 配置 Tab Bar 在滚动等交互下的收起行为 | https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:) | 已见 |
| `ToolbarSpacer(_:placement:)` | SwiftUI | 是 | 工具栏里的标准分隔间距项，可固定或弹性 | https://developer.apple.com/documentation/swiftui/toolbarspacer | 已见 |
| `NSGlassEffectView` | AppKit | 是 | 把 contentView 嵌入动态玻璃效果的容器视图 | https://developer.apple.com/documentation/appkit/nsglasseffectview | 已见 |
| `NSGlassEffectView.cornerRadius` | AppKit | 是 | 玻璃四角曲率 | https://developer.apple.com/documentation/appkit/nsglasseffectview/cornerradius | 已见 |
| `NSGlassEffectView.tintColor` | AppKit | 是 | 玻璃背景/效果的着色目标色 | https://developer.apple.com/documentation/appkit/nsglasseffectview/tintcolor | 已见 |
| `NSGlassEffectView.style` (`NSGlassEffectView.Style`: `.regular`/`.clear`) | AppKit | 是 | 玻璃风格：常规或清澈 | https://developer.apple.com/documentation/appkit/nsglasseffectview/style-swift.enum | 已见 |
| `NSGlassEffectView.effectIsInteractive` | AppKit | **否，JSON 原文显示 macOS 27.0+** | 是否对交互给出视觉反馈 | https://developer.apple.com/documentation/appkit/nsglasseffectview/effectisinteractive | 已见（注意 availability 高于本项目目标 OS） |
| `NSGlassEffectContainerView` | AppKit | 是 | 合并邻近的子孙玻璃视图以减少渲染 pass、提升性能 | https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview | 已见 |
| `NSGlassEffectContainerView.spacing` | AppKit | 是 | 判定开始合并渲染的邻近阈值 | https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview/spacing | 已见（合并到 contentView/spacing 一并抓取） |
| `NSButton.BezelStyle.glass` | AppKit | 是 | 带玻璃效果的按钮 bezel 样式 | https://developer.apple.com/documentation/appkit/nsbutton/bezelstyle-swift.enum/glass | 已见 |
| `NSButton.BezelStyle.prominentGlass` | AppKit | 未知 | （推测存在的突出玻璃按钮样式） | — | 未验证，未找到文档页，不确认存在 |
| `NSVisualEffectView` 新规则 | AppKit | — | 未专门检索 | — | 未验证 |
| `accessibilityReduceMotion`（SwiftUI 环境值） | SwiftUI | 是（macOS 10.15+，非 26 新增） | Reduce Motion 系统偏好是否开启，开启时应避免大幅/拟三维动画 | https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion | 已见 |
| `NSWorkspace.accessibilityDisplayShouldReduceMotion` | AppKit | 是（macOS 10.12+，非 26 新增） | 同上，AppKit 侧读取方式；变化时可订阅 `accessibilityDisplayOptionsDidChangeNotification` | https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion | 已见 |

---

## 未找到 / 未验证清单

- HIG Materials 页（https://developer.apple.com/design/human-interface-guidelines/materials）正文：抓取失败，只有一句摘要，未见完整"玻璃层级规则/hover/press feedback"原文表述。
- HIG Motion 页（https://developer.apple.com/design/human-interface-guidelines/motion）：完全未找到可访问正文，apple-dev-mcp 搜索也无结果。
- WWDC25 四场会话的 Apple 官方 transcript 全文：均未能直接抓取（SPA），本文档四节内容均转引自 wwdcnotes.com 二手笔记，不是 Apple 一手 transcript 原文，请注意这层来源差异。
- `glassProminent` 按钮样式的 JSON 文档原文：未直接抓到，仅有 WebSearch 摘要确认其存在及语义，标记未验证。
- `NSButton.BezelStyle.prominentGlass`：未找到对应文档页，无法确认是否存在，未写入正式清单当作已验证项。
- AppKit 侧是否存在独立的"morph transition"API（对应 SwiftUI `GlassEffectTransition`）：**没有找到**——`NSGlassEffectContainerView` 官方文档原文只讲性能层面的渲染合并，未出现"morph"措辞，判断当前 AppKit API 里没有对应能力，只能通过配合 `NSAnimationContext`/隐式动画自行实现，但没有找到官方文档明确背书这个做法。
- "glassEffect 是否需要窗口/面板背景有真实内容才能工作"的官方明确表述：**没有找到**。这是本次研究被要求验证的一条假设，最终判定为"未在官方原文中找到直接支持或反对的句子"，不应在 nanoPod 代码里当作已验证事实使用。
- `glassEffect(_:in:isEnabled:)` 的 `isEnabled:` 重载：JSON 端点只返回了不带 `isEnabled` 的签名，未直接验证到三参数重载是否存在。
- 具体的 morph/appear 动画时长数字（毫秒/秒级）：官方资料中未找到任何具体数字，只有行为性描述（受 `withAnimation` 参数控制，无独立 duration API）。
