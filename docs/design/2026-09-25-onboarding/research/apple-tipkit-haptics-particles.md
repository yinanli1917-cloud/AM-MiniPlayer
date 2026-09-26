# 调研报告 3：TipKit / NSPopover / 子窗口层级 / Haptic / HIG / Reduce Motion / 粒子 / 进度环

调研代理：Sonnet 5（research），2026-09-25。一手来源以本机 SDK 头文件与 swiftinterface 为准（路径见各条）；developer.apple.com 正文为 JS 渲染，WebFetch 只拿到标题，HIG 引文来自搜索引擎索引快照，URL 为官方页面但未逐句核对上下文。

## 1. TipKit 在 macOS

结论：TipKit 在 macOS 14.0 起就有完整能力，且有专属 AppKit 呈现类 `TipNSPopover` 与 `TipNSView`，两者都能锚定到 `NSStatusItem.button`。核心开放风险：SwiftUI `.popoverTip` 在 nonactivating / 非 key 的 NSPanel 里的表现没有直接测试报告，只有同源风险的间接证据（NSPopover 在菜单栏 app 里普遍需要显式 `becomeKey` / `NSApp.activate`）。

- `.popoverTip(_:arrowEdge:action:)`：macOS 14.0 起可用；macOS 26.0 新增带 `isPresented: Binding<Bool>?` + `attachmentAnchor: PopoverAttachmentAnchor` 的重载。来源：`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/TipKit.framework/Versions/A/Modules/TipKit.swiftmodule/arm64e-apple-macos.swiftinterface` 第 255–310 行。
- 呈现机制是否为 NSPopover：官方未取得原文；社区共识 SwiftUI `.popover()` 在 macOS 由 `NSPopover` 承载，TipKit 的 AppKit 版直接叫 `TipNSPopover: NSPopover`，推断同路。
- 已知问题：官方论坛报告 SwiftUI `ToolbarItem` 里的按钮不显示 tip（developer.apple.com/forums/thread/735961、760594）。未查到针对 nonactivating / 非 key NSPanel 的直接报告。
- `TipNSPopover: NSPopover`，macOS 14.0+，AppKit 专属。用法 `TipNSPopover(tip).show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)`——与锚定 `NSStatusItem.button` 的标准 NSPopover 调用一致。同一 swiftinterface 第 1015 行起。
- `TipNSView: NSView`，macOS 14.0+，不带 popover 外壳的内嵌形态。
- 样式面：`backgroundColor` / `cornerRadius` / `imageSize` / `viewStyle`（14.0+），`imageStyle`（15.0+），`backgroundStyle`（26.0+）。
- `TipGroup`：**macOS 15.0+**（不是 14.0）。`TipGroup.Priority` 有 `.firstAvailable` / `.ordered`；`currentTip` / `currentTipUpdates` 同 15.0+。第 709–770 行。
- `#Rule` 宏：14.0+；macOS 26.0 新增 `Rule.CompoundOperation`（`.conjunction` / `.disjunction`）。
- `Tip.invalidate(reason:)`：14.0+；`InvalidationReason`：`.actionPerformed`（14.0+）、`.displayCountExceeded`（14.0+）、`.displayDurationExceeded`（15.0+）、`.tipClosed`（14.0+）。
- `Tip.statusUpdates: AsyncStream<Status>`、`shouldDisplay` / `shouldDisplayUpdates`：14.0+。macOS 26.0 新增 `Tip.resetEligibility() async`。
- `Tips.configure`：`.datastoreLocation(...)`（14.0+）、`.displayFrequency(.immediate/.hourly/.daily/.weekly/.monthly)`（14.0+）、`.cloudKitContainer`（15.0+）。`Tips.resetDatastore()`：14.0+。单条绕开节流：`Tips.IgnoresDisplayFrequency`。
- 「用户真操作后自动关闭并推进下一条」：可行且是 TipKit 设计内的模式——自己侦测到真实操作后调 `tip.invalidate(reason: .actionPerformed)`，配合 `TipGroup(.ordered)` 让下一条成为 `currentTip`。硬门槛 `TipGroup` = macOS 15.0。
- `TipViewStyle` 协议（14.0+）：`makeBody(configuration:)`，configuration 暴露 `.tip` / `.image` / `.title` / `.message` / `.actions`——可以完全重写泡泡内部渲染（进度环、自定义按钮可画进去），但改不了「泡泡怎么弹出 / 朝哪边弹」的 AppKit 定位算法。`.tipViewStyle` / `.tipBackground` / `.tipCornerRadius` / `.tipImageSize` / `.tipBackgroundInteraction` 均 14.0+。
- 未查到「同一时刻系统强制只显示一条」的官方表述；已确认机制是 `displayFrequency` 节流新 tip 出现的最小间隔。
- 数据存储：二手来源一致——默认 `[Application Support]/.tipkit/tips-store.db`，沙盒下落在容器内。

## 2. NSPopover 在 macOS 26

结论：技术上可行，但「不抢焦点」与「NSPopover 常依赖 key window / app 激活」有根本张力，且 `.semitransient` 明确禁止 positioningView 处于子窗口内。

- 来源：`.../AppKit.framework/Headers/NSPopover.h`。
- `behavior`：`.applicationDefined`（默认，"Your application assumes responsibility for closing the popover."）、`.transient`（"AppKit will close the popover when the user interacts with a user interface element outside the popover."）、`.semitransient`（"...Semi-transient popovers cannot be shown relative to views in other popovers, nor can they be shown relative to views in child windows."）。
- `show(relativeTo:of:preferredEdge:)`：header 详述锚点回退算法——优先 `preferredEdge`，放不下则对侧，再放不下任意边，最后居中兜底并失去锚点。从 `NSStatusItem.button` 弹出是社区标准写法（shaheengandhi.com/using-nspopover-with-nsstatusitem/）。
- key window：多篇独立博客（techconcepts.org、swiftyn.com）汇报菜单栏 app 中 NSPopover 常见「静默不显示 / 不可交互」，根因是 app / 窗口未成为 key；修法是显式 `becomeKey` 或 `NSApp.activate(ignoringOtherApps:)`。`.nonactivatingPanel` 里的 TextField 点了没反应也是同一根因。
- `hasFullSizeContent`（macOS 14.0+）：内容可延伸进箭头区域。NSPopover 本身不提供材质属性，毛玻璃要自己塞 NSVisualEffectView。
- macOS 26 Liquid Glass 下 NSPopover 默认外观变化：未查到 AppKit 层面专门记录。

## 3. 子窗口方案与窗口层级

结论：关键 API 全在 `NSWindow.h`；层级用 `CGWindowLevel.h` 原始数值一锤定音——`.statusBar` / `.popUpMenu` 能盖过菜单栏本身。这是「不抢焦点」和「贴着菜单栏图标弹卡片」两个约束都不冲突的方案。

- 来源：`.../AppKit.framework/Headers/NSWindow.h`：`addChildWindow(_:ordered:)` / `removeChildWindow(_:)`（第 608–609 行）、`childWindows`（610）、`parentWindow`、`level`（504）、`hasShadow`（514）、`isOpaque`（517）、`ignoresMouseEvents`（794）、`backgroundColor`（401，可 `.clear` 配合 `isOpaque=false`）。
- 子窗口跟随父窗口移动 / 是否继承 level / 父窗口 miniaturize 时的行为：官方原文未取得；长期社区认知——子窗口跟随父窗口移动与排序，但**不自动继承 level**（需单独设置）；miniaturize 是常提到的坑点。建议实测。
- 层级数值（一手，`.../CoreGraphics.framework/Versions/A/Headers/CGWindowLevel.h`）：

  | 常量 | 值 | NSWindow.Level |
  |---|---|---|
  | kCGNormalWindowLevel | 0 | .normal |
  | kCGFloatingWindowLevel | 3 | .floating |
  | kCGModalPanelWindowLevel | 8 | .modalPanel |
  | kCGUtilityWindowLevel | 19 | .utility |
  | kCGDockWindowLevel | 20 | .dock |
  | kCGMainMenuWindowLevel | 24 | .mainMenu（菜单栏本身） |
  | kCGStatusWindowLevel | 25 | .statusBar |
  | kCGPopUpMenuWindowLevel | 101 | .popUpMenu |
  | kCGOverlayWindowLevel | 102 | — |
  | kCGScreenSaverWindowLevel | 1000 | .screenSaver |

  `NSWindow.h` 第 198 行：`static const NSWindowLevel NSStatusWindowLevel = kCGStatusWindowLevel;`。结论：卡片窗口 level 设到 `.statusBar` 或更高即可叠在菜单栏之上。
- 状态栏图标屏幕矩形：`statusItem.button?.window?.frame` 或 `button.convert(button.bounds, to: nil)` + `window.convertToScreen(_:)`——标准 AppKit 套路（本次未逐字核对 header，API 二十多年未变）。

## 4. 触控板 Haptic

结论：唯一途径是 `NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime:)`；纪律是「反馈要伴随屏幕上真实发生的视觉变化」；用户手不在板上时系统自动吞掉请求。

- 来源：`.../AppKit.framework/Headers/NSHapticFeedback.h`（全文已读）。
- `NSHapticFeedbackPattern`（10.11+）：`.generic`（"when none of the other options apply"）、`.alignment`（"Alignment of any type: guides, best fit, etc..."）、`.levelChange`（"Changes in discrete pressure zones. Used by NSMultiLevelAcceleratorButtons."）。
- `NSHapticFeedbackPerformanceTime`：`.default`（= `.drawCompleted`）、`.now`、`.drawCompleted`（等下一次屏幕绘制 + layer 渲染完成后同步触发）。
- 协议原文："Always use the feedback pattern that describes the user action. In most cases, haptic feedback should occur with something on screen such as the appearance of an alignment guide." "The system reserves the right to suppress this request. For example, Force Touch trackpads will not perform the feedback if the user isn't currently touching the trackpad."
- `defaultPerformer` 原文提示："This device may change during the life of your application. Always request the defaultPerformer when you need to perform feedback"——不要缓存引用。
- HIG「Playing haptics」页原文：未取得。

## 5. HIG 章节摘录（索引快照）

**Onboarding**（developer.apple.com/design/human-interface-guidelines/onboarding）
- "if you try to teach too much, people can feel overwhelmed and may be less likely to remember what they learned."
- "design a brief, enjoyable experience that doesn't require people to memorize a lot of information. When onboarding is quick and entertaining, people are more likely to complete it."
- "People want to start using your app or game immediately after first launching it, whether they participate in an onboarding flow or skip it."
- "Consider providing a collection of context-specific tips instead of a single onboarding flow... A context-specific tip can also help people learn better because it lets them concentrate on a single action or task before encountering new information."

**Popovers**（.../popovers）
- "A popover's arrow should point as directly as possible to the element that revealed it."
- "never show a cascade or hierarchy of popovers, in which one emerges from another."
- "show one popover at a time, as displaying multiple popovers clutters the interface and causes confusion."

**Motion**（.../motion）
- "when Reduce Motion is turned on, Apple replaces large zoom animations and layered motion with simpler transitions, usually fades."
- "certain types of motion, such as scaling, spinning, or peripheral motion, cause dizziness or nausea for people with motion sensitivity."

**Launching**（.../patterns/launching）
- "At first launch, people want to dive right in; they don't want to be required to read a lot of content, provide a rating, or grant access to their private data before they get a sense of the experience."
- "avoid asking for setup information up front... postpone nonessential setup flows or customization steps and provide reasonable default settings."

**The menu bar**（.../the-menu-bar；HIG 无单独 Menu Bar Extras 页）
- "A menu bar extra exposes app-specific functionality using an icon that appears in the menu bar when your app is running, even when it's not the frontmost app."
- "When necessary, the system hides menu bar extras to make room for app menus."——锚定状态栏图标的卡片要处理「图标被系统临时挤掉」。

## 6. Reduce Motion / Reduce Transparency 读法

- SwiftUI（一手，SwiftUICore swiftinterface 约第 18425 行）：`EnvironmentValues.accessibilityReduceMotion` / `accessibilityReduceTransparency`，`@available(macOS 10.15, *)`。
- AppKit：`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`（true 时 "UI should avoid large animations, especially those that simulate the third dimension"）、`accessibilityDisplayShouldReduceTransparency`（true 时 "UI (mainly window) backgrounds should not be semi-transparent; they should be opaque"）。变化监听：`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`。

## 7. 礼花 / 粒子

结论：250×284 面板、0.8–1.2s、30–60 粒子量级三条路都能扛；优先 Canvas + TimelineView（自写或接 Vortex），因为「停止 = 从层级 / 驱动源移除」这条纪律与项目 banned-patterns 的动画排坑习惯一致，风险最低。

- CAEmitterLayer 一次性喷发标准做法（nshipster.com/caemitterlayer/）：keyframe 把 `birthRate` 从 1 降到 0（keyTimes `[0, 0.5, 1]`，values `[1, 0, 0]`），动画 delegate 结束时 `removeAllAnimations` + `removeFromSuperlayer`；`beginTime` 必须在显示前用 `CACurrentMediaTime()` 赋值否则 "it'll render with the wrong time space"。
- birthRate=0 后是否仍有渲染开销：**未查到权威数据**。按项目既有教训（resident CIGaussianBlur 静态行仍被合成器每帧求值）外推：动画结束后一定 `removeFromSuperlayer`，不要只置 0。
- SwiftUI `TimelineView(.animation(minimumInterval:paused:))` + 一个 `Canvas` 一次性绘制全部粒子；`paused: true` 即整体停止刷新。`.drawingGroup()` 可合成到 Metal-backed layer，是否叠加需实测。粒子数上限：未查到权威数字；影响性能的是「每帧重算 + 重画的粒子数 × 目标帧率」的乘积。
- Vortex（twostraws）：一手确认用 `TimelineView(.animation(minimumInterval: 1 / Double(targetFrameRate))) { Canvas { ... } }`，`macOS(.v12)`；一次性 burst 用 `VortexViewReader` 拿 `VortexProxy`；内置 confetti / fireworks 预设。来源：github.com/twostraws/Vortex/blob/main/Sources/Vortex/Views/VortexView.swift。
- ConfettiSwiftUI（simibac）：`macOS(.v11)`，每片彩纸是一个真实 SwiftUI View，30–60 片量级问题不大但比 Canvas 重。
- SPConfetti（ivanvorobei）：Package.swift 原文 `platforms: [.iOS(.v11), .tvOS(.v11)]`，不支持 macOS，排除。

## 8. 进度环

- `Circle().trim(from: 0, to: progress).stroke(style: StrokeStyle(lineWidth:, lineCap: .round)).rotationEffect(.degrees(-90))`——业界通用写法。
- `.contentTransition(.numericText())`：`ContentTransition` 基线 macOS 13.0+；`numericText(value: Double)` 重载 macOS 14.0+（一手，SwiftUICore swiftinterface 约第 16135–16148 行）。
- `.symbolEffect(.bounce)` / `.symbolEffect(.replace)`：`BounceSymbolEffect` / `ReplaceSymbolEffect` 均 `@available(macOS 14.0, *)`（一手，Symbols.framework swiftinterface 第 49–58、220–229 行）；`.contentTransition(.symbolEffect(.replace))` 同 14.0+。
- macOS 26 专属新动效 API：未查到；现有组合已是稳定方案。
