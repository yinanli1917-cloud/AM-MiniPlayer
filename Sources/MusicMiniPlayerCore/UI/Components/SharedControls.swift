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

struct SkipControlButton: View {
    let action: () -> Void
    let direction: CGFloat

    @State private var isHovering = false
    @State private var replacementPhase: CGFloat = 0
    @State private var animationSerial = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            playReplacementAnimation(perform: action)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isHovering ? 0.25 : 0))

                Circle()
                    .fill(Color.white.opacity(internalPulseOpacity))
                    .scaleEffect(internalPulseScale)
                    .blur(radius: 0.6)

                Circle()
                    .strokeBorder(Color.white.opacity(internalRingOpacity), lineWidth: 1.0)
                    .scaleEffect(internalRingScale)

                interiorMotion

                ZStack {
                    triangle(role: .incoming)
                    triangle(role: .backAdvance)
                    triangle(role: .frontExit)
                }
                .frame(width: 32, height: 32)
                .scaleEffect(clusterScale)
                .offset(x: clusterOffset)
                .scaleEffect(x: direction, y: 1)
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(SkipPressStyle(reduceMotion: reduceMotion))
        .frame(width: 32, height: 32)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }

    private enum TriangleRole {
        case frontExit, backAdvance, incoming
    }

    private struct TriangleMetrics {
        let x: CGFloat
        let opacity: Double
        let scaleX: CGFloat
        let scaleY: CGFloat
        let blur: CGFloat
        let brightness: Double
        let coreOpacity: Double
        let coreX: CGFloat
        let coreScaleX: CGFloat
        let coreScaleY: CGFloat
        let coreBlur: CGFloat
    }

    private struct MomentumRibbonMetrics {
        let x: CGFloat
        let opacity: Double
        let scaleX: CGFloat
        let blur: CGFloat
    }

    private struct SparkMetrics {
        let x: CGFloat
        let opacity: Double
        let scale: CGFloat
        let blur: CGFloat
    }

    private struct InteriorCueMetrics {
        let x: CGFloat
        let opacity: Double
        let scale: CGFloat
        let stretch: CGFloat
        let blur: CGFloat
    }

    private var interiorMotion: some View {
        ZStack {
            momentumRibbon(delay: 0.00, y: -4.1, width: 14.4, height: 1.75, peakOpacity: 0.24)
            momentumRibbon(delay: 0.06, y: 0.2, width: 10.8, height: 1.45, peakOpacity: 0.16)
            momentumRibbon(delay: 0.12, y: 4.3, width: 7.8, height: 1.25, peakOpacity: 0.12)

            contactBridge(y: -1.2, width: 8.4, height: 1.15, peakOpacity: 0.24)
            contactBridge(y: 3.9, width: 5.8, height: 0.95, peakOpacity: 0.16)

            sparkAccent(delay: 0.16, originX: -6.0, y: -6.0, size: 2.1, peakOpacity: 0.30)
            sparkAccent(delay: 0.25, originX: -2.8, y: 6.2, size: 1.55, peakOpacity: 0.22)
            sparkAccent(delay: 0.34, originX: 2.8, y: -6.8, size: 1.25, peakOpacity: 0.18)
        }
        .frame(width: 32, height: 32)
        .scaleEffect(x: direction, y: 1)
        .allowsHitTesting(false)
    }

    private var internalPulseOpacity: Double {
        let launch = smoothStep(replacementPhase, start: 0.00, end: 0.18)
        let decay = 1 - smoothStep(replacementPhase, start: 0.46, end: 0.94)
        return Double(0.44 * launch * decay)
    }

    private var internalPulseScale: CGFloat {
        0.20 + 0.82 * smoothStep(replacementPhase, start: 0.00, end: 0.82)
    }

    private var internalRingOpacity: Double {
        let launch = smoothStep(replacementPhase, start: 0.10, end: 0.36)
        let decay = 1 - smoothStep(replacementPhase, start: 0.54, end: 0.98)
        return Double(0.52 * launch * decay)
    }

    private var internalRingScale: CGFloat {
        0.36 + 0.60 * smoothStep(replacementPhase, start: 0.10, end: 0.92)
    }

    private var clusterScale: CGFloat {
        let press = smoothStep(replacementPhase, start: 0.00, end: 0.08) * (1 - smoothStep(replacementPhase, start: 0.10, end: 0.20))
        let settle = pulse(replacementPhase, start: 0.78, duration: 0.18)
        return 1.0 - 0.12 * press + 0.024 * settle
    }

    private var clusterOffset: CGFloat {
        let press = smoothStep(replacementPhase, start: 0.00, end: 0.08) * (1 - smoothStep(replacementPhase, start: 0.10, end: 0.18))
        return -0.82 * press
    }

    private func playReplacementAnimation(perform action: @escaping () -> Void) {
        guard !reduceMotion else {
            action()
            return
        }

        animationSerial += 1
        let serial = animationSerial

        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            replacementPhase = 0
        }

        DispatchQueue.main.async {
            guard animationSerial == serial else { return }
            withAnimation(.timingCurve(0.08, 0.86, 0.12, 1.0, duration: 1.18)) {
                replacementPhase = 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.052) {
            action()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.36) {
            guard animationSerial == serial else { return }

            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                replacementPhase = 0
            }
        }
    }

    private func triangle(role: TriangleRole) -> some View {
        let metrics = triangleMetrics(for: role, phase: replacementPhase)

        return ZStack {
            Image(systemName: "play.fill")
                .font(.system(size: 13.6, weight: .semibold))
                .foregroundStyle(.white)

            Capsule(style: .continuous)
                .fill(Color.white.opacity(metrics.coreOpacity))
                .frame(width: 7.0, height: 2.0)
                .scaleEffect(x: metrics.coreScaleX, y: metrics.coreScaleY)
                .offset(x: metrics.coreX)
                .blur(radius: metrics.coreBlur)
                .mask {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13.6, weight: .semibold))
                        .scaleEffect(0.74)
                }
                .opacity(metrics.coreOpacity > 0 ? 1 : 0)
        }
            .scaleEffect(x: metrics.scaleX, y: metrics.scaleY)
            .offset(x: metrics.x)
            .blur(radius: metrics.blur)
            .brightness(metrics.brightness)
            .shadow(color: .white.opacity(metrics.opacity * 0.18), radius: 2.0, x: 0, y: 0)
            .opacity(metrics.opacity)
    }

    private func momentumRibbon(delay: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, peakOpacity: Double) -> some View {
        let metrics = momentumRibbonMetrics(delay: delay, peakOpacity: peakOpacity, phase: replacementPhase)

        return Capsule(style: .continuous)
            .fill(Color.white.opacity(metrics.opacity))
            .frame(width: width, height: height)
            .scaleEffect(x: metrics.scaleX, y: 1)
            .offset(x: metrics.x, y: y)
            .blur(radius: metrics.blur)
            .opacity(metrics.opacity > 0 ? 1 : 0)
    }

    private func contactBridge(y: CGFloat, width: CGFloat, height: CGFloat, peakOpacity: Double) -> some View {
        let metrics = contactBridgeMetrics(peakOpacity: peakOpacity, phase: replacementPhase)

        return Capsule(style: .continuous)
            .fill(Color.white.opacity(metrics.opacity))
            .frame(width: width, height: height)
            .scaleEffect(x: metrics.stretch, y: metrics.scale)
            .offset(x: metrics.x, y: y)
            .blur(radius: metrics.blur)
            .opacity(metrics.opacity > 0 ? 1 : 0)
    }

    private func sparkAccent(delay: CGFloat, originX: CGFloat, y: CGFloat, size: CGFloat, peakOpacity: Double) -> some View {
        let metrics = sparkMetrics(delay: delay, originX: originX, peakOpacity: peakOpacity, phase: replacementPhase)

        return Circle()
            .fill(Color.white.opacity(metrics.opacity))
            .frame(width: size, height: size)
            .scaleEffect(metrics.scale)
            .offset(x: metrics.x, y: y)
            .blur(radius: metrics.blur)
            .opacity(metrics.opacity > 0 ? 1 : 0)
    }

    private func momentumRibbonMetrics(delay: CGFloat, peakOpacity: Double, phase rawPhase: CGFloat) -> MomentumRibbonMetrics {
        let phase = min(max(rawPhase, 0), 1)
        let appear = smoothStep(phase, start: 0.10 + delay, end: 0.22 + delay)
        let vanish = smoothStep(phase, start: 0.58 + delay, end: 0.88 + delay)
        let travel = smoothStep(phase, start: 0.13 + delay, end: 0.48 + delay)
        let recoil = smoothStep(phase, start: 0.56 + delay, end: 0.74 + delay)
        let inertia = pulse(phase, start: 0.36 + delay, duration: 0.18)
        let pullback = pulse(phase, start: 0.56 + delay, duration: 0.22)
        let settle = pulse(phase, start: 0.76 + delay, duration: 0.16)
        let active = appear * (1 - vanish)

        return MomentumRibbonMetrics(
            x: -5.2 + 10.4 * travel - 1.08 * recoil + 0.82 * inertia - 0.66 * pullback + 0.14 * settle,
            opacity: Double(CGFloat(peakOpacity) * active),
            scaleX: 0.18 + 0.88 * travel + 0.18 * inertia - 0.18 * pullback + 0.04 * settle,
            blur: 0.35 * (1 - active)
        )
    }

    private func contactBridgeMetrics(peakOpacity: Double, phase rawPhase: CGFloat) -> InteriorCueMetrics {
        let phase = min(max(rawPhase, 0), 1)
        let appear = smoothStep(phase, start: 0.64, end: 0.70)
        let vanish = smoothStep(phase, start: 0.88, end: 1.0)
        let followThrough = pulse(phase, start: 0.66, duration: 0.16)
        let pullback = pulse(phase, start: 0.80, duration: 0.16)
        let rebound = pulse(phase, start: 0.91, duration: 0.09)
        let active = appear * (1 - vanish)

        return InteriorCueMetrics(
            x: 1.25 * followThrough - 1.45 * pullback + 0.28 * rebound,
            opacity: Double(CGFloat(peakOpacity) * active),
            scale: 1.0,
            stretch: 1.0,
            blur: 0.16 * (1 - active)
        )
    }

    private func sparkMetrics(delay: CGFloat, originX: CGFloat, peakOpacity: Double, phase rawPhase: CGFloat) -> SparkMetrics {
        let phase = min(max(rawPhase, 0), 1)
        let appear = smoothStep(phase, start: 0.12 + delay, end: 0.22 + delay)
        let vanish = smoothStep(phase, start: 0.46 + delay, end: 0.70 + delay)
        let travel = smoothStep(phase, start: 0.14 + delay, end: 0.44 + delay)
        let recoil = smoothStep(phase, start: 0.52 + delay, end: 0.68 + delay)
        let pop = pulse(phase, start: 0.18 + delay, duration: 0.20)
        let pullback = pulse(phase, start: 0.54 + delay, duration: 0.20)
        let active = appear * (1 - vanish)

        return SparkMetrics(
            x: originX + 7.4 * travel - 1.4 * recoil + 0.58 * pop - 0.46 * pullback,
            opacity: Double(CGFloat(peakOpacity) * active),
            scale: max(0.2, 0.34 + 0.78 * pop - 0.22 * pullback),
            blur: 0.18 * (1 - active)
        )
    }

    private func triangleMetrics(for role: TriangleRole, phase rawPhase: CGFloat) -> TriangleMetrics {
        let phase = min(max(rawPhase, 0), 1)
        let rearSlot: CGFloat = -4.9
        let frontSlot: CGFloat = 4.9
        let slotDistance = frontSlot - rearSlot
        let press = pulse(phase, start: 0.00, duration: 0.16)
        let advance = smoothStep(phase, start: 0.18, end: 0.58)
        let arrivalOvershoot = pulse(phase, start: 0.46, duration: 0.20)
        let pullback = pulse(phase, start: 0.60, duration: 0.18)
        let settle = pulse(phase, start: 0.74, duration: 0.14)

        switch role {
        case .frontExit:
            let exit = smoothStep(phase, start: 0.08, end: 0.40)
            let collapse = smoothStep(phase, start: 0.10, end: 0.42)
            let fade = smoothStep(phase, start: 0.28, end: 0.48)
            let squash = pulse(phase, start: 0.08, duration: 0.18)
            return TriangleMetrics(
                x: frontSlot - 0.36 * press + 8.4 * exit,
                opacity: Double(1 - fade),
                scaleX: max(0.08, 1.0 + 0.18 * squash - 0.92 * collapse),
                scaleY: max(0.12, 1.0 - 0.12 * squash - 0.82 * collapse),
                blur: 0.34 * collapse,
                brightness: Double(0.10 * press + 0.10 * squash),
                coreOpacity: Double(0.22 * (1 - fade) * (1 - collapse)),
                coreX: -0.65 * collapse,
                coreScaleX: max(0.12, 0.86 - 0.62 * collapse),
                coreScaleY: max(0.18, 0.72 - 0.42 * collapse),
                coreBlur: 0.10 + 0.18 * collapse
            )

        case .backAdvance:
            let overshoot = 1.55 * arrivalOvershoot
            let recoil = -1.48 * pullback + 0.18 * settle
            return TriangleMetrics(
                x: rearSlot - 0.24 * press + slotDistance * advance + overshoot + recoil,
                opacity: 1.0,
                scaleX: 1.0,
                scaleY: 1.0,
                blur: 0.0,
                brightness: Double(0.08 * arrivalOvershoot),
                coreOpacity: Double(0.12 + 0.18 * arrivalOvershoot * (1 - smoothStep(phase, start: 0.78, end: 0.92))),
                coreX: -0.40 + 0.50 * arrivalOvershoot - 0.40 * pullback + 0.10 * settle,
                coreScaleX: 0.72,
                coreScaleY: 0.64,
                coreBlur: 0.05
            )

        case .incoming:
            let enter = smoothStep(phase, start: 0.18, end: 0.58)
            let fade = smoothStep(phase, start: 0.14, end: 0.26)
            let grow = smoothStep(phase, start: 0.18, end: 0.52)
            let arrivalPop = pulse(phase, start: 0.42, duration: 0.18)
            let overshoot = 1.55 * arrivalOvershoot
            let recoil = -1.48 * pullback + 0.18 * settle
            return TriangleMetrics(
                x: rearSlot - 8.8 + 8.8 * enter + overshoot + recoil,
                opacity: Double(fade),
                scaleX: max(0.08, 0.08 + 0.92 * grow + 0.18 * arrivalPop),
                scaleY: max(0.10, 0.12 + 0.88 * grow + 0.12 * arrivalPop),
                blur: 0.26 * (1 - enter),
                brightness: Double(0.14 * fade + 0.08 * arrivalPop + 0.08 * arrivalOvershoot),
                coreOpacity: Double(0.22 * fade * arrivalOvershoot * (1 - smoothStep(phase, start: 0.78, end: 0.92))),
                coreX: 0.40 - 0.50 * arrivalOvershoot + 0.40 * pullback - 0.10 * settle,
                coreScaleX: 0.68,
                coreScaleY: 0.62,
                coreBlur: 0.05
            )
        }
    }

    private func smoothStep(_ value: CGFloat, start: CGFloat = 0, end: CGFloat = 1) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func pulse(_ value: CGFloat, start: CGFloat, duration: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let t = min(max((value - start) / duration, 0), 1)
        return sin(CGFloat.pi * t)
    }
}

private struct SkipPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.78 : 1.0)
            .opacity(1.0)
            .animation(
                reduceMotion ? nil : .interpolatingSpring(mass: 0.75, stiffness: 520, damping: 18, initialVelocity: 0),
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
