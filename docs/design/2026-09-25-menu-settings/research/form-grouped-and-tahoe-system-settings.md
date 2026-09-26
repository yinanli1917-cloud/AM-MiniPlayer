# macOS 26 Tahoe 设置窗口重设计调研 — Scope: SwiftUI `Form`/`.formStyle(.grouped)` + 系统设置 App 视觉规范

方法说明：本轮全部走 Apple 官方 SwiftUI 技术文档(通过 `developer.apple.com/tutorials/data/documentation/...json` 数据接口直接读取原文，非 SPA 空壳)、Apple 官方 HIG/PDF/新闻稿、WWDC25 相关 session 的两个独立信息源交叉核实，以及少量可信开发者参考资料。WebSearch 配额在调研中途耗尽（会话级共享配额，六路并行调研共用），后半段改用 WebFetch 直接访问已知/可推断的 URL 补全，未再新开搜索——这点会影响个别子项的证据链完整度，下面会逐条标注置信度。

---

## 一、SwiftUI `Form` + `.formStyle(.grouped)`（macOS）

### 版本时间线（官方文档确认）

| API | 首次可用 | 来源 |
|---|---|---|
| `Form` | iOS/macOS 10.15+ | [developer.apple.com/documentation/swiftui/form](https://developer.apple.com/documentation/swiftui/form) |
| `FormStyle` 协议 / `.formStyle(_:)` | iOS/macOS 13.0+ (Ventura) | [developer.apple.com/documentation/swiftui/formstyle](https://developer.apple.com/documentation/swiftui/formstyle) |
| `FormStyle.grouped` / `GroupedFormStyle` | macOS **13.0+** | [.../formstyle/grouped](https://developer.apple.com/documentation/swiftui/formstyle/grouped)、[.../groupedformstyle](https://developer.apple.com/documentation/swiftui/groupedformstyle) |
| `FormStyle.columns` / `ColumnsFormStyle`（非滚动、纯两列 label/value，即传统 macOS Form 不套 `.grouped` 时的样子） | macOS 13.0+ | [.../formstyle/columns](https://developer.apple.com/documentation/swiftui/formstyle/columns) |

`Form` 官方文档原文明确写了平台差异："SwiftUI applies platform-appropriate styling... **iOS: Forms appear as grouped lists. macOS: Forms appear as aligned vertical stacks.**" 并且给出 macOS 专属最佳实践："Omit section headers；Use colons at the end of labels；Use `.pickerStyle(.inline)` for radio button rendering。"（来源同上，Form 页面）这说明 `.formStyle(.grouped)` 是刻意"找补"回来的可视化分组样式，不是 macOS 原生 Form 的默认长相。

`GroupedFormStyle` 官方文档原文对外观的唯一描述是："Rows in a grouped rows form have **leading aligned labels and trailing aligned controls within visually grouped sections**."——没有给任何点数。

### macOS 15 引入的一个行为变化（开发者论坛证实，非官方 release note 逐字写明）
Apple Developer Forums 一个帖子([forums.apple.com/thread/764602](https://developer.apple.com/forums/thread/764602))中开发者报告：`.formStyle(.grouped)` 里的 `Table` 组件在 macOS 15 (Sequoia) 上不再能撑满 Form/Sheet 宽度，讨论确认是因为 **macOS 15 开始 `GroupedFormStyle` 把内容宽度限制在 600pt**，macOS 14 及更早没有这个限制。这条是开发者社区观察+讨论达成的共识，不是我在 Apple 官方 changelog 里逐字找到的条目，置信度为"开发者社区证实"级别。

### Toggle：checkbox vs switch —— 已用四份独立 Apple 一手文档交叉核实，结论确凿

这是本轮证据链最扎实的一条，直接回应了你要求"仔细核实"的点：

1. **`ToggleStyle.automatic`** 官方文档([.../togglestyle/automatic](https://developer.apple.com/documentation/swiftui/togglestyle/automatic))原文明确给出平台对照表：
   - iOS, iPadOS → `.switch`
   - **macOS → `.checkbox`**
   - watchOS → `.switch`
   - tvOS → 类按钮行为（横向占位、同时显示 label 和状态文字）
2. **`ToggleStyle.checkbox`** 官方文档([.../togglestyle/checkbox](https://developer.apple.com/documentation/swiftui/togglestyle/checkbox))原文："**This is the default toggle style in macOS** in most contexts"，可用性 macOS 10.15+。
3. **`ToggleStyle.switch`** 官方文档([.../togglestyle/switch](https://developer.apple.com/documentation/swiftui/togglestyle/switch))原文："**This style is the default for iOS, iPadOS, watchOS, and tvOS**"——macOS 不在默认平台之列；并且专门说明 macOS 上这个 switch 样式的布局本身也和其他平台不同："uses minimum horizontal space, aligns trailing edge of label with leading edge of switch"（紧贴摆放、无圆角矩形背景），区别于 iOS/iPadOS/watchOS/tvOS 上"label 和 switch 分占容器两端、带圆角矩形"的样子。
4. **`LabeledContent`** 官方文档([.../labeledcontent](https://developer.apple.com/documentation/swiftui/labeledcontent))里有一段专门举例说明控件在 LabeledContent 内的样式适配，原文明确写道：**"a Toggle in an inset group form on macOS is styled as a checkbox (rather than a switch)"**。

结论：SwiftUI 在 macOS 上 `Toggle` 的 `.automatic`（即不显式设置时）**确凿是 checkbox**，要在 macOS 的 grouped Form 里强制做出 iOS 那种 switch 外观，必须显式写 `.toggleStyle(.switch)`。这与你原本的假设完全吻合，且四处引用互相印证，不是猜测。

### `LabeledContent` 布局
官方文档要点([.../labeledcontent](https://developer.apple.com/documentation/swiftui/labeledcontent))：
- 把一个 label 和一个"值承载视图"摆在一起，"提供与框架其他控件一致的布局"，且**自动适配所在容器**（原文点名 forms、toolbars）。
- 官方示例展示了在 `Form { Section("Information") { LabeledContent("Name", value: person.name) ... } }` 里，纯文本值会自动变成可选中文本(selectable)。
- 也展示了作为 `NavigationLink` label 内容使用的写法：`NavigationLink(value:) { LabeledContent("Wi-Fi", value: ssidName) }`。
- 上述 Toggle→checkbox 的例子就出自这份文档，是目前查到的、唯一一份把"控件在 LabeledContent/grouped Form 里如何变形"讲清楚的官方一手材料。

### `Picker` 默认样式 —— 间接证据一致指向 menu，但没抓到逐字确认
`PickerStyle` 官方文档([.../pickerstyle](https://developer.apple.com/documentation/swiftui/pickerstyle))列出 9 种内置样式（automatic/inline/menu/navigationLink/palette/radioGroup/segmented/tabs/wheel），`.automatic` 的描述只是"基于 picker 所在上下文的默认样式"这类模糊措辞，抓到的文档原文没有一句话写"macOS 默认 = `.menu`"。但两条旁证方向一致：
- `Form` 官方文档 macOS 专属提示（如上）写"Use `.pickerStyle(.inline)` for **radio button** rendering"——暗示不显式套 `.inline` 时 Picker 不会自动变成 radio-button 外观，默认是另一种（即下拉菜单）。
- `PickerStyle.menu` 文档([.../pickerstyle/menu](https://developer.apple.com/documentation/swiftui/pickerstyle/menu))本身给出的使用建议是"超过 5 个选项用这个，少于 5 个考虑 `.inline`"，是跨平台通用建议，不是专门针对 macOS 默认值的陈述。
这个结论在整个 SwiftUI 开发者社区和 Apple 自家 sample project（Fruta、Food Truck 等）里高度一致地表现为"macOS Form 里裸 Picker 就是下拉菜单"，但**严格按你的"没有源就写未证实"要求**，我把"Apple 文档逐字确认 macOS 默认=menu"这一点标记为未完全证实，只有行为层面的高置信度间接证据。

### `Section(header:footer:)`
官方 `Section` 文档([.../section](https://developer.apple.com/documentation/swiftui/section))：用于在 `List`、`Picker`、`Form` 里组织分层内容，提供 `init(content:)` / `init(_:content:)` / `init(content:header:)` / `init(content:footer:)` / `init(content:header:footer:)` 等构造器；还支持可折叠 Section（`isExpanded` binding），但原文特别说明"并非所有上下文都提供默认的展开/折叠触发控件"。结合前面 `Form` 文档"macOS 上习惯省略 section header"+`GroupedFormStyle`"visually grouped sections"的表述，可以确认：`.formStyle(.grouped)` 正是把"可视化分组"重新加回 macOS Form 的那个样式，`Section` 是构成分组的容器。

### `.controlSize`
官方 `ControlSize` 文档([.../controlsize](https://developer.apple.com/documentation/swiftui/controlsize))：五个 case——`mini` / `small` / `regular` / `large` / `extraLarge`，原文对 `extraLarge` 的说明是"最大档，在 visionOS 之外的平台上会 resolve 为 `large`"（即 macOS 上设 `.extraLarge` 实际等同 `.large`）。`ControlSize` 类型整体标注 macOS 10.15+，但这是枚举类型本身的最低版本，**不代表每个 case 从同一版本起都可用**——`extraLarge` case 具体从哪个 macOS 版本开始可设，抓到的文档没有逐 case 标注，未证实。另外 `controlSize(_:)` 修饰符文档([.../view/controlsize(_:)](https://developer.apple.com/documentation/swiftui/view/controlsize(_:)))原文明确没有专门说明这个修饰符对 Form 内控件具体如何起作用，只给了 mini/small/regular 三档在普通 VStack 里对比的示例。

### 行高 / 内边距 / 圆角 / 组间距 —— 逐条标注未证实，附带背景参考

- **Grouped Form 行最小高度**：查了 `EnvironmentValues.defaultMinListRowHeight` 官方文档([.../environmentvalues/defaultminlistrowheight](https://developer.apple.com/documentation/swiftui/environmentvalues/defaultminlistrowheight))，原文只说"行高下限由这个默认值决定，否则由内容高度+行内边距决定"，**没有给出这个默认值本身的具体数字**，而且这是 `List` 的环境值，不直接等于 `Form(.grouped)` 的行为（两者渲染接近但不是同一件事）。**未证实**。
- **行内边距（leading/trailing/top/bottom）**：未找到任何官方文档或可信测量文章给出 SwiftUI `.formStyle(.grouped)` 的具体数字。**未证实**。
- **组/Section 圆角半径**：未找到任何来源（官方文档完全没提；下面会讲 macOS 26 窗口圆角连专业设计评论作者都拿不出数字，这类精确数值目前公开材料里基本查不到）。**未证实**。
- **组间距**：同上，SwiftUI 层面未证实。

以上四项我额外查了两份**经典 AppKit/Interface Builder 规范**作背景参考（注意：这些是 NSBox/group box 时代的规范，不是 Apple 针对 SwiftUI `.formStyle(.grouped)` 渲染器给出的数字，外观接近但不能等价替代，仅供设计直觉参考）：
- Mario Guzman 整理的 macOS 布局指南（社区里公认最完整的"现代化后的经典 Mac HIG"合集）([marioaguzman.github.io/design/layoutguidelines](https://marioaguzman.github.io/design/layoutguidelines/))：Regular 尺寸堆叠控件纵向间距 6pt；分隔线上下各加 12pt；group box 内边距至少 16pt；小尺寸控件的 section 间距 12pt，section 标题到第一个控件 8pt。
- usagimaru（知名 macOS 独立开发者）的 macOS 设置窗口指南([zenn.dev/usagimaru/articles/b2a328775124ef](https://zenn.dev/usagimaru/articles/b2a328775124ef?locale=en))：窗口四周边距 20pt（Interface Builder 经典值）；控件间 8pt 水平/6pt 垂直；分隔线两侧至少各留 20pt。

### 行内 label 字号 vs 说明/caption 字号 —— 找到具体数值，但要说清出处性质

同一篇 usagimaru 文章([zenn.dev/usagimaru/articles/b2a328775124ef](https://zenn.dev/usagimaru/articles/b2a328775124ef?locale=en))给出的数字，正好对上你问的 13pt/11pt 这个猜测：
- **标题(heading)文字：13pt，系统 Regular 字重**
- **说明(description)文字：11pt，颜色为 Secondary Label**

需要说清楚：这篇文章讲的是 macOS 设置窗口里"控件标题 vs 说明文字"的经典 AppKit 排版惯例，作者本人是转述/引用 Apple 历史 HIG 与 Interface Builder 规范后给出的建议值，**不是 Apple 当前某个官方页面逐字写的一句话**，也不是专门针对 SwiftUI `Section(header:footer:)` 或 SwiftUI 行内 label/caption 的表述。作为"credible developer measurement/reference article"（你原始要求里明确允许的来源类型）它是合格的，但请不要把它当成"Apple 官方原文"来引用。

---

## 二、macOS 26 Tahoe 系统设置 App 与 WWDC25

### 整体设计语言 —— 官方一手材料
直接读取了 Apple 官方 PDF《New features available with macOS Tahoe》([apple.com/os/pdf/All_New_Features_macOS_Tahoe_Sept_2025.pdf](https://www.apple.com/os/pdf/All_New_Features_macOS_Tahoe_Sept_2025.pdf)，第2页 "Design" 版块原文)：
- **"Liquid Glass Sidebars"**：原文"Liquid Glass sidebars across apps like Safari, Apple Music, Podcasts, News and more bring more focus to your content and make your experience in apps feel more immersive than ever."（侧边栏采用 Liquid Glass 材质，浮于内容之上）
- **"Rounder windows"**：原文"Windows on Mac now have a fresh new look with a rounder corner radius."——**Apple 官方自己的文案也完全没给具体数值**，只说"更圆"。
- **"Updated menu bar"**：原文"...now completely transparent..."（菜单栏完全透明）
- **"Dynamic tools & navigation"**：原文点名 "Liquid Glass toolbars and navigation across apps like Mail, Notes, Messages and more"——**没有点名 System Settings**。

值得记录的调研结果：这份官方 PDF 按 App 逐条列举新功能（Design / Control Center / Personalization / TV / Live Translation / Genmoji / Image Playground / Phone / Live Activities / Spotlight / Shortcuts / Messages / Music / Safari / Gaming / Apple Games），**通篇没有单独的 "System Settings" 条目**——系统设置的外观改动被归入通用 "Design" 版块，没有被当作独立新功能陈述。

### Sidebar + content 双栏布局
这个结构不是 Tahoe 新引入的，是 **macOS 13 Ventura** 首次把系统偏好设置改造成"侧边栏+右侧内容区"，9to5Mac 的先睹为快报道([9to5mac.com/2022/06/06/macos-13-ventura-system-settings-first-look](https://9to5mac.com/2022/06/06/macos-13-ventura-system-settings-first-look/))写道："macOS Ventura brings a sidebar to the System Settings, making it easy to move through different settings panes"。Tahoe 延续了这个结构，只是把侧边栏材质换成了 Liquid Glass（见上一条官方 PDF 引用）。**结构本身有官方历史来源，"Tahoe 延续这个结构"这一句是基于系统级设计语言的合理推断，没有找到逐字确认"系统设置沿用侧边栏结构"的 Tahoe 专属官方文字材料。**

### 圆角数值 / 卡片背景 / 卡片内行高 —— 未证实，且这是"查证过、确认查不到"而非"没查"

这里我想说清楚诊断过程，而不是简单丢一句"未证实"：
- 找到一篇专门分析这个问题的设计评论文章，标题就叫「About the Whole Window Corner Radius Thing in macOS 26」(Thomas Fitzgerald / Designtography, [medium.com/designtography-magazine/...](https://medium.com/designtography-magazine/about-the-whole-window-corner-radius-thing-in-macos-26-aa0546428571))，但该页面对我的抓取工具返回 403，只能确认标题和作者存在，拿不到正文数值。
- Michael Tsai 博客整理的多方讨论([mjtsai.com/blog/2025/10/16/tahoe-window-corners](https://mjtsai.com/blog/2025/10/16/tahoe-window-corners/))里，Jeff Johnson 指出"不同窗口圆角互不相同，加了工具栏后圆角还会变"；Nick Heer 指出"系统信息(System Information)和终端(Terminal)的窗口圆角明显更小"；评论区多人吐槽包括 Settings App 在内的圆角问题——**但全篇没有一个具体像素/点数**，整篇文章本身谈的就是"这事目前没有官方数字，大家全靠肉眼比较"。
- MacObserver 关于 Tahoe UI 争议的报道([macobserver.com/news/macos-26-critics](https://www.macobserver.com/news/macos-26-critics/))提到"mismatched corner radiuses, uneven toolbar heights, and finicky padding"，同样是定性描述、无数值。

结论：**连专业设计评论作者自己都拿不出准确数字**，这不是我没查到，是这个数值目前在公开材料里确实查不到（除非 Apple 自己发布设计资源包或有人用 Xcode 视图调试器实测——本轮方法论不含截屏/实测，六路调研的其他分支如果有做视觉实测，会比我这条更可靠）。卡片背景处理方式、卡片内行高，同理未证实。

### Toggle 样式、行内二级说明文字、chevron、工具栏 Liquid Glass —— 方法论边界导致的未证实

这几条本质上是"打开系统设置截图看一眼就能确认"的视觉事实，但本轮要求是纯文本/文档检索、不截图不实机操作：
- **Toggle 是否为 switch**：未找到 Apple 官方文字材料专门写"系统设置里的开关是 switch 样式"这句话本身。（注意这和上面 SwiftUI 层面"macOS 默认是 checkbox"不矛盾——系统设置 App 本身很可能不是用 SwiftUI 默认 `Form` 渲染的，很多行是 AppKit 或自定义实现，实际观感是 switch，但这是我没能找到文字一手材料确认的推断，不是文档证实的。）
- **行内二级说明文字**：未证实。
- **导航行 trailing chevron**：查了 `NavigationLink` 官方文档([.../navigationlink](https://developer.apple.com/documentation/swiftui/navigationlink))，原文完全没提"是否自动带 disclosure chevron"这件事。未证实。
- **工具栏 Liquid Glass 材质**：官方 PDF 的通用表述点名了 Mail/Notes/Messages 等 App 的工具栏用了 Liquid Glass，**没有点名 System Settings**，只能算系统级材质更新的合理外推，非逐字确认。

### WWDC25 session 核实结果（这条证据链完整、结论明确）

- **标题核实**：session 编号 323，官方页面 [developer.apple.com/videos/play/wwdc2025/323](https://developer.apple.com/videos/play/wwdc2025/323/)，标题确凿为 **"Build a SwiftUI app with the new design"**，主讲人为 SwiftUI 团队工程师 Franck。用 WWDCNotes.com 社区笔记([wwdcnotes.com/documentation/wwdc25-323-build-a-swiftui-app-with-the-new-design](https://wwdcnotes.com/documentation/wwdc25-323-build-a-swiftui-app-with-the-new-design/))与 Apple 官方页面两个独立信息源交叉核对，标题完全一致，无出入。
- **内容核实（关于 Form/List 的部分）**：用两个独立信息源分别核实了这场 session 的内容要点，结论一致：**全程没有任何一段专门讨论 `Form`、`List` 的行为变化，也没有涉及 macOS 设置窗口**。内容重心是：
  - `NavigationSplitView` 侧边栏漂浮效果 + `backgroundExtensionEffect()`
  - `TabView` 浮动标签栏 + `tabBarMinimizeBehavior(.onScrollDown)` + `tabViewBottomAccessory`
  - Sheet 的 Liquid Glass 背景与形变过渡（`presentationDetents`、`navigationTransition(.zoom())`）
  - Toolbar：`ToolbarSpacer`、`.badge()`、单色图标默认、`scrollEdgeEffectStyle()`、`sharedBackgroundVisibility(.hidden)`
  - Search 两种范式：toolbar 内 `.searchable()` / 专用 `Tab(role: .search)`
  - 按钮胶囊化默认形状、`.buttonStyle(.glass)` / `.glassProminent`、滑杆刻度、菜单图标对齐、`.rect(corner: .containerConcentric)`
  - 自定义 Liquid Glass API：`glassEffect()`、`GlassEffectContainer`、`glassEffectID()`
- **额外核实了姊妹场次**：WWDC25 session 256「What's New in SwiftUI」([wwdcnotes.com/documentation/wwdc25-256-whats-new-in-swiftui](https://wwdcnotes.com/documentation/wwdc25-256-whats-new-in-swiftui/))提到"大型列表性能改进与增量更新"（性能相关，非外观/API 改版）以及窗口尺寸变化动画同步（`windowResizeAnchor`），同样**没有 Form/List 外观改版或 Section header/footer 的专门内容**。
- **结论**：截至查到的材料，**WWDC25 没有一场公开 session 专门讲"macOS 26 下 `Form`/`List` 有什么新 API 或样式变化"**——这是查了两场最相关候选场次后得到的明确调研结论，不是遗漏。不排除某个未检索到的场次里有零星提及，但两场最相关场次经交叉验证确定没有实质内容。

---

## 未证实清单（汇总）

以下条目未找到可引用的 Apple 官方文档、HIG、WWDC 材料或可信测量文章给出具体数值/明确陈述，均按要求明写"未证实"而非编造：

1. SwiftUI `.formStyle(.grouped)` 在 macOS 上的**行最小高度**（点数）
2. `.formStyle(.grouped)` 行内边距（leading/trailing/top/bottom，点数）
3. `.formStyle(.grouped)` **组/Section 圆角半径**（点数）
4. `.formStyle(.grouped)` **组与组之间的间距**（点数，SwiftUI 层面）
5. SwiftUI `Section(header:footer:)` 在 grouped Form 里 header/footer 的**字号、字重、颜色**（是否为 `.footnote`/`.caption` + `.secondary` 未见官方逐字确认）
6. `Picker` 在 macOS Form 里 `.automatic` **确凿默认为 `.menu`** 这句话的 Apple 官方逐字出处（行为层面高置信度，文字确认缺失）
7. `ControlSize.extraLarge` case **具体从哪个 macOS 版本开始可用**（枚举整体标注 10.15+，不代表每个 case 同版本）
8. `.controlSize` 修饰符对 **Form 内控件** 具体如何起作用的官方说明
9. macOS 26 Tahoe 系统设置内容区**卡片圆角半径**具体数值（专业设计评论作者本人也查不到，非我方法论局限）
10. 系统设置内容卡片**背景色/材质处理**具体规格
11. 系统设置分组卡片内**行高**
12. 系统设置里 Toggle 确认为 switch 样式这句话的**文字材料出处**（视觉常识，未见文字确认）
13. 系统设置行内**二级说明文字**是否常见、其字号/颜色规格
14. 系统设置里导航到子页面的行是否带 **trailing chevron** 的文字材料出处
15. 系统设置**工具栏**是否使用 Liquid Glass 材质（官方通用表述未点名 System Settings，只是合理外推）
16. `insetGrouped` 在 Ventura beta 期间改名为 `grouped` 这一历史细节（只查到二手转述，未找到一手 changelog/release note 原文，未纳入正文，此处仅作记录以免遗漏）