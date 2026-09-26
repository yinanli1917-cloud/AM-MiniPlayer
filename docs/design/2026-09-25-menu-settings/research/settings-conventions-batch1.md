# Settings 窗口设计调研：CleanShot X / Raycast / iStat Menus 7 / Bartender 5 / Klack / Hand Mirror

纯文本检索结果，没有用 computer use 或截图，所以很多视觉细节(尤其小厂 App)找不到独立来源佐证。能证实的都标了来源链接；找不到可信来源的一律写"未证实"，没有替换成别的 App 的情况去猜。

## 速览表(方便跳读，细节看下面分节)

| App | 整体布局 | 标签/页数(大致) | 控件样式 | Launch at Login 位置 | About 位置 |
|---|---|---|---|---|---|
| CleanShot X | sidebar+content(v5 改版后) | ≥6(General/Recording/Screenshots/Wallpaper/Shortcuts/History/Advanced) | switch(v5 起，取代了 v4 的 checkbox) | 未证实 | 未证实 |
| Raycast | sidebar+content(官方原文确认) | ~10 个侧栏分区 | 未证实具体样式 | General 分区 | 独立 About 分区 |
| iStat Menus 7 | 图标式 sidebar+content | 模块图标 9-10+ 个，另有 Global/Rules/Notifications 等全局标签 | switch(至少模块启用开关是) | 未证实(App 内位置) | 未证实 |
| Bartender 5 | 确认分标签，具体样式未证实 | ≥6(Menu Bar Items/Preset/Appearance/Hotkeys/General/Advanced) | 未证实 | General 标签(中等置信度) | 未证实 |
| Klack | 未证实 | 至少 General/Sound 两块(截图文件名推断) | 未证实 | 未证实 | 未证实 |
| Hand Mirror | 未证实 | 未证实(只确认有"Notch Trigger panel"一个分组名) | 未证实 | 未证实 | 未证实 |

---

## 1. CleanShot X

**整体布局**：v5 改版把 v4 的单栏列表式布局，换成了左侧 sidebar + 右侧内容面板的两栏式设计，作者原话形容为"mirrors macOS Ventura's system settings pattern"(仿照 macOS Ventura 系统设置的样式)。这是一篇专门评论这次改版的设计评论文章，高置信度。来源：[CleanShot's bulldozed settings – Unsung](https://unsung.aresluna.org/cleanshots-bulldozed-settings/)

**标签数量**：该评论文章明确点名的面板有 Quick recording settings、General、Recording、Advanced。其余来源(检索摘要级，非直接原文核实)补充确认还有：Shortcuts 标签(菜单栏下拉 → Settings → Shortcuts tab，点击某条快捷键后按组合键即可录制)[KeyScreen 教程](https://keyscreen.app/cleanshot-x-keyboard-shortcuts)；Wallpaper 标签(截图加桌面壁纸背景+投影)[Sayz Lim 的评测](https://sayzlim.net/snappy-to-cleanshot-x/)；History 标签(提及"Preferences > History"，来自搜索摘要，未直接核实原文，中等置信度)。屏幕录制相关设置横跨 General/Video/GIF 三个面板。

**每个标签的设置组数**：没有单一来源给出精确统计。General 至少含"自动打开 Annotate""自动复制到剪贴板""Hide while capturing(截图时隐藏桌面图标)""Optimize PNG size"等≥4 项；Advanced 内明确是 3 个关于置顶截图(pinned screenshot)的 checkbox(圆角/投影/边框)。

**窗口尺寸**：未证实，没有任何来源给出具体像素数字，也没有来源明说是否可调整大小。

**控件样式**：v4 用 checkbox + radio button；v5(现行版本)把 checkbox 换成了 switch(开关式控件)、radio button 换成了下拉菜单(pop-up menu)，评论文章原话是"every panel looks much more alike"(各面板视觉上更趋同)。这是本次调研里对控件样式最确凿的一条证据。来源同上。

**inline 说明性小字**：未证实具体视觉形式。评论文章倒是提出了一个相关但不同的批评——两栏式布局让"标签与控件视觉上脱节(labels are disconnected from their controls)"，控件普遍右对齐("right alignment is harder to process in a left-to-right language")，但这说的是对齐问题不是有没有灰色小字说明，两者不能划等号。

**About 位置**：未证实。

**Launch at Login 位置**：未证实，检索没有找到任何一处提到 CleanShot X 的开机启动选项具体在哪个标签。

**快捷键设置页布局**：确认存在独立 Shortcuts tab，交互方式是点击某一行、按下想要的组合键([来源](https://keyscreen.app/cleanshot-x-keyboard-shortcuts))；但录制控件是否逐行右对齐没有来源明确描述，未证实(评论文章提到的"右对齐"是针对一般设置项的整体设计趋势，不专指 Shortcuts tab，不能直接当作确认)。

---

## 2. Raycast

**整体布局**：官方 manual 原文确认是 sidebar 导航模式，不是 toolbar 式图标+文字标签："The Settings window focuses sidebar navigation when opened"。来源：[Settings | Raycast Manual](https://manual.raycast.com/settings)（直接核实原文，高置信度）

**标签数量**：sidebar 列出的分区有 Account、General、AI、Applications、Launcher、Shortcuts、Keyboard、Advanced、Organizations(仅 Teams 版可见)、About，另外底部单独一块 Extensions(再按 Built-in commands / Store extensions / Script Commands / Quicklinks 分类，每个扩展还有自己的一套偏好设置子页)。总共约 10 个主分区。每页组数举例：General 内部再分 Open at Login / Show in Menu Bar / Raycast Hotkey / Appearance 约 4 组。来源同上。

**窗口尺寸**：未证实，manual 没给具体尺寸或是否可调整大小的说明。

**控件样式**：manual 里出现"Toggle this off to manually choose a theme"这类措辞，说明存在开关类控件，但没有明说视觉上是 switch 还是 checkbox，未能坐实具体样式。

**inline 说明性小字**：确认存在。快捷键设置项下方会有引导性小字，比如"The default is ⌥Space"。来源：[Settings | Raycast Manual](https://manual.raycast.com/settings)

**About 位置**：sidebar 里独立的 About 分区，显示当前版本号，附官网和更新日志链接。来源同上。

**Launch at Login 位置**：General 分区下的"Open at Login"子项。来源同上。

**快捷键设置页布局**：Settings 内有两个相关分区——Shortcuts(鸟瞰所有已分配的快捷键，"gives you a bird's-eye view of every shortcut assigned across Raycast")和 Keyboard(定制键盘导航方式)。录制控件的行为：按键会实时显示成按键样式的图形，输入合法组合后有约 1.5 秒进度条倒计时后自动保存，冲突时用红色高亮提示冲突对象。来源：[Command Aliases & Hotkeys | Raycast Manual](https://manual.raycast.com/command-aliases-and-hotkeys)。是否右对齐：Settings 里 Shortcuts 列表页本身的对齐方式没有直接核实到，但另一处 Action Panel(操作面板，注意不是 Settings 页面本身)明确是"每个操作的快捷键显示在右侧"，这条来自搜索摘要转述，未直接 fetch 到 [Action Panel | Raycast Manual](https://manual.raycast.com/action-panel) 原文，中等置信度，且要注意这是 Action Panel 不是 Settings 窗口，不能直接套用。

---

## 3. iStat Menus 7

**整体布局**：图标式 sidebar + 内容面板。操作方式是"select an icon"以及"⌥-click 侧栏图标来开关某一项"，这条措辞来自搜索摘要综合(可能源自 bjango 官方帮助文档的 Menus 页)，未直接 fetch 到该页原文逐字确认，中等偏高置信度。我直接核实过原文的是 Global 设置页：[Global | iStat Menus 7 帮助文档](https://bjango.com/help/istatmenus7/global/)。

**标签数量**：sidebar 图标对应的是各个可独立开关的监控模块，确认至少包括 Global、Rules、Weather、Processor(CPU & GPU)、Disks、Network、Sensors、Power、Combined，另有独立的 Notifications 设置(几乎每个监控项都能配置提醒阈值)。这是六款 App 里标签(侧栏图标)数量明显最多的一个——每个被监控的系统指标都对应一个独立图标，跟 CleanShot X / Bartender 那种"功能分类标签"性质不同。来源综合自 [iStat Menus 7 帮助首页](https://bjango.com/help/istatmenus7/welcome/)、[TheSweetBits 评测](https://thesweetbits.com/tools/istat-menus-review/)。

**Global 页设置组数**：直接核实原文，共 3 组——① 主题(theme carousel，上半控制所有菜单栏项主题、下半控制所有下拉菜单主题)；② 菜单栏间距(Normal / Compact 两档，"compact can't be used if you have multiple displays attached")；③ 刷新频率(数据采样频率，快慢有性能取舍)。来源：[bjango.com/help/istatmenus7/global/](https://bjango.com/help/istatmenus7/global/)

**窗口尺寸**：未证实。

**控件样式**：switch。原话是"turn on the large switch near the top of the window"来启用/停用一个监控模块，多条独立检索都一致提到"large switch"这个具体措辞，但均为搜索摘要转述而非我直接读到 bjango 原文逐字，中等偏高置信度。

**inline 说明性小字**：部分证实。Global 帮助页里确实有"compact can't be used if you have multiple displays attached"这类解释文字，但这是我从 Help 文档拿到的说明，不能 100% 确认它在实际 Preferences 窗口里就是"标签下方的灰色小字"这种视觉形式——也可能只是帮助文档单独的解释，具体视觉呈现方式未证实。

**About 位置**：未证实，多次检索没找到任何来源提及。

**Launch at Login 位置**：没有在 App 自身 Preferences 里找到位置说明。唯一找到的相关文档是一篇故障排查页，指导用户去系统层面的 System Settings → General → Login Items 手动关闭再打开来修复登录项失效问题——这不代表 App 内没有自己的开关，只是没查到 App 内部对应设置项在哪个标签。来源：[Login items | iStat Menus 7 帮助文档](https://bjango.com/help/istatmenus7/loginitems/)(直接核实原文)

**快捷键设置页**：未证实是否存在。

---

## 4. Bartender 5

**整体布局**：确认是分标签(tab-based)的 Preferences 窗口，"设置会记住上次打开时所在的标签页"(Settings opens to whichever tab you opened last)，这条来自搜索摘要综合(引用 macbartender.com)。但具体是 toolbar 图标+文字标签、还是左侧 sidebar 列表，没有任何来源描述，未证实。

**标签数量**：针对 Bartender 5(不是旧版)，综合多个直接 fetch 到的评测确认存在：Menu Bar Items(显示/隐藏/始终隐藏 三分区拖放管理，含"Add a spacer"和"Add menu bar item group"两个工具)[来源](https://eshop.macsales.com/blog/86939-bartender-5-serves-up-your-mac-menu-bar-with-custom-decluttered-style/)；Preset(预设布局，可配合 Trigger 按 App 自动切换)、Appearance(图标可见性开关 + 菜单栏色调/描边粗细颜色/圆角自定义)、Hotkeys(显示隐藏项/隐藏左侧 App 菜单/显示全部/搜索框聚焦 等功能的全局快捷键)[来源](https://mausereviews.wordpress.com/2024/06/14/bartender-5-customize-your-overloaded-menu-bar/)。另一个付费视频教程的章节标记显示还有"General Settings"和"Advanced"两个章节，但只看到章节标题没看到正文内容([ScreenCastsOnline](https://www.screencastsonline.com/tutorials/setapp/bartender-5))。

需要特别说明一点：我另外找到一篇 HowToGeek 文章描述的标签名是"Menu Items"(不是"Menu Bar Items")、"Hot Keys"、"General"、"Appearance"、"Advanced"，用词跟 macbartender.com 官方明确标注为 Bartender 3 的帮助页([Bartender Preferences | Bartender 3](https://www.macbartender.com/gettingstarted/bartender-preferences/))一致，判断那篇文章说的其实是旧版 Bartender 3/4，不是当前的 5(Podfeet 对 5 的评测标题就是"a Major Upgrade in Style"，暗示 UI 有较大改动)。为避免误导，那篇文章里"checkbox 控件""左侧列表布局"这类具体细节我没有当作 Bartender 5 的证据用，只用它佐证 General/Advanced/Hotkeys 这几个标签名字大概率延续了下来。

**每个标签设置组数**：Menu Bar Items 约 3-4 组(如上)；Appearance 约 2-3 组(图标可见性 + 菜单栏样式)。其余标签内部分组未证实。

**窗口尺寸**：未证实。

**控件样式**：未证实，没有任何 Bartender 5 专属来源明确说是 switch 还是 checkbox。

**inline 说明性小字**：未证实。

**About 位置**：未证实，多方检索没找到。

**Launch at Login 位置**：General 标签，功能名叫"Start at Login"。有一篇官方博客专门讨论"start at login not working after updating from 4"这个故障，标题本身印证了该功能确实叫这个名字、且在 Bartender 的 Settings 里；但我 fetch 正文时只拿到故障排除步骤原文"Disable Start at Login in Bartender Settings, quit Bartender"，没有直接点名标签页名字，"在 General 标签"这一点来自另一条搜索摘要综合，非逐字核实，整体中等置信度。来源：[Bartender 5 - start at login not working](https://www.macbartender.com/b5blog/Bartender5-start-at-login/)

**快捷键设置页布局**：确认 Hotkeys 是独立区域，能为固定几个功能分别设置全局快捷键(来源同 Preset 那条)；是否逐行右对齐、录制控件长什么样，没有 Bartender 5 专属来源描述，未证实。

---

## 5. Klack

**整体布局**：确认有独立 Settings 窗口，从菜单栏下拉菜单里的"Klack Settings…"项打开——注意这个下拉菜单本身还另外有"Sound"和"Switches"两个子菜单用于快速切换，这是菜单栏下拉菜单自己的结构，不等于 Settings 窗口内部的标签结构。这条是直接 fetch 官网原文确认的：来源 [tryklack.com](https://tryklack.com/)。

Settings 窗口内部：从第三方文章里两张贴图的文件名"023-klack-settings-general.png"和"023-klack-settings-sound.png"可以推断，Settings 窗口内至少分 General 和 Sound 两块，但这是从图片文件名反推的，不是文章正文文字描述，中等置信度。来源：[tsamoudakis.com](https://www.tsamoudakis.com/klack-brought-the-joy-of-mechanical-keyboard-sounds-to-my-macbook/)。是 toolbar 式标签还是 sidebar，未证实。

**每页设置组数**：没有来源给出分组结构，但各处零散提到的设置项包括：音效套装选择(不同来源列出的名单略有出入，如 Japanese Black / Oreo / Milky Yellow / Cream / Crystal Purple / Cardboard 等)、音量(可用独立于系统音量的方式调节，一条来源明确提到过"Volume Overrides & Replace With Slider"这个具体更新项)、按键按下/抬起分别配音、随机音高变化、鼠标点击音效、菜单栏图标点击行为与不透明度、全局开关热键(默认 ⌥⌘K，可改)、通知开关、使用统计展示。这些具体落在 General 还是 Sound 分区，未证实。

**窗口尺寸 / 控件样式 / inline 说明性小字 / About 位置**：均未证实。

**Launch at Login 位置**：未证实——值得一提，检索全程没有任何来源提到 Klack 有开机启动这个设置项。这类后台常驻小工具通常都会有，但没查到可引用来源，如实标注未证实，不替它猜位置。

**快捷键设置页**：只确认了一个全局开关热键(默认 ⌥⌘K)，没有证据表明存在一个包含多行快捷键的独立设置页；该热键在 Settings 里的呈现方式(是否右对齐录制控件)未证实。

---

## 6. Hand Mirror

**整体布局**：未证实是 toolbar tabs 还是 sidebar，也未证实是否分标签——所有来源都只是零散提到"Settings 里有某个具体开关"，从没描述过整体窗口结构。唯一能确认的分组名是"Notch Trigger panel"(刘海触发面板)，里面至少含一个"Hide Menu Bar Icon"开关。来源综合自搜索摘要(引用 Setapp 相关内容)。

**每页设置组数**：没有统一的分组结构来源，零散设置项包括：Popover 模式 / Smart Window 模式切换、Window Masks(窗口形状/大小自定义遮罩)、默认摄像头出现位置、Alternative Icons(菜单栏图标可选多款)、Notch Trigger(含 Hide Menu Bar Icon 子开关)、麦克风切换、"Close window when unfocused"(失焦自动关闭)、多显示器下的显示偏好、右键菜单快速访问。这些设置项具体分布在哪些标签/分区，未证实。来源综合：[Setapp 产品页](https://setapp.com/apps/hand-mirror)、[9to5Mac 评测](https://9to5mac.com/2022/12/19/hand-mirror-macos-app-camera-check/)、[App Store 页面](https://apps.apple.com/us/app/hand-mirror/id1502839586)。

**窗口尺寸**：未证实(注意 Smart Window 模式"可拖拽缩放"说的是摄像头预览窗口本身，不是 Settings 窗口)。

**控件样式 / inline 说明性小字 / About 位置**：均未证实。

**Launch at Login 位置**：未证实——和 Klack 一样，没有任何来源提到这个具体设置项存在于哪里。

**快捷键设置页**：未证实，没有发现 Hand Mirror 是一个以快捷键为核心卖点的 App 的证据，可能压根没有专门的快捷键设置页。

---

## 组合"未证实"清单(按维度汇总，六款横向对比)

- **窗口具体像素/pt 尺寸**：六款全部未证实——没有一款找到任何来源给出过具体数字，也没有来源明确说"可自由调整大小"或"固定大小"这个事实本身(唯一沾边的是 Hand Mirror 的 Smart Window 摄像头预览窗口可调整大小，但那不是 Settings 窗口)。
- **控件样式(switch vs checkbox)**：CleanShot X(证实 switch)、iStat Menus 7(至少模块启用开关证实 switch)两款有证据；Raycast 有开关类措辞但视觉样式未坐实；Bartender 5、Klack、Hand Mirror 三款完全未证实。
- **inline 说明性灰色小字**：仅 Raycast 明确证实存在；其余五款(CleanShot X、iStat Menus 7、Bartender 5、Klack、Hand Mirror)均未证实。
- **About 位置**：仅 Raycast 证实(独立 About 分区)；其余五款均未证实。
- **Launch at Login 位置**：Raycast(General 分区，高置信度)、Bartender 5(General 标签，中等置信度)两款有着落；CleanShot X、iStat Menus 7(只证实了系统层面的路径，App 内位置未证实)、Klack、Hand Mirror 四款完全未证实。
- **快捷键设置页录制控件是否逐行右对齐**：仅 Raycast 有间接证据(但那是 Action Panel 不是 Settings 页本身，不能直接当同一件事)；CleanShot X、Bartender 5 证实存在专门的 Shortcuts/Hotkeys 区域，但对齐方式未证实；iStat Menus 7、Klack 连是否存在多行快捷键设置页都未证实；Hand Mirror 大概率没有这类页面。
- **整体是 sidebar+content 还是 toolbar 图标+文字 tab pager**：Raycast(官方原文证实 sidebar)、CleanShot X(设计评论文章证实 v5 是 sidebar)两款高置信度；iStat Menus 7 是图标式侧栏，中等偏高置信度(来自搜索摘要转述)；Bartender 5 只确认"分标签"这个事实，具体视觉样式未证实；Klack、Hand Mirror 两款完全未证实，Klack 只能从截图文件名弱推断可能有 General/Sound 两块。

**方法论说明**：Klack 和 Hand Mirror 是两款体量较小的独立开发者 App，没有被设计类媒体做过深入的 Settings 界面评测，检索到的内容几乎全是功能罗列而非界面描述，所以这两款的"未证实"项明显比另外四款多——这是信息源本身稀缺导致的，不是检索不够努力。