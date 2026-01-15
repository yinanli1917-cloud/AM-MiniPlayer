/**
 * [INPUT]: MusicController (播放状态 + 歌单数据 + 封面缓存)
 * [OUTPUT]: PlaylistView (歌单页面视图)
 * [POS]: UI/ 的歌单页面，与 MiniPlayerView 通过 Binding 交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import AppKit

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlaylistView
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 macOS 26 修复：不用 Section + LazyVStack + pinnedViews（会触发递归 bug）
// 🔑 Sticky Header：全局 overlay + PreferenceKey 追踪 section 位置
// 🔑 Gemini 方案：header 纯文字透明，歌单行滚动到 header 区域时自己模糊
// 🔑 Snap scroll：.scrollTargetLayout() + .scrollTargetBehavior(.viewAligned)

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PreferenceKey for Section Tracking
// ═══════════════════════════════════════════════════════════════════════════════

struct SectionOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

public struct PlaylistView: View {
    @EnvironmentObject var musicController: MusicController

    // ═══════════════════════════════════════════
    // MARK: - Bindings（与 MiniPlayerView 同步）
    // ═══════════════════════════════════════════
    @Binding var currentPage: PlayerPage
    @Binding var selectedTab: Int
    @Binding var showControls: Bool
    @Binding var isHovering: Bool
    @Binding var showOverlayContent: Bool

    var animationNamespace: Namespace.ID

    // ═══════════════════════════════════════════
    // MARK: - Local State
    // ═══════════════════════════════════════════
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var isManualScrolling: Bool = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var isCoverAnimating: Bool = false

    // 滚动控制状态
    @State private var lastVelocity: CGFloat = 0
    @State private var scrollLocked: Bool = false
    @State private var hasTriggeredSlowScroll: Bool = false

    // 控件显示状态
    @State private var controlsVisible: Bool = false

    // 全屏封面模式
    @State private var fullscreenAlbumCover: Bool = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")

    // Sticky header 状态
    @State private var sectionOffsets: [String: CGFloat] = [:]

    // ═══════════════════════════════════════════
    // MARK: - Constants
    // ═══════════════════════════════════════════
    private let artSizeRatio: CGFloat = 0.18
    private let artSizeMax: CGFloat = 60.0
    private let headerHeight: CGFloat = 32

    // ═══════════════════════════════════════════
    // MARK: - Init
    // ═══════════════════════════════════════════
    public init(
        currentPage: Binding<PlayerPage>,
        animationNamespace: Namespace.ID,
        selectedTab: Binding<Int>,
        showControls: Binding<Bool>,
        isHovering: Binding<Bool>,
        showOverlayContent: Binding<Bool>
    ) {
        self._currentPage = currentPage
        self.animationNamespace = animationNamespace
        self._selectedTab = selectedTab
        self._showControls = showControls
        self._isHovering = isHovering
        self._showOverlayContent = showOverlayContent
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Body
    // ═══════════════════════════════════════════════════════════════════════════════
    public var body: some View {
        GeometryReader { geometry in
            let artSize = min(geometry.size.width * artSizeRatio, artSizeMax)
            let rowArtSize = min(geometry.size.width * 0.12, 40.0)

            ZStack(alignment: .top) {
                // ═══════════════════════════════════════════
                // MARK: - Background
                // ═══════════════════════════════════════════
                if fullscreenAlbumCover {
                    AdaptiveFluidBackground(artwork: musicController.currentArtwork)
                        .ignoresSafeArea()
                } else {
                    LiquidBackgroundView(artwork: musicController.currentArtwork)
                        .ignoresSafeArea()
                }

                // ═══════════════════════════════════════════
                // MARK: - Main ScrollView with Sections
                // ═══════════════════════════════════════════
                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {

                            // ═══════════════════════════════════════════
                            // MARK: - History Section（有 sticky header）
                            // ═══════════════════════════════════════════
                            PlaylistSection(
                                sectionID: "history",
                                title: "History",
                                headerHeight: headerHeight
                            ) {
                                if musicController.recentTracks.isEmpty {
                                    emptyStateText("No recent tracks")
                                } else {
                                    ForEach(musicController.recentTracks.reversed(), id: \.persistentID) { track in
                                        PlaylistItemRowCompact(
                                            track: track,
                                            artSize: rowArtSize,
                                            currentPage: $currentPage,
                                            isScrolling: isManualScrolling,
                                            fadeHeaderHeight: headerHeight
                                        )
                                    }
                                }
                            }
                            .id("historySection")

                            // ═══════════════════════════════════════════
                            // MARK: - Now Playing Section（普通标题，不 sticky）
                            // ═══════════════════════════════════════════
                            PlainHeaderSection(
                                title: "Now Playing",
                                headerHeight: headerHeight
                            ) {
                                nowPlayingCard(geometry: geometry, artSize: artSize)
                            }
                            .id("nowPlayingSection")

                            // ═══════════════════════════════════════════
                            // MARK: - Up Next Section（有 sticky header）
                            // ═══════════════════════════════════════════
                            PlaylistSection(
                                sectionID: "upNext",
                                title: "Up Next",
                                headerHeight: headerHeight
                            ) {
                                if musicController.upNextTracks.isEmpty {
                                    emptyStateText("Queue is empty")
                                } else {
                                    ForEach(musicController.upNextTracks, id: \.persistentID) { track in
                                        PlaylistItemRowCompact(
                                            track: track,
                                            artSize: rowArtSize,
                                            currentPage: $currentPage,
                                            isScrolling: isManualScrolling,
                                            fadeHeaderHeight: headerHeight
                                        )
                                    }
                                }
                            }
                            .id("upNextSection")

                            // 底部留白
                            Spacer().frame(height: 120)
                        }
                        .scrollTargetLayout()
                    }
                    .coordinateSpace(name: "playlistScroll")
                    .scrollTargetBehavior(.viewAligned)
                    .onPreferenceChange(SectionOffsetKey.self) { offsets in
                        sectionOffsets = offsets
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                        }
                    }
                    .onChange(of: currentPage) { _, newPage in
                        if newPage == .playlist {
                            scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                            showControlsWithAnimation()
                        }
                    }
                    .onChange(of: musicController.currentTrackTitle) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                            }
                        }
                    }
                }
                .scrollDetectionWithVelocity(
                    onScrollStarted: { handleScrollStarted() },
                    onScrollEnded: { handleScrollEnded() },
                    onScrollWithVelocity: { deltaY, velocity in handleScrollWithVelocity(deltaY: deltaY, velocity: velocity) },
                    onScrollOffsetChanged: { _ in },
                    isEnabled: currentPage == .playlist
                )

                // ═══════════════════════════════════════════
                // MARK: - Global Sticky Header Overlay
                // ═══════════════════════════════════════════
                // 🔑 根据 section offset 决定显示哪个 sticky header
                // 🔑 只有当 section 滚动到顶部且还有内容在下方时才显示
                VStack {
                    if let stickyTitle = computeStickyHeader() {
                        Text(stickyTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(height: headerHeight)
                            .allowsHitTesting(false)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)

                // ═══════════════════════════════════════════
                // MARK: - Bottom Controls Overlay
                // ═══════════════════════════════════════════
                VStack {
                    Spacer()

                    ZStack(alignment: .bottom) {
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
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                }
                .opacity(controlsVisible ? 1 : 0)
                .offset(y: controlsVisible ? 0 : 20)
                .animation(.easeInOut(duration: 0.3), value: controlsVisible)
            }
            .onAppear {
                musicController.fetchUpNextQueue()
            }
            .onHover { hovering in
                handleHover(hovering: hovering)
            }
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

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Subviews
    // ═══════════════════════════════════════════════════════════════════════════════

    @ViewBuilder
    private func emptyStateText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 20)
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Now Playing Card
    // ═══════════════════════════════════════════════════════════════════════════════
    @ViewBuilder
    private func nowPlayingCard(geometry: GeometryProxy, artSize: CGFloat) -> some View {
        if musicController.currentTrackTitle != "Not Playing" {
            VStack(spacing: 0) {
                Button(action: {
                    let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
                    withAnimation(.spring(response: animationDuration, dampingFraction: 0.85)) {
                        isCoverAnimating = true
                        currentPage = .album
                        isHovering = true
                        showControls = true
                        showOverlayContent = true
                    }
                }) {
                    HStack(alignment: .center, spacing: 12) {
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
                        .foregroundColor(musicController.shuffleEnabled ? themeColor : .white)
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
                        .foregroundColor(musicController.repeatMode > 0 ? themeColor : .white)
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
                .padding(.bottom, 16)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Event Handlers
    // ═══════════════════════════════════════════════════════════════════════════════

    private func handleScrollStarted() {
        isManualScrolling = true
        lastVelocity = 0
        scrollLocked = false
        hasTriggeredSlowScroll = false
        autoScrollTimer?.invalidate()
    }

    private func handleScrollEnded() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            if !isHovering {
                hideControls()
            } else if !controlsVisible {
                showControlsWithAnimation()
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                isManualScrolling = false
                lastVelocity = 0
                scrollLocked = false
                hasTriggeredSlowScroll = false
            }
        }
    }

    private func handleScrollWithVelocity(deltaY: CGFloat, velocity: CGFloat) {
        let absVelocity = abs(velocity)
        let threshold: CGFloat = 800

        if deltaY < 0 {
            if controlsVisible { hideControls() }
            scrollLocked = true
        } else if absVelocity >= threshold {
            if !scrollLocked { scrollLocked = true }
            if controlsVisible { hideControls() }
        } else if deltaY > 0 && !scrollLocked && !hasTriggeredSlowScroll {
            hasTriggeredSlowScroll = true
            if !controlsVisible { showControlsWithAnimation() }
        }

        lastVelocity = absVelocity
    }

    private func handleHover(hovering: Bool) {
        guard currentPage == .playlist else { return }
        isHovering = hovering

        if !hovering {
            hideControls()
        } else if !isManualScrolling && !controlsVisible {
            showControlsWithAnimation()
        }
    }

    private func showControlsWithAnimation() {
        showControls = true
        controlsVisible = true
    }

    private func hideControls() {
        showControls = false
        controlsVisible = false
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Sticky Header Logic
    // ═══════════════════════════════════════════════════════════════════════════════
    // 🔑 计算当前应该显示的 sticky header
    // 🔑 条件：section 已滚动到顶部（minY <= 0）且还有内容在视口内（底部未完全离开）

    private func computeStickyHeader() -> String? {
        let historyMinY = sectionOffsets["history_minY"] ?? 1000
        let historyMaxY = sectionOffsets["history_maxY"] ?? 1000
        let upNextMinY = sectionOffsets["upNext_minY"] ?? 1000
        let upNextMaxY = sectionOffsets["upNext_maxY"] ?? 1000

        // History: 当 section 顶部滚过视口顶部，且底部还在视口内
        if historyMinY <= 0 && historyMaxY > headerHeight {
            return "History"
        }

        // Up Next: 当 section 顶部滚过视口顶部，且底部还在视口内
        if upNextMinY <= 0 && upNextMaxY > headerHeight {
            return "Up Next"
        }

        return nil
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlaylistSection
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 避免 Section + pinnedViews 的递归 bug (POSTM-001)
// 🔑 用 PreferenceKey 报告 section 位置给父视图
// 🔑 内部 header 在 section 未滚动时显示，滚动后由全局 overlay 接管

struct PlaylistSection<Content: View>: View {
    let sectionID: String
    let title: String
    let headerHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header（在 section 内部，滚出视口后由全局 overlay 接管）
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(height: headerHeight)

            // 内容
            content
        }
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named("playlistScroll"))
                Color.clear
                    .preference(
                        key: SectionOffsetKey.self,
                        value: [
                            "\(sectionID)_minY": frame.minY,
                            "\(sectionID)_maxY": frame.maxY
                        ]
                    )
            }
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlainHeaderSection
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 普通标题（不 sticky），用于 Now Playing

struct PlainHeaderSection<Content: View>: View {
    let title: String
    let headerHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(height: headerHeight)

            content
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlaylistItemRowCompact
// ═══════════════════════════════════════════════════════════════════════════════

struct PlaylistItemRowCompact: View {
    let track: (title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)
    let artSize: CGFloat
    @Binding var currentPage: PlayerPage
    var isScrolling: Bool = false
    var fadeHeaderHeight: CGFloat = 0

    @State private var isHovering = false
    @State private var artwork: NSImage? = nil
    @State private var currentArtworkID: String = ""
    @EnvironmentObject var musicController: MusicController

    private var isCurrentTrack: Bool {
        track.persistentID == musicController.currentPersistentID
    }

    var body: some View {
        Button(action: {
            if isCurrentTrack {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    currentPage = .album
                }
            } else {
                musicController.playTrack(persistentID: track.persistentID)
            }
        }) {
            HStack(spacing: 8) {
                if let artwork = artwork, currentArtworkID == track.persistentID {
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
                    Text(track.title)
                        .font(.system(size: 11, weight: isCurrentTrack ? .bold : .medium))
                        .foregroundColor(isCurrentTrack ? Color(red: 0.99, green: 0.24, blue: 0.27) : .white)
                        .lineLimit(1)

                    Text(track.artist)
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
        .modifier(ScrollFadeEffect(headerHeight: fadeHeaderHeight, isScrolling: isScrolling))
        .onHover { hovering in
            guard !isScrolling else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .task(id: track.persistentID) {
            await loadArtwork()
        }
    }

    private func loadArtwork() async {
        let pid = track.persistentID
        guard currentArtworkID != pid else { return }

        currentArtworkID = pid
        artwork = nil

        if let cached = musicController.getCachedArtwork(persistentID: pid) {
            artwork = cached
            return
        }

        if let localImg = await musicController.fetchArtworkByPersistentID(persistentID: pid) {
            await MainActor.run {
                if currentArtworkID == pid { artwork = localImg }
            }
            return
        }

        let img = await musicController.fetchMusicKitArtwork(
            title: track.title,
            artist: track.artist,
            album: track.album
        )
        await MainActor.run {
            if currentArtworkID == pid { artwork = img }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ScrollFadeEffect
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 Gemini 方案：歌单行滚动到 header 区域时自己模糊+淡出

struct ScrollFadeEffect: ViewModifier {
    let headerHeight: CGFloat
    var isScrolling: Bool = false

    func body(content: Content) -> some View {
        if headerHeight > 0 {
            content
                .visualEffect { effectContent, geometryProxy in
                    let frame = geometryProxy.frame(in: .named("playlistScroll"))
                    let minY = frame.minY
                    // 🔑 当行滚动到 header 区域内时开始模糊
                    let progress = max(0, min(1, 1 - (minY / headerHeight)))

                    return effectContent
                        .blur(radius: progress * 8)
                        .opacity(1.0 - (progress * 0.4))
                }
        } else {
            content
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Preview
// ═══════════════════════════════════════════════════════════════════════════════

#if DEBUG
struct PlaylistView_Previews: PreviewProvider {
    @Namespace static var namespace
    static var previews: some View {
        PlaylistView(
            currentPage: .constant(.playlist),
            animationNamespace: namespace,
            selectedTab: .constant(1),
            showControls: .constant(true),
            isHovering: .constant(false),
            showOverlayContent: .constant(true)
        )
        .environmentObject(MusicController(preview: true))
        .frame(width: 300, height: 300)
    }
}
#endif
