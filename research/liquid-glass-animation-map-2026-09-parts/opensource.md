# 开源 Liquid Glass / 流体动效实现调研（2026-09）

调研范围：GitHub 上 2025–2026 活跃的 Liquid Glass / 流体动效开源实现，覆盖 a–g 七类动效词汇。方法：WebSearch 定位仓库 + WebFetch 抓 README（部分仓库因搜索小模型摘要限制未能抓源码文件，标 [未验证]）。所有条目均来自实际抓取结果，未编造仓库。

nanoPod 适用性判定基准：macOS 悬浮 NSPanel、无 glass-on-glass、禁 `.hudWindow`、禁私有 API、必须有 Reduce Motion 回退。

---

## a. Glass morph between shapes（GlassEffectContainer / glassEffectID / NSGlassEffectContainerView）

| 仓库 | URL | 活跃度 | 语言/框架 | macOS 26 | 公开 API | 许可证 | 技术要点 | 适用性 |
|---|---|---|---|---|---|---|---|---|
| conorluddy/LiquidGlassReference | github.com/conorluddy/LiquidGlassReference | 2026 活跃 | SwiftUI 文档+示例 | 是（iOS 26 API 文档，含 macOS 对应 API） | 是（纯官方 API 摘录） | [未验证] | 汇总 `GlassEffectContainer` + `glassEffectID(_:in:)` 用法：同容器内、共享 namespace、条件显隐触发 morph | 参考资料性质非可直接嫁接的渲染代码；可作为核对官方 API 用法的速查表，非 C1 直接代码来源 |
| mertozseven/LiquidGlassSwiftUI | github.com/mertozseven/LiquidGlassSwiftUI | 2025-2026 | SwiftUI, iOS 26 | iOS-only（未见 macOS target） | 是 | [未验证] | quote card + 可展开 action buttons + symbol transition，用 `.glassEffect` 系列 API | iOS-only，仅可读 morph 触发时机代码，不可直接跑在 macOS NSPanel |
| Apple 官方 AppKit 文档：NSGlassEffectContainerView | developer.apple.com/documentation/appkit/nsglasseffectcontainerview | 官方持续更新 | AppKit (macOS 26) | 是 | 是（官方 API） | 官方 | `NSGlassEffectContainerView.spacing` 控制邻近玻璃视图何时融合；子 NSGlassView z-order 自动提升，`contentView` 承载内容 | 最贴近我们需求的一手信息源：AppKit 原生 API，直接适用于 NSPanel；C1 边缘胶囊 morph 应优先读这份官方文档而非第三方 repo |
| onmyway133/blog Issue #997 "How to morph liquid glass view transition" | github.com/onmyway133/blog/issues/997 | 2025-2026 讨论串 | SwiftUI 讨论 | 混合 | 未知 | N/A（Issue 非代码库） | 讨论 morph 触发条件与常见踩坑（namespace 不一致导致不 morph） | 非代码仓库，仅作问题排查参考 |

未找到独立成仓库、专门演示 AppKit `NSGlassEffectContainerView` pill↔card morph 的第三方开源项目——搜索只返回 Apple 官方文档与转述博客，说明这块目前几乎是官方文档独占，第三方 AppKit-glass 开源示例稀缺。

---

## b. Notch 边缘胶囊 dock/hover 展开（仅取边缘胶囊力学，非 Dynamic-Island 多形态挂载）

| 仓库 | URL | 活跃度 | 语言/框架 | macOS 26 | 公开 API | 许可证 | 展开/收起机制 | 适用性 |
|---|---|---|---|---|---|---|---|---|
| TheBoredTeam/boring.notch | github.com/TheBoredTeam/boring.notch | 高活跃，1268 commits，245 open issues/110 PR，仍在合并 | SwiftUI, macOS 14+（源码构建需 macOS 15.6+/Xcode 26） | 是 | 未验证具体渲染文件，README 未见私有 API 提示 | **GPL-3.0**（需 flag：GPL 传染性强，若借鉴实现思路而非直接引用代码则安全，直接搬运代码到闭源/非 GPL 项目违规） | hover 展开为音乐可视化+日历+系统 HUD 的常驻通知中心；具体是"resize 真实 NSWindow"还是"固定透明大窗口内容动画"未在 README 中说明，需读源码确认 [未验证] | GPL 许可证是硬阻碍——nanoPod 若非 GPL 协议不可直接复用其代码，只能读思路；仍值得读一遍 hover 展开的触发/收起时序作为参考 |
| altic-dev/DynamicNotchKit | github.com/altic-dev/DynamicNotchKit | 中活跃，159 commits | SwiftUI, macOS 13+ | 是（明确支持无 notch 机型的 `.floating` 降级） | 是（纯 SwiftUI，README 未提私有 API） | **MIT** | `await notch.expand()` 异步 API；明确同时支持"真实 notch"和"无 notch 的 floating 模式"，说明其展开机制是与几何解耦的抽象层，很可能是固定窗口内容动画而非真实 resize（因为要兼容两种物理布局）[未验证，需读源码确证] | 许可证友好（MIT）+ 明确的降级模式思路（有 notch/无 notch 统一 API）与我们"边缘隐藏/peek"场景的抽象方式接近，值得细读 window 管理源码 |
| Zach677/NotchDrop | github.com/Zach677/NotchDrop | 2025-2026，boring.notch 致谢的上游项目 | SwiftUI | 是 | 未验证 | [未验证，原项目未在搜索摘要给出] | 文件拖拽 tray，被 boring.notch 借用了 "Shelf" 概念；本身展开动效细节未抓取到 | 概念上游，动效实现细节需二次抓取，优先级低于 boring.notch/DynamicNotchKit |
| navtoj/NotchBar | github.com/navtoj/NotchBar | [未验证具体活跃度] | Swift, macOS notch | [未验证] | [未验证] | [未验证] | 搜索仅列出仓库名，未抓取 README | 标记待读，未来若需要更多样本可补充抓取 |
| monuk7735/mew-notch | github.com/monuk7735/mew-notch | [未验证] | Swift | [未验证] | [未验证] | [未验证] | "Make the Notches on newer Macs Useful" | 同上，未深挖 |
| jackson-storm/DynamicNotch / winstonkhoe/DynamicNotch | 两个同名不同作者仓库 | [未验证] | Swift | [未验证] | [未验证] | [未验证] | 一个做"系统级 live surface"，一个做"AirDrop 临时文件存储" | 命名混淆需注意别搞错仓库；均未深读 |

注：Peninsula、NotchNook 本身是**闭源/付费**项目（搜索结果显示 NotchNook 售价 $25，且被称为"boring.notch 是它的开源替代"），不满足本次开源调研范围，故不建表，仅作背景说明：boring.notch 定位为 NotchNook 的开源对标。

---

## c. Liquid / fluid buttons（press scale、hover highlight 滑动、liquid tab bar indicator）

| 仓库 | URL | 活跃度 | 语言/框架 | macOS 26 | 公开 API | 许可证 | 技术要点 | 适用性 |
|---|---|---|---|---|---|---|---|---|
| ryanashcraft/FabBar | github.com/ryanashcraft/FabBar | 2025-2026 | SwiftUI (iOS) | iOS-only，未见 macOS target | [未验证] | [未验证] | 用 `UISegmentedControl` 作底座、隐藏默认 label、叠加自定义 tab item 视图来复刻触摸下的"气泡"玻璃效果 | 依赖 UIKit `UISegmentedControl`，iOS-only，不可直接移植到 macOS NSPanel；仅动效思路（底层用系统控件承载物理反馈、上层叠视觉）可借鉴 |
| unionst/union-tab-view | github.com/unionst/union-tab-view | 2025-2026 | SwiftUI | [未验证 macOS 支持] | [未验证] | [未验证] | 浮动玻璃效果 tab，支持任意自定义 `@ViewBuilder` tab item | 需二次确认平台支持后再评估 |
| Tilak1028-st/LiquidGlassTabBar | github.com/Tilak1028-st/LiquidGlassTabBar | 2025-2026 | SwiftUI | [未验证，命名暗示 iOS 26 风格] | [未验证] | [未验证] | `matchedGeometryEffect` 驱动的气泡切换 + squish-on-land 落地挤压动效 | squish-on-land 的弹簧曲线思路可参考，落地前需确认是否 macOS 兼容 |
| exyte/LiquidSwipe | github.com/exyte/LiquidSwipe | 较老但知名，Exyte 系列 | SwiftUI (iOS) | 明确 iOS-only | 是 | MIT（Exyte 系列惯例，[未直接核实此仓库]） | 贝塞尔曲线驱动的液态滑动手势过渡 | 纯 iOS 手势过渡，与我们的边缘胶囊/按钮场景关联度低，仅作"液态形变数学"参考 |

未找到专门针对 **macOS 原生按钮**（非 iOS 移植）的"liquid press scale"开源库；此类效果在开源生态中几乎全部以 iOS SwiftUI 组件形式存在，macOS 特化实现空缺，需自行基于 `.buttonStyle` + spring 实现。

---

## d. Hover capsule highlight（跟随 hover 移动的胶囊，如 macOS 26 工具栏悬浮）

| 仓库 | URL | 活跃度 | 语言/框架 | macOS 26 | 公开 API | 许可证 | 技术要点 | 适用性 |
|---|---|---|---|---|---|---|---|---|
| gahntpo/MatchedGeometryExamples | github.com/gahntpo/MatchedGeometryExamples | [未验证具体日期，长期维护型 demo] | SwiftUI | 跨平台（demo 项目，未锁定单一平台） | 是 | [未验证] | 多场景 `matchedGeometryEffect` 用例合集，含分段控件高亮迁移 | 平台无关的 demo 集合，可直接读几个 case 里的 segmented-control 高亮实现，改绑 macOS `onHover` 即可用 |
| nilcoalescing 博客："Custom Segmented Control With MatchedGeometryEffect" | nilcoalescing.com/blog/CustomSegmentedControlWithMatchedGeometryEffect | 长期参考文章 | SwiftUI 代码片段（非仓库） | 跨平台代码 | 是 | N/A（博客非仓库，无许可证问题） | 用 `matchedGeometryEffect` 实现分段控件里胶囊跟随选中项移动的背景 | 非 GitHub 仓库但代码片段完整、无许可证顾虑，是 D 类最直接可抄的参考之一；需自行把"选中态切换"改为"hover 态切换" |
| swiftui-lab/swiftui-hero-animations | github.com/swiftui-lab/swiftui-hero-animations | [未验证近期活跃度] | SwiftUI | 跨平台 | 是 | [未验证] | `matchedGeometryEffect` 驱动的 hero 过渡/视图形变 | 讲的是跨视图 hero 过渡而非同容器内 hover 胶囊，间接参考价值一般 |

未找到专门以 "macOS 26 工具栏 hover 胶囊" 为主题、独立成仓库的开源实现——这是一个新出现不久的系统级视觉细节，社区尚未沉淀出专门复刻的仓库；D 类的最佳做法是把 c/d 两类里的 segmented-control matchedGeometryEffect 代码改绑 `onHover` 而非寻找现成的"hover 版"实现。

---

## e. Liquid Glass 预 26 / 自渲染重实现（Metal / CIFilter / SwiftUI shader，backport）

| 仓库 | URL | 活跃度 | 语言/框架 | macOS 26 | 公开 API | 许可证 | 技术要点 | 适用性 |
|---|---|---|---|---|---|---|---|---|
| DnV1eX/LiquidGlassKit | github.com/DnV1eX/LiquidGlassKit | 2026 活跃（README 内提及 2026-09-10 前后活动） | Swift, Metal shader | iOS 13–18 backport + iOS 26+ 重实现；**README 未提及 macOS 支持** | **否，明确使用私有 API `CABackdropLayer`**（虽提供"App Store-safe 备选方案"用公开渲染路径） | [未验证] | Metal shader 模拟折射/色散/菲涅尔反射/高光；用 `CABackdropLayer` 捕获背景做零拷贝桥接；备选路径改用根视图渲染 | **禁用**：项目明确使用私有 API（`CABackdropLayer`），直接触犯 nanoPod 禁私有 API 铁律；且是 iOS-only，无 macOS 支持证据。仅可读它"如何用 CIFilter 做折射/色散"的算法思路，绝不可引入其 CABackdropLayer 路径 |
| BarredEwe/LiquidGlass | github.com/BarredEwe/LiquidGlass | 2025-2026 | Metal shader, SwiftUI + UIKit | [未验证 macOS 支持，README 标题只提 SwiftUI/UIKit] | 声称"no screenshots, no boilerplate"，具体是否走公开 API 未验证 [未验证] | [未验证] | 自定义 Metal shader 做实时毛玻璃折射，不依赖系统截图机制 | 需二次抓取源码确认是否用了私有 CA 层；在未验证前不建议引入 |
| 官方 xcode-27-system-prompts 仓库（artemnovichkov）转载的 Apple SwiftUI/AppKit Liquid Glass 实现文档 | github.com/artemnovichkov/xcode-27-system-prompts | 持续更新（镜像 Xcode 27 beta 文档） | 官方文档转载 | 是 | 是（官方 API 文档原文） | 未知（第三方镜像官方文档，版权归 Apple） | 非渲染库，是 Apple 官方 SwiftUI/AppKit Liquid Glass 实现指南的可搜索镜像 | 最安全的参考：内容等同官方文档，公开 API，无许可证风险；适合作为 API 用法的补充检索源 |

结论：e 类里能查到的"重实现/backport"仓库几乎都伴随私有 API 使用（`CABackdropLayer` 等）或平台仅限 iOS，与 nanoPod 的"禁私有 API + macOS 悬浮面板"要求直接冲突。e 类的正确用法是只读它们的 **CIFilter 折射/色散算法**（数学层面，非 API 调用），自行用公开 `CIFilter` API 重新实现,不整体引入这些库。

---

## f. Apple 官方样例代码

| 名称 | URL | macOS 26 | 公开 API | 许可证 | 技术要点 | 适用性 |
|---|---|---|---|---|---|---|
| Landmarks: Building an app with Liquid Glass | developer.apple.com/documentation/SwiftUI/Landmarks-Building-an-app-with-Liquid-Glass | 是（SwiftUI，官方样例通常含 iOS/macOS 双 target） | 是，官方一手示例 | Apple 官方样例许可（可参考不可整体商用分发） | 官方对 `GlassEffectContainer`/`glassEffectID`/系统与自定义 Liquid Glass 混用的权威范例 | **最高优先级参考**：这是本次调研里唯一确认为官方、macOS 可用、100% 公开 API 的样例，C1/C2 morph 动效应首先对照这份样例的容器嵌套与 namespace 用法 |
| AppKit-Implementing-Liquid-Glass-Design.md（xcode-27-system-prompts 镜像） | github.com/artemnovichkov/xcode-27-system-prompts/blob/main/AdditionalDocumentation/AppKit-Implementing-Liquid-Glass-Design.md | 是 | 是 | 第三方镜像官方文档 | AppKit 专属的 Liquid Glass 实现指南（`NSGlassEffectContainerView` 等），补足 SwiftUI Landmarks 样例未覆盖的 AppKit 细节 | 对 nanoPod（AppKit NSPanel 为主）比 SwiftUI 样例更直接相关，建议与 Landmarks 样例对照读 |

未找到 Apple 官方专门针对 **AppKit 完整应用**（而非文档片段）的 Liquid Glass 样例工程——WWDC25 Session "Build an AppKit app with the new design"（developer.apple.com/videos/play/wwdc2025/310/）有配套讲解但未确认独立可下载工程，标 [未验证]。

---

## g. "三时钟解耦过渡" / "转场前预热目标视图 ~20ms" 相关动画库

| 仓库 | URL | macOS 支持 | 许可证 | 是否提及三时钟解耦/预热思路 | 适用性 |
|---|---|---|---|---|---|
| EmergeTools/Pow | github.com/EmergeTools/Pow | **是**，README 明确列 iOS 15+/macOS 12+/Mac Catalyst 15+/visionOS | **MIT** | **否**，抓取的 README 未出现"三时钟"或"预热/pre-seed"表述；Pow 的机制是 SwiftUI transition + Change Effect（值变化触发一次性效果），本质是单时钟的声明式触发，不是几何/内容/材质三通道分离调度 | macOS 支持+MIT 许可证使其是 g 类里唯一可直接依赖的库，但它解决的是"值变化后触发装饰性特效"，与我们需要的"几何 125-150ms / 内容 20-80ms / 材质 270-350ms 三通道错峰"调度模型不是一回事，不能指望它自带这个能力，需要自己在 Pow 之外手写调度层 |
| Motion（家族名，未定位到确切仓库） | [搜索未返回明确仓库地址] | [未验证] | [未验证] | [未验证] | 本次搜索未能定位到与"Motion" 动画库同名且描述匹配"三时钟解耦"的活跃 GitHub 仓库，标记为**搜索无结果**，不编造 |
| Wave（家族名，未定位到确切仓库） | [搜索未返回明确仓库地址] | [未验证] | [未验证] | [未验证] | 同上，搜索无结果，不编造 |
| Inferno（家族名，未定位到确切仓库） | [搜索未返回明确仓库地址] | [未验证] | [未验证] | [未验证] | 同上，搜索无结果，不编造 |

结论：g 类关键词（"三时钟解耦转场"、"pre-seed target view ~20ms"）在本次搜索中**没有在任何开源动画库的 README/文档里直接命中**——这更像是我们项目内部（contract 文档）总结出的调度模型，而非业界通用命名概念。Motion/Wave/Inferno 三个库名未能通过本次搜索定位到确切、可核实的 GitHub 地址，为避免编造仓库,本报告不列出具体 URL；如需要，应作为独立后续任务用 GitHub 仓库搜索（而非通用 WebSearch）直接按库名精确查找。

---

## 候选优先级

### C1（边缘隐藏/peek 胶囊 morph）—— 值得深入精读的 5 个仓库/资料，按优先级：

1. **Apple 官方 AppKit-Implementing-Liquid-Glass-Design 文档**（xcode-27-system-prompts 镜像）—— 唯一确认公开 API、AppKit 原生、直接对应我们 NSPanel 架构的权威资料，应第一个读。
2. **NSGlassEffectContainerView 官方文档**（developer.apple.com）—— `spacing` 属性控制融合距离，直接决定我们能否用它做胶囊↔卡片的邻近融合，是 C1 实现前必须确认的 API 语义来源。
3. **altic-dev/DynamicNotchKit**（MIT，macOS 13+）—— 明确同时支持"真实 notch"与"无 notch 的 floating 降级"，这个抽象方式与我们"边缘隐藏 vs 展开"两态设计思路最接近，且许可证无阻碍，值得读它的窗口管理源码。
4. **TheBoredTeam/boring.notch**（GPL-3.0，需注意协议）—— 生态里最成熟、issue/PR 最活跃的边缘胶囊 hover 展开实现，虽 GPL 不可直接抄代码，但读它的 hover 触发时序、展开/收起状态机设计仍有参考价值。
5. **官方 Landmarks: Building an app with Liquid Glass 样例**——SwiftUI 侧的权威 morph 范例，即使我们主渲染在 AppKit，仍可用来核对 `glassEffectID` + namespace 的官方推荐用法，避免自造不兼容的 morph 触发逻辑。

### C3（微交互：按钮/hover 胶囊等）—— 值得深入精读的 3 个仓库/资料，按优先级：

1. **nilcoalescing 博客「Custom Segmented Control With MatchedGeometryEffect」**——无许可证顾虑的完整代码片段，直接演示胶囊跟随选中项移动，是改造为 hover 版本的最短路径。
2. **gahntpo/MatchedGeometryExamples**——多场景 demo 合集，可对照挑选与我们按钮排列方式最接近的 case 再本地化。
3. **EmergeTools/Pow**（MIT，明确 macOS 12+ 支持）——虽不解决三时钟调度，但其 press/value-change 触发的轻量特效模式可直接作为按钮微交互的补充层（比如按下反馈），且许可证和平台都无阻碍，是本次调研里少数可以直接 `import` 使用的库。

---

## 未覆盖 / 搜索无结果的类别

- g 类的 Motion / Wave / Inferno 具体仓库地址未定位到，已如实标注，未编造。
- a 类中独立成仓库、专门演示 AppKit `NSGlassEffectContainerView` pill↔card morph 的第三方开源项目未找到，只有官方文档覆盖。
- d 类中没有找到专门复刻"macOS 26 工具栏 hover 胶囊"这一具体系统细节的独立仓库。
- c 类中没有找到 macOS 原生（非 iOS 移植）的 liquid press-scale 按钮库。
