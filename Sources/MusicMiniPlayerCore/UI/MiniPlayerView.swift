import SwiftUI

// Custom Blur AnimatableModifier for smooth blur transitions
struct BlurModifier: AnimatableModifier {
    var blurRadius: Double

    var animatableData: Double {
        get { blurRadius }
        set { blurRadius = newValue }
    }

    func body(content: Content) -> some View {
        content.blur(radius: blurRadius)
    }
}

// Custom AnimatableModifier for smooth text size changes
struct AnimatableFontModifier: AnimatableModifier {
    var size: CGFloat
    var weight: Font.Weight

    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension AnyTransition {
    static var blurFadeSlide: AnyTransition {
        AnyTransition.modifier(
            active: BlurModifier(blurRadius: 40.0),
            identity: BlurModifier(blurRadius: 0.0)
        )
        .combined(with: .opacity)
        .combined(with: .scale(scale: 0.92, anchor: .bottom))
        .combined(with: .offset(y: 15))
    }
}

// Page enumeration for three-page system
public enum PlayerPage {
    case album
    case lyrics
    case playlist
}

public struct MiniPlayerView: View {
    @EnvironmentObject var musicController: MusicController
    @State private var currentPage: PlayerPage = .album
    @State private var isHovering: Bool = false
    @State private var showControls: Bool = false
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @Namespace private var animation

    var openWindow: OpenWindowAction?

    public init(openWindow: OpenWindowAction? = nil) {
        self.openWindow = openWindow
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background (Liquid Glass)
                LiquidBackgroundView(artwork: musicController.currentArtwork)
                
                // Content
                VStack(spacing: 0) {
                    if currentPage == .album {
                        // Album Art with Track Info
                        if let artwork = musicController.currentArtwork {
                            VStack(spacing: 0) {
                                if !isHovering {
                                    // Centered layout when not hovering
                                    Spacer()
                                } else {
                                    // Fixed top padding when hovering
                                    Spacer()
                                        .frame(height: 24)
                                }

                                // Album Artwork
                                ZStack(alignment: .bottom) {
                                    // Artwork with Progressive Blur
                                    ZStack {
                                        Image(nsImage: artwork)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(
                                                width: isHovering ? geometry.size.width * 0.50 : geometry.size.width * 0.70,
                                                height: isHovering ? geometry.size.width * 0.50 : geometry.size.width * 0.70
                                            )

                                        Image(nsImage: artwork)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(
                                                width: isHovering ? geometry.size.width * 0.50 : geometry.size.width * 0.70,
                                                height: isHovering ? geometry.size.width * 0.50 : geometry.size.width * 0.70
                                            )
                                            .blur(radius: 80)
                                            .mask(
                                                LinearGradient(
                                                    gradient: Gradient(stops: [
                                                        .init(color: .clear, location: 0.0),
                                                        .init(color: .clear, location: 0.65),
                                                        .init(color: .black.opacity(0.5), location: 0.80),
                                                        .init(color: .black, location: 1.0)
                                                    ]),
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                    }
                                    .clipped()

                                    // Dark Gradient for Text
                                    LinearGradient(
                                        gradient: Gradient(colors: [.clear, .black.opacity(0.7)]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .frame(
                                        width: isHovering ? geometry.size.width * 0.50 : geometry.size.width * 0.70,
                                        height: (isHovering ? geometry.size.width * 0.50 : geometry.size.width * 0.70) * 0.4
                                    )
                                    .allowsHitTesting(false)

                                    // Track Info - with blur-fade transition
                                    ZStack {
                                        if !isHovering {
                                            VStack(spacing: 4) {
                                                ScrollingText(
                                                    text: musicController.currentTrackTitle,
                                                    font: .system(size: 16, weight: .bold),
                                                    textColor: .white,
                                                    maxWidth: geometry.size.width * 0.70 - 24
                                                )
                                                .shadow(radius: 2)

                                                ScrollingText(
                                                    text: musicController.currentArtist,
                                                    font: .system(size: 14, weight: .medium),
                                                    textColor: .white.opacity(0.8),
                                                    maxWidth: geometry.size.width * 0.70 - 24
                                                )
                                                .shadow(radius: 2)
                                            }
                                            .frame(width: geometry.size.width * 0.70 - 24)
                                            .transition(.blurFadeSlide)
                                        } else {
                                            VStack(spacing: 2) {
                                                ScrollingText(
                                                    text: musicController.currentTrackTitle,
                                                    font: .system(size: 14, weight: .bold),
                                                    textColor: .white,
                                                    maxWidth: geometry.size.width * 0.50 - 24
                                                )
                                                .shadow(radius: 2)

                                                ScrollingText(
                                                    text: musicController.currentArtist,
                                                    font: .system(size: 12, weight: .medium),
                                                    textColor: .white.opacity(0.8),
                                                    maxWidth: geometry.size.width * 0.50 - 24
                                                )
                                                .shadow(radius: 2)
                                            }
                                            .frame(width: geometry.size.width * 0.50 - 24)
                                            .transition(.blurFadeSlide)
                                        }
                                    }
                                    .padding(.bottom, 12)
                                    .padding(.horizontal, 12)
                                }
                                .cornerRadius(12)
                                .shadow(color: .black.opacity(0.5), radius: 25, x: 0, y: 12)
                                .matchedGeometryEffect(id: "albumArt", in: animation)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                        currentPage = currentPage == .album ? .lyrics : .album
                                    }
                                }

                                // Bottom Spacer - for centering when not hovering
                                if !isHovering {
                                    Spacer()
                                } else {
                                    // Small spacing before controls when hovering
                                    Spacer()
                                        .frame(height: 16)
                                }

                                // Controls - only visible on hover
                                if showControls {
                                    VStack(spacing: 12) {
                                        // Time & Lossless Badge
                                        HStack {
                                            Text(formatTime(musicController.currentTime))
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                                .foregroundColor(.white.opacity(0.6))
                                                .frame(width: 35, alignment: .leading)

                                            Spacer()

                                            // Audio quality badge (dynamic)
                                            if let quality = musicController.audioQuality {
                                                HStack(spacing: 2) {
                                                    if quality == "Hi-Res Lossless" {
                                                        Image(systemName: "waveform.badge.magnifyingglass")
                                                            .font(.system(size: 8))
                                                    } else if quality == "Dolby Atmos" {
                                                        Image(systemName: "spatial.audio.badge.checkmark")
                                                            .font(.system(size: 8))
                                                    } else {
                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 8))
                                                    }
                                                    Text(quality)
                                                        .font(.system(size: 9, weight: .semibold))
                                                }
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.ultraThinMaterial)
                                                .cornerRadius(4)
                                                .foregroundColor(.white.opacity(0.9))
                                            }

                                            Spacer()

                                            Text("-" + formatTime(musicController.duration - musicController.currentTime))
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                                .foregroundColor(.white.opacity(0.6))
                                                .frame(width: 35, alignment: .trailing)
                                        }
                                        .padding(.horizontal, 28)

                                        // Progress Bar with hover animation
                                        ZStack {
                                            GeometryReader { geo in
                                                let currentProgress: CGFloat = {
                                                    if musicController.duration > 0 {
                                                        return dragPosition ?? CGFloat(musicController.currentTime / musicController.duration)
                                                    }
                                                    return 0
                                                }()

                                                ZStack(alignment: .leading) {
                                                    // Background Track
                                                    Capsule()
                                                        .fill(Color.white.opacity(0.2))
                                                        .frame(height: isProgressBarHovering ? 8 : 6)

                                                    // Active Progress
                                                    Capsule()
                                                        .fill(Color.white)
                                                        .frame(
                                                            width: geo.size.width * currentProgress,
                                                            height: isProgressBarHovering ? 8 : 6
                                                        )
                                                }
                                                .scaleEffect(isProgressBarHovering ? 1.05 : 1.0)
                                                .contentShape(Rectangle())
                                                .onHover { hovering in
                                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                                        isProgressBarHovering = hovering
                                                    }
                                                }
                                                .gesture(
                                                    DragGesture(minimumDistance: 0)
                                                        .onChanged({ value in
                                                            let percentage = min(max(0, value.location.x / geo.size.width), 1)
                                                            dragPosition = percentage
                                                        })
                                                        .onEnded({ value in
                                                            let percentage = min(max(0, value.location.x / geo.size.width), 1)
                                                            let time = percentage * musicController.duration
                                                            musicController.seek(to: time)
                                                            dragPosition = nil
                                                        })
                                                )
                                                .frame(maxHeight: .infinity, alignment: .center)
                                            }
                                        }
                                        .frame(height: 20)
                                        .padding(.horizontal, 20)

                                        // Playback Controls - lyrics left, controls center, playlist right
                                        HStack(spacing: 0) {
                                            Spacer().frame(width: 12)

                                            // Lyrics Icon (left)
                                            Button(action: {
                                                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                                    currentPage = currentPage == .album ? .lyrics : .album
                                                }
                                            }) {
                                                Image(systemName: "quote.bubble")
                                                    .font(.system(size: 16))
                                                    .foregroundColor(.white.opacity(0.7))
                                                    .frame(width: 28, height: 28)
                                            }

                                            Spacer()

                                            // Previous Track
                                            Button(action: musicController.previousTrack) {
                                                Image(systemName: "backward.fill")
                                                    .font(.system(size: 20))
                                                    .foregroundColor(.white)
                                                    .frame(width: 32, height: 32)
                                            }

                                            Spacer().frame(width: 10)

                                            // Play/Pause
                                            Button(action: musicController.togglePlayPause) {
                                                ZStack {
                                                    Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill")
                                                        .font(.system(size: 24))
                                                        .foregroundColor(.white)
                                                }
                                                .frame(width: 32, height: 32)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)

                                            Spacer().frame(width: 10)

                                            // Next Track
                                            Button(action: musicController.nextTrack) {
                                                Image(systemName: "forward.fill")
                                                    .font(.system(size: 20))
                                                    .foregroundColor(.white)
                                                    .frame(width: 32, height: 32)
                                            }

                                            Spacer()

                                            // Playlist Icon (right)
                                            Button(action: {
                                                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                                    currentPage = currentPage == .album ? .playlist : .album
                                                }
                                            }) {
                                                Image(systemName: "music.note.list")
                                                    .font(.system(size: 16))
                                                    .foregroundColor(.white.opacity(0.7))
                                                    .frame(width: 28, height: 28)
                                            }

                                            Spacer().frame(width: 12)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 4)
                                    .padding(.top, 0)
                                    .transition(
                                        .asymmetric(
                                            insertion: .blurFadeSlide,
                                            removal: .opacity.combined(with: .scale(scale: 0.95))
                                        )
                                    )
                                }
                            }
                        } else {
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
                    } else if currentPage == .lyrics {
                        // Lyrics View with 3D flip animation
                        LyricsView(currentPage: $currentPage, openWindow: openWindow)
                            .rotation3DEffect(
                                .degrees(currentPage == .lyrics ? 0 : -90),
                                axis: (x: 0, y: 1, z: 0),
                                perspective: 0.5
                            )
                            .transition(.opacity)
                    } else if currentPage == .playlist {
                        // Playlist View with 3D flip animation
                        PlaylistView(currentPage: $currentPage)
                            .rotation3DEffect(
                                .degrees(currentPage == .playlist ? 0 : 90),
                                axis: (x: 0, y: 1, z: 0),
                                perspective: 0.5
                            )
                            .transition(.opacity)
                    }
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.25)) {
                    isHovering = hovering
                }

                // Delayed controls
                if hovering {
                    withAnimation(.easeInOut(duration: 0.30).delay(0.05)) {
                        showControls = true
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.30)) {
                        showControls = false
                    }
                }
            }
        }
        .frame(width: 300, height: 380) // Increased height to fit controls
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
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
            .frame(width: 300, height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
    }
}
