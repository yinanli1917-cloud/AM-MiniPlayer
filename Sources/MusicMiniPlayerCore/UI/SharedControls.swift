import SwiftUI
import AppKit

// NSView wrapper that prevents window dragging
struct NonDraggableView: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableNSView {
        return NonDraggableNSView()
    }

    func updateNSView(_ nsView: NonDraggableNSView, context: Context) {}
}

class NonDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Window Draggable View
// NSView wrapper that explicitly enables window dragging
struct WindowDraggableView: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableNSView {
        return DraggableNSView()
    }

    func updateNSView(_ nsView: DraggableNSView, context: Context) {}
}

class DraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Start window drag
        window?.performDrag(with: event)
    }
}

// MARK: - Custom Transitions

extension AnyTransition {
    // 圆角矩形从下往上渐现的动画
    static var customSlideUpWithRoundedCorners: AnyTransition {
        AnyTransition.asymmetric(
            insertion: .roundedCornerSlideIn,
            removal: .opacity
        )
    }

    static var roundedCornerSlideIn: AnyTransition {
        AnyTransition.modifier(active: RoundedCornerSlideModifier(isVisible: false), identity: RoundedCornerSlideModifier(isVisible: true))
    }
}

struct RoundedCornerSlideModifier: ViewModifier {
    let isVisible: Bool
    private let travelDistance: CGFloat = 80  // 滑动距离

    func body(content: Content) -> some View {
        content
            .offset(y: isVisible ? 0 : travelDistance)
            .opacity(isVisible ? 1 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Shared Bottom Controls
struct SharedBottomControls: View {
    @EnvironmentObject var musicController: MusicController
    @Binding var currentPage: PlayerPage
    @Binding var isHovering: Bool
    @Binding var showControls: Bool
    @Binding var isProgressBarHovering: Bool
    @Binding var dragPosition: CGFloat?
    var onControlsHoverChanged: ((Bool) -> Void)? = nil  // 🔑 可选回调：控件hover状态变化
    var translationButton: AnyView? = nil  // 🔑 可选的翻译按钮
    @State private var isDraggingProgressBar: Bool = false
    @State private var isControlAreaHovering: Bool = false  // 🔑 整个控件区域的hover状态

    var body: some View {
        VStack(spacing: 0) {  // 🔑 spacing=0 让翻译按钮紧贴进度条
            // 🔑 翻译按钮 - 进度条上方（如果有）
            if let translationButton = translationButton {
                HStack {
                    Spacer()
                    translationButton
                }
                .padding(.trailing, 12)
                .padding(.bottom, 10)  // 从进度条往上 10px
            }

            VStack(spacing: 4) {  // 🔑 进度条区域与播放按钮间距=4
                // Progress Bar & Time - 🔑 时间显示移到进度条下方
                VStack(spacing: 2) {  // 🔑 进度条与时间间距=2
                    // Progress Bar - 放在最上面
                    progressBar

                    // Time labels - 移到进度条下方，padding与进度条一致
                    HStack {
                        Text(formatTime(musicController.currentTime))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))

                        Spacer()

                        // Audio quality badge
                        if let quality = musicController.audioQuality {
                            qualityBadge(quality)
                        }

                        Spacer()

                        Text("-" + formatTime(musicController.duration - musicController.currentTime))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 20)  // 🔑 与进度条padding一致，对齐端点
                }
                .background(NonDraggableView())

                // Playback Controls
                HStack(spacing: 10) {
                // Left navigation button
                leftNavigationButton
                    .frame(width: 26, height: 26)

                Spacer()

                // Previous Track
                HoverableControlButton(iconName: "backward.fill", size: 17) {
                    musicController.previousTrack()
                }
                .frame(width: 30, height: 30)

                // Play/Pause
                HoverableControlButton(iconName: musicController.isPlaying ? "pause.fill" : "play.fill", size: 21) {
                    musicController.togglePlayPause()
                }
                .frame(width: 30, height: 30)

                // Next Track
                HoverableControlButton(iconName: "forward.fill", size: 17) {
                    musicController.nextTrack()
                }
                .frame(width: 30, height: 30)

                Spacer()

                // Right navigation button
                playlistNavigationButton
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)  // 🔑 与 PlaylistView Now Playing 卡片一致
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        // 🔑 跟踪整个控件区域的hover状态
        .onHover { hovering in
            isControlAreaHovering = hovering
            onControlsHoverChanged?(hovering)
        }
        // 🔑 移除clipShape transition，避免方形遮罩问题
        .transition(.opacity)
    }

    // MARK: - Computed Properties

    private var leftNavigationButton: some View {
        NavigationIconButton(
            iconName: currentPage == .lyrics ? "quote.bubble.fill" : "quote.bubble",
            isActive: currentPage == .lyrics
        ) {
            // 🔑 快速但不弹性的动画
            withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                if currentPage == .album {
                    // 🔑 用户手动打开歌词页面
                    musicController.userManuallyOpenedLyrics = true
                    currentPage = .lyrics
                } else if currentPage == .lyrics {
                    currentPage = .album
                } else if currentPage == .playlist {
                    // 🔑 用户手动打开歌词页面
                    musicController.userManuallyOpenedLyrics = true
                    currentPage = .lyrics
                }
            }
        }
    }

    private var playlistNavigationButton: some View {
        NavigationIconButton(
            iconName: currentPage == .playlist ? "play.square.stack.fill" : "play.square.stack",
            isActive: currentPage == .playlist
        ) {
            // 🔑 快速但不弹性的动画
            withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                if currentPage == .album {
                    currentPage = .playlist
                } else if currentPage == .playlist {
                    currentPage = .album
                } else {
                    currentPage = .playlist
                }
            }
        }
    }


    private var progressBar: some View {
        let barHeight: CGFloat = isProgressBarHovering ? 12 : 7  // 🔑 hover前7px，hover后12px

        return GeometryReader { geo in
            let currentProgress: CGFloat = {
                if musicController.duration > 0 {
                    return dragPosition ?? CGFloat(musicController.currentTime / musicController.duration)
                }
                return 0
            }()

            // 🔑 使用遮罩实现圆角不拉伸效果
            ZStack {
                // Background Track - 从中心向上下扩展
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: barHeight)

                // Active Progress - 使用遮罩保持圆角不变形
                Capsule()
                    .fill(Color.white)
                    .frame(height: barHeight)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: geo.size.width * currentProgress)
                            Spacer(minLength: 0)
                        }
                    )
            }
            .frame(maxHeight: .infinity)  // 🔑 让ZStack在GeometryReader中垂直居中
            .contentShape(Capsule())
            .onHover { hovering in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isProgressBarHovering = hovering
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged({ value in
                        isDraggingProgressBar = true
                        let percentage = min(max(0, value.location.x / geo.size.width), 1)
                        dragPosition = percentage
                    })
                    .onEnded({ value in
                        let percentage = min(max(0, value.location.x / geo.size.width), 1)
                        let time = percentage * musicController.duration
                        musicController.seek(to: time)
                        dragPosition = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isDraggingProgressBar = false
                        }
                    })
            )
        }
        .frame(height: 14)  // 🔑 容器高度略大于最大bar高度，确保居中效果
        .padding(.horizontal, 20)  // 🔑 进度条额外padding
    }

    private func qualityBadge(_ quality: String) -> some View {
        return HStack(spacing: 2) {
            if quality == "Hi-Res Lossless" {
                Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 8))
            } else if quality == "Dolby Atmos" {
                Image(systemName: "spatial.audio.badge.checkmark").font(.system(size: 8))
            } else {
                Image(systemName: "waveform").font(.system(size: 8))
            }
            Text(quality).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .cornerRadius(4)
        .foregroundColor(.white.opacity(0.9))
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Hoverable Button Components

struct HoverableControlButton: View {
    let iconName: String
    let size: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: size))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.25 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

struct NavigationIconButton: View {
    let iconName: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 15))
                .foregroundColor(.white)  // 🔑 icon 始终 100% opacity
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity((isActive || isHovering) ? 0.25 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}