import SwiftUI
import AppKit
import os.log

public struct PlaylistView: View {
    @EnvironmentObject var musicController: MusicController
    @Binding var selectedTab: Int
    @Binding var showControls: Bool
    @Binding var isHovering: Bool
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var isManualScrolling: Bool = false
    @State private var autoScrollTimer: Timer? = nil
    @Binding var currentPage: PlayerPage
    var animationNamespace: Namespace.ID
    @State private var isCoverAnimating: Bool = false
    @State private var lastVelocity: CGFloat = 0
    @State private var scrollLocked: Bool = false
    @State private var hasTriggeredSlowScroll: Bool = false

    // 🔑 控件模糊渐入效果（初始值为 0，在页面切换时触发动画）
    @State private var controlsBlurAmount: CGFloat = 0
    @State private var controlsOffsetY: CGFloat = 0

    @Binding var scrollOffset: CGFloat

    // 🔑 全屏封面模式（从 UserDefaults 读取）
    @State private var fullscreenAlbumCover: Bool = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")

    // 🔑 统一的 artSize 常量（与 MiniPlayerView 同步）
    private let artSizeRatio: CGFloat = 0.18
    private let artSizeMax: CGFloat = 60.0

    // 🔑 布局常量
    private let headerHeight: CGFloat = 36

    public init(currentPage: Binding<PlayerPage>, animationNamespace: Namespace.ID, selectedTab: Binding<Int>, showControls: Binding<Bool>, isHovering: Binding<Bool>, scrollOffset: Binding<CGFloat>) {
        self._currentPage = currentPage
        self.animationNamespace = animationNamespace
        self._selectedTab = selectedTab
        self._showControls = showControls
        self._isHovering = isHovering
        self._scrollOffset = scrollOffset
    }

    public var body: some View {
        GeometryReader { geometry in
            let artSize = min(geometry.size.width * artSizeRatio, artSizeMax)

            ZStack {
                // Background - 全屏模式用流体渐变，普通模式用 Liquid Glass
                if fullscreenAlbumCover {
                    AdaptiveFluidBackground(artwork: musicController.currentArtwork)
                        .ignoresSafeArea()
                } else {
                    LiquidBackgroundView(artwork: musicController.currentArtwork)
                        .ignoresSafeArea()
                }

                // 主内容 ScrollView
                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            // ═══════════════════════════════════════════
                            // MARK: - History Section（上滑才能看到）
                            // ═══════════════════════════════════════════
                            Section(header: stickyHeader("History")) {
                                if musicController.recentTracks.isEmpty {
                                    Text("No recent tracks")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 20)
                                } else {
                                    // 🔑 反转顺序：最近的在底部（靠近 Now Playing）
                                    ForEach(0..<musicController.recentTracks.count, id: \.self) { index in
                                        PlaylistItemRowCompact(
                                            index: index,
                                            isUpNext: false,
                                            artSize: min(geometry.size.width * 0.12, 40.0),
                                            currentPage: $currentPage,
                                            fadeHeaderHeight: headerHeight
                                        )
                                    }
                                }
                            }
                            // 🔑 基于内容的 ID，强制在数据变化时重建整个 Section
                            .id("history-\(musicController.recentTracks.map { "\($0.title)-\($0.artist)" }.joined(separator: "|"))")

                            // ═══════════════════════════════════════════
                            // MARK: - Now Playing Section（默认位置，无 sticky header）
                            // ═══════════════════════════════════════════
                            VStack(spacing: 0) {
                                // Simple header (non-sticky)
                                Text("Now Playing")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(height: 36)

                                nowPlayingCard(geometry: geometry, artSize: artSize)
                            }
                            .id("nowPlayingSection")

                            // ═══════════════════════════════════════════
                            // MARK: - Up Next Section
                            // ═══════════════════════════════════════════
                            Section(header: stickyHeader("Up Next")) {
                                if musicController.upNextTracks.isEmpty {
                                    Text("Queue is empty")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 20)
                                } else {
                                    ForEach(0..<musicController.upNextTracks.count, id: \.self) { index in
                                        PlaylistItemRowCompact(
                                            index: index,
                                            isUpNext: true,
                                            artSize: min(geometry.size.width * 0.12, 40.0),
                                            currentPage: $currentPage,
                                            fadeHeaderHeight: headerHeight
                                        )
                                    }
                                }
                            }
                            // 🔑 基于内容的 ID，强制在数据变化时重建整个 Section
                            .id("upnext-\(musicController.upNextTracks.map { "\($0.title)-\($0.artist)" }.joined(separator: "|"))")

                            // 底部留白
                            Spacer().frame(height: 120)  // 🔑 增加留白，给控件腾出空间
                        }
                        .scrollTargetLayout()  // 🔑 恢复 snap 支持
                    }
                    .coordinateSpace(name: "playlistScroll")  // 🔑 Gemini 方案需要
                    .scrollTargetBehavior(.viewAligned)  // 🔑 恢复 snap 行为
                    .defaultScrollAnchor(.top)  // 🔑 默认锚点
                    .onAppear {
                        // 🔑 立即滚动到 Now Playing（无延迟，避免跳闪）
                        scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                    }
                    .onChange(of: currentPage) { _, newPage in
                        // 🔑 切换到歌单页时立即滚动到 Now Playing
                        if newPage == .playlist {
                            scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                            // 🔑 触发 blur + move-in 动画
                            controlsBlurAmount = 10
                            controlsOffsetY = 30
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                controlsBlurAmount = 0
                                controlsOffsetY = 0
                            }
                        }
                    }
                    .onChange(of: musicController.currentTrackTitle) { _, _ in
                        // 歌曲切换时也滚动到 Now Playing
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                            }
                        }
                    }
                }
                .scrollDetectionWithVelocity(
                    onScrollStarted: {
                        isManualScrolling = true
                        lastVelocity = 0
                        scrollLocked = false
                        hasTriggeredSlowScroll = false
                        autoScrollTimer?.invalidate()
                    },
                    onScrollEnded: {
                        autoScrollTimer?.invalidate()
                        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                            if !isHovering {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    showControls = false
                                    controlsBlurAmount = 10
                                    controlsOffsetY = 30
                                }
                            } else {
                                // 🔑 鼠标在窗口内，显示控件（带 blur+offset 动画）
                                controlsBlurAmount = 10
                                controlsOffsetY = 30
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    showControls = true
                                    controlsBlurAmount = 0
                                    controlsOffsetY = 0
                                }
                            }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isManualScrolling = false
                                lastVelocity = 0
                                scrollLocked = false
                                hasTriggeredSlowScroll = false
                            }
                        }
                    },
                    onScrollWithVelocity: { deltaY, velocity in
                        let absVelocity = abs(velocity)
                        let threshold: CGFloat = 800

                        if deltaY < 0 {
                            // 往上滚：隐藏控件
                            if showControls {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    showControls = false
                                    controlsBlurAmount = 10
                                    controlsOffsetY = 30
                                }
                            }
                            scrollLocked = true
                        } else if absVelocity >= threshold {
                            // 快速滚动：隐藏控件
                            if !scrollLocked {
                                scrollLocked = true
                            }
                            if showControls {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    showControls = false
                                    controlsBlurAmount = 10
                                    controlsOffsetY = 30
                                }
                            }
                        } else if deltaY > 0 && !scrollLocked && !hasTriggeredSlowScroll {
                            // 慢速往下滚：显示控件
                            hasTriggeredSlowScroll = true
                            if !showControls {
                                controlsBlurAmount = 10
                                controlsOffsetY = 30
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    showControls = true
                                    controlsBlurAmount = 0
                                    controlsOffsetY = 0
                                }
                            }
                        }

                        lastVelocity = absVelocity
                    },
                    onScrollOffsetChanged: { offset in
                        scrollOffset = offset
                    },
                    isEnabled: currentPage == .playlist
                )

                // 底部控件 overlay
                VStack {
                    Spacer()

                    ZStack(alignment: .bottom) {
                        // 🔑 统一使用 VisualEffectView（不允许用透明黑色渐变，会穿透）
                        VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                            .frame(height: 100)
                            .mask(
                                LinearGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .black.opacity(0.5), location: 0.15),
                                        .init(color: .black, location: 0.35),
                                        .init(color: .black, location: 1.0)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .allowsHitTesting(false)

                        SharedBottomControls(
                            currentPage: $currentPage,
                            isHovering: $isHovering,
                            showControls: $showControls,
                            isProgressBarHovering: $isProgressBarHovering,
                            dragPosition: $dragPosition
                        )
                        .padding(.bottom, 0)
                    }
                    // 🔑 blur + move-in 动画
                    .blur(radius: controlsBlurAmount)
                    .offset(y: controlsOffsetY)
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                }
                .opacity(showControls ? 1 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showControls)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controlsBlurAmount)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controlsOffsetY)
            }
            .onAppear {
                musicController.fetchUpNextQueue()
            }
            // 🔑 hover 控件显示/隐藏动画（与歌词页面同步）
            .onHover { hovering in
                isHovering = hovering
                // 🔑 鼠标离开窗口时总是隐藏控件（无论是否在滚动）
                if !hovering {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        showControls = false
                        controlsBlurAmount = 10
                        controlsOffsetY = 30
                    }
                }
                // 🔑 只在非滚动状态时，鼠标进入显示控件
                else if !isManualScrolling {
                    // 🔑 进入时重置模糊和位移状态
                    controlsBlurAmount = 10
                    controlsOffsetY = 30
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        showControls = true
                        controlsBlurAmount = 0
                        controlsOffsetY = 0
                    }
                }
                // 滚动时鼠标进入不自动显示控件（由scroll逻辑控制）
            }
            // 🔑 监听全屏封面设置变化
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                let newValue = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")
                if newValue != fullscreenAlbumCover {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        fullscreenAlbumCover = newValue
                    }
                }
            }
        }
    }

    // MARK: - Sticky Header（Gemini 方案：纯文字透明背景，歌单行自己模糊）
    @ViewBuilder
    private func stickyHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: headerHeight)
        // 🔑 Header 完全透明，背景完美透传
        // 歌单行滚动到这下面时会自己模糊，不需要 header 加材质
    }

    // MARK: - Now Playing Card
    @ViewBuilder
    private func nowPlayingCard(geometry: GeometryProxy, artSize: CGFloat) -> some View {
        if musicController.currentTrackTitle != "Not Playing" {
            VStack(spacing: 0) {
                // Now Playing 卡片
                Button(action: {
                    withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                        isCoverAnimating = true
                        currentPage = .album
                        // 🔑 确保回到专辑页时控件可见
                        isHovering = true
                        showControls = true
                    }
                }) {
                    HStack(alignment: .center, spacing: 12) {
                        // Album art placeholder（用于 matchedGeometryEffect）
                        if musicController.currentArtwork != nil {
                            Color.clear
                                .frame(width: artSize, height: artSize)
                                .cornerRadius(6)
                                .matchedGeometryEffect(id: "playlist-placeholder", in: animationNamespace, isSource: true)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: artSize, height: artSize)
                        }

                        // Track info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(musicController.currentTrackTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text(musicController.currentArtist)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Shuffle & Repeat buttons
                HStack(spacing: 16) {
                    let themeColor = Color(red: 0.99, green: 0.24, blue: 0.27)
                    let themeBackground = themeColor.opacity(0.20)

                    Spacer()

                    Button(action: { musicController.toggleShuffle() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 11))
                            Text("Shuffle")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(musicController.shuffleEnabled ? themeColor : .white)  // 🔑 icon 始终 100% opacity
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(musicController.shuffleEnabled ? themeBackground : Color.white.opacity(0.1))
                        .cornerRadius(14)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: { musicController.cycleRepeatMode() }) {
                        HStack(spacing: 5) {
                            Image(systemName: musicController.repeatMode == 1 ? "repeat.1" : "repeat")
                                .font(.system(size: 11))
                            Text("Repeat")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(musicController.repeatMode > 0 ? themeColor : .white)  // 🔑 icon 始终 100% opacity
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(musicController.repeatMode > 0 ? themeBackground : Color.white.opacity(0.1))
                        .cornerRadius(14)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)  // 增加与 Up Next 的间距
            }
        }
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Compact Playlist Item Row（带 Gemini 模糊效果）
// 🔑 macOS 26 修复：接收 index + isUpNext 参数，从 musicController 动态读取数据
// 这样即使 SwiftUI 复用 view，数据也会是最新的

struct PlaylistItemRowCompact: View {
    let index: Int                    // 🔑 在数组中的索引
    let isUpNext: Bool                // 🔑 true = upNextTracks, false = recentTracks
    let artSize: CGFloat
    @Binding var currentPage: PlayerPage
    var fadeHeaderHeight: CGFloat = 0
    @State private var isHovering = false
    @State private var artwork: NSImage? = nil
    @State private var currentArtworkID: String = ""
    @EnvironmentObject var musicController: MusicController

    // 🔑 从 musicController 动态读取当前 track 数据
    private var track: (title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)? {
        if isUpNext {
            guard index < musicController.upNextTracks.count else { return nil }
            return musicController.upNextTracks[index]
        } else {
            // recentTracks 是反转显示的
            let reversed = Array(musicController.recentTracks.reversed())
            guard index < reversed.count else { return nil }
            return reversed[index]
        }
    }

    private var title: String { track?.title ?? "" }
    private var artist: String { track?.artist ?? "" }
    private var album: String { track?.album ?? "" }
    private var persistentID: String { track?.persistentID ?? "" }

    var isCurrentTrack: Bool {
        persistentID == musicController.currentPersistentID
    }

    private var contentID: String {
        "\(title)-\(artist)"
    }

    // 🔑 加载封面
    private func loadArtwork() {
        guard track != nil else { return }
        let requestID = contentID
        let pid = persistentID
        guard currentArtworkID != requestID else { return }

        artwork = nil
        currentArtworkID = requestID

        Task {
            // 🔑 优先从 Music.app 本地获取（有缓存，最快）
            if let localImg = await musicController.fetchArtworkByPersistentID(persistentID: pid) {
                await MainActor.run {
                    if currentArtworkID == requestID {
                        artwork = localImg
                    }
                }
                return
            }

            // 🔑 回退到 iTunes API（网络请求，较慢）
            let img = await musicController.fetchMusicKitArtwork(title: title, artist: artist, album: album)
            await MainActor.run {
                if currentArtworkID == requestID {
                    artwork = img
                }
            }
        }
    }

    var body: some View {
        Button(action: {
            if isCurrentTrack {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    currentPage = .album
                }
            } else {
                musicController.playTrack(persistentID: persistentID)
            }
        }) {
            HStack(spacing: 8) {
                if let artwork = artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: artSize, height: artSize)
                        .cornerRadius(4)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: artSize, height: artSize)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: artSize * 0.35))
                                .foregroundColor(.white.opacity(0.3))
                        )
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: isCurrentTrack ? .bold : .medium))
                        .foregroundColor(isCurrentTrack ? Color(red: 0.99, green: 0.24, blue: 0.27) : .white)
                        .lineLimit(1)

                    Text(artist)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer()

                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.99, green: 0.24, blue: 0.27))
                        .padding(.trailing, 8)
                } else if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovering ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 🔑 Gemini 方案：滚动到 header 区域时自己模糊
        .modifier(ScrollFadeEffect(headerHeight: fadeHeaderHeight))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        // 🔑 macOS 26 修复：使用 contentID 作为 task id
        // 当 musicController 的数组更新时，contentID 会变化，触发重新加载
        .task(id: contentID) {
            loadArtwork()
        }
    }
}

// MARK: - Gemini 方案：Per-View Progressive Blur
// 🔑 歌单行滚动到 header 区域时自己模糊+淡出，header 完全透明无色差

struct ScrollFadeEffect: ViewModifier {
    let headerHeight: CGFloat

    func body(content: Content) -> some View {
        if headerHeight > 0 {
            content
                .visualEffect { effectContent, geometryProxy in
                    // 获取当前行在 ScrollView 坐标系中的位置
                    let frame = geometryProxy.frame(in: .named("playlistScroll"))
                    let minY = frame.minY

                    // 🔑 只模糊行的上 1/3（约 15pt）
                    // minY >= 15: progress = 0（完全清晰）
                    // minY <= 0: progress = 1（完全模糊）
                    let fadeZone: CGFloat = 15  // 1/3 行高
                    let progress = max(0, min(1, 1 - (minY / fadeZone)))

                    return effectContent
                        .blur(radius: progress * 8)
                        .opacity(1.0 - (progress * 0.4))
                }
        } else {
            content
        }
    }
}


#if DEBUG
struct PlaylistView_Previews: PreviewProvider {
    @Namespace static var namespace
    static var previews: some View {
        PlaylistView(currentPage: .constant(.playlist), animationNamespace: namespace, selectedTab: .constant(1), showControls: .constant(true), isHovering: .constant(false), scrollOffset: .constant(0))
            .environmentObject(MusicController(preview: true))
            .frame(width: 300, height: 300)
    }
}
#endif
