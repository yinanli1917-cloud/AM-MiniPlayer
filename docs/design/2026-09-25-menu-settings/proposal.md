# nanoPod 菜单栏菜单与设置窗口重做方案（v2，2026-09-26）

作者：设计会话（只出方案，不改 `Sources/`）。配套视觉稿：同目录 `mockup.html`（1pt = 1px，深浅色各一份）。调研原文在 `research/`。v1（09-25）推荐的 toolbar 分页已按创始人 09-26 反馈作废，改为系统设置式 sidebar；本文是唯一有效版本。

数值标注：「实测」= 对创始人截图做脚本量化（`research/measure_*.py`；两张图都是 144 dpi，1pt = 2px）；「代码」= 仓库常量；「系统」= 由 AppKit / SwiftUI 决定、我们不写数值；「取值」= 设计取值，Apple 没有公开数字。

## 强调色（先放最前，给 onboarding 会话对齐）

| 项 | 值 |
|---|---|
| 名称 | `AccentColor`（asset catalog 里的 color set；Info.plist `NSAccentColorName = AccentColor`） |
| 浅色 | `#FA4058`（250, 64, 88） |
| 深色 | `#FB546C`（251, 84, 108） |
| 性质 | **取样色，不是 Apple 公布的官方色值。** Apple 没有公布 Apple Music 的品牌色：marketing.services.apple 的《Apple Music Identity Guidelines》只提供黑 / 白 / 彩色三版素材，要求「原样使用 Apple 提供的素材」，全文没有任何 hex / RGB / Pantone。 |
| 取样来源 | 本机 `/System/Applications/Music.app`（1.6.2，macOS 26.2）的 `AppIcon.icns` 256px 位图（`sips` 转 PNG 后 PIL 取样，脚本命令在 §8）：渐变上段 `#FB546C`、中段 `#FA4058`、下段 `#FA2B43`，饱和像素均值 `#F93F57`。浅色取中段（图标主体色）；深色取上段（更亮，与系统色深色版一律更亮的惯例一致：systemPink `#FF2D55` → `#FF375F`）。 |
| 对照 | 系统 Pink `#FF2D55` / `#FF375F`、Red `#FF383C` / `#FF4245`（HIG Color 表，本机 `NSColor.systemPink/systemRed` 实测一致）——都不是 Apple Music 的颜色，不用。仓库专辑页已在用 `Color(red: 0.99, green: 0.24, blue: 0.27)` = `#FC3D45` 当「Apple Music 红」（`PlaylistView.swift:490/859/878`、`MiniPlayerView.swift:529`），比取样色偏橙红；建议后续统一到 `AccentColor`（后续项，本次不改）。 |
| 用法 | 控件、选中态、sidebar 选中行：`Color.accentColor` / `NSColor.controlAccentColor`。按 HIG，这只在系统设置「强调色 = 多彩」时生效；用户选了具体颜色时系统把整个 app 的强调色换成用户色——这是原生行为，不抵抗（Music.app 自己就这么做：Info.plist `NSAccentColorName = KeyColor`）。品牌元素（引导页进度环、卡片描边）想固定粉色，用 `Color("AccentColor")` 直接读资源值，不随用户覆盖。 |
| 对比度 | 白字压 `#FA4058` ≈ 3.5:1（systemBlue `#0088FF` 压白字 ≈ 4.0:1），和系统强调色一个量级；需要 Increase Contrast 变体时用下段 `#FA2B43`。 |
| 实现 | color set 放新建的 `Sources/MusicMiniPlayerApp/Resources/AppAssets.xcassets`（放 app target，不放 Core——Core 资源包 release 不随 app 发布），`build_app.sh` 现有的 actool 步骤一并编进 `Contents/Resources/Assets.car`，Info.plist 手写 `NSAccentColorName`（Apple 文档允许直接写）；出包门禁：`assetutil -I Assets.car` 里没有 `AccentColor` 就拒绝交付（同 icns 门禁）。 |

## 0. 结论先行

1. 菜单「胖」的来源是两行 `NSMenuItem.view` 自定义行：行高 26 比原生 24 高 2pt，图标墨迹 15–16pt 比原生行的 12–13.5pt 大 20–30%，标签 13.5pt 比原生 13pt 大且右偏 2pt，再加一个 33×18 自绘开关。整份菜单改成纯原生 `NSMenuItem`，尺寸全部交给系统。
2. 菜单只放「次高频」：面板里没有、又不值得为它打开设置的操作。定稿 5 项 4 组：显示/隐藏面板 · 全屏封面 ✓ · 翻译为 ▸ · 设置… · 退出 nanoPod；引导没做完时在设置…上方临时多一项「继续引导…」。功能项带图标，App 项不带（CleanShot 规则）。「显示翻译」按创始人规则移出菜单（面板歌词页已有翻译按钮），这是本文唯一与主会话清单不同的地方，见 §3.3。
3. 设置窗口做成系统设置式：左 sidebar（220pt，彩色圆角方块图标）+ 右内容区（500pt，圆角分组卡片，每行标题 + 灰色说明 + 右侧 switch），5 页：通用 / 面板 / 歌词 / 快捷键 / 关于。实现走 SwiftUI `NavigationSplitView` + `NSHostingController`（macOS 14 起 `sceneBridgingOptions` 默认把 `.navigationTitle` / `.toolbar` 桥到宿主窗口）。强调色 Apple Music 粉，见上表。
4. 关于页只留占位（图标、名称、版本、链接），动画另开会话。
5. 剩一个要创始人拍板的点：「显示翻译」是否留在菜单（§7）。

## 1. 现状诊断

### 1.1 菜单（`Sources/MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift`：`populateMenuBarMenu` 627 行起；自定义 view 995–1227 行）

实测几何（`research/measure_menu.py`，pt，纵向从菜单顶边起）：菜单 203 × 189.5；分隔线在 34 / 121 / 156.5；行中心 Show Window 15.5、Fullscreen Cover 51、Lyrics Translation 78、Translate To 102.7、Settings... 138、Quit 173。由此解出：上下内边距 5、原生行 24、分隔线 11、自定义行 26（代码 `rowHeight = 26`）。原生行 24 / 分隔线 11 与开源 muri 项目对 macOS 菜单的目测值一致（§8）。

| 项 | 现状 | 问题 |
|---|---|---|
| 容器 | 4 个原生项 + 2 个 `NSMenuItem.view` 自定义项 | Apple 文档：设 `view` 后标题、勾选态、字体等系统绘制全部作废，键盘事件不送达自定义 view；系统高亮、方向键导航、VoiceOver「菜单项，已选中」全部要自己补，现在都没补 |
| 行高 | 原生 24（实测）；自定义 26（代码） | 自定义行高 2pt |
| 标签 | 原生 13pt 系统菜单字体；自定义 `systemFont(ofSize: 13.5)`（代码 1067 行） | 大 0.5pt |
| 文字起点 | 原生 38.0–38.5（实测）；自定义 40.5（实测；代码 `textX = 39`） | 右偏 2pt，一列文字不对齐 |
| 图标 | 全部 `SymbolConfiguration(pointSize: 15, weight: .medium)`；原生行被系统缩成 12–13.5pt 墨迹，自定义行 `NSImageView` 原样画出 15×16 / 14.5×13.5（实测） | 同一菜单两种图标尺寸；`.medium` 比 13pt Regular 文字重一档（HIG SF Symbols：符号字重匹配相邻文字） |
| 开关 | 自绘 `CompactSwitchControl` 33×18（实测 32×17），右内边距 9 | Control Center 的语言；HIG Toggles（macOS）：switch/checkbox 属于 window body，不进 toolbar / status bar 这类临时 chrome；菜单里的状态从来用勾选或 Show/Hide 标题 |
| hover | 自定义行自画 12% `selectedContentBackgroundColor`、圆角 4，只响应鼠标 | 与系统高亮不一致；方向键选到该行不高亮 |
| 宽度 | 自定义行 `intrinsicContentSize` 宽 206 | 菜单宽度不再由最长标题决定 |
| 图标语义 | Quit 用 `power`；Fullscreen Cover 用 `rectangle.expand.vertical` | `power` 在 macOS 是关机；`rectangle.expand.vertical` 只表达纵向拉伸 |
| 文案 | `"Settings..."` 三个句点；`"Quit"` 无 app 名；「Show Window」「Show/Hide Panel」「显示浮窗」「面板」四个名字 | 省略号应为 U+2026；同一物体多名 |
| 与面板重复 | 「Lyrics Translation」开关 | 面板歌词页底部控件已有同一开关（`TranslationButtonView`，`HoverableButtons.swift:256–325`，挂在 `SharedControls.swift:280–295`） |

历史：2026-05-23 `ed2e126` 把点击图标从「切换面板」改成弹菜单并引入自绘开关行，当时行高 22、符号 12pt；同日 `6df3adb` 调成 26 / 15 / 13.5，即今天的样子。

### 1.2 设置窗口（`SettingsView.swift`；窗口创建 `createSettingsWindow` 751 行起）

| 项 | 现状 | 问题 |
|---|---|---|
| 结构 | 普通 `NSWindow` 里放 SwiftUI `TabView` + `.tabItem`，渲染为 NSTabView 顶部分段控件 + 内容框 | 分段控件是「文档窗口里的子页签」语言；创始人要的是系统设置的 sidebar + 内容区 |
| 尺寸 | `setContentSize(450×400)` + `.frame(minWidth: 450, minHeight: 350)` + `.padding(20)` 包 TabView，再套 `Form(.grouped)` 自带内边距 | 双层边距；四页同高，短页大片空白，长页（通用）在 400pt 里滚动 |
| 布尔项 | `Toggle` 未指定样式 | Apple 文档（`ToggleStyle.automatic` / `.checkbox` / `LabeledContent`）：macOS 分组表单里 `Toggle` 默认 checkbox，不是系统设置那种 switch；Ice、Rectangle 都是显式 `.toggleStyle(.switch)` |
| 标题 | `"Music Mini Player Settings"`；主菜单 About / Hide / Quit 也是「Music Mini Player」 | 旧产品名 |
| 位置 | 每次 `showSettingsWindow` 都 `center()` | 不记用户放哪 |
| 通用页 | Apple Music 状态（圆点 + 中文硬编码 `musicKitAuthStatus` + 按钮塞一行）、Show in Dock、5 个快捷键录制器、清除播放记录 | 权限、启动、快捷键、数据四类混一页；状态文案英文界面下仍是中文 |
| 外观页 | 全屏封面模式、换歌时显示歌曲（贴边行为）、翻译语言 | 「换歌时显示」不是外观；翻译开关缺席 |
| 关于页 | 56pt 渐变 `music.note` 永久 `symbolEffect(.pulse)`、圆体「nanoPod」、版本、GitHub | 永久动画不看 Reduce Motion；圆体与全 app 不一致；无致谢（KeyboardShortcuts 为 MIT 许可） |
| 控件反馈 | `settingsFeedbackPulse`（C4 臂，默认 `.custom`）切换时把标签缩放一下 | 系统设置没有这种反馈 |
| 强调色 | 跟随系统默认（蓝） | 创始人要 Apple Music 粉 |
| 缺项 | 无「登录时启动」 | 常驻菜单栏 app 的标准项；Ice、Rectangle、Raycast、Dropover、Amphetamine 都放在 General 第一组 |

### 1.3 系统设置参考图实测（`ref-system-settings-trackpad.webp`，macOS 26 Tahoe，2x；`research/measure_system_settings*.py`）

| 项 | 实测（pt） |
|---|---|
| 窗口 | 723 × 632；交通灯 14pt，中心 (26, 26) |
| sidebar | 宽 222；底色 (249,249,249)，内容区白 (254)；搜索框 195×28 顶 61（nanoPod 不用）；行距 32；选中行 194×31、圆角 ≈8、左缩进 18.5；图标方块 20×20、圆角 ≈5、左 24.5；标签起点 50，13pt；组间空 ≈13 |
| 内容区 | 列宽 500；卡片宽 460（两侧 20 边距）、圆角 ≈10、底色 (246) 压白底；标题 + 说明行距 53（标题 13pt 墨迹 12.5–24.5，说明 11pt 墨迹 30–40）；文字左缩进 10；分隔线 1pt 通宽 (234)；switch 轨道 36×16、右缩进 10；分段控件 24 高通卡片宽；按钮 24 高 |
| 标题 | 工具栏标题 13pt 粗体 + 副标题 11pt——就是 `.unified` 工具栏的标准 title / subtitle，不是自定义大标题 |

## 2. 设计原则

1. 原生优先：`NSMenuItem` / `NavigationSplitView` / `Form(.grouped)` 能表达的不写自定义 view。系统组件在 macOS 26 自动获得 Liquid Glass（sidebar 自动成浮动玻璃面板），自动响应 Reduce Transparency / Increase Contrast，自带键盘导航与 VoiceOver。
2. 菜单只放次高频（创始人 09-26）：高频操作都在常驻面板里；菜单放「面板里没有、又不值得为它打开设置」的操作。
3. 有 Show 就有 Hide：能切换的窗口用动词换标题，模式用勾选。
4. 图标规则（CleanShot）：功能项带图标，App 项（设置、退出、引导）不带；HIG 同组要么全有要么全无，按组各自成立。
5. 同词同物：一个东西在菜单、设置、快捷键名里只有一个名字。
6. 尺寸交给系统：行高、图标框、勾选列、快捷键列、sidebar 行高、卡片圆角都不手写数值。

## 3. 菜单方案

### 3.1 菜单项清单

| # | 英文 | 中文 | SF Symbol | 状态表达 | 快捷键列 | 动作 | 理由 |
|---|---|---|---|---|---|---|---|
| 1 | Show Player / Hide Player | 显示面板 / 隐藏面板 | `macwindow` | 动词换标题：面板可见且未贴边收起 → Hide；隐藏或已贴边 → Show | 用户录的「显示/隐藏面板」快捷键，`item.setShortcut(for: .togglePanel)` 自动跟随改键；未录则空 | `toggleFloatingWindow()` | 面板隐藏后自己无法把自己叫出来，这是菜单存在的第一理由；HIG Menus 对显隐命令给的第一种写法就是换标题 |
| — | 分隔线 | | | | | | |
| 2 | Fullscreen Cover | 全屏封面 | `arrow.up.left.and.arrow.down.right` | 勾选 | 无 | 翻转 `fullscreenAlbumCover` | 面板上没有这个开关（消费方只轮询 UserDefaults，`PlaylistView.swift:361`、`LyricsView.swift:923`）；模式类偏好用勾选；符号换成系统「全屏」同款 |
| 3 | Translate To ▸ | 翻译为 ▸ | `translate` | 子菜单单选勾选 | 无 | 子菜单：Follow System / 中文 / English / 日本語 / 한국어 / Français / Deutsch / Español（macOS 15+ 才有此行） | 切目标语言面板上没有，也不值得为它开设置；`translate` 是 SF Symbols 5 的翻译专用符号（macOS 14 起可用，本机实测存在） |
| — | 分隔线 | | | | | | |
| 4 | Continue Setup… | 继续引导… | 无 | — | 无 | `showOnboardingWindow()`；仅当 `!OnboardingState.shared.hasCompletedOnboarding` 时出现 | 临时项，做完引导即消失；App 项不带图标；放在设置…上方而不是菜单顶部，因为它和设置同属「App」组，不打断面板入口 |
| 5 | Settings… | 设置… | 无 | — | ⌘, | `openSettings` | App 项不带图标（CleanShot 同款）；⌘, 在菜单打开期间生效，与 app 菜单一致；省略号用 U+2026 |
| — | 分隔线 | | | | | | |
| 6 | Quit nanoPod | 退出 nanoPod | 无 | — | 无 | `NSApp.terminate` | 菜单栏 app 惯例带 app 名（Ice「Quit Ice」）；不标 ⌘Q——app 是 LSUIElement、面板是 nonactivating panel，几乎不在前台，标了等于承诺一个菜单外按不出来的快捷键；CleanShot 的 Quit 同样不标；去掉 `power` |

英文用 HIG 的 title-style capitalization；中文不加空格、不加标点。分组：[显隐面板] | [全屏封面 · 翻译为] | [继续引导 · 设置…] | [退出]——功能组两项都有图标，App 组两项都没有，HIG「同组一致」按组成立。

### 3.2 度量

| 属性 | 方案 | 标注 |
|---|---|---|
| 行高 / 上下内边距 / 分隔线 | 24 / 5 / 11 | 系统（实测值，仅用于视觉稿） |
| 整体高度 | 5 项 4 组约 163pt（今天 6 项 189.5）；带「继续引导…」约 187 | 少一行不是目的，一致才是 |
| 字体 | 13pt Regular 系统菜单字体 | 系统；HIG Typography Body 13 |
| 图标 | `NSImage(systemSymbolName:)`，`isTemplate = true`，**不加** `SymbolConfiguration` | 系统按自己给菜单符号的尺寸绘制（macOS 26 自动插入的菜单符号实测约 12×12，与今天原生行上的 12–13.5 一致）；若创始人肉眼觉得偏小，回退 `pointSize: 13, weight: .regular` |
| 勾选列 / 图标列 / 文字起点 | 系统 | 有勾选时勾号落在最左状态列、图标列不动——AppKit 文档「状态图显示在项目左侧」+ WWDC25「同组图标成列」的推断，Apple 没写两者并存的几何，以真机为准 |
| 快捷键列 / 子菜单箭头 | 系统 | `keyEquivalent` / `submenu` |
| 宽度 | 系统按最长标题 + 快捷键列自算；英文约 190，中文约 140 | 不再强制 206 |
| 高亮 / 键盘导航 / VoiceOver | 系统 | 原生项自带 |
| macOS 27 | `preferredImageVisibility = .visible`（`#available(macOS 27, *)`） | 27 起菜单符号图默认隐藏（§8）；创始人机器现为 26.2 |

### 3.3 砍掉与不加的项（含对主会话清单的一处反驳）

| 项 | 处理 | 去处 / 理由 |
|---|---|---|
| **显示翻译（主会话清单里保留，本文建议移出）** | 不进菜单 | 面板歌词页底部控件已有同一开关：`TranslationButtonView`（`HoverableButtons.swift:256–325`，符号 `translate`，辅助标签「开启翻译 / 关闭翻译」），挂在 `SharedBottomControls`（`SharedControls.swift:280–295`），由 `LyricsView.swift:1712` 传入。按创始人 09-26 规则「菜单只放面板里没有的次高频操作」，它是重复项。保留意见：这个按钮随底部控件一起 hover 才出现、且只在歌词页；若创始人认为这算「面板里没有」，就在第 2 组加回「Show Translation / Hide Translation」（动词换标题，图标 `translate`，此时「翻译为 ▸」改用 `globe`），视觉稿多一行即可。 |
| 自绘开关 `CompactSwitchControl`、自定义行 `MenuBarCustomItemView` / `MenuBarSwitchItemView`、`MenuBarMenuMetrics` | 删除（约 230 行） | 无 |
| Play/Pause、Next、Previous（L10n 残留键） | 不进菜单 | 面板、媒体键与全局快捷键已覆盖 |
| Open Music（L10n 残留键） | 不进菜单 | 面板封面可跳 Music；非高频 |
| About nanoPod | 不进菜单 | 设置「关于」页；主菜单 About 保留 |
| Check for Updates… | 不进菜单 | 完整版放「关于」页；纯净版不得自更新（App Store 审核指南 2.4.5(vii)、2.5.2） |
| Section header、badge、subtitle | 不用 | 5 项 4 组分隔线足够；badge / subtitle 的行内排布 Apple 未描述 |

### 3.4 子菜单

「翻译为 ▸」保持一层；当前语言 `state = .on`；「跟随系统」第一项。不用 `indentationLevel` 表达层级（HIG Menus 明文不建议）。

## 4. 设置方案（系统设置式 sidebar）

### 4.1 信息架构

| 序 | 英文 | 中文 | sidebar 图标（20pt 圆角方块 + 白色符号） | 组 · 行 |
|---|---|---|---|---|
| 1 | General | 通用 | `gearshape` 于 systemGray（系统设置「通用」同色） | 启动 2 · 权限 2 · 数据 1 |
| 2 | Player | 面板 | `macwindow` 于 systemBlue | 封面 1 · 贴边 1 |
| 3 | Lyrics | 歌词 | `text.quote` 于 AccentColor（Apple Music 粉；与引导页「同步歌词」行同符号） | 翻译 2 |
| — | （组间空） | | | |
| 4 | Shortcuts | 快捷键 | `keyboard` 于 systemGray（系统设置「键盘」同色） | 1 组 5 行 |
| 5 | About | 关于 | app 图标本身（`NSApp.applicationIconImage`，20pt） | 占位 |
| (6) | Diagnostics | — | `waveform.path.ecg` 于 systemGray；仅 DEBUG / LOCAL_DEVELOPER_BUILD | 现有面板原样 |

为什么 5 页：sidebar 不怕页薄（系统设置的「登录密码」「Game Center」都只有一两行），换来每页语义单一；歌词单独成页是因为菜单「翻译为 ▸」要有一个同词的家。为什么彩色方块而不是单色符号：创始人点名系统设置的样子；HIG Color 明文固定色 sidebar 图标不被用户强调色覆盖，是允许的固定色用法；只用两种系统色 + 品牌粉，三个灰，不成彩虹。Ice 用单色 `systemSymbol("gearshape")`，列作备选。

sidebar 不做搜索框（5 页用不上），不做前进 / 后退（没有子页面）。

### 4.2 逐页逐项（每页一个 `Form(.grouped)`）

**General / 通用**

| 组 | 行 | 英文 | 中文 | 控件 | 说明文字 |
|---|---|---|---|---|---|
| 启动（无组标题） | 1 | Launch at Login | 登录时启动 | switch（`SMAppService.mainApp`）；`status == .requiresApproval` 时行下加一行说明「Approval required in System Settings」+「Open Login Items…」链接（`SMAppService.openSystemSettingsLoginItems()`），Dropover 5.2.2 同款 | 无 |
| | 2 | Show in Dock | 在 Dock 显示 | switch | 无 |
| Permissions / 权限 | 3 | Music Automation | Music 自动化 | 右侧状态文字 + 按钮：未决定 → Grant Access…；已拒绝 → Open System Settings… | 组脚注：nanoPod reads what's playing and controls Music through Automation. Apple Music access adds artwork and song info. / nanoPod 通过自动化读取播放状态并控制 Music；Apple Music 访问用于封面与歌曲信息。 |
| | 4 | Apple Music | Apple Music | 同上（MusicKit） | |
| Data / 数据 | 5 | Playback History | 播放记录 | 右侧 `Clear…` / `清除…`，点后 `confirmationDialog` 确认 | 行内说明：nanoPod's own record of played tracks. / nanoPod 自己记录的播放历史。 |

状态文字复用 `OnboardingAuthorizationStatus` 的双语文案，替换 `musicKitAuthStatus` 的中文硬编码。

**Player / 面板**

| 组 | 行 | 英文 | 中文 | 控件 | 说明文字 |
|---|---|---|---|---|---|
| 封面（无组标题） | 1 | Fullscreen Cover | 全屏封面 | switch | Fill the panel with the album cover. / 专辑封面铺满面板。 |
| Edge / 贴边 | 2 | Show Song on Track Change | 换歌时显示歌曲 | switch | 沿用现文案：When tucked into the screen edge, briefly show the new song. Turn off if Music already notifies you. / 贴边收起时短暂显示新歌；Music 已有换歌通知的话可以关掉。 |

**Lyrics / 歌词**（macOS 14 整页不出现在 sidebar，与现有 `#available(macOS 15.0, *)` 一致）

| 组 | 行 | 英文 | 中文 | 控件 | 说明文字 |
|---|---|---|---|---|---|
| 翻译（无组标题） | 1 | Show Translation | 显示翻译 | switch（与面板歌词页按钮同一状态 `LyricsService.showTranslation`） | Translated lines appear under the original. / 译文显示在原文下方。 |
| | 2 | Translate To | 翻译为 | Picker（menu 样式），选项数组与菜单子菜单同一份 `L10n.translationLanguageOptions` | 无 |

**Shortcuts / 快捷键**

一组五行 `KeyboardShortcuts.Recorder("标题", name:)`：库内部已用 `LabeledContent` 做「标签左、录制框右」，录制框 `NSSearchField` 外观，最小 130 宽、24 高，zh-Hans 本地化内置。顺序：Play/Pause · Next Track · Previous Track · Show/Hide Player · Hide to Edge。「Show/Hide Panel」改「Show/Hide Player」/「显示/隐藏面板」与菜单第一项同词。组脚注：Shortcuts work in any app. None are set by default. / 快捷键全局生效；默认未设置。录制冲突时库默认弹 `NSAlert`（菜单项冲突 block、系统快捷键 warn、沙盒不允许的组合 block），是用户主动录键时的即时反馈，保留默认。

**About / 关于（占位）**

真实 app 图标 64pt、「nanoPod」Title 2（17pt）、「Version 0.28 (build …)」Subheadline 11pt secondary、一句定位「A menu bar companion for Apple Music.」/「常驻菜单栏的 Apple Music 伴生小窗。」、链接行 GitHub · Acknowledgements（KeyboardShortcuts，MIT）· Report an Issue；完整版多一个「Check for Updates…」按钮（`UpdateService`），纯净版不编入。去掉永久脉冲。**动画不在本次范围**：创始人的 Pinterest 参考另开会话；这页的整块内容区就是给它的预留位，实现时把占位内容放进一个独立的 `AboutPageView`，动画会话只改这一个文件。

### 4.3 窗口与布局

| 属性 | 方案 | 依据 / 标注 |
|---|---|---|
| 结构 | `NavigationSplitView { sidebar } detail: { page }`，sidebar `List(selection:)` + `.listStyle(.sidebar)`，`.navigationSplitViewStyle(.balanced)` | Ice `SettingsView.swift:40-44` 同款；macOS 13+ |
| sidebar 宽 | `.navigationSplitViewColumnWidth(220)` 固定 | 参考图实测 222 |
| sidebar 折叠钮 | `.toolbar(removing: .sidebarToggle)` | macOS 14+，Apple 文档示例就是 NavigationSplitView 去掉折叠钮 |
| 窗口 | `NSWindow(contentViewController: NSHostingController(rootView:))`；`styleMask [.titled, .closable, .miniaturizable, .resizable]`；`toolbarStyle = .unified`；`titlebarSeparatorStyle = .automatic` | 系统设置本身可最小化、可纵向缩放（参考图三个交通灯都亮），跟它 |
| 尺寸 | 720 × 520 起始；`minSize (720, 460)`，`maxSize (720, 900)`——宽固定、高可调 | 取值：sidebar 220 + 内容 500；最长页（通用）内容约 400pt |
| 标题 | detail 上 `.navigationTitle(page.title)`；`NSHostingController.sceneBridgingOptions` 在作为 `contentViewController` 时默认 `.all`（`.title` + `.toolbars`），标题自动写进窗口、显示在内容列上方工具栏区 | Apple 文档，macOS 14+；参考图标题就是 13pt 粗体工具栏标题 |
| 位置 | `setFrameAutosaveName("Settings")`；仅首次 `center()` | 记住放置 |
| 记住页 | 上次页写 UserDefaults；`nanopod://settings/<general|player|lyrics|shortcuts|about>`，`appearance` 作 `player` 别名 | HIG Settings：重开回到上次页 |
| 快捷键 | ⌘, 打开（主菜单已有），⌘W 关闭 | 标准 |
| 卡片 / 行 | `Form(.grouped)` 自带：卡片圆角、20pt 边距、行分隔线、组 header/footer | 系统；参考图卡片圆角 ≈10、宽 460、行距 53 是 Tahoe 的系统值，不手写 |
| 行内排版 | 标题 `Text` 13pt；说明 `.font(.subheadline)`（11pt）`.foregroundStyle(.secondary)`；两行放同一个 `VStack(alignment: .leading, spacing: 2)` 当 `Toggle` 的 label；switch `.toggleStyle(.switch)` 常规尺寸 | HIG Typography Body 13 / Subheadline 11；参考图实测 13 / 11 |
| sidebar 行 | `Label { Text } icon: { 20×20 RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color) + Image(systemName:).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white) }`；行高、选中胶囊、选中色由 `List(.sidebar)` 决定 | 参考图：方块 20 / 圆角 5 / 行距 32 / 选中行圆角 8；选中色 = 强调色（多彩时为 Apple Music 粉） |
| 分段控件 / 预览图 | 本次不用 | 系统设置在「触控板」用预览是因为手势看不见；nanoPod 每个开关的效果都在常驻面板上直接可见；日后某页出现 ≥2 个面向（例如面板页分「封面 / 贴边」）再上 `Picker(.segmented)` 通卡片宽（参考图 24pt 高） |
| 强调色 | 见文首表 | |

### 4.4 菜单与设置的一致性

| 菜单项 | 设置位置 | 文案 |
|---|---|---|
| Show Player / Hide Player | 快捷键页「Show/Hide Player」 | 同词 |
| Fullscreen Cover ✓ | 面板页 · 封面组 · switch | 同词 |
| Translate To ▸ | 歌词页 · Picker | 同词、同选项数组 |
| （面板歌词页翻译按钮） | 歌词页「Show Translation」switch | 同一状态 |
| Continue Setup… | 引导窗口 | — |
| Settings… | 打开上次页 | — |

## 5. 实现要点

### 5.1 菜单（`MusicMiniPlayerApp.swift`）

- `populateMenuBarMenu` 只产生原生 `NSMenuItem`：`title` / `image` / `state` / `keyEquivalent` / `submenu`，不设 `view`。`menuNeedsUpdate` 继续每次打开重建（≤6 项）。
- 图标只给 #1 #2 #3：`NSImage(systemSymbolName:accessibilityDescription:)`，不调 `withSymbolConfiguration`；`#available(macOS 27, *)` 下 `preferredImageVisibility = .visible`。
- #1 `setShortcut(for: .togglePanel)`（KeyboardShortcuts 3.0.1 `NSMenuItem++.swift:108`），自动跟随改键并在清除时还原。库文档要求菜单打开期间禁用全局热键：`menuWillOpen` → `GlobalShortcutRegistrar.deactivate()`，`menuDidClose` → `activate()`（两者已存在，`@MainActor`）。
- #1 标题：`floatingWindow?.isVisible == true && liquidEdge?.isActive != true` → Hide，否则 Show。
- #4 只在 `!OnboardingState.shared.hasCompletedOnboarding` 时插入；动作 `showOnboardingWindow()`（已存在）。
- 「Settings…」`keyEquivalent = ","`、`keyEquivalentModifierMask = .command`；Quit 不设。
- L10n：新增 `showPlayer` / `hidePlayer` / `translateTo` / `continueSetup` / `quitApp`；`settings` 改「Settings…」/「设置…」；删除 `mb.*` 与 `showWindow`；`GlobalShortcutAction.togglePanel` 标题改「Show/Hide Player」/「显示/隐藏面板」。
- 删除 `MenuBarMenuMetrics`、`MenuBarCustomItemView`、`MenuBarSwitchItemView`、`CompactSwitchControl`。

### 5.2 设置（`SettingsView.swift` + `createSettingsWindow`）

- `SettingsTab` 改为 `general / player / lyrics / shortcuts / about (/ diagnostics)`，各带 `title`、`symbolName`、`tileColor`；`visibleCases` 在 macOS 14 去掉 `lyrics`。
- `SettingsWindowView` = `NavigationSplitView`；sidebar `List(selection: $state.selectedTab)`，两个 `Section`（前四页 / 关于 + 诊断）做组间空；detail 按页切 `Form`。
- 窗口按 §4.3；`NSHostingController` 直接当 `contentViewController`，不手设 `sceneBridgingOptions`（默认 `.all`）。若真机上标题没桥过去，显式 `controller.sceneBridgingOptions = [.title, .toolbars]`。
- 备选路线（只在 SwiftUI 桥接出问题时用）：AppKit `NSSplitViewController` + `NSSplitViewItem(sidebarWithViewController:)`（`allowsFullHeightLayout = true`）装两个 `NSHostingController`，外观相同，多约 60 行。
- 每页 `Form { … }.formStyle(.grouped)`；`Toggle(...).toggleStyle(.switch)`；权限行与数据行用 `LabeledContent`。
- 强调色：新建 `Sources/MusicMiniPlayerApp/Resources/AppAssets.xcassets/AccentColor.colorset`（Any = `#FA4058`，Dark = `#FB546C`，sRGB）；`build_app.sh` 的 actool 命令输入里加上这个 catalog（与 `AppIcon.icon` 一起 `--compile` 进同一个 `Assets.car`）；`Info.plist` 加 `NSAccentColorName = AccentColor`；出包门禁 `assetutil -I nanoPod.app/Contents/Resources/Assets.car | grep -q AccentColor`。Xcode 的 Global Accent Color Name 设置对应 actool 的 `--accent-color` 参数，可加可不加——色集编进 catalog + plist 键就够。
- 登录时启动：`SMAppService.mainApp.register()` / `unregister()`，`status` 回读（`.enabled` / `.requiresApproval` / `.notRegistered`）；macOS 13+ 公开 API。
- 权限状态复用 `OnboardingState.automationStatus` / `musicKitStatus`（不在渲染路径触发系统弹窗，按钮点击才请求）。
- 手感臂：`settingsTab` 自定义臂随 TabView 删除；`settingsToggle` 脉冲臂默认改 `.system`（代码可留作对照）。
- 主菜单三处「Music Mini Player」与窗口标题改 nanoPod。
- 关于页：`AboutPageView` 独立文件，只放占位内容，给动画会话。

### 5.3 风险与边界

| 边界 | 处理 |
|---|---|
| 深浅色 | 菜单、sidebar、grouped Form、switch 全部系统绘制；自绘只剩 sidebar 方块（系统色 + AccentColor 两态）与关于页文字（`.primary` / `.secondary`） |
| Liquid Glass（macOS 26） | 原生 NSMenu 与 `List(.sidebar)` 自动获得（sidebar 自动成浮动玻璃）；不加 `NSVisualEffectView` / `glassEffect` |
| Reduce Transparency / Increase Contrast | 系统组件自动响应；自绘文字不用 `opacity`，用语义色；AccentColor 可加 High Contrast 变体 `#FA2B43` |
| Reduce Motion | 关于页去掉永久 `symbolEffect`；sidebar 切页无自定义动画 |
| 用户强调色 ≠ 多彩 | 系统把选中态、switch 换成用户色（HIG 明文），sidebar 固定色方块不变；不硬编码粉色去抵抗 |
| 辅助功能 | 原生菜单项自带「已选中」朗读与方向键高亮；sidebar `List` 自带；switch 自带 |
| 中英文长度 | 菜单宽度系统自算；内容列 500pt 下英文最长行「Show Song on Track Change」+ 两行说明 + switch 不折行；zh 更短 |
| macOS 14 | 歌词页与菜单「翻译为」按 `#available(macOS 15.0, *)` 隐藏；`translate` 符号 macOS 14 起可用（本机 26.2 实测 169 个候选符号名 168 个存在，仅 `ipod.nano` 不存在）；`sceneBridgingOptions`、`toolbar(removing:)` 均 macOS 14+ |
| macOS 15 沙盒 | 录快捷键时单独 Option 不允许，库自带中文提示 |
| macOS 27 | 菜单符号图默认隐藏，需 `preferredImageVisibility = .visible` |
| 沙盒 / App Store | `SMAppService`、`NSApp.terminate`、`x-apple.systempreferences:`、KeyboardShortcuts（README：fully sandboxed and Mac App Store compatible）均公开 API；「Check for Updates…」只在完整版 target 编入（2.4.5(vii)、2.5.2） |
| actool 中止 | build_app.sh 现在允许 actool 失败回退 icns；AccentColor 同样会静默丢失（系统回落蓝色）——所以要门禁 |
| 面板是 `.nonactivatingPanel` | 打开设置已 `NSApp.activate`，不改 activation policy（banned-patterns：只有 `updateDockVisibility` 可改） |
| `NSHostingView` 尺寸探测 | 每页 `Form` 给 `.frame(minWidth: 500)` 即可，窗口尺寸由 `minSize/maxSize` 管，不靠 `preferredContentSize` |

## 6. 代码层验收项（创始人禁止截图 / 录屏 / computer use；最终视觉由他本人验收）

菜单：
1. `populateMenuBarMenu` 产出的每个 item `view == nil`。
2. 标题序列快照（en / zh 各一份）与分隔线位置等于 §3.1；引导未完成时多「Continue Setup…」于 Settings… 之前，完成后不出现。
3. `image != nil` 且 `isTemplate` 仅限 #1 #2 #3；#4 #5 #6 `image == nil`；符号名经 `NSImage(systemSymbolName:)` 解析非空；macOS 27 下 `preferredImageVisibility == .visible`。
4. 面板可见且未贴边 → 第一项「Hide Player」；隐藏或贴边 → 「Show Player」（注入可见性与 liquidEdge 状态）。
5. `fullscreenAlbumCover` 为 true 时 #2 `state == .on`，false 时 `.off`；执行 action 后 UserDefaults 翻转。
6. Settings… `keyEquivalent == ","` 且 modifier `.command`；Quit 与 Continue Setup `keyEquivalent == ""`；#1 在隔离 defaults 里录入快捷键后 `keyEquivalent` 随之变化、清除后为空。
7. 标题不含 `"..."`，需要处含 U+2026。
8. `menuWillOpen` 触发 `deactivate()`、`menuDidClose` 触发 `activate()`（注入假注册器计数）。
9. 「翻译为」子菜单恰一项 `.on`，与 `translationLanguage`（含 system 映射）一致。

设置：
1. `SettingsTab.visibleCases` 在 macOS 15+ 为 `[general, player, lyrics, shortcuts, about]`，DEBUG 下末尾多 `diagnostics`；macOS 14 无 `lyrics`；每页 title 双语、symbolName 可解析。
2. 窗口 `minSize == (720, 460)`、`maxSize.width == 720`、`toolbarStyle == .unified`；选中页切换后 `window.title == 该页 title`。
3. 选中页持久化：设为 `.shortcuts` 后新建状态对象读回 `.shortcuts`。
4. `openSettingsPage(named: "appearance")` 落到 `.player`；`"lyrics"` 落到 `.lyrics`。
5. 登录时启动通过协议调用 register / unregister；`status` 回读驱动 switch 初值与「需批准」说明行（注入假 service 三态）。
6. 每个新 L10n 键 en / zh 都有值，`localized(key) != key`。
7. `MicroInteractionFeel.settingsToggle` 默认解析值为 `.system`。
8. AppKit 目标源码不再出现「Music Mini Player」（脚本断言）。
9. 每页 `Toggle` 均显式 `.toggleStyle(.switch)`（源码断言：`Toggle(` 出现次数 == `.toggleStyle(.switch)` 出现次数）。
10. 出包：`Assets.car` 含 `AccentColor`（`assetutil -I`），`Info.plist` `NSAccentColorName == "AccentColor"`；`AccentColor.colorset/Contents.json` 的 Any / Dark 分量等于 `#FA4058` / `#FB546C`。
11. `AboutPageView` 不含 `symbolEffect`（源码断言）。

## 7. 需创始人拍板（唯一）

**「显示翻译」是否留在菜单。** 本文按创始人 09-26 规则移出（面板歌词页已有同一开关，`HoverableButtons.swift:256–325`），主会话清单里保留。推荐移出；若创始人认为 hover 才出现的面板按钮不算「面板里有」，加回一行「Show Translation / Hide Translation」即可，其余方案不变。

其他小项已按推荐值写定，创始人看稿时可直接改：sidebar 图标彩色方块（备选：Ice 式单色符号）；「登录时启动」新增；「继续引导…」放设置…上方；关于页占位内容。

## 8. 调研来源

- 创始人反馈 09-26（主会话转述）：系统设置式 sidebar；Apple Music 粉强调色、要写出处；关于页动画另议；菜单只放次高频、功能项才带图标、有 Show 就有 Hide。
- 参考图：`ref-current-menu.png`（现菜单，2x）、`ref-cleanshot-menu.jpg`、`ref-system-settings-trackpad.webp`（macOS 26 系统设置，2x）；量化脚本 `research/measure_menu.py`、`research/measure_system_settings.py`、`research/measure_system_settings_cards.py`。
- 强调色取样：`sips -s format png /System/Applications/Music.app/Contents/Resources/AppIcon.icns --out music_icon.png` 后 PIL 在 x=12% 列取 y=25/50/75% 三点；`plutil -p /System/Applications/Music.app/Contents/Info.plist` → `NSAccentColorName = KeyColor`；本机 `NSColor.systemPink/systemRed/systemBlue/systemGray` 两种外观实测；Apple Music Identity Guidelines（marketing.services.apple）无色值。
- Apple HIG（2026-09-25 抓取）：Menus、The menu bar、Settings、Toggles、SF Symbols、Materials、Typography；Color（macOS 系统色表；强调色三句：多彩时应用 app 强调色 / 用户选色则覆盖 / 固定色 sidebar 图标不覆盖）。
- Apple 文档：`NSHostingController.sceneBridgingOptions`（macOS 14.0；作为 contentViewController 时默认 `.all`）、`NSHostingSceneBridgingOptions`（`.title` 桥 `navigationTitle/navigationSubtitle`，`.toolbars` 桥 `toolbar(content:)`）、`View.toolbar(removing:)`（macOS 14.0，示例即 NavigationSplitView 去 `.sidebarToggle`）、`NSAccentColorName`（macOS 11+，可直接写 Info.plist）、`NSMenuItem.view` / `state` / `image`、`preferredImageVisibility`（27.0）、`ToggleStyle.automatic`（macOS → checkbox）、`LabeledContent`（inset group form 里的 Toggle 是 checkbox）、`SMAppService.mainApp`（13+）。
- WWDC25 session 310 / 356：macOS 26 菜单大量加图标，同组图标成一列。
- macOS 26/27 菜单图标：tonsky.me、mjtsai 2025-12-10 / 2026-06-18、daringfireball 2026-03。
- 原生菜单度量对照：github.com/MattJackson/muri `src/theme.rs`（目测校准：行高 24、分隔线 11、内边距 10/5、图标 16）。
- CleanShot X（本机 bundle 只读）：`LSUIElement`、`menubar*` 图标资源 24×24pt、`menubarHideDesktopIcons` / `menubarShowDesktopIcons` 成对；About / Check for Updates / Settings / Quit 无图标（创始人截图）。
- 第三方设置窗口（`research/` 六份）：Ice（`NavigationSplitView` 侧栏 6 页、900×625、`.toggleStyle(.switch)`、Launch at Login 在 General 第一组、sidebar 图标 `systemSymbol("gearshape")` 单色）；Rectangle（`NSTabViewController.toolbar`，本版不用）；CleanShot v5 / Raycast / iStat Menus 7 / Dropover 均为 sidebar；Dropover 5.2.2 登录启动旁提示需在系统设置批准。
- App Store 审核指南（2026-09-25 三方交叉核实）：2.4.5(vii)、2.5.2。
- KeyboardShortcuts 3.0.1：`NSMenuItem++.swift` `setShortcut(for:)`；`RecorderCocoa` 130×24；`ConflictPolicy` 默认 block / warn / block；README「fully sandboxed and Mac App Store compatible」；zh-Hans 本地化。
- 本仓库：`MusicMiniPlayerApp.swift`、`SettingsView.swift`、`LocalizedStrings.swift`、`GlobalShortcuts.swift`、`MicroInteractionFeel.swift`、`OnboardingState.swift`（`hasCompletedOnboarding`）、`HoverableButtons.swift`（`TranslationButtonView`）、`SharedControls.swift`（`SharedBottomControls.translationButton`）、`LyricsView.swift:1712`、`PlaylistView.swift` / `MiniPlayerView.swift`（`#FC3D45`）、`Package.swift`（`.macOS(.v14)`）、`build_app.sh`（actool 步骤、`NANOPOD_EDITION`）；`git log` `ed2e126` / `6df3adb` / `1a4eb79`。
