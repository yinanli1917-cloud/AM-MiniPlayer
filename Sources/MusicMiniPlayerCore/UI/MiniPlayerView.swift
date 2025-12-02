import SwiftUI

// 移除自定义transition，使用SwiftUI官方transition避免icon消失bug

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
    @State private var showAlbumText: Bool = true  // 控制专辑页文字渐现
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

                // 🔑 使用ZStack叠加所有页面，通过opacity和zIndex控制显示
                // 这样matchedGeometryEffect可以在页面切换时正确工作

                // Lyrics View (底层)
                if currentPage == .lyrics {
                    LyricsView(currentPage: $currentPage, openWindow: openWindow)
                        .zIndex(1)
                }

                // Playlist View (中层) - 始终存在以支持matchedGeometryEffect
                PlaylistView(currentPage: $currentPage, animationNamespace: animation)
                    .opacity(currentPage == .playlist ? 1 : 0)
                    .zIndex(currentPage == .playlist ? 2 : 0)
                    .allowsHitTesting(currentPage == .playlist)

                // Album View (顶层) - 始终存在以支持matchedGeometryEffect
                albumPageContent(geometry: geometry)
                    .opacity(currentPage == .album ? 1 : 0)
                    .zIndex(currentPage == .album ? 2 : 0)
                    .allowsHitTesting(currentPage == .album)
            }
        }
        // 移除固定尺寸，让视图自动填充窗口以支持缩放
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            // Music按钮 - 只在album页面显示（其他页面有各自的按钮）
            if showControls && currentPage == .album {
                MusicButtonView()
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Hide按钮 - 只在album页面显示（其他页面有各自的按钮）
            if showControls && currentPage == .album {
                HideButtonView()
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
        .onChange(of: currentPage) { oldValue, newValue in
            // 🔑 页面切换时控制文字渐现动画
            if newValue == .album && oldValue == .playlist {
                // 从歌单返回专辑页 - 先隐藏文字，动画完成后渐现
                showAlbumText = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showAlbumText = true
                    }
                }
            } else if newValue == .playlist && oldValue == .album {
                // 从专辑去歌单页 - 隐藏文字
                showAlbumText = false
            } else {
                // 其他情况显示文字
                showAlbumText = true
            }
        }
    }

    // MARK: - Album Page Content (抽取为函数支持matchedGeometryEffect)
    @ViewBuilder
    private func albumPageContent(geometry: GeometryProxy) -> some View {
        if let artwork = musicController.currentArtwork {
            GeometryReader { geo in
                ZStack {
                    Color.clear
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(
                    ZStack {
                        // Calculate available height for centering
                        let availableHeight = geo.size.height - (showControls ? 100 : 0)
                        let artSize = isHovering ? geo.size.width * 0.50 : geo.size.width * 0.70

                        // Shadow offset adds visual weight at bottom
                        let shadowYOffset: CGFloat = 6

                        // Album Artwork + Text Unit
                        ZStack(alignment: .bottomLeading) {
                            // 1. Main Artwork - 使用matchedGeometryEffect
                            Image(nsImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: artSize, height: artSize)
                                .clipped()
                                .cornerRadius(12)
                                .shadow(color: .black.opacity(0.5), radius: 25, x: 0, y: 12)
                                .matchedGeometryEffect(id: "album-artwork", in: animation, isSource: currentPage == .album)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                        currentPage = currentPage == .album ? .lyrics : .album
                                    }
                                }

                            // 2. Gradient Mask - 动画过渡时隐藏
                            if showAlbumText {
                                LinearGradient(
                                    gradient: Gradient(colors: [.clear, .black.opacity(0.5)]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(width: artSize, height: 50)
                                .cornerRadius(12, corners: [.bottomLeft, .bottomRight])
                                .allowsHitTesting(false)
                            }

                            // 3. Track Info - 动画过渡时隐藏
                            if showAlbumText {
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
                        }
                        .frame(width: artSize, height: artSize)
                        .position(
                            x: geo.size.width / 2,
                            y: (availableHeight / 2) + shadowYOffset
                        )

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
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
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

    var body: some View {
        Button(action: {
            NSApplication.shared.keyWindow?.orderOut(nil)
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
