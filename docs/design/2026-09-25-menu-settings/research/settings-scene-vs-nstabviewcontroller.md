# 调研结果:SwiftUI Settings scene 与 NSTabViewController toolbar-tabs

## 一、SwiftUI `Settings` scene(macOS 13+ 问的,实际 macOS 11+ 就有)

**TabView 自动变成 toolbar 式分页 tab(图标在上、文字在下)**
- 这是 `Settings` scene 专属行为,不是 `TabView` 本身的能力。Apple Frameworks Engineer 在官方开发者论坛的原话:"SwiftUI's Settings scene is designed to help you build a first-class Mac settings experience that follows Apple's Human Interface Guidelines... Toolbars within Settings scenes use a style appropriate for a typical macOS settings window, which displays centered tabs to group related settings."(来源:https://developer.apple.com/forums/thread/810793 )这段回复同时确认这个居中 tab 样式是刻意强制的设计决定,不能通过 `.toolbar` placement 改成靠边。
- 独立来源印证同一结论:同一 `TabView` 放进 `WindowGroup`(主窗口)只显示朴素样式,放进 `Settings` scene 才有这种"好看的 tab"——这是社区反复抱怨的现象(来源:https://developer.apple.com/forums/thread/707668,原帖作者原话 "if we use a TabView in a Preferences scene you get nice looking tabs, whereas if we use a TabView in the main scene, the tabs are plain")。另一篇博客独立确认:"TabView on macOS inside Settings displays the tab items above the main content."(来源:https://www.swiftyplace.com/blog/tabview-in-swiftui-styling-navigation-and-more )
- 不需要新 API:老写法 `.tabItem { Label("Profile", systemImage: "person.crop.circle") }`(macOS 11 时代写法)和新写法 `Tab("General", systemImage: "gear") { ... }`(新 `Tab` builder)在 `Settings` scene 里都能触发这个 toolbar-tab 样式。老写法示例来源:https://serialcoder.dev/text-tutorials/macos-tutorials/presenting-the-preferences-window-on-macos-using-swiftui/ ;新写法示例来自 Apple 官方 `Settings` 文档自带的代码样例(来源:https://developer.apple.com/documentation/swiftui/settings ,通过 `tutorials/data` JSON 端点取到)。

**窗口标题是否自动跟随选中 tab 的标签**
- 没找到任何来源明确证实或证伪。Apple 官方 `Settings` 文档页面的 discussion 正文没提这点;上述几篇独立博客/论坛帖也都没提。列入文末"未证实"。

**`SettingsLink`**
- 来源:Apple 官方文档 JSON(https://developer.apple.com/documentation/swiftui/settingslink )。
- 引入版本:**macOS 14.0+**,仅 macOS 平台可用。
- 声明:`nonisolated struct SettingsLink<Label> where Label : View: View`。
- 作用:点击后打开 app 的 `Settings` 窗口;如果已经开着就带到前台。
- 两个初始化方法:`init()`(用系统默认 label)、`init(label: () -> Label)`(自定义 label)。用法示例(来源:https://captainswiftui.substack.com/p/expanding-app-options-on-macos ):
```swift
SettingsLink {
    Image(systemName: "gear")
        .font(.largeTitle)
}
```
- 相关 API:`OpenSettingsAction`、`EnvironmentValues.openSettings`(等效的命令式写法,`@Environment(\.openSettings) private var openSettings` 然后 `openSettings()`)、`DefaultSettingsLinkLabel`(默认 label 类型)。
- 这个对 nanoPod 有直接意义:`SettingsLink`/`openSettings` 是 SwiftUI 侧"打开 Settings 窗口"的标准入口,但**它要求 app 声明了 `Settings` scene**——nanoPod 现在是纯 `NSApplicationDelegate` 架构、没有 `App`/`Settings` scene,所以这条 API 目前对 nanoPod 不适用,除非额外接入一个 `Settings` scene(见下文第二部分,这也是为什么 NSTabViewController 路线更贴合 nanoPod 现状)。

**`Settings` scene 默认窗口尺寸 / 是否可调整大小**
- 没有找到"默认尺寸是 XxY"这种明确写死的数值。Apple 官方文档自己的代码示例用的是 `.scenePadding()` + `.frame(maxWidth: 350, minHeight: 100)` 去约束内容尺寸(来源同上,Apple 官方 `Settings` 文档 JSON)。
- 独立来源印证"没有固定默认尺寸,靠内容 frame 决定窗口大小"这个结论:"It's necessary to give the TabView a certain width and height, as that's going to be the size of the Preferences window."(来源:https://serialcoder.dev/text-tutorials/macos-tutorials/presenting-the-preferences-window-on-macos-using-swiftui/ ,该教程用 `.frame(width: 450, height: 250)`)
- 是否默认可拖拽调整大小:没找到明确来源正面确认或否定,列入"未证实"。

---

## 二、重点:NSTabViewController + `tabStyle = .toolbar`(AppKit 原生等价物)

nanoPod 不用 `App`/`Settings` scene,结论是:**能拿到几乎一样的 toolbar-tab 外观(图标在上文字在下),但"窗口标题自动跟 tab 走"和"切 tab 自动带动画地改窗口高度"这两条都不是白送的——业界所有严肃实现都是手写代码做的,不是 `NSTabViewController` 自带。** 逐条证据如下。

### 2.1 最简代码骨架 + 真实 API 名
```swift
let tabVC = NSTabViewController()
tabVC.tabStyle = .toolbar                 // NSTabViewController.TabStyle

let generalVC = NSHostingController(rootView: GeneralSettingsView())
let generalItem = NSTabViewItem(viewController: generalVC)
generalItem.label = "General"
generalItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
tabVC.addTabViewItem(generalItem)
// 对 Appearance / Diagnostics / About 重复

let window = NSWindow(contentViewController: tabVC)
```
API 名称核对来源:Apple 官方 `NSTabViewController` 文档(https://developer.apple.com/documentation/appkit/nstabviewcontroller ),确认存在:`tabStyle`、`tabView`、`transitionOptions`、`canPropagateSelectedChildViewControllerTitle`、`tabViewItems`、`tabViewItem(for:)`、`addTabViewItem(_:)`、`insertTabViewItem(_:at:)`、`removeTabViewItem(_:)`、`selectedTabViewItemIndex`,以及委托方法 `tabView(_:shouldSelect:)` / `tabView(_:willSelect:)` / `tabView(_:didSelect:)`。`addChild(_:)`/`insertChild(_:at:)` 也会自动生成对应的默认 `NSTabViewItem`。

### 2.2 `NSTabViewController.TabStyle` 全部取值(macOS 10.10+ 引入,来源同上文档 JSON)
| 取值 | 说明 |
|---|---|
| `.segmentedControlOnTop` | **`tabStyle` 的默认值**。segmented control 排在顶边 |
| `.segmentedControlOnBottom` | segmented control 排在底边 |
| `.toolbar` | 自动把 tab 塞进窗口 toolbar;controller 接管窗口 toolbar 并把自己设成 toolbar 的 delegate |
| `.unspecified` | controller 不提供切换 UI,app 自己提供控件(如 `NSSegmentedControl`/`NSPopUpButton`)并绑定到 controller |

**注意**:默认值是 `.segmentedControlOnTop`,不是 `.toolbar`——nanoPod 要拿到 System Settings 那种图标在上文字在下的外观,必须显式设 `tabStyle = .toolbar`。

### 2.3 `.toolbar` 到底自动到什么程度

**tab 本身的 toolbar 外观:确认是全自动的。** WWDC 2014 Session 212《Storyboards and Controllers on OS X》原话(来源:https://asciiwwdc.com/2014/sessions/212 ,ASCIIwwdc 逐字稿):"There's the toolbar style. That's all you have to do. You set the tab style to toolbar. The TabViewController will create the toolbar on your behalf and place it in the window as the toolbar; you're done." 同一段还提到一个隐藏机制:如果你不显式设 `tabViewItem.image`,系统会"look at the class name of the view controller and try and find imagery sources with that same name"来自动找图标——这条对 nanoPod 是个坑:用 `NSHostingController<GeneralSettingsView>` 包 SwiftUI 视图时,运行时类名是泛型具体化后的名字,几乎不可能匹配到项目里起的图片资源名,所以**必须显式设置每个 `NSTabViewItem` 的 `.image` 和 `.label`,不能依赖自动推断**(这条推断是我把 WWDC 讲的机制和 `NSHostingController<T>` 泛型类名的性质结合得出的合理外推,WWDC 原话本身没有点名 `NSHostingController` 这个反例)。

**窗口标题跟随选中 tab:不是自动的,要么自己写代码,要么自己建绑定。**
- `NSTabViewController` 自己有个 `.title` 属性,可以通过 `canPropagateSelectedChildViewControllerTitle`(`Bool`,**默认 `true`**,macOS 10.10+)让它跟随选中的子 view controller 的 `.title`(来源:Apple 官方文档 JSON,https://developer.apple.com/documentation/appkit/nstabviewcontroller/canpropagateselectedchildviewcontrollertitle )。**但这只更新 `NSTabViewController` 自己的 `.title` 属性,不会自动写进真实窗口的标题栏文字。** 窗口的 `.title` 要单独绑定:"The contentViewController only controls the contentView, and not the title of the window. The window title can easily be bound to the contentViewController with the following: `[window bind:NSTitleBinding toObject:contentViewController withKeyPath:@"title" options:nil]`"(来源:WebSearch 汇总的开发者问答内容,原始出处未能定位到具体 URL,标记为中等可信度)。
- 更有力的旁证是两个独立的真实实现,都是手写代码更新窗口标题,没有依赖框架自动行为:
  - `sindresorhus/Settings`(GitHub 上最常用的 macOS 设置窗口开源库,被大量 Mac app 使用)的 `SettingsTabViewController.swift` 里有显式方法 `private func updateWindowTitle(tabIndex: Int) { window.title = panes[tabIndex].paneTitle ... }`,在切 tab 时手动调用(来源:https://github.com/sindresorhus/Settings ,源码 https://raw.githubusercontent.com/sindresorhus/Settings/main/Sources/Settings/SettingsTabViewController.swift )。**这个库甚至完全没用 `NSTabViewController`**,是从零手写的 tab 切换架构。
  - 独立 gist 同样手动设置:`override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) { ... view.window?.title = tabViewItem.label; resizeWindowToFit(tabViewItem: tabViewItem) }`(来源:https://gist.github.com/mminer/caec00d2165362ff65e9f1f728cecae2 )。

**切 tab 自动带动画地改窗口高度:同样不是自动的,证据更强。**
- 两个独立开源 gist 的存在本身就是反证——它们的项目描述直接说明了"plain NSTabViewController 缺这个功能":
  - "NSTabViewController **for preferences window that resizes itself to fit activated tab view**"(标题暗示原生没有)(来源:https://gist.github.com/mminer/caec00d2165362ff65e9f1f728cecae2 ),手动实现 `resizeWindowToFit(tabViewItem:)`,在 `didSelect` 里调用,还要缓存每个 tab 的尺寸来做平滑动画。
  - "A drop-in **replacement** for a plain NSTabViewController that **animates size changes** of the preferences window when selecting a different tab"(来源:https://gist.github.com/florianpircher/be8507c20a888614296ba8123335fc4b ),明确写着自己是"替代品",核心动画代码是手动调 `window.setFrame(newWindowFrame, display: true, animate: true)`。
  - `sindresorhus/Settings` 同样手写:用 `viewController.view.fittingSize` 算新尺寸,包在 `NSAnimationContext` 里、显式设 0.25 秒时长和 `.easeInEaseOut` 曲线;库文档自己写"There are no animations on macOS 10.13 and earlier"——暗示 10.14+ 的动画也是他们自己写的代码,不是框架给的(来源同上两条 sindresorhus/Settings 链接)。
- 一条相对弱一些的旁证说明"哪怕不带动画,尺寸适配也不是完全自动免费的":切 tab 时的 resize 依赖"each tabViewItem's view"的 Auto Layout 约束是否设置完整,原生行为大致是在 `tabView(_:willSelectTabViewItem:)` 这个时机按新 pane 的原始尺寸走(来源:WebSearch 汇总内容,未能定位到单一权威原文链接,可信度中等)。**没能找到 Apple 官方文档明确写"NSTabViewController 会自动把窗口 resize 到新 tab 的尺寸,哪怕不带动画"这句话本身**——这点本身也列入未证实。

结论(给 nanoPod 决策用):`tabStyle = .toolbar` 能免费拿到图标在上文字在下的 toolbar tab 外观;但"标题跟 tab 走"和"切 tab 高度动画过渡"这两个 nanoPod 需要的行为,必须自己在 `NSTabViewDelegate` 的 `tabView(_:didSelect:)` 里写(设 `window.title`,算 `fittingSize` 后 `window.setFrame(_:display:animate:)`),这和 nanoPod 现有 SwiftUI `TabView` + `Form` 方案相比,换 `NSTabViewController` 主要是为了拿"原生 toolbar tab 长相",高度动画这部分工作量不会省。

### 2.4 每个 tab 是否需要自己的 `NSViewController` 包一层 `NSHostingController<YourSwiftUIView>`

确认:**需要**。`NSTabViewItem(viewController:)` 这个初始化方法本身要求传入一个 `NSViewController`;SwiftUI 内容的标准接法就是 `NSTabViewItem(viewController: NSHostingController(rootView: YourSwiftUIView()))`。
- 来源 1(2019 年开发者论坛帖子里给出的具体代码尝试,虽然是 0 回复的未解答帖,但代码模式和 Apple 官方 API 签名一致):https://developer.apple.com/forums/thread/124806
```swift
let t = NSTabViewItem(viewController: NSHostingController(rootView: item))
```
- 来源 2(一个真实生产项目的 PR 描述,用这个组合替换掉了 SwiftUI 原生 `TabView` 的丑陋 pill 样式):"the canonical settings pattern: NSTabViewController with toolbar-style tabs... each pane stays as its existing SwiftUI view inside an NSHostingController"(来源:https://github.com/m4ttstack/rt/pull/319 )。**注意**:这条来源我只拿到了 PR 描述文字,没能成功取到具体 diff/代码,所以这个真实项目里 `NSHostingController` 具体怎么处理尺寸问题,没能验证到细节,列入未证实。

### 2.5 SwiftUI 内容通过 `NSHostingController` 挂进 `NSTabViewController` toolbar tabs 的已知坑

- **根因**:`NSHostingController.view` 背后是 `NSHostingView`,它靠"探测"(probe)自己的 SwiftUI `rootView` 来生成 Auto Layout 约束——同时生成最小尺寸、intrinsic content size、最大尺寸三组约束。macOS 13 引入了 `sizingOptions` 属性来控制用哪几组,默认是全部三组:`[.minSize, .intrinsicContentSize, .maxSize]`(来源:https://mjtsai.com/blog/2023/08/03/how-nshostingview-determines-its-sizing/ ,转述自 Brian Webster 原文 https://www.tumblr.com/brian-webster/723846294121152512/how-nshostingview-determines-its-sizing )。
- **具体表现**:如果 SwiftUI 根视图的 intrinsic size 没有明确定义(比如一个带 `Spacer()` 想撑满容器的 `VStack`),`NSHostingView` 探测出来的 intrinsic content size 会跟你想要的"填满可用空间"冲突——Brian Webster 记录了自己踩到"`Spacer` 死活不撑高"的坑,解法是 macOS 13+ 把 `sizingOptions` 设成 `[.minSize]`(忽略 intrinsic size),macOS 12 及更早则要自己 subclass `NSHostingView` 并 override `intrinsicContentSize` 去屏蔽它(来源同上)。
- **对 `NSTabViewController` 切 tab resize 的直接影响**:既然原生的切 tab 尺寸适配(2.3 节提到的、依赖"each tabViewItem's view 的 Auto Layout 约束是否设置完整"那条)本来就要吃每个 pane 视图的 Auto Layout 约束,而 `NSHostingView` 默认又会把 SwiftUI 内容的 intrinsic size 塞进约束系统——这两者叠加意味着:**给 SwiftUI 根视图一个明确的 `.frame(width:height:)`(或等价的 `.fixedSize()`),是让 `NSHostingView` 报出确定的 intrinsic size、从而让 `NSTabViewController` 的切 tab 尺寸计算不出岔子的标准做法。** 这条结论是我把"`NSHostingView` 靠探测 SwiftUI 内容定尺寸"(mjtsai/Brian Webster,通用 AppKit+SwiftUI 场景)和"NSTabViewController 切 tab 尺寸依赖每个 pane 的 Auto Layout 约束"(2.3 节的中等可信度来源)两条拼接推出来的,**没有找到一篇文章把"NSHostingController 挂进 NSTabViewController toolbar tabs"这个组合从头到尾当一个案例讲清楚**——找到的唯一一个专门讨论这个精确组合的帖子(https://developer.apple.com/forums/thread/124806 )是 2019 年的 0 回复提问,没有解法。side note:SwiftUI 层面(`Settings` scene 里的 `TabView`)有独立来源印证同一现象——"必须给 TabView 一个明确的宽高,那就是窗口的尺寸"(https://serialcoder.dev/text-tutorials/macos-tutorials/presenting-the-preferences-window-on-macos-using-swiftui/ )这和 nanoPod 现有 Settings 窗口本身就用固定 450×400pt 是同一套逻辑。

---

## 未证实(明确找过但没能证实的点,按顺序对应上文)

1. SwiftUI `Settings` scene 里,窗口标题栏文字是否会自动跟随选中 tab 的 label 变化——没找到任何来源正面确认或否定。
2. `Settings` scene 窗口是否默认允许用户拖拽边缘调整大小——没找到明确来源。
3. `Settings` scene 里的 toolbar-tab 自动样式是否要求至少 2 个 tab(单 tab 时是否还显示 tab 栏)——没找到来源。
4. `TabView` 在 `Settings` scene 里自动变成 toolbar 样式这件事本身,具体从 macOS 11.0 就有,还是某个后续小版本才加上——`Settings` scene 本体确认是 macOS 11.0+(Apple 官方文档),但这条"自动居中 toolbar tab"外观本身没有单独的版本号来源。
5. 普通 `NSTabViewController`(`.toolbar` 样式)在**不写任何额外代码**的情况下,切 tab 时窗口尺寸是否会哪怕不带动画地"瞬间跳"到新 tab 的合适尺寸——弱来源(一段 WebSearch 汇总文字)称会,依赖 Auto Layout 约束是否设置完整,但没找到 Apple 官方文档正面确认这句话,也没找到能验证这条的最小可复现例子。
6. `window.bind(.title, to: contentViewController, withKeyPath: "title", options: nil)` 这种 Cocoa Bindings 写法的原始出处链接——内容来自 WebSearch 结果汇总,没能定位到具体原始网页 URL 核实。
7. m4ttstack/rt PR #319 里 `NSHostingController` pane 具体怎么处理尺寸/frame——只拿到 PR 描述文字,没能成功取到实际代码 diff。
8. Xcode Storyboard 模板里,拖一个 Window Controller Scene 是否会自动帮你把窗口 `.title` 绑定到 `contentViewController.title`(即"这条绑定 Interface Builder 里是不是免费的,只有纯代码路径才要手写")——没找到来源确认。nanoPod 是纯代码 AppKit 架构,这条即便有免费的 Storyboard 绑定也用不上,但为了回答完整性列出未证实。