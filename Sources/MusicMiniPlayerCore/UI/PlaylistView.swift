import SwiftUI
import AppKit
import os.log
import Glur

public struct PlaylistView: View {
    @EnvironmentObject var musicController: MusicController
    @Binding var selectedTab: Int
    @Binding var showControls: Bool
    @Binding var isHovering: Bool  // 🔑 改为 Binding，从 MiniPlayerView 同步
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var isManualScrolling: Bool = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var lastDragLocation: CGFloat = 0
    @State private var wasFastScrolling: Bool = false
    @Binding var currentPage: PlayerPage
    var animationNamespace: Namespace.ID
    @State private var isCoverAnimating: Bool = false
    @State private var lastVelocity: CGFloat = 0
    @State private var scrollLocked: Bool = false
    @State private var hasTriggeredSlowScroll: Bool = false  // 🔑 慢速滚动是否已触发过控件显示

    // 🔑 Clip 逻辑 - 滚动偏移量跟踪（通过 Binding 传递给 MiniPlayerView）
    @Binding var scrollOffset: CGFloat

    // 🐛 调试窗口状态
    @State private var showDebugWindow: Bool = false
    @State private var debugMessages: [String] = []

    public init(currentPage: Binding<PlayerPage>, animationNamespace: Namespace.ID, selectedTab: Binding<Int>, showControls: Binding<Bool>, isHovering: Binding<Bool>, scrollOffset: Binding<CGFloat>) {
        self._currentPage = currentPage
        self.animationNamespace = animationNamespace
        self._selectedTab = selectedTab
        self._showControls = showControls
        self._isHovering = isHovering  // 🔑 接收 isHovering binding
        self._scrollOffset = scrollOffset  // 🔑 接收 scrollOffset binding
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background (Liquid Glass)
                LiquidBackgroundView(artwork: musicController.currentArtwork)
                .ignoresSafeArea()

                // 主内容 ScrollView - 单页布局：History（上滚可见）→ Now Playing（默认位置）→ Up Next
                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            // 🔑 顶部占位 - 为 overlay 按钮留空间
                            Spacer()
                                .frame(height: 50)

                            // ═══════════════════════════════════════════
                            // MARK: - History Section（往上滚动才能看到）
                            // ═══════════════════════════════════════════
                            Text("History")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)

                            if musicController.recentTracks.isEmpty {
                                Text("No recent tracks")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 20)
                            } else {
                                ForEach(Array(musicController.recentTracks.enumerated()), id: \.offset) { index, track in
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

                            // ═══════════════════════════════════════════
                            // MARK: - Now Playing Section（默认位置）
                            // ═══════════════════════════════════════════
                            if musicController.currentTrackTitle != "Not Playing" {
                                let artSize = min(geometry.size.width * 0.18, 60.0)

                                // 🔑 锚点 - 用于默认滚动到此位置
                                Color.clear
                                    .frame(height: 50)  // 顶部留空给Music/Hide按钮
                                    .id("nowPlaying")

                                Button(action: {
                                withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                                    isCoverAnimating = true
                                    currentPage = .album
                                }
                            }) {
                                HStack(spacing: 10) {
                                    // Placeholder for Album art
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
                                .padding(10)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)

                            // Shuffle & Repeat buttons
                            HStack(spacing: 20) {
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
                        }

                        // ═══════════════════════════════════════════
                        // MARK: - Up Next Section
                        // ═══════════════════════════════════════════
                        Text("Up Next")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.top, 16)
                            .padding(.bottom, 8)

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

                            Spacer().frame(height: 120)
                        }
                    }
                    .onAppear {
                        // 🔑 默认滚动到 Now Playing 位置
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo("nowPlaying", anchor: .top)
                        }
                    }
                }
                // 🔑 scroll检测逻辑：
                // - 只有"最开始就是慢速下滑"才显示控件（一次）
                // - 一旦快速滚动过，本轮滚动不再显示控件
                // - 快速→慢速衰减不显示
                // - 滚动停止时隐藏
                .scrollDetectionWithVelocity(
                    onScrollStarted: {
                        // 开始手动滚动时重置状态
                        isManualScrolling = true
                        lastVelocity = 0
                        scrollLocked = false
                        hasTriggeredSlowScroll = false
                        autoScrollTimer?.invalidate()
                    },
                    onScrollEnded: {
                        // 🔑 滚动结束后保持控件2秒再隐藏（如果鼠标仍在窗口内则不隐藏）
                        autoScrollTimer?.invalidate()
                        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                            // 只有当鼠标不在窗口内时才隐藏
                            if !isHovering {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showControls = false
                                }
                            }
                            // 重置滚动状态
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
                        // 🔑 阈值提高到800，让稍微快一点的下滑也算慢速
                        let threshold: CGFloat = 800

                        // 🔑 上滑（deltaY < 0）→ 立即隐藏控件
                        if deltaY < 0 {
                            if showControls {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls = false
                                }
                            }
                            scrollLocked = true  // 锁定本轮滚动
                        }
                        // 🔑 快速滚动 → 隐藏并锁定本轮（只有剧烈快速才触发）
                        else if absVelocity >= threshold {
                            if !scrollLocked {
                                scrollLocked = true
                            }
                            if showControls {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls = false
                                }
                            }
                        }
                        // 🔑 慢速下滑 → 只在未锁定且未触发过时显示一次
                        else if deltaY > 0 && !scrollLocked && !hasTriggeredSlowScroll {
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
                .overlay(
                    Group {
                        if showControls {
                            VStack {
                                Spacer()

                                ZStack(alignment: .bottom) {
                                    // 🔑 渐变模糊背景 - 使用系统backdrop blur实时模糊下层内容
                                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                                        .frame(height: 130)
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
                            // 🔑 使用与LyricsView相同的简单transition
                            .transition(.opacity.combined(with: .offset(y: 20)))
                        }
                    }
                )
                // 🔑 移除PlaylistView自己的onHover，完全由MiniPlayerView控制hover状态
                // 避免多个onHover导致状态冲突和抽风

                // 🐛 调试窗口
                if showDebugWindow {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Scroll Debug")
                                .font(.system(size: 10, weight: .bold))
                            Spacer()
                            Button("Clear") {
                                debugMessages.removeAll()
                            }
                            .font(.system(size: 9))
                            Button("✕") {
                                showDebugWindow = false
                            }
                            .font(.system(size: 9))
                        }
                        .padding(4)
                        .background(Color.black.opacity(0.8))

                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(debugMessages.suffix(20), id: \.self) { msg in
                                    Text(msg)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.green)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 150)
                        .background(Color.black.opacity(0.9))
                    }
                    .frame(width: 280)
                    .background(Color.black.opacity(0.95))
                    .cornerRadius(8)
                    .shadow(radius: 10)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .onAppear {
                musicController.fetchUpNextQueue()
            }
        }
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func addDebugMessage(_ message: String) {
        debugMessages.append(message)
        if debugMessages.count > 100 {
            debugMessages.removeFirst(50)
        }
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


#Preview {
    @Previewable @State var currentPage: PlayerPage = .playlist
    @Previewable @State var selectedTab: Int = 1
    @Previewable @State var showControls: Bool = true
    @Previewable @State var isHovering: Bool = false
    @Previewable @State var scrollOffset: CGFloat = 0
    @Previewable @Namespace var namespace
    PlaylistView(currentPage: $currentPage, animationNamespace: namespace, selectedTab: $selectedTab, showControls: $showControls, isHovering: $isHovering, scrollOffset: $scrollOffset)
        .environmentObject(MusicController(preview: true))
        .frame(width: 300, height: 300)
}
