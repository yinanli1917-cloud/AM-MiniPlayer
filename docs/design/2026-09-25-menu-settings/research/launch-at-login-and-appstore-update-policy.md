# 调研结果:菜单栏 app 设置约定 + App Store 自更新条款

## 1. "Launch at Login" 是否惯例性放在 General 标签第一项

证据不统一,但有明显倾向。找到两个开源 app 的真实源码作为一手证据:

**Ice**(github.com/jordanbaird/Ice,专做菜单栏图标管理):
- 设置窗口标签顺序(源码 `SettingsView.swift` 里 `SettingsNavigationIdentifier` 的 switch/icon 定义):**General → Menu Bar Layout → Menu Bar Appearance → Hotkeys → Advanced → About**,General 就是第一个标签。
- General 标签内部第一个控件就是 `LaunchAtLogin.Toggle()`("Launch at Login"),其后紧跟的是它自己状态栏图标的显示/隐藏、选择图标图片、"Apply system theme to icon"等。
- 源码:https://github.com/jordanbaird/Ice/blob/main/Ice/Settings/SettingsPanes/GeneralSettingsPane.swift 、 https://github.com/jordanbaird/Ice/blob/main/Ice/Settings/SettingsView.swift

**Rectangle**(github.com/rxhanson/Rectangle,窗口管理工具):
- 设置窗口只有 4 个标签,顺序是 **Shortcuts → Snap Areas → Behavior → App Settings**——注意它根本没有一个叫"General"的标签,最接近的是排在**最后**的"App Settings"。
- 但在"App Settings"标签内部,**第一项仍然是"Launch on login"**,其后依次是 Hide menu bar icon → Check for Updates 按钮 → 版本号 → Check for updates automatically → Remove keyboard shortcut restrictions → Import/Export → Restore Defaults。
- 源码:https://github.com/rxhanson/Rectangle/blob/main/Rectangle/SettingsWindow/AppSettingsView.swift 、 https://github.com/rxhanson/Rectangle/blob/main/Rectangle/SettingsWindow/SettingsWindowController.swift

**iStat Menus** 是另一种模式:官方故障排查页只提到"打开 System Settings › General › Login Items 把 iStat Menus 关了再开",指向的是 **macOS 系统设置**而不是 app 自己的偏好设置项;无法确认它在 app 内部是否还另有一个 launch-at-login 开关。来源:https://bjango.com/help/istatmenus7/knownissues/

另外两条非任务指定 app 的补充证据(搜索结果直接摘到的原文,增强"普遍性"判断):
- 开源项目 8tp/ScreenCap:"Preferences ; General, Save location, launch at login, image format..." (github.com/8tp/ScreenCap)
- 评测文章原话:"In the General tab, enable the following options: Launch at login." (Yahoo Tech, Text Lens 应用)

**结论**:凡是 app 设置里存在一个"General"式的综合标签,Launch at Login 几乎总是该标签里排最前的一两项之一;但那个标签本身不一定是整个设置窗口排第一的标签(Rectangle 是反例,标签本身垫底,内部顺序却仍是它第一)。

## 2. "Check for Updates" 放在 General 还是 About

同样用 Ice 和 Rectangle 两份源码对比,发现和题目假设("General 放自动开关 + About 放手动按钮"拆两地)不同——**两个 app 都是自动开关和手动按钮拴在同一个标签里,只是那个标签选的不一样**:

| | 标签名 | 内容 |
|---|---|---|
| Rectangle | **App Settings**(唯一综合标签,没有单独 About) | "Check for Updates…"/"Update Available…" 按钮 + 版本号文本 + "Check for updates automatically" 开关,和 Launch on Login 挤在同一屏 |
| Ice | **About**(与 General 分开单列) | "Automatically check for updates"开关 + "Automatically download updates"开关 + "Check for Updates"按钮(仅 `canCheckForUpdates` 为真时显示)+ "Last checked: …" 时间戳,同标签还有 Acknowledgements/Contribute/Report a Bug |

源码:https://github.com/jordanbaird/Ice/blob/main/Ice/Settings/SettingsPanes/AboutSettingsPane.swift

此外,业界最常用的第三方 Sparkle 更新框架本身的约定是:标准 UI 只保证应用菜单里有一条"Check for Updates…"菜单项,是否在偏好设置界面里放、放哪个标签,Sparkle 不作规定,由各 app 自行决定。来源:https://maccurrent.com/sparkle-app-updater-mac 及相关 GitHub issue/PR 讨论(sparkle-project/Sparkle 生态)。

**结论**:题目假设的"General 放开关、About 放按钮"这种拆分,在我找到的两个真实样本里都不成立——两者总是绑在一起,只是那个共同的标签有的叫 General/App Settings、有的叫 About。

## 3. 菜单栏图标样式设置放在哪

只有 Ice 给出了清晰、分层的证据(它的核心功能就是管理菜单栏图标):

- **App 自己的状态栏图标**(显示/隐藏、选择图标图片按钮、"Apply system theme to icon")放在 **General** 标签里,紧跟在 Launch at Login 后面。
- **整条菜单栏的外观**(配色/间距等,用调色板图标)是独立的 **Menu Bar Appearance** 标签,与 General 平级、彼此分开;另外还有专门的 **Menu Bar Layout** 标签管理"哪些图标显示/隐藏/常驻"。
- 源码列表:https://github.com/jordanbaird/Ice/tree/main/Ice/Settings/SettingsPanes (`GeneralSettingsPane.swift` / `MenuBarAppearanceSettingsPane.swift` / `MenuBarLayoutSettingsPane.swift`)

Rectangle 只有一个简单的"Hide menu bar icon"开关(没有"样式"选项),同样紧跟在 Launch on login 后面,放在它唯一的综合标签里。

**结论**:简单的"显示/隐藏"这种开关,常年是跟 Launch at Login 拼在同一个 General 类标签里;但只要 app 的菜单栏外观能力足够复杂(配色/间距等),通常会被拆成独立标签,不塞进 General。样本量小(只有 1 个强证据 app),这条结论置信度中等偏低。

## 4. App Store Review Guidelines 自更新条款(重点,已三方交叉核实)

方法:先用 WebFetch 抓取 https://developer.apple.com/app-store/review/guidelines/ 两次(第二次用更严格的"逐字输出、查无必须明说 NOT FOUND"提示词防幻觉),两次结果一致;因为第一次结果内部有自相矛盾的措辞,我又追加了**真实浏览器直接渲染读取该页面正文**(非截图,纯文本提取)做第三方交叉验证。三次结果逐字一致,今天(2026-09-25)可确认如下:

**Guideline 2.4.5(vii)**(Mac App Store 专属要求组,标题是"2.4.5 Apps distributed via the Mac App Store have some additional requirements to keep in mind:",下辖 (i)–(ix) 九条,第 7 条):
> "**They must use the Mac App Store to distribute updates; other update mechanisms are not allowed.**"

**结论:CLAUDE.md 里沿用的老编号"2.4.5(vii)"今天依然是正确、现行的编号,没有被重新编号**——这是本次调研最直接回答用户问题的一条。

同一组里还有一条更早、字面上更直接命中"下载额外代码"的:

**Guideline 2.4.5(iv)**:
> "They may not download or install standalone apps, kexts, additional code, or resources to add functionality or significantly change the app from what we see during the review process."

另外,通用条款(不区分平台,Section 2.5 Software Requirements 下):

**Guideline 2.5.2**:
> "Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app, including other apps. Educational apps designed to teach, develop, or allow students to test executable code may, in limited circumstances, download code provided that such code is not used for other purposes. Such apps must make the source code provided by the app completely viewable and editable by the user."

这条是 iOS/macOS 通用规则,历史上至少从 2018 年前后就存在("自包含 app"条款),2026 年 Apple 仍在用它执法(9to5Mac 2026-03-30 报道 Apple 用 2.5.2 下架/拦截 vibe-coding 类 app 更新):https://9to5mac.com/2026/03/30/apple-steps-up-crackdown-on-vibe-coding-apps-pulls-anything-from-the-app-store/ 、 https://apple.gadgethacks.com/news/apple-app-store-takedown-lawsuit-explained-guideline-252-and-ai-dev-apps/

**Section 3(Business)检查结果**:我通读了 3.1 Payments 全部和 3.2 Other Business Model Issues 可见部分(到 3.2.1(v) 为止,受单次页面读取长度限制未看完全部 3.2),**没有发现另一条专门针对"自更新/执行下载代码"的规则**。唯一沾边的一句是 3.1.1 里的"Apps distributed via the Mac App Store may host plug-ins or extensions that are enabled with mechanisms other than the App Store"——但这说的是插件/扩展的**付费解锁机制**豁免 In-App Purchase,跟"自己下载新版本二进制替换 app bundle"是两回事,不要混为一谈。

"Sparkle"这个词在整个页面里完全没有出现——Guidelines 从不点名任何具体框架,只给一般性规则。来源(原始页面):https://developer.apple.com/app-store/review/guidelines/

**对 nanoPod 的直接含义**:`UpdateService.swift`/`UpdateApplier.swift` 这套"查 GitHub Releases → 下载 → SHA256 校验 → quit 时换 bundle"的自更新机制,一旦编进"纯净版"提交 Mac App Store 审核,会同时撞上 **2.4.5(vii)**(Mac 专属:必须用 Mac App Store 分发更新,其它更新机制不允许)和 **2.5.2**(通用:不得下载/安装/执行会改变功能的代码)。两条编号和原文均为今天现查现验。

---

## 未证实清单

- **CleanShot X** 具体设置标签结构:搜到的唯一提及"General"的间接来源(koffret.com)经核实,那个"General"实际指 **macOS 系统设置**的 Login Items 面板,不是 CleanShot X app 自己的偏好设置标签——**不能采信**,已排除。CleanShot X app 内 Launch at Login / Check for Updates 具体在哪个标签,本次未能拿到可靠一手证据。
- **Bartender**:"launch at login 在 General 标签"只有一条 WebSearch 综合摘要提及,未能定位到具体可引用的原始页面或截图描述,置信度低,未采纳为正文结论。
- **Raycast、AlDente、Klack、Hand Mirror、Dropover、Amphetamine、Latest、Velja、Shottr、Sip**:均未找到本次调研范围内足够扎实的一手证据(源码或明确的截图/文档描述),正文未给出具体结论。（Raycast 官方 manual.raycast.com/preferences 路径返回 404,未找到正确路径；AlDente 域名解析失败。）
- **App Store Review Guidelines Section 3.2 后半段(3.2.2 及以后)、Section 4 Design、Section 5 Legal**:受限于单次页面提取长度,未完整通读,不能 100% 排除后面另有相关条款,但按章节主题(4=界面设计规范,5=法律/隐私)推断,出现"自更新代码执行"规则的可能性较低。
- 本次调研中途 WebSearch 工具触发会话级配额上限("200 of 200",应为 6 条并行调研流共用同一份额度),之后全部改用真实浏览器直连页面 + WebFetch 直连 URL 取证,方法上不影响已给出结论的可靠性(尤其第 4 点做了三方交叉验证),但意味着第 1–3 点没能做更大范围的横向搜索比对,样本停留在 2 个强证据开源 app(Ice、Rectangle)+ 少量弱证据。