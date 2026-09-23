# nanoPod 浮窗状态空间清单 (2026-09-19)

供「贴边收起动效」全面重做用的前置调研。纯代码读取 + grep，全部标注 file:line。推测项显式标注「推测」并说明依据。

---

## 1. Pages（页面）

### 1.1 枚举与持有者
`PlayerPage` 定义于 `Sources/MusicMiniPlayerCore/Services/MusicController.swift:27-31`：
```swift
public enum PlayerPage {
    case album
    case lyrics
    case playlist
}
```
只有 3 页：专辑封面页 (`.album`)、歌词页 (`.lyrics`)、播放列表/队列页 (`.playlist`)。没有第 4 种页（搜索、设置等均是独立 NSWindow，见第 2 节）。

状态持有：`@Published public var currentPage: PlayerPage = .album` — `Sources/MusicMiniPlayerCore/Services/MusicController.swift:176`（单例 `MusicController`，非某个 View 的本地 `@State`）。`MiniPlayerView.swift:11` 注释明确写着「Use `musicController.currentPage` instead of local page state so every surface stays synchronized」——菜单栏与浮窗共用同一状态源。

### 1.2 页面挂载策略（哪些页常驻/懒加载）
`Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift:80-104`：
- `.lyrics`：**条件挂载**——只有 `currentPage == .lyrics` 时才 `if` 出 `LyricsView`（行 83-86），配 `.transition(.opacity)`；注释「Keep it unmounted while hidden so album/playlist pages do not pay that CPU cost」（行 79-81）。切走时整个视图树连同其内部计时器/native renderer 一起销毁重建。
- `.playlist`：**常驻挂载**，用 `.opacity`/`.zIndex`/`.allowsHitTesting` 三件套做可见性切换（行 92-95），不卸载——注释「Playlist stays mounted to support matchedGeometryEffect」（行 91）。
- `.album`：**常驻挂载**，同样走 opacity/zIndex（行 100-103），承载 `matchedGeometryEffect` 的 hero 移动源（"only hosts the hero placeholder, so it rides the geometry clock" 行 99）。

### 1.3 切页触发方式
- **点击封面**（album ↔ lyrics 互切）：`MiniPlayerView.swift:693-704`，`onTapGesture` 包一层 `withAnimation(.spring(response: 0.2, dampingFraction: 1.0))`：
  ```swift
  if musicController.currentPage == .album {
      musicController.userManuallyOpenedLyrics = true
      musicController.currentPage = .lyrics
  } else {
      musicController.currentPage = .album
  }
  ```
- **播放列表 Tab Bar**：`PlaylistTabBarIntegrated`（`Sources/MusicMiniPlayerCore/UI/HoverableButtons.swift:334`起）——集成版 Tab Bar，带透明背景（注释见 330-332 行），具体切页动作在 `PlaylistView.swift` 内经 `currentPage: $currentPage` 绑定传入。
- **点击「Now Playing」卡片返回专辑页**（从 playlist 页）：`PlaylistView.swift:369-378`，`Button` action 内 `withAnimation(.spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85))` 设 `currentPage = .album`，同时联动 `isHovering/showControls/showOverlayContent = true`。
- **点击播放列表行（当前播放曲目）返回专辑页**：`PlaylistView.swift:715-721`，`Button` action 内 `withAnimation(.spring(response: 0.4, dampingFraction: 0.8))` 设 `currentPage = .album`。
- **歌词页出错自动回退专辑页**：`LyricsView.swift:809-812`——`newError != nil && !musicController.userManuallyOpenedLyrics && currentPage == .lyrics` 时设 `currentPage = .album`（非用户手势触发，是数据层副作用）。
- 未发现二指滑动手势直接触发切页——`SnappablePanel.swift` 里的二指滚动只用于贴边/隐藏（见第 3 节），不驱动 `currentPage`。

### 1.4 切页动画（三时钟）
`MiniPlayerView.swift:295` 起的 `pageSwitchAnimations` 计算属性，驱动三条独立动画通道：`.geometry`（matchedGeometryEffect hero 移动 + 页面 offset，用于 album 页 `.zIndex`/`.animation`，`MiniPlayerView.swift:104,110`）、`.content`（新页文字/控件透明度，行 122）、`.material`（PanelBackdrop/覆盖层材质渐隐，行 96，仅用于 playlist）。

三时钟具体时长由 `Sources/MusicMiniPlayerCore/UI/PageSwitchClockScheduler.swift` 计算：
- Reduce Motion：全部退化为 `.linear(duration: 0.1)`（`PageSwitchClockScheduler.swift:47-54`）。
- `.single` 臂（默认之一）或 Reduce Motion：三通道字节级等同今日的 `.spring(response: 0.25, dampingFraction: 0.9)`（`PageSwitchClockScheduler.swift:75-78` 注释 + `animations()` 实现 79-89 行，`guard arm == .split else { ... return (today, today, today) }`）。
- `.split` 臂：三通道各自用 `.smooth(duration:)`，content 额外加 `contentLag` 延迟（`PageSwitchClockScheduler.swift:87-92`）。
- 臂选择读自 `MicroInteractionFeel.PageSwitchMode`（`.split`/`.single`，定义于 `MicroInteractionFeel.swift:130-138`，默认 `.split`——`resolve(from:)` 里 `?? .split`，行 136），可经 `nanopod://debug/feel/pageswitch/<split|single>` 切换（`MicroInteractionFeel.swift:382-383`）。

注意：点击封面切页那处（`MiniPlayerView.swift:693-704`）用的是**硬编码** `.spring(response: 0.2, dampingFraction: 1.0)`，**不经过** `pageSwitchAnimations`/`PageSwitchClockScheduler` —— 这条路径与另外两条切页路径（playlist→album 两处、材质/geometry 三时钟那条）用的是不同的动画配方，是本次重做需要注意的不一致点。

### 1.5 页面状态是否跨窗口隐藏/恢复保持
**保持，不重置。** 在 `Sources/MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift` 中搜遍所有隐藏路径（`collapseToMenuBar()` 行 498-505、`dismissFloatingWindow()` 行 549-568、`toggleFloatingWindow()` 隐藏分支行 475-478、`hideToEdge()` 行 492-494）均只操作 `floatingWindow`/`isFloatingMode`/`musicController.setPanelOccluded`，**没有任何一处写 `musicController.currentPage = .album`**。全仓 grep `currentPage = .album` 只命中 SwiftUI 视图内的用户交互路径（`MiniPlayerView.swift:701`, `PlaylistView.swift:374`, `PlaylistView.swift:720`），AppMain.swift 里零命中。因此：菜单栏收起再展开、贴边隐藏再恢复，`currentPage` 原样保留——如果用户在歌词页贴边隐藏，恢复后仍是歌词页。

---

## 2. Window geometry（窗口几何）

文件：`Sources/MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift`（浮动面板创建）、`Sources/MusicMiniPlayerCore/UI/SnappablePanel.swift`（面板类本身，几何限制字段声明在此类但赋值在 AppMain）。

### 2.1 默认尺寸与位置
`createFloatingWindow()`，`MusicMiniPlayerApp.swift:344-351`：
```swift
let windowSize = NSSize(width: 250, height: 316)
let screenFrame = NSScreen.main?.visibleFrame ?? .zero
let windowRect = NSRect(
    x: screenFrame.maxX - windowSize.width - 20,
    y: screenFrame.maxY - windowSize.height - 20,
    ...)
```
默认贴屏幕右上角，留 20pt 边距。

### 2.2 宽高比锁定 / 缩放范围
`MusicMiniPlayerApp.swift:377-379`：
```swift
snappableWindow.aspectRatio = NSSize(width: 250, height: 316)
snappableWindow.minSize = NSSize(width: 180, height: 228)
snappableWindow.maxSize = NSSize(width: 400, height: 506)
```
250:316 比例锁定（`NSWindow.aspectRatio` 是 AppKit 原生约束，用户拖角缩放时保持比例）。这些值是**全局单一值，不按页面区分**——没有找到任何按 `currentPage` 切换 min/max/aspectRatio 的代码（grep `aspectRatio\|minSize\|maxSize` 只命中这一处赋值）。

### 2.3 用户可调整大小
`styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]`（`MusicMiniPlayerApp.swift:357`）——`.resizable` 位打开，AppKit 原生边缘拖拽可用；另有 `Sources/MusicMiniPlayerCore/UI/Components/WindowResizeHandler.swift`（未在本次读取中展开，规模超出本任务范围，仅确认其存在于目录清单中，见 CLAUDE.md 目录树）。

### 2.4 窗口层级 / 空间行为 / 全屏行为
`MusicMiniPlayerApp.swift:364-370`：
```swift
snappableWindow.isFloatingPanel = true
snappableWindow.level = .floating
snappableWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
snappableWindow.backgroundColor = .clear
snappableWindow.isOpaque = false
snappableWindow.hasShadow = true
snappableWindow.isMovableByWindowBackground = false
snappableWindow.titlebarAppearsTransparent = true
snappableWindow.titleVisibility = .hidden
snappableWindow.hidesOnDeactivate = false
snappableWindow.acceptsMouseMovedEvents = true
snappableWindow.becomesKeyOnlyIfNeeded = false
```
- `.floating` level：浮在普通窗口之上。
- `.canJoinAllSpaces`：跟随用户切换 Space 始终可见。
- `.fullScreenAuxiliary`：可在其他 App 全屏时仍显示（辅助窗口身份）。
- `.transient`：不出现在 Mission Control/App Exposé 的独立窗口列表里。
- `.nonactivatingPanel`（styleMask 位，行 357）：点击面板不会激活 App/抢焦点。
- 无标题栏可见（`titleVisibility = .hidden` + `titlebarAppearsTransparent`），三个标准窗口按钮全部 `isHidden = true`（`MusicMiniPlayerApp.swift:466-468`）。

### 2.5 SnappablePanel 类自身字段（声明处）
`SnappablePanel.swift:10-13`：`cornerMargin: CGFloat = 16`、`projectionFactor: CGFloat = 0.28`（甩手投掷惯性系数）、`snapToCorners: Bool = true`、`edgeHiddenVisibleWidth: CGFloat = 6`（贴边隐藏时露出宽度，即"6pt sliver"，对应任务描述里的 6pt）。

---

## 3. 手势 / 输入清单

### 3.1 二指触控板滚动（专辑页 vs 歌词/播放列表页分流）
分流逻辑在 `SnappablePanel.sendEvent(_:)` 的 `.scrollWheel` 分支，`SnappablePanel.swift:99-163`：

- **专辑页**（`currentPage == .album`，行 102-111）：任何二指滚动都走 `handleScrollDrag`/`handleScrollEnd`（全方向拖拽+贴边），"双指触控板手势用于贴边/隐藏（全方向）"（注释行 101）。
- **歌词/播放列表页**（行 112-158）：横向手势才触发贴边隐藏，纵向传给内容（滚动歌词/播放列表）；有"残余动量抑制"逻辑（`suppressMomentum`，行 116-123）防止横向手势的惯性泄漏给内容滚动引发抽搐；方向判定用阈值 `absX > absY * 1.2 && absX > 2.0` 判横向、`absY > 1.0` 判纵向（行 131-136），一旦确定方向本次手势不再切换。

`handleHorizontalHideGesture`/`handleHorizontalHideGestureEnd`：`SnappablePanel.swift:314-341`（实现细节未逐行摘录，超出行号范围但已确认存在，供后续深入读取）。
`checkAndHideToEdgeWithVelocity`：`SnappablePanel.swift:343`——按松手速度判定是否贴边。

### 3.2 鼠标拖拽（移动窗口）
`handleMouseDown`/`handleMouseDragged`/`handleMouseUp`：`SnappablePanel.swift:171-238`。关键点：
- `handleMouseDown`（171-192）：若 `isEdgeHidden`，直接 `restoreFromEdge()` 并 return（行 172-175）——**贴边态下任意鼠标按下即恢复**，不需要先 hover。会跳过可交互控件命中测试（`isInteractiveView`，行 177-180）和底部控制区（`isInBottomControlsArea`，行 182-184）。
- 拖拽只移动真实窗口 frame（`setFrameOrigin`，行 213），不做惯性预测；松手时"鼠标拖拽只移动窗口，贴边/隐藏由双指触控板手势处理"（注释行 235，即拖拽松手本身不触发贴边）。
- 拖拽距离 < 3pt 视为点击而非拖拽（行 229-232），事件继续传递。

### 3.3 Hover Peek（贴边态下鼠标悬停偷看）
`handleMouseMoved`：`SnappablePanel.swift:440-457`。`mouseInWindow` 进入 → `peekFromEdge()`（行 459-478，向内平移 `peekAmount = 30pt`，行 438）；离开 → `hideBackToEdge()`（行 480-501，弹回贴边位置）。两者都调用 `onGeometryMorphWillStart?(.peekEntered/.peekExited, ...)` 通知 `EdgePresentationModel`（行 463, 484）后走 `startPeekAnimation()`。这是"直接移动真实窗口"式的动画（注释行 504："🔑 直接移动真实窗口：用户要看到 hover 动画随窗口飞的灵动感"）。

### 3.4 键盘全局快捷键
`GlobalShortcutAction` 枚举，`Sources/MusicMiniPlayerCore/Services/GlobalShortcuts.swift:24-30`，共 5 个 case：
| Case | 绑定名 | 分发目标（`handler(for:controller:panel:)`, `GlobalShortcuts.swift:80-97`） |
|---|---|---|
| `.togglePlayPause` | `.togglePlayPause` | `controller?.togglePlayPause()` |
| `.nextTrack` | `.nextTrack` | `controller?.nextTrack()` |
| `.previousTrack` | `.previousTrack` | `controller?.previousTrack()` |
| `.togglePanel` | `.togglePanel` | `panel?.togglePanel()` → `AppMain.togglePanel()` → `toggleFloatingWindow()`（`MusicMiniPlayerApp.swift:474-484`；`486-488` 是 `PanelCommands` 协议入口） |
| `.hideToEdge` | `.hideToEdge` | `panel?.hideToEdge()` → `AppMain.hideToEdge()` → `(floatingWindow as? SnappablePanel)?.hideToNearestEdge()`（`MusicMiniPlayerApp.swift:491-494`） |

注册：`GlobalShortcutRegistrar.activate()`，`GlobalShortcuts.swift:101` 起，对 `GlobalShortcutAction.allCases` 逐一挂 `KeyboardShortcuts.onKeyDown`（行 106-108）。快捷键本身用第三方 `KeyboardShortcuts` 库存储用户自定义键位（`SettingsView.swift` 内配置 UI，未展开）。

### 3.5 菜单栏图标点击
`statusItem.menu = menu`（`MusicMiniPlayerApp.swift:311`）——标准 `NSStatusItem` 挂 `NSMenu`，点击图标即弹出菜单（AppKit 原生行为，无自定义点击处理器；`menuNeedsUpdate(_:)` 行 587-590 在菜单弹出前重建菜单项）。菜单内含"显示窗口"项（`showWindowFromMenu`，行 594-597 附近）。`toggleMode()`（行 329-339）是菜单栏模式 ↔ 浮动模式切换的旧入口，目前 `showMenuBarMenu()` 用 `button.performClick(nil)` 程序化弹出菜单（行 579-582）。

### 3.6 ScrollDetector（歌词/播放列表内部滚动 vs 面板贴边手势的消歧）
文件：`Sources/MusicMiniPlayerCore/UI/Components/ScrollDetector.swift`（351 行，本次未逐行深入，规模超出本任务核心范围）。已确认的分工边界：`SnappablePanel.sendEvent` 在方向判定为"纵向"时调用 `super.sendEvent(event)` 放行给内容视图（`SnappablePanel.swift:145`），内容视图内部的滚动检测（进入手动滚动模式、恢复自动滚动等）由 `ScrollDetector.swift` 承接；两者的边界就是 `SnappablePanel.swift:99-163` 那段方向仲裁代码——面板层先吃事件做横向/纵向分流，纵向的部分才轮到 `ScrollDetector`。**（推测：`ScrollDetector.swift` 内部具体实现未读取，此段落只从调用边界反推分工，未直接引用该文件的行号——如需精确 file:line 需要单独读取该文件。）**

---

## 4. Show/Hide 路径清单

文件：`Sources/MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift`、`Sources/MusicMiniPlayerCore/UI/EdgePresentation.swift`。

`EdgePresentation` 枚举（`EdgePresentation.swift:16-22`）5 态：`.card`（正常/贴边前）、`.hidingToPill`（hideToEdge 触发过渡中）、`.pill`（已贴边未 peek）、`.peeking`（贴边 hover 偷看中）、`.restoringToCard`（restore 过渡中）。由 `EdgePresentationReducer.reduce(current:event:)` 纯函数状态机驱动（`EdgePresentation.swift:58-87`），事件源 `SnapEvent`（`.hideRequested/.restoreRequested/.peekEntered/.peekExited/.settled`，行 26-32）。转移表见 `EdgePresentation.swift:39-45` 文档注释（完整穷举 5x5，含非法组合原样返回 current）。

以下是让窗口出现/消失的入口，及各自落下的 `EdgePresentation` 态：

| # | 入口 | 代码位置 | 效果 | 落下的 EdgePresentation 态 |
|---|---|---|---|---|
| 1 | 状态栏图标点击 | AppKit 原生 `NSStatusItem` + `NSMenu`（`MusicMiniPlayerApp.swift:311`） | 弹出菜单，菜单内"显示窗口"项 | 不直接过 EdgePresentation（菜单是独立 UI，不是浮动面板本身） |
| 2 | 菜单内"显示窗口" | `showWindowFromMenu` → `revealFloatingWindowFromMenuBar()`（`MusicMiniPlayerApp.swift:566-569`） | `isFloatingMode = true; showFloatingWindow(revealNearbySnapPosition: true)` | 不改 EdgePresentation（geometry 回调只在 `onGeometryMorphWillStart/DidSettle` 触发，程序化 show 不经过这些 hook——**推测**：因为未在 `showFloatingWindow`/`presentFloatingWindow` 里看到任何 `edgePresentationModel.apply(...)` 调用，只在 `SnappablePanel` 的贴边/peek/restore 几何动画钩子里调用，见 `MusicMiniPlayerApp.swift:405-461`） |
| 3 | 全局快捷键 `togglePanel` | `AppMain.togglePanel()` → `toggleFloatingWindow()`（`MusicMiniPlayerApp.swift:474-484`） | 可见则 `dismissFloatingWindow` + `setPanelOccluded(true)`；不可见则 `presentFloatingWindow(makeKey:false)` + `setPanelOccluded(false)` | 同上，不直接驱动 EdgePresentation（该路径只是整窗 order in/out，非贴边几何） |
| 4 | 全局快捷键 `hideToEdge` | `AppMain.hideToEdge()` → `SnappablePanel.hideToNearestEdge()`（`MusicMiniPlayerApp.swift:491-494`；内部见 `SnappablePanel.swift:369`） | 触发几何贴边动画 | `onGeometryMorphWillStart(.hideRequested)` → `.card`/`.restoringToCard` → `.hidingToPill`；动画落定 `.settled` → `.pill`（`hideToEdge(_:)` 实现 `SnappablePanel.swift:377-405`，内部行 381 fire `.hideRequested`） |
| 5 | 鼠标点击贴边态面板（任意处） | `handleMouseDown` 内 `if isEdgeHidden { restoreFromEdge(); return }`（`SnappablePanel.swift:172-175`） | 恢复到 card | `.restoreRequested` fire（`restoreFromEdge()` 内 `SnappablePanel.swift:411`）→ 落 `.restoringToCard`，settled 后 `.card` |
| 6 | Hover 进入贴边态面板 | `handleMouseMoved` → `peekFromEdge()`（`SnappablePanel.swift:440-478`） | 面板向内探出 30pt | `.peekEntered` fire（行 463）→ `.pill` → `.peeking` |
| 7 | Hover 离开（peek 中） | `handleMouseMoved` → `hideBackToEdge()`（`SnappablePanel.swift:480-501`） | 弹回贴边 | `.peekExited` fire（行 484）→ `.peeking` → `.pill` |
| 8 | 收起回菜单栏（隐藏按钮/`onHide`） | `MiniPlayerContentView(onHide: { collapseToMenuBar() })`（`MusicMiniPlayerApp.swift:443-445`）→ `collapseToMenuBar()`（行 498-505） | `dismissFloatingWindow` + `setPanelOccluded(true)` + `showMenuBarMenu()` | 不驱动 EdgePresentation（整窗隐藏，非贴边几何路径） |
| 9 | 旧的 `toggleMode()` 模式切换 | `MusicMiniPlayerApp.swift:329-339` | accessory↔floating 模式切换的历史入口，`showFloatingWindow()`/`floatingWindow?.orderOut(nil)` | 同 #2/#3，不驱动 EdgePresentation |
| 10 | `windowShouldClose` 委托回调 | `dismissFloatingWindowFromDelegate(_:)`（`MusicMiniPlayerApp.swift:505-507`，转给 `dismissFloatingWindow`） | 同 dismiss 路径的淡出效果 | 同 #3，不驱动 EdgePresentation |

**关键发现**：只有「贴边隐藏 / 鼠标点击恢复 / hover peek 进出」（#4/#5/#6/#7，均在 `SnappablePanel.swift` 内部）驱动 `EdgePresentationModel`；「整窗显示/隐藏」（#2/#3/#8/#9/#10，均在 `MusicMiniPlayerApp.swift` 顶层）走另一套完全独立的 `windowPresent` 淡入淡出通道（`presentFloatingWindow`/`dismissFloatingWindow`，`MusicMiniPlayerApp.swift:517-568`），两套动效系统目前互不相交——这是任务要求"重做 collapse-to-edge 动效"时必须先厘清的边界：贴边动效只服务 #4-#7 四条路径，不服务整窗显示隐藏。

### 4.1 windowPresent 淡入淡出通道（整窗 show/hide 用，非贴边）
`presentFloatingWindow(_:makeKey:)`（`MusicMiniPlayerApp.swift:517-537`）：Reduce Motion 或 `.hardcut` 臂时直接 `alphaValue = 1` + `makeKeyAndOrderFront`/`orderFront`（无动画）；否则 `alphaValue = 0` 起手，`NSAnimationContext` 跑 `windowFadeInDuration` 渐显（`easeOut`）。`dismissFloatingWindow(_:)`（行 545-568）对称：淡出到 0 后 `orderOut` + 复位 `alphaValue = 1`。两者都用 `windowPresentGeneration` 计数器防止快速连续 show/hide 时旧动画的 completion 覆盖新状态（`WindowPresentGeneration.advance/shouldApply`，行 519/538/551/564，定义于 `MicroInteractionFeel.swift:628` 起）。臂开关 `MicroInteractionFeel.windowPresent`（`.fade`默认 / `.hardcut`，`MicroInteractionFeel.swift:79-90`）。

---

## 5. "贴边隐藏 6pt sliver" 与 "peek" 态下每页显示什么

**核心发现：pill 内容完全不感知 `currentPage`（专辑/歌词/播放列表），只感知 `EdgePresentation` 态本身。**

`EdgeMorphHost.pillContent(presentation:)`（`Sources/MusicMiniPlayerCore/UI/EdgeMorphHost.swift:169-190`）：
```swift
VStack(spacing: 6) {
    if let artwork = musicController.currentArtwork { Image(...) }   // 24x24 圆角封面缩略图
    Capsule().fill(Color.white.opacity(0.5)).frame(width: 2)          // 细分隔线
    if presentation == .peeking {
        Button { musicController.togglePlayPause() } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
    }
}
```
- **贴边 6pt sliver（`.pill`/`.hidingToPill`/`.restoringToCard` 态，`edgeHiddenVisibleWidth = 6`，`SnappablePanel.swift:13`）**：pill 宽度非 peeking 时是 20pt（`pillContent` 内 `.frame(width: presentation == .peeking ? 44 : 20)`，行 187），显示专辑封面缩略图 + 分隔线，**不显示播放/暂停按钮**（该按钮只在 `.peeking` 分支渲染）。
- **Peek 态（`.peeking`，宽度变为 44pt）**：额外显示播放/暂停按钮。
- 无论当前 `currentPage` 是 `.album`/`.lyrics`/`.playlist`，pill 内容完全一样——**歌词页贴边时 sliver/peek 不显示任何歌词内容**，只显示当前曲目的封面图（来自 `musicController.currentArtwork`，全局状态非页面相关）。这是任务描述里明确要核实的点：「歌词页 peek 是否显示歌词」——**代码给出的答案是否定的**，pill 内容与页面无关，只有一套通用的"封面+分隔线(+播放按钮)"视图。

其他细节：
- pill 从哪条边露出由 `edgePresentation.snappedEdge`（`SnappedEdge` 枚举 `.none/.left/.right`，`EdgePresentation.swift:96-98`）决定，`.frame(maxWidth: .infinity, alignment: edge == .left ? .leading : .trailing)`（`EdgeMorphHost.swift:189`）。
- `showsPill(presentation:arm:)` 纯函数（`EdgeMorphHost.swift:192-200`）：`.v0` 臂永不显示 pill；`.morph` 臂在除 `.card` 外全部 4 态显示。
- pill 渲染依赖 macOS 26 `GlassEffectContainer`/`glassEffect` API（`#available(macOS 26.0, *)` 门控，`EdgeMorphHost.swift:32`），macOS < 26 或 `.v0` 臂下渲染 `EmptyView()`（行 88-92, 95-97）——即旧系统上贴边态没有这个玻璃 pill 视觉，只剩 `SnappablePanel` 自身几何位移出的 6pt 窄条（窗口本体，非 SwiftUI 内容层）。

---

## 6. Background（背景）

文件：`Sources/MusicMiniPlayerCore/UI/Background/PanelBackdrop.swift`（130 行）、`FluidGradientBackground.swift`（319 行）。

### 6.1 PanelBackdropStyle（两种底材）
`PanelBackdropStyle` 枚举，`PanelBackdrop.swift:16-19`：`.fluid`（默认，流体渐变，不透明）、`.glass`（macOS 26 原生 `NSGlassEffectView` 玻璃实验臂）。`resolve(from:)` 未知/缺省值回落 `.fluid`（行 23-30，被 `PanelBackdropStyleTests.test_resolve_absentValue_fallsBackToFluid` 钉死）。运行时切换：`nanopod://debug/backdrop/<style>`（见 CLAUDE.md 目录树条目）。

### 6.2 PanelBackdropRole（两种角色）
`PanelBackdropRole` 枚举，`PanelBackdrop.swift:32-34`：`.base`（面板根层背景，`MiniPlayerView.swift:63` 用）、`.pageOverlay`（页面级叠加，`PlaylistView.swift:114` 用，只有 playlist 页额外套一层）。`.fluid` 样式下两个角色渲染路径不同（`case .fluid:` 行 64-67 附近，`case .glass:` 下 `.base`/`.pageOverlay` 又各自分支，行 69-72）——具体差异需要深入读 60-100 行区间，本次未逐行摘录（**推测**：从调用点看 `.base` 是唯一挂在 `MiniPlayerView` 根 ZStack 的背景层，`.pageOverlay` 是 playlist 页额外叠加的第二层，两者具体渲染细节需单独读取该文件 60-100 行）。

`LyricsView` 本身**不**单独挂 `PanelBackdrop`（`grep PanelBackdrop LyricsView.swift` 零命中）——歌词页直接透明地坐在 `MiniPlayerView` 根层的 `.base` 背景之上（`MiniPlayerView.swift:63` 的 `PanelBackdrop(artwork:)` 在 ZStack 最底层，`LyricsView` 在其上以 `.zIndex(1)` 叠加，`MiniPlayerView.swift:82-86`）。也就是说：**歌词页背景 = 专辑页共用的同一张 `.base` FluidGradientBackground**，只有 playlist 页额外套了 `.pageOverlay` 一层。

### 6.3 FluidGradientBackground / C5 对比度层
`FluidGradientBackground` struct，`FluidGradientBackground.swift:12` 起。C5（roadmap C5「浅色封面对比度」）相关：
- `contrastResolution` 状态，每次封面变化解析一次（`@State private var contrastResolution = ArtworkContrastPolicy.resolve(...)`，行 23，更新逻辑在 `updateTone()` 行 142-152）。
- 模糊/饱和度：`.blur(radius: legacyArtworkContrast ? 58 : contrastResolution.blurRadius)`、`.saturation(...)`（行 60-61）。
- **C5 额外可读性 scrim**（亮色封面加暗）：行 72-78，`.opacity(contrastResolution.darkenOpacity)`，用 `.smooth(duration: MicroInteractionFeel.Tokens.artworkContrastDarkenAnimationDuration)` 动画过渡（行 78）。
- `ArtworkContrastPolicy`（`MicroInteractionFeel.swift:497` 起）是驱动这层的策略函数，参数来自 `MicroInteractionFeel.Tokens`（`artworkContrastBlurRadius/darken/brightnessThreshold/saturation/darkenRamp`，`MicroInteractionFeel.swift:166-170`）。

---

## 7. MicroInteractionFeel 中与窗口/边缘相关的对照臂通道

文件：`Sources/MusicMiniPlayerCore/UI/MicroInteractionFeel.swift`（641 行）。总控注释：`nanopod://debug/feel/<channel>/<arm>` 实时切换，未知值回落默认（行 10-11）。

### 7.1 windowPresent（整窗淡入淡出）
- 枚举 `WindowPresentMode`：`.fade`（默认）/ `.hardcut`（`MicroInteractionFeel.swift:79-90`）。
- 调试命令：`nanopod://debug/feel/windowPresent/<fade|hardcut>`（case 分支 `"windowpresent"`，`MicroInteractionFeel.swift:370-372`）。
- 默认存储键：`windowPresentDefaultsKey = "nanoPodFeelWindowPresent"`（行 31）。
- 用于第 4 节的 `presentFloatingWindow`/`dismissFloatingWindow`。

### 7.2 edgeMorph（贴边card↔pill形变）
- 枚举 `EdgeMorphMode`：`.morph`（默认）/ `.v0`（`MicroInteractionFeel.swift:93-104`）。
- 调试命令：`nanopod://debug/feel/edgeMorph/<morph|v0>`（`"edgemorph"` 分支，行 373-375）。
- 默认存储键：`edgeMorphDefaultsKey = "nanoPodFeelEdgeMorph"`（行 32）。
- 三时钟 token（`MicroInteractionFeel.swift:449-453`）：
  - `edgeMorphPreSeedLead: 0.02`（预埋提前量）
  - `edgeMorphContentLagMin: 0.02` / `edgeMorphContentLagMax: 0.08`（内容切换延迟范围）
  - `edgeMorphMaterialSettle: 0.31`（材质渐显时长）
  - `edgeMorphContentDuration: 0.14`（身份切换动画时长）
- 用于第 5 节的 `EdgeMorphHost`/`EdgeMorphClockScheduler`。

### 7.3 pageSwitch（三页切换三时钟）
- 枚举 `PageSwitchMode`：`.split`（默认）/ `.single`（`MicroInteractionFeel.swift:130-141`）。
- 调试命令：`nanopod://debug/feel/pageswitch/<split|single>`（`"pageswitch"` 分支，行 382-384）。
- 默认存储键：`pageSwitchDefaultsKey = "nanoPodFeelPageSwitch"`（行 35）。
- token 组（行 461 起注释「C2 page-switch three-clock scheduler」，未在本次 grep 范围内逐一摘出具体数值，需要读 461-495 行区间获取 `pageGeometryDuration`/`pageContentLag`/`pageContentDuration`/`pageMaterialDuration` 精确值——**推测**：`PageSwitchClockScheduler.swift:59-64` 引用了这四个 token 名，说明其存在，但本次未读取赋值行号）。

### 7.4 全部重置入口
`MicroInteractionFeel.swift:417-421`：`resetAll()`（或类似方法）清空 `windowPresentDefaultsKey`/`edgeMorphDefaultsKey`/`pageSwitchDefaultsKey` 等全部 UserDefaults 覆盖，回到编译期默认值。

---

## 8. 既有测试（钉死边缘行为）

### `Tests/MusicMiniPlayerTests/EdgePresentationReducerTests.swift`
- `test_exhaustive_transitionTable`（行 27）——穷举 5x5 转移表
- `test_illegalCombos_returnCurrentUnchanged`（行 40）——非法组合原样返回
- `test_interruption_hideRequestedDuringRestore`（行 54）——restore 途中被 hideRequested 打断
- `test_model_appliesReducerAndPublishes`（行 63）——`EdgePresentationModel` 正确发布

### `Tests/MusicMiniPlayerTests/EdgeMorphFeelTests.swift`
- `test_resolve_absentValue_fallsBackToMorph`（行 23）
- `test_resolve_unknownValue_fallsBackToMorph`（行 27）
- `test_resolve_knownValues_caseInsensitive`（行 32）
- `test_apply_setsDefaultsBackedValue_untilReset`（行 43）
- `test_apply_unknownValue_clampsToMorphInDefaults`（行 57）
- `test_apply_reset_channel_clearsEdgeMorph`（行 66）
- `test_showsPill_v0_neverShows`（行 80）
- `test_showsPill_morph_showsForEveryNonCardState`（行 89）
- `test_baseBackdropHidden_mirrorsShowsPill`（行 100）

### `Tests/MusicMiniPlayerTests/EdgeMorphClockSchedulerTests.swift`
- `test_plan_normal_preSeedStartsAtT0`（行 20）
- `test_plan_normal_contentStartsAtContentLagMin`（行 25）
- `test_plan_normal_materialStartsAtContentLagMin`（行 30）
- `test_plan_normal_contentDurationMatchesToken`（行 35）
- `test_plan_normal_materialDurationMatchesSettleToken`（行 40）
- `test_plan_reduceMotion_allStartsEqualT0`（行 49）
- `test_plan_reduceMotion_durationsAre015`（行 56）
- `test_ordering_preSeedNeverStartsAfterContentOrMaterial`（行 66）
- `test_ordering_materialEndIsAtOrAfterContentEnd`（行 74）
- `test_ordering_contentDurationWithinGeometryClassRange`（行 83）
- `test_ordering_materialDurationWithinSettleRange`（行 89）
- `test_tokens_pinnedValues`（行 99）
- `test_animations_reduceMotion_bothLinear015`（行 111）
- `test_animations_normal_useSmoothWithTokenDurations`（行 117）
- `test_shouldApply_sameGeneration_true`（行 127）
- `test_shouldApply_staleGeneration_false`（行 131）
- `test_shouldApply_futureGenerationNeverObserved_stillFalseWhenMismatched`（行 136）

### SnappablePanel 相关测试文件
全仓 grep 未找到名为 `SnappablePanel*Tests.swift` 的独立测试文件（`find Tests -iname "*SnappablePanel*"` 零命中）。`SnappablePanel.swift` 本身（贴边几何弹簧、拖拽惯性、mouse hit-test 分流等）**没有专属单元测试文件**——现有测试覆盖的是它上游/下游的纯状态机（`EdgePresentationReducer`）和纯调度器（`EdgeMorphClockScheduler`），`SnappablePanel` 这个 AppKit 类本身（`sendEvent`/`handleScrollDrag`/`calculateReleaseVelocity`/`calculateTargetCorner` 等）目前处于测试盲区。`PanelBackdropStyleTests.swift`（找到但不属于本节要求的四个文件清单，额外发现）覆盖 `PanelBackdropStyle.resolve` 的缺省回落行为（`test_resolve_absentValue_fallsBackToFluid` 行 18、`test_resolve_unknownValue_fallsBackToFluid` 行 22、`test_resolve_knownStyles_caseInsensitive` 行 31）。

---

## 附：本次调研的已知缺口（供后续深挖）

1. `ScrollDetector.swift`（351 行）内部具体实现未逐行读取，只从调用边界反推了分工（第 3.6 节）。
2. `PanelBackdrop.swift` 60-100 行区间（`.fluid`/`.glass` 两种样式 x `.base`/`.pageOverlay` 两种角色的四种组合渲染细节）未逐行摘录。
3. `MicroInteractionFeel.Tokens` 中 pageSwitch 相关 4 个 token 的具体数值（`pageGeometryDuration`/`pageContentLag`/`pageContentDuration`/`pageMaterialDuration`）未读取赋值行号，只确认了其被引用。
4. `WindowResizeHandler.swift` 完全未读取（任务列出但本次未深入，因其与「collapse-to-edge 动效」关联度低于其余 7 节）。
5. `SnappablePanel.swift` 中 `calculateReleaseVelocity`/`calculateTargetCorner`/`launchAnimation`/`renderFrame` 的具体弹簧数学（行 517-666 区间）未逐行摘录，只确认函数存在及大致职责。
