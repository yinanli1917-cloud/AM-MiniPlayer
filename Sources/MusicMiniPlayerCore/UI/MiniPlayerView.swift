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
            active: BlurModifier(blurRadius: 30.0),
            identity: BlurModifier(blurRadius: 0.0)
        )
        .combined(with: .opacity)
        .combined(with: .scale(scale: 0.92, anchor: .bottom))
        .combined(with: .offset(y: 15))
    }
}

public struct MiniPlayerView: View {
    @EnvironmentObject var musicController: MusicController
    @State private var isFlipped: Bool = false
    @State private var isHovering: Bool = false
    @State private var showControls: Bool = false
    @Namespace private var animation

    public init() {}
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background (Liquid Glass)
                LiquidBackgroundView(artwork: musicController.currentArtwork)
                
                // Content
                VStack(spacing: 0) {
                    if !isFlipped {
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

                                    // Track Info
                                    VStack(spacing: 4) {
                                        Text(musicController.currentTrackTitle)
                                            .modifier(AnimatableFontModifier(
                                                size: isHovering ? 14 : 16,
                                                weight: .bold
                                            ))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .shadow(radius: 2)

                                        Text(musicController.currentArtist)
                                            .modifier(AnimatableFontModifier(
                                                size: isHovering ? 12 : 14,
                                                weight: .medium
                                            ))
                                            .foregroundColor(.white.opacity(0.8))
                                            .lineLimit(1)
                                            .shadow(radius: 2)
                                    }
                                    .padding(.bottom, 12)
                                    .padding(.horizontal, 12)
                                }
                                .cornerRadius(12)
                                .shadow(color: .black.opacity(0.5), radius: 25, x: 0, y: 12)
                                .matchedGeometryEffect(id: "albumArt", in: animation)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                        isFlipped.toggle()
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

                                // Controls - only visible on hover with delay
                                if showControls {
                                    VStack(spacing: 12) {
                                        // Time & Lossless Badge
                                        HStack {
                                            Text("0:07")
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                                .foregroundColor(.white.opacity(0.6))
                                                .frame(width: 30, alignment: .leading)

                                            Spacer()

                                            HStack(spacing: 2) {
                                                Image(systemName: "waveform")
                                                    .font(.system(size: 8))
                                                Text("Lossless")
                                                    .font(.system(size: 9, weight: .semibold))
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.ultraThinMaterial)
                                            .cornerRadius(4)
                                            .foregroundColor(.white.opacity(0.9))

                                            Spacer()

                                            Text("-4:11")
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                                .foregroundColor(.white.opacity(0.6))
                                                .frame(width: 30, alignment: .trailing)
                                        }
                                        .padding(.horizontal, 8)

                                        // Progress Bar
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Capsule()
                                                    .fill(Color.white.opacity(0.2))
                                                    .frame(height: 4)

                                                Capsule()
                                                    .fill(Color.white)
                                                    .frame(width: geo.size.width * 0.3, height: 4)
                                            }
                                        }
                                        .frame(height: 4)

                                        // Playback Controls
                                        ZStack {
                                            HStack {
                                                Button(action: {}) {
                                                    Image(systemName: "speaker.wave.2.fill")
                                                        .font(.system(size: 14))
                                                        .foregroundColor(.white.opacity(0.7))
                                                }
                                                .frame(width: 40)
                                                Spacer()
                                            }

                                            HStack(spacing: 24) {
                                                Button(action: musicController.previousTrack) {
                                                    Image(systemName: "backward.fill")
                                                        .font(.system(size: 18))
                                                        .foregroundColor(.white)
                                                }

                                                Button(action: musicController.togglePlayPause) {
                                                    Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill")
                                                        .font(.system(size: 32))
                                                        .foregroundColor(.white)
                                                }

                                                Button(action: musicController.nextTrack) {
                                                    Image(systemName: "forward.fill")
                                                        .font(.system(size: 18))
                                                        .foregroundColor(.white)
                                                }
                                            }

                                            HStack {
                                                Spacer()
                                                HStack(spacing: 16) {
                                                    Button(action: { withAnimation { isFlipped.toggle() } }) {
                                                        Image(systemName: "quote.bubble")
                                                            .font(.system(size: 14))
                                                            .foregroundColor(.white.opacity(0.7))
                                                    }

                                                    Button(action: {}) {
                                                        Image(systemName: "list.bullet")
                                                            .font(.system(size: 14))
                                                            .foregroundColor(.white.opacity(0.7))
                                                    }
                                                }
                                                .frame(width: 60, alignment: .trailing)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 20)
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
                            Spacer()
                        }
                    } else {
                        // Lyrics View
                        LyricsView()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                    isFlipped.toggle()
                                }
                            }
                            .transition(.opacity)
                    }
                }
            }
            .onHover { hovering in
                // Animation for album art and text - faster
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isHovering = hovering
                }

                if hovering {
                    // Delay showing controls by 0.1s after animation starts
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            showControls = true
                        }
                    }
                } else {
                    // Hide controls quickly when mouse leaves
                    withAnimation(.easeOut(duration: 0.18)) {
                        showControls = false
                    }
                }
            }
        }
        .frame(width: 300, height: 340) // Compact MiniPlayer size
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                let controller = MusicController.shared
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
