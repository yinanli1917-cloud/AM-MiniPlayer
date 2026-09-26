# 六款 macOS 菜单栏/工具类应用 Settings 窗口调研

调研范围：Dropover、Amphetamine、Latest、Velja、Shottr、Sip。逐项列出证据来源；找不到可靠信源的问题标"未证实"，不用其他应用的模式做推广。

---

## Dropover

- **布局**：确认为**侧边栏（sidebar）**样式，不是标签页。Dropover 5.2 版本说明明确提到"Settings sidebar icons"经过重新设计，并带有随系统外观（深色/浅色）自动切换的图标。[Dropover 5.2 更新说明](https://dropoverapp.com/whats-new/5.2.0)
- **页数/分组**：Dropover 5 整体重做了 Settings，从旧的 Preferences 改名为 Settings（对齐系统命名习惯）。[Dropover 5 更新说明](https://dropoverapp.com/whats-new/5.0.0.html) 可确认的具体分区/标签至少有三个：主设置区（含 Launch at Login）、Shelf Interaction（含 Screenshot shelf 的 Setup 向导）、Advanced（含 Keyboard Shortcuts 管理和 Screenshots 的 Manage 按钮）。[Dropover Screenshots KB 页](https://dropoverapp.com/kb/screenshots) 完整分区总数未证实。
- **窗口尺寸**：未证实，没有找到任何页面给出具体像素值。
- **开关控件样式**：4.15 版本的快捷键面板里,用户"enable or disable specific shortcuts"用的控件被来源描述为 checkbox。[Dropover 4.15 更新说明](https://dropoverapp.com/whats-new/4.15.0) 其余设置项的开关样式未证实。
- **行内说明文字**：有证据支持。5.2.2 版本说明提到 Launch at Login 旁边"indicate if approval is still required in System Settings"并给出跳转链接,属于典型的行内辅助说明文字。[Dropover 5.2.2 更新说明](https://dropoverapp.com/whats-new/5.2.2)
- **About 位置**：5.0 版本说明提到 About 画面"重新设计"，但具体放在 Settings 内的哪个位置（独立标签/底部/主菜单）未证实。
- **Launch at Login 位置**：在 Settings 的主/常规设置区（5.2.2 说明称为"general settings"），旁边带跳转 System Settings 的提示链接。[Dropover 5.2.2 更新说明](https://dropoverapp.com/whats-new/5.2.2)
- **快捷键设置页**：自 4.15 起支持自定义键盘快捷键，位于 Advanced 标签内,每条快捷键有开/关 checkbox + 可点击输入新组合的控件。[Dropover 4.15 更新说明](https://dropoverapp.com/whats-new/4.15.0) 快捷键录制控件是否右对齐未证实。

---

## Amphetamine

- **布局**：未证实。多个来源提到多个具名标签（General、Triggers 等），但没有任何来源明确说明这是顶部工具栏图标式标签、还是普通 tab bar、还是侧边栏。
- **页数/分组**：确认存在的标签/区域：**General**（含 Launch at Login）[yama-mac.com 使用指南](https://yama-mac.com/en/amphetamine/)；**Triggers**（外接显示器、电池状态、Wi-Fi 网络、USB/蓝牙设备、CPU 占用、闲置时间等自动化条件）[jonbrown.org 评测](https://jonbrown.org/blog/amphetamine-review-and-walkthrough/)；Drive Alive 作为一个偏好项存在（用于选择哪些磁盘保持唤醒），[同上];App Store 描述中还列出菜单栏图标自定义、通知声音自定义、12/24 小时会话时间显示等功能，但未确认这些各自是否单独成标签。[App Store 页面](https://apps.apple.com/us/app/amphetamine/id937984704) 完整标签总数未证实。
- **命名沿革**：5.3 版本起,macOS 13 及以上系统中把"Preferences"改名为"Settings"，与系统命名对齐（与 Dropover 同一趋势）。[FileHorse Amphetamine 页面](https://mac.filehorse.com/download-amphetamine/)
- **窗口尺寸**：未证实。
- **开关控件样式**：General 标签下 Launch at Login 确认为 **checkbox**（来源原文："a checkbox for 'Launch Amphetamine at login'"）。[yama-mac.com](https://yama-mac.com/en/amphetamine/) 其余控件样式未证实，注意来源用词是否严格代表视觉控件类型本身存疑。
- **行内说明文字**：未证实。
- **About 位置**：未证实。
- **Launch at Login 位置**：General 标签，checkbox 形式。[yama-mac.com](https://yama-mac.com/en/amphetamine/)
- **快捷键设置页**：App Store 描述提到"Hot key support"，但没有来源描述具体设置页布局（是否可重新映射、是否列表形式），未证实。

---

## Latest

这是六款里资料最少的一款——开源小工具（作者 mangerlahn/Max Langer），设置体系明显比其余五款简单得多，但以下判断基于"没找到更复杂的证据"，不是直接证实"就是简单"。

- **布局**：未证实（标签/侧边栏/单页均无来源描述）。
- **页数/分组**：唯一找到的具体设置项：0.11 版本说明中"支持有限的 App"默认隐藏,"can be enabled in Settings"——说明至少存在一个 Settings 区域和至少一个开关。[GitHub Releases](https://github.com/mangerlahn/Latest/releases) 同时确认应用带有传统的顶部菜单栏（File 菜单有 Open 动作、View 菜单有 Sort By 子菜单），提示这款应用更接近"轻量应用+菜单栏图标"而非纯粹的下拉面板式菜单栏工具，但 Settings 窗口本身结构仍未证实。
- **窗口尺寸**：未证实。
- **开关控件样式**：未证实。
- **行内说明文字**：未证实。
- **About 位置**：未证实。
- **Launch at Login 位置**：未证实——没有任何来源提到这个功能是否存在。
- **快捷键设置页**：未证实，没有证据表明存在。

---

## Velja

开发者 Sindre Sorhus，官网信息相对完整。

- **布局**：确认为**多标签（tab）**结构。[sindresorhus.com/velja](https://sindresorhus.com/velja) 是否为顶部工具栏图标样式未证实。
- **页数/分组**：确认 **4 个标签**：
  - **Browsers**：Browser / Alternate Browser 两个默认浏览器选择 + Shown Browsers（哪些浏览器在选择弹窗中显示）+ 浏览器 Profile 访问授权
  - **Rules**：自定义路由规则（URL matcher + 来源 App 条件），含 Sample URL 测试输入框、底部 Export/Import
  - **Advanced**：Show menu bar icon、Transform all URLs before matching rules、Expand short URLs、Remove tracking parameters、Force show prompt when opening from browser extension、Focus Filters 支持、Debug log 访问
  - **Apps**：预置常见 Web App（如 Zoom、Google Meet）列表，每行一个下拉框选择"用本地 App 打开"还是"用浏览器打开"
  
  [sindresorhus.com/velja](https://sindresorhus.com/velja)；标签存在性与部分细节也见 [podfeet.com 评测](https://www.podfeet.com/blog/2022/11/velja/)（经搜索引擎摘要确认，原页面直接抓取被 403 拒绝）。
- **窗口尺寸**：未证实。当前版本要求 macOS 26+，旧版本支持 macOS 12–15（这是系统版本要求，非窗口尺寸）。[sindresorhus.com/velja](https://sindresorhus.com/velja)
- **开关控件样式**：未证实（来源用"enabled/disabled"描述功能，未视觉确认是 switch 还是 checkbox）。
- **行内说明文字**：有间接证据——例如"展开短链接"功能依赖某个开关先启用，文档在功能描述旁给出这类条件说明，提示存在行内辅助文字，但未见明确截图确认排版样式。
- **About 位置**：未证实。
- **Launch at Login 位置**：未证实——没找到任何来源提及这个设置。
- **快捷键设置页**：Velja 本身**没有**发现可自定义快捷键映射列表；它的交互靠固定的修饰键（Fn 长按呼出选择、Control 点击后台打开、Option 显示复制/分享按钮、Shift+Command+C 复制链接、Control+Tab 切换浏览器等），这些是写死的交互键位而非 Settings 里可改的快捷键表。[sindresorhus.com/velja](https://sindresorhus.com/velja)

---

## Shottr

- **布局**：确认为多标签结构（默认停留在 General 标签）。[How-To Geek 评测](https://www.howtogeek.com/reasons-i-use-shottr-instead-of-the-mac-screenshot-tool/) 是否为工具栏图标式样式未证实。
- **页数/分组**：确认标签：
  - **General**（默认）：Window Screenshot Background 四选一（透明底保留阴影 / 裁掉窗口阴影 / 纯色底保留阴影 / 壁纸底保留阴影）、颜色格式、保存图片自动选择格式、主窗口是否置顶、遥测（telemetry）开关
  - **Hotkeys**：配置各截图指令快捷键（含滚动截图热键），面板内有一个"Open System Settings"按钮（用于跳转系统权限设置）
  - **Advanced**：文字识别（OCR）语言选择、去除 OCR 文本换行符、"Don't show splash" checkbox（关闭启动画面）、Hide menubar icon
  - **License**：仅 Friends Club（付费支持者）可见，据称可用于隐藏 Dock 图标等实验性设置
  
  [Shottr FAQ](https://shottr.cc/kb/faq)、[Shottr Start Guide](https://shottr.cc/kb/startguide)、[How-To Geek 评测](https://www.howtogeek.com/reasons-i-use-shottr-instead-of-the-mac-screenshot-tool/)
- **窗口尺寸**：Settings 窗口本身尺寸未证实。注意：v1.5 版本说明提到"主窗口现在可调整大小并支持全屏"，但这里的"主窗口"指截图标注/编辑窗口，**不是** Settings 窗口，不能混为一谈。[Shottr 更新日志](https://shottr.cc/newversion.html)
- **开关控件样式**：Advanced 标签下"Don't show splash"确认为 **checkbox**。[Shottr FAQ](https://shottr.cc/kb/faq) 其余控件样式未证实。
- **行内说明文字**：未证实明确的行内小字说明样式。
- **About 位置**：未证实。
- **Launch at Login 位置**：**确认不在 App 自己的 Settings 内**，需要用户自行去 macOS 系统的 System Settings → General → Login Items 设置，Shottr 没有自带这一项。这是六款中唯一明确证实"开机启动"完全交给系统处理、不在自身 Settings 里做镜像开关的应用。[Shottr FAQ](https://shottr.cc/kb/faq)
- **快捷键设置页**：Hotkeys 标签，含"Open System Settings"跳转按钮；具体录制控件是否逐行右对齐未证实。

---

## Sip

- **布局**：Preferences 通过主界面底部工具条（Bottom Bar）的按钮打开，Bottom Bar 上还并列有 Color Blindness Settings、Main Window、Quit Sip 三个按钮——这意味着 Color Blindness Settings 有可能是与 Preferences **平级的独立面板**，而不一定是 Preferences 内部的一个标签，这一点未完全证实。[Sip 官方文档 - Using Sip](https://docs.sipapp.io/using-sip) Preferences 内部确认为多标签结构，是否工具栏图标样式未证实。
- **页数/分组**：确认存在的标签：
  - **General**：Recover Deleted Palettes（15 天内恢复已删除调色板）等
  - **Formats**：色彩格式显示勾选列表，含 CSS Hex、CSS3 HSL、CSS3 RGB、Calibrated/Device NSColor（HSB/RGB/CMYK）、UIColor（HSB/RGB）、CGColor（Generic RGB/CMYK）等约 12 种格式选项
  - **Shortcuts**：分 5 个命名分组——General（5 条：对比度检查器、取色器、状态菜单、Sip 菜单、色板面板访问）、Picker（8 条：上下左右 1px/10px 移动）、Zoom & Size（4 条）、Color Dock（1 条：显示/隐藏）、Extensions（2 条：主/副颜色获取），底部有 Reset Shortcuts 按钮
  - **About**：确认为 Preferences 内的一个独立区域，用途包括账号"unlink"（取消授权），官方文档路径写作"Sip › Preferences > About"
  - 另有 Menu Bar Icon 自定义（简化版图标 / 图标随取色变化填充色）相关设置，具体归属哪个标签未证实
  
  [Sip 官方文档 - Shortcuts](https://docs.sipapp.io/shortcuts)、[Sip FAQs](https://sipapp.io/faqs/)、[Sip 文档索引](https://docs.sipapp.io)
- **窗口尺寸**：未证实。
- **开关控件样式**：未证实。
- **行内说明文字**：未证实。
- **About 位置**：确认是 **Preferences 内部的一个独立分区/标签**（而非应用主菜单的"About Sip"或页脚），这点在六款中是明确证实的唯一案例。[Sip 官方文档索引](https://docs.sipapp.io)
- **Launch at Login 位置**：确认功能存在("Set Sip to launch at log-in")，但具体在哪个标签内未证实。[MacUpdate Sip 页面](https://sip.macupdate.com/)
- **快捷键设置页**：Shortcuts 标签内按 5 个功能分组排列，共约 20 条快捷键，底部统一 Reset 按钮；单条快捷键录制控件是否逐行右对齐未证实。

---

## 六款对比速览

| | 布局 | 确认标签/分区 | 窗口尺寸 | 开关样式 | About 位置 | Launch at Login 位置 |
|---|---|---|---|---|---|---|
| Dropover | 侧边栏（确认） | General、Shelf Interaction、Advanced | 未证实 | 部分 checkbox（快捷键面板） | 未证实具体位置 | 主/General 区，带系统跳转提示 |
| Amphetamine | 未证实 | General、Triggers（+Drive Alive等） | 未证实 | General 内 checkbox | 未证实 | General 标签，checkbox |
| Latest | 未证实 | 至少 1 个 Settings 开关 | 未证实 | 未证实 | 未证实 | 未证实（无证据） |
| Velja | 多标签（确认） | Browsers、Rules、Advanced、Apps | 未证实 | 未证实 | 未证实 | 未证实（无证据） |
| Shottr | 多标签（确认） | General、Hotkeys、Advanced、License | 未证实（Settings 窗口本身） | Advanced 内 checkbox | 未证实 | **不在 App 内**，走系统 Login Items |
| Sip | 多标签（确认） | General、Formats、Shortcuts、About | 未证实 | 未证实 | **Preferences 内独立分区**（确认） | 存在，具体标签未证实 |

---

## 综合"未证实"清单（六款共通缺口）

- **窗口精确像素尺寸**：六款全部未找到任何来源给出过 Settings/Preferences 窗口的具体宽高数值，也没找到"是否可调整大小"的明确说法（Shottr 唯一一处"可调整大小"指的是截图编辑窗口，不是 Settings 窗口）。
- **开关控件的视觉样式（switch vs checkbox）**：仅 Amphetamine（Launch at Login）、Shottr（Don't show splash）、Dropover（快捷键启停）三处来源用了"checkbox"这个词，但这更可能是评测作者的习惯性措辞，不代表逐一视觉核实过是方形 checkbox 还是 macOS 风格的椭圆 switch；Velja、Sip、Latest 完全没有相关描述。
- **行内说明文字（设置项下方灰色小字）是否为通用设计语言**：六款都没有找到明确截图或文字确认这个具体排版模式,只有 Dropover（Launch at Login 旁的系统授权提示）和 Velja（功能间的条件说明）有间接迹象。
- **About 的具体摆放方式**：只有 Sip 明确证实是 Preferences 内部一个独立分区；其余五款（尤其是"About 到底是独立标签、页脚，还是完全在应用主菜单里"这一问题）全部未证实。
- **Launch at Login 的具体标签归属**：Amphetamine（General）、Dropover（主/General 区）两款证实；Sip 证实功能存在但标签未知；Shottr 证实不在应用内、转交系统设置；Velja、Latest 完全没找到相关证据。
- **快捷键设置页里录制控件是否统一右对齐**：六款全部未证实——这是所有来源都没有细致到的排版级细节，包括对 Dropover、Sip、Shottr 这三款确认拥有快捷键设置页的应用也一样。
- **Latest 整体的 Settings 结构**：由于是资料最少的一款开源小工具，几乎所有问题项都未证实,只能确认"存在至少一个 Settings 区域和至少一个开关"这一最低限度的事实。
- **Velja、Latest 的 Launch at Login**：两款均完全没有相关来源提及，无法判断功能是否存在。