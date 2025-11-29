import SwiftUI
import AppKit

public struct PlaylistView: View {
    @EnvironmentObject var musicController: MusicController
    @State private var selectedTab: Int = 1 // 0 = History, 1 = Up Next
    @State private var isHovering: Bool = false
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var isManualScrolling: Bool = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var showControls: Bool = true
    @State private var lastDragLocation: CGFloat = 0
    @State private var dragVelocity: CGFloat = 0
    @Binding var currentPage: PlayerPage
    var animationNamespace: Namespace.ID
    @State private var isCoverAnimating: Bool = false

    public init(currentPage: Binding<PlayerPage>, animationNamespace: Namespace.ID) {
        self._currentPage = currentPage
        self.animationNamespace = animationNamespace
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background (Liquid Glass) - same as MiniPlayerView
                LiquidBackgroundView(artwork: musicController.currentArtwork)
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 第一行：Music/Hide按钮 - 仅在hover时显示
                    if isHovering && showControls {
                        HStack {
                            MusicButtonView()
                            Spacer()
                            HideButtonView()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .transition(.opacity)
                    }

                    // Tab Bar
                    HStack(spacing: 0) {
                        ZStack {
                            // Background Capsule
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
                        .padding(.horizontal, 60)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                    }

                    // ScrollView - controls must be OUTSIDE as overlay
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {

                            // Now Playing Section - responsive sizing
                            if musicController.currentTrackTitle != "Not Playing" {
                                let artSize = min(geometry.size.width * 0.22, 70.0) // Smaller art size

                                VStack(spacing: 0) {
                                    Button(action: {
                                        // 5-second animation to album page
                                        print("🎬 Starting 5-second animation")
                                        withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 5.0)) {
                                            isCoverAnimating = true
                                            currentPage = .album
                                        }
                                    }) {
                                        HStack(spacing: 10) {
                                            // Album art (responsive)
                                            if let artwork = musicController.currentArtwork {
                                                Image(nsImage: artwork)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: artSize, height: artSize)
                                                    .cornerRadius(6)
                                                    .shadow(radius: 3)
                                                    .matchedGeometryEffect(id: "main-artwork", in: animationNamespace)
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

                                    // Control buttons (Shuffle & Repeat) - Centered and Spaced
                                    HStack(spacing: 30) {
                                        Spacer()

                                        // Shuffle button
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

                                        // Repeat button
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
                                .padding(.bottom, 12)  // 与下面的歌曲列表间距
                            }

                            // Tab Content
                            if selectedTab == 0 {
                                // History Tab
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
                                // Up Next Tab
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
                    .overlay(
                        // 🔑 关键：控件必须在ScrollView的overlay之上，带渐变遮罩且防止点击穿透
                        Group {
                            if showControls {
                                VStack {
                                    Spacer()

                                    // 渐变遮罩 + 控件区域（整体拦截点击，防止穿透）
                                    ZStack(alignment: .bottom) {
                                        // Gradient mask
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
                                    .contentShape(Rectangle())  // 🔑 确保整个区域可点击
                                    .allowsHitTesting(true)     // 🔑 拦截所有点击，防止穿透到下层歌单
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            }
                        }
                    )
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.3)) {
                    isHovering = hovering
                    if hovering && !isManualScrolling {
                        showControls = true
                    } else if !hovering && !isManualScrolling {
                        showControls = false
                    }
                }
            }
            .onAppear {
                musicController.fetchUpNextQueue()
            }
        }
    }

    // Time formatting helper
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Compact Playlist Item Row (responsive sizing)

struct PlaylistItemRowCompact: View {
    let title: String
    let artist: String
    let album: String
    let persistentID: String
    let artSize: CGFloat
    @Binding var currentPage: PlayerPage
    @State private var isHovering = false
    @State private var artwork: NSImage? = nil
    @EnvironmentObject var musicController: MusicController

    // Check if this is the currently playing track
    var isCurrentTrack: Bool {
        title == musicController.currentTrackTitle && artist == musicController.currentArtist
    }

    var body: some View {
        Button(action: {
            // If clicking on current track, go back to album page
            if isCurrentTrack {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    currentPage = .album
                }
            } else {
                musicController.playTrack(persistentID: persistentID)
            }
        }) {
            HStack(spacing: 8) {
                // Album art (responsive)
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

                // Track info
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

                // Play icon on hover or current track indicator
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
        .task {
            // Use .task instead of .onAppear for better async handling
            if artwork == nil {
                // Try AppleScript first (most reliable for local tracks)
                if let fetchedArtwork = await musicController.fetchArtworkByPersistentID(persistentID: persistentID) {
                    await MainActor.run {
                        artwork = fetchedArtwork
                    }
                } else {
                    // Fallback to MusicKit
                    let fetchedArtwork = await musicController.fetchMusicKitArtwork(title: title, artist: artist, album: album)
                    await MainActor.run {
                        artwork = fetchedArtwork
                    }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var currentPage: PlayerPage = .playlist
    @Previewable @Namespace var namespace
    PlaylistView(currentPage: $currentPage, animationNamespace: namespace)
        .environmentObject(MusicController(preview: true))
}