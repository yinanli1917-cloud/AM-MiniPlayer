# nanoPod 菜单栏菜单与设置窗口重做方案（v3，2026-09-26 下午）

作者：设计会话（只出方案，不改 `Sources/`）。配套视觉稿：同目录 `mockup.html`（1pt = 1px，深浅色各一份）。调研原文在 `research/`。本文是唯一有效版本；v1（toolbar 分页）、v2（系统设置式 sidebar）均已作废。

## v3 改了什么（对照创始人 09-26 下午第二批反馈）

| 反馈 | v3 的处理 |
|---|---|
| 菜单一行同时有勾选和图标难看；整体还是小胖 | 整份菜单不带任何图标、主菜单不用任何勾选；能切换的项用动词换标题；去掉 `⌘,`；「全屏封面」移出菜单（§3.3 论证）；4 项 3 组 2 条分隔线。实测（`NSMenu.size`，不显示菜单）：146 × 128，比现状 203 × 189.5 窄 28%、矮 33%，比 v2 窄 36%、矮 21%（§3.5 对比表） |
| 「只要任何一项带状态，AppKit 就会留勾选列」 | 实测：一项 `state = .on` 整份菜单宽 +8pt；子菜单里的勾选**不**影响父菜单（146 = 146）。所以主菜单零勾选，「翻译为 ▸」子菜单内保留单选勾选（§3.2） |
| 设置不要 sidebar，太重；要的是「触控板」页右侧那种插图 + 小动画示意 | 单窗口 480 × 562、无 sidebar、无工具栏：顶部一个 440 × 120 的演示台（stage），下面 4 段分段控件（面板 · 通用 · 快捷键 · 关于），再下面分组行。悬停某一行，演示台播放这一行的效果动画；切换开关时播一次。13 段演示全部 SwiftUI 矢量绘制，无第三方依赖；Reduce Motion 给静帧（§4） |
| Apple Music 粉保留 | 强调色规格不变（§强调色），用在 switch、分段控件选中段、演示台里的面板高亮 |
| 关于页只留占位 | 「关于」是第 4 段，整块内容区留给动画会话（§4.2） |
| 「继续引导」名字由 Onboarding 设计师定 | 已定名（onboarding proposal §9.2）：整套引导叫「认识 nanoPod / Getting to know nanoPod」；设置「通用」段一行「认识 nanoPod」，按钮文字随状态变——没走完（skipped 或中途停下）显示「接着认识 nanoPod / Keep getting to know nanoPod」，点了从上次停下处接着走；走完了显示「重新认识 nanoPod / Get to know nanoPod again」，点了从头走（§4.3） |
| 主会话 09-26 晚：菜单里不放引导入口 | v3 初稿曾在引导未完成时临时多一行「接着认识 nanoPod…」，实测把菜单撑到 EN 259 × 152 / ZH 182 × 152；onboarding 稿里点「以后再说」后状态是 skipped、入口会长期挂着，正撞上「胖」。已删：菜单始终 4 项 146 × 128，回头接着走引导只从设置「通用」段那一行进（次高频规矩） |

## 强调色（给 onboarding 会话对齐，v2 起不变）

| 项 | 值 |
|---|---|
| 名称 | `AccentColor`（asset catalog color set；Info.plist `NSAccentColorName = AccentColor`） |
| 浅色 | `#FA4058`（250, 64, 88） |
| 深色 | `#FB546C`（251, 84, 108） |
| 性质 | **取样色，不是 Apple 公布的官方色值。** Apple 没有公布 Apple Music 的品牌色：《Apple Music Identity Guidelines》只提供黑 / 白 / 彩色三版素材，全文没有任何 hex / RGB / Pantone。 |
| 取样来源 | 本机 `/System/Applications/Music.app`（1.6.2，macOS 26.2）的 `AppIcon.icns` 256px 位图：渐变上段 `#FB546C`、中段 `#FA4058`、下段 `#FA2B43`，饱和像素均值 `#F93F57`。浅色取中段；深色取上段（更亮，与系统色深色版一律更亮的惯例一致：systemPink `#FF2D55` → `#FF375F`）。 |
| 对照 | 系统 Pink `#FF2D55` / `#FF375F`、Red `#FF383C` / `#FF4245` 都不是 Apple Music 的颜色，不用。仓库专辑页现有 `Color(red: 0.99, green: 0.24, blue: 0.27)` = `#FC3D45`（`PlaylistView.swift:490/859/878`、`MiniPlayerView.swift:529`）偏橙红，建议后续统一到 `AccentColor`（后续项）。 |
| 用法 | 控件、选中态：`Color.accentColor` / `NSColor.controlAccentColor`（系统「强调色 = 多彩」时生效；用户选了具体颜色时系统按 HIG 覆盖，这是原生行为；Music.app 自己 `NSAccentColorName = KeyColor`）。品牌元素要固定粉色时用 `Color("AccentColor")`。 |
| 对比度 | 白字压 `#FA4058` ≈ 3.5:1（systemBlue ≈ 4.0:1）；Increase Contrast 变体用下段 `#FA2B43`。 |
| 实现 | color set 放新建的 `Sources/MusicMiniPlayerApp/Resources/AppAssets.xcassets`（app target，不放 Core），随 `build_app.sh` 现有 actool 步骤编进 `Assets.car`；Info.plist 手写 `NSAccentColorName`；出包门禁 `assetutil -I Assets.car` 必须含 `AccentColor`。 |

## 0. 结论先行

1. 菜单：纯文字、零勾选、零图标、零 `⌘,`，4 项 3 组——隐藏面板/显示面板 · 翻译为 ▸ | 设置… | 退出 nanoPod。始终 146 × 128（录了面板快捷键时 174 × 128）；没有任何临时项。
2. 「全屏封面」从菜单移到设置（§3.3）：它是设一次不动的显示偏好，在菜单里要么带勾选（宽 +8、正是创始人嫌的组合），要么用「封面铺满面板 / 封面留边」这种绕口的动词对（宽 +39、高 +24）。
3. 设置窗口：480 × 562 单窗口，演示台 + 分段控件 + 分组行，无 sidebar 无工具栏；13 段矢量小动画对应 13 行设置，悬停即演示、切换即回放；Reduce Motion 静帧；一次只动一段，不悬停不动。通用段多一行「认识 nanoPod」，按钮随引导状态在「接着认识 / 重新认识」之间切换（Onboarding 定名）。
4. 剩一个要创始人拍板的点：菜单里「翻译为 ▸」去留（§7）——它是宽度的主要来源（子菜单箭头列 +31pt）。推荐留。

## 1. 现状诊断（不变部分从略，见 v2；这里只列 v3 用到的数）

### 1.1 菜单

现状实测（创始人截图，`research/measure_menu.py`）：203 × 189.5；原生行 24、自定义开关行 26、分隔线 11、上下内边距 5；自定义行标签 13.5pt、文字右偏 2pt；图标墨迹 15–16 vs 12–13.5；自绘开关 33 × 18。

本机 `NSMenu.size` 实测（macOS 26.2，不显示菜单、不依赖 NSApp；脚本在 scratchpad `menusize.swift` / `menusize2.swift`，不进仓库）：

| 因素 | 宽度变化 | 高度 |
|---|---|---|
| 基线：4 个纯文字项（最长「Quit nanoPod」） | 115 | 行 24；上下各 5；分隔线 11 |
| 任一项 `state = .on` | +8（123） | — |
| 一项带 16pt 符号图 | +15（130）；全部带 +21（136）；图 + 勾 +23（138） | — |
| 一项带子菜单（箭头列） | +31（146） | — |
| 子菜单内部有勾选 vs 没有 | 父菜单不变（146 = 146）；子菜单自身 128 vs 120 | — |
| `Settings… ⌘,` | 无子菜单时 +40（155）；已有子菜单时 +9（155） | — |
| 「Hide Player ⌥⌘P」 | 174（有子菜单） | — |

### 1.2 设置窗口

现状：普通 `NSWindow` 里 SwiftUI `TabView` 分段控件 + 20pt 外边距 + `Form(.grouped)`，450 × 400 定死，通用页滚动；`Toggle` 未指定样式（macOS 分组表单默认 checkbox）；标题旧名；每次打开 `center()`；关于页永久脉冲动画；无「登录时启动」；强调色系统蓝。v2 的 sidebar 方案已否：sidebar 220pt 让 app 显大，无轻盈感。

创始人要的参照是系统设置「触控板」页右侧（`ref-system-settings-trackpad.webp`，实测）：顶部两块 150pt 高的演示区、24pt 分段控件、圆角卡片行（标题 13 + 说明 11，行距 53，switch 36 × 16）；悬停行时演示区播放对应手势。

## 2. 设计原则

1. 原生优先：`NSMenuItem`、`Form(.grouped)`、`Picker(.segmented)`、`PhaseAnimator` / `KeyframeAnimator`（macOS 14），不引第三方。
2. 菜单只放次高频，且瘦：不带图标、不带勾选、不带只在菜单打开时才生效的快捷键。
3. 有 Show 就有 Hide：能切换的窗口用动词换标题。
4. 设置靠演示说话：每一行的效果用动画示意，说明文字只留一行；不悬停不动，一次只动一段。
5. 尺寸交给系统：菜单行高、宽度、分组行、switch 全由 AppKit / SwiftUI 决定；只有演示台与窗口尺寸是取值。

## 3. 菜单方案

### 3.1 菜单项清单

| # | 英文 | 中文 | 状态表达 | 快捷键列 | 动作 | 理由 |
|---|---|---|---|---|---|---|
| 1 | Show Player / Hide Player | 显示面板 / 隐藏面板 | 动词换标题：面板可见且未贴边 → Hide；隐藏或已贴边 → Show | 用户录的「显示/隐藏面板」快捷键（`setShortcut(for: .togglePanel)`），未录则空 | `toggleFloatingWindow()` | 面板隐藏后自己叫不回自己，这是菜单存在的第一理由；录了的快捷键是用户自己的信息，值 +28pt 宽 |
| 2 | Translate To ▸ | 翻译为 ▸ | 子菜单单选勾选（不影响父菜单宽度，实测） | 无 | 子菜单：Follow System / 中文 / English / 日本語 / 한국어 / Français / Deutsch / Español（macOS 15+） | 切目标语言面板上没有，也不值得为它开设置 |
| — | 分隔线 | | | | | |
| 3 | Settings… | 设置… | — | 无（去掉 `⌘,`） | `openSettings` | `⌘,` 只在菜单打开期间生效，是个空承诺，还占一列；app 菜单里的 ⌘, 照旧 |
| — | 分隔线 | | | | | |
| 4 | Quit nanoPod | 退出 nanoPod | — | 无 | `NSApp.terminate` | 菜单栏 app 惯例带 app 名；不标 ⌘Q（同上理由） |

英文 title-style capitalization；中文不加空格、不加标点。整份菜单没有图标，没有勾选，没有随状态增减的临时项（引导入口只在设置里，§4.3）。

### 3.2 度量（全部实测或系统）

| 属性 | 值 | 标注 |
|---|---|---|
| 行高 / 上下内边距 / 分隔线 | 24 / 5 / 11 | 实测（`NSMenu.size` 与截图一致） |
| 宽 × 高（EN，未录快捷键） | 146 × 128 | 实测 |
| 宽 × 高（EN，录了 ⌥⌘P） | 174 × 128 | 实测 |
| 宽 × 高（ZH） | 146 × 128；录了 174 × 128 | 实测（子菜单箭头列决定宽度，中英同宽） |
| 文字起点 | 系统（纯文字项约 21pt；没有勾选列、没有图标列） | 系统 |
| 字体 | 13pt 系统菜单字体 | 系统 |
| 子菜单「翻译为」 | 128 × 202（8 项，勾选列 +8 只在子菜单自身） | 实测 |
| 高亮 / 键盘导航 / VoiceOver | 系统 | 原生项自带 |

### 3.3 砍掉与不加的项（含论证）

| 项 | 处理 | 理由 |
|---|---|---|
| **全屏封面**（v2 在菜单里带勾选 + 图标） | 移出菜单，只在设置「面板」页（带演示动画） | 它改的是专辑页封面尺寸（`MiniPlayerView.swift:461/821`：铺满 = 面板宽，否则 68%，悬停 48%），是设一次不动的显示偏好，不是听歌时反复切的动作。留在菜单只有两种写法：勾选（宽 +8，正是创始人嫌难看的组合的一半）或动词对「封面铺满面板 / 封面留边」（EN「Fill Panel with Cover / Fit Cover in Panel」，实测宽 +39、高 +24，且「留边」不是用户会主动想的词）。移出后菜单 146 × 128。若创始人仍要留：用动词对，185 × 152。 |
| 显示翻译 | 不进菜单 | 面板歌词页底部已有同一开关（`HoverableButtons.swift:256–325` 的 `TranslationButtonView`，挂在 `SharedControls.swift:280–295`）；v2 已论证，创始人未反对 |
| `⌘,`、⌘Q | 不标 | 只在菜单打开期间生效；`⌘,` 有子菜单时仍占 +9pt |
| 图标 | 全部不带 | 创始人 09-26：不必每项都有图标；再瘦一些。实测一个图标 +15、全部 +21 |
| Play/Pause、Next、Previous、Open Music、About、Check for Updates… | 不进菜单 | 同 v2：面板/媒体键/设置/关于页/完整版 |
| 自绘开关与自定义行 4 个类型 | 删除 | 同 v2 |

### 3.4 分组与分隔线（反馈 c）

| 方案 | 结构 | 高 | 判断 |
|---|---|---|---|
| 1 条分隔线 | [隐藏面板 · 翻译为 ▸ · 设置…] \| [退出] | 117 | 「设置…」混进操作组，读起来像面板功能；省 11pt 不值 |
| **2 条（推荐）** | [隐藏面板 · 翻译为 ▸] \| [设置…] \| [退出] | 128 | 操作 / app / 退出三组，与 Time Machine、Ice 等菜单栏菜单一致 |
| 3 条 | [隐藏面板] \| [翻译为 ▸] \| [设置…] \| [退出] | 139 | 4 项 3 线，松 |

### 3.5 对比表（反馈 d）

| 版本 | 宽 × 高（pt） | 项 / 分隔线 | 图标 | 勾选 | 快捷键列 | 来源 |
|---|---|---|---|---|---|---|
| 现状 | 203 × 189.5 | 6 / 3 | 6 个 | 0（两个自绘开关） | 无 | 创始人截图实测 |
| v2 | 227 × 163（录了 ⌥⌘P）；208 × 163（未录） | 5 / 3 | 3 个 | 1 | ⌥⌘P、⌘, | `NSMenu.size` 近似（原生项复刻 v2 结构） |
| **v3** | **146 × 128**（未录）；174 × 128（录了） | 4 / 2 | 0 | 0 | 仅用户录的快捷键 | `NSMenu.size` 实测 |
| v3 若保留全屏封面（动词对） | 185 × 152 | 5 / 2 | 0 | 0 | — | `NSMenu.size` 实测 |
| v3 若去掉「翻译为 ▸」 | 115 × 104 | 3 / 2 | 0 | 0 | — | 推算：箭头列 −31，一行 −24 |

v3 对现状：宽 −28%，高 −33%；对 v2：宽 −30%～−36%，高 −21%。

### 3.6 实现要点（菜单）

- `populateMenuBarMenu` 只产生纯文字 `NSMenuItem`：不设 `image`、不设 `state`、不设 `keyEquivalent`（#1 除外：`setShortcut(for: .togglePanel)`）。`menuNeedsUpdate` 每次打开重建。
- #1 标题：`floatingWindow?.isVisible == true && liquidEdge?.isActive != true` → Hide，否则 Show。
- 菜单不读引导状态，不插任何临时项；引导入口只在设置「通用」段（§4.3）。
- 菜单打开期间禁用全局热键：`menuWillOpen` → `GlobalShortcutRegistrar.deactivate()`，`menuDidClose` → `activate()`（KeyboardShortcuts 文档要求）。
- 子菜单：当前语言 `state = .on`，「跟随系统」第一项。
- 删除 `MenuBarMenuMetrics`、`MenuBarCustomItemView`、`MenuBarSwitchItemView`、`CompactSwitchControl`；L10n 删 `mb.*`、`showWindow`，加 `showPlayer` / `hidePlayer` / `translateTo` / `quitApp`；`settings` 改「Settings…」/「设置…」；`GlobalShortcutAction.togglePanel` 标题改「Show/Hide Player」/「显示/隐藏面板」。

## 4. 设置方案（演示台 + 分段 + 分组行）

### 4.1 为什么这样更轻

- 无 sidebar、无工具栏：窗口 480 宽（v2 720），一眼一列；标题栏只有「Settings / 设置」。
- 顶部少量分页而不是单页滚动：全部 14 行摊开约 700pt，再加演示台就要滚；4 段各 4–5 行，一屏放完不滚动。分段控件是「触控板」页自己的语言（Point & Click / Scroll & Zoom / More Gestures）。
- 演示台一个、共用：一次只播一段，不悬停不动，空闲零合成成本（创始人对 WindowServer 成本敏感，见 defect 5）；比每行各配一段常驻动画轻得多。
- 行只留标题 + 一行说明 + switch，效果交给演示台讲。

### 4.2 结构与尺寸

| 部件 | 尺寸 / 位置 | 内容 |
|---|---|---|
| 窗口 | 内容 480 × 562（取值：20 + 120 + 14 + 24 + 14 + 350 + 20），标题栏 28；`styleMask [.titled, .closable]`；不可缩放、不可最小化（HIG Settings）；`setFrameAutosaveName`；⌘W 关闭 | 标题「Settings」/「设置」 |
| 演示台 stage | 440 × 120（取值），圆角 10，卡片色底（与分组卡片同色）；左下角 11pt secondary 说明当前演示的行名 | 当前段第一行的静帧；悬停某行 → 播该行动画循环；切换该行的开关/选项 → 播一次到新状态；离开 → 停在最后一帧 |
| 分段控件 | 440 × 24，`Picker(.segmented)`：Player · General · Shortcuts · About / 面板 · 通用 · 快捷键 · 关于 | 选中段 = 强调色（多彩时 Apple Music 粉） |
| 分组行 | `Form(.grouped)`，固定高 350（最长的通用段 6 行 + 脚注约 350），仅内容溢出（放大字体）时滚动 | 见 4.3 |
| 关于段 | 演示台 + 分组行整块换成 `AboutPageView` 占位（图标、名称、版本、三条链接） | 动画另开会话 |
| 边距 | 四周 20；stage–分段 14；分段–Form 14 | 取值 |

### 4.3 逐段逐行 + 演示动画

演示台的画面全部由 SwiftUI 形状拼成，四个共用部件：`MiniScreen`（200 × 125 圆角矩形 + 顶部 10pt 菜单栏条 + 可选 Dock 胶囊）、`MiniPanel`（62.5 × 71 = 真实面板 250 × 284 的 1/4，圆角 4，里面封面方块 + 两条文字条 + 三个控制点）、`LyricSheet`（三条歌词条，中间一条亮，下方可出译文条）、`Keycap`（圆角键帽，显示用户录的快捷键 `Shortcut.description`；未录则虚线空键帽）。

**Player / 面板**

| 行 | 控件 | 说明文字 | 演示动画（悬停循环 / 切换回放） | Reduce Motion 静帧 |
|---|---|---|---|---|
| Fullscreen Cover / 全屏封面 | switch | Fill the panel with the album cover. / 专辑封面铺满面板。 | `MiniPanel` 专辑页：封面从 68% 宽居中（真实值 `artSize = 0.68 × width`）弹到铺满面板宽，文字条压到底部渐变上；停 1.2s 弹回。弹簧用面板自己的常数 `.spring(response: 0.5 / 0.4, dampingFraction: 0.85)`（`MiniPlayerView.swift:461`） | 按当前值定格 |
| Show Song on Track Change / 换歌时显示歌曲 | switch | When tucked into the screen edge, briefly show the new song. / 贴边收起时短暂显示新歌。 | `MiniScreen` 右缘一道 6 × 56（按比例）的贴边条带进度光；「换歌」→ 胶囊（封面 + 标题条）从边缘滑出，停 2.5s（LiquidEdge 自动探出的真实时长），缩回。关：只有条上的光换色，不探出 | 条 + 胶囊探出态 / 条 |
| Show Translation / 显示翻译 | switch | Translated lines appear under the original. / 译文显示在原文下方。 | `LyricSheet`：亮行下方译文条淡入（0.35s），上下行让位；关 → 淡出并合拢 | 有/无译文 |
| Translate To / 翻译为 | Picker（menu） | 无 | `LyricSheet` 的译文条换成所选语言的样句（交叉淡入 0.25s）：Let's go see the sea → 我们去看海吧 / 海を見に行こう / 바다 보러 가자 / Allons voir la mer / Lass uns ans Meer fahren / Vamos a ver el mar；「跟随系统」按系统语言 | 当前语言样句 |

**General / 通用**

| 行 | 控件 | 说明文字 | 演示动画 | 静帧 |
|---|---|---|---|---|
| Launch at Login / 登录时启动 | switch（`SMAppService.mainApp`；`.requiresApproval` 时行下加「Approval required in System Settings」+「Open Login Items…」） | 无 | `MiniScreen` 从暗到亮（0.4s，像刚登录），菜单栏条上 ♪ 弹出（scale 0.6 → 1）。关：亮起后菜单栏没有 ♪ | 亮屏 + 有/无 ♪ |
| Show in Dock / 在 Dock 显示 | switch | 无 | `MiniScreen` 底部 Dock 胶囊 4 个灰块，nanoPod 块插入（邻块让位、块弹入）；关：抽出、Dock 收窄 | 有/无块 |
| Getting to know nanoPod / 认识 nanoPod | 右侧按钮，文字随引导状态变（Onboarding §9.2 定名）：没走完（skipped 或中途停下）→「Keep getting to know nanoPod」/「接着认识 nanoPod」，点了从上次停下处接着走（不重置进度，`showOnboardingWindow()`）；走完了 →「Get to know nanoPod again」/「重新认识 nanoPod」，点了从头走（重置 `OnboardingState` 完成标志再 `showOnboardingWindow()`）。按钮宽度按较长的英文「Keep getting to know nanoPod」排，两种文字同宽不跳 | 无 | 静态示意：`MiniPanel` 旁一张小引导卡（圆角卡 + 进度环轮廓）；不动 | 同左 |
| Music Automation / Music 自动化 | 状态文字 + 按钮（未决定 → Grant Access…；已拒绝 → Open System Settings…） | 组脚注：nanoPod reads what's playing and controls Music through Automation. Apple Music access adds artwork and song info. | 静态示意：Music 图标（圆角方块 ♪）→ 箭头 → `MiniPanel`；已授权箭头实线、面板有曲名条；未授权箭头虚线、面板空 | 同左（本行本来就是静态） |
| Apple Music | 同上（MusicKit） | | 静态示意：`MiniPanel` 封面方块有色（已授权）/ 灰色占位（未授权） | 同左 |
| Playback History / 播放记录 | `Clear…` 按钮 + `confirmationDialog` | nanoPod's own record of played tracks. / nanoPod 自己记录的播放历史。 | 静态：`MiniPanel` 历史页三行；点「清除」后三行淡出（一次） | 三行 |

**Shortcuts / 快捷键**（5 行 `KeyboardShortcuts.Recorder`，库自带标签左录制框右；脚注 Shortcuts work in any app. None are set by default. / 快捷键全局生效；默认未设置）

| 行 | 演示动画（键帽显示已录组合；未录则虚线空键帽） | 静帧 |
|---|---|---|
| Play/Pause | 键帽按下（scale 0.92，120ms）→ `MiniPanel` 播放图标 ▶︎ ⇄ ❚❚（`contentTransition(.symbolEffect(.replace))`），进度条停/走 | 键帽 + ▶︎ |
| Next Track | 键帽按下 → 封面方块向左滑出、新封面（另一色）滑入，标题条换宽度 | 键帽 + 面板 |
| Previous Track | 同上镜像 | 同上 |
| Show/Hide Player | 键帽按下 → `MiniScreen` 里的面板淡出（用 `MicroInteractionFeel.Tokens.windowFadeOutDuration`），再按淡入 | 键帽 + 面板 |
| Hide to Edge | 键帽按下 → 面板滑向右缘并收成贴边条（弹簧），再按展回 | 键帽 + 贴边条 |

**About / 关于**：占位——真实 app 图标 64pt、「nanoPod」17pt、「Version 0.28 (build …)」11pt secondary、GitHub · Acknowledgements · Report an Issue；完整版多「Check for Updates…」，纯净版不编入；无动画。整块区域预留给动画会话，实现放独立 `AboutPageView`。

### 4.4 实现要点（设置）

- 结构：`VStack { DemoStage; Picker(.segmented); Form(.grouped) }` 装进 `NSHostingController`，`NSWindow(contentViewController:)`，`styleMask [.titled, .closable]`，`setContentSize(480 × 562)`，`setFrameAutosaveName("Settings")`。不用 `NavigationSplitView`、不用工具栏。
- 每行 `Toggle(...).toggleStyle(.switch)`；说明文字 `.font(.subheadline).foregroundStyle(.secondary)`；权限行 `LabeledContent`。
- 演示台：`enum SettingsDemo`（13 个 case + `about`）；`DemoStage(demo:state:playToken:)`。动画驱动：macOS 14 的 `PhaseAnimator(phases, trigger: playToken)`——每次 `playToken` 变化把各阶段走一遍、停在末态（正好是「切换回放一次」）；悬停循环 = 悬停期间每个周期结束时再 +1 `playToken`（`TimelineView(.periodic)` 或 `Task.sleep` 循环，离开即停）；贴边探出这种多段时间轴用 `KeyframeAnimator`。播放/暂停图标用 `Image(systemName:)` + `.contentTransition(.symbolEffect(.replace))`。全部 `RoundedRectangle` / `Capsule` / `Text` / `Image(systemName:)`，无位图、无第三方。
- 时间常数复用 app 自己的：封面弹簧 `response 0.5/0.4, damping 0.85`（`MiniPlayerView`）；窗口淡出 `MicroInteractionFeel.Tokens.windowFadeOutDuration`；贴边探出停留 2.5s（LiquidEdge autoPeek）。演示演的就是真实曲线。
- 悬停意图：复用 `SharedControls.swift` 的 `ProgressHoverIntentEngine`（指针停留 150ms 且期间移动不超过 4pt 才算停住，按鼠标事件判定、不定时采样；`docs/craft-notes.md` 09-25 条，创始人 09-26 真机验收通过）——路过的行不切换演示。离开行不清空，停在最后一帧。
- Reduce Motion：`@Environment(\.accessibilityReduceMotion)` 为真时不挂 `PhaseAnimator`，直接画 `demo.restingFrame(state:)`；悬停只切静帧，无过渡。
- 成本：一次只有一段动画；无悬停、无切换时演示台是静态视图，不挂 `TimelineView`；窗口 `orderOut` / 遮挡（`NSWindow.didChangeOcclusionStateNotification`）时停循环。
- 辅助功能：演示台 `.accessibilityHidden(true)`（纯装饰），行自带标签；键帽文字随录制值更新。
- 强调色：`AccentColor`（见文首）；演示台里面板的「当前行」高亮与贴边光用 `Color.accentColor`。
- 记住段：上次段写 UserDefaults；`nanopod://settings/<player|general|shortcuts|about>`，`appearance` 与 `lyrics` 作 `player` 别名；`showSettingsWindow(selectedTab: .shortcuts)` 供引导最后一张卡「录个快捷键」直达。
- L10n 新键：`tour.settings.title`（「Getting to know nanoPod」/「认识 nanoPod」）、`tour.settings.keepGoing`（「Keep getting to know nanoPod」/「接着认识 nanoPod」）、`tour.settings.again`（「Get to know nanoPod again」/「重新认识 nanoPod」）。按钮用 `fixedSize` + 以 keepGoing 文案测出的最小宽度，切换文字不改行宽。
- 手感臂：`settingsTab` 自定义 crossfade 臂随 TabView 删除；`settingsToggle` 脉冲臂默认 `.system`（演示台回放已是切换反馈）。
- 主菜单三处「Music Mini Player」与窗口标题改 nanoPod。

### 4.5 风险与边界

| 边界 | 处理 |
|---|---|
| 深浅色 | 分组行、switch、分段控件系统绘制；演示台用语义色（`.primary/.secondary/.quaternary` + `Color.accentColor`），两套外观自动成立 |
| Liquid Glass | 不加任何材质；窗口是普通不透明设置窗口 |
| Reduce Motion / Reduce Transparency / Increase Contrast | 静帧；无透明材质；`AccentColor` 高对比变体 |
| 用户强调色 ≠ 多彩 | switch、分段选中、演示台高亮跟用户色（HIG），不硬编码粉 |
| macOS 14 | `PhaseAnimator` / `KeyframeAnimator` / `contentTransition(.symbolEffect)` 均 macOS 14+；翻译两行与菜单「翻译为」按 `#available(macOS 15.0, *)` 隐藏 |
| macOS 15 沙盒 | 录快捷键时单独 Option 不允许，库自带中文提示 |
| 放大字体 | Form 区固定 320 高，溢出时 Form 自身滚动 |
| 沙盒 / App Store | `SMAppService`、`NSApp.terminate`、`x-apple.systempreferences:`、KeyboardShortcuts 均公开 API；「Check for Updates…」只在完整版 |
| 演示与真实不一致 | 演示只用比例和真实时间常数，不承诺像素；说明文字仍是权威 |
| 面板是 `.nonactivatingPanel` | 打开设置已 `NSApp.activate`，不改 activation policy |

## 5. 代码层验收项（创始人禁止截图 / 录屏 / computer use；最终视觉由他本人验收）

菜单：
1. `populateMenuBarMenu` 产出的每个 item：`view == nil`、`image == nil`、`state == .off`（子菜单项除外）。
2. 标题序列快照（en / zh）与分隔线位置等于 §3.1；引导状态取 completed / skipped / 中途停下三种时，菜单项数与标题都不变（菜单不含任何引导入口）。
3. 面板可见且未贴边 → 「Hide Player」；否则「Show Player」。
4. 只有 #1 可能有 `keyEquivalent`（隔离 defaults 录入后出现、清除后为空）；Settings… 与 Quit `keyEquivalent == ""`。
5. `menuWillOpen` → `deactivate()`、`menuDidClose` → `activate()`。
6. 「翻译为」子菜单恰一项 `.on`，与 `translationLanguage` 一致。
7. 尺寸门：把 `populateMenuBarMenu` 产出的菜单交给 `NSMenu.size`，EN 未录快捷键时宽 ≤ 150、高 ≤ 130（当前实测 146 × 128）；这条测试就是本文数字的回归线。
8. 标题不含 `"..."`，需要处含 U+2026。

设置：
1. 段序列 `[player, general, shortcuts, about]`（DEBUG 末尾多 `diagnostics`）；macOS 14 下 Player 段不含翻译两行。
2. 窗口 `styleMask` 不含 `.resizable` / `.miniaturizable`；内容尺寸 480 × 562；`title` 双语。
2a. 通用段「认识 nanoPod」行：引导未走完（skipped 或中途停下）时按钮标题为「Keep getting to know nanoPod」/「接着认识 nanoPod」，点击不重置进度、引导窗口被请求显示；走完时标题为「Get to know nanoPod again」/「重新认识 nanoPod」，点击后 `hasCompletedOnboarding == false` 且引导窗口被请求显示（注入假窗口所有者计数、假状态三态）；两种标题下按钮宽度相同。
3. 选中段持久化；`openSettingsPage(named: "appearance" | "lyrics")` 落到 `.player`。
4. 每个 `Toggle` 显式 `.toggleStyle(.switch)`（源码断言计数相等）。
5. `SettingsDemo.allCases` 与设置行一一对应（每行声明 `demo`，`Set` 相等）；每个 case 有 `restingFrame(state:)`。
6. Reduce Motion 注入为真时，`DemoStage` 的 body 不含 `PhaseAnimator` / `KeyframeAnimator` / `TimelineView`（用 `Mirror` 或类型断言）。
7. 悬停意图：假时钟驱动 `ProgressHoverIntentEngine`，快速掠过（停留不足 150ms）不切换 demo，停住 150ms 后切换。
8. 登录时启动通过协议 register / unregister；`status` 三态驱动 switch 与说明行。
9. `Assets.car` 含 `AccentColor`；`Info.plist` `NSAccentColorName == "AccentColor"`；color set 分量 `#FA4058` / `#FB546C`。
10. `AboutPageView` 不含 `symbolEffect` / `PhaseAnimator`；AppKit 目标源码不再出现「Music Mini Player」。

## 6. 视觉稿说明

`mockup.html`：菜单「现状 vs v3」（深/浅/中文，1:1）；设置窗口三段（面板 浅色、通用 深色、快捷键 浅色）+ 关于占位；一排 8 个演示台缩略图，说明每段动画演什么。演示台画面是静帧示意，动效只能真机看。

## 7. 需创始人拍板（唯一）

**「翻译为 ▸」是否留在菜单。** 它是 v3 宽度的主要来源：子菜单箭头列 +31pt（146 → 115），少它菜单是 115 × 104。推荐留：切目标语言是听多语种歌时会做、面板上又没有的操作，设置里翻两层不如菜单一层。若创始人要更瘦，去掉它，语言只在设置「面板」段切。

其余按推荐值写定：全屏封面移出菜单；`⌘,` 不标；2 条分隔线；设置 4 段 + 演示台；关于占位。

## 8. 调研与实测来源

- 创始人反馈 09-26 上午（sidebar、粉色、菜单次高频）与下午（去勾选加图标、再瘦、不要 sidebar、要触控板页式演示）。
- `NSMenu.size` 实测（macOS 26.2，本机，不显示菜单）：scratchpad `menusize.swift` / `menusize2.swift`（按要求不进仓库）；关键数字：行 24、分隔线 11、上下 5；`.on` +8、图标 +15/+21、子菜单箭头 +31、子菜单内勾选不影响父菜单、`⌘,` +40（无子菜单）/ +9（有子菜单）；v3 146 × 128、v2 近似 227 × 163。
- 参考图实测：`research/measure_menu.py`（现菜单 203 × 189.5）、`research/measure_system_settings*.py`（触控板页：演示区 150 高、分段 24、卡片行距 53、标题 13 / 说明 11、switch 36 × 16）。
- 强调色取样：Music.app 1.6.2 `AppIcon.icns`；`NSAccentColorName = KeyColor`；本机系统色实测；Apple Music Identity Guidelines 无色值。
- 仓库：`MiniPlayerView.swift:461/821`（全屏封面 = 封面宽 100% vs 68%/48%）、`:141/153/206…`（弹簧 0.5/0.4, 0.85）；`HoverableButtons.swift` `TranslationButtonView`；`SharedControls.swift` `ProgressHoverIntentEngine`；`docs/craft-notes.md`（hover intent 100ms / 4pt）；`OnboardingState.hasCompletedOnboarding`；`docs/design/2026-09-25-onboarding/proposal.md` §9.2（「认识 nanoPod」「接着认识 nanoPod」「重新认识 nanoPod」定名）；`MicroInteractionFeel.Tokens.windowFadeOutDuration`；LiquidEdge autoPeek 2.5s（memory 09-22）。
- Apple 文档 / HIG（v2 已列）：HIG Menus / The menu bar / Settings / Toggles / Color；`NSMenuItem.view` / `state` / `image`；`ToggleStyle.automatic`（macOS → checkbox）；`PhaseAnimator`、`KeyframeAnimator`、`contentTransition(.symbolEffect)`（macOS 14）；`NSAccentColorName`（macOS 11）；`SMAppService.mainApp`（13）。
- KeyboardShortcuts 3.0.1：`setShortcut(for:)`、`Shortcut.description`、`RecorderCocoa` 130 × 24、README 沙盒兼容。
