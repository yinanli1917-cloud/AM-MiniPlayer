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
    let timePublisher: TimePublisher
    @Binding var currentPage: PlayerPage
    @Binding var isHovering: Bool
    @Binding var showControls: Bool
    @Binding var isProgressBarHovering: Bool
    @Binding var dragPosition: CGFloat?
    var onControlsHoverChanged: ((Bool) -> Void)? = nil  // 🔑 可选回调：控件hover状态变化
    var translationButton: AnyView? = nil  // 🔑 可选的翻译按钮
    @State private var isControlAreaHovering: Bool = false  // 🔑 整个控件区域的hover状态
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = controlInk
        let subduedInk = controlInk.opacity(lightControlSurface ? 0.62 : 0.68)
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
                PlaybackProgressSection(
                    timePublisher: timePublisher,
                    isProgressBarHovering: $isProgressBarHovering,
                    dragPosition: $dragPosition,
                    ink: ink,
                    subduedInk: subduedInk,
                    shadowColor: controlShadowColor,
                    shadowRadius: controlShadowRadius,
                    lightControlSurface: lightControlSurface,
                    reduceMotion: reduceMotion
                )

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
                .foregroundStyle(ink)
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
            isActive: currentPage == .lyrics,
            inkColor: controlInk,
            hoverFill: controlInk.opacity(lightControlSurface ? 0.12 : 0.22)
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
            }, direction: -1, inkColor: controlInk, hoverFill: controlInk.opacity(lightControlSurface ? 0.10 : 0.18), beginDiagnostics: {
                beginPlaybackInteraction(.previousTrack)
            }, finishDiagnostics: { id, status, detail in
                finishPlaybackInteraction(id, status: status, detail: detail)
            })
            .frame(width: 30, height: 30)
            .accessibilityLabel("上一首")

            PlayPauseControlButton(
                isPlaying: musicController.isPlaying,
                inkColor: controlInk,
                hoverFill: controlInk.opacity(lightControlSurface ? 0.12 : 0.22)
            ) {
                musicController.togglePlayPause()
            }
            .frame(width: 30, height: 30)
            .accessibilityLabel(musicController.isPlaying ? "暂停" : "播放")

            SkipControlButton(action: {
                musicController.nextTrack()
            }, direction: 1, inkColor: controlInk, hoverFill: controlInk.opacity(lightControlSurface ? 0.10 : 0.18), beginDiagnostics: {
                beginPlaybackInteraction(.nextTrack)
            }, finishDiagnostics: { id, status, detail in
                finishPlaybackInteraction(id, status: status, detail: detail)
            })
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
            isActive: currentPage == .playlist,
            inkColor: controlInk,
            hoverFill: controlInk.opacity(lightControlSurface ? 0.12 : 0.22)
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


    private var lightControlSurface: Bool {
        false
    }

    private var controlInk: Color {
        Color.white
    }

    private var controlShadowColor: Color {
        Color.black.opacity(0.35 + 0.28 * musicController.controlAreaLuminance)
    }

    private var controlShadowRadius: CGFloat {
        2 + 5 * musicController.controlAreaLuminance
    }

    private func beginPlaybackInteraction(_ type: DiagnosticInteractionType) -> UUID? {
        let page = String(describing: currentPage)
        var metrics = musicController.diagnosticsLyricsWorkloadMetrics()
        metrics["skipAnimationDurationMs"] = 600
        var evidence = musicController.diagnosticsLyricsWorkloadEvidence()
        evidence["animation"] = "SkipControlButton.replacementFlow"
        evidence["pageAtStart"] = page
        return DiagnosticsService.shared.beginInteraction(
            type: type,
            page: page,
            expectedDuration: 0.60,
            track: musicController.diagnosticsTrackContext(),
            metrics: metrics,
            evidence: evidence
        )
    }

    private func finishPlaybackInteraction(
        _ id: UUID?,
        status: DiagnosticInteractionStatus,
        detail: String?
    ) {
        var metrics = musicController.diagnosticsLyricsWorkloadMetrics()
        metrics["skipAnimationFinished"] = status == .completed ? 1 : 0
        var evidence = musicController.diagnosticsLyricsWorkloadEvidence()
        evidence["pageAtFinish"] = String(describing: currentPage)
        DiagnosticsService.shared.completeInteraction(
            id,
            status: status,
            detail: detail,
            metrics: metrics,
            evidence: evidence
        )
    }
}

private struct PlaybackProgressSection: View {
    @EnvironmentObject var musicController: MusicController
    @ObservedObject var timePublisher: TimePublisher
    @Binding var isProgressBarHovering: Bool
    @Binding var dragPosition: CGFloat?
    let ink: Color
    let subduedInk: Color
    let shadowColor: Color
    let shadowRadius: CGFloat
    let lightControlSurface: Bool
    let reduceMotion: Bool

    var body: some View {
        let currentTime = timePublisher.currentTime
        let duration = musicController.duration
        VStack(spacing: 2) {
            progressBar(currentTime: currentTime, duration: duration)

            HStack {
                Text(formatTime(currentTime))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(subduedInk)
                    .shadow(color: shadowColor, radius: shadowRadius)
                    .accessibilityHidden(true)

                Spacer()

                if let quality = musicController.audioQuality {
                    qualityBadge(quality)
                }

                Spacer()

                Text("-" + formatTime(duration - currentTime))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(subduedInk)
                    .shadow(color: shadowColor, radius: shadowRadius)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
        }
    }

    private func progressBar(currentTime: Double, duration: Double) -> some View {
        let barHeight: CGFloat = isProgressBarHovering ? 12 : 7  // 🔑 hover前7px，hover后12px

        return GeometryReader { geo in
            let currentProgress: CGFloat = {
                if duration > 0 {
                    return dragPosition ?? CGFloat(currentTime / duration)
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
                    .fill(ink.opacity(lightControlSurface ? 0.78 : 1.0))
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
        }
        .frame(height: 14)  // 🔑 容器高度略大于最大bar高度，确保居中效果
        .padding(.horizontal, 20)  // 🔑 进度条额外padding
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(formatTime(currentTime)) / \(formatTime(duration))")
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
        .foregroundStyle(ink.opacity(0.9))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("音频质量：\(quality)")
    }

    private func formatTime(_ time: Double) -> String {
        let totalSeconds = max(0, Int(time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds < 10 ? "\(minutes):0\(seconds)" : "\(minutes):\(seconds)"
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

private struct PlayPauseControlButton: View {
    let isPlaying: Bool
    let inkColor: Color
    let hoverFill: Color
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovering ? hoverFill : Color.clear)

                ZStack {
                    Image(systemName: "play.fill")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(inkColor)
                        .offset(x: 1.0)
                        .scaleEffect(isPlaying ? 0.82 : 1.0)
                        .opacity(isPlaying ? 0.0 : 1.0)

                    Image(systemName: "pause.fill")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(inkColor)
                        .scaleEffect(isPlaying ? 1.0 : 0.82)
                        .opacity(isPlaying ? 1.0 : 0.0)
                }
                .frame(width: 32, height: 32)
                .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isPlaying)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(PlayPausePressStyle(reduceMotion: reduceMotion))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

private struct PlayPausePressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.86 : 1.0)
            .animation(
                reduceMotion ? nil : .interpolatingSpring(mass: 0.75, stiffness: 560, damping: 22, initialVelocity: 0),
                value: configuration.isPressed
            )
    }
}

// MARK: - Skip Control Button (Replacement Flow Micro-Interaction)

struct SkipControlButton: View {
    let action: () -> Void
    let direction: CGFloat
    let inkColor: Color
    let hoverFill: Color
    var beginDiagnostics: (() -> UUID?)? = nil
    var finishDiagnostics: ((UUID?, DiagnosticInteractionStatus, String?) -> Void)? = nil

    @State private var isHovering = false
    @State private var replacementStart: Date?
    @State private var animationSerial = 0
    @State private var activeDiagnosticID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let replacementDuration: TimeInterval = 0.60

    var body: some View {
        Button {
            playReplacementAnimation(perform: action)
        } label: {
            skipGlyphLabel
        }
        .buttonStyle(SkipPressStyle(reduceMotion: reduceMotion))
        .frame(width: 32, height: 32)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .onDisappear {
            finishActiveAnimationAsInterrupted(
                "Skip animation view disappeared before the replacement flow completed."
            )
        }
    }

    @ViewBuilder
    private var skipGlyphLabel: some View {
        if replacementStart != nil {
            TimelineView(.animation) { timeline in
                skipGlyph(phase: replacementPhase(at: timeline.date))
            }
        } else {
            skipGlyph(phase: 0)
        }
    }

    private func skipGlyph(phase: CGFloat) -> some View {
        let hoverOpacity = isHovering ? 1.0 : 0.0

        return ZStack {
            Circle()
                .fill(hoverFill.opacity(hoverOpacity))

            ZStack {
                triangle(role: .incoming, phase: phase)
                triangle(role: .backAdvance, phase: phase)
                triangle(role: .frontExit, phase: phase)
            }
            .frame(width: 32, height: 32)
            .scaleEffect(clusterScale(phase: phase))
            .offset(x: clusterOffset(phase: phase))
            .scaleEffect(x: direction, y: 1)
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    private func replacementPhase(at date: Date) -> CGFloat {
        guard let replacementStart else { return 0 }
        return min(max(CGFloat(date.timeIntervalSince(replacementStart) / replacementDuration), 0), 1)
    }

    private enum TriangleRole {
        case frontExit, backAdvance, incoming
    }

    private struct TriangleMetrics {
        let x: CGFloat
        let y: CGFloat
        let opacity: Double
        let scaleX: CGFloat
        let scaleY: CGFloat
        let blur: CGFloat
        let brightness: Double
    }

    private func clusterScale(phase: CGFloat) -> CGFloat {
        let pressSink = asymmetricGlide(phase, start: 0.00, peak: 0.075, end: 0.22)
        let compression = arrivalCompression(phase)
        let bloom = arrivalScaleBloom(phase)
        return 1.0 - 0.082 * pressSink - 0.020 * compression + 0.018 * bloom
    }

    private func clusterOffset(phase: CGFloat) -> CGFloat {
        let pressSink = asymmetricGlide(phase, start: 0.00, peak: 0.075, end: 0.22)
        return -0.24 * pressSink
    }

    private func playReplacementAnimation(perform action: @escaping () -> Void) {
        if let activeDiagnosticID {
            finishDiagnostics?(
                activeDiagnosticID,
                .interrupted,
                "Skip animation was replaced by another skip request before it completed."
            )
            self.activeDiagnosticID = nil
        }

        let diagnosticID = beginDiagnostics?()
        activeDiagnosticID = diagnosticID

        guard !reduceMotion else {
            action()
            finishDiagnostics?(diagnosticID, .completed, "Reduced motion path completed without replacement animation.")
            activeDiagnosticID = nil
            return
        }

        animationSerial += 1
        let serial = animationSerial

        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            replacementStart = nil
        }

        DispatchQueue.main.async {
            guard animationSerial == serial else { return }
            var start = Transaction()
            start.disablesAnimations = true
            withTransaction(start) {
                replacementStart = Date()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            action()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + replacementDuration + 0.08) {
            guard animationSerial == serial else { return }

            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                replacementStart = nil
            }
            finishDiagnostics?(diagnosticID, .completed, nil)
            if activeDiagnosticID == diagnosticID {
                activeDiagnosticID = nil
            }
        }
    }

    private func finishActiveAnimationAsInterrupted(_ detail: String) {
        guard let activeDiagnosticID else { return }
        animationSerial += 1
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            replacementStart = nil
        }
        finishDiagnostics?(activeDiagnosticID, .interrupted, detail)
        self.activeDiagnosticID = nil
    }

    private func triangle(role: TriangleRole, phase: CGFloat) -> some View {
        let metrics = triangleMetrics(for: role, phase: phase)

        return Image(systemName: "play.fill")
            .font(.system(size: 13.6, weight: .semibold))
            .foregroundStyle(inkColor)
            .scaleEffect(x: metrics.scaleX, y: metrics.scaleY)
            .offset(x: metrics.x, y: metrics.y)
            .blur(radius: metrics.blur)
            .brightness(metrics.brightness)
            .opacity(metrics.opacity)
    }

    private func triangleMetrics(for role: TriangleRole, phase rawPhase: CGFloat) -> TriangleMetrics {
        let phase = min(max(rawPhase, 0), 1)
        let rearSlot: CGFloat = -4.9
        let frontSlot: CGFloat = 4.9
        let slotDistance = frontSlot - rearSlot
        let pressSink = asymmetricGlide(phase, start: 0.00, peak: 0.075, end: 0.22)
        let touchScale = 1.0 - 0.038 * pressSink
        let compression = arrivalCompression(phase)
        let scaleBloom = arrivalScaleBloom(phase)
        let pairDrift = pairedOvershoot(phase)
        let pairCompression = pairSpacingCompression(phase)
        let pairReleaseOvershoot = pairSpacingRelease(phase)

        switch role {
        case .frontExit:
            let anticipate = asymmetricGlide(phase, start: 0.02, peak: 0.10, end: 0.21)
            let exit = easeInOutSmoother(phase, start: 0.09, end: 0.44)
            let fade = easeInOutSmoother(phase, start: 0.26, end: 0.46)
            let collapse = easeInOutSmoother(phase, start: 0.11, end: 0.42)
            let float = asymmetricGlide(phase, start: 0.08, peak: 0.22, end: 0.44)
            return TriangleMetrics(
                x: frontSlot - 0.28 * anticipate + 20.80 * exit,
                y: -0.012 * pressSink - 0.040 * float,
                opacity: Double(1 - fade),
                scaleX: max(0.22, touchScale * (1.0 + 0.060 * anticipate - 0.760 * collapse)),
                scaleY: max(0.24, touchScale * (1.0 - 0.040 * anticipate - 0.660 * collapse)),
                blur: 0.06 * exit,
                brightness: Double(0.003 * anticipate)
            )

        case .backAdvance:
            let anticipate = asymmetricGlide(phase, start: 0.04, peak: 0.12, end: 0.22)
            let advance = easeInOutSmoother(phase, start: 0.11, end: 0.58)
            let carryStretch = asymmetricGlide(phase, start: 0.18, peak: 0.36, end: 0.58)
            let compressedX = 1.0 - 0.086 * compression
            let compressedY = 1.0 - 0.076 * compression
            return TriangleMetrics(
                x: rearSlot - 0.18 * anticipate + slotDistance * advance + pairDrift - pairCompression + pairReleaseOvershoot,
                y: -0.008 * pressSink,
                opacity: 1.0,
                scaleX: touchScale * (compressedX - 0.018 * anticipate + 0.020 * carryStretch + 0.034 * scaleBloom),
                scaleY: touchScale * (compressedY - 0.026 * anticipate - 0.006 * carryStretch + 0.026 * scaleBloom),
                blur: 0.0,
                brightness: Double(0.002 * scaleBloom)
            )

        case .incoming:
            let enter = easeInOutSmoother(phase, start: 0.15, end: 0.58)
            let fade = easeInOutSmoother(phase, start: 0.19, end: 0.40)
            let grow = easeInOutSmoother(phase, start: 0.15, end: 0.56)
            let travelStretch = asymmetricGlide(phase, start: 0.20, peak: 0.38, end: 0.58)
            return TriangleMetrics(
                x: rearSlot - 20.80 + 20.80 * enter + pairDrift + pairCompression - pairReleaseOvershoot,
                y: -0.006 * pressSink,
                opacity: Double(fade),
                scaleX: max(0.28, touchScale * (0.30 + 0.70 * grow + 0.042 * travelStretch - 0.094 * compression + 0.042 * scaleBloom)),
                scaleY: max(0.30, touchScale * (0.32 + 0.68 * grow - 0.016 * travelStretch - 0.080 * compression + 0.032 * scaleBloom)),
                blur: 0.08 * (1 - enter),
                brightness: Double(0.003 * fade + 0.002 * scaleBloom)
            )
        }
    }

    private func pairedOvershoot(_ phase: CGFloat) -> CGFloat {
        0.52 * arrivalPositionCarry(phase)
    }

    private func pairSpacingCompression(_ phase: CGFloat) -> CGFloat {
        1.45 * arrivalCompression(phase)
    }

    private func pairSpacingRelease(_ phase: CGFloat) -> CGFloat {
        0.30 * arrivalSpacingBloom(phase)
    }

    private func arrivalCompression(_ phase: CGFloat) -> CGFloat {
        let form = smootherStep(phase, start: 0.30, end: 0.48)
        let release = smootherStep(phase, start: 0.48, end: 0.62)
        return form * (1 - release)
    }

    private func arrivalPositionCarry(_ phase: CGFloat) -> CGFloat {
        asymmetricGlide(phase, start: 0.54, peak: 0.66, end: 0.94)
    }

    private func arrivalScaleBloom(_ phase: CGFloat) -> CGFloat {
        asymmetricGlide(phase, start: 0.56, peak: 0.74, end: 1.00)
    }

    private func arrivalSpacingBloom(_ phase: CGFloat) -> CGFloat {
        asymmetricGlide(phase, start: 0.58, peak: 0.80, end: 1.00)
    }

    private func pairFormation(_ phase: CGFloat) -> CGFloat {
        smootherStep(phase, start: 0.34, end: 0.48)
    }

    private func tailCompletion(_ phase: CGFloat, delay: CGFloat = 0) -> CGFloat {
        smootherStep(phase, start: 0.48 + delay, end: 0.76 + delay)
    }

    private func tailOvershoot(_ phase: CGFloat, delay: CGFloat = 0) -> CGFloat {
        asymmetricGlide(phase, start: 0.58 + delay, peak: 0.76 + delay, end: 0.98 + delay)
    }

    private func unitProgress(_ value: CGFloat, start: CGFloat, end: CGFloat) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        return min(max((value - start) / (end - start), 0), 1)
    }

    private func smootherStep(_ value: CGFloat, start: CGFloat = 0, end: CGFloat = 1) -> CGFloat {
        let t = unitProgress(value, start: start, end: end)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func easeInOutSmoother(_ value: CGFloat, start: CGFloat, end: CGFloat) -> CGFloat {
        smootherStep(value, start: start, end: end)
    }

    private func asymmetricGlide(_ value: CGFloat, start: CGFloat, peak: CGFloat, end: CGFloat) -> CGFloat {
        guard start < peak, peak < end else { return 0 }
        if value <= peak {
            return smootherStep(value, start: start, end: peak)
        }
        return 1 - smootherStep(value, start: peak, end: end)
    }
}

private struct SkipPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.90 : 1.0)
            .opacity(1.0)
            .animation(
                reduceMotion ? nil : .interpolatingSpring(mass: 1.0, stiffness: 400, damping: 28, initialVelocity: 0),
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

// MARK: - Animated Shuffle Icon

struct AnimatedShuffleIcon: View {
    let color: Color
    let isEnabled: Bool
    var size: CGFloat = 11
    var weight: Font.Weight = .semibold

    @State private var commitTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ShuffleCrossGlyph(
            color: color,
            size: size,
            weight: weight,
            values: ShuffleDrawValues()
        )
        .keyframeAnimator(
            initialValue: ShuffleDrawValues(),
            trigger: commitTrigger
        ) { _, value in
            ShuffleCrossGlyph(
                color: color,
                size: size,
                weight: weight,
                values: value
            )
        } keyframes: { _ in
            KeyframeTrack(\.phase) {
                MoveKeyframe(0.0)
                CubicKeyframe(0.18, duration: 0.055)
                CubicKeyframe(0.76, duration: 0.155)
                CubicKeyframe(1.0, duration: 0.105)
            }
            KeyframeTrack(\.glyphScale) {
                MoveKeyframe(0.94)
                CubicKeyframe(0.965, duration: 0.055)
                CubicKeyframe(1.014, duration: 0.165)
                SpringKeyframe(1.0, duration: 0.160, spring: .init(response: 0.28, dampingRatio: 0.90))
            }
        }
        .onChange(of: isEnabled) { _, _ in
            guard !reduceMotion else { return }
            commitTrigger += 1
        }
    }
}

private struct ShuffleDrawValues {
    var phase: CGFloat = 1.0
    var glyphScale: CGFloat = 1.0
}

private struct ShuffleCrossGlyph: View {
    let color: Color
    let size: CGFloat
    let weight: Font.Weight
    let values: ShuffleDrawValues

    private var glyphWidth: CGFloat {
        max(size * 1.68, 16)
    }

    private var glyphHeight: CGFloat {
        max(size * 1.44, 13)
    }

    var body: some View {
        Image(systemName: "shuffle")
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .frame(width: glyphWidth, height: glyphHeight)
            .mask(
                ShuffleSymbolRevealMask(
                    size: size,
                    weight: weight,
                    phase: values.phase
                )
                .frame(width: glyphWidth, height: glyphHeight)
            )
            .scaleEffect(values.glyphScale)
            .frame(width: glyphWidth, height: glyphHeight)
    }
}

private struct ShuffleSymbolRevealMask: View {
    let size: CGFloat
    let weight: Font.Weight
    let phase: CGFloat

    private var glyphWidth: CGFloat {
        max(size * 1.68, 16)
    }

    private var glyphHeight: CGFloat {
        max(size * 1.44, 13)
    }

    var body: some View {
        let lineWidth = revealWidth(for: size, weight: weight)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let headStyle = StrokeStyle(lineWidth: lineWidth * 1.12, lineCap: .round, lineJoin: .round)
        let leadMotion = strokeMotion(start: 0.00, end: 0.80)
        let trailMotion = strokeMotion(start: 0.17, end: 1.00)

        ZStack {
            routeLayer(route: .topToBottom, motion: leadMotion, style: style, headStyle: headStyle)
            routeLayer(route: .bottomToTop, motion: trailMotion, style: style, headStyle: headStyle)

            Image(systemName: "shuffle")
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white)
                .opacity(Double(smootherStep(phase, start: 0.985, end: 1.0)))
        }
        .frame(width: glyphWidth, height: glyphHeight)
    }

    @ViewBuilder
    private func routeLayer(
        route: ShuffleRoute,
        motion: ShuffleStrokeMotion,
        style: StrokeStyle,
        headStyle: StrokeStyle
    ) -> some View {
        ShuffleRouteShape(route: route)
            .trim(from: 0, to: motion.inkEnd)
            .stroke(.white, style: style)
            .opacity(motion.inkOpacity)

        ShuffleRouteShape(route: route)
            .trim(from: motion.headStart, to: motion.headEnd)
            .stroke(.white, style: headStyle)
            .opacity(motion.headOpacity)

        ShuffleArrowWingShape(route: route, wing: .upper)
            .trim(from: 0, to: motion.upperWing)
            .stroke(.white, style: style)
            .opacity(motion.wingOpacity)

        ShuffleArrowWingShape(route: route, wing: .lower)
            .trim(from: 0, to: motion.lowerWing)
            .stroke(.white, style: style)
            .opacity(motion.wingOpacity)
    }

    private func revealWidth(for size: CGFloat, weight: Font.Weight) -> CGFloat {
        let base = max(size * 0.31, 3.4)
        switch weight {
        case .regular:
            return base - 0.18
        case .medium:
            return base - 0.08
        case .semibold:
            return base
        case .bold, .heavy, .black:
            return base + 0.18
        default:
            return base
        }
    }

    private func strokeMotion(start: CGFloat, end: CGFloat) -> ShuffleStrokeMotion {
        let local = unitProgress(phase, start: start, end: end)
        let travel = smootherStep(local, start: 0.00, end: 0.86)
        let tailLag = 0.120 - 0.055 * smootherStep(local, start: 0.30, end: 0.78)
        let headLength = 0.225 - 0.075 * smootherStep(local, start: 0.22, end: 0.72)
        let inkEnd = clamped(travel - tailLag * (1 - smootherStep(local, start: 0.82, end: 1.00)))
        let headStart = clamped(travel - headLength)
        let headVisibility = smootherStep(local, start: 0.02, end: 0.16) * (1 - smootherStep(local, start: 0.82, end: 1.00))
        let upperWing = smootherStep(local, start: 0.72, end: 0.93)
        let lowerWing = smootherStep(local, start: 0.78, end: 0.98)
        let wingOpacity = smootherStep(local, start: 0.70, end: 0.86)

        return ShuffleStrokeMotion(
            inkEnd: local >= 1 ? 1 : inkEnd,
            headStart: local >= 1 ? 1 : headStart,
            headEnd: local >= 1 ? 1 : travel,
            headOpacity: Double(headVisibility),
            upperWing: upperWing,
            lowerWing: lowerWing,
            wingOpacity: Double(wingOpacity),
            inkOpacity: Double(0.74 + smootherStep(local, start: 0.06, end: 0.28) * 0.26)
        )
    }

    private func unitProgress(_ value: CGFloat, start: CGFloat, end: CGFloat) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        return clamped((value - start) / (end - start))
    }

    private func smootherStep(_ value: CGFloat, start: CGFloat = 0, end: CGFloat = 1) -> CGFloat {
        let t = unitProgress(value, start: start, end: end)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct ShuffleStrokeMotion {
    let inkEnd: CGFloat
    let headStart: CGFloat
    let headEnd: CGFloat
    let headOpacity: Double
    let upperWing: CGFloat
    let lowerWing: CGFloat
    let wingOpacity: Double
    let inkOpacity: Double
}

private enum ShuffleRoute {
    case topToBottom
    case bottomToTop
}

private struct ShuffleRouteShape: Shape {
    let route: ShuffleRoute

    func path(in rect: CGRect) -> Path {
        let leftX = rect.minX + rect.width * 0.06
        let leadX = rect.minX + rect.width * 0.25
        let tipX = rect.minX + rect.width * 0.94
        let topY = rect.minY + rect.height * 0.33
        let bottomY = rect.minY + rect.height * 0.67

        var path = Path()

        switch route {
        case .topToBottom:
            path.move(to: CGPoint(x: leftX, y: topY))
            path.addLine(to: CGPoint(x: leadX, y: topY))
            path.addCurve(
                to: CGPoint(x: tipX, y: bottomY),
                control1: CGPoint(x: rect.minX + rect.width * 0.42, y: topY),
                control2: CGPoint(x: rect.minX + rect.width * 0.60, y: bottomY)
            )
        case .bottomToTop:
            path.move(to: CGPoint(x: leftX, y: bottomY))
            path.addLine(to: CGPoint(x: leadX, y: bottomY))
            path.addCurve(
                to: CGPoint(x: tipX, y: topY),
                control1: CGPoint(x: rect.minX + rect.width * 0.42, y: bottomY),
                control2: CGPoint(x: rect.minX + rect.width * 0.60, y: topY)
            )
        }

        return path
    }
}

private enum ShuffleArrowWing {
    case upper
    case lower
}

private struct ShuffleArrowWingShape: Shape {
    let route: ShuffleRoute
    let wing: ShuffleArrowWing

    func path(in rect: CGRect) -> Path {
        let tipX = rect.minX + rect.width * 0.94
        let wingX = rect.minX + rect.width * 0.78
        let wingOffsetY = rect.height * 0.145
        let centerY: CGFloat

        switch route {
        case .topToBottom:
            centerY = rect.minY + rect.height * 0.68
        case .bottomToTop:
            centerY = rect.minY + rect.height * 0.32
        }

        let wingY: CGFloat
        switch wing {
        case .upper:
            wingY = centerY - wingOffsetY
        case .lower:
            wingY = centerY + wingOffsetY
        }

        var path = Path()
        path.move(to: CGPoint(x: wingX, y: wingY))
        path.addLine(to: CGPoint(x: tipX, y: centerY))
        return path
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
    let inkColor: Color
    let hoverFill: Color
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 15))
                .foregroundStyle(inkColor)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill((isActive || isHovering) ? hoverFill : Color.clear)
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
