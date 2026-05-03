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
    @ObservedObject var timePublisher: TimePublisher
    @Binding var currentPage: PlayerPage
    @Binding var isHovering: Bool
    @Binding var showControls: Bool
    @Binding var isProgressBarHovering: Bool
    @Binding var dragPosition: CGFloat?
    var onControlsHoverChanged: ((Bool) -> Void)? = nil  // 🔑 可选回调：控件hover状态变化
    var translationButton: AnyView? = nil  // 🔑 可选的翻译按钮
    @State private var isDraggingProgressBar: Bool = false
    @State private var isControlAreaHovering: Bool = false  // 🔑 整个控件区域的hover状态
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let translationButton = translationButton {
                HStack {
                    Spacer()
                    translationButton
                }
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }

            VStack(spacing: 4) {  // 🔑 进度条区域与播放按钮间距=4
                // Progress Bar & Time - 🔑 时间显示移到进度条下方
                VStack(spacing: 2) {  // 🔑 进度条与时间间距=2
                    // Progress Bar - 放在最上面
                    progressBar

                    // Time labels - 移到进度条下方，padding与进度条一致
                    HStack {
                        Text(formatTime(timePublisher.currentTime))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .shadow(color: .black.opacity(0.2 + 0.4 * musicController.controlAreaLuminance), radius: 2 + 6 * musicController.controlAreaLuminance)
                            .accessibilityHidden(true)

                        Spacer()

                        // Audio quality badge
                        if let quality = musicController.audioQuality {
                            qualityBadge(quality)
                        }

                        Spacer()

                        Text("-" + formatTime(musicController.duration - timePublisher.currentTime))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .shadow(color: .black.opacity(0.2 + 0.4 * musicController.controlAreaLuminance), radius: 2 + 6 * musicController.controlAreaLuminance)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 20)  // 🔑 与进度条padding一致，对齐端点
                }

                // Playback Controls
                HStack(spacing: 10) {
                // Left navigation button
                leftNavigationButton
                    .frame(width: 26, height: 26)
                    .accessibilityLabel(currentPage == .lyrics ? "歌词（已选中）" : "歌词")

                Spacer()

                // Playback cluster — wrapped in GlassEffectContainer for shared sampling
                playbackCluster

                Spacer()

                // Right navigation button
                playlistNavigationButton
                    .frame(width: 26, height: 26)
                    .accessibilityLabel(currentPage == .playlist ? "播放列表（已选中）" : "播放列表")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)  // 🔑 与 PlaylistView Now Playing 卡片一致
            .padding(.bottom, 16)
            .contentShape(Rectangle())
            .background(NonDraggableView())
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
            let animation: Animation? = reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 1.0)
            withAnimation(animation) {
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

    @ViewBuilder
    private var playbackCluster: some View {
        let buttons = HStack(spacing: 10) {
            SkipControlButton(action: {
                musicController.previousTrack()
            }, direction: -1)
            .frame(width: 30, height: 30)
            .accessibilityLabel("上一首")

            HoverableControlButton(iconName: musicController.isPlaying ? "pause.fill" : "play.fill", size: 21) {
                musicController.togglePlayPause()
            }
            .frame(width: 30, height: 30)
            .accessibilityLabel(musicController.isPlaying ? "暂停" : "播放")

            SkipControlButton(action: {
                musicController.nextTrack()
            }, direction: 1)
            .frame(width: 30, height: 30)
            .accessibilityLabel("下一首")
        }

        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                buttons
            }
        } else {
            buttons
        }
    }

    private var playlistNavigationButton: some View {
        NavigationIconButton(
            iconName: currentPage == .playlist ? "play.square.stack.fill" : "play.square.stack",
            isActive: currentPage == .playlist
        ) {
            let animation: Animation? = reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 1.0)
            withAnimation(animation) {
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
                    return dragPosition ?? CGFloat(timePublisher.currentTime / musicController.duration)
                }
                return 0
            }()

            // 🔑 使用遮罩实现圆角不拉伸效果
            ZStack {
                // Background Track
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .light)
                    .frame(height: barHeight)

                // Active Progress
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
                let animation: Animation? = reduceMotion ? nil : .smooth(duration: 0.25)
                withAnimation(animation) {
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
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(formatTime(timePublisher.currentTime)) / \(formatTime(musicController.duration))")
        .accessibilityAddTraits(.allowsDirectInteraction)
    }

    private func qualityBadge(_ quality: String) -> some View {
        return HStack(spacing: 2) {
            if quality == "Hi-Res Lossless" {
                Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 8))
                    .accessibilityHidden(true)
            } else if quality == "Dolby Atmos" {
                Image(systemName: "spatial.audio.badge.checkmark").font(.system(size: 8))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "waveform").font(.system(size: 8))
                    .accessibilityHidden(true)
            }
            Text(quality).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .modifier(GlassCapsule(fallbackOpacity: 0.15))
        .foregroundStyle(Color.white.opacity(0.9))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("音频质量：\(quality)")
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
    var direction: CGFloat = 0
    @State private var isHovering = false
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            action()
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.12, dampingFraction: 0.9)) { isPressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { isPressed = false }
            }
        } label: {
            Image(systemName: iconName)
                .contentTransition(.symbolEffect(.replace.offUp))
                .font(.system(size: size))
                .foregroundColor(.white)
                .scaleEffect(isPressed ? 0.82 : 1.0)
                .offset(x: isPressed ? direction * 3.5 : 0)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.25 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Skip Control Button (Replacement Flow Micro-Interaction)

private struct TriangleAnimValues {
    var offsetX: CGFloat = 0
    var opacity: Double = 1.0
    var scaleX: CGFloat = 1.0
}

struct SkipControlButton: View {
    let action: () -> Void
    let direction: CGFloat

    @State private var isHovering = false
    @State private var commitTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(isHovering ? 0.25 : 0))

            Button {
                action()
                if !reduceMotion { commitTrigger += 1 }
            } label: {
                HStack(spacing: -4) {
                    trailTriangle
                    leadTriangle
                }
                .scaleEffect(x: direction, y: 1)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
            }
            .buttonStyle(SkipPressStyle(reduceMotion: reduceMotion))
        }
        .frame(width: 32, height: 32)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }

    private var leadTriangle: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 13.5))
            .foregroundColor(.white)
            .keyframeAnimator(
                initialValue: TriangleAnimValues(),
                trigger: commitTrigger
            ) { content, value in
                content
                    .scaleEffect(x: value.scaleX, y: 1.0)
                    .offset(x: value.offsetX)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.offsetX) {
                    CubicKeyframe(18, duration: 0.28)
                    MoveKeyframe(-14)
                    SpringKeyframe(0, duration: 0.42, spring: .init(response: 0.38, dampingRatio: 0.88))
                }
                KeyframeTrack(\.opacity) {
                    CubicKeyframe(0, duration: 0.22)
                    MoveKeyframe(0)
                    CubicKeyframe(1.0, duration: 0.34)
                }
                KeyframeTrack(\.scaleX) {
                    CubicKeyframe(1.15, duration: 0.25)
                    MoveKeyframe(0.88)
                    SpringKeyframe(1.0, duration: 0.34, spring: .init(response: 0.30, dampingRatio: 0.85))
                }
            }
    }

    private var trailTriangle: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 13.5))
            .foregroundColor(.white)
            .keyframeAnimator(
                initialValue: TriangleAnimValues(),
                trigger: commitTrigger
            ) { content, value in
                content
                    .scaleEffect(x: value.scaleX, y: 1.0)
                    .offset(x: value.offsetX)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.offsetX) {
                    LinearKeyframe(0, duration: 0.06)
                    CubicKeyframe(15, duration: 0.28)
                    MoveKeyframe(-12)
                    SpringKeyframe(0, duration: 0.40, spring: .init(response: 0.38, dampingRatio: 0.88))
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1.0, duration: 0.06)
                    CubicKeyframe(0, duration: 0.22)
                    MoveKeyframe(0)
                    CubicKeyframe(1.0, duration: 0.32)
                }
                KeyframeTrack(\.scaleX) {
                    LinearKeyframe(1.0, duration: 0.06)
                    CubicKeyframe(1.12, duration: 0.25)
                    MoveKeyframe(0.90)
                    SpringKeyframe(1.0, duration: 0.32, spring: .init(response: 0.30, dampingRatio: 0.85))
                }
            }
    }
}

private struct SkipPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.85 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.12, dampingFraction: 0.65),
                value: configuration.isPressed
            )
    }
}

// MARK: - Skip Text Transition (entry-only, smooth spring)

private struct MetadataTransitionValues {
    var offsetX: CGFloat = 0
    var blur: CGFloat = 0
    var opacity: Double = 1.0
}

struct SkipTextTransition: ViewModifier {
    let text: String
    let direction: CGFloat
    var offset: CGFloat = 30
    var maxBlur: CGFloat = 8
    @State private var trigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(
                initialValue: MetadataTransitionValues(),
                trigger: trigger
            ) { view, value in
                view
                    .offset(x: value.offsetX)
                    .blur(radius: value.blur)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.offsetX) {
                    MoveKeyframe(direction * offset)
                    CubicKeyframe(direction * offset * 0.6, duration: 0.12)
                    SpringKeyframe(0, duration: 0.65, spring: .init(response: 0.5, dampingRatio: 0.92))
                }
                KeyframeTrack(\.blur) {
                    MoveKeyframe(maxBlur)
                    CubicKeyframe(maxBlur * 0.5, duration: 0.15)
                    CubicKeyframe(0, duration: 0.50)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0.0)
                    CubicKeyframe(0.3, duration: 0.12)
                    CubicKeyframe(1.0, duration: 0.45)
                }
            }
            .onChange(of: text) { oldValue, newValue in
                guard !reduceMotion, oldValue != newValue else { return }
                trigger += 1
            }
    }
}

// MARK: - Animated Shuffle Icon (Per-Arrow Swap Flow)

private struct ShuffleArrowValues {
    var offsetX: CGFloat = 0
    var opacity: Double = 1.0
    var scale: CGFloat = 1.0
}

struct AnimatedShuffleIcon: View {
    let color: Color
    let isEnabled: Bool
    var size: CGFloat = 11
    var weight: Font.Weight = .semibold

    @State private var commitTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "shuffle")
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .keyframeAnimator(
                initialValue: ShuffleArrowValues(),
                trigger: commitTrigger
            ) { content, value in
                content
                    .scaleEffect(value.scale)
                    .offset(x: value.offsetX)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.offsetX) {
                    CubicKeyframe(12, duration: 0.25)
                    MoveKeyframe(-10)
                    SpringKeyframe(0, duration: 0.40, spring: .init(response: 0.38, dampingRatio: 0.88))
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.12, duration: 0.22)
                    MoveKeyframe(0.88)
                    SpringKeyframe(1.0, duration: 0.32, spring: .init(response: 0.30, dampingRatio: 0.85))
                }
                KeyframeTrack(\.opacity) {
                    CubicKeyframe(0, duration: 0.20)
                    MoveKeyframe(0)
                    CubicKeyframe(1.0, duration: 0.32)
                }
            }
            .onChange(of: isEnabled) { _, _ in
                guard !reduceMotion else { return }
                commitTrigger += 1
            }
    }
}

struct CapsulePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.1, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

struct NavigationIconButton: View {
    let iconName: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 15))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity((isActive || isHovering) ? 0.25 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}
