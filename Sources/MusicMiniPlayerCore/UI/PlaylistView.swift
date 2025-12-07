import SwiftUI
import AppKit
import os.log

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

                // 主内容 ScrollView
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // 🔑 顶部占位 - 为 Tab 层留空间（Music/Hide 按钮是 overlay 不占空间）
                        Spacer()
                            .frame(height: 60)  // Tab 高度固定 60

                        // Now Playing Section
                        if musicController.currentTrackTitle != "Not Playing" {
                            let artSize = min(geometry.size.width * 0.22, 70.0)

                            VStack(spacing: 0) {
                                Button(action: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
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
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(musicController.currentTrackTitle)
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundColor(.white)
                                                .lineLimit(1)

                                            Text(musicController.currentArtist)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(.white.opacity(0.8))
                                                .lineLimit(1)

                                            if !musicController.currentAlbum.isEmpty {
                                                Text(musicController.currentAlbum)
                                                    .font(.system(size: 10, weight: .regular))
                                                    .foregroundColor(.white.opacity(0.6))
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer()
                                    }
                                    .padding(12)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                // Shuffle & Repeat buttons
                                HStack(spacing: 30) {
                                    Spacer()

                                    Button(action: {
                                        musicController.toggleShuffle()
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "shuffle")
                                                .font(.system(size: 12))
                                            Text("Shuffle")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundColor(musicController.shuffleEnabled ? .white : .white.opacity(0.6))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(musicController.shuffleEnabled ? Color(red: 0.99, green: 0.24, blue: 0.27) : Color.white.opacity(0.1))
                                        .cornerRadius(16)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        musicController.cycleRepeatMode()
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: musicController.repeatMode == 1 ? "repeat.1" : "repeat")
                                                .font(.system(size: 12))
                                            Text("Repeat")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundColor(musicController.repeatMode > 0 ? .white : .white.opacity(0.6))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(musicController.repeatMode > 0 ? Color(red: 0.99, green: 0.24, blue: 0.27) : Color.white.opacity(0.1))
                                        .cornerRadius(16)
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()
                                }
                                .padding(.top, 12)
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                        }

                        // Tab Content
                        if selectedTab == 0 {
                            if musicController.recentTracks.isEmpty {
                                Text("No recent tracks")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 40)
                            } else {
                                ForEach(Array(musicController.recentTracks.enumerated()), id: \.offset) { index, track in
                                    PlaylistItemRowCompact(
                                        title: track.title,
                                        artist: track.artist,
                                        album: track.album,
                                        persistentID: track.persistentID,
                                        artSize: min(geometry.size.width * 0.15, 45.0),
                                        currentPage: $currentPage
                                    )
                                }
                            }
                        } else {
                            if musicController.upNextTracks.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 40))
                                        .foregroundColor(.white.opacity(0.3))

                                    Text("Queue is empty")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                ForEach(Array(musicController.upNextTracks.enumerated()), id: \.offset) { index, track in
                                    PlaylistItemRowCompact(
                                        title: track.title,
                                        artist: track.artist,
                                        album: track.album,
                                        persistentID: track.persistentID,
                                        artSize: min(geometry.size.width * 0.15, 45.0),
                                        currentPage: $currentPage
                                    )
                                }
                            }
                        }

                        Spacer().frame(height: 100)
                    }
                }
                // 🔑 scroll检测 - 与LyricsView同步的逻辑：阈值300，只触发一次，停止时隐藏
                .scrollDetectionWithVelocity(
                    onScrollStarted: {
                        // 开始手动滚动时
                        isManualScrolling = true
                        lastVelocity = 0
                        scrollLocked = false
                        hasTriggeredSlowScroll = false  // 🔑 重置慢速滚动触发标志
                        autoScrollTimer?.invalidate()
                    },
                    onScrollEnded: {
                        // 滚动结束时立即隐藏控件
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showControls = false  // 🔑 停止滚动时立即隐藏控件
                        }
                        autoScrollTimer?.invalidate()
                        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isManualScrolling = false
                                lastVelocity = 0
                                scrollLocked = false
                                hasTriggeredSlowScroll = false  // 🔑 重置慢速滚动触发标志
                            }
                        }
                    },
                    onScrollWithVelocity: { deltaY, velocity in
                        let absVelocity = abs(velocity)
                        let threshold: CGFloat = 300  // 🔑 阈值提高到300

                        let debugMsg = String(format: "🔍 deltaY: %.1f, v: %.1f, locked: %@, triggered: %@", deltaY, absVelocity, scrollLocked ? "YES" : "NO", hasTriggeredSlowScroll ? "YES" : "NO")
                        addDebugMessage(debugMsg)

                        // 快速滚动 → 隐藏并锁定，同时重置慢速触发标志
                        if absVelocity >= threshold {
                            addDebugMessage("⚡️ FAST - hiding & locking")
                            scrollLocked = true
                            hasTriggeredSlowScroll = false  // 🔑 快速滚动时重置，允许下次慢速时再触发
                            if showControls {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls = false
                                }
                            }
                        }
                        // 慢速下滑 → 只触发一次显示
                        else if deltaY > 0 && absVelocity < threshold && !hasTriggeredSlowScroll {
                            addDebugMessage("🐌 SLOW DOWN - unlocking & showing (ONCE)")
                            scrollLocked = false
                            hasTriggeredSlowScroll = true  // 🔑 标记已触发，防止反复触发
                            if !showControls {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls = true
                                }
                            }
                        }

                        lastVelocity = absVelocity
                    },
                    onScrollOffsetChanged: { offset in
                        // 🔑 跟踪滚动偏移量用于 clip 逻辑
                        scrollOffset = offset
                    },
                    isEnabled: currentPage == .playlist  // 🔑 只在歌单页面启用滚动检测
                )
                .overlay(
                    Group {
                        if showControls {
                            VStack {
                                Spacer()

                                ZStack(alignment: .bottom) {
                                    // 渐变背景 - 使用opacity动画，不需要clipShape
                                    LinearGradient(
                                        gradient: Gradient(colors: [.clear, .black.opacity(0.5)]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .frame(height: 80)

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
                .onHover { hovering in
                    isHovering = hovering
                    // 🔑 鼠标离开窗口时总是隐藏控件（与LyricsView同步）
                    if !hovering {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showControls = false
                        }
                    }
                    // 🔑 歌单页面不在非滚动时自动显示控件（由tab层和scroll逻辑控制）
                }

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
}
