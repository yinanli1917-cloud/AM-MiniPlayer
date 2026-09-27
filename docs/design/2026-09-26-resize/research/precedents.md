# 面板缩放 · 平台与业界先例（原始记录，2026-09-26）

设计会话抓取。每条给出处 URL 与当次读到的原文（英文照录），供 `../proposal.md` §2 引用。Apple 开发者文档站是 JS 渲染，直接抓只回标题，HIG 两页经 r.jina.ai 转 Markdown 读到正文；Apple 支持页按文章 id 直抓。

## 1. macOS 画中画（Picture in Picture）

- Apple Support HT206997「Watch video using Picture in Picture on your Mac」：
  - "You can drag the window to any corner of the screen and the window stays put, even if you switch desktop spaces."
  - "You can resize the window to see more or less of what's behind it."
  - 搜索摘要另给："To make the window bigger or smaller, drag the edge or corner of the window."
- 第三方（iDownloadBlog 2016-10-24、OSXDaily 2016-12-19）：默认拖动会吸到四角之一；按住 Command 拖可放任意位置。
- 结论：自由拖边缩放（视频比例固定）+ 四角吸附。内容是位图视频，缩放不涉及排版。

## 2. iOS 画中画

- Apple Support iphcc3587b5d「Multitask with Picture in Picture on iPhone」：
  - "To make the small video window larger, pinch open. To shrink it again, pinch closed."
  - "Drag it to a different corner of the screen."
  - "Drag it off the left or right edge of the screen."
- MacRumors「iOS 14: How to Use Picture in Picture Mode on iPhone」：
  - "You can double tap on any Picture in Picture window or use pinch gestures to change the Picture in Picture window size."
  - "There are three sizes to choose from: small, medium, and large."
  - "The small window is about the size of two app icons, the medium is as wide as about three app icons and as tall as one and a half, while the largest window is the size of eight app icons."
  - "The small and medium windows can be moved to any corner of the iPhone's display, while the large Picture in Picture window can be placed at the top or the bottom of the screen."
- Cult of Mac「Change the size of picture-in-picture windows」："There are three PiP window sizes to choose from on both iPhone and iPad." 双击循环切档。
- 结论：捏合连续驱动、松手落到三档之一；双击循环；档位决定可停靠的位置。

## 3. 小组件（Widgets）

- HIG「Widgets」（developer.apple.com/design/human-interface-guidelines/widgets，经 r.jina.ai）：
  - 尺寸族：small / medium / large / extra large / extra large portrait。
  - "Avoid expanding a smaller widget's content to simply fill a larger area."
  - "It's more important to create one widget in the size that best represents the content than providing the widget in all sizes."
  - "Offer widgets in multiple sizes when doing so adds value."
  - 规格表：iOS（430×932）small 170×170、medium 364×170、large 364×382；iPadOS（1024×1366）small 170×170、medium 378.5×170、large 378.5×378.5、extra large 795×378.5。表里没有 macOS 行。
- macOS 桌面小组件（Sonoma 起）：Control-click 小组件选 Small / Medium / Large（部分 Extra Large）——Setapp「How to add widgets on Mac」、MacRumors「How Interactive Widgets Work in macOS Sonoma」。
- 结论：固定几档，每档单独设计版式；HIG 明确反对「把小的拉大填满」。

## 4. Music.app 迷你播放器（MiniPlayer）

- Apple Support mus71d7dcfce「Use Music MiniPlayer on Mac」：
  - 打开："Choose Window > Switch to MiniPlayer"。
  - "MiniPlayer displays the album artwork for the song that's playing. When you move the pointer over the artwork, controls appear."
  - 缩小：More 按钮 → "Hide Large Artwork"（只剩控件）；还原 "Show Large Artwork"。
  - 置顶：Music > Settings > Advanced > "Keep MiniPlayer on top of all other windows"。
- iDownloadBlog 2020-04-07「How to use the Apple Music MiniPlayer on your Mac」："just drag an edge or corner to resize it."；"the next time you open it, your adjustments will be remembered."
- Apple Community 251380256：四角光标变双向箭头后拖动。2017 年旧帖（7816884）称 mini-player 被限制在约 400×400，未验证、版本已过时。
- 本仓库参考截图 `../../2026-09-26-album-buttons/ref-apple-music-miniplayer.webp`：封面铺满 + 控件覆盖在封面下部，尺寸变化时封面跟着变、控件字号不变。
- 结论：自由拖边（记住尺寸）+ 两种形态（有/无大封面）。

## 5. Liqoria

- 官网 liqoria.com：Floating / menu bar / dock / Lock Screen 四种播放器；"Music widget for Mac … designed in multiple sizes"；"Pin Window option … respecting grid-based layouts"。
- 博客「Liqoria slim player, Music Widget」："The Slim Player is perfect for users who want quick access to Now Playing controls, but feel the normal floating player is too big" … "Just swipe up and instantly, a beautiful Slim Player appears"。全文没有自由缩放。
- Changelog（liqoria.com/changelog）：1.0.9 "New Slim Player – swipe up from the normal player to enter Slim Player"；1.1 "Minimized floating player now returns to its last position"；1.3.0 "Animated artwork on Big Player – now displays when expanded"；1.4.6 "Pin Window option that makes the floating player respect the grid layout"；1.7.0.2 "Enhanced Liquid Glass design for the Massive Floating Player"；1.7.5 "New pill-style Notch Player"。
- 本仓库逐帧测量（`research/references/liqoria-demo-animation-spec.md` §1、§2.1；`liqoria-liquid-glass-spec.md` §2.2）：四个形态——compact pill 580×300 px、expanded card 585×945 px（同一左上锚点，只长高）、card+lyrics 1190×945 px（整体左移约 300 px）、ultra-compact glanceable pill；card→pill 是先塌高再展宽、两套版式中途交叉淡化、目标缩略图提前约 20 ms 预置、几何 125–150 ms、材质沉降 270–350 ms。两段录像都没有拖边缩放。
- 结论：Liqoria 的是「形态切换」（pill / card / card+lyrics / notch / dock），不同形态不同版式，用滑动或点击进入；不是同一张卡的几个尺码。

## 6. 其他迷你播放器

- Spotify 桌面 Miniplayer（2024-03 上线，nerdschalk / TechBloat / Digital Music News）：始终置顶；可自由拖成不同形状——"a small box, a wider rectangle, or a slim bar"，版式随形状变（响应式）。
- Sleeve（replay.software/sleeve）："Pin Sleeve to any desktop corner or edge, across any active displays."；"Scale artwork all the way up or all the way down."；"Customize the layout, alignment and position to fit your setup."——桌面无边框小件，尺寸是设置里的连续滑杆，不是窗口拖边。
- Tuneful（GitHub README）：只提到 "New mini player and menu bar player options"，无尺寸细节。

## 7. macOS 26 Tahoe 的窗口拖边命中区

- Michael Tsai「The Struggle of Resizing Windows on Tahoe」（2026-01-12）转引 Norbert Heger："The window expects this click to happen in an area of 19 × 19 pixels, located near the window corner. But due to the huge corner radius in Tahoe, most of it – about 75% – now lies outside the window."
- Daring Fireball「Why It's Difficult to Resize Windows on MacOS 26」："If the window had no rounded corners at all, 62% of that area would lie inside the window. But due to the huge corner radius in Tahoe, most of it — about 75% — now lies outside the window."
- 搜索摘要另称 26.3 撤回了 RC 里的修复、发行说明改为 Known Issue（未逐字核对）。
- 结论：在 Tahoe 上，圆角越大、拖边越难发现；nanoPod 面板圆角 16、无标题栏、无任何可见把手，只靠拖边等于没有入口。

## 8. HIG 其他相关句

- Windows（macOS）："People can move a window by dragging the frame and can often resize the window by dragging its edges."；"Avoid putting critical information or actions in a bottom bar, because people often relocate a window in a way that hides its bottom edge."
- Layout："Design a layout that adapts gracefully and consistently."；"Keep functionality the same as size classes change, and keep layout changes recognizable and familiar to the platform."
- Windows（iPadOS）："The system remembers window size and placement even when an app is closed."

## 9. AppKit API（据文档名，未逐字抓到正文）

- `NSWindow.aspectRatio` / `contentAspectRatio`：用户缩放时把 frame 约束到比例的整数倍。
- `NSWindow.minSize` / `maxSize`。
- `NSWindow.setFrameAutosaveName(_:)`：把 frame 存进 UserDefaults 并在下次创建时还原。
- `NSWindowDelegate.windowWillResize(_:to:)`：用户缩放过程中每次都问一次，可以改回别的尺寸；`windowWillStartLiveResize` / `windowDidEndLiveResize`。
- `NSEvent.EventType.magnify` + `magnification`：触控板捏合。
- `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime:)`：Force Touch 触控板的对齐触觉。
- `NSApplication.didChangeScreenParametersNotification`；`CGDisplayCreateUUIDFromDisplayID`。
