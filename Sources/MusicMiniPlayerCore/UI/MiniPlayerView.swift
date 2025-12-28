import SwiftUI
import Translation

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
        // 🔑 删除onChange中的hover强制设置，让onHover自然控制状态
    }
}

// MARK: - MiniPlayerView Methods
extension MiniPlayerView {
    // MARK: - Album Overlay Content (文字遮罩 + 底部控件)
    @ViewBuilder
    func albumOverlayContent(geometry: GeometryProxy) -> some View {
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
                            height: 20,  // 🔑 明确高度，防止被裁剪
                            alignment: .leading
                        )
                        .matchedGeometryEffect(id: "track-title", in: animation)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)

                        ScrollingText(
                            text: musicController.currentArtist,
                            font: .system(size: 13, weight: .medium),
                            textColor: .white.opacity(0.9),
                            maxWidth: artSize - 24,
                            height: 16,  // 🔑 明确高度，防止被裁剪
                            alignment: .leading
                        )
                        .matchedGeometryEffect(id: "track-artist", in: animation)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                    }
                    .padding(.leading, 12)
                    .padding(.bottom, 12)  // 🔑 增加底部padding，防止文字被裁剪
                    .frame(width: artSize, height: maskHeight, alignment: .bottomLeading)
                    .position(x: geo.size.width / 2, y: maskY)
                    .opacity(showOverlayContent ? 0 : 1)
                    .allowsHitTesting(false)
                }

                // 🎨 hover状态：歌曲信息行 + SharedBottomControls
                if isHovering && showControls {
                    VStack(spacing: 0) {
                        Spacer()

                        // 🔑 歌曲信息行：标题/艺术家 (左) + Shuffle/Repeat (右)
                        HStack(alignment: .center) {  // 🔑 居中对齐
                            VStack(alignment: .leading, spacing: -2) {  // 🔑 spacing=-2 负间距更紧凑
                                ScrollingText(
                                    text: musicController.currentTrackTitle,
                                    font: .system(size: 12, weight: .bold),
                                    textColor: .white,
                                    maxWidth: geo.size.width * 0.50,
                                    height: 15,  // 🔑 紧凑高度
                                    alignment: .leading
                                )
                                .matchedGeometryEffect(id: "track-title", in: animation)

                                ScrollingText(
                                    text: musicController.currentArtist,
                                    font: .system(size: 10, weight: .medium),
                                    textColor: .white.opacity(0.7),
                                    maxWidth: geo.size.width * 0.50,
                                    height: 13,  // 🔑 紧凑高度
                                    alignment: .leading
                                )
                                .matchedGeometryEffect(id: "track-artist", in: animation)
                            }

                            Spacer()

                            HStack(spacing: 4) {
                                let themeColor = Color(red: 0.99, green: 0.24, blue: 0.27)
                                let themeBackground = themeColor.opacity(0.20)

                                Button(action: { musicController.toggleShuffle() }) {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(musicController.shuffleEnabled ? themeColor : .white.opacity(0.5))
                                        .frame(width: 24, height: 24)  // 🔑 24x24 匹配文字高度
                                        .background(Circle().fill(musicController.shuffleEnabled ? themeBackground : Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)

                                Button(action: { musicController.cycleRepeatMode() }) {
                                    Image(systemName: musicController.repeatMode == 1 ? "repeat.1" : "repeat")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(musicController.repeatMode > 0 ? themeColor : .white.opacity(0.5))
                                        .frame(width: 24, height: 24)  // 🔑 24x24 匹配文字高度
                                        .background(Circle().fill(musicController.repeatMode > 0 ? themeBackground : Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 32)  // 🔑 12 + 20 = 32，与进度条对齐
                        .padding(.bottom, 4)  // 🔑 距离进度条更近

                        // 🔑 使用 SharedBottomControls
                        SharedBottomControls(
                            currentPage: $musicController.currentPage,
                            isHovering: $isHovering,
                            showControls: $showControls,
                            isProgressBarHovering: $isProgressBarHovering,
                            dragPosition: $dragPosition
                        )
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
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
                    // 原图始终存在
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: artSize, height: artSize)
                        .clipped()

                    // 🔑 底部渐进模糊 - 用 opacity 控制显示/隐藏，实现平滑过渡
                    // 只在 album 页面非 hover 时显示
                    // 范围略高于文字区域，模糊从 8px 开始递减
                    Group {
                        // 第1层：模糊 8px，覆盖底部 ~15%
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: artSize + 24, height: artSize + 24)
                            .blur(radius: 8)
                            .frame(width: artSize, height: artSize)
                            .clipped()
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 0.82),
                                        .init(color: .black, location: 0.92),
                                        .init(color: .black, location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        // 第2层：模糊 5px，覆盖底部 ~20%
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: artSize + 16, height: artSize + 16)
                            .blur(radius: 5)
                            .frame(width: artSize, height: artSize)
                            .clipped()
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 0.77),
                                        .init(color: .black, location: 0.87),
                                        .init(color: .black, location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        // 第3层：模糊 2px，覆盖底部 ~25%
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: artSize + 8, height: artSize + 8)
                            .blur(radius: 2)
                            .frame(width: artSize, height: artSize)
                            .clipped()
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 0.72),
                                        .init(color: .black, location: 0.82),
                                        .init(color: .black, location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .opacity(musicController.currentPage == .album && !isHovering ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: isHovering)
                    .allowsHitTesting(false)
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

/// 翻译按钮 - 显示/隐藏歌词翻译（直接toggle，无二级菜单）
struct TranslationButtonView: View {
    @ObservedObject var lyricsService: LyricsService
    @State private var isHovering = false
    // 🔑 记录是否已经尝试过强制重试（防止无限重试）
    @State private var hasTriedForceRetry = false

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                // 🔑 智能翻译逻辑：
                // 1. 如果翻译开关关闭 → 打开翻译
                // 2. 如果翻译开关已开启但没有翻译结果，且未尝试过强制重试 → 强制重试翻译
                // 3. 其他情况 → 关闭翻译

                if !lyricsService.showTranslation {
                    // 情况1：打开翻译
                    lyricsService.showTranslation = true
                    hasTriedForceRetry = false  // 重置重试标记
                    lyricsService.debugLogPublic("🔘 翻译按钮：打开翻译")
                } else if !lyricsService.hasTranslation && !lyricsService.isTranslating && !hasTriedForceRetry {
                    // 情况2：翻译开关已开启但没有翻译结果，强制重试一次
                    lyricsService.debugLogPublic("🔘 翻译按钮：强制重试翻译（当前无翻译结果）")
                    hasTriedForceRetry = true  // 标记已尝试过
                    lyricsService.forceRetryTranslation()
                } else {
                    // 情况3：关闭翻译
                    lyricsService.showTranslation = false
                    hasTriedForceRetry = false  // 重置重试标记
                    lyricsService.debugLogPublic("🔘 翻译按钮：关闭翻译")
                }
            }
        }) {
            Image(systemName: "translate")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(lyricsService.showTranslation ? .white : (isHovering ? .white.opacity(0.95) : .white.opacity(0.8)))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(lyricsService.showTranslation ? 0.3 : (isHovering ? 0.2 : 0.12)))  // 🔑 切换状态 0.3，hover 0.2，常驻 0.12
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        // 🔑 歌曲切换时重置重试标记
        .onChange(of: lyricsService.lyrics.count) { _, _ in
            hasTriedForceRetry = false
        }
        .help("Toggle Translation")
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

