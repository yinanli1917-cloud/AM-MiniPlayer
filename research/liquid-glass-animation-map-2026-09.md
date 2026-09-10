# Liquid Glass 动效落地地图（2026-09-10 综合）

来源：`research/liquid-glass-animation-map-2026-09-parts/{official,opensource,current-state}.md` 三份调研 + `docs/roadmap-2026-09-10.md` WT-C（C1–C6）。本文件只做综合排布，不新增检索，不引入三份原始文件之外的 API 名或仓库。

---

## 1. 摘要

1. **自动 morph 触发机制**（官方 `applying-liquid-glass-to-custom-views` JSON 端点，已见原文）：需要同时满足三件事——(a) 各视图套 `glassEffect(_:in:)` 并同处一个 `GlassEffectContainer`；(b) 参与形变的视图打上同一 `Namespace` 下的 `glassEffectID(_:in:)`；(c) 视图的出现/消失/增删发生在 `withAnimation` 包裹内。原文：「Animating views in or out causes the shapes to morph apart or together as the space in the container changes.」`GlassEffectTransition` 的 `.matchedGeometry` 是容器内默认过渡类型，`.materialize` 用于间距超出容器 spacing 时的淡入淡出替代方案。**没有找到独立于 `withAnimation` 的 morph duration/曲线专属 API**——时长和缓动完全由外层 `withAnimation(_:_:)` 决定。
2. **AppKit vs SwiftUI 的 morph 能力缺口**：SwiftUI 有完整的 `glassEffectID`/`GlassEffectTransition`/`GlassEffectContainer` 三件套做形状级动画过渡；AppKit 的 `NSGlassEffectContainerView` 官方文档通篇只讲「合并渲染 pass 提升性能」，全文没有出现"morph"一词，也没有配套的显式过渡 API。这意味着 nanoPod（AppKit `NSPanel` 为主渲染宿主）如果要在 AppKit 层做 card↔pill 形状融合，**没有官方一手 API 可以直接调用**，只能靠 (a) 用一层 SwiftUI 内容承载真正的 morph 视觉，AppKit 只管窗口 frame；或 (b) 在 AppKit 里手写基于 `NSAnimationContext`/圆角插值的近似形变——后者没有官方文档背书。
3. **macOS 26 可用性警示**：`NSGlassEffectView.effectIsInteractive` 官方 JSON 端点明确标注 **macOS 27.0+**，不是 26.0——这是本次调研里唯一确认的"晚一代"API，若 C1/C3 设计依赖交互反馈这个属性，当前 macOS 26 时代不可用。`glassProminent` 按钮样式、`NSButton.BezelStyle.prominentGlass`、`glassEffect(_:in:isEnabled:)` 三参数重载均未见到官方一手签名，标 [未验证]。
4. **开源生态现状**：覆盖 a–g 七类动效词汇的调研中，**满足"macOS + 公开 API + 宽松许可证"三条件的仓库只有 2 个**——`altic-dev/DynamicNotchKit`（MIT，macOS 13+，兼容 notch/无 notch 降级）与 `EmergeTools/Pow`（MIT，明确 macOS 12+）。`TheBoredTeam/boring.notch` 生态最成熟但是 **GPL-3.0**（需标记，不可直接抄代码）；`DnV1eX/LiquidGlassKit` 明确使用私有 API `CABackdropLayer`（禁用）。**没有找到**任何独立成仓库、专门做 AppKit `NSGlassEffectContainerView` pill↔card morph 的第三方开源实现——这块几乎是 Apple 官方文档独占，第三方样本稀缺。"三时钟解耦"（几何/内容/材质错峰）在开源生态里**没有命中任何仓库**，判断这是项目内部（liqoria 规格）总结的调度模型，非业界通用命名，需要自己在 `Pow` 之外手写调度层。
5. **最大的现状缺口**：`current-state.md` 显示菜单栏图标点击 / 窗口出现消失是纯 `orderFront(nil)`/`orderOut(nil)` 硬切（`MusicMiniPlayerApp.swift:389-401,700,714`），**零动效**，与 `SnappablePanel` 已有的弹簧引擎完全脱节——这是清单里唯一"空白"而非"有差距"的大项。其次，`SnappablePanel.swift` 的贴边/探出/恢复三个动作**未见任何 `accessibilityReduceMotion` 读取**（AppKit 层不在 SwiftUI Environment 树内），是 Reduce Motion 覆盖面里唯一确认的缺口。

---

## 2. 总表

说明：「现状」列的文件:行均取自 `current-state.md`；「官方 API」列的 API 名均取自 `official.md` API 清单且标注「已见」，非已见的一律带 [未验证] 标签；「开源参考」列的仓库/URL/license 均取自 `opensource.md` 原文，GPL 已标注风险；「三时钟落地方式」是按 liqoria 规格（geometry 125–150ms / content 滞后 20–80ms / material 270–350ms，无独立开源支持，需自行调度）给出的应用建议，非已验证的现成实现。

| 动作 | 路线图条目 | 现状（文件:行，参数） | 官方 API 或「需手写」 | 开源参考（URL，license） | 适用性 | 三时钟落地方式 | 对照臂建议 |
|---|---|---|---|---|---|---|---|
| 贴边隐藏与探出的水吸附 morph（card↔pill） | C1 | `SnappablePanel.swift:354-375`（隐藏 `Spring(duration:0.5, bounce:0.15)`）、`:398-434`（探出 `Spring(duration:0.3, bounce:0.0)`，`peekAmount=30pt`）、`:377-396`（恢复同 0.5/0.15），纯 `NSPanel.setFrameOrigin` 几何通道，无材质通道 | `GlassEffectContainer`（已见）+ `glassEffectID(_:in:)`（已见）+ `GlassEffectTransition`（已见）用于 pill 内容层；AppKit 侧 `NSGlassEffectContainerView`（已见，仅性能合并语义）+ `NSGlassEffectView`（已见）承载材质 | `altic-dev/DynamicNotchKit`（MIT，github.com/altic-dev/DynamicNotchKit，明确支持真实 notch/无 notch floating 降级，抽象方式贴近本场景）；`TheBoredTeam/boring.notch`（**GPL-3.0**，github.com/TheBoredTeam/boring.notch，仅可读 hover 展开时序，不可抄代码） | macOS 26 可用（`NSGlassEffectView`/`GlassEffectContainer` 均已见 26.0+）；需自建 Reduce Motion 回退（现状 SnappablePanel 完全未读 `NSWorkspace.accessibilityDisplayShouldReduceMotion`）；与禁用模式冲突——玻璃只能套 pill（轻内容），card 保持不透明，否则撞 `PanelBackdrop.swift` 已有的"page overlay 用 Color.clear 避免叠材质"设计 | 见第 3 节 C1 专节详细方案 | `nanopod://debug/feel/edgeMorph/<v0|morph>`：v0 臂=现状纯几何 Spring；morph 臂=三时钟拆分版 |
| 三页切换 | C2 | `MiniPlayerView.swift:86,93,99,109`，单一 `.spring(response:0.25, dampingFraction:0.9)` 同时驱动几何+内容，`matchedGeometryEffect(id:"trackTitle"/"artistName"/"album-placeholder", in: animation)`（`:16`）；Pages 常驻挂载 | `glassEffectID(_:in:)`（已见，用于身份延续）；三时钟拆分本身无官方专属 API，靠三个独立 `withAnimation` 分别包裹几何/内容/材质变化实现 | 无直接匹配（`gahntpo/MatchedGeometryExamples`，跨平台，[未验证] 具体日期，可读 segmented-control 高亮迁移思路） | macOS 26 可用（matchedGeometryEffect 非 26 新增，通用）；现状已有 `reduceMotion ? .linear(0.1) : .spring(...)` 三元回退（`MiniPlayerView.swift` 多处）；不涉及玻璃叠玻璃 | 几何 125–150ms 驱动 matchedGeometryEffect；内容（新页面文字/占位符）滞后 20–80ms 淡入，需新增"预埋占位符"这一级（现状没有）；材质（背景 blur/透明度）270–350ms 单独跑表 | `nanopod://debug/feel/pageSwitch/<single|split>`：single=现状单弹簧；split=三时钟版 |
| 按钮 hover 胶囊 | C3 | `HoverableButtons.swift:148-153`/`:269-274`，原生 `.onHover` 驱动各自 `.animation`，无统一弹簧值，无胶囊背景高亮层 | `NSTintProminence`/`tintProminence`（AppKit，已见，控制强调程度，非胶囊高亮本身）；SwiftUI 侧无专属"hover capsule"API，需手写 | `nilcoalescing` 博客「Custom Segmented Control With MatchedGeometryEffect」（博客非仓库，代码片段完整，无许可证顾虑，D 类最直接可抄参考，改绑 `onHover`）；`gahntpo/MatchedGeometryExamples`（[未验证] 活跃度，跨平台 demo） | macOS 26 可用（matchedGeometryEffect 通用 API）；现状 `HoverableButtons.swift` 已有 reduceMotion 接入（`:136,149,230,248,270,275`），可复用退化模式；不涉及玻璃叠玻璃（胶囊背景层非额外 glass 材质，用 `.background` 色块即可） | liqoria 观察值：hover 进入 200–300ms 渐显（demo-spec.md:83-86,278）；单通道足够，不必三时钟拆分 | `nanopod://debug/feel/hoverCapsule/<off|capsule>` |
| 按压缩放 | C3 | 三处不同参数：`SharedControls.swift:902-909`（Play/Pause `interpolatingSpring(mass:0.75,stiffness:560,damping:22)` 缩至0.86）、`:1227-1235`（Skip `interpolatingSpring(mass:1.0,stiffness:400,damping:28)` 缩至0.90）、`:1580-1588`（另一按钮 `.spring(response:0.1,dampingFraction:0.7)` 缩至0.93），未统一 token 化 | 无专属；`EmergeTools/Pow` 的 Change Effect 机制可承载按下反馈这类"值变化触发一次性效果" | `EmergeTools/Pow`（**MIT**，github.com/EmergeTools/Pow，明确 macOS 12+，可直接 `import` 使用，是本次调研少数可直接依赖的库） | macOS 26 可用；现状 reduceMotion 已接（`SharedControls.swift` 大量三元式）；不涉及玻璃叠玻璃 | 纯几何通道，liqoria 强调"无回弹"（critically damped，非精确数值，需自行调参逼近）——现状三套参数需统一到临界阻尼附近 | `nanopod://debug/feel/pressScale/<legacy|unified>` |
| 进度条 hover | C3 | `SharedControls.swift:604`（`barHeight = isProgressHovering ? 12 : 7`，纯几何放大）+ `:636-712`（`updateProgressLayers`/`applyProgressFrame`：hover 引发的 track/fill/mask 帧变化各自套 `CABasicAnimation(keyPath:"bounds"/"position"/"cornerRadius")`，`hoverTransitionDuration=0.25s`，`timingFunctionName:.easeInEaseOut`）+ `:657,664`（`guard !prefersReducedMotion else { return nil }`，已有 reduceMotion 覆盖）+ `:320`（`view.prefersReducedMotion = reduceMotion` 从 SwiftUI Environment 注入 AppKit 层） | 无专属；系统 slider 无此放大反馈，是手写 CALayer 动画 | 同"按钮 hover 胶囊"一行参考 | macOS 26 可用；reduceMotion 已覆盖（非缺口） | 单通道（几何：bounds/position/cornerRadius 联动），0.25s 已接近 liqoria 200–300ms 观察值 | `nanopod://debug/feel/progressHover/<off|hover>` |
| Shuffle/Repeat | C3 | `MiniPlayerView.swift:460-462` + `Components/PlaylistControlButton.swift`，双段弹簧：触发 `.spring(response:0.12,dampingFraction:0.9)`，回落 `.spring(response:0.35,dampingFraction:0.55)` | 无专属，需手写 | `EmergeTools/Pow`（MIT）可承载触发瞬间的轻量特效层 | macOS 26 可用；对照 `current-state.md` 差距清单：回落 dampingFraction 0.55 明显欠阻尼会回弹，与 liqoria "无过冲"目标相反，**是清单里最值得先测量对齐的一项** | 纯几何通道；先把回落阻尼调到临界阻尼附近，再评估是否需要材质通道 | `nanopod://debug/feel/shuffleRepeat/<legacy055|critical>` |
| 音量 | C3 | `MusicController+Playback.swift:810-822`（`setVolume(_:)`，`app.setValue(clamped, forKey:"soundVolume")` 写 Music.app）——专项 `grep -rn -i "volume" Sources/MusicMiniPlayerCore/UI Sources/MusicMiniPlayerApp` 零命中，**UI 层不存在任何音量控件**（无滑杆、无 hover-reveal、无动效） | 无专属（没有 UI 就无动效 API 需求，需要先设计再选 API，可能不需要 API 只需手写 SwiftUI Slider） | 无（一次性效果不适用于持续拖拽的音量滑杆，不套 Pow） | macOS 26 可用；这是"空白"而非"有差距"——需先决定是否做 hover-reveal 音量控件，再谈参数 | 单通道即可（纯几何，滑杆填充比例） | `nanopod://debug/feel/volume/<legacy|refined>` |
| 收藏 | C3 | UI 层无收藏/收藏按钮视图；后端 `MusicController+Playback.swift:874-887`（`toggleStar()`，读写 Music.app `loved` 字段）**无任何调用点**（`grep -rn "toggleStar" Sources/` 只命中定义本身）。`HoverableButtons.swift:221-224` 注释「翻译按钮 - 显示/隐藏歌词翻译（直接toggle，无二级菜单）」证实 `TranslationButtonView`（`:225-277`）是翻译开关，非收藏按钮 | 无专属，需先补上缺失的收藏按钮 UI 再谈动效 API | 无（未确认落地形态前不预判） | macOS 26 可用；**收藏功能在 UI 层完全空白**，`toggleStar()` 是孤立未接线的后端方法；`TranslationButtonView` 命名疑点已解除——它服务翻译开关，备注见下 | 单通道即可（纯几何，触发反馈量级），前提是先补上按钮本身 | `nanopod://debug/feel/favorite/<legacy|refined>`（先落地 UI，再接对照臂）。备注：翻译开关另有其臂，见"三页切换"外单独讨论——`TranslationButtonView` 触发反馈用 `.spring(response:0.12,dampingFraction:0.9)` bounce + `scaleEffect(1+toggleBounce*0.15)`（`HoverableButtons.swift:248-278`），如需对照臂应挂在翻译开关自己的条目而非收藏 |
| 页签 Tab Bar | C3 | `HoverableButtons.swift:295-338`（`PlaylistTabBarIntegrated`），选中胶囊 `.animation(.bouncy(duration:0.35), value: selectedTab)`（`:307`），自定义 `RoundedCorner: Shape`（`:355-381`）做单角圆角；**结构体内 0 处 `accessibilityReduceMotion` 读取**（对比同文件 `HoverableActionButton`/`TranslationButtonView` 均在 `:136,230` 接入）；**仓库内无任何调用点**（`grep -rn "PlaylistTabBarIntegrated" Sources/ Tests/` 只命中同文件定义本身），是未接线的死代码 | `glassEffectID`（已见，若要做玻璃形态切换） | `nilcoalescing` 博客同上；`Tilak1028-st/LiquidGlassTabBar`（[未验证] macOS 支持，命名暗示 iOS 26 风格，squish-on-land 弹簧曲线思路可参考） | macOS 26 可用；**先接线到调用方再谈动效**，且必须补上缺失的 reduceMotion 回退（现状是清单里除 `SnappablePanel` 外唯一确认零 reduceMotion 覆盖的项） | 几何+内容双通道（切换胶囊位置 + 文字高亮） | `nanopod://debug/feel/tabBar/<current|split>` |
| 设置页 Tab 切换 | C4 | `SettingsView.swift:34`，原生 `TabView(selection:)`，**全文件零 `.transition(`/`.animation(`/`spring(`**，完全依赖系统默认 | 系统默认（SwiftUI `TabView` 内建过渡，未在 `official.md` 中单独列出具体 API 名） | 无匹配（C4 不在 opensource.md 七类范围内） | macOS 26 可用；现状是"未实现"而非"有差距"，从零开始设计 | 若要自定义，需三时钟全套；否则维持系统默认也是合理选项（先问创始人） | `nanopod://debug/feel/settingsTab/<system|custom>`（若决定自定义才需要） |
| 设置页开关/Picker 反馈 | C4 | `SettingsView.swift:99,120,236`（`Toggle`），原生 `Toggle` + `UserDefaultsBinding.bool`，无自定义动效 | 无专属 | 无匹配 | macOS 26 可用；同上，空白而非差距 | 单通道，触发反馈量级，不需要三时钟 | `nanopod://debug/feel/settingsToggle/<system|custom>` |
| 设置页背景情怀动画 | C4 | 不存在，需创始人提供 Pinterest「ani」参考图（roadmap 原文要求）后才能设计 | 待定 | 待定 | 待定——设计未定案前不判适用性 | 待定 | 待定 |
| 菜单栏图标点击 | C3/C4（roadmap 未单列，归入 C3 微交互清单） | `MusicMiniPlayerApp.swift:273-401`，`statusItem.button` 点击直接 `orderFront(nil)`/`orderOut(nil)`，**无 `.animator()`、无 alphaValue 淡入淡出**，硬切 | `NSWorkspace.accessibilityDisplayShouldReduceMotion`（已见，AppKit 侧读取 Reduce Motion，本项尤其需要因为这是纯 AppKit 路径不进 SwiftUI Environment） | 同"贴边隐藏"一行的 `DynamicNotchKit`/`boring.notch` 窗口显隐时序参考 | macOS 26 可用；**当前是本文档最大的单点缺口**（现状调研原话），需要新增而非调整；不涉及玻璃叠玻璃（只是窗口 alpha/位置过渡） | 材质通道（alpha fade）270–350ms 量级为主，几何通道（位置/缩放）可选 | `nanopod://debug/feel/windowPresent/<hardcut|fade>` |
| 窗口出现/消失 | C3/C4（同上，与菜单栏点击是同一段代码） | 同上 `MusicMiniPlayerApp.swift:389-401,700,714`，与 `SnappablePanel` 弹簧引擎完全不共享，体验不一致（现状调研明确指出） | 同上 | 同上 | 同上 | 同上 | 同上，与"菜单栏图标点击"共用一个 channel 更合理，避免重复对照臂 |
| 封面切歌 crossfade | 不在 roadmap C1-C6 明确条目内，属现有机制的三时钟对齐 | `MiniPlayerView.swift:78,133,142,150` + `MusicController+Artwork.swift:933,1113`，SwiftUI `.transition(.opacity)` 四处，"pointer-keyed background crossfade"驱动替换时机，叠加 `matchedGeometryEffect` 与页面切换共存 | `glassEffectID`（已见，若要与 morph 打通身份） | 无直接匹配 | macOS 26 可用；现状已是独立通道（方向对），但缺"预埋占位符→真实图"两级淡入 | 内容通道已存在但只有一级 opacity transition，liqoria 目标是占位符先淡入（20ms 级）、真实图后替换（约147ms 后）——需要新增一级 | `nanopod://debug/feel/artworkCrossfade/<single|twoStage>` |
| 浅色封面对比度 | C5 | 不在本次 current-state.md 现状清单范围内（TODOS P1，独立议题） | 无 API 关联——这是材质/调色问题非动效问题 | 无 | **说明**：C5 是 Apple Music iOS 方案（封面 blur+压暗+饱和替代系统材质）的调参问题，与本文档讨论的 morph/spring/三时钟动效体系不是同一类，不适用本表的"三时钟"列；需要创始人实时调参终验 | 不适用 | 不适用（非动效对照臂场景） |
| 引导页 Onboarding | C6 | 不存在 | 无特定关联 | 无 | 一行结论：首次启动流程设计，不涉及本文档讨论的 Liquid Glass morph/三时钟体系，可用系统标准过渡（TabView/sheet），无需专项动效调研 | 不适用 | 不适用 |

（总表行数：17）

### 2.1 总表逐行展开（同一事实，拆分成条目便于对照查阅）

以下是总表每一行的展开版，内容与第 2 节表格完全一致，不新增事实，只是把宽表格里挤在一个单元格内的长句拆成分项，方便逐条对照 roadmap C1-C6 执行。

**贴边隐藏与探出的水吸附 morph（card↔pill）— C1**
- 现状：`SnappablePanel.swift:354-375` 隐藏动作 `Spring(duration:0.5, bounce:0.15)`；`:398-434` 探出动作 `Spring(duration:0.3, bounce:0.0)`，`peekAmount=30pt`；`:377-396` 恢复动作同 0.5/0.15。
- 通道现状：纯几何（`NSPanel.setFrameOrigin`），无材质通道。
- 官方 API：`GlassEffectContainer`、`glassEffectID(_:in:)`、`GlassEffectTransition`（SwiftUI 侧，均已见）承载 pill 内容层；`NSGlassEffectContainerView`、`NSGlassEffectView`（AppKit 侧，均已见，前者仅性能合并语义）承载材质。
- 开源参考：`altic-dev/DynamicNotchKit`（MIT）真实 notch/无 notch floating 降级抽象；`TheBoredTeam/boring.notch`（GPL-3.0，仅读思路）。
- 适用性：macOS 26 可用；需要自建 Reduce Motion 回退（现状缺失）；与禁用模式的冲突点是玻璃只能套 pill 轻内容，card 保持不透明。
- 三时钟：见第 3 节 C1 专节详细方案。
- 对照臂：`nanopod://debug/feel/edgeMorph/<v0|morph>`。

**三页切换 — C2**
- 现状：`MiniPlayerView.swift:86,93,99,109` 单一 `.spring(response:0.25, dampingFraction:0.9)` 同时驱动几何+内容；`:16` `matchedGeometryEffect(id:"trackTitle"/"artistName"/"album-placeholder", in: animation)`；Pages 常驻挂载，非条件渲染。
- 官方 API：`glassEffectID(_:in:)`（已见，身份延续）；三时钟拆分无官方专属 API，靠三个独立 `withAnimation` 分别驱动。
- 开源参考：`gahntpo/MatchedGeometryExamples`（跨平台，[未验证] 具体活跃度）。
- 适用性：macOS 26 可用；现状已有 `reduceMotion ? .linear(0.1) : .spring(...)` 三元回退；不涉及玻璃叠玻璃。
- 三时钟：几何 125–150ms 驱动 matchedGeometryEffect；内容滞后 20–80ms 淡入，需新增"预埋占位符"一级（现状没有）；材质 270–350ms 单独跑表。
- 对照臂：`nanopod://debug/feel/pageSwitch/<single|split>`。

**按钮 hover 胶囊 — C3**
- 现状：`HoverableButtons.swift:148-153`/`:269-274`，原生 `.onHover` 驱动各自 `.animation`，无统一弹簧值，无胶囊背景高亮层。
- 官方 API：`NSTintProminence`/`tintProminence`（AppKit，已见，控制强调程度，非胶囊高亮本身）；SwiftUI 侧无专属 hover capsule API，需手写。
- 开源参考：`nilcoalescing` 博客「Custom Segmented Control With MatchedGeometryEffect」（代码片段完整、无许可证顾虑）；`gahntpo/MatchedGeometryExamples`（[未验证] 活跃度）。
- 适用性：macOS 26 可用；`HoverableButtons.swift` 已有 reduceMotion 接入（`:136,149,230,248,270,275`）；不涉及玻璃叠玻璃。
- 三时钟：liqoria 观察值 hover 进入 200–300ms 渐显（demo-spec.md:83-86,278），单通道足够。
- 对照臂：`nanopod://debug/feel/hoverCapsule/<off|capsule>`。

**按压缩放 — C3**
- 现状：三处不同参数——`SharedControls.swift:902-909`（Play/Pause `interpolatingSpring(mass:0.75,stiffness:560,damping:22)` 缩至 0.86）、`:1227-1235`（Skip `interpolatingSpring(mass:1.0,stiffness:400,damping:28)` 缩至 0.90）、`:1580-1588`（另一按钮 `.spring(response:0.1,dampingFraction:0.7)` 缩至 0.93），未统一 token 化。
- 官方 API：无专属。
- 开源参考：`EmergeTools/Pow`（**MIT**，macOS 12+，可直接 import，本次调研少数可直接依赖的库）承载值变化触发的一次性效果。
- 适用性：macOS 26 可用；现状 reduceMotion 已大量接入；不涉及玻璃叠玻璃。
- 三时钟：纯几何通道，liqoria 强调无回弹（临界阻尼附近，非精确数值），现状三套参数需统一。
- 对照臂：`nanopod://debug/feel/pressScale/<legacy|unified>`。

**进度条 hover — C3**
- 现状：`SharedControls.swift:604`（`barHeight = isProgressHovering ? 12 : 7`，hover 时轨道/填充条从 7pt 长到 12pt）；`:636-712`（`updateProgressLayers`/`applyProgressFrame`/`applyProgressMask`：track/fill/mask 三层各自的 bounds/position/cornerRadius 变化套 `CABasicAnimation`，`hoverTransitionDuration=0.25s`，`.easeInEaseOut`）；`:657,664`（两处 `guard !prefersReducedMotion else { return nil }`，reduceMotion 时动画时长直接置 nil，退化为瞬切）；`:320`（`view.prefersReducedMotion = reduceMotion`，把 SwiftUI Environment 的 reduceMotion 注入这个纯 AppKit `NSView`）。
- 官方 API：无专属；系统 slider 没有这种放大反馈，是手写 `CALayer` + `CABasicAnimation`。
- 开源参考：同"按钮 hover 胶囊"行。
- 适用性：macOS 26 可用；reduceMotion 已覆盖，不是缺口。
- 三时钟：单通道（几何：track/fill/mask 联动缩放），0.25s 已接近 liqoria 200–300ms 观察值。
- 对照臂：`nanopod://debug/feel/progressHover/<off|hover>`。

**Shuffle/Repeat — C3**
- 现状：`MiniPlayerView.swift:460-462` + `Components/PlaylistControlButton.swift`，双段弹簧——触发 `.spring(response:0.12,dampingFraction:0.9)`，回落 `.spring(response:0.35,dampingFraction:0.55)`。
- 官方 API：无专属，需手写。
- 开源参考：`EmergeTools/Pow`（MIT）可承载触发瞬间的轻量特效层。
- 适用性：macOS 26 可用；回落 dampingFraction 0.55 明显欠阻尼会回弹，与 liqoria"无过冲"目标相反，是差距清单里最值得先测量对齐的一项。
- 三时钟：纯几何通道，先调回落阻尼到临界阻尼附近，再评估是否需要材质通道。
- 对照臂：`nanopod://debug/feel/shuffleRepeat/<legacy055|critical>`。

**音量 — C3**
- 现状：`MusicController+Playback.swift:810-822`（`setVolume(_:)`），只写 Music.app `soundVolume`（`app.setValue(clamped, forKey:"soundVolume")`），是纯后端控制。专项 `grep -rn -i "volume" Sources/MusicMiniPlayerCore/UI Sources/MusicMiniPlayerApp` 零命中——**UI 层不存在任何音量控件**，没有滑杆、没有 hover-reveal、没有 `.animation`/`.spring`。
- 官方 API：无专属；没有 UI 就没有可评估的动效 API 需求，需要先设计控件形态。
- 开源参考：无——持续拖拽式滑杆不适合 `Pow` 这种一次性效果库，故不引用。
- 适用性：macOS 26 可用；这是"空白"而非"有差距"，需先决定要不要做 hover-reveal 音量控件。
- 三时钟：单通道即可（纯几何，滑杆填充比例）。
- 对照臂：`nanopod://debug/feel/volume/<legacy|refined>`。

**收藏 — C3**
- 现状：UI 层不存在收藏按钮视图；后端 `MusicController+Playback.swift:874-887`（`toggleStar()`，读写 Music.app `loved` 字段）**无任何调用点**——`grep -rn "toggleStar" Sources/` 只命中方法定义本身（`:874`）。`HoverableButtons.swift:221-224` 的注释「翻译按钮 - 显示/隐藏歌词翻译（直接toggle，无二级菜单）」证实 `TranslationButtonView`（`:225-277`）就是翻译开关，不是收藏按钮，命名疑点已解除。
- 官方 API：无专属；需要先补上收藏按钮本身的 UI 再谈动效 API。
- 开源参考：暂不预判——落地形态未定。
- 适用性：macOS 26 可用；收藏功能在 UI 层完全空白，`toggleStar()` 是孤立未接线的后端方法。
- 三时钟：单通道即可（纯几何，触发反馈量级），前提是先补上按钮。
- 对照臂：`nanopod://debug/feel/favorite/<legacy|refined>`（先落地 UI 再接对照臂）。
- 备注（翻译开关，与收藏无关）：`TranslationButtonView` 是真实存在且已接线的翻译开关（调用点 `LyricsView.swift:1498`），触发反馈为 `.spring(response:0.12,dampingFraction:0.9)` 触发 bounce + `scaleEffect(1+toggleBounce*0.15)`（`HoverableButtons.swift:248-278`），reduceMotion 已接入（`:230,248,270,275`）；如需为翻译开关单独定对照臂，应另开条目，不应挂在"收藏"这行下。

**页签 Tab Bar — C3**
- 现状：`HoverableButtons.swift:295-338`（`PlaylistTabBarIntegrated`），选中胶囊 `.animation(.bouncy(duration:0.35), value: selectedTab)`（`:307`），自定义 `RoundedCorner: Shape`（`:355-381`）做单角圆角。**结构体内 0 处 `@Environment(\.accessibilityReduceMotion)`**（对比同文件 `HoverableActionButton`/`TranslationButtonView` 分别在 `:136`/`:230` 接入）。**仓库内无任何调用点**——`grep -rn "PlaylistTabBarIntegrated" Sources/ Tests/` 只命中同文件内的定义（`:3,291,295`），是未接线的死代码。
- 官方 API：`glassEffectID`（已见，若要做玻璃形态切换）。
- 开源参考：`nilcoalescing` 博客同上；`Tilak1028-st/LiquidGlassTabBar`（[未验证] macOS 支持，squish-on-land 弹簧曲线思路可参考）。
- 适用性：macOS 26 可用；先接线到实际调用方，再补上缺失的 reduceMotion 回退（现状是除 `SnappablePanel` 外唯一确认零 reduceMotion 覆盖的项）。
- 三时钟：几何+内容双通道（胶囊位置切换 + 文字高亮）。
- 对照臂：`nanopod://debug/feel/tabBar/<current|split>`。

**设置页 Tab 切换 — C4**
- 现状：`SettingsView.swift:34`，原生 `TabView(selection:)`，全文件零 `.transition(`/`.animation(`/`spring(`，完全依赖系统默认。
- 官方 API：系统默认（SwiftUI `TabView` 内建过渡，`official.md` 未单独列出具体 API 名）。
- 开源参考：无匹配（C4 不在 opensource.md 七类范围内）。
- 适用性：macOS 26 可用；现状是"未实现"而非"有差距"，从零开始设计。
- 三时钟：若自定义需三时钟全套；否则维持系统默认也是合理选项，需先问创始人。
- 对照臂：`nanopod://debug/feel/settingsTab/<system|custom>`（若决定自定义才需要）。

**设置页开关/Picker 反馈 — C4**
- 现状：`SettingsView.swift:99,120,236`（`Toggle`），原生 `Toggle` + `UserDefaultsBinding.bool`，无自定义动效。
- 官方 API：无专属。
- 开源参考：无匹配。
- 适用性：macOS 26 可用；空白而非差距。
- 三时钟：单通道，触发反馈量级，不需要三时钟。
- 对照臂：`nanopod://debug/feel/settingsToggle/<system|custom>`。

**设置页背景情怀动画 — C4**
- 现状：不存在，需创始人提供 Pinterest「ani」参考图（roadmap 原文要求）后才能设计。
- 其余各列：待定，设计未定案前不判适用性。

**菜单栏图标点击 / 窗口出现消失 — C3/C4（roadmap 未单列，归入 C3 微交互清单；两者是同一段代码，合并说明）**
- 现状：`MusicMiniPlayerApp.swift:273-401,389-401,700,714`，`statusItem.button` 点击直接 `orderFront(nil)`/`orderOut(nil)`，无 `.animator()`、无 alphaValue 淡入淡出，硬切；与 `SnappablePanel` 弹簧引擎完全不共享，体验不一致（现状调研明确指出）。
- 官方 API：`NSWorkspace.accessibilityDisplayShouldReduceMotion`（已见，AppKit 侧读取 Reduce Motion，本项尤其需要因为这是纯 AppKit 路径不进 SwiftUI Environment）。
- 开源参考：同"贴边隐藏"行的 `DynamicNotchKit`/`boring.notch` 窗口显隐时序参考。
- 适用性：macOS 26 可用；**当前是本文档最大的单点缺口**（现状调研原话），需要新增而非调整；不涉及玻璃叠玻璃（只是窗口 alpha/位置过渡）。
- 三时钟：材质通道（alpha fade）270–350ms 量级为主，几何通道（位置/缩放）可选。
- 对照臂：`nanopod://debug/feel/windowPresent/<hardcut|fade>`，两个动作共用一个 channel 避免重复对照臂。

**封面切歌 crossfade — 不在 roadmap C1-C6 明确条目内，属现有机制的三时钟对齐**
- 现状：`MiniPlayerView.swift:78,133,142,150` + `MusicController+Artwork.swift:933,1113`，SwiftUI `.transition(.opacity)` 四处，"pointer-keyed background crossfade"驱动替换时机，叠加 `matchedGeometryEffect` 与页面切换共存。
- 官方 API：`glassEffectID`（已见，若要与 morph 打通身份）。
- 开源参考：无直接匹配。
- 适用性：macOS 26 可用；现状已是独立通道（方向对），但缺"预埋占位符→真实图"两级淡入。
- 三时钟：内容通道已存在但只有一级 opacity transition，liqoria 目标是占位符先淡入（20ms 级）、真实图后替换（约 147ms 后）——需要新增一级。
- 对照臂：`nanopod://debug/feel/artworkCrossfade/<single|twoStage>`。

**浅色封面对比度 — C5**
- 现状：不在本次 current-state.md 现状清单范围内（TODOS P1，独立议题）。
- 说明：这是 Apple Music iOS 方案（封面 blur+压暗+饱和替代系统材质）的调参问题，与本文档讨论的 morph/spring/三时钟动效体系不是同一类，不适用本表"三时钟"列；需要创始人实时调参终验。
- 官方 API/开源参考/三时钟/对照臂：不适用。

**引导页 Onboarding — C6**
- 现状：不存在。
- 一行结论：首次启动流程设计，不涉及本文档讨论的 Liquid Glass morph/三时钟体系，可用系统标准过渡（TabView/sheet），无需专项动效调研。
- 其余各列：不适用。

---

## 3. C1 专节：贴边隐藏 morph（card↔pill）设计选项对比

C1 是路线图里最先做、也最难的一项（roadmap 原文：「先出设计稿再写码」）。以下给三个方案，均基于 `SnappablePanel.swift` 现状（`NSPanel.setFrameOrigin` 驱动真实窗口 frame，`Spring(duration:0.5,bounce:0.15)`）和 `PanelBackdrop.swift` 现状（`role:.base`/`role:.pageOverlay` 分层，glass 臂下 pageOverlay 渲染 `Color.clear` 以避免叠材质）。

### 选项 (a)：保留 NSPanel frame 动画 + 仅 pill 内容用 SwiftUI GlassEffectContainer 做窗内形变

- **机制**：`SnappablePanel` 继续用现有 `Spring(duration:0.5,bounce:0.15)` 驱动窗口 frame 几何（贴边/探出/恢复三个动作不变）；在 pill 这个窄小的露边形态（现状 `peekAmount=30pt`）内部套一层 SwiftUI `GlassEffectContainer` + `glassEffectID(_:in:)`，用同一个 `Namespace` 把 card 内容元素（专辑名、按钮等）与 pill 内容元素（缩略图标）关联起来，让内容层在窗口 frame 动画期间跟着做玻璃形态融合，而不是整个窗口做 morph。
- **改动文件**：`SnappablePanel.swift`（三个动作的 frame 动画本身不用大改，只需在动画开始前/结束后切换内容视图的挂载状态）、新增一个承载 pill/card 内容的 SwiftUI 视图（可能挂在 `MiniPlayerView.swift` 或独立新文件）、`PanelBackdrop.swift`（需要确认 pill 形态下如何选用 glass 角色，避免与现有 `.base`/`.pageOverlay` 二分法冲突）。
- **三时钟映射**：几何通道＝现有 NSPanel frame Spring（125–150ms 量级需要重新量，现状 0.5s duration 比 liqoria 观察值慢得多，需要调参）；内容通道＝`glassEffectID` 驱动的 SwiftUI 形状融合，滞后几何 20–80ms 需要用独立 `withAnimation` 延迟触发；材质通道＝`NSGlassEffectView`/`GlassEffectContainer` 本身的透明度收敛，走 270–350ms。
- **Reduce Motion 回退**：`SnappablePanel` 侧需要新增读 `NSWorkspace.accessibilityDisplayShouldReduceMotion`（现状完全没有）直接跳过 frame Spring，改为瞬时定位；SwiftUI 内容层用现有 `@Environment(\.accessibilityReduceMotion)` 模式即可复用。
- **glass-on-glass 风险**：中等。`PanelBackdrop.swift` 现有设计（`role:.pageOverlay` 用 `Color.clear` 避免叠材质）是给"整面板"用的二分法；pill 是面板收起后的一个更小的独立形态，如果 pill 本身也走 `PanelBackdrop` 的 base glass，同时又在其上叠 `GlassEffectContainer` 做形变，就会形成两层材质——需要明确 pill 内容层**不**再单独调用 `.glassEffect()`，而是让 `NSGlassEffectView`（AppKit base 层）保持唯一材质来源，SwiftUI 内容层只做形状/位置动画不叠加材质。
- **未知项 [未验证，需 Xcode 26 实机确认]**：`official.md` 明确指出"没有找到官方文档中专门针对 NSPanel/透明背景浮动窗口 + glassEffect 组合的明确说明或禁止性描述"，这个方案依赖 NSPanel 承载的 SwiftUI 内容层是否能正常渲染 glassEffect 需要实机验证。项目证据：`PanelBackdrop.swift:106-107`（`func makeNSView(context:) -> NSGlassEffectView { let view = NSGlassEffectView() ... }`）已经在这块同一个透明 `NSPanel` 上跑通了 AppKit 侧的 `NSGlassEffectView`，且此前的成本 A/B（原生玻璃 vs 不透明 fluid）结果打平，说明 AppKit 玻璃能在这块面板上正常渲染并非未知——真正未验证的只剩 SwiftUI `glassEffect` 修饰符包在 `NSHostingView` 里、挂在这同一块面板上时的渲染表现，两者不能混为一谈。

### 选项 (b)：过大透明窗口 + 内容层单独动画（notch app 常用手法）

- **机制**：参考 `opensource.md` 里 `altic-dev/DynamicNotchKit`（MIT）"真实 notch/无 notch floating 降级"的抽象方式——始终保持一个**尺寸固定的透明大窗口**（覆盖 card 最大态到 pill 最小态的整个包络范围），贴边/展开动作不再改变 NSPanel 的实际 frame，而是只改变窗口内 SwiftUI 内容的布局/透明度/裁剪。
- **改动文件**：`SnappablePanel.swift` 改动最大——现状的核心机制（`NSPanel.setFrameOrigin` 驱动真实 frame）需要整体替换为固定大窗口 + 内容动画，这与现有三个动作（`hideToEdge`/`peek`/`restoreFromEdge`）的实现方式冲突面广；`PanelBackdrop.swift` 需要重新设计以支持"局部区域走 glass、其余透明"的裁剪逻辑。
- **三时钟映射**：三条通道都在同一个 SwiftUI 视图树内，用三个独立 `withAnimation` 分别驱动内容 frame（几何）、文字/图标替换（内容）、材质透明度（材质），落地上更"干净"，因为不需要跨 AppKit/SwiftUI 边界协调节奏。
- **Reduce Motion 回退**：单一 SwiftUI Environment 读取即可覆盖全部三通道，比选项 (a) 更简单。
- **glass-on-glass 风险**：较低，因为材质渲染集中在一层内容视图里，容易统一管理不叠加。
- **代价**：这是对 `SnappablePanel.swift` 现有贴边吸附机制（`CADisplayLink` 60-120Hz 解析解逐帧求值、释放速度清零判定等，`:458,466-469,514-535`）的一次较大重构，风险高于选项 (a)，且需要重新验证现状代码注释里提到的"动画期间 `hasShadow=false` + `disableScreenUpdatesUntilFlush()`"这类性能优化是否还适用。

### 选项 (c)：AppKit `NSGlassEffectContainerView` 实验臂

- **机制**：完全在 AppKit 层实现——`NSPanel` frame 动画不变，但 pill/card 形态切换时把内容视图包进 `NSGlassEffectContainerView`，依赖其 `spacing` 属性（已见）做"邻近合并"触发一种视觉上的融合观感。
- **改动文件**：`SnappablePanel.swift`（frame 动画不变）+ 新增 AppKit 内容视图层（可能复用或扩展 `PanelBackdrop.swift` 的 `NativeGlassSurface`）。
- **为什么不推荐**：`official.md` 第 6 节已经明确指出，`NSGlassEffectContainerView` 官方文档**只讲性能层面的渲染合并**（"reducing the number of passes required to render similar glass effect views"），全文没有出现"morph"这个词，也没有配合 `NSAnimationContext`/显式过渡 API 的动画融合机制描述——这意味着这个选项本质上是在**没有官方文档支持"形状动画过渡"这个语义**的前提下自行摸索，风险最高、最不可预测。`opensource.md` 也确认"没有找到独立成仓库、专门演示 AppKit `NSGlassEffectContainerView` pill↔card morph 的第三方开源项目"，没有任何可参考的先例。

**推荐**：选项 (a)——理由是它改动面最小（`SnappablePanel.swift` 的核心吸附物理引擎完全不动，只在露边形态上加一层 SwiftUI 内容），三时钟拆分有官方 API（`GlassEffectContainer`/`glassEffectID`/`GlassEffectTransition`）直接支撑而不需要像选项 (c) 那样在无文档背书的 AppKit morph 语义上裸奔，同时避免了选项 (b) 对现有吸附/性能优化代码的大范围重构风险；唯一要先解决的悬而未决问题是 NSPanel 透明背景宿主上 SwiftUI glassEffect 渲染表现需要 Xcode 26 实机截图验证（[未验证]项，见第 5 节）。

---

## 4. 待创始人确认的设计问题

1. **C1 采用哪个方案**：选项 (a)（保留 NSPanel frame 动画，SwiftUI GlassEffectContainer 只做 pill 内容层形变，本文档推荐）、选项 (b)（过大透明窗口 + 纯内容动画，notch app 常见手法，改动面更大但架构更干净）、还是选项 (c)（AppKit NSGlassEffectContainerView 实验臂，无官方 morph 语义支持，风险最高）？
2. **贴边隐藏的圆角回弹参数**：现状 `Spring(duration:0.5, bounce:0.15)` 带轻微回弹，liqoria 规格观察到的是"无回弹/临界阻尼"——是否要把 bounce 调到 0（如探出动作现状 `bounce:0.0` 那样），还是先做感知测试确认 0.15 是否真的可感知到过冲，再决定要不要改？
3. **Shuffle/Repeat 回落阻尼**：现状回落 `dampingFraction:0.55` 明显欠阻尼会回弹，与 liqoria 目标相反——是直接改成临界阻尼附近的数值，还是先做 A/B 对照臂让创始人肉眼判断哪个更符合直觉，再定档？
4. **三处按压缩放参数是否统一 token 化**：现状 Play/Pause、Skip、另一按钮各用一套不同的 `interpolatingSpring`/`spring` 参数——是统一成一套全局 token，还是保留差异化（比如主按钮和次按钮手感有意不同）？
5. **菜单栏图标点击 / 窗口出现消失**：这是现状里唯一"零动效"的硬切大项——是优先做（本文档认为是最大缺口），还是按 roadmap C3 微交互清单的既有顺序排在后面？
6. **设置页 Tab 切换/Toggle 反馈是否自定义**：现状完全依赖系统默认（零自定义代码）——C4 是否要求做完全自定义的三时钟动效，还是维持系统默认过渡、只在背景情怀动画和图标上做定制？

---

## 5. 未验证与风险清单

**[未验证] API/文档项（均来自 official.md 明确标注）：**
- `glassProminent`（`.buttonStyle(.glassProminent)`）：仅二手 WebSearch 摘要确认存在，未见 JSON 一手签名。
- `NSButton.BezelStyle.prominentGlass`：未找到对应文档页，未确认存在。
- `glassEffect(_:in:isEnabled:)` 三参数重载：JSON 端点只返回不带 `isEnabled` 的签名，未直接验证三参数重载是否存在。
- `NSVisualEffectView` 新规则：本次未专门抓取，暂不下结论。
- HIG Materials/Motion 页正文：均抓取失败，只有摘要或完全无结果。
- WWDC25 四场会话：全部转引自 wwdcnotes.com 二手笔记，非 Apple 一手 transcript。
- AppKit 侧是否存在独立 morph-transition API：**没有找到**，判断当前 AppKit 里没有对应能力。
- "glassEffect 是否需要窗口/面板背景有真实内容才能工作"：**没有找到**官方明确表述，不应在 nanoPod 代码里当作已验证事实使用（C1 选项 (a)/(b) 都间接依赖这一点在 NSPanel 透明背景上的实际表现，需要 Xcode 26 实机验证）。项目证据：`PanelBackdrop.swift:106-107` 已经把 AppKit `NSGlassEffectView` 挂在这块同一个透明 `NSPanel` 上（`nanopod://debug/backdrop/<style>` 可运行时切换），且早前的成本 A/B（原生玻璃 vs 不透明 fluid）成本打平，说明 AppKit 玻璃在这块透明面板上不需要"真实内容"也能正常渲染；未验证的范围收窄到 SwiftUI `glassEffect` 修饰符本身在 `NSHostingView` 内、挂在这同一块面板上时是否也一样，不能把 AppKit 已验证的结论套到 SwiftUI 路径上。
- 具体 morph/appear 动画时长数字：官方资料中未找到任何具体毫秒/秒数字，只有行为性描述。

**macOS 27+ 才可用的 API（本项目目标是 macOS 26）：**
- `NSGlassEffectView.effectIsInteractive`：JSON 端点明确 availability 是 macOS 27.0+，当前不可用于交互反馈设计。

**开源引用风险：**
- `TheBoredTeam/boring.notch`：**GPL-3.0**，直接搬运代码到 nanoPod（非 GPL 项目）违规，只能读思路不能抄代码。
- `DnV1eX/LiquidGlassKit`：明确使用私有 API `CABackdropLayer`，触犯项目"禁私有 API"铁律，**禁止引入其渲染路径**，只可读折射/色散算法思路自行用公开 `CIFilter` 重实现。
- 多个仓库许可证标注 [未验证]（`conorluddy/LiquidGlassReference`、`mertozseven/LiquidGlassSwiftUI`、`onmyway133/blog` Issue 讨论串等），使用前需二次核实许可证再决定是否参考代码。

**现状调研本身的预算限制（`current-state.md` 明确标注，非本文档新增）：**
- "音量"控件专属动效参数未逐行核实。
- "Shuffle/Repeat"按钮调用点归属（`PlaylistControlButton.swift` vs 具体图标内容传入方）未逐行核实。
- "玻璃叠玻璃"风险仅在 `PanelBackdrop.swift` 本身确认了设计意图（page overlay 用 Color.clear），但未逐一 grep `MiniPlayerView.swift`/`PlaylistView.swift` 全部子视图确认没有绕开这道防线的独立 `ultraThinMaterial`/`VisualEffectView` 用法。

---

## 6. 来源

- `research/liquid-glass-animation-map-2026-09-parts/official.md`（Apple 官方 API/WWDC 转述调研）
- `research/liquid-glass-animation-map-2026-09-parts/opensource.md`（开源实现调研）
- `research/liquid-glass-animation-map-2026-09-parts/current-state.md`（nanoPod 现状盘点）
- `docs/roadmap-2026-09-10.md` 第 46-54 行（WT-C：C1–C6）

关键 URL（均见于 official.md / opensource.md 原文，未在本文档新增任何新 URL）：
- https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview
- https://developer.apple.com/documentation/appkit/nsglasseffectview
- https://developer.apple.com/documentation/appkit/nsglasseffectview/effectisinteractive
- https://developer.apple.com/documentation/swiftui/glasseffectcontainer/
- https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)
- https://developer.apple.com/documentation/swiftui/glasseffecttransition
- github.com/altic-dev/DynamicNotchKit
- github.com/TheBoredTeam/boring.notch
- github.com/EmergeTools/Pow
- github.com/DnV1eX/LiquidGlassKit
- developer.apple.com/documentation/SwiftUI/Landmarks-Building-an-app-with-Liquid-Glass
- github.com/artemnovichkov/xcode-27-system-prompts
