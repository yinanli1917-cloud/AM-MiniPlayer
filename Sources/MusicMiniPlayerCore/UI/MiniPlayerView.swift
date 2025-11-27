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

                // Content - NO WindowDragGesture here to avoid conflicts
                VStack(spacing: 0) {
                    if currentPage == .album {
                        // Album Art with Track Info - using auto layout
                        if let artwork = musicController.currentArtwork {
                            GeometryReader { geo in
                                ZStack {
                                    Color.clear // Ensure ZStack takes space if needed, but frame below is better
                                }
                                .frame(width: geo.size.width, height: geo.size.height)
                                .overlay(
                                    ZStack {
                                    // Calculate available height for centering
                                    let availableHeight = geo.size.height - (showControls ? 100 : 0)
                                    let artSize = isHovering ? geo.size.width * 0.50 : geo.size.width * 0.70
                                    
                                    // Shadow offset adds visual weight at bottom, so adjust center point
                                    let shadowYOffset: CGFloat = 6  // Half of shadow y offset (12/2) for visual balance
                                    
                                    // Album Artwork + Text Unit (as a single ZStack with explicit size)
                                    ZStack(alignment: .bottomLeading) {
                                        // 1. Main Artwork - defines the ZStack size
                                        Image(nsImage: artwork)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: artSize, height: artSize)
                                            .clipped()
                                            .cornerRadius(12)
                                            .shadow(color: .black.opacity(0.5), radius: 25, x: 0, y: 12)
                                            .matchedGeometryEffect(id: "main-artwork", in: animation)
                                            .onTapGesture {
                                                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                                    currentPage = currentPage == .album ? .lyrics : .album
                                                }
                                            }
                                        
                                        // 2. Gradient Mask (Bottom) - ALWAYS VISIBLE
                                        LinearGradient(
                                            gradient: Gradient(colors: [.clear, .black.opacity(0.8)]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                        .frame(width: artSize, height: isHovering ? 80 : 100)
                                        .cornerRadius(12, corners: [.bottomLeft, .bottomRight])
                                        .allowsHitTesting(false)
                                        
                                        // 3. Track Info - Inside artwork, STRICTLY left aligned - ALWAYS VISIBLE
                                        VStack(alignment: .leading, spacing: 2) {
                                            ScrollingText(
                                                text: musicController.currentTrackTitle,
                                                font: .system(size: isHovering ? 14 : 16, weight: .bold),
                                                textColor: .white,
                                                maxWidth: artSize - 24,
                                                alignment: .leading
                                            )
                                            .shadow(radius: 2)
                                            
                                            ScrollingText(
                                                text: musicController.currentArtist,
                                                font: .system(size: isHovering ? 12 : 13, weight: .medium),
                                                textColor: .white.opacity(0.9),
                                                maxWidth: artSize - 24,
                                                alignment: .leading
                                            )
                                            .shadow(radius: 2)
                                        }
                                        .padding(.leading, 12)
                                        .padding(.bottom, 12)
                                    }
                                    .frame(width: artSize, height: artSize) // Explicit frame to ensure proper sizing
                                    .position(
                                        x: geo.size.width / 2,
                                        y: (availableHeight / 2) + shadowYOffset  // Adjust for shadow visual weight
                                    )
                                    .transition(.blurFadeSlide)

                                    // Controls - fixed at bottom (overlay)
                                    if showControls {
                                        VStack {
                                            Spacer()

                                            SharedBottomControls(
                                                currentPage: $currentPage,
                                                isHovering: $isHovering,
                                                showControls: $showControls,
                                                isProgressBarHovering: $isProgressBarHovering,
                                                dragPosition: $dragPosition
                                            )
                                            .padding(.bottom, 0)
                                        }
                                        .transition(
                                            .asymmetric(
                                                insertion: .blurFadeSlide,
                                                removal: .opacity.combined(with: .scale(scale: 0.95))
                                            )
                                        )
                                    }
                                }
                                )
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
                        PlaylistView(currentPage: $currentPage, animationNamespace: animation)
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
        .frame(width: 300, height: 380) // Original aspect ratio
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            // Music按钮 - hover时显示
            if showControls {
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
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(12)
                .help("打开 Apple Music")
                .transition(
                    .asymmetric(
                        insertion: .blurFadeSlide,
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    )
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            // Hide按钮 - hover时显示
            if showControls {
                Button(action: {
                    NSApplication.shared.keyWindow?.orderOut(nil)
                }) {
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .help("收起到菜单栏")
                .transition(
                    .asymmetric(
                        insertion: .blurFadeSlide,
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    )
                )
            }
        }
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
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
    }
}


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
