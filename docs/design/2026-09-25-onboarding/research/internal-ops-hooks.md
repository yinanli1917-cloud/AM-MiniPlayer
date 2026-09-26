# 调研报告：交互式 onboarding 代码层面事实调研

仓库：`/Users/yinanli/Documents/MusicMiniPlayer`。以下按 A–I 逐项列出证据，找不到的一律写明「未找到（搜过：…）」。

---

## A. 高频操作清单

| # | 操作 | 入口文件:行 | 触发方式 | 完成后可观察的状态 | 已有可订阅信号 |
|---|------|------------|---------|-------------------|---------------|
| 1 | 播放/暂停 | `Sources/MusicMiniPlayerCore/UI/Components/SharedControls.swift:225-233`（`PlayPauseControlButton`）→ `Sources/MusicMiniPlayerCore/Services/MusicController+Playback.swift:55-98`（`togglePlayPause()`） | 点击圆形按钮 | `MusicController.isPlaying`（`@Published`，`Sources/MusicMiniPlayerCore/Services/MusicController.swift:174`） | 是 |
| 1 | 上一首/下一首 | `SharedControls.swift:215-221`/`:235-241`（`SkipControlButton`）→ `MusicController+Playback.swift:100-138`（`nextTrack()`/`previousTrack()`） | 点击箭头按钮 | `currentTrackTitle`/`currentArtist`/`currentArtwork`（`MusicController.swift:175-178`） | 是 |
| 2 | 专辑↔歌词切页 | `SharedControls.swift:190-210`（`leftNavigationButton`）；专辑页封面点击 `Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift:764-776`（`onTapGesture`） | 点击左下角歌词图标 / 点击专辑封面 | `MusicController.currentPage`（`@Published`，`MusicController.swift:205-211`，`PlayerPage` 枚举定义于 `:27-31`：`case album, lyrics, playlist`） | 是 |
| 2 | 专辑↔歌单切页 | `SharedControls.swift:255-273`（`playlistNavigationButton`） | 点击右下角歌单图标 | 同上 `currentPage` | 是 |
| 2 | 三页滑动手势/快捷键 | — | 未找到（搜过 `MiniPlayerView.swift`/`PlaylistView.swift`/`LyricsView.swift` 内 `DragGesture`/`onSwipe`/`magnificationGesture`，`GlobalShortcuts.swift` 仅 5 个 action 无切页项，未发现任何 `keyDown` 本地事件监视器） | 否 |
| — | ⚠️ 更正：Tab Bar 位置 | `Sources/MusicMiniPlayerCore/UI/HoverableButtons.swift:334-382` 的 `PlaylistTabBarIntegrated` 是歌单页内部「History / Up Next」子 tab，**不是**三页导航；三页导航按钮实际在 `SharedControls.swift` | — | — |
| 3 | 歌词翻译开关 | `HoverableButtons.swift:255-327`（`TranslationButtonView`），接入点 `Sources/MusicMiniPlayerCore/UI/LyricsView.swift:1712-1713`（仅当 `lyricsService.canTranslate` 为真才挂载） | 点击歌词页翻译图标 | `LyricsService.showTranslation`（`@Published`，`Sources/MusicMiniPlayerCore/Services/LyricsService.swift:121-130`，UserDefaults 键 `"showTranslation"` 定义于 `:250`） | 是 |
| 3 | 翻译目标语言 | `Sources/MusicMiniPlayerAppKit/SettingsView.swift:297-319`（Picker）；菜单栏子菜单 `Sources/MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift:646-656` | 设置窗口 / 菜单栏 | `LyricsService.translationLanguage`（UserDefaults 键 `"translationLanguage"`，`LyricsService.swift:132-138,251`） | 是 |
| 4 | 贴边收起 | `Sources/MusicMiniPlayerCore/UI/SnappablePanel.swift:193-219`（双指横向滑向屏幕边缘，`handleLiquidEdgeSwipe`）或 `:395-419`（拖拽松手时速度判定，`checkAndHideToEdgeWithVelocity`）→ `Sources/MusicMiniPlayerCore/UI/LiquidEdge/LiquidEdgeController.swift:96-106`（`collapse(to:)`） | 双指横向滑动 / 拖拽甩向屏幕边缘 / 全局快捷键 `hideToEdge` | `LiquidEdgeController.state`（`LiquidEdgeState`，见下） | **否**（见下方说明） |
| 4 | 贴边展开 | `Sources/MusicMiniPlayerCore/UI/LiquidEdge/LiquidEdgeStageView.swift:423-426`（点击小条/胶囊，`mouseDown`→`onTap`→`expand()`）；`LiquidEdgeController.swift:240-253`（hover 停留 0.08s 自动展开为 floating）；`LiquidEdgeGestures.swift:31-41`（双指反向滑动展开） | 点击 / hover 停留 0.08s / 双指反向滑动 | 同上 `state` | 否 |
| 5 | 面板拖动/吸附四角/缩放 | 拖动+吸角：`SnappablePanel.swift:223-293`（鼠标拖动）、`:719-745`（`calculateTargetCorner`，甩向最近角）；缩放：**原生** `.resizable` styleMask（`MusicMiniPlayerApp.swift:374`）+ `aspectRatio`/`minSize`/`maxSize`（`:394-396`），锁定比例 = `PanelWindowMetrics.defaultSize`（250×284） | 拖动面板背景 / 拖动窗口边缘（系统级，无自定义视觉把手） | 面板 `frame.origin`（无 `@Published`，纯 AppKit 属性） | 否 |
| 6 | 歌词行点击 seek | 旧渲染路径：`Sources/MusicMiniPlayerCore/UI/LyricsView.swift:1825-1859`（`handleLineTap`，挂载于 `:1188`）；原生渲染路径：`Sources/MusicMiniPlayerCore/UI/NativeLyricsRowView.swift:1473-1479`（`mouseDown`→`onTap`），挂载于 `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:1340` | 点击某行歌词 | `MusicController.currentTime` / `LyricsService.currentLineIndex` | 是 |
| 6 | 手动滚动 | `LyricsView.swift:1296-1298`（`onScrollStarted`/`onScrollEnded`/`onScrollWithVelocity`，来自 `Sources/MusicMiniPlayerCore/UI/Components/ScrollDetector.swift`） | 在歌词页滚轮/触控板滚动 | `LyricsService.isManualScrolling`（`@Published`，`LyricsService.swift:174`） | 是 |
| 6 | 逐字/行级切换 | — | **无用户可操作的手动开关**——由 `LyricsWordLevelPriority` 系统按数据源自动决定（行级/逐字热切换只允许升级不允许降级，见 CLAUDE.md 已知规则），未找到面向用户的 UI 入口 | 否 |
| 6 | 喜欢/收藏（favorite） | `MusicController+Playback.swift:1083-1096`（`toggleStar()`存在）；仅经 `Sources/MusicMiniPlayerCore/Services/PlaybackSource/AppleMusicControlSink.swift:20` 协议 + `Sources/MusicMiniPlayerCore/Services/PlaybackSource/AppleMusicPlaybackSource.swift:227-229`（`toggleFavorite() { sink.toggleStar() }`）可达 | **未找到任何 SwiftUI 按钮调用点**；也未找到 heart/爱心 SF Symbol 在 UI 代码中出现（搜过 `"heart`/`suit.heart`/`systemName:.*heart`） | 无对外 `@Published` 回读「是否已收藏」 | 否，UI 层完全空缺 |
| 6 | 音量 | `MusicController+Playback.swift:1022-1044`（`setVolume()`/`toggleMute()`存在） | **未找到任何 UI 滑杆**（搜过 `NSSlider`/`Slider(`/`setVolume(`/`soundVolume`/`VolumeSlider`/`volumeControl`，命中的唯一一处是 `SnappablePanel.swift:753` 的 `is NSSlider` 类型判断，与音量无关） | — | 否，UI 层完全空缺 |
| 6 | Shuffle/Repeat | 专辑页：`Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift:522-567`（`shuffleRepeatCluster`）；歌单页：`Sources/MusicMiniPlayerCore/UI/PlaylistView.swift:491,505`（`PlaylistControlButton`，组件定义于 `Sources/MusicMiniPlayerCore/UI/Components/PlaylistControlButton.swift:50-76`） | 点击胶囊按钮（两个页面各有一份） | `musicController.shuffleEnabled`(`MusicController.swift:192`)/`repeatMode`(`:193`) | 是 |
| 7 | 菜单栏图标点击 | `Sources/MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift:311-326`（`setupStatusItem()`，`statusItem.menu = menu`） | 点击（任意键）弹出下拉菜单 | — | — |
| 7 | 左键/右键/option 区分 | — | 未找到（`statusItem.menu` 直接赋值是 AppKit 标准行为：任意鼠标键点击都弹同一菜单，代码里没有任何区分点击类型的逻辑，搜过 `button.action`/`rightMouseDown`/`modifierFlags`） | — | — |
| 7 | 设置窗口打开 | `MusicMiniPlayerApp.swift:751`（`createSettingsWindow()`）、`:794`（`showSettingsWindow(selectedTab:)`），菜单项在 `:662` 附近 | 菜单栏「设置…」 | — | — |
| 7 | 全局快捷键 | `Sources/MusicMiniPlayerCore/Services/GlobalShortcuts.swift:15-21` 定义 5 个 `KeyboardShortcuts.Name`：`togglePlayPause`/`nextTrack`/`previousTrack`/`togglePanel`/`hideToEdge` | 系统级热键 | — | — |
| 7 | 默认键位 | — | **无默认键位**——文件头注释明确：`"No default key combos — users record their own."`（`GlobalShortcuts.swift:8`），录制 UI 在 `SettingsView.swift:232-233`（`KeyboardShortcuts.Recorder`） | — |
| 8 | 歌单页点歌播放 | `Sources/MusicMiniPlayerCore/UI/PlaylistView.swift:756`（`struct PlaylistItemRowCompact`），`:813-834`（`Button(action:)` → `musicController.playTrack(...)`） | 点击某行 | `MusicController.currentTrackTitle` 等 | 是 |
| 8 | 拖动排序 | — | 未找到（搜过 `onDrag`/`onDrop`/`onMove`/`draggable(` 均落空——Up Next/History 本身是 Music.app 队列的只读镜像，非本地可排序数据） | — |

---

## B. 现有 onboarding（`OnboardingView.swift` + `OnboardingState.swift`）

文件：`Sources/MusicMiniPlayerCore/Services/OnboardingState.swift`（172 行）、`Sources/MusicMiniPlayerAppKit/OnboardingView.swift`（273 行）。

- **完成键**：`OnboardingState.completedKey = "nanoPodOnboardingCompleted"`（`OnboardingState.swift:29`）
- **schema 版本**：`schemaKey = "nanoPodOnboardingSchema"`，`currentSchema = 1`（`:31-32`）；`hasCompletedOnboarding` 同时校验两个键（`:46-49`）
- **展示逻辑**：`shouldPresent(hasCompleted:launchCount:forced:)`（纯函数，`:68-72`）——只在**首次启动**（`launchCount <= 1`）且未完成时展示，或调试强制
- **权限检测**：
  - MusicKit：`musicKitStatus`（`:118-125`）直接读 `MusicAuthorization.currentStatus`，与 `MusicController.musicKitAuthorized`（`MusicController.swift:221`）同一数据源，只读不弹窗
  - Automation（Music.app 自动化）：`automationStatus`（`:130-132`）→ `queryAutomationStatus(askUserIfNeeded: false)`（`:134-165`），用 `AEDeterminePermissionToAutomateTarget` **只读查询、不弹系统对话框**；真正触发系统弹窗的是按钮点击后调 `requestAutomationAccess()`（`:169-171`，内部调用既有的 `AppleScriptRunner.fetchPlayerState`）
- **展示方式**：`OnboardingWindowView`（`OnboardingView.swift:47-273`）是**独立三页向导窗口**（welcome/authorization/done，`OnboardingPage` 枚举 `:16-20`），固定 460×380，非锚定控件、非卡片弹出。创建于 `MusicMiniPlayerApp.swift:825-854`（`createOnboardingWindow()`）：`NSWindow`（非 `NSPanel`），`styleMask = [.titled, .closable, .fullSizeContentView]`，`level = .normal`，非模态但**会激活 app**（`showOnboardingWindow()` 内 `:866` 调 `NSApp.activate(ignoringOtherApps: true)`）
- **触发点**：`MusicMiniPlayerApp.swift:124-127`（`applicationDidFinishLaunching` 路径：`OnboardingState.shared.incrementLaunchCount()` → `presentIfNeeded(launchCount:)` → `showOnboardingWindow()`）
- **调试入口**：`nanopod://debug/onboarding/<show|reset>` 处理于 `MusicMiniPlayerApp.swift:224-230`，转发给 `OnboardingState.handleDebugAction(_:)`（`OnboardingState.swift:97-111`），仅 `DEBUG || LOCAL_DEVELOPER_BUILD` 生效
- **Settings 里的「重新显示引导」入口**：**未找到**（搜过 `SettingsView.swift` 全文的 `onboarding`/`Onboarding`/`Tutorial`/`重新`/`再次`/`Reset`，`SettingsTab` 只有 `general`/`appearance`/`about` 三个 tab，均无引导相关内容）
- **grep 全部 `OnboardingState` 引用**（除自身定义文件外）：仅 `MusicMiniPlayerApp.swift:124,125,126,227,827,871` 六处，无其他文件引用

---

## C. 面板窗口类型与层级

`SnappablePanel`（`Sources/MusicMiniPlayerCore/UI/SnappablePanel.swift:6`）：`public class SnappablePanel: NSPanel`。创建配置见 `Sources/MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift:372-396`：

```
styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]
isFloatingPanel = true
level = .floating
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
hidesOnDeactivate = false
becomesKeyOnlyIfNeeded = false
```

`canBecomeKey`/`canBecomeMain` 覆盖在 `SnappablePanel.swift:796-797`：**`canBecomeKey: Bool { true }`，`canBecomeMain: Bool { false }`**——面板本身能拿到 key window，这与典型「辅助面板不抢焦点」不同，新卡片窗口若不想抢面板焦点，不能简单复制这份配置。

LSUIElement：`Sources/MusicMiniPlayerApp/Info.plist` 确认 `<key>LSUIElement</key><true/>`。

**`addChildWindow` 全项目未使用**（grep 全仓库落空）。

**现成的「面板旁再弹窗口且不抢焦点」范式**就是 `LiquidEdgeStageWindow`（`Sources/MusicMiniPlayerCore/UI/LiquidEdge/LiquidEdgeStageView.swift:108-130`）：

```swift
final class LiquidEdgeStageWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hasShadow = false
    }
}
```

它**不是**用 `addChildWindow` 挂靠，而是手动同步：`LiquidEdgeController.swift:135-182`（`prepareStage`）每次都用 `Self.drawnPanelFrame(card)`（`card.frame`）重新计算舞台窗口的 frame，并 `window.level = card.level` + `window.order(.below, relativeTo: card.windowNumber)`（`:163-165`）把自己叠在面板正下方——即「跟随」是每次交互开始时重新定位，不是持续绑定。这是本项目里**唯一**的「伴随面板但不抢焦点」的窗口先例，交互式 onboarding 的卡片窗口应参照这份配置（`borderless + nonactivatingPanel`、`canBecomeKey=false`、`level` 跟随面板、按需重新计算 frame），而不是参照 `OnboardingWindowView` 用的普通 `NSWindow`（那个会激活 app、抢焦点）。

---

## D. 屏幕坐标锚定

- `anchorPreference`：**未找到**（全仓库 grep 落空）
- `GeometryReader`：广泛用于内部布局（`MiniPlayerView.swift`、`LyricsView.swift`、`PlaylistView.swift` 等），但**没有**用于把某个控件坐标导出为屏幕坐标的模式
- `PreferenceKey`：仅两处，且都不是坐标锚定用途——`SectionOffsetKey`（`PlaylistView.swift:23`，粘性 header 滚动追踪）、`LyricLineMotionFramePreferenceKey`（`LyricsView.swift:403`，歌词行运动动画）
- `coordinateSpace(name:)`：`PlaylistView.swift:258`（`"playlistScroll"`）、`LyricsView.swift:1258`（`lyricLineMotionCoordinateSpace`），都用于内部滚动/动画计算，非屏幕锚定
- `NSWindow.convertToScreen`/`convertPoint(toScreen:)`：**未找到**任何调用
- `NSStatusItem`：变量名 `statusItem`（`MusicMiniPlayerApp.swift:25`，`var statusItem: NSStatusItem!`），其 `.button` 仅在 `setupStatusItem()`（`:311-329`）和 `updateStatusItemIcon()`（`:331-341`）、`showMenuBarMenu()`（`:617-620`，`button.performClick(nil)`）里被引用，**没有**任何代码读取 `statusItem.button?.window` 或 `.frame` 做屏幕坐标计算

**结论：项目里没有现成的「拿到 SwiftUI 控件屏幕坐标」代码，交互式 onboarding 需要从零实现这套机制**（常见做法是自定义 `PreferenceKey` 收集 `.background(GeometryReader{...}.frame(in:.global))`，但项目里没有先例可抄）。

**32pt 偏移**（`Sources/MusicMiniPlayerCore/UI/PanelWindowMetrics.swift:44-60`，`makeContentView`）：

```swift
let container = NSView(frame: NSRect(origin: .zero, size: defaultSize))       // 窗口大小 250×284
let host = NSHostingView(rootView: root.safeAreaPadding(.top, tunedTopSafeArea))  // tunedTopSafeArea = 32
host.frame = NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height + tunedTopSafeArea)  // 316 高
```

`host`（承载 SwiftUI 内容的 `NSHostingView`）与 `container`（= 窗口内容视图，也是窗口本身，founder 2026-09-23 后窗口不再比面板高 32pt）**共享同一个原点 (0,0)**，`host` 只是比窗口高出 32pt 向上多伸出，超出窗口 frame 的部分不会显示在屏幕上。这意味着：**在 SwiftUI 内部用 `.global` coordinateSpace 测得的坐标，其原点已经和窗口一致（不需要手动再减 32pt）**；32pt 只在直接操作 AppKit 层几何（例如假设旧 316pt 窗口高度写死 Y 偏移）时才会踩坑。这一推论基于代码结构，项目里没有对这个具体换算写过测试或注释验证，交互式 onboarding 实现时应该用真实控件做一次实测校验。

---

## E. 多显示器 / 位置记忆

- **面板位置持久化**：**未找到**（搜过 `setFrameAutosaveName`/`frameAutosaveName`/`windowFrame`/`panelPosition`/`savedFrame`/`restoreFrame`/`UserDefaults.*[Ff]rame`/`UserDefaults.*[Oo]rigin` 全部落空）。每次启动位置都是重新计算，写死在 `createFloatingWindow()`（`MusicMiniPlayerApp.swift:360-370`）：

```swift
let screenFrame = NSScreen.main?.visibleFrame ?? .zero
let windowRect = NSRect(x: screenFrame.maxX - windowSize.width - 20, y: screenFrame.maxY - windowSize.height - 20, ...)
```

固定用 `NSScreen.main`，锚在其可视区域右上角，偏移 20pt。**尺寸也不持久化**——每次都用 `PanelWindowMetrics.defaultSize`（250×284），用户手动拖边缘缩放后关闭重开会丢失。

- **贴边吸附用哪个 NSScreen**：**窗口自己当前所在的 `.screen`**，非鼠标所在屏、非 `NSScreen.main` 优先——`SnappablePanel.swift` 里所有吸附/贴边函数（`nearEdge`、`checkAndHideToEdgeWithVelocity`、`hideToEdge`、`moveToEdgeCorner`、`calculateTargetCorner` 等）统一写法是 `guard let screen = screen ?? NSScreen.main else { return }`（例如 `:184-191`、`:395-397`），即"窗口当前的 `.screen`，取不到才退到 `NSScreen.main`"。

---

## F. 微交互 token（`MicroInteractionFeel.swift`）

文件：`Sources/MusicMiniPlayerCore/UI/MicroInteractionFeel.swift`（668 行），是一套运行时 A/B 切换注册表（`nanopod://debug/feel/<channel>/<arm>`）。

**Arm 枚举**（每个都有默认值 + 对照值）：`HoverCapsuleMode`(`.capsule`/`.off`)、`PressScaleMode`(`.unified`/`.legacy`)、`ProgressHoverMode`(`.tuned`/`.legacy`)、`ShuffleRepeatMode`(`.critical`/`.legacy055`)、`WindowPresentMode`(`.fade`/`.hardcut`)、`EdgeMorphMode`(`.morph`/`.v0`，默认 `.v0`)、`SettingsTabMode`(`.custom`/`.system`，默认 `.system`)（`:24-127`）。

**`Tokens` 枚举**（数值，`:438-509`）关键项：
```
pressScaleFactor = 0.92, pressSpringResponse = 0.18, pressSpringDamping = 1.0
hoverCapsuleDuration = 0.22, hoverCapsuleOpacity = 0.12
progressHoverDuration = 0.16
shuffleReboundResponse = 0.30, shuffleReboundDamping = 1.0
windowFadeInDuration = 0.18, windowFadeOutDuration = 0.14
pageGeometryDuration = 0.14, pageContentLag = 0.04, pageContentDuration = 0.16, pageMaterialDuration = 0.31
```

用法示例：`PressScaleStyle.resolve(...)` 在 `SharedControls.swift:11-37` 被 `PlayPausePressStyle`/`SkipPressStyle` 调用；`HoverCapsuleStyle.resolve(...)` 在 `HoverableButtons.swift:131-144` 被 `HoverableActionButton`/`TranslationButtonView` 调用；`ShuffleRepeatStyle.resolve(...)`（`PlaylistControlButton.swift:11-43`）被 `MiniPlayerView.swift:558-564` 调用。

**Reduce Motion 读取**：
- SwiftUI 侧：`@Environment(\.accessibilityReduceMotion)`，几乎每个动效 View 都注入（`SharedControls.swift`/`HoverableButtons.swift`/`MiniPlayerView.swift`/`LyricsView.swift` 等）
- AppKit 侧：`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` 只有 4 处：`SnappablePanel.swift:30`（`reduceMotionProvider` 默认实现）、`LiquidEdge/LiquidEdgeController.swift:88`、`MusicMiniPlayerApp.swift:558,590`

**Haptic**：`NSHapticFeedbackManager` **未找到任何使用**（grep 全仓库落空）。

---

## G. 一次性动画 / 粒子

- `CAEmitterLayer`/`confetti`/`particle`：grep 命中的 5 个文件（`LyricPieceTranslation.swift`、`ScriptRunSegmenter.swift`、`LanguageUtils.swift`、`MetadataResolver.swift`、`LyricsCandidateSelection.swift`）**全部是误报**——命中的是 NLP 里「虚词/助词」（Chinese `.particle` `NLTag`，如"的/了/着"），不是图形粒子系统。**项目里没有任何粒子/礼花实现**，交互式 onboarding 如果要做「完成时的庆祝动效」需要从零写。
- `TimelineView`：仅两处——`SharedControls.swift:1044`（`SkipControlButton` 用它驱动逐帧回放式的换歌动效）、`NativeLyricsFeelParity.swift`（对照臂参数展示）
- `Canvas`：未在正文中直接以 `Canvas {`/`: Canvas` 形式使用（CLAUDE.md 提到的"v2.8 Canvas 模型"是歌词渲染架构的比喻名，不是 SwiftUI `Canvas` API）

**零常驻开销检测机制**（G 问的"教训"和"已有检测方法"）：
1. `NativeLyricsLoopIdleDecision`（`Sources/MusicMiniPlayerCore/UI/LyricsPresentationModels.swift:169-247`）——纯函数判定 display link 是否该停：`vetoes(...)` 返回否决停摆的原因名列表（`appearWindow`/`tapSettle`/`engineMotion`/`visualMotion`/`textAnim`/`interlude`/`deferredDeactivation`），`shouldKeepPresentationLoopRunning(isWindowOccluded:vetoes:)`（`:204-210`）在窗口被遮挡时无条件停。这是本项目「新增动效必须能自证零常驻开销」的标准范式，新 onboarding 卡片动效如果要常驻判断也应该抄这套「否决原因命名列表」写法。
2. `WindowAnimationCensus`（`Sources/MusicMiniPlayerCore/Utils/WindowAnimationCensus.swift`，192 行）——一次性全窗口 CAAnimation 普查工具，API：`sweepAllWindows() -> [Report]`（`:101-104`）、`format(_:) -> String`（`:158-176`）、`dump(to:)`（`:180-191`，默认写到 `/tmp/nanopod_anim_census.log`），通过 `nanopod://debug/animsweep` 触发（`MusicMiniPlayerApp.swift:222-223`）。`Report` 含 `animations`（每个动画的 `isInfinite`/`isRemovedOnCompletion` 等）+ `effectViews`（`NSVisualEffectView` 清单）+ `stats`（layer/filter/光栅化层数）。这是排查"新加的动效是不是不小心常驻了"的标准工具。

---

## H. 翻译失败静默 / 状态枚举

**`LyricsDisplayState`**（`Sources/MusicMiniPlayerCore/Services/LyricsService.swift:28-87`，唯一权威渲染状态）：
```
case searching       // 快速前台检索中，还没内容
case deepSearching   // 前台结束，长回填在跑（"Searching more sources"）
case content         // lyrics 数组就是要画的内容
case noLyrics        // 终态：所有源都搜过，没有（含"纯伴奏"判定）
case networkUnreachable  // 终态：网络问题，非"这首歌没词"
```
`isSearchPhase`（`:55-57`）= `searching || deepSearching`；`isLoading` 兼容属性（`:118`）由它派生。

**翻译可用/失败状态**：
- `canTranslate`（`@Published private(set)`，`:173`）——由 `translationAvailability(lyrics:translationLanguage:translationsAreFromLyricsSource:)`（纯函数，`:2891-2901`）算出：无歌词→false；源自带译文→true；目标是中文且歌词本身已是中文为主→false；否则看歌词是否已经就是目标语言
- `isTranslating`（`:171`）/`translationFailed`（`:172`）——都是 `@Published`
- `hasTranslation`（计算属性，`:187-189`）= `lyrics.contains { $0.hasTranslation }`
- **没有单独一个叫 `translationAvailable` 的属性**——`canTranslate` 就是这个语义的对外名字

**MusicController 侧状态读取**：
- 是否在播放：`musicController.isPlaying`（`@Published`，`MusicController.swift:174`）
- 当前歌是否有歌词：`LyricsService.shared.displayState == .content`（或 `!lyrics.isEmpty`）
- Music.app 是否运行：**没有直接的 `@Published` 布尔值**。唯一的对外代理是 `currentTrackTitle == kNotPlayingSentinel`（`kNotPlayingSentinel = "Not Playing"`，定义于 `MusicController.swift:24`，赋值见 `:2589-2592`）——这个代理**混淆了"app 没开"和"app 开着但没在播"两种情况**，内部真正的 `app.isRunning` 判断散落在各个 `controlApp`/`stateApp`/`queueApp` 等多个 `SBApplication` 实例的调用点（如 `MusicController+Playback.swift` 多处 `guard let app = ..., app.isRunning else`），没有汇总成一个可订阅信号

---

## I. 本地化（`LocalizedStrings.swift`）

文件：`Sources/MusicMiniPlayerAppKit/LocalizedStrings.swift`（118 行）。

- **机制**：手写 Swift 字典 `L10n.allStrings: [String: (en: String, zh: String)]`（`:44-103`），`L10n.localized(_ key:)`（`:25-27`）按 `isSystemChinese` 二选一，找不到 key 就原样返回 key
- **中英切换依据**：`isSystemChinese`（`:15-17`）→ `systemLanguageCode.hasPrefix("zh")`，`systemLanguageCode`（`:20-22`）读 `Locale.current.language.languageCode?.identifier ?? "en"`——**跟随系统语言，不是 UserDefaults 键**，代码里没有让用户手动切换 app 显示语言的开关
- **String Catalog（`.xcstrings`）**：未找到（项目没有用 Xcode 的 String Catalog 机制，纯手写字典）
- `onboarding.*` 系列 key 已经存在（`:83-102`，welcome/feature/auth/done 各页文案），新交互式 onboarding 如果复用文案风格可以参照这批 key 的命名（`onboarding.<page>.<field>`）

---

### 几个对交互式 onboarding 设计直接相关的缺口（非推测，均为上面证据的直接推论）

1. **LiquidEdge 无可订阅信号**：`LiquidEdgeController.state` 是 `public private(set) var`（非 `@Published`，类本身不是 `ObservableObject`），也没有 `NotificationCenter` 广播状态变化——只有 `onPanelOccluded: ((Bool) -> Void)?` 一个闭包。要让 onboarding 自动检测"用户把面板贴边了"，需要给 `LiquidEdgeController` 新增一个钩子（比如把 `state` 改 `@Published`，或者在 `transition(_:settle:kind:)` 里加一个回调）。
2. **favorite / 音量在 UI 层完全空缺**：底层方法都在，但没有任何按钮/滑杆——这两项如果要作为 onboarding 高频操作教学，得先补 UI 才有"要点击的控件"可以指。
3. **面板位置/尺寸不持久化**：每次启动都回到固定的右上角位置和默认尺寸，onboarding 卡片如果要"记住用户已经学过哪一步"，不能依赖窗口位置做状态判断。
4. **坐标锚定要从零搭**：没有 `anchorPreference`/坐标导出先例，需要新写一套 PreferenceKey 机制才能把"播放按钮在屏幕上的位置"传给 onboarding 卡片窗口。
5. **`LiquidEdgeStageWindow` 是唯一现成的"伴随面板、不抢焦点"窗口范式**，新卡片窗口的 `styleMask`/`canBecomeKey`/`level`/跟随逻辑应该抄它，而不是抄会抢焦点的 `OnboardingWindowView`。