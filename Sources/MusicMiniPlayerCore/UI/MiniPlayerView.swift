import SwiftUI
import Translation

// 移除自定义transition，使用SwiftUI官方transition避免icon消失bug
// PlayerPage enum 已移至 MusicController 以支持状态共享

public struct MiniPlayerView: View {
    @EnvironmentObject var musicController: MusicController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 🔑 使用 musicController.currentPage 替代本地状态，实现浮窗/菜单栏同步
    @State private var isHovering: Bool = false
    @State private var showControls: Bool = false
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var playlistSelectedTab: Int = 1  // 0 = History, 1 = Up Next
    @Namespace private var animation

    // 🔑 Clip 逻辑 - 从 PlaylistView 传递的滚动偏移量

    // 🔑 封面页hover后文字和遮罩延迟显示
    @State private var showOverlayContent: Bool = false

    // 🔑 封面页控件模糊渐入效果（除歌曲信息外）
    @State private var controlsBlurAmount: CGFloat = 10
    // 🔑 封面页控件从下往上移入（10% 距离）
    @State private var controlsOffsetY: CGFloat = 30  // 约 300px * 10% = 30

    // 🔑 全屏封面模式（从 UserDefaults 读取）
    @State private var fullscreenAlbumCover: Bool = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")

    // 🔑 封面亮度（用于动态调整按钮样式）
    @State private var artworkBrightness: CGFloat = 0.5

    // 🔑 Shuffle/Repeat 流动动画进度
    @State private var shuffleFlow: Double = 0
    @State private var repeatFlow: Double = 0

    // 🔑 页面切换后短暂锁定 hover 状态，防止 onHover(false) 覆盖
    @State private var hoverLocked: Bool = false

    var openWindow: OpenWindowAction?
    var onHide: (() -> Void)?
    var onExpand: (() -> Void)?

    public init(openWindow: OpenWindowAction? = nil, onHide: (() -> Void)? = nil, onExpand: (() -> Void)? = nil) {
        self.openWindow = openWindow
        self.onHide = onHide
        self.onExpand = onExpand
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background (Liquid Glass)
                LiquidBackgroundView(artwork: musicController.currentArtwork)
                    .overlay(
                        Color.black
                            .opacity(max(0, 1 - 0.35 / max(Double(musicController.controlAreaLuminance), 0.01)))
                            .allowsHitTesting(false)
                    )
                    .animation(.easeInOut(duration: 0.5), value: musicController.controlAreaLuminance)
                    .accessibilityHidden(true)

                // 🔑 窗口拖动层 - 允许从空白区域拖动窗口
                WindowDraggableView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)

                // 🔑 使用ZStack叠加所有页面，通过opacity和zIndex控制显示
                // matchedGeometryEffect: 使用单个浮动Image + invisible placeholders避免crossfade

                // Lyrics View - 使用 opacity 模式与其他页面一致，避免阻挡 WindowDraggableView
                LyricsView(currentPage: $musicController.currentPage, openWindow: openWindow, onHide: onHide, onExpand: onExpand)
                    .opacity(musicController.currentPage == .lyrics ? 1 : 0)
                    .zIndex(musicController.currentPage == .lyrics ? 1 : 0)
                    .allowsHitTesting(musicController.currentPage == .lyrics)
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.25, dampingFraction: 0.9), value: musicController.currentPage)

                // Playlist View - 始终存在以支持matchedGeometryEffect
                PlaylistView(currentPage: $musicController.currentPage, animationNamespace: animation, selectedTab: $playlistSelectedTab, showControls: $showControls, isHovering: $isHovering, showOverlayContent: $showOverlayContent)
                    .opacity(musicController.currentPage == .playlist ? 1 : 0)
                    .zIndex(musicController.currentPage == .playlist ? 1 : 0)  // 🔑 降低到 zIndex 1（和封面同层）
                    .allowsHitTesting(musicController.currentPage == .playlist)
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.25, dampingFraction: 0.9), value: musicController.currentPage)

                // Album View - 始终存在以支持matchedGeometryEffect
                albumPageContent(geometry: geometry)
                    .opacity(musicController.currentPage == .album ? 1 : 0)
                    .zIndex(musicController.currentPage == .album ? 1 : 0)  // 🔑 降低到 zIndex 1（和封面同层）
                    .allowsHitTesting(musicController.currentPage == .album)
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.25, dampingFraction: 0.9), value: musicController.currentPage)

                // 🎯 浮动的Artwork - 单个Image实例，通过matchedGeometry移动
                if let artwork = musicController.currentArtwork {
                    floatingArtwork(artwork: artwork, geometry: geometry)
                        .zIndex(musicController.currentPage == .album ? 50 : 1)  // 🔑 歌单页 1（同层），专辑页 50（遮住文字）
                        .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.25, dampingFraction: 0.9), value: musicController.currentPage)
                        .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)  // 🔑 监听 isHovering 变化
                        .accessibilityHidden(true)
                }

                // 🎨 Album页面的文字和遮罩 - 必须在浮动artwork之上
                // 🔑 始终存在，使用 opacity 控制显示，确保丝滑过渡
                albumOverlayContent(geometry: geometry)
                    .zIndex(101)  // 在浮动artwork之上
                    .opacity(musicController.currentPage == .album ? 1 : 0)
                    .allowsHitTesting(musicController.currentPage == .album)
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.25, dampingFraction: 0.9), value: musicController.currentPage)
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)  // 🔑 监听 isHovering 变化


            }
        }
        // 移除固定尺寸，让视图自动填充窗口以支持缩放
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .topLeading) {
            // Music按钮 - hover时显示，但歌单页面不显示
            if showControls && musicController.currentPage != .playlist {
                MusicButtonView(artworkBrightness: artworkBrightness, isAlbumPage: musicController.currentPage == .album)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Hide/Expand 按钮 - hover时显示，但歌单页面不显示
            if showControls && musicController.currentPage != .playlist {
                // 根据模式显示不同按钮
                if onExpand != nil {
                    // 菜单栏模式：显示展开按钮
                    ExpandButtonView(onExpand: onExpand!, artworkBrightness: artworkBrightness, isAlbumPage: musicController.currentPage == .album)
                        .padding(12)
                        .transition(.opacity)
                } else if onHide != nil {
                    // 浮窗模式：显示收起按钮
                    HideButtonView(onHide: onHide!, artworkBrightness: artworkBrightness, isAlbumPage: musicController.currentPage == .album)
                        .padding(12)
                        .transition(.opacity)
                } else {
                    // 无回调时的默认行为
                    HideButtonView(onHide: {
                        if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel }) {
                            window.orderOut(nil)
                        }
                    }, artworkBrightness: artworkBrightness, isAlbumPage: musicController.currentPage == .album)
                    .padding(12)
                    .transition(.opacity)
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard !isHovering else { return }
                let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
                let hoverAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.82)
                let controlsAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)
                withAnimation(hoverAnim) { isHovering = true }
                controlsBlurAmount = 10
                controlsOffsetY = 30
                withAnimation(controlsAnim) {
                    showControls = true
                    showOverlayContent = true
                    controlsBlurAmount = 0
                    controlsOffsetY = 0
                }
            case .ended:
                if hoverLocked { return }
                let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
                let controlsAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)
                let hoverAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.82)
                withAnimation(hoverAnim) { isHovering = false }
                withAnimation(controlsAnim) {
                    showOverlayContent = false
                    controlsBlurAmount = 10
                    controlsOffsetY = 30
                    showControls = false
                }
            }
        }
        // 🔑 监听全屏封面设置变化
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let newValue = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")
            if newValue != fullscreenAlbumCover {
                withAnimation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.82)) {
                    fullscreenAlbumCover = newValue
                }
            }
        }
        // 🔑 监听封面变化，计算整图 + 底部区域亮度
        .onChange(of: musicController.currentArtwork) { _, newArtwork in
            if let artwork = newArtwork {
                artworkBrightness = artwork.perceivedBrightness()
                musicController.artworkLuminance = artworkBrightness
                musicController.controlAreaLuminance = artwork.bottomBrightness(fraction: 0.3)
            }
        }
        .onAppear {
            if let artwork = musicController.currentArtwork {
                artworkBrightness = artwork.perceivedBrightness()
                musicController.artworkLuminance = artworkBrightness
                musicController.controlAreaLuminance = artwork.bottomBrightness(fraction: 0.3)
            }
        }
        // 🔑 监听页面切换：从其他页面切回专辑页时，同步所有 hover 相关状态
        .onChange(of: musicController.currentPage) { oldPage, newPage in
            // 从歌单/歌词页切换到专辑页时，强制同步 hover 状态
            if newPage == .album && oldPage != .album {
                let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4

                // 🔑 锁定 hover 状态，防止 onHover(false) 覆盖
                hoverLocked = true

                // 🔑 用 withAnimation 包裹所有状态变化，确保动画系统正确处理
                controlsBlurAmount = 10
                controlsOffsetY = 30
                withAnimation(reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)) {
                    isHovering = true
                    showControls = true
                    showOverlayContent = true
                    controlsBlurAmount = 0
                    controlsOffsetY = 0
                }

                // 🔑 延迟解除锁定（动画完成后）
                DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                    hoverLocked = false
                }
            }
        }
    }
}

// MARK: - MiniPlayerView Methods
extension MiniPlayerView {
    // MARK: - Album Overlay Content (文字遮罩 + 底部控件)
    @ViewBuilder
    func albumOverlayContent(geometry: GeometryProxy) -> some View {
        GeometryReader { geo in
            // 🔑 全屏模式：封面尺寸始终为窗口宽度；普通模式：根据hover状态变化
            let artSize = fullscreenAlbumCover ? geo.size.width : (isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68)
            // 控件区域高度（与SharedBottomControls一致）
            let controlsHeight: CGFloat = 80
            // 🔑 非全屏模式：非hover时封面在整个窗口居中，hover时在可用区域居中
            let availableHeight = isHovering ? (geo.size.height - controlsHeight) : geo.size.height
            let artCenterY = availableHeight / 2
            let artBottomY = artCenterY + artSize / 2
            // 🔑 非全屏模式：封面左边缘 X 位置
            let artLeftX = (geo.size.width - artSize) / 2

            ZStack {
                // ═══════════════════════════════════════════
                // 🎨 歌曲信息：使用 matchedGeometryEffect 实现丝滑过渡
                // ═══════════════════════════════════════════

                // 🔑 标题 - matchedGeometryEffect
                Text(musicController.currentTrackTitle)
                    .font(.system(size: isHovering ? 12 : 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3 + 0.5 * artworkBrightness), radius: 4 + 12 * artworkBrightness, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.15 + 0.25 * artworkBrightness), radius: 2 + 4 * artworkBrightness, x: 0, y: 0)
                    .matchedGeometryEffect(id: "trackTitle", in: animation)
                    .frame(width: isHovering ? geo.size.width - 112 : artSize - 24, alignment: .leading)
                    .position(
                        x: isHovering
                            ? 32 + (geo.size.width - 112) / 2  // hover: 左边距32，右边距80
                            : (fullscreenAlbumCover
                                ? 12 + (geo.size.width - 24) / 2  // 全屏: 左边距12
                                : artLeftX + 12 + (artSize - 24) / 2),  // 普通: 封面内左边距12
                        y: isHovering
                            ? geo.size.height - controlsHeight - 4 - 16  // hover: 控件上方
                            : (fullscreenAlbumCover
                                ? geo.size.height - 12 - 18 - 8  // 全屏非hover: 底边距12 + 艺术家行高18 + 间距8
                                : artBottomY - 38)   // 普通: 封面底部内，标题位置（距底边38）
                    )
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)

                // 🔑 艺术家 - matchedGeometryEffect
                Text(musicController.currentArtist)
                    .font(.system(size: isHovering ? 10 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovering ? 0.7 : 0.9))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3 + 0.5 * artworkBrightness), radius: 4 + 12 * artworkBrightness, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.15 + 0.25 * artworkBrightness), radius: 2 + 4 * artworkBrightness, x: 0, y: 0)
                    .matchedGeometryEffect(id: "artistName", in: animation)
                    .frame(width: isHovering ? geo.size.width - 112 : artSize - 24, alignment: .leading)
                    .position(
                        x: isHovering
                            ? 32 + (geo.size.width - 112) / 2  // hover: 左边距32，右边距80
                            : (fullscreenAlbumCover
                                ? 12 + (geo.size.width - 24) / 2  // 全屏: 左边距12
                                : artLeftX + 12 + (artSize - 24) / 2),  // 普通: 封面内左边距12
                        y: isHovering
                            ? geo.size.height - controlsHeight - 4 - 4   // hover: 标题下方
                            : (fullscreenAlbumCover
                                ? geo.size.height - 12 - 8  // 全屏非hover: 底边距12 + 半行高8（艺术家在最下方）
                                : artBottomY - 18)   // 普通: 封面底部内，艺术家位置（距底边18）
                    )
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)
                    .allowsHitTesting(false)

                // ═══════════════════════════════════════════
                // 🎨 hover 状态：Shuffle/Repeat + 控件（blur+move-in 动画）
                // ═══════════════════════════════════════════
                VStack(spacing: 0) {
                    Spacer()

                    // 🔑 Shuffle/Repeat 按钮行
                    HStack {
                        Spacer()

                        shuffleRepeatCluster
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 4)
                    .blur(radius: controlsBlurAmount)
                    .offset(y: controlsOffsetY)

                    // 🔑 SharedBottomControls
                    SharedBottomControls(
                        timePublisher: musicController.timePublisher,
                        currentPage: $musicController.currentPage,
                        isHovering: $isHovering,
                        showControls: $showControls,
                        isProgressBarHovering: $isProgressBarHovering,
                        dragPosition: $dragPosition
                    )
                    .blur(radius: controlsBlurAmount)
                    .offset(y: controlsOffsetY)
                }
                .opacity(showOverlayContent ? 1 : 0)
                .allowsHitTesting(showOverlayContent)
            }
            // 🔑 动画时长：全屏模式 0.5s，非全屏模式 0.4s
            .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)
            .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: showOverlayContent)
        }
    }

    // MARK: - Shuffle/Repeat Cluster (GlassEffectContainer on macOS 26+)
    @ViewBuilder
    private var shuffleRepeatCluster: some View {
        let themeColor = Color(red: 0.99, green: 0.24, blue: 0.27)
        let isLightBg = artworkBrightness > 0.6
        let normalFillOpacity = isLightBg ? 0.5 : 0.20
        let shadowOp = isLightBg ? 0.6 : 0.3
        let shadowRad: CGFloat = isLightBg ? 15 : 8

        let buttons = HStack(spacing: 4) {
            Button(action: { musicController.toggleShuffle() }) {
                Image(systemName: "shuffle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(musicController.shuffleEnabled ? themeColor : .white)
                    .rotationEffect(.degrees(shuffleFlow * 12))
                    .scaleEffect(1 - shuffleFlow * 0.12)
                    .frame(width: 24, height: 24)
                    .modifier(GlassCircle(
                        isEnabled: true,
                        fallbackFill: musicController.shuffleEnabled ? themeColor : .white,
                        fallbackOpacity: musicController.shuffleEnabled ? 0.25 : normalFillOpacity,
                        fallbackShadowOpacity: shadowOp,
                        fallbackShadowRadius: shadowRad
                    ))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("随机播放")
            .accessibilityAddTraits(musicController.shuffleEnabled ? .isSelected : [])
            .onChange(of: musicController.shuffleEnabled) { _, _ in
                guard !reduceMotion else { return }
                // Rotation wiggle: fast press, slow spring-back with overshoot
                withAnimation(.spring(response: 0.12, dampingFraction: 0.9)) { shuffleFlow = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 8)) { shuffleFlow = 0 }
                }
            }

            Button(action: { musicController.cycleRepeatMode() }) {
                Image(systemName: musicController.repeatMode == 1 ? "repeat.1" : "repeat")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(musicController.repeatMode > 0 ? themeColor : .white)
                    .rotationEffect(.degrees(repeatFlow * 10))
                    .scaleEffect(1 - repeatFlow * 0.1)
                    .frame(width: 24, height: 24)
                    .modifier(GlassCircle(
                        isEnabled: true,
                        fallbackFill: musicController.repeatMode > 0 ? themeColor : .white,
                        fallbackOpacity: musicController.repeatMode > 0 ? 0.25 : normalFillOpacity,
                        fallbackShadowOpacity: shadowOp,
                        fallbackShadowRadius: shadowRad
                    ))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(musicController.repeatMode == 0 ? "关闭循环" : musicController.repeatMode == 1 ? "单曲循环" : "列表循环")
            .onChange(of: musicController.repeatMode) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.12, dampingFraction: 0.9)) { repeatFlow = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { repeatFlow = 0 }
                }
            }
        }

        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                buttons
            }
        } else {
            buttons
        }
    }

    // MARK: - Floating Artwork (单个Image实例避免crossfade)
    @ViewBuilder
    private func floatingArtwork(artwork: NSImage, geometry: GeometryProxy) -> some View {
        // 🔑 单个Image实例，通过计算位置实现流畅动画
        GeometryReader { geo in
            // 控件区域高度（与albumOverlayContent一致）
            let controlsHeight: CGFloat = 80
            let availableHeight = geo.size.height - (showControls ? controlsHeight : 0)
            // 🔑 底部延伸区域高度（全屏模式用）
            let remainingHeight = geo.size.height - geo.size.width

            // 根据当前页面计算尺寸和位置
            let (artSize, cornerRadius, shadowRadius, xPosition, yPosition): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = {
                if musicController.currentPage == .album {
                    if fullscreenAlbumCover {
                        // 🔑 全屏封面模式：封面占满窗口宽度，hover时尺寸不变
                        let size = geo.size.width
                        return (
                            size,
                            0.0,    // 无圆角
                            0.0,    // 无阴影
                            geo.size.width / 2,
                            size / 2  // 顶部对齐
                        )
                    } else {
                        // 普通模式：居中大图（在可用区域内居中）
                        // 🔑 与albumOverlayContent保持一致的尺寸
                        let size = isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68
                        return (
                            size,
                            12.0,
                            25.0,
                            geo.size.width / 2,
                            availableHeight / 2
                        )
                    }
                } else if musicController.currentPage == .playlist {
                    // 🔑 与 PlaylistView 中的 artSize 完全一致
                    let size = min(geo.size.width * 0.18, 60.0)

                    // 🔑 计算在 Now Playing 卡片内的位置：
                    // - "Now Playing" header 高度: 36 (非 sticky，但仍占空间)
                    // - 卡片上 padding(.top, 8): 8
                    // - 卡片内 padding(12): 12
                    let headerHeight: CGFloat = 36
                    let cardTopPadding: CGFloat = 8
                    let cardInnerPadding: CGFloat = 12
                    let topOffset = headerHeight + cardTopPadding + cardInnerPadding + size/2

                    // X 位置：外 padding 12 + 卡片内 padding 12 + size/2
                    let xOffset = 12 + 12 + size/2

                    return (
                        size,
                        6.0,
                        3.0,
                        xOffset,
                        topOffset
                    )
                } else {
                    // Lyrics页面：不显示
                    return (0, 0, 0, 0, 0)
                }
            }()

            if musicController.currentPage != .lyrics {
                // 🔑 全屏模式：整图模糊背景 + 清晰封面覆盖
                if fullscreenAlbumCover {
                    let coverSize = geo.size.width
                    // 羽化区域高度
                    let blendHeight: CGFloat = 100

                    // 🔑 根据当前页面决定封面尺寸和位置
                    let isAlbumPage = musicController.currentPage == .album
                    let displaySize = isAlbumPage ? coverSize : artSize
                    let displayCornerRadius: CGFloat = isAlbumPage ? 0 : cornerRadius
                    let displayX = isAlbumPage ? geo.size.width / 2 : xPosition
                    let displayY = isAlbumPage ? coverSize / 2 : yPosition

                    // 🔑 羽化遮罩高度用动画值过渡，避免接缝
                    let animatedBlendHeight: CGFloat = isAlbumPage ? blendHeight : 0

                    // ===== Layer 1: 整图模糊背景 - 用 opacity 淡入淡出 =====
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 50, opaque: true)
                        .saturation(1.2)
                        .brightness(-0.1)
                        .opacity(isAlbumPage ? 1 : 0)  // 🔑 opacity 动画过渡
                        .accessibilityHidden(true)

                    // ===== Layer 2: 正方形封面（Hero）- 参与 matchedGeometryEffect =====
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: displaySize, height: displaySize)
                        .clipped()
                        // 🔑 底部羽化遮罩 - 高度用动画值过渡
                        .mask(
                            VStack(spacing: 0) {
                                Rectangle().fill(Color.black)
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .clear, location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: animatedBlendHeight)  // 🔑 动画过渡高度
                            }
                        )
                        .cornerRadius(displayCornerRadius)
                        .shadow(
                            color: .black.opacity(isAlbumPage ? 0 : 0.5),
                            radius: isAlbumPage ? 0 : shadowRadius,
                            x: 0,
                            y: isAlbumPage ? 0 : 2
                        )
                        .matchedGeometryEffect(
                            id: isAlbumPage ? "album-placeholder" : "playlist-placeholder",
                            in: animation,
                            isSource: false
                        )
                        .position(x: displayX, y: displayY)
                        .allowsHitTesting(false)
                        .accessibilityLabel("专辑封面")
                } else {
                    // 🎯 普通模式：封面图片 + 底部渐进模糊
                    ZStack {
                        // 原图始终存在
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: artSize, height: artSize)
                            .clipped()
                            .accessibilityLabel("专辑封面")

                        // 🔑 底部渐进模糊（15-25%）— 3 层递进
                        Group {
                            progressiveBlurLayer(artwork: artwork, size: artSize, expand: 24, blurRadius: 8, fadeStart: 0.82, fadeEnd: 0.92)
                            progressiveBlurLayer(artwork: artwork, size: artSize, expand: 16, blurRadius: 5, fadeStart: 0.77, fadeEnd: 0.87)
                            progressiveBlurLayer(artwork: artwork, size: artSize, expand: 8, blurRadius: 2, fadeStart: 0.72, fadeEnd: 0.82)
                        }
                        .opacity(musicController.currentPage == .album && !isHovering ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25), value: isHovering)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .cornerRadius(cornerRadius)
                    .shadow(
                        color: .black.opacity(0.5),
                        radius: shadowRadius,
                        x: 0,
                        y: musicController.currentPage == .album ? 12 : 2
                    )
                    .matchedGeometryEffect(
                        id: musicController.currentPage == .album ? "album-placeholder" : "playlist-placeholder",
                        in: animation,
                        isSource: false
                    )
                    .position(x: xPosition, y: yPosition)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - 渐进模糊层（消除 3 层重复代码）
    @ViewBuilder
    private func progressiveBlurLayer(artwork: NSImage, size: CGFloat, expand: CGFloat, blurRadius: CGFloat, fadeStart: Double, fadeEnd: Double) -> some View {
        Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: size + expand, height: size + expand)
            .blur(radius: blurRadius)
            .frame(width: size, height: size)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: fadeStart),
                        .init(color: .black, location: fadeEnd),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    // MARK: - Album Page Content (抽取为函数支持matchedGeometryEffect)
    @ViewBuilder
    private func albumPageContent(geometry: GeometryProxy) -> some View {
        if musicController.currentArtwork != nil {
            GeometryReader { geo in
                // 控件区域高度（与albumOverlayContent一致）
                let controlsHeight: CGFloat = 80
                // 封面可用高度
                let availableHeight = geo.size.height - (showControls ? controlsHeight : 0)
                // 🔑 全屏模式：封面尺寸始终为窗口宽度；普通模式：根据hover状态变化
                let artSize = fullscreenAlbumCover ? geo.size.width : (isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68)
                // 🔑 全屏模式：顶部对齐；普通模式：垂直居中
                let artCenterY = fullscreenAlbumCover ? artSize / 2 : availableHeight / 2

                // Album Artwork Placeholder (用于matchedGeometryEffect)
                Color.clear
                    .frame(width: artSize, height: artSize)
                    .cornerRadius(fullscreenAlbumCover ? 0 : 12)
                    .matchedGeometryEffect(id: "album-placeholder", in: animation, isSource: true)
                    .onTapGesture {
                        // 🔑 快速但不弹性的动画
                        withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                            if musicController.currentPage == .album {
                                // 🔑 用户手动打开歌词页面
                                musicController.userManuallyOpenedLyrics = true
                                musicController.currentPage = .lyrics
                            } else {
                                musicController.currentPage = .album
                            }
                        }
                    }
                    .position(
                        x: geo.size.width / 2,
                        y: artCenterY
                    )
            }
        } else {
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: geometry.size.width * 0.70, height: geometry.size.width * 0.70)
                    .overlay(Text("No Art").foregroundColor(.white))

                Text(kNotPlayingSentinel)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.top, 10)
                Spacer()
            }
        }
    }
}

#if DEBUG
struct MiniPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            // Simulate Desktop Wallpaper (Purple)
            if let wallpaperURL = Bundle.module.url(forResource: "wallpaper", withExtension: "jpg"),
               let wallpaper = NSImage(contentsOf: wallpaperURL) {
                Image(nsImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            } else {
                Color.purple
                    .ignoresSafeArea()
            }

            // The Player Window
            MiniPlayerView()
                .environmentObject({
                    let controller = MusicController(preview: true)
                    controller.currentTrackTitle = "Cariño"
                    controller.currentArtist = "The Marías"
                    if let artURL = Bundle.module.url(forResource: "album_cover", withExtension: "jpg"),
                       let art = NSImage(contentsOf: artURL) {
                        controller.currentArtwork = art
                    }
                    return controller
                }())
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 20)
        }
    }
}
#endif

