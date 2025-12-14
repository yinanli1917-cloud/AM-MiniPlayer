import SwiftUI
import Glur

// 移除自定义transition，使用SwiftUI官方transition避免icon消失bug
// PlayerPage enum 已移至 MusicController 以支持状态共享

public struct MiniPlayerView: View {
    @EnvironmentObject var musicController: MusicController
    // 🔑 使用 musicController.currentPage 替代本地状态，实现浮窗/菜单栏同步
    @State private var isHovering: Bool = false
    @State private var showControls: Bool = false
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var playlistSelectedTab: Int = 1  // 0 = History, 1 = Up Next
    @Namespace private var animation

    // 🔑 Clip 逻辑 - 从 PlaylistView 传递的滚动偏移量
    @State private var playlistScrollOffset: CGFloat = 0

    // 🔑 封面页hover后文字和遮罩延迟显示
    @State private var showOverlayContent: Bool = false

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

                // 🔑 窗口拖动层 - 允许从空白区域拖动窗口
                WindowDraggableView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 🔑 使用ZStack叠加所有页面，通过opacity和zIndex控制显示
                // matchedGeometryEffect: 使用单个浮动Image + invisible placeholders避免crossfade

                // Lyrics View - 使用 opacity 模式与其他页面一致，避免阻挡 WindowDraggableView
                LyricsView(currentPage: $musicController.currentPage, openWindow: openWindow, onHide: onHide, onExpand: onExpand)
                    .opacity(musicController.currentPage == .lyrics ? 1 : 0)
                    .zIndex(musicController.currentPage == .lyrics ? 1 : 0)
                    .allowsHitTesting(musicController.currentPage == .lyrics)

                // Playlist View - 始终存在以支持matchedGeometryEffect
                PlaylistView(currentPage: $musicController.currentPage, animationNamespace: animation, selectedTab: $playlistSelectedTab, showControls: $showControls, isHovering: $isHovering, scrollOffset: $playlistScrollOffset)
                    .opacity(musicController.currentPage == .playlist ? 1 : 0)
                    .zIndex(musicController.currentPage == .playlist ? 1 : 0)  // 🔑 降低到 zIndex 1（和封面同层）
                    .allowsHitTesting(musicController.currentPage == .playlist)

                // Album View - 始终存在以支持matchedGeometryEffect
                albumPageContent(geometry: geometry)
                    .opacity(musicController.currentPage == .album ? 1 : 0)
                    .zIndex(musicController.currentPage == .album ? 1 : 0)  // 🔑 降低到 zIndex 1（和封面同层）
                    .allowsHitTesting(musicController.currentPage == .album)

                // 🎯 浮动的Artwork - 单个Image实例，通过matchedGeometry移动
                if let artwork = musicController.currentArtwork {
                    floatingArtwork(artwork: artwork, geometry: geometry)
                        .zIndex(musicController.currentPage == .album ? 50 : 1)  // 🔑 歌单页 1（同层），专辑页 50（遮住文字）
                }

                // 🎨 Album页面的文字和遮罩 - 必须在浮动artwork之上
                if musicController.currentPage == .album, musicController.currentArtwork != nil {
                    albumOverlayContent(geometry: geometry)
                        .zIndex(101)  // 在浮动artwork之上
                }


            }
        }
        // 移除固定尺寸，让视图自动填充窗口以支持缩放
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            // Music按钮 - hover时显示，但歌单页面不显示
            if showControls && musicController.currentPage != .playlist {
                MusicButtonView()
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
                    ExpandButtonView(onExpand: onExpand!)
                        .padding(12)
                        .transition(.opacity)
                } else if onHide != nil {
                    // 浮窗模式：显示收起按钮
                    HideButtonView(onHide: onHide!)
                        .padding(12)
                        .transition(.opacity)
                } else {
                    // 无回调时的默认行为
                    HideButtonView(onHide: {
                        if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel }) {
                            window.orderOut(nil)
                        }
                    })
                    .padding(12)
                    .transition(.opacity)
                }
            }
        }
        .onHover { hovering in
            // 🔑 简单逻辑：鼠标在窗口内=hover（显示控件+缩小封面），鼠标离开=非hover（放大封面）
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                isHovering = hovering
            }
            if hovering {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        showControls = true
                    }
                }
                // 🔑 文字和渐变遮罩延迟0.1秒后渐现（等待matchedGeometry动画完成）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showOverlayContent = true
                    }
                }
            } else {
                // 🔑 离开时立即隐藏文字遮罩
                withAnimation(.easeOut(duration: 0.1)) {
                    showOverlayContent = false
                }
                withAnimation(.easeOut(duration: 0.18)) {
                    showControls = false
                }
            }
        }
        // 🔑 当从 playlist 切换到 album 页面时，如果鼠标在窗口内，恢复控件显示
        .onChange(of: musicController.currentPage) { newPage in
            if newPage == .album && isHovering {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    showControls = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showOverlayContent = true
                    }
                }
            }
        }
    }

    // MARK: - Album Overlay Content (文字遮罩 + 底部控件)
    @ViewBuilder
    private func albumOverlayContent(geometry: GeometryProxy) -> some View {
        GeometryReader { geo in
            let artSize = isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68
            // 控件区域高度（与SharedBottomControls一致）
            let controlsHeight: CGFloat = 80
            // 可用高度（给封面居中用）
            let availableHeight = geo.size.height - (showControls ? controlsHeight : 0)
            // 封面中心Y
            let artCenterY = availableHeight / 2
            // 遮罩高度
            let maskHeight: CGFloat = 60
            // 遮罩Y位置（封面底部）
            let maskY = artCenterY + (artSize / 2) - (maskHeight / 2)

            ZStack {
                // 🎨 非hover状态：文字在封面底部（已删除黑色渐变遮罩，依靠底部模糊效果）
                if !isHovering {
                    VStack(alignment: .leading, spacing: 2) {
                        ScrollingText(
                            text: musicController.currentTrackTitle,
                            font: .system(size: 16, weight: .bold),
                            textColor: .white,
                            maxWidth: artSize - 24,
                            alignment: .leading
                        )
                        .matchedGeometryEffect(id: "track-title", in: animation)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)

                        ScrollingText(
                            text: musicController.currentArtist,
                            font: .system(size: 13, weight: .medium),
                            textColor: .white.opacity(0.9),
                            maxWidth: artSize - 24,
                            alignment: .leading
                        )
                        .matchedGeometryEffect(id: "track-artist", in: animation)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                    }
                    .padding(.leading, 12)
                    .padding(.bottom, 10)
                    .frame(width: artSize, height: maskHeight, alignment: .bottomLeading)
                    .position(x: geo.size.width / 2, y: maskY)
                    .opacity(showOverlayContent ? 0 : 1)
                    .allowsHitTesting(false)
                }

                // 🎨 hover状态：歌曲信息行 + SharedBottomControls风格的控件
                if isHovering && showControls {
                    VStack(spacing: 0) {
                        Spacer()

                        // 🔑 歌曲信息行：标题/艺术家 (左) + Shuffle/Repeat (右)
                        // 🔑 使用.center对齐，文字和按钮在同一个frame里垂直居中
                        HStack(alignment: .center) {
                            // 🔑 缩小文字间距和字体，让整体更紧凑
                            VStack(alignment: .leading, spacing: 1) {
                                ScrollingText(
                                    text: musicController.currentTrackTitle,
                                    font: .system(size: 13, weight: .bold),  // 🔑 从14改为13
                                    textColor: .white,
                                    maxWidth: geo.size.width * 0.50,
                                    alignment: .leading
                                )
                                .matchedGeometryEffect(id: "track-title", in: animation)

                                ScrollingText(
                                    text: musicController.currentArtist,
                                    font: .system(size: 11, weight: .medium),  // 🔑 从10改回11
                                    textColor: .white.opacity(0.7),
                                    maxWidth: geo.size.width * 0.50,
                                    alignment: .leading
                                )
                                .matchedGeometryEffect(id: "track-artist", in: animation)
                            }
                            .frame(height: 26)  // 🔑 固定高度与按钮一致

                            Spacer()

                            HStack(spacing: 8) {
                                // 🔑 主题色（Apple Music红）
                                let themeColor = Color(red: 0.99, green: 0.24, blue: 0.27)
                                // 🔑 背景：主题色20%不透明度
                                let themeBackground = themeColor.opacity(0.20)

                                Button(action: { musicController.toggleShuffle() }) {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(musicController.shuffleEnabled ? themeColor : .white.opacity(0.5))
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(musicController.shuffleEnabled ? themeBackground : Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)

                                Button(action: { musicController.cycleRepeatMode() }) {
                                    Image(systemName: musicController.repeatMode == 1 ? "repeat.1" : "repeat")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(musicController.repeatMode > 0 ? themeColor : .white.opacity(0.5))
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(musicController.repeatMode > 0 ? themeBackground : Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 40)  // 🔑 与进度条左右端点对齐
                        .padding(.bottom, 8)  // 🔑 歌曲信息行下边padding改为8

                        // 🔑 与SharedBottomControls完全一致的控件布局
                        VStack(spacing: 4) {  // 🔑 进度条区域与播放按钮间距=4
                            // 进度条 + 时间标签（时间在进度条下方）
                            VStack(spacing: 2) {  // 🔑 进度条与时间间距=2
                                // 进度条 - 放在最上面
                                progressBarView(geo: geo)

                                // 时间标签 - 移到进度条下方，padding与进度条一致
                                HStack {
                                    Text(formatTime(musicController.currentTime))
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundColor(.white.opacity(0.6))

                                    Spacer()

                                    if let quality = musicController.audioQuality {
                                        qualityBadge(quality)
                                    }

                                    Spacer()

                                    Text("-" + formatTime(musicController.duration - musicController.currentTime))
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                                .padding(.horizontal, 20)  // 🔑 与进度条padding一致，对齐端点
                            }
                            .background(NonDraggableView())

                            // 播放控件
                            HStack(spacing: 12) {
                                NavigationIconButton(
                                    iconName: musicController.currentPage == .lyrics ? "quote.bubble.fill" : "quote.bubble",
                                    isActive: musicController.currentPage == .lyrics
                                ) {
                                    // 🔑 更快但不弹性的动画
                                    withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                                        musicController.currentPage = musicController.currentPage == .lyrics ? .album : .lyrics
                                    }
                                }
                                .frame(width: 28, height: 28)

                                Spacer()

                                HoverableControlButton(iconName: "backward.fill", size: 18) {
                                    musicController.previousTrack()
                                }
                                .frame(width: 32, height: 32)

                                HoverableControlButton(iconName: musicController.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                                    musicController.togglePlayPause()
                                }
                                .frame(width: 32, height: 32)

                                HoverableControlButton(iconName: "forward.fill", size: 18) {
                                    musicController.nextTrack()
                                }
                                .frame(width: 32, height: 32)

                                Spacer()

                                NavigationIconButton(
                                    iconName: musicController.currentPage == .playlist ? "play.square.stack.fill" : "play.square.stack",
                                    isActive: musicController.currentPage == .playlist
                                ) {
                                    // 🔑 更快但不弹性的动画
                                    withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                                        musicController.currentPage = musicController.currentPage == .playlist ? .album : .playlist
                                    }
                                }
                                .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)  // 🔑 与SharedBottomControls一致
                        .padding(.bottom, 20)  // 🔑 底部padding减小（32→20）
                    }
                    // 🔑 hover状态的控件使用showOverlayContent控制延迟显示
                    .opacity(showOverlayContent ? 1 : 0)
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isHovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: showControls)
            .animation(.easeInOut(duration: 0.2), value: showOverlayContent)
        }
    }

    // 进度条视图（与SharedBottomControls完全一致，padding固定为20）
    @ViewBuilder
    private func progressBarView(geo: GeometryProxy) -> some View {
        let barHeight: CGFloat = isProgressBarHovering ? 12 : 7  // 🔑 hover前7px，hover后12px

        GeometryReader { barGeo in
            let currentProgress: CGFloat = {
                if musicController.duration > 0 {
                    return dragPosition ?? CGFloat(musicController.currentTime / musicController.duration)
                }
                return 0
            }()

            // 🔑 使用遮罩实现圆角不拉伸效果
            ZStack {
                // Background Track - 从中心向上下扩展
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: barHeight)

                // Active Progress - 使用遮罩保持圆角不变形
                Capsule()
                    .fill(Color.white)
                    .frame(height: barHeight)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: barGeo.size.width * currentProgress)
                            Spacer(minLength: 0)
                        }
                    )
            }
            .frame(maxHeight: .infinity)  // 🔑 让ZStack在GeometryReader中垂直居中
            .contentShape(Capsule())
            .onHover { hovering in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isProgressBarHovering = hovering
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged({ value in
                        dragPosition = min(max(0, value.location.x / barGeo.size.width), 1)
                    })
                    .onEnded({ value in
                        let percentage = min(max(0, value.location.x / barGeo.size.width), 1)
                        musicController.seek(to: percentage * musicController.duration)
                        dragPosition = nil
                    })
            )
        }
        .frame(height: 14)  // 🔑 容器高度略大于最大bar高度，确保居中效果
        .padding(.horizontal, 20)  // 🔑 固定padding=20，与SharedBottomControls完全一致
    }

    // 音质标签
    private func qualityBadge(_ quality: String) -> some View {
        HStack(spacing: 2) {
            if quality == "Hi-Res Lossless" {
                Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 8))
            } else if quality == "Dolby Atmos" {
                Image(systemName: "spatial.audio.badge.checkmark").font(.system(size: 8))
            } else {
                Image(systemName: "waveform").font(.system(size: 8))
            }
            Text(quality).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .cornerRadius(4)
        .foregroundColor(.white.opacity(0.9))
    }

    // 时间格式化
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Floating Artwork (单个Image实例避免crossfade)
    @ViewBuilder
    private func floatingArtwork(artwork: NSImage, geometry: GeometryProxy) -> some View {
        // 🔑 单个Image实例，通过计算位置实现流畅动画
        GeometryReader { geo in
            // 控件区域高度（与albumOverlayContent一致）
            let controlsHeight: CGFloat = 80
            let availableHeight = geo.size.height - (showControls ? controlsHeight : 0)

            // 根据当前页面计算尺寸和位置
            let (artSize, cornerRadius, shadowRadius, xPosition, yPosition): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = {
                if musicController.currentPage == .album {
                    // Album页面：居中大图（在可用区域内居中）
                    // 🔑 与albumOverlayContent保持一致的尺寸
                    let size = isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68
                    return (
                        size,
                        12.0,
                        25.0,
                        geo.size.width / 2,
                        availableHeight / 2
                    )
                } else if musicController.currentPage == .playlist {
                    // 🔑 与 PlaylistView 中的 artSize 完全一致
                    let size = min(geo.size.width * 0.18, 60.0)

                    // 计算在 Now Playing 卡片内的位置：
                    // - Section header 高度: 36
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
                // 🎯 封面图片 + 底部渐进模糊
                ZStack {
                    // 原始封面
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: artSize, height: artSize)
                        .clipped()

                    // 🔑 底部渐进模糊overlay - 只在album页面非hover时显示
                    // 文字区域约占封面底部30%，模糊需要覆盖这个区域
                    if musicController.currentPage == .album && !isHovering {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: artSize, height: artSize)
                            .clipped()
                            .blur(radius: 50)  // 增大模糊值
                            .mask(
                                LinearGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 0.45),  // 顶部45%完全清晰
                                        .init(color: .black.opacity(0.3), location: 0.55),
                                        .init(color: .black.opacity(0.7), location: 0.65),
                                        .init(color: .black, location: 0.75),  // 底部25%完全模糊
                                        .init(color: .black, location: 1.0)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .allowsHitTesting(false)
                            .id(artwork)
                    }
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

    // MARK: - Album Page Content (抽取为函数支持matchedGeometryEffect)
    @ViewBuilder
    private func albumPageContent(geometry: GeometryProxy) -> some View {
        if musicController.currentArtwork != nil {
            GeometryReader { geo in
                // 控件区域高度（与albumOverlayContent一致）
                let controlsHeight: CGFloat = 80
                // 封面可用高度
                let availableHeight = geo.size.height - (showControls ? controlsHeight : 0)
                // 🔑 与albumOverlayContent和floatingArtwork保持一致的尺寸
                let artSize = isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68

                // Album Artwork Placeholder (用于matchedGeometryEffect)
                Color.clear
                    .frame(width: artSize, height: artSize)
                    .cornerRadius(12)
                    .matchedGeometryEffect(id: "album-placeholder", in: animation, isSource: true)
                    .onTapGesture {
                        // 🔑 快速但不弹性的动画
                        withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                            musicController.currentPage = musicController.currentPage == .album ? .lyrics : .album
                        }
                    }
                    .position(
                        x: geo.size.width / 2,
                        y: availableHeight / 2
                    )
            }
        } else {
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: geometry.size.width * 0.70, height: geometry.size.width * 0.70)
                    .overlay(Text("No Art").foregroundColor(.white))

                Text("Not Playing")
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


extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) // Simplified for macOS
        // Note: SwiftUI on macOS doesn't support partial corners easily with standard shapes without more complex paths.
        // For simplicity in this environment, we'll use a standard corner radius for now or a custom path if strictly needed.
        // But since UIRectCorner is iOS, we need a macOS equivalent.
        return Path(path.cgPath)
    }
}

// Helper for macOS corners since UIRectCorner is iOS only
struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

extension NSBezierPath {
    convenience init(roundedRect rect: CGRect, byRoundingCorners corners: RectCorner, cornerRadii: CGSize) {
        self.init()
        // Implementation of custom path for partial corners would go here.
        // For now, falling back to standard rounded rect to avoid compilation errors if complex path logic is missing.
        self.appendRoundedRect(rect, xRadius: cornerRadii.width, yRadius: cornerRadii.height)
    }
}

// MARK: - Hoverable Button Views

struct MusicButtonView: View {
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            let musicAppURL = URL(fileURLWithPath: "/System/Applications/Music.app")
            NSWorkspace.shared.openApplication(at: musicAppURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Music")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovering ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    Color.white.opacity(isHovering ? 0.15 : 0.08)
                    if isHovering {
                        Color.white.opacity(0.05)
                    }
                }
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .help("打开 Apple Music")
    }
}

struct HideButtonView: View {
    @State private var isHovering = false
    var onHide: () -> Void

    var body: some View {
        Button(action: {
            onHide()
        }) {
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isHovering ? .white : .white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        Color.white.opacity(isHovering ? 0.15 : 0.08)
                        if isHovering {
                            Color.white.opacity(0.05)
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .help("收起到菜单栏")
    }
}

/// 展开按钮 - 从菜单栏视图展开为浮窗
struct ExpandButtonView: View {
    @State private var isHovering = false
    var onExpand: () -> Void

    var body: some View {
        Button(action: {
            onExpand()
        }) {
            Image(systemName: "pip.exit")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovering ? .white : .white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        Color.white.opacity(isHovering ? 0.15 : 0.08)
                        if isHovering {
                            Color.white.opacity(0.05)
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .help("展开为浮窗")
    }
}

// MARK: - Playlist Tab Bar (集成版，带透明背景)

struct PlaylistTabBarIntegrated: View {
    @Binding var selectedTab: Int

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                // Background Capsule - 恢复原来的透明设计
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 32)

                // Selection Capsule
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: geo.size.width / 2 - 4, height: 28)
                        .offset(x: selectedTab == 0 ? 2 : geo.size.width / 2 + 2, y: 2)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedTab)
                }

                // Tab Labels
                HStack(spacing: 0) {
                    Button(action: { selectedTab = 0 }) {
                        Text("History")
                            .font(.system(size: 13, weight: selectedTab == 0 ? .semibold : .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(action: { selectedTab = 1 }) {
                        Text("Up Next")
                            .font(.system(size: 13, weight: selectedTab == 1 ? .semibold : .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 32)
        }
        .padding(.horizontal, 50)
    }
}



// MARK: - Conditional View Modifier

extension View {
    /// Applies a modifier conditionally
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

