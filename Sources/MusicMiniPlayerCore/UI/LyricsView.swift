import SwiftUI
import AppKit

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
    @State private var wasFastScrolling: Bool = false
    @State private var showLoadingDots: Bool = false
    @Binding var currentPage: PlayerPage
    var openWindow: OpenWindowAction?
    var onHide: (() -> Void)?
    var onExpand: (() -> Void)?
    @State private var lastVelocity: CGFloat = 0
    @State private var scrollLocked: Bool = false
    @State private var hasTriggeredSlowScroll: Bool = false

    // 🔑 手动滚动 Y 轴偏移量
    @State private var manualScrollOffset: CGFloat = 0
    // 🔑 行高度缓存（用于精确计算位置）
    @State private var lineHeights: [Int: CGFloat] = [:]
    // 🔑 记录上次滚动时间（用于速度计算）
    @State private var lastScrollTime: CFTimeInterval = 0
    // 🔑 手动滚动时锁定的行索引（防止歌词在手动滚动时跟随播放移动）
    @State private var lockedLineIndex: Int? = nil
    // 🔑 锁定时的累积高度（用于固定滚动位置）
    @State private var lockedAccumulatedHeight: CGFloat = 0
    // 🔑 锁定时每行的目标索引快照（手动滚动期间不变）
    @State private var lockedLineTargetIndices: [Int: Int] = [:]

    // 🔑 AMLL 波浪效果：每行的目标 currentIndex（用于错开动画触发时间）
    @State private var lineTargetIndices: [Int: Int] = [:]
    // 🔑 上一次的 currentIndex（用于检测变化并触发波浪）
    @State private var lastCurrentIndex: Int = -1

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
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.3))
                        Text(error)
                            .font(.system(size: 13, weight: .medium))
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
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Retry")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(6)
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
                    // 🔑 AMLL 风格：VStack 自适应高度 + Y 轴整体偏移
                    GeometryReader { geo in
                        let containerHeight = geo.size.height
                        let controlBarHeight: CGFloat = 120
                        let currentIndex = lyricsService.currentLineIndex ?? 0

                        // 🔑 锚点位置：当前行在容器的 24% 高度处
                        let anchorY = (containerHeight - controlBarHeight) * 0.24

                        // 🔑 计算页面超出回弹边界
                        let visibleHeight = containerHeight - controlBarHeight
                        let totalContentHeight = calculateTotalContentHeight()
                        let headOverscroll = visibleHeight * 0.10  // 上 10%
                        let tailOverscroll = visibleHeight * 0.20  // 下 20%

                        // 🔑 AMLL 波浪效果：不在容器级别计算偏移，而是在每行单独计算
                        // 每行使用自己的 lineTargetIndices[index] 来决定位置

                        ZStack(alignment: .topLeading) {  // 🔑 使用 ZStack 实现 AMLL 风格布局
                            ForEach(Array(lyricsService.lyrics.enumerated()), id: \.element.id) { index, line in
                                if index == 0 || index >= lyricsService.firstRealLyricIndex {
                                    // 🔑 手动滚动时：使用锁定时的目标索引快照
                                    // 🔑 自动滚动时：每行使用自己的 lineTargetIndex
                                    let lineOffset: CGFloat = {
                                        if isManualScrolling {
                                            // 手动滚动：使用锁定时的目标索引，不随播放变化
                                            let frozenTargetIndex = lockedLineTargetIndices[index] ?? lockedLineIndex ?? currentIndex
                                            return anchorY - calculateAccumulatedHeight(upTo: frozenTargetIndex) + manualScrollOffset
                                        } else {
                                            // 自动滚动：使用该行的目标索引计算偏移
                                            let lineTargetIndex = lineTargetIndices[index] ?? currentIndex
                                            return anchorY - calculateAccumulatedHeight(upTo: lineTargetIndex)
                                        }
                                    }()

                                    Group {
                                        if isPreludeEllipsis(line.text) {
                                            let nextLineStartTime: TimeInterval = {
                                                if index == 0 && lyricsService.firstRealLyricIndex < lyricsService.lyrics.count {
                                                    return lyricsService.lyrics[lyricsService.firstRealLyricIndex].startTime
                                                }
                                                for nextIndex in max(index + 1, lyricsService.firstRealLyricIndex)..<lyricsService.lyrics.count {
                                                    let nextLine = lyricsService.lyrics[nextIndex]
                                                    if !isPreludeEllipsis(nextLine.text) {
                                                        return nextLine.startTime
                                                    }
                                                }
                                                return line.endTime
                                            }()

                                            PreludeDotsView(
                                                startTime: line.startTime,
                                                endTime: nextLineStartTime,
                                                musicController: musicController
                                            )
                                            .frame(height: 30)
                                            .padding(.horizontal, 32)
                                            .padding(.vertical, 8)  // 🔑 前奏点的 padding
                                        } else {
                                            LyricLineView(
                                                line: line,
                                                index: index,
                                                currentIndex: currentIndex,  // 🔑 始终使用真实的当前索引（用于高亮）
                                                isScrolling: isManualScrolling,
                                                currentTime: musicController.currentTime,
                                                onTap: {
                                                    // 🐛 调试：输出歌词时间信息
                                                    fputs("🐛 [DEBUG] Line \(index): text=\"\(line.text.prefix(20))...\" start=\(String(format: "%.2f", line.startTime))s end=\(String(format: "%.2f", line.endTime))s hasSyllable=\(line.hasSyllableSync) words=\(line.words.count)\n", stderr)
                                                    if line.hasSyllableSync {
                                                        for (i, word) in line.words.prefix(5).enumerated() {
                                                            fputs("   word[\(i)]: \"\(word.word)\" \(String(format: "%.2f", word.startTime))-\(String(format: "%.2f", word.endTime))s\n", stderr)
                                                        }
                                                    }
                                                    fputs("🎵 [LyricsView] Tapped line \(index): \"\(line.text)\" -> seek to \(line.startTime)s\n", stderr)
                                                    // 🔑 点击跳转：取消当前计时器，立即跳转
                                                    autoScrollTimer?.invalidate()
                                                    autoScrollTimer = nil

                                                    // 🔑 先解锁滚动状态
                                                    isManualScrolling = false
                                                    lockedLineIndex = nil
                                                    manualScrollOffset = 0

                                                    // 🔑 然后执行 seek，让音乐跳转
                                                    musicController.seek(to: line.startTime)
                                                    fputs("🎵 [LyricsView] Seek called, scroll unlocked\n", stderr)
                                                }
                                            )
                                            .padding(.horizontal, 32)
                                            // 🔑 VStack spacing=4 已经提供了行间距，这里不再加 vertical padding
                                        }
                                    }
                                    // 🔑 存储每行高度用于计算偏移
                                    .background(
                                        GeometryReader { lineGeo in
                                            Color.clear.onAppear {
                                                lineHeights[index] = lineGeo.size.height
                                            }
                                            .onChange(of: lineGeo.size.height) { _, newHeight in
                                                lineHeights[index] = newHeight
                                            }
                                        }
                                    )
                                    // 🔑 AMLL 核心：每行有自己的 Y 偏移（基于该行的目标索引）
                                    .offset(y: lineOffset + calculateLinePosition(index: index))
                                    // 🔑 每行单独的 spring 动画（手动滚动时禁用）
                                    .animation(
                                        isManualScrolling ? nil : .interpolatingSpring(
                                            mass: 1,
                                            stiffness: 100,
                                            damping: 16.5,
                                            initialVelocity: 0
                                        ),
                                        value: isManualScrolling ? 0 : lineOffset  // 手动滚动时使用固定值，不触发动画
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .clipped()
                    // 🔑 滚轮事件监听（与 PlaylistView 一致）
                    .contentShape(Rectangle())
                    .scrollDetectionWithVelocity(
                        onScrollStarted: {
                            // 🔑 锁定当前状态，防止歌词跟随播放移动
                            let currentIdx = lyricsService.currentLineIndex ?? 0
                            lockedAccumulatedHeight = calculateAccumulatedHeight(upTo: currentIdx)
                            lockedLineIndex = currentIdx
                            // 🔑 保存每行的目标索引快照
                            lockedLineTargetIndices = lineTargetIndices
                            isManualScrolling = true
                            lastVelocity = 0
                            scrollLocked = false
                            hasTriggeredSlowScroll = false
                            autoScrollTimer?.invalidate()
                        },
                        onScrollEnded: {
                            autoScrollTimer?.invalidate()
                            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [self] _ in
                                fputs("🔓 [LyricsView] Scroll ended: unlocking, returning to current position\n", stderr)
                                // 🔑 2秒后恢复到当前播放位置
                                // 先解锁，再用动画恢复
                                isManualScrolling = false
                                lockedLineIndex = nil

                                withAnimation(.interpolatingSpring(
                                    mass: 1,
                                    stiffness: 100,
                                    damping: 16.5,
                                    initialVelocity: 0
                                )) {
                                    manualScrollOffset = 0
                                }
                                scrollLocked = false
                                hasTriggeredSlowScroll = false

                                // 🔑 恢复后如果鼠标在窗口内则显示控件
                                if isHovering {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showControls = true
                                    }
                                }
                            }
                        },
                        onScrollWithVelocity: { deltaY, velocity in
                            // 🔑 计算滚动边界：基于内容高度和当前行位置
                            let totalContentHeight = calculateTotalContentHeight()
                            let localCurrentIndex = lyricsService.currentLineIndex ?? 0
                            let currentLineOffset = calculateAccumulatedHeight(upTo: localCurrentIndex)

                            // 🔑 简化边界计算：允许向上滚动到第一行，向下滚动到最后一行
                            // 上边界 = 当前行之前的所有内容高度（可以滚动回到开头）
                            let maxScrollUp = currentLineOffset
                            // 下边界 = 当前行之后的所有内容高度（可以滚动到结尾）
                            let maxScrollDown = max(0, totalContentHeight - currentLineOffset - 200)

                            var newOffset = manualScrollOffset + deltaY
                            // 🔑 超出边界时应用阻尼（橡皮筋效果）
                            if newOffset > maxScrollUp {
                                let overscroll = newOffset - maxScrollUp
                                newOffset = maxScrollUp + overscroll * 0.3
                            } else if newOffset < -maxScrollDown {
                                let overscroll = -maxScrollDown - newOffset
                                newOffset = -maxScrollDown - overscroll * 0.3
                            }
                            manualScrollOffset = newOffset

                            let absVelocity = abs(velocity)
                            let threshold: CGFloat = 800

                            // 🔑 与 PlaylistView 完全一致的逻辑
                            if deltaY < 0 {
                                // 往上滚：隐藏控件
                                if showControls {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showControls = false
                                    }
                                }
                                scrollLocked = true
                            } else if absVelocity >= threshold {
                                // 快速滚动：隐藏控件
                                if !scrollLocked {
                                    scrollLocked = true
                                }
                                if showControls {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showControls = false
                                    }
                                }
                            } else if deltaY > 0 && !scrollLocked && !hasTriggeredSlowScroll {
                                // 慢速往下滚：显示控件
                                hasTriggeredSlowScroll = true
                                if !showControls {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showControls = true
                                    }
                                }
                            }

                            lastVelocity = absVelocity
                        },
                        isEnabled: currentPage == .lyrics
                    )
                    // 🔑 底部控件 overlay（与 PlaylistView 相同实现 + 滑入滑出动画）
                    .overlay(
                        VStack {
                            Spacer()
                            ZStack(alignment: .bottom) {
                                // 渐变模糊背景
                                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                                    .frame(height: 120)
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
                                    .allowsHitTesting(false)

                                SharedBottomControls(
                                    currentPage: $currentPage,
                                    isHovering: $isHovering,
                                    showControls: $showControls,
                                    isProgressBarHovering: $isProgressBarHovering,
                                    dragPosition: $dragPosition
                                )
                            }
                            // 🔑 滑入滑出动画（从下往上）
                            .offset(y: showControls ? 0 : 30)
                        }
                        .allowsHitTesting(showControls)
                        .opacity(showControls ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25), value: showControls)
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
        // 🔑 AMLL 波浪效果：监听当前行变化，触发波浪动画
        .onChange(of: lyricsService.currentLineIndex) { oldValue, newValue in
            guard let newIndex = newValue else { return }
            let oldIndex = oldValue ?? lastCurrentIndex

            if newIndex != lastCurrentIndex && !isManualScrolling {
                triggerWaveAnimation(from: oldIndex, to: newIndex)
                lastCurrentIndex = newIndex
            }
        }
        // 🔑 No Lyrics 时自动跳回专辑页面（除非用户手动打开了歌词页面）
        .onChange(of: lyricsService.error) { _, newError in
            // 🐛 调试日志
            fputs("🔄 [LyricsView] lyricsService.error changed to: \(newError ?? "nil"), currentPage=\(currentPage), userManuallyOpenedLyrics=\(musicController.userManuallyOpenedLyrics)\n", stderr)

            // 只有当：1. 有错误（No lyrics）2. 用户没有手动打开歌词页面 3. 当前在歌词页面
            // 才自动跳回专辑页面
            if newError != nil && !musicController.userManuallyOpenedLyrics && currentPage == .lyrics {
                fputs("🔄 [LyricsView] Auto-jumping back to album page\n", stderr)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    currentPage = .album
                }
            }
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

            // 渐变模糊 + 控件区域
            ZStack(alignment: .bottom) {
                // 渐变模糊背景（不拦截点击，让上层内容可点击）
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                    .frame(height: 120)
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
                    .allowsHitTesting(false)  // 🔑 模糊背景不拦截点击

                SharedBottomControls(
                    currentPage: $currentPage,
                    isHovering: $isHovering,
                    showControls: $showControls,
                    isProgressBarHovering: $isProgressBarHovering,
                    dragPosition: $dragPosition
                )
                .padding(.bottom, 0)
            }
            // 🔑 只有控件区域拦截点击，渐变模糊区域穿透
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

    /// 🔑 检测是否为前奏/间奏省略号占位符
    private func isPreludeEllipsis(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 检测各种省略号格式: "...", "…", "⋯", "。。。", "..." 等
        let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・"]
        return ellipsisPatterns.contains(trimmed) || trimmed.isEmpty
    }

    /// 🔑 计算从第一行到指定行的累积高度（用于 VStack offset）
    private func calculateAccumulatedHeight(upTo targetIndex: Int) -> CGFloat {
        let spacing: CGFloat = 6  // 🔑 与 VStack spacing 保持一致
        var totalHeight: CGFloat = 0
        let defaultHeight: CGFloat = 36  // 默认行高（用于尚未测量的行）

        // 获取实际渲染的行索引列表
        let renderedIndices = lyricsService.lyrics.enumerated()
            .filter { index, _ in index == 0 || index >= lyricsService.firstRealLyricIndex }
            .map { $0.offset }

        // 计算目标行在渲染列表中的位置
        guard let targetPosition = renderedIndices.firstIndex(of: targetIndex) else {
            return 0
        }

        // 累加目标行之前所有行的高度 + 间距
        for i in 0..<targetPosition {
            let lineIndex = renderedIndices[i]
            let height = lineHeights[lineIndex] ?? defaultHeight
            totalHeight += height + spacing
        }

        return totalHeight
    }

    /// 🔑 计算某行在容器中的位置（相对于第一行）
    /// 用于 ZStack 布局中确定每行的 Y 位置
    private func calculateLinePosition(index: Int) -> CGFloat {
        let spacing: CGFloat = 6  // 与 VStack spacing 保持一致
        var position: CGFloat = 0
        let defaultHeight: CGFloat = 36

        // 获取实际渲染的行索引列表
        let renderedIndices = lyricsService.lyrics.enumerated()
            .filter { idx, _ in idx == 0 || idx >= lyricsService.firstRealLyricIndex }
            .map { $0.offset }

        // 找到目标行在渲染列表中的位置
        guard let targetPosition = renderedIndices.firstIndex(of: index) else {
            return 0
        }

        // 累加目标行之前所有行的高度 + 间距
        for i in 0..<targetPosition {
            let lineIndex = renderedIndices[i]
            let height = lineHeights[lineIndex] ?? defaultHeight
            position += height + spacing
        }

        return position
    }

    /// 🔑 计算内容总高度
    private func calculateTotalContentHeight() -> CGFloat {
        let spacing: CGFloat = 6  // 🔑 与 VStack spacing 保持一致
        var totalHeight: CGFloat = 0
        let defaultHeight: CGFloat = 36

        let renderedIndices = lyricsService.lyrics.enumerated()
            .filter { index, _ in index == 0 || index >= lyricsService.firstRealLyricIndex }
            .map { $0.offset }

        for (i, lineIndex) in renderedIndices.enumerated() {
            let height = lineHeights[lineIndex] ?? defaultHeight
            totalHeight += height
            if i < renderedIndices.count - 1 {
                totalHeight += spacing
            }
        }

        return totalHeight
    }

    /// 🔑 AMLL 波浪效果：触发波浪动画
    /// 真相：波浪是从屏幕当前可见区域的顶部开始的！
    /// 我们的布局中，高亮行在 anchorY (24% 位置)，所以屏幕顶部大约是高亮行往上 2-3 行
    /// 高亮行及之后的行：延迟间隔逐渐变小（甩尾加速效果）
    private func triggerWaveAnimation(from oldIndex: Int, to newIndex: Int) {
        guard !isManualScrolling else { return }

        let totalLines = lyricsService.lyrics.count
        guard totalLines > 0 else { return }

        // 获取实际渲染的行索引列表（按顺序）
        let renderedIndices = lyricsService.lyrics.enumerated()
            .filter { idx, _ in idx == 0 || idx >= lyricsService.firstRealLyricIndex }
            .map { $0.offset }

        // 🔑 AMLL 核心：波浪从当前屏幕可见区域的顶部开始
        // 高亮行在 24% 位置，假设每行约 40px，屏幕高度约 400px
        // 屏幕顶部大约是高亮行往上 2-3 行
        // 找到当前可见区域顶部的行索引
        let visibleTopLineIndex = max(0, newIndex - 3)  // 高亮行上方约 3 行是屏幕顶部

        // 找到 visibleTopLineIndex 在 renderedIndices 中的位置
        let startPosition = renderedIndices.firstIndex(where: { $0 >= visibleTopLineIndex }) ?? 0

        var delay: Double = 0
        var currentDelayStep: Double = 0.05  // 基础延迟步长 50ms

        // 🔑 从屏幕顶部开始向下遍历
        for i in startPosition..<renderedIndices.count {
            let lineIndex = renderedIndices[i]

            if delay < 0.01 {
                // 🔑 屏幕顶部第一行：立即更新目标索引
                lineTargetIndices[lineIndex] = newIndex
            } else {
                // 🔑 其他行：延迟更新目标索引
                let capturedDelay = delay
                DispatchQueue.main.asyncAfter(deadline: .now() + capturedDelay) {
                    guard !self.isManualScrolling else { return }
                    self.lineTargetIndices[lineIndex] = newIndex
                }
            }

            // 🔑 累加延迟
            delay += currentDelayStep

            // 🔑 AMLL 甩尾加速：高亮行及之后的行，延迟步长逐渐变小
            if lineIndex >= newIndex {
                currentDelayStep /= 1.05
            }
        }

        // 🔑 屏幕顶部之上的行（已滚出屏幕）：立即更新，无延迟
        for i in 0..<startPosition {
            let lineIndex = renderedIndices[i]
            lineTargetIndices[lineIndex] = newIndex
        }
    }
}

// MARK: - Lyric Line View

struct LyricLineView: View {
    let line: LyricLine
    let index: Int
    let currentIndex: Int
    let isScrolling: Bool
    var currentTime: TimeInterval = 0  // 保留用于将来逐字高亮
    var onTap: (() -> Void)? = nil  // 🔑 点击回调

    @State private var isHovering: Bool = false

    private var distance: Int { index - currentIndex }
    private var isCurrent: Bool { distance == 0 }
    private var isPast: Bool { distance < 0 }
    private var absDistance: Int { abs(distance) }

    // 🔑 清理歌词文本
    private var cleanedText: String {
        let pattern = "\\[\\d{2}:\\d{2}[:.]*\\d{0,3}\\]"
        return line.text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        let scale: CGFloat = {
            if isScrolling { return 0.95 }
            if isCurrent { return 1.0 }
            return 0.95
        }()

        let blur: CGFloat = {
            if isScrolling { return 0 }
            if isCurrent { return 0 }
            return CGFloat(absDistance) * 1.5
        }()

        // 🔑 行级高亮：当前行全白，其他行半透明（用 foregroundColor 控制，不用外层 opacity）
        let textOpacity: CGFloat = {
            if isScrolling { return 0.6 }  // 滚动时所有行统一透明度
            if isCurrent { return 1.0 }    // 当前行全白
            return 0.35                     // 其他行固定 35% 透明度
        }()

        // 🔑 稳定版本：简单的行级高亮（等待正确的逐字高亮实现）
        HStack(spacing: 0) {
            Text(cleanedText)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(textOpacity))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        // 🔑 不设固定高度，让内容自然决定高度
        .padding(.vertical, 8)  // 🔑 每句歌词的内部 padding（hover 背景用）
        .padding(.horizontal, 8)
        .background(
            Group {
                if isScrolling && isHovering && line.text != "⋯" {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.08))
                }
            }
        )
        .padding(.horizontal, -8)  // 🔑 抵消内部 padding，保持文字对齐
        .blur(radius: blur)
        .scaleEffect(scale, anchor: .leading)
        .animation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 20), value: scale)
        .animation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 20), value: blur)
        .animation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 20), value: textOpacity)
        // 🔑 点击整个区域触发跳转
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .onHover { hovering in
            if isScrolling { isHovering = hovering }
        }
    }
}

// MARK: - AMLL Style Lyrics Container (手动布局 + Spring 动画)

struct AMLLLyricsContainer: View {
    let lyrics: [LyricLine]
    let currentLineIndex: Int?
    let currentTime: TimeInterval
    let isScrolling: Bool
    let firstRealLyricIndex: Int
    let onSeek: (TimeInterval) -> Void

    // 🔑 布局参数
    private let lineHeight: CGFloat = 60  // 每行基础高度
    private let lineSpacing: CGFloat = 20  // 行间距
    private let containerHeight: CGFloat = 400  // 可视区域高度
    private let alignPosition: CGFloat = 0.35  // 当前行对齐位置 (0=顶部, 0.5=中间, 1=底部)

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let anchorY = totalHeight * alignPosition  // 当前行锚点位置

            ZStack(alignment: .topLeading) {
                ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                    // 🔑 只渲染真正的歌词行
                    if index == 0 || index >= firstRealLyricIndex {
                        let isPrelude = isPreludeEllipsis(line.text)
                        let lineConfig = calculateLineConfig(
                            index: index,
                            currentIndex: currentLineIndex ?? 0,
                            isScrolling: isScrolling
                        )

                        if isPrelude {
                            // 前奏/间奏省略号
                            AMLLPreludeDotsLine(
                                line: line,
                                lyrics: lyrics,
                                index: index,
                                firstRealLyricIndex: firstRealLyricIndex,
                                currentTime: currentTime
                            )
                            .offset(y: calculateYOffset(
                                index: index,
                                currentIndex: currentLineIndex ?? 0,
                                anchorY: anchorY
                            ))
                            .opacity(lineConfig.opacity)
                            .blur(radius: lineConfig.blur)
                            .animation(.interpolatingSpring(
                                mass: 2,
                                stiffness: 100,
                                damping: 25,
                                initialVelocity: 0
                            ), value: currentLineIndex)
                        } else {
                            // 普通歌词行
                            VStack(spacing: 0) {
                                AMLLLyricLine(
                                    line: line,
                                    currentTime: currentTime,
                                    config: lineConfig,
                                    isScrolling: isScrolling,
                                    onTap: { onSeek(line.startTime) }
                                )

                                // 🔑 间奏检测：当前行结束到下一行开始 >= 5秒时显示间奏动画
                                if let interludeInfo = checkForInterlude(index: index, lyrics: lyrics, firstRealLyricIndex: firstRealLyricIndex) {
                                    InterludeDotsView(
                                        startTime: interludeInfo.startTime,
                                        endTime: interludeInfo.endTime,
                                        currentTime: currentTime
                                    )
                                    .frame(height: 30)
                                    .padding(.top, 8)
                                }
                            }
                            .offset(y: calculateYOffset(
                                index: index,
                                currentIndex: currentLineIndex ?? 0,
                                anchorY: anchorY
                            ))
                            .animation(.interpolatingSpring(
                                mass: 2,
                                stiffness: 100,
                                damping: 25,
                                initialVelocity: 0
                            ), value: currentLineIndex)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .drawingGroup()  // 🔑 性能优化
    }

    // 🔑 计算每行的 Y 偏移量 (AMLL 风格：当前行固定在锚点位置)
    private func calculateYOffset(index: Int, currentIndex: Int, anchorY: CGFloat) -> CGFloat {
        let distance = index - currentIndex
        // 当前行在锚点位置，其他行相对偏移
        return anchorY + CGFloat(distance) * (lineHeight + lineSpacing)
    }

    // 🔑 计算每行的视觉配置
    private func calculateLineConfig(index: Int, currentIndex: Int, isScrolling: Bool) -> AMLLLineConfig {
        let distance = index - currentIndex
        let absDistance = abs(distance)
        let isCurrent = distance == 0
        let isPast = distance < 0

        if isScrolling {
            return AMLLLineConfig(scale: 0.92, blur: 0, opacity: 1.0, isCurrent: false)
        }

        if isCurrent {
            return AMLLLineConfig(scale: 1.0, blur: 0, opacity: 1.0, isCurrent: true)
        }

        let blur = 1.0 + CGFloat(absDistance) * 0.8
        let opacity = isPast ? 0.85 : max(0.2, 1.0 - Double(absDistance) * 0.15)
        return AMLLLineConfig(scale: 0.97, blur: blur, opacity: opacity, isCurrent: false)
    }

    private func isPreludeEllipsis(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・"]
        return ellipsisPatterns.contains(trimmed) || trimmed.isEmpty
    }

    // 🔑 检测是否有间奏（当前行结束到下一行开始 >= 5秒）
    private func checkForInterlude(index: Int, lyrics: [LyricLine], firstRealLyricIndex: Int) -> (startTime: TimeInterval, endTime: TimeInterval)? {
        // 确保有下一行
        guard index + 1 < lyrics.count else { return nil }

        let currentLine = lyrics[index]
        let nextLine = lyrics[index + 1]

        // 跳过省略号行
        let currentTrimmed = currentLine.text.trimmingCharacters(in: .whitespaces)
        let nextTrimmed = nextLine.text.trimmingCharacters(in: .whitespaces)
        let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・", ""]
        if ellipsisPatterns.contains(currentTrimmed) || ellipsisPatterns.contains(nextTrimmed) {
            return nil
        }

        // 计算间隔：下一行开始时间 - 当前行结束时间
        let gap = nextLine.startTime - currentLine.endTime
        if gap >= 5.0 {
            return (startTime: currentLine.endTime, endTime: nextLine.startTime)
        }

        return nil
    }
}

// MARK: - Line Configuration

struct AMLLLineConfig {
    let scale: CGFloat
    let blur: CGFloat
    let opacity: CGFloat
    let isCurrent: Bool
}

// MARK: - AMLL Style Single Line

struct AMLLLyricLine: View {
    let line: LyricLine
    let currentTime: TimeInterval
    let config: AMLLLineConfig
    let isScrolling: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    // 🔑 清理歌词文本：移除时间戳标记如 [02:47.49]
    private var cleanedText: String {
        let pattern = "\\[\\d{2}:\\d{2}[:.]*\\d{0,3}\\]"
        return line.text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 🔑 根据是否有逐字时间信息选择渲染方式
            if line.hasSyllableSync && config.isCurrent && !isScrolling {
                SyllableSyncTextView(
                    words: line.words,
                    currentTime: currentTime,
                    fontSize: 24
                )
                .scaleEffect(config.scale, anchor: .leading)
            } else {
                Text(cleanedText)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(config.isCurrent ? .white : .white.opacity(0.6))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)  // 🔑 允许文本自然换行，不截断
                    .scaleEffect(config.scale, anchor: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(minHeight: 50, alignment: .center)  // 🔑 内容自适应高度 (hug content)
        .background(
            Group {
                if isScrolling && isHovering {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.08))
                        .padding(.horizontal, 8)
                }
            }
        )
        .blur(radius: config.blur)
        .opacity(config.opacity)
        .animation(.interpolatingSpring(
            mass: 2, stiffness: 100, damping: 25, initialVelocity: 0
        ), value: config.scale)
        .animation(.interpolatingSpring(
            mass: 2, stiffness: 100, damping: 25, initialVelocity: 0
        ), value: config.blur)
        .animation(.interpolatingSpring(
            mass: 2, stiffness: 100, damping: 25, initialVelocity: 0
        ), value: config.opacity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            if isScrolling { isHovering = hovering }
        }
    }
}

// MARK: - AMLL Prelude Dots Line

struct AMLLPreludeDotsLine: View {
    let line: LyricLine
    let lyrics: [LyricLine]
    let index: Int
    let firstRealLyricIndex: Int
    let currentTime: TimeInterval

    private var nextLineStartTime: TimeInterval {
        if index == 0 && firstRealLyricIndex < lyrics.count {
            return lyrics[firstRealLyricIndex].startTime
        }
        for nextIndex in max(index + 1, firstRealLyricIndex)..<lyrics.count {
            let nextLine = lyrics[nextIndex]
            if !isPreludeEllipsis(nextLine.text) {
                return nextLine.startTime
            }
        }
        return line.endTime
    }

    private let fadeOutDuration: TimeInterval = 0.7

    var body: some View {
        let totalDuration = nextLineStartTime - line.startTime
        let dotsActiveDuration = max(0.1, totalDuration - fadeOutDuration)
        let segmentDuration = dotsActiveDuration / 3.0

        let dotProgresses: [CGFloat] = (0..<3).map { idx in
            let dotStartTime = line.startTime + segmentDuration * Double(idx)
            let dotEndTime = line.startTime + segmentDuration * Double(idx + 1)
            if currentTime <= dotStartTime { return 0.0 }
            else if currentTime >= dotEndTime { return 1.0 }
            else {
                let progress = (currentTime - dotStartTime) / (dotEndTime - dotStartTime)
                return CGFloat(sin(progress * .pi / 2))
            }
        }

        let fadeOutProgress: CGFloat = {
            let fadeStartTime = line.startTime + dotsActiveDuration
            if currentTime < fadeStartTime { return 0.0 }
            else if currentTime >= nextLineStartTime { return 1.0 }
            else { return CGFloat((currentTime - fadeStartTime) / fadeOutDuration) }
        }()

        let overallOpacity = 1.0 - fadeOutProgress
        let breathingPhase = sin(currentTime * .pi * 0.8)

        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    let progress = dotProgresses[dotIndex]
                    let isLightingUp = progress > 0.0 && progress < 1.0
                    let breathingScale: CGFloat = isLightingUp ? (1.0 + CGFloat(breathingPhase) * 0.06) : 1.0

                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .opacity(0.25 + progress * 0.75)
                        .scaleEffect((0.85 + progress * 0.15) * breathingScale)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
        .opacity(overallOpacity)
        .blur(radius: fadeOutProgress * 8)
    }

    private func isPreludeEllipsis(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let patterns = ["...", "…", "⋯", "。。。", "···", "・・・"]
        return patterns.contains(trimmed) || trimmed.isEmpty
    }
}

// MARK: - Syllable Sync Text View (逐字高亮)

struct SyllableSyncTextView: View {
    let words: [LyricWord]
    let currentTime: TimeInterval
    let fontSize: CGFloat

    var body: some View {
        // 🔑 使用 HStack 排列每个字/词，保留原有空格
        HStack(spacing: 0) {
            ForEach(words) { word in
                SyllableWordView(
                    word: word,
                    currentTime: currentTime,
                    fontSize: fontSize
                )
            }
        }
    }
}

// MARK: - 进度裁剪形状 (从左到右裁剪)

struct ProgressClipShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: 0, y: 0, width: rect.width * progress, height: rect.height))
        return path
    }
}

// MARK: - Single Word View with Highlight Animation (AMLL-style)

struct SyllableWordView: View {
    let word: LyricWord
    let currentTime: TimeInterval
    let fontSize: CGFloat

    // 🔑 AMLL 参数
    private let brightOpacity: CGFloat = 1.0       // 已唱部分不透明度
    private let darkOpacity: CGFloat = 0.35        // 未唱部分不透明度

    // 🔑 AMLL 风格：进度根据时间轴精确计算（线性插值）
    private var progress: CGFloat {
        let wordDuration = word.endTime - word.startTime
        guard wordDuration > 0 else { return currentTime >= word.startTime ? 1.0 : 0.0 }

        if currentTime < word.startTime {
            return 0.0
        } else if currentTime >= word.endTime {
            return 1.0
        } else {
            // 🔑 线性进度：直接按时间比例
            return CGFloat((currentTime - word.startTime) / wordDuration)
        }
    }

    // 是否正在高亮（0 < progress < 1）
    private var isHighlighting: Bool {
        progress > 0 && progress < 1
    }

    // 是否完成高亮（progress >= 1）
    private var isCompleted: Bool {
        progress >= 1
    }

    // 🔑 AMLL: 强调词条件 - 持续时间 >= 1秒 且 字符数 1-7
    private var isEmphasis: Bool {
        let duration = word.endTime - word.startTime
        let charCount = word.word.count
        return duration >= 1.0 && charCount >= 1 && charCount <= 7
    }

    // 🔑 AMLL: 强调词缩放比例
    // 1200-2000ms: 1.07, 2000-3000ms: 1.08, >=3000ms: 1.10
    private var emphasisScale: CGFloat {
        let duration = (word.endTime - word.startTime) * 1000  // ms
        let amount: CGFloat
        if duration < 2000 {
            amount = 0.7
        } else if duration < 3000 {
            amount = 0.8
        } else {
            amount = 1.0
        }
        return 1.0 + 0.1 * amount  // 1.07, 1.08, 1.10
    }

    // 🔑 AMLL: Float 上抬量 = 0.05em
    private var liftAmount: CGFloat {
        fontSize * 0.05  // 0.05em
    }

    // 当前缩放比例（sin 曲线平滑）
    private var currentScale: CGFloat {
        guard isEmphasis && isHighlighting else { return 1.0 }
        // 🔑 使用 sin 曲线让缩放更自然
        return 1.0 + sin(progress * .pi) * (emphasisScale - 1.0)
    }

    // 🔑 当前 Y 轴偏移（高亮时上移，完成后保持）
    private var currentLift: CGFloat {
        if isHighlighting {
            // 正在高亮：逐渐上抬
            return -liftAmount * progress
        } else if isCompleted {
            // 已完成：保持上抬位置
            return -liftAmount
        } else {
            return 0
        }
    }

    // 🔑 计算文字颜色：根据进度决定亮度
    private var textColor: Color {
        if isCompleted {
            return .white.opacity(brightOpacity)
        } else if isHighlighting {
            // 🔑 正在高亮的字：整体变亮（简化实现，不截断）
            return .white.opacity(darkOpacity + (brightOpacity - darkOpacity) * progress)
        } else {
            return .white.opacity(darkOpacity)
        }
    }

    var body: some View {
        // 🔑 简单实现：根据进度改变整个字的亮度，不使用 mask 避免截断
        Text(word.word)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(textColor)
            // 🔑 AMLL 风格：强调词缩放 + 上抬动画
            .scaleEffect(currentScale, anchor: .bottom)
            .offset(y: currentLift)
            // 🔑 不使用显式动画，让进度直接跟随 currentTime 变化
    }
}

/// 间奏加载点视图 - 基于播放时间精确控制动画
struct InterludeDotsView: View {
    let startTime: TimeInterval  // 间奏开始时间（前一句歌词结束时间）
    let endTime: TimeInterval    // 间奏结束时间（下一句歌词开始时间）
    let currentTime: TimeInterval  // 🔑 改为直接接收 currentTime

    // 🔑 淡出动画时长（算入总时长）
    private let fadeOutDuration: TimeInterval = 0.7

    // 🔑 是否在间奏时间范围内
    private var isInInterlude: Bool {
        currentTime >= startTime && currentTime < endTime
    }

    var body: some View {
        // 🔑 总时长，三个点只占用 (总时长 - 淡出时长)
        let totalDuration = endTime - startTime
        let dotsActiveDuration = max(0.1, totalDuration - fadeOutDuration)
        let segmentDuration = dotsActiveDuration / 3.0

        // 计算每个点的精细进度
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = startTime + segmentDuration * Double(index)
            let dotEndTime = startTime + segmentDuration * Double(index + 1)

            if currentTime <= dotStartTime {
                return 0.0
            } else if currentTime >= dotEndTime {
                return 1.0
            } else {
                let progress = (currentTime - dotStartTime) / (dotEndTime - dotStartTime)
                return CGFloat(sin(progress * .pi / 2))
            }
        }

        // 🔑 计算整体淡出透明度和模糊
        let fadeOutProgress: CGFloat = {
            let fadeStartTime = startTime + dotsActiveDuration
            if currentTime < fadeStartTime {
                return 0.0
            } else if currentTime >= endTime {
                return 1.0
            } else {
                let progress = (currentTime - fadeStartTime) / fadeOutDuration
                return CGFloat(progress)
            }
        }()

        let overallOpacity = isInInterlude ? (1.0 - fadeOutProgress) : 0.0
        let overallBlur = fadeOutProgress * 8

        // 🔑 呼吸动画：降低频率到 0.8Hz（更慢更柔和）
        let breathingPhase = sin(currentTime * .pi * 0.8)

        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let progress = dotProgresses[dotIndex]
                // 🔑 只有正在点亮过程中的点（0 < progress < 1）才有呼吸动画
                let isLightingUp = progress > 0.0 && progress < 1.0
                let breathingScale: CGFloat = isLightingUp ? (1.0 + CGFloat(breathingPhase) * 0.06) : 1.0

                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .opacity(0.25 + progress * 0.75)
                    .scaleEffect((0.85 + progress * 0.15) * breathingScale)
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .opacity(overallOpacity)
        .blur(radius: overallBlur)
        .animation(.easeOut(duration: 0.2), value: isInInterlude)
    }
}

/// 前奏加载点视图 - 替换 "..." 省略号歌词
struct PreludeDotsView: View {
    let startTime: TimeInterval  // 前奏/间奏开始时间
    let endTime: TimeInterval    // 前奏/间奏结束时间（下一句歌词开始时间）
    @ObservedObject var musicController: MusicController

    // 🔑 淡出动画时长（算入总时长）
    private let fadeOutDuration: TimeInterval = 0.7

    private var currentTime: TimeInterval {
        musicController.currentTime
    }

    var body: some View {
        // 🔑 总时长 = 原时长，但三个点只占用 (总时长 - 淡出时长)
        let totalDuration = endTime - startTime
        let dotsActiveDuration = max(0.1, totalDuration - fadeOutDuration)
        let segmentDuration = dotsActiveDuration / 3.0

        // 计算每个点的精细进度
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = startTime + segmentDuration * Double(index)
            let dotEndTime = startTime + segmentDuration * Double(index + 1)

            if currentTime <= dotStartTime {
                return 0.0
            } else if currentTime >= dotEndTime {
                return 1.0
            } else {
                let progress = (currentTime - dotStartTime) / (dotEndTime - dotStartTime)
                return CGFloat(sin(progress * .pi / 2))
            }
        }

        // 🔑 计算整体淡出透明度和模糊
        let fadeOutProgress: CGFloat = {
            let fadeStartTime = startTime + dotsActiveDuration
            if currentTime < fadeStartTime {
                return 0.0
            } else if currentTime >= endTime {
                return 1.0
            } else {
                let progress = (currentTime - fadeStartTime) / fadeOutDuration
                return CGFloat(progress)
            }
        }()

        let overallOpacity = 1.0 - fadeOutProgress
        let overallBlur = fadeOutProgress * 8

        // 🔑 呼吸动画：降低频率到 0.8Hz
        let breathingPhase = sin(currentTime * .pi * 0.8)

        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let progress = dotProgresses[index]
                    // 🔑 只有正在点亮过程中的点（0 < progress < 1）才有呼吸动画
                    let isLightingUp = progress > 0.0 && progress < 1.0
                    let breathingScale: CGFloat = isLightingUp ? (1.0 + CGFloat(breathingPhase) * 0.06) : 1.0

                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .opacity(0.25 + progress * 0.75)
                        .scaleEffect((0.85 + progress * 0.15) * breathingScale)
                        .animation(.easeOut(duration: 0.3), value: progress)
                }
            }
            Spacer(minLength: 0)
        }
        // 🔑 移除 padding，因为外层 VStack 已经有 padding 了
        .padding(.vertical, 8)
        .opacity(overallOpacity)
        .blur(radius: overallBlur)
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
            let fadeOutDuration: TimeInterval = 0.35 // 与动画时长同步

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
            .font(.system(size: 23, weight: .medium)) // 🔑 去掉 .rounded，与歌词字体保持一致
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
