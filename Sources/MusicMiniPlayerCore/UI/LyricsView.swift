import SwiftUI
import AppKit
import Glur

public struct LyricsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    @State private var isHovering: Bool = false
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var isManualScrolling: Bool = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var showControls: Bool = true
    @State private var lastDragLocation: CGFloat = 0
    @State private var dragVelocity: CGFloat = 0
    @State private var wasFastScrolling: Bool = false  // 🔑 防抖：追踪是否刚经历快速滚动
    @State private var showLoadingDots: Bool = false
    @Binding var currentPage: PlayerPage
    var openWindow: OpenWindowAction?
    var onHide: (() -> Void)?
    var onExpand: (() -> Void)?
    @State private var lastVelocity: CGFloat = 0  // 记录上一次速度
    @State private var scrollLocked: Bool = false  // 🔑 锁定快速滚动状态，防止检测衰减速度
    @State private var hasTriggeredSlowScroll: Bool = false  // 🔑 慢速滚动是否已触发过控件显示

    // 🐛 调试窗口状态
    @State private var showDebugWindow: Bool = false
    @State private var debugMessages: [String] = []

    public init(currentPage: Binding<PlayerPage>, openWindow: OpenWindowAction? = nil, onHide: (() -> Void)? = nil, onExpand: (() -> Void)? = nil) {
        self._currentPage = currentPage
        self.openWindow = openWindow
        self.onHide = onHide
        self.onExpand = onExpand
    }

    private func addDebugMessage(_ message: String) {
        debugMessages.append(message)
        if debugMessages.count > 100 {
            debugMessages.removeFirst(50)
        }
    }

    public var body: some View {
        ZStack {
            // Background (Liquid Glass) - same as MiniPlayerView
            LiquidBackgroundView(artwork: musicController.currentArtwork)
            .ignoresSafeArea()

            // Main lyrics container
            VStack(spacing: 0) {
                if lyricsService.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundColor(.white)
                        .overlay(
                            Group {
                                if showControls {
                                    controlBar
                                }
                            }
                        )
                } else if let error = lyricsService.error {
                    VStack(spacing: 12) {  // 🔑 缩小: 16→12
                        Image(systemName: "music.note")
                            .font(.system(size: 36))  // 🔑 缩小: 48→36
                            .foregroundColor(.white.opacity(0.3))
                        Text(error)
                            .font(.system(size: 13, weight: .medium))  // 🔑 缩小: 16→13
                            .foregroundColor(.white.opacity(0.5))

                        // Retry button
                        Button(action: {
                            lyricsService.fetchLyrics(
                                for: musicController.currentTrackTitle,
                                artist: musicController.currentArtist,
                                duration: musicController.duration,
                                forceRefresh: true
                            )
                        }) {
                            HStack(spacing: 5) {  // 🔑 缩小: 6→5
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))  // 🔑 缩小: 12→10
                                Text("Retry")
                                    .font(.system(size: 12, weight: .semibold))  // 🔑 缩小: 14→12
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)  // 🔑 缩小: 20→16
                            .padding(.vertical, 8)  // 🔑 缩小: 10→8
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(6)  // 🔑 缩小: 8→6
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .overlay(
                        Group {
                            if showControls {
                                controlBar
                            }
                        }
                    )
                } else if lyricsService.lyrics.isEmpty {
                    emptyStateView
                        .overlay(
                            Group {
                                if showControls {
                                    controlBar
                                }
                            }
                        )
                } else {
                    // Lyrics scroll view - controls must be OUTSIDE as overlay
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 20) {  // 恢复原来的20px spacing
                                // Top spacer for centering first lyrics
                                Spacer()
                                    .frame(height: 160)

                                ForEach(Array(lyricsService.lyrics.enumerated()), id: \.element.id) { index, line in
                                    LyricLineView(
                                        line: line,
                                        index: index,
                                        currentIndex: lyricsService.currentLineIndex ?? 0,
                                        currentTime: musicController.currentTime,
                                        isScrolling: isManualScrolling
                                    )
                                    .id(line.id)
                                    .onTapGesture {
                                        musicController.seek(to: line.startTime)
                                    }

                                    // 检测间奏：上一句结束时间到下一句开始时间的间隔
                                    checkAndShowInterlude(at: index, currentTime: musicController.currentTime)
                                }

                                // Bottom spacer for centering last lyrics
                                Spacer()
                                    .frame(height: 100)
                            }
                            .drawingGroup()  // Performance optimization for smooth 60fps animations
                        }
                        .onChange(of: lyricsService.currentLineIndex) { oldValue, newValue in
                            if !isManualScrolling, let currentIndex = newValue, currentIndex < lyricsService.lyrics.count {
                                // 🔑 统一动画：滚动和视觉变化使用完全相同的动画曲线
                                // 动画时长 0.6s，配合 0.6s 提前量实现同步
                                let animationDuration = 0.6
                                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1.0, duration: animationDuration)) {
                                    proxy.scrollTo(lyricsService.lyrics[currentIndex].id, anchor: .center)
                                }
                            }
                        }
                    }
                    // 🔑 scroll检测逻辑 - 与歌单页PlaylistView完全一致
                    // - 只有"最开始就是慢速下滑"才显示控件（一次）
                    // - 一旦快速滚动过，本轮滚动不再显示控件
                    // - 快速→慢速衰减不显示
                    // - 滚动停止时隐藏
                    .scrollDetectionWithVelocity(
                        onScrollStarted: {
                            // 开始手动滚动时重置状态
                            isManualScrolling = true
                            lastVelocity = 0
                            scrollLocked = false
                            hasTriggeredSlowScroll = false
                            autoScrollTimer?.invalidate()
                        },
                        onScrollEnded: {
                            // 🔑 滚动结束后保持控件2秒再隐藏（如果鼠标仍在窗口内则不隐藏）
                            autoScrollTimer?.invalidate()
                            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                                // 只有当鼠标不在窗口内时才隐藏
                                if !isHovering {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showControls = false
                                    }
                                }
                                // 重置滚动状态
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isManualScrolling = false
                                    lastVelocity = 0
                                    scrollLocked = false
                                    hasTriggeredSlowScroll = false
                                }
                            }
                        },
                        onScrollWithVelocity: { deltaY, velocity in
                            let absVelocity = abs(velocity)
                            // 🔑 阈值提高到800，让稍微快一点的下滑也算慢速
                            let threshold: CGFloat = 800

                            // 🔑 快速滚动 → 隐藏并锁定本轮（只有剧烈快速才触发）
                            if absVelocity >= threshold {
                                if !scrollLocked {
                                    scrollLocked = true
                                }
                                if showControls {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showControls = false
                                    }
                                }
                            }
                            // 🔑 慢速下滑 → 只在未锁定且未触发过时显示一次
                            else if deltaY > 0 && !scrollLocked && !hasTriggeredSlowScroll {
                                hasTriggeredSlowScroll = true
                                if !showControls {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showControls = true
                                    }
                                }
                            }

                            lastVelocity = absVelocity
                        }
                    )
                    .overlay(
                        // 🔑 关键：控件必须在ScrollView的overlay之上，而不是在同一个ZStack内
                        Group {
                            if showControls {
                                controlBar
                            }
                        }
                    )
                }
            }

            // 🐛 调试窗口 - inside ZStack
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
        .overlay(alignment: .topLeading) {
            // Music按钮 - overlay不接收hover事件，不改变布局
            if showControls {
                MusicButtonView()
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Hide/Expand 按钮 - 根据模式显示不同按钮
            if showControls {
                if onExpand != nil {
                    // 菜单栏模式：显示展开按钮
                    ExpandButtonView(onExpand: onExpand!)
                        .padding(12)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if onHide != nil {
                    // 浮窗模式：显示收起按钮
                    HideButtonView(onHide: onHide!)
                        .padding(12)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    // 无回调时的默认行为
                    HideButtonView(onHide: {
                        if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel }) {
                            window.orderOut(nil)
                        }
                    })
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .onHover { hovering in
            isHovering = hovering
            // 🔑 鼠标离开窗口时总是隐藏控件（无论是否在滚动）
            if !hovering {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showControls = false
                }
            }
            // 🔑 只在非滚动状态时，鼠标进入显示控件
            else if !isManualScrolling {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showControls = true
                }
            }
            // 滚动时鼠标进入不自动显示控件（由scroll逻辑控制）
        }
        // 🔑 当切换到歌词页面时，显示控件（因为是从hover状态切换过来的）
        .onChange(of: currentPage) { _, newPage in
            if newPage == .lyrics {
                // 🔑 假设是从 hover 状态切换过来的，设置 isHovering = true
                isHovering = true
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = true
                }
            }
        }
        .onAppear {
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration)
        }
          .onChange(of: musicController.currentTrackTitle) {
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration)
        }
        .onChange(of: musicController.currentTime) {
            lyricsService.updateCurrentTime(musicController.currentTime)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 10) {  // 🔑 缩小: 12→10
            Image(systemName: "music.note")
                .font(.system(size: 36))  // 🔑 缩小: 48→36
                .foregroundColor(.white.opacity(0.3))
            Text("No lyrics available")
                .font(.system(size: 13, weight: .medium))  // 🔑 缩小: 16→13
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    private var controlBar: some View {
        VStack {
            Spacer()

            // 渐变模糊 + 控件区域（整体拦截点击，防止穿透）
            ZStack(alignment: .bottom) {
                // 🔑 渐变模糊背景 - 使用系统backdrop blur实时模糊下层内容
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                    .frame(height: 100)
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.3), location: 0.15),
                                .init(color: .black.opacity(0.6), location: 0.3),
                                .init(color: .black, location: 0.5),
                                .init(color: .black, location: 1.0)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

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
            .allowsHitTesting(true)     // 🔑 拦截所有点击，防止穿透到下层歌词
        }
        // 🔑 移除clipShape transition，使用纯opacity + 轻微offset动画
        .transition(.opacity.combined(with: .offset(y: 20)))
    }
    
    private var timeAndProgressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text(formatTime(musicController.currentTime))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 35, alignment: .leading)

                Spacer()

                if let quality = musicController.audioQuality {
                    qualityBadge(quality)
                }

                Spacer()

                Text("-" + formatTime(musicController.duration - musicController.currentTime))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 35, alignment: .trailing)
            }
            .padding(.horizontal, 28)

            progressBar
        }
    }
    
    private func qualityBadge(_ quality: String) -> some View {
        HStack(spacing: 2) {
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
    
    private var progressBar: some View {
        GeometryReader { geo in
            let currentProgress: CGFloat = musicController.duration > 0 ? (dragPosition ?? CGFloat(musicController.currentTime / musicController.duration)) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: isProgressBarHovering ? 8 : 6)
                Capsule().fill(Color.white).frame(width: geo.size.width * currentProgress, height: isProgressBarHovering ? 8 : 6)
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
        .frame(height: 20)
        .padding(.horizontal, 20)
    }
    
    private var playbackControls: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 12)
            Button(action: { withAnimation(.spring(response: 5.0, dampingFraction: 0.8)) { currentPage = .album } }) {
                Image(systemName: "quote.bubble.fill").font(.system(size: 16)).foregroundColor(.white).frame(width: 28, height: 28)
            }
            Spacer()
            Button(action: musicController.previousTrack) {
                Image(systemName: "backward.fill").font(.system(size: 20)).foregroundColor(.white).frame(width: 32, height: 32)
            }
            Spacer().frame(width: 10)
            Button(action: musicController.togglePlayPause) {
                ZStack {
                    Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 24)).foregroundColor(.white)
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer().frame(width: 10)
            Button(action: musicController.nextTrack) {
                Image(systemName: "forward.fill").font(.system(size: 20)).foregroundColor(.white).frame(width: 32, height: 32)
            }
            Spacer()
            Button(action: { withAnimation(.spring(response: 5.0, dampingFraction: 0.8)) { currentPage = .playlist } }) {
                Image(systemName: "music.note.list").font(.system(size: 16)).foregroundColor(.white.opacity(0.7)).frame(width: 28, height: 28)
            }
            Spacer().frame(width: 12)
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private func checkAndShowInterlude(at index: Int, currentTime: TimeInterval) -> some View {
        if index < lyricsService.lyrics.count - 1 {
            let currentLine = lyricsService.lyrics[index]
            let nextLine = lyricsService.lyrics[index + 1]
            let interludeGap = nextLine.startTime - currentLine.endTime

            if interludeGap >= 5.0 && currentLine.text != "⋯" && nextLine.text != "⋯" {
                InterludeLoadingDotsView(
                    currentTime: currentTime,
                    startTime: currentLine.endTime,
                    endTime: nextLine.startTime
                )
                .id("interlude-\(index)")
            }
        }
    }
}

// MARK: - Lyric Line View

struct LyricLineView: View {
    let line: LyricLine
    let index: Int
    let currentIndex: Int
    let currentTime: TimeInterval
    let isScrolling: Bool // Add parameter to know if user is scrolling

    @State private var isHovering: Bool = false

    var body: some View {
        let distance = index - currentIndex
        let isCurrent = distance == 0
        let isPast = distance < 0
        let absDistance = abs(distance)

        // Enhanced Visual State Calculations with smoother transitions
        // 使用scaleEffect而不是动态字体，保持文本排版一致性
        // 手动滚动时，所有歌词使用统一的"未选中"样式（scale=0.92）
        let scale: CGFloat = {
            // 手动滚动时所有歌词使用统一的"未选中"大小
            if isScrolling { return 0.92 }

            if isCurrent {
                return 1.08
            } else if absDistance == 1 {
                return 0.96
            } else {
                return 0.92
            }
        }()

        let blur: CGFloat = {
            // 手动滚动时完全清晰，无模糊
            if isScrolling { return 0 }

            // Progressive blur based on distance when not scrolling
            if isCurrent { return 0 }

            if isPast {
                // Past lines: gentle blur that increases with distance
                let blurAmount = min(CGFloat(absDistance) * 0.4, 2.5)
                return blurAmount
            } else {
                // Future lines: stronger blur for depth effect
                let blurAmount = min(CGFloat(absDistance) * 0.7, 5.0)
                return blurAmount
            }
        }()

        let opacity: CGFloat = {
            // 手动滚动时所有歌词统一透明度 100%（完全不透明）
            if isScrolling { return 1.0 }

            if isCurrent {
                return 1.0
            }

            if isPast {
                // Past lines: fade gracefully but remain readable
                let fadeAmount = max(0.4, 1.0 - Double(absDistance) * 0.15)
                return fadeAmount
            } else {
                // Future lines: progressive fade with smoother curve
                let fadeAmount = max(0.25, 0.95 - Double(absDistance) * 0.10)
                return fadeAmount
            }
        }()
        
        // Enhanced yOffset with smoother transitions
        let yOffset: CGFloat = {
            if isCurrent {
                return -3 // Slightly more lift for emphasis
            } else if absDistance == 1 {
                return -1 // Subtle lift for adjacent lines
            } else {
                return 0
            }
        }()
        
        // 🔑 关键修复：所有歌词使用完全一致的字体（24pt + semibold）
        // 字体大小、粗细、行间距完全相同，确保所有歌词的文本排版100%一致
        // 只通过scaleEffect改变视觉大小，不触发任何布局重新计算
        HStack(spacing: 0) {
            Group {
                if line.text == "⋯" {
                    // 特殊处理：加载占位符显示基于时间的三等分点亮动画
                    TimeBasedLoadingDotsView(
                        currentTime: currentTime,
                        endTime: line.endTime
                    )
                } else {
                    Text(line.text)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scaleEffect(scale, anchor: .leading)  // 🔑 在文字上直接应用scale，anchor为leading

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)  // 先应用左右padding
        .padding(.vertical, 8)  // 增加垂直 padding 让 hover 背景有空间
        .background(
            // 🎨 macOS 26 Liquid Glass hover 效果
            Group {
                if isScrolling && isHovering && line.text != "⋯" {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.08))
                        .padding(.horizontal, 8)  // 背景左右留出8px空间
                }
            }
        )
        .blur(radius: blur)
        .opacity(opacity)
        .offset(y: yOffset)
        .animation(
            .timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.6),  // 🔑 与滚动动画完全同步
            value: currentIndex
        )
        .animation(
            .easeInOut(duration: 0.3),
            value: isScrolling
        )
        .animation(
            .easeInOut(duration: 0.2),
            value: isHovering
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            // 只在手动滚动时启用 hover 效果
            if isScrolling {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Time-Based Loading Dots View (三等分前奏时间点亮动画)

struct TimeBasedLoadingDotsView: View {
    let currentTime: TimeInterval  // 🔑 仅用于初始化和重置
    let endTime: TimeInterval

    // 🔑 内部状态：使用 Timer 驱动动画
    @State private var animationTime: TimeInterval = 0
    @State private var animationTimer: Timer?
    @State private var initialTime: TimeInterval = 0  // 🔑 记录初始时间

    var body: some View {
        let duration = endTime // 前奏总时长
        let segmentDuration = duration / 3.0 // 每个点占1/3时间

        // 计算每个点的进度（0.0-1.0）
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = segmentDuration * Double(index)
            let dotEndTime = segmentDuration * Double(index + 1)

            if animationTime <= dotStartTime {
                return 0.0
            } else if animationTime >= dotEndTime {
                return 1.0
            } else {
                // 平滑渐变函数
                let progress = (animationTime - dotStartTime) / (dotEndTime - dotStartTime)
                return CGFloat(progress * progress * (3.0 - 2.0 * progress)) // Smoothstep
            }
        }

        // 🔑 计算整体淡出透明度：与第一句歌词滚动同步
        let overallOpacity: CGFloat = {
            let fadeOutDuration: TimeInterval = 0.6 // 与LyricsService的scrollAnimationLeadTime同步

            if animationTime >= endTime {
                // 已经超过结束时间，完全透明
                return 0.0
            } else if animationTime >= endTime - fadeOutDuration {
                // 进入淡出阶段，与第一句歌词滚动进入同步
                let fadeProgress = (endTime - animationTime) / fadeOutDuration
                return CGFloat(fadeProgress) // 从1.0淡到0.0
            } else {
                // 正常显示
                return 1.0
            }
        }()

        HStack(spacing: 10) {
            ForEach(0..<3) { index in
                let progress = dotProgresses[index]
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .opacity(0.35 + progress * 0.65) // 从0.35渐变到1.0
                    .scaleEffect(1.0 + progress * 0.3) // 从1.0渐变到1.3
                    .animation(.easeInOut(duration: 0.3), value: progress)  // 🔑 添加平滑动画
            }
        }
        .scaleEffect(0.8) // 整体缩小到0.8x
        .frame(height: 24) // Match lyric text height
        .opacity(overallOpacity) // 🔑 应用整体淡出效果
        .onAppear {
            startAnimation()
        }
        .onDisappear {
            stopAnimation()
        }
        .onChange(of: currentTime) { _, newTime in
            // 🔑 外部时间跳变时重新同步
            if abs(newTime - animationTime) > 1.0 {
                initialTime = newTime
                animationTime = newTime
            }
        }
    }

    private func startAnimation() {
        initialTime = currentTime
        animationTime = currentTime
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [self] _ in
            // 🔑 每帧递增 1/60 秒
            animationTime += 1.0/60.0
        }
        if let timer = animationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

// MARK: - Interlude Loading Dots View (间奏加载动画)

struct InterludeLoadingDotsView: View {
    let currentTime: TimeInterval  // 🔑 仅用于初始化和重置
    let startTime: TimeInterval  // 间奏开始时间（上一句结束）
    let endTime: TimeInterval    // 间奏结束时间（下一句开始）

    // 🔑 内部状态：使用 Timer 驱动动画
    @State private var animationTime: TimeInterval = 0
    @State private var animationTimer: Timer?
    @State private var initialTime: TimeInterval = 0  // 🔑 记录初始时间

    var body: some View {
        let duration = endTime - startTime // 间奏总时长
        let segmentDuration = duration / 3.0 // 每个点占1/3时间

        // 计算每个点的进度（0.0-1.0）
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = startTime + segmentDuration * Double(index)
            let dotEndTime = startTime + segmentDuration * Double(index + 1)

            if animationTime <= dotStartTime {
                return 0.0
            } else if animationTime >= dotEndTime {
                return 1.0
            } else {
                // 平滑渐变函数
                let progress = (animationTime - dotStartTime) / (dotEndTime - dotStartTime)
                return CGFloat(progress * progress * (3.0 - 2.0 * progress)) // Smoothstep
            }
        }

        // 🔑 整体淡入淡出
        let overallOpacity: CGFloat = {
            let fadeInDuration: TimeInterval = min(1.0, duration / 6.0) // 快速淡入（最多1秒）
            let fadeOutDuration: TimeInterval = 3.5 // 3.5秒淡出，同时下一句歌词进入

            if animationTime < startTime {
                // 还没到间奏，完全透明
                return 0.0
            } else if animationTime < startTime + fadeInDuration {
                // 快速淡入
                let fadeProgress = (animationTime - startTime) / fadeInDuration
                return CGFloat(fadeProgress)
            } else if animationTime >= endTime {
                // 已过间奏，完全透明
                return 0.0
            } else if animationTime >= endTime - fadeOutDuration {
                // 淡出阶段（与下一句歌词进入同步）
                let fadeProgress = (endTime - animationTime) / fadeOutDuration
                return CGFloat(fadeProgress)
            } else {
                // 间奏播放中，完全不透明
                return 1.0
            }
        }()

        HStack(spacing: 10) {
            ForEach(0..<3) { index in
                let progress = dotProgresses[index]
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .opacity(0.35 + progress * 0.65) // 从0.35渐变到1.0
                    .scaleEffect(1.0 + progress * 0.3) // 从1.0渐变到1.3
                    .animation(.easeInOut(duration: 0.3), value: progress)  // 🔑 添加平滑动画
            }
        }
        .scaleEffect(0.8) // 整体缩小到0.8x
        .frame(height: 24) // Match lyric text height
        .opacity(overallOpacity) // 🔑 应用整体淡入淡出效果
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            startAnimation()
        }
        .onDisappear {
            stopAnimation()
        }
        .onChange(of: currentTime) { _, newTime in
            // 🔑 外部时间跳变时重新同步
            if abs(newTime - animationTime) > 1.0 {
                initialTime = newTime
                animationTime = newTime
            }
        }
    }

    private func startAnimation() {
        initialTime = currentTime
        animationTime = currentTime
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [self] _ in
            // 🔑 每帧递增 1/60 秒
            animationTime += 1.0/60.0
        }
        if let timer = animationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

// MARK: - Loading Dots Lyric View (in scroll list)

struct LoadingDotsLyricView: View {
    let currentTime: TimeInterval
    let nextLineStartTime: TimeInterval
    let previousLineEndTime: TimeInterval

    var body: some View {
        // Calculate the gap duration (time between lyrics)
        let gapDuration = nextLineStartTime - previousLineEndTime

        // Only show dots if there's a meaningful gap
        guard gapDuration > 0.3 else {
            return AnyView(EmptyView())
        }

        // Calculate elapsed time in this gap
        let elapsedTime = max(0, currentTime - previousLineEndTime)

        // Only show dots if we're still in the gap (before the next line starts exactly)
        // This prevents overlap with the first lyric line
        guard elapsedTime < gapDuration else {
            return AnyView(EmptyView())
        }

        // Use 3 equal segments for the dots animation - true thirds
        let segmentDuration = gapDuration / 3.0

        // Calculate smooth progress for each dot
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = segmentDuration * CGFloat(index)
            let dotEndTime = segmentDuration * CGFloat(index + 1)

            if elapsedTime <= dotStartTime {
                return 0.0
            } else if elapsedTime >= dotEndTime {
                return 1.0
            } else {
                // Smooth easing function for natural animation
                let progress = (elapsedTime - dotStartTime) / (dotEndTime - dotStartTime)
                return progress * progress * (3.0 - 2.0 * progress) // Smooth step function
            }
        }

        // Display dots as proper lyric line with Apple Music style - much larger
        return AnyView(
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    let progress = dotProgresses[index]

                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10) // Much larger dots
                        .scaleEffect(0.7 + progress * 0.3) // Scale from 0.7 to 1.0
                        .opacity(0.4 + progress * 0.6) // Fade from 0.4 to 1.0
                        .animation(.timingCurve(0.2, 0.0, 0.0, 1.0, duration: 0.4), value: progress)
                        // Add breathing effect for completed dots
                        .overlay(
                            Circle()
                                .fill(Color.white)
                                .scaleEffect(progress > 0.5 ? 1.2 + sin(Date().timeIntervalSince1970 * 3) * 0.1 : 1.0)
                                .opacity(progress > 0.5 ? 0.3 : 0.0)
                                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: progress > 0.5)
                        )
                }
            }
            .font(.system(size: 23, weight: .medium, design: .rounded)) // Same size as lyric lines
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0.7) // Slightly transparent like upcoming lyrics
        )
    }
}



#if DEBUG
struct LyricsView_Previews: PreviewProvider {
    static var previews: some View {
        LyricsView(currentPage: .constant(.lyrics))
            .environmentObject(MusicController(preview: true))
            .frame(width: 300, height: 300)
            .background(Color.black)
    }
}
#endif
