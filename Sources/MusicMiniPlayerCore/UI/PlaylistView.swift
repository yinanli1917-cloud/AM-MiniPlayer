import SwiftUI
import AppKit
import os.log
import Glur

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

    @Binding var scrollOffset: CGFloat

    // 🔑 统一的 artSize 常量（与 MiniPlayerView 同步）
    private let artSizeRatio: CGFloat = 0.18
    private let artSizeMax: CGFloat = 60.0

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
                // Background (Solid color from album art)
                SolidColorBackgroundView(artwork: musicController.currentArtwork)
                    .ignoresSafeArea()

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
                                    ForEach(Array(musicController.recentTracks.reversed().enumerated()), id: \.offset) { index, track in
                                        PlaylistItemRowCompact(
                                            title: track.title,
                                            artist: track.artist,
                                            album: track.album,
                                            persistentID: track.persistentID,
                                            artSize: min(geometry.size.width * 0.12, 40.0),
                                            currentPage: $currentPage
                                        )
                                    }
                                }
                            }
                            .id("historySection")

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
                                    ForEach(Array(musicController.upNextTracks.enumerated()), id: \.offset) { index, track in
                                        PlaylistItemRowCompact(
                                            title: track.title,
                                            artist: track.artist,
                                            album: track.album,
                                            persistentID: track.persistentID,
                                            artSize: min(geometry.size.width * 0.12, 40.0),
                                            currentPage: $currentPage
                                        )
                                    }
                                }
                            }
                            .id("upNextSection")

                            // 底部留白
                            Spacer().frame(height: 20)
                        }
                        .scrollTargetLayout()  // 🔑 启用 snap 目标
                    }
                    .scrollTargetBehavior(.viewAligned)  // 🔑 snap 效果
                    .onAppear {
                        // 🔑 默认滚动到 Now Playing 位置
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                        }
                    }
                    .onChange(of: musicController.currentTrackTitle) { _ in
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
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showControls = false
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
                            if showControls {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls = false
                                }
                            }
                            scrollLocked = true
                        } else if absVelocity >= threshold {
                            if !scrollLocked {
                                scrollLocked = true
                            }
                            if showControls {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls = false
                                }
                            }
                        } else if deltaY > 0 && !scrollLocked && !hasTriggeredSlowScroll {
                            hasTriggeredSlowScroll = true
                            if !showControls {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls = true
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
                if showControls {
                    VStack {
                        Spacer()

                        ZStack(alignment: .bottom) {
                            // 渐变模糊背景
                            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                                .frame(height: 80)
                                .mask(
                                    LinearGradient(
                                        gradient: Gradient(stops: [
                                            .init(color: .clear, location: 0),
                                            .init(color: .black.opacity(0.3), location: 0.15),
                                            .init(color: .black.opacity(0.6), location: 0.3),
                                            .init(color: .black, location: 0.5),
                                            .init(color: .black, location: 1.0)
                                        ]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

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
                    .transition(.opacity.combined(with: .offset(y: 20)))
                }
            }
            .onAppear {
                musicController.fetchUpNextQueue()
            }
        }
    }

    // MARK: - Sticky Header (Pure Gaussian Blur)
    @ViewBuilder
    private func stickyHeader(_ title: String) -> some View {
        ZStack(alignment: .leading) {
            // 纯高斯模糊背景，不添加任何颜色或透明度
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)

            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 36)
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
                        .foregroundColor(musicController.shuffleEnabled ? themeColor : .white.opacity(0.6))
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
                        .foregroundColor(musicController.repeatMode > 0 ? themeColor : .white.opacity(0.6))
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
                .padding(.bottom, 0)
            }
        }
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Compact Playlist Item Row

struct PlaylistItemRowCompact: View {
    let title: String
    let artist: String
    let album: String
    let persistentID: String
    let artSize: CGFloat
    @Binding var currentPage: PlayerPage
    @State private var isHovering = false
    @State private var artwork: NSImage? = nil
    @State private var currentArtworkID: String = ""
    @EnvironmentObject var musicController: MusicController

    var isCurrentTrack: Bool {
        title == musicController.currentTrackTitle && artist == musicController.currentArtist
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
                if let artwork = artwork, currentArtworkID == persistentID {
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .task(id: persistentID) {
            if currentArtworkID != persistentID {
                artwork = nil
                currentArtworkID = persistentID
            }

            if let fetchedArtwork = await musicController.fetchArtworkByPersistentID(persistentID: persistentID) {
                await MainActor.run {
                    if currentArtworkID == persistentID {
                        artwork = fetchedArtwork
                    }
                }
            } else {
                let fetchedArtwork = await musicController.fetchMusicKitArtwork(title: title, artist: artist, album: album)
                await MainActor.run {
                    if currentArtworkID == persistentID {
                        artwork = fetchedArtwork
                    }
                }
            }
        }
    }
}

// MARK: - Solid Color Background View (Album Art Color Extraction - 与 LiquidBackgroundView 相同算法)

struct SolidColorBackgroundView: View {
    var artwork: NSImage?
    @State private var dominantColor: Color = .clear

    var body: some View {
        dominantColor
            .onAppear {
                updateColor()
            }
            .onChange(of: artwork) { _ in
                updateColor()
            }
    }

    private func updateColor() {
        if let artwork = artwork {
            DispatchQueue.global(qos: .userInitiated).async {
                if let nsColor = artwork.dominantColor() {
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.8)) {
                            // 🔑 使用与 LiquidBackgroundView 完全相同的逻辑
                            self.dominantColor = Color(nsColor: nsColor)
                        }
                    }
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.6)) {
                dominantColor = .clear
            }
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
