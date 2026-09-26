# Part A — Apple 自家小型设置窗口

方法说明:本轮 WebSearch 配额在过程中被这次并行调研的六个分支共用耗尽(200/200),后半段改用 WebFetch 直接抓 Apple 官方指南页。四个 app 我都没找到任何权威来源给出像素尺寸——Apple 帮助文档从不写窗口尺寸——所以尺寸一律标未证实,只给定性描述。

| App | 顶部 toolbar 分页(icon-above-text) | 页数 | 窗口尺寸 |
|---|---|---|---|
| Shortcuts.app | 未完全证实,见下 | 至少 2(General、Advanced),完整总数未证实 | 未证实 |
| Keynote | 有直接引用支持 | 官方原句只点名 3 个,第三方资料称共 5 个(不一致,见下) | 未证实 |
| Music.app | 措辞支持但非直接可视化描述 | 4(General/Playback/Files/Advanced) | 未证实 |
| TextEdit | 措辞支持但非直接可视化描述 | 2(New Document/Open and Save) | 未证实 |

## Shortcuts.app (macOS)
- 入口:「Shortcuts > Settings」。来源:[Advanced Privacy and security settings in Shortcuts on Mac](https://support.apple.com/guide/shortcuts-mac/advanced-shortcuts-settings-apdfeb05586f/mac)
- 已确认存在的 tab:General(含 iCloud Sync 开关)、Advanced(含 Allow Running Scripts,以及运行 JavaScript/恶意软件防护相关的隐私与安全项)。原句:"Select Allow Running Scripts in the **Advanced tab**."
- 我对该指南首页做了 TOC 抓取,能确认的 Settings 相关链接只有「Advanced Shortcuts settings」「Adjust privacy settings」两条,后者读起来像是 Advanced tab 内部的一个子区块而非独立 tab。之前一次 WebSearch 摘要里出现过"Sidebar preferences"字样,但我没能在任何直接引用的原句里再次找到它——不排除是搜索引擎摘要时的整合/编造,未独立证实,不采信为独立 tab。
- 是否 toolbar 分页:没有拿到类似 Keynote 那种"at the top of the window"的直接原句。基于 Shortcuts for Mac 是较新的、大量使用 SwiftUI 的 app(Monterey 起加入 Mac 原生版),合理推测其 Settings 窗口用的是 SwiftUI `Settings` scene 默认产出的 toolbar 分页样式,但这是推断,非引用证实。

## Keynote
- 直接引用来源:[Change Keynote settings on Mac](https://support.apple.com/guide/keynote/set-keynote-preferences-tan003125d0e/mac),原句:"To see each group of settings, click General, Rulers, or Auto-Correction **at the top of the window**."——这句话本身就是 toolbar 分页的标准描述,可信度高。
- 不一致点:该原句只点名 3 个 tab(General/Rulers/Auto-Correction);但另一独立来源 [danstutorials.com](https://danstutorials.com/tutorials/tutor-for-keynote/lessons/getting-around-keynote/topics/a-look-at-keynote-preferences-2/) 描述共 5 个 tab(General/Slideshow/Rulers/Remotes/Auto-Correction)。两个来源没能互相印证总数,如实呈现矛盾,不替你选边。

## Music.app
- 来源:[Change settings in Music on Mac](https://support.apple.com/guide/music/change-music-settings-mus0fb1b421b/mac),原句:"choose Music > Settings, then click any of the following"——后接 General、Playback、Files、Advanced 四项。
- "click any of the following"这个措辞不是"at the top of the window"那种直接可视化描述,但确认了这是四个可点击的并列项,与 toolbar 分页行为一致。

## TextEdit
- 来源:[Change preferences in TextEdit on Mac](https://support.apple.com/guide/textedit/change-preferences-txted1063/mac),原句:"choose TextEdit > Settings, then click New Document or Open and Save."
- 只有 2 个 tab,同样没有"at the top"这类可视化措辞的直接引用。

---

# Part B — 开源第三方菜单栏应用源码

三个仓库均已只读 shallow clone 到 scratchpad(`/private/tmp/claude-501/.../scratchpad/repos/`),以下每条都给了仓库内相对路径 + 行号,均来自我自己读到的源码,不是转述。

## 1. Ice — https://github.com/jordanbaird/Ice

**布局范式:sidebar,不是 toolbar tab。** `Ice/Ice/Settings/SettingsView.swift:40-44`:
```swift
NavigationSplitView {
    sidebar
} detail: {
    detailView
}
```
这点值得注意——题目问的"toolbar-style tab pager"这个范式,Ice 并没有用,它用的是 macOS 13+ 的 NavigationSplitView 侧栏。

**页数:6 个**,`Ice/Ice/Main/Navigation/NavigationIdentifiers/SettingsNavigationIdentifier.swift:8-14`:
```swift
enum SettingsNavigationIdentifier: String, NavigationIdentifier {
    case general = "General"
    case menuBarLayout = "Menu Bar Layout"
    case menuBarAppearance = "Menu Bar Appearance"
    case hotkeys = "Hotkeys"
    case advanced = "Advanced"
    case about = "About"
}
```

**每页分组数**(以 `IceSection` 出现次数统计):General 6 组(`GeneralSettingsPane.swift:56-77`)、Hotkeys 3 组(`HotkeysSettingsPane.swift:16-29`,按"Menu Bar Sections"/"Menu Bar Items"/"Other"分)、Advanced 4 组、About 2 组;Menu Bar Layout 与 Menu Bar Appearance 两页 `IceSection` 出现 0 次——这两页是自定义拖拽/预览类 UI,不走标准表单分组。

**窗口尺寸,可调整**。`Ice/Ice/Settings/SettingsWindow.swift`:
```swift
// line 20
.frame(minWidth: 825, minHeight: 500)
// line 23
.windowResizability(.contentSize)
// line 24
.defaultSize(width: 900, height: 625)
```
`.windowResizability(.contentSize)` + 只设 min 没设 max,意味着窗口可被用户拖拽变大变小,不是固定尺寸,只兜底最小 825×500,默认开窗 900×625。

**Toggle 样式:统一走 switch,不是 checkbox。** `Ice/Ice/UI/IceUI/IceForm.swift:72-85`:
```swift
private struct IceFormToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        IceLabeledContent {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        } label: {
            configuration.label
        }
    }
}
```
这是 `IceForm` 内容区默认套的 toggleStyle(`IceForm.swift:65`),所以任何塞进 `IceForm { }` 的 `Toggle` 都会被渲染成 mini 尺寸的原生 switch,而不是 checkbox。

**行布局:统一的 label-left / control-right primitive。** `Ice/Ice/UI/IceUI/IceLabeledContent.swift:31-40`:
```swift
var body: some View {
    LabeledContent {
        content
            .layoutPriority(1)
    } label: {
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)
    }
}
```
label 被强制 `maxWidth: .infinity, alignment: .leading`,把 content(控件)挤到行的右边。整个设置界面的每一行——包括 hotkey recorder——都走这同一个 primitive。

**Hotkey recorder 行对齐:右对齐,用的就是上面这个 IceLabeledContent。** `Ice/Ice/UI/HotkeyRecorder/HotkeyRecorder.swift:18-33`:
```swift
var body: some View {
    IceLabeledContent {
        HStack(spacing: 1) {
            leadingSegment
            trailingSegment
        }
        .frame(width: 132, height: 24)
        ...
    } label: {
        label
        ...
    }
}
```
录制控件(132×24 的双段按钮)是 `content`,按 IceLabeledContent 的规则会被推到行右侧,标签("Toggle the hidden section"等)在左。

**内联说明文字:大量存在,靠专门的 `.annotation()` modifier,不是临时拼 Text。** `GeneralSettingsPane.swift` 里 `.annotation(` 出现 8 次,`AdvancedSettingsPane.swift` 里 3 次。例如 `GeneralSettingsPane.swift:186-188`:
```swift
Toggle("Use Ice Bar", isOn: manager.bindings.useIceBar)
    .annotation("Show hidden menu bar items in a separate bar below the menu bar")
```

**Launch at Login 位置:General 页,第一组。** `GeneralSettingsPane.swift:56-59` + `87-89`:
```swift
IceForm {
    IceSection {
        launchAtLogin
    }
    ...
}
...
private var launchAtLogin: some View {
    LaunchAtLogin.Toggle()
}
```
用的是 sindresorhus/LaunchAtLogin 这个第三方包(与下面 AlDente 用的是同一个包)。

**About 位置:独立 sidebar tab,不是 footer 也不是 app menu。** `AboutSettingsPane.swift:8-14` 是完整一页(app 图标+版本+版权、更新设置两个 Toggle、底部一条胶囊形按钮栏 Quit/Acknowledgements/Contribute/Report a Bug/Support Ice,见 `:138-161`)。侧栏图标用的是自定义 asset 而非系统符号:`SettingsView.swift:105` `case .about: .assetCatalog(.iceCubeStroke)`。

## 2. Rectangle — https://github.com/rxhanson/Rectangle

**架构:AppKit 外壳 + SwiftUI 内容的混合体,不是纯 AppKit。** `Rectangle/Rectangle/SettingsWindow/SettingsWindowController.swift` 用 `NSTabViewController` 做壳,但 4 个 tab 里有 3 个(Behavior/App Settings/Snap Areas)的实际内容是 SwiftUI `Form` 通过 `NSHostingController` 塞进去的,只有 "Shortcuts" 这一 tab 是纯 AppKit(`NSOutlineView`)。

**Toolbar 分页:是,显式设置。** `SettingsWindowController.swift:77`:
```swift
self.tabStyle = .toolbar
```
这行代码就是题目问的那个范式本身——AppKit `NSTabViewController.tabStyle = .toolbar`。

**页数:4 个。** `SettingsWindowController.swift:29-34`:
```swift
enum Tab: Int, CaseIterable {
    case shortcuts
    case snapAreas
    case behavior
    case appSettings
```
标签文案(`:37-42`):"Shortcuts"、"Snap Areas"、"Behavior"、"App Settings"。

**窗口尺寸:每个 tab 各自的尺寸,切 tab 时动画 resize 整个窗口,不是共享一个固定尺寸。**
```swift
// :12
window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
// :18
window.minSize = NSSize(width: 500, height: 350)
// :53(仅 shortcuts tab 显式写死)
case .shortcuts:   return NSSize(width: 500, height: 540)
```
其余三个 tab 的 `defaultSize` 是 `nil`(`:54` `default: return nil`),回落到 `calculateContentSize(for:)`(`:117-128`)按 SwiftUI 内容的 `fittingSize`/`preferredContentSize` 动态算。`ShortcutsViewController.swift:217`(纯 AppKit 那页)另有 `initialSize = NSSize(width: 500, height: 610)`,和 tab 枚举里写的 540 不是同一个数——一个是窗口内容尺寸,一个是这个 view controller 自己的内部 size,两处口径不同,如实记录不替你合并。整体 `styleMask` 含 `.resizable`,但代码里每次切 tab 都会用动画把窗口强制 resize 到该 tab 的目标尺寸(`resizeWindow(toContentSize:animated:)`,约 `:130-140` 一带),用户手动拖拽应该还是可以的,但程序会在切 tab 时覆盖。

**Toggle 样式:混用,以 switch 为主,一处显式 checkbox。**
- `BehaviorSettingsView.swift:72-74`:紧凑的多选分数尺寸簇,显式 `.toggleStyle(.checkbox)`
- `BehaviorSettingsView.swift:89-91`、`:115-117`:显式 `.toggleStyle(.switch)`
- 其余大量 `Toggle(...)` 未显式指定,在 `.formStyle(.grouped)`(`AppSettingsView.swift:79` / `BehaviorSettingsView.swift:389` / `SnapAreaSettingsView.swift:199`)下按 macOS 13+ 默认渲染成 switch。

**内联说明文字:大量存在,统一模式 `Text(...).font(.caption).foregroundColor(.secondary)`,紧跟在相关 Toggle 下面一个 `VStack(alignment: .leading)` 里。** 例如 `AppSettingsView.swift:38-40`:
```swift
Text("When the menu bar icon is hidden, relaunch Rectangle from Finder to open")
    .font(.caption)
    .foregroundColor(.secondary)
```
`BehaviorSettingsView.swift` 里这个模式重复了至少 8 处(`:140-142`、`:213-215`、`:234-236`、`:253-255`、`:260-262`、`:284-285`、`:353-355`、`:376-378`)。

**Launch on login 位置:第 4 个 tab "App Settings",第一个 Section 第一行。** `AppSettingsView.swift:33-35`:
```swift
Section {
    Toggle("Launch on login", isOn: $viewModel.launchOnLogin)
    Toggle("Hide menu bar icon", isOn: $viewModel.hideMenuBarIcon)
```

**About 位置:不在任何 Settings tab 里,走系统标准 About panel,挂在 app 菜单。** `Rectangle/Rectangle/Base.lproj/Main.storyboard:18-21`:
```xml
<menuItem title="About Rectangle" id="5kV-Vb-QxS">
    ...
    <action selector="orderFrontStandardAboutPanel:" ... />
```
`AppDelegate.swift:264-266`:
```swift
@IBAction func showAbout(_ sender: Any) {
    NSApp.orderFrontStandardAboutPanel(sender)
}
```

**Hotkey recorder 行对齐:右对齐,两条独立证据互相印证。**
1. 纯 AppKit 的 Shortcuts tab,`ShortcutsViewController.swift` 里 `ShortcutActionCellView.setup()`:`titleLabel.alignment = .right`(`:132`),`titleLabel` leading 锚定容器 leading+20(`:175`),`shortcutView`(MASShortcutView)trailing 锚定容器 trailing−66(`:154`),宽 160 高 19(`:160-161`),右边还有个 20×20 的 popoverButton 贴着它右侧(`:163-166`)——整体是标题贴左、录制控件贴右靠近窗口边缘的布局。
2. SwiftUI 侧(Behavior tab)同样模式,`BehaviorSettingsView.swift:174-182`:
```swift
HStack {
    Text("Toggle Todo")
    Spacer()
    MASShortcutViewRepresentable(...)
        .frame(width: 130, height: 22)
}
```
`Text` + `Spacer` + 控件的写法在该文件里重复了至少 3 次(`:174-182`、`:184-192`、`:264-269`),效果同样是控件右对齐。

**每 tab 分组数大致统计**(以 `Section {` 计):App Settings 4 组(`:32/44/59/68`,分别是"启动与更新前两项"/"检查更新"/"快捷键限制"/"导入导出与恢复默认");Behavior 9 组(Repeated commands、Gaps、Todo Mode 三个普通 Section,外加 Maximize/Across Display/Stacked Windows/Side Split Ratio/Stage Manager(条件)/Extras 六个套了 `DisclosureGroup` 的可折叠 Section,默认全部折叠);Snap Areas 至少 4 组(`SnapAreaSettingsView.swift:156/162/182/191`,后面 `:266/274` 是否算同一页主体我没有进一步深挖);Shortcuts tab 不用 Section 概念,是 2 个顶层 `NSOutlineView` group(`standardGroup` 不可折叠常驻展开、`moreGroup "⋯"` 可折叠,内嵌 4 类标准动作 + "⋯"下 4 类 + 嵌套的"Extra"子组另 5 类),见 `ShortcutsViewController.swift:288-319`。

## 3. AlDente

**仓库确认过程:** 原作者仓库 `davidwernhart/AlDente` 现已重定向到 `AppHouseKitchen/AlDente-Battery_Care_and_Monitoring`(https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring,当前 clone 得到 HEAD `9136e85` / 2025-07-15,`master` 分支)。这个仓库自己的 `README.md`("## Closed‑Source Notice")原文写明:"This project is no longer open source. Although the GitHub repository contains legacy code and archived releases, **the current version of the software is proprietary and closed-source.**" README 同时说 AlDente Pro"有更多功能……offers a better design"。

**结论(重要,直接影响下面所有结论的适用范围):这个仓库里能读到的源码是 2021 年那版 AlDente Free/Classic 的旧代码,不代表当前 AlDente Pro 的真实 UI。** 仓库只有 4 个 Swift 源文件(`AlDente/AppDelegate.swift`、`ContentView.swift`、`Helper.swift`、`PersistanceManager.swift`),没有任何 Settings/Preferences 专用文件夹,与 README 自称"仍在积极维护、界面更好"的 Pro 版明显对不上——Pro 版真实设置窗口的布局、tab 数、尺寸,本仓库不含,标为未证实。

以下结论均限定在这份 legacy 代码范围内:

**没有独立的 Settings 窗口,是菜单栏 NSPopover。** `AlDente/AppDelegate.swift:47-50`:
```swift
let popover = NSPopover()
popover.contentSize = NSSize(width: 400, height: 600)
popover.behavior = .transient
popover.contentViewController = NSHostingController(rootView: contentView)
```

**单页,无 tab,无 sidebar,无 toolbar。** 设置区是同一个 popover 里的一段可展开/收起区域。`AlDente/ContentView.swift:163-166` 一个 "Settings" 按钮切换 `showSettings`,`:192-194`:
```swift
if showSettings {
    Settings()
}
```

**尺寸:固定,不可用户调整,靠代码在两个写死的高度间切换。** `ContentView.swift:196`:
```swift
.frame(width: 400, height: adaptableHeight)
```
`adaptableHeight` 初始 100(`:133`),点开 Settings 后设为 275(`:165`)。注意这和 popover 自己声明的 `contentSize`(400×600,见上)对不上——popover 留白比实际内容大,这是代码本身的不一致,不是我读错。

**Toggle 样式:未显式设置,走系统默认。** 全文件 grep 不到任何 `.toggleStyle(`,两处 `Toggle(isOn:) { Text(...) }`(`:45-55` 和 `:58-77`)都用的裸 `Toggle`。

**Launch at login 位置:就在这唯一的 Settings 展开区里,第一项。** `ContentView.swift:9` `import LaunchAtLogin`;`:45-55`:
```swift
Toggle(isOn: Binding(
    get: { launchAtLogin },
    set: { newValue in
        launchAtLogin = newValue
        LaunchAtLogin.isEnabled = newValue
    }
)) {
    Text("Launch at login")
}
```
用的第三方包与 Ice 相同(sindresorhus/LaunchAtLogin)。

**About 位置:内联文字,同一个 Settings 展开区里,不是独立 tab。** `ContentView.swift:93-106`:版本号 + GitHub 链接(`"github.com/davidwernhart/AlDente"`)+ "Cooked up in 2021 by AppHouseKitchen" + 一个跳转官网的 "Get Pro 🍜" 按钮(`:111-117`)。

**Hotkey recorder 行:不适用。** 这份代码里没有任何用户可配置快捷键/热键功能,无对应 UI,故无从回答对齐方式。

---

# 未证实清单

- Shortcuts.app Settings 窗口完整 tab 列表与总数(只确认 General、Advanced 两个存在;"Sidebar"是否为独立 tab 未能用直接引用证实,可能是搜索摘要整合出的伪信息)
- Shortcuts.app 是否为 icon-above-text 的 toolbar 分页(未找到可视化描述的直接引用,仅为基于 SwiftUI Settings scene 常见做法的推断)
- Keynote Preferences 的 tab 总数(官方指南原句只点名 3 个,第三方资料称 5 个,两者不一致,未消歧)
- Shortcuts / Keynote / Music.app / TextEdit 四者的 Settings 窗口像素尺寸(width/height)——全部未在任何信源中找到,不作数字猜测
- TextEdit、Music.app 的 tab 是否确切为"icon-above-text"样式(措辞只确认了可点击并列项,未确认图标+文字的具体视觉呈现)
- AlDente **当前** Pro 版本真实设置界面的布局/tab 数/尺寸(闭源,完全无法核实;本报告 Part B 第 3 节全部结论仅适用于 2021 年 Free/Classic 遗留代码)
- Rectangle `ShortcutsViewController.swift:217` 的 `initialSize.height = 610` 与 `SettingsWindowController.swift:53` tab 枚举里 `defaultSize` 的 `height: 540` 为何不一致——只如实记录两个数字都存在,未深挖是否为历史遗留的口径差异

## 关键文件路径汇总(均为本机只读 clone,非项目目录)
- `/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/repos/Ice/`
- `/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/repos/Rectangle/`
- `/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/repos/AlDente/`