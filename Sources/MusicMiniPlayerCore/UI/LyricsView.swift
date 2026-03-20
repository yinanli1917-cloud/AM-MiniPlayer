import SwiftUI
import AppKit
import Translation

public struct LyricsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    @State private var isHovering: Bool = false
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var isManualScrolling: Bool = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var showControls: Bool = true
    // 🔑 控件模糊渐入效果（初始值为 0，在 onAppear/页面切换时触发动画）
    @State private var controlsBlurAmount: CGFloat = 0
    @State private var controlsOffsetY: CGFloat = 0
    @Binding var currentPage: PlayerPage
    var openWindow: OpenWindowAction?
    var onHide: (() -> Void)?
    var onExpand: (() -> Void)?
    @State private var lastVelocity: CGFloat = 0
    @State private var scrollLocked: Bool = false
    @State private var hasTriggeredSlowScroll: Bool = false

    // 🔑 手动滚动 Y 轴偏移量
    @State private var manualScrollOffset: CGFloat = 0  // 显示用（含橡皮筋）
    @State private var rawScrollOffset: CGFloat = 0     // 原始累积（不含橡皮筋）
    // 🔑 行高度缓存（用于精确计算位置）
    @State private var lineHeights: [Int: CGFloat] = [:]
    // 🔑 手动滚动时锁定的行索引（防止歌词在手动滚动时跟随播放移动）
    @State private var lockedLineIndex: Int? = nil
    // 🔑 AMLL 波浪效果：每行的目标 currentIndex（用于错开动画触发时间）
    @State private var lineTargetIndices: [Int: Int] = [:]
    // 🔑 上一次的 currentIndex（用于检测变化并触发波浪）
    @State private var lastCurrentIndex: Int = -1
    // 🔑 波浪动画 Work Item（用于取消未完成的动画）
    @State private var waveAnimationWorkItems: [DispatchWorkItem] = []

    // 🔑 性能优化：缓存总高度和累积高度，避免滚动时重复计算
    @State private var cachedTotalContentHeight: CGFloat = 0
    @State private var cachedAccumulatedHeights: [Int: CGFloat] = [:]  // [lineIndex: accumulatedHeight]
    @State private var heightCacheInvalidated: Bool = true
    // 🔑 缓存歌词容器高度，供 @escaping 闭包使用（GeometryProxy 不可逃逸）
    @State private var lyricsContainerHeight: CGFloat = 300

    // 🔑 系统翻译会话配置 (仅 macOS 15.0+)
    // 使用 Any 类型来避免编译时的可用性检查
    @State private var translationSessionConfigAny: Any?
    // 🔑 翻译触发器本地状态（用于强制视图重建）
    @State private var localTranslationTrigger: Int = 0

    // 🔑 全屏封面模式（从 UserDefaults 读取）
    @State private var fullscreenAlbumCover: Bool = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")

    public init(currentPage: Binding<PlayerPage>, openWindow: OpenWindowAction? = nil, onHide: (() -> Void)? = nil, onExpand: (() -> Void)? = nil) {
        self._currentPage = currentPage
        self.openWindow = openWindow
        self.onHide = onHide
        self.onExpand = onExpand
    }

    // 🔑 更新翻译会话配置 (仅 macOS 15.0+)
    private func updateTranslationSessionConfig() {
        if #available(macOS 15.0, *) {
            let targetLang = Locale.Language(identifier: lyricsService.translationLanguage)

            // 检测歌词源语言（如果已有歌词）
            if !lyricsService.lyrics.isEmpty {
                let lyricTexts = lyricsService.lyrics.map { $0.text }
                if let sourceLang = TranslationService.detectLanguage(for: lyricTexts) {
                    translationSessionConfigAny = TranslationSession.Configuration(
                        source: sourceLang,
                        target: targetLang
                    )
                    return
                }
            }

            // 默认配置（source 为 nil 让系统自动检测）
            translationSessionConfigAny = TranslationSession.Configuration(
                source: nil,
                target: targetLang
            )
        }
    }

    public var body: some View {
        ZStack {
            // Background - 全屏模式用流体渐变，普通模式用 Liquid Glass
            if fullscreenAlbumCover {
                AdaptiveFluidBackground(artwork: musicController.currentArtwork)
                    .id(musicController.currentTrackTitle)  // 🔑 强制在歌曲切换时重建
                    .ignoresSafeArea()
            } else {
                LiquidBackgroundView(artwork: musicController.currentArtwork)
                    .ignoresSafeArea()
            }

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
                    // 🔑 性能优化核心思路：
                    // - 自动滚动：每行单独计算偏移（波浪动画）
                    // - 手动滚动：整个容器统一偏移（避免重新计算每行）
                    // 🔑 使用歌曲 ID 强制重建整个歌词视图，避免切歌时视图残留
                    let lyricsViewID = "\(musicController.currentTrackTitle)-\(musicController.currentArtist)"
                    GeometryReader { geo in
                        let containerHeight = geo.size.height
                        let controlBarHeight: CGFloat = 120
                        let currentIndex = lyricsService.currentLineIndex ?? 0
                        // 🔑 同步容器高度到 @State（供 @escaping 滚动闭包使用）
                        let _ = updateLyricsContainerHeight(containerHeight)

                        // 🔑 锚点位置：当前行在容器的 24% 高度处
                        let anchorY = (containerHeight - controlBarHeight) * 0.24

                        let _ = updateLyricsContainerHeight(containerHeight)
                        ZStack(alignment: .topLeading) {  // 🔑 使用 ZStack 实现 AMLL 风格布局
                            ForEach(Array(lyricsService.lyrics.enumerated()), id: \.element.id) { index, line in
                                if index == 0 || index >= lyricsService.firstRealLyricIndex {
                                    // 🔑 性能优化：手动滚动时使用锁定的基础偏移（不包含 manualScrollOffset）
                                    // manualScrollOffset 在容器级别应用，避免触发每行重新计算
                                    let lineOffset: CGFloat = {
                                        if isManualScrolling {
                                            // 🔑 手动滚动时：所有行统一用 lockedLineIndex
                                            // 不能用 lockedLineTargetIndices（波浪动画逐行快照），
                                            // 否则不同行锚定到不同 targetIndex → 基础偏移不一致 → 行重叠
                                            let frozenTargetIndex = lockedLineIndex ?? currentIndex
                                            return anchorY - calculateAccumulatedHeight(upTo: frozenTargetIndex)
                                        } else {
                                            // 自动滚动：使用该行的目标索引计算偏移（波浪动画）
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
                                            // 普通歌词行 + 间奏动画
                                            VStack(spacing: 0) {
                                                LyricLineView(
                                                    line: line,
                                                    index: index,
                                                    currentIndex: currentIndex,
                                                    isScrolling: isManualScrolling,
                                                    currentTime: musicController.currentTime,
                                                    onTap: {
                                                        autoScrollTimer?.invalidate()
                                                        autoScrollTimer = nil
                                                        isManualScrolling = false
                                                        lyricsService.isManualScrolling = false  // 同步到 LyricsService
                                                        lockedLineIndex = nil
                                                        rawScrollOffset = 0
                                                        manualScrollOffset = 0
                                                        musicController.seek(to: line.startTime)
                                                    },
                                                    showTranslation: lyricsService.showTranslation,
                                                    isTranslating: lyricsService.isTranslating
                                                )
                                                .padding(.horizontal, 32)

                                                // 🔑 间奏检测：当前行结束到下一行开始 >= 5秒时显示动画
                                                if let interludeInfo = checkForInterlude(at: index) {
                                                    InterludeDotsView(
                                                        startTime: interludeInfo.startTime,
                                                        endTime: interludeInfo.endTime,
                                                        currentTime: musicController.currentTime
                                                    )
                                                    .frame(height: 30)
                                                    .padding(.top, 8)
                                                    .padding(.horizontal, 32)
                                                }
                                            }
                                        }
                                    }
                                    // 🔑 存储每行高度用于计算偏移
                                    .background(
                                        GeometryReader { lineGeo in
                                            Color.clear.onAppear {
                                                if lineHeights[index] != lineGeo.size.height {
                                                    lineHeights[index] = lineGeo.size.height
                                                    heightCacheInvalidated = true  // 🔑 使缓存失效
                                                }
                                            }
                                            .onChange(of: lineGeo.size.height) { _, newHeight in
                                                if lineHeights[index] != newHeight {
                                                    lineHeights[index] = newHeight
                                                    heightCacheInvalidated = true  // 🔑 使缓存失效
                                                }
                                            }
                                        }
                                    )
                                    // 🔑 AMLL 核心：每行有自己的 Y 偏移（基于该行的目标索引）
                                    .offset(y: lineOffset + calculateLinePosition(index: index))
                                    // 🔑 每行单独的 spring 动画（手动滚动时禁用）
                                    // 🔑 监听完整偏移值（lineOffset + linePosition），
                                    // 这样翻译导致的行高变化也会触发平滑动画
                                    .animation(
                                        isManualScrolling ? nil : .interpolatingSpring(
                                            mass: 1,
                                            stiffness: 100,
                                            damping: 16.5,
                                            initialVelocity: 0
                                        ),
                                        value: {
                                            let fullOffset = lineOffset + calculateLinePosition(index: index)
                                            return isManualScrolling ? 0 : fullOffset
                                        }()
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        // 🔑 性能关键：手动滚动偏移在容器级别应用，而不是每行单独计算
                        // 这样 manualScrollOffset 变化只会触发一次 transform，而不是 N 次（N = 歌词行数）
                        // 🔑 不用三元！isManualScrolling=false 时三元直接跳 0，
                        // manualScrollOffset 的动画没人读 → 容器跳变 → 歌词卡顿
                        .offset(y: manualScrollOffset)
                    }
                    .modifier(BottomFadeMask(isActive: showControls))
                    // 🔑 强制在歌曲切换时重建整个 GeometryReader，避免 ZStack 视图残留
                    .id(lyricsViewID)
                    // 🔑 滚轮事件监听（与 PlaylistView 一致）
                    .contentShape(Rectangle())
                    .scrollDetectionWithVelocity(
                        onScrollStarted: {
                            // 🔑 滚动开始时立即锁定状态，之后滚动只更新 manualScrollOffset
                            autoScrollTimer?.invalidate()

                            // 先更新缓存（同步，但只在需要时）
                            if heightCacheInvalidated {
                                updateHeightCache()
                            }

                            // 🔑 锁定当前状态
                            let currentIdx = lyricsService.currentLineIndex ?? 0
                            lockedLineIndex = currentIdx
                            rawScrollOffset = manualScrollOffset
                            isManualScrolling = true
                            lyricsService.isManualScrolling = true  // 同步到 LyricsService

                            lastVelocity = 0
                            scrollLocked = false
                            hasTriggeredSlowScroll = false
                        },
                        onScrollEnded: {
                            // 🔑 松手后立即弹回边界
                            let (maxUp, maxDown) = scrollBounds()
                            if rawScrollOffset > maxUp || rawScrollOffset < -maxDown {
                                rawScrollOffset = min(maxUp, max(-maxDown, rawScrollOffset))
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    manualScrollOffset = rawScrollOffset
                                }
                            }

                            // 🔑 2 秒后 spring 回当前播放行
                            autoScrollTimer?.invalidate()
                            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [self] _ in
                                lockedLineIndex = nil
                                rawScrollOffset = 0
                                withAnimation(.interpolatingSpring(
                                    mass: 1,
                                    stiffness: 100,
                                    damping: 16.5,
                                    initialVelocity: 0
                                )) {
                                    isManualScrolling = false
                                    lyricsService.isManualScrolling = false
                                    manualScrollOffset = 0
                                }
                                scrollLocked = false
                                hasTriggeredSlowScroll = false

                                // 🔑 恢复后如果鼠标在窗口内则显示控件（带 blur+offset 动画）
                                if isHovering {
                                    controlsBlurAmount = 10
                                    controlsOffsetY = 30
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                        showControls = true
                                        controlsBlurAmount = 0
                                        controlsOffsetY = 0
                                    }
                                }
                            }
                        },
                        onScrollWithVelocity: { deltaY, velocity in
                            // 🔑 Apple 风格橡皮筋：raw 累积 + overscroll 衰减
                            rawScrollOffset += deltaY
                            let (maxUp, maxDown) = scrollBounds()
                            let dim = max(lyricsContainerHeight * 0.4, 120)

                            // 🔑 overscroll 区域：每帧衰减 rawScrollOffset 向边界靠拢
                            // 模拟原生橡皮筋的"回拉力"，而非仅在松手后弹回
                            if rawScrollOffset > maxUp {
                                let overshoot = rawScrollOffset - maxUp
                                rawScrollOffset = maxUp + overshoot * 0.92
                                manualScrollOffset = maxUp + rubberBand(rawScrollOffset - maxUp, dim)
                            } else if rawScrollOffset < -maxDown {
                                let overshoot = rawScrollOffset + maxDown  // 负值
                                rawScrollOffset = -maxDown + overshoot * 0.92
                                manualScrollOffset = -maxDown + rubberBand(rawScrollOffset + maxDown, dim)
                            } else {
                                manualScrollOffset = rawScrollOffset
                            }

                            let absVelocity = abs(velocity)
                            let threshold: CGFloat = 800

                            // 🔑 与 PlaylistView 完全一致的逻辑
                            if deltaY < 0 {
                                // 往上滚：隐藏控件
                                if showControls {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                        showControls = false
                                        controlsBlurAmount = 10
                                        controlsOffsetY = 30
                                    }
                                }
                                scrollLocked = true
                            } else if absVelocity >= threshold {
                                // 快速滚动：隐藏控件
                                if !scrollLocked {
                                    scrollLocked = true
                                }
                                if showControls {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                        showControls = false
                                        controlsBlurAmount = 10
                                        controlsOffsetY = 30
                                    }
                                }
                            } else if deltaY > 0 && !scrollLocked && !hasTriggeredSlowScroll {
                                // 慢速往下滚：显示控件
                                hasTriggeredSlowScroll = true
                                if !showControls {
                                    controlsBlurAmount = 10
                                    controlsOffsetY = 30
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                        showControls = true
                                        controlsBlurAmount = 0
                                        controlsOffsetY = 0
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
                                // 🔑 已改用 BottomFadeMask，不需要模糊背景
                                Color.clear.frame(height: 1).allowsHitTesting(false)

                                SharedBottomControls(
                                    currentPage: $currentPage,
                                    isHovering: $isHovering,
                                    showControls: $showControls,
                                    isProgressBarHovering: $isProgressBarHovering,
                                    dragPosition: $dragPosition,
                                    translationButton: !lyricsService.lyrics.isEmpty ? AnyView(TranslationButtonView(lyricsService: lyricsService)) : nil
                                )
                            }
                            // 🔑 blur + move-in 动画
                            .blur(radius: controlsBlurAmount)
                            .offset(y: controlsOffsetY)
                        }
                        .allowsHitTesting(showControls)
                        .opacity(showControls ? 1 : 0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showControls)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controlsBlurAmount)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controlsOffsetY)
                    )
                }
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
            // 🔑 Hide/Expand 按钮 - 翻译按钮已移到底部进度条上方
            if showControls {
                HStack(spacing: 8) {
                    // Hide/Expand 按钮
                    if onExpand != nil {
                        // 菜单栏模式：显示展开按钮
                        ExpandButtonView(onExpand: onExpand!)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    } else if onHide != nil {
                        // 浮窗模式：显示收起按钮
                        HideButtonView(onHide: onHide!)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    } else {
                        // 无回调时的默认行为
                        HideButtonView(onHide: {
                            if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel }) {
                                window.orderOut(nil)
                            }
                        })
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .padding(12)
            }
        }
        .onHover { hovering in
            isHovering = hovering
            // 🔑 鼠标离开窗口时总是隐藏控件（无论是否在滚动）
            if !hovering {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showControls = false
                    controlsBlurAmount = 10
                    controlsOffsetY = 30
                }
            }
            // 🔑 只在非滚动状态时，鼠标进入显示控件
            else if !isManualScrolling {
                // 🔑 进入时重置模糊和位移状态
                controlsBlurAmount = 10
                controlsOffsetY = 30
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showControls = true
                    controlsBlurAmount = 0
                    controlsOffsetY = 0
                }
            }
            // 滚动时鼠标进入不自动显示控件（由scroll逻辑控制）
        }
        // 🔑 当切换到歌词页面时，显示控件（因为是从hover状态切换过来的）
        .onChange(of: currentPage) { _, newPage in
            if newPage == .lyrics {
                // 🔑 假设是从 hover 状态切换过来的，设置 isHovering = true
                isHovering = true
                // 🔑 触发 blur + move-in 动画
                controlsBlurAmount = 10
                controlsOffsetY = 30
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showControls = true
                    controlsBlurAmount = 0
                    controlsOffsetY = 0
                }
            }
        }
        .onAppear {
            debugPrint("📝 [LyricsView] onAppear - track: '\(musicController.currentTrackTitle)' by '\(musicController.currentArtist)'\n")
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration)
            // 🔑 macOS 15.0+: 初始化翻译会话配置
            if #available(macOS 15.0, *) {
                updateTranslationSessionConfig()
            }
        }
          .onChange(of: musicController.currentTrackTitle) {
            debugPrint("📝 [LyricsView] onChange(currentTrackTitle) - track: '\(musicController.currentTrackTitle)' by '\(musicController.currentArtist)'\n")
            // 🔑 歌曲切换时取消未完成的波浪动画
            cancelWaveAnimations()
            lineTargetIndices.removeAll()
            lastCurrentIndex = -1
            // 🔑 使高度缓存失效
            heightCacheInvalidated = true
            lineHeights.removeAll()

            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration)
        }
        // 🔑 macOS 15.0+: 歌词加载完成后更新翻译会话配置
        .onChange(of: lyricsService.lyrics.count) { _, newCount in
            if #available(macOS 15.0, *), newCount > 0 {
                updateTranslationSessionConfig()
            }
            // 🔑 歌词变化时使缓存失效
            heightCacheInvalidated = true
        }
        // 🔑 macOS 15.0+: 歌词加载完成时（isLoading: true -> false），检查是否需要触发系统翻译
        .onChange(of: lyricsService.isLoading) { oldValue, newValue in
            if #available(macOS 15.0, *) {
                // 从加载中变为加载完成
                if oldValue && !newValue && !lyricsService.lyrics.isEmpty {
                    updateTranslationSessionConfig()
                }
            }
        }
        // 🔑 macOS 15.0+: 翻译语言变化时更新配置
        .onChange(of: lyricsService.translationLanguage) { _, _ in
            if #available(macOS 15.0, *) {
                updateTranslationSessionConfig()
            }
        }
        // 🔑 macOS 15.0+: 翻译开关变化时更新配置（确保重新触发翻译）
        .onChange(of: lyricsService.showTranslation) { _, newValue in
            // 🔑 翻译开关变化会影响行高，但不立即使缓存失效
            // 让 SwiftUI 的自然布局动画先执行，然后延迟更新缓存
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                heightCacheInvalidated = true
            }
            if #available(macOS 15.0, *), newValue {
                updateTranslationSessionConfig()
            }
        }
        // 🔑 macOS 15.0+: 翻译请求触发器变化时，确保配置已更新
        .onChange(of: lyricsService.translationRequestTrigger) { _, newValue in
            if #available(macOS 15.0, *) {
                // 确保 config 已更新，这样 .translationTask 才能正确触发
                updateTranslationSessionConfig()
                // 🔑 更新本地触发器，强制视图重建
                localTranslationTrigger = newValue
            }
        }
        // 🔑 翻译状态变化会影响行高（显示/隐藏加载动画和翻译内容）
        .onChange(of: lyricsService.isTranslating) { _, _ in
            // 🔑 延迟更新缓存，让自然动画先执行
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                heightCacheInvalidated = true
            }
        }
        .onChange(of: musicController.currentTime) {
            lyricsService.updateCurrentTime(musicController.currentTime)
        }
        // 🔑 监听 LyricsService 的手动滚动状态（由 SnappablePanel 触发）
        .onChange(of: lyricsService.isManualScrolling) { _, newValue in
            if newValue && !isManualScrolling {
                // SnappablePanel 触发了手动滚动模式
                if heightCacheInvalidated {
                    updateHeightCache()
                }
                let currentIdx = lyricsService.currentLineIndex ?? 0
                lockedLineIndex = currentIdx
                isManualScrolling = true

                lastVelocity = 0
                scrollLocked = false
                hasTriggeredSlowScroll = false

                // 启动 2 秒后自动恢复的计时器
                autoScrollTimer?.invalidate()
                autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [self] _ in
                    isManualScrolling = false
                    lyricsService.isManualScrolling = false
                    lockedLineIndex = nil

                    withAnimation(.interpolatingSpring(
                        mass: 1,
                        stiffness: 100,
                        damping: 16.5,
                        initialVelocity: 0
                    )) {
                        manualScrollOffset = 0
                    }
                    rawScrollOffset = 0
                    scrollLocked = false
                    hasTriggeredSlowScroll = false
                }
                RunLoop.main.add(autoScrollTimer!, forMode: .common)
            }
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
            // 只有当：1. 有错误（No lyrics）2. 用户没有手动打开歌词页面 3. 当前在歌词页面
            // 才自动跳回专辑页面
            if newError != nil && !musicController.userManuallyOpenedLyrics && currentPage == .lyrics {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    currentPage = .album
                }
            }
        }
        // 🔑 监听全屏封面设置变化
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let newValue = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")
            if newValue != fullscreenAlbumCover {
                withAnimation(.easeInOut(duration: 0.3)) {
                    fullscreenAlbumCover = newValue
                }
            }
        }
        // 🔑 macOS 15.0+: 系统翻译集成
        .modifier(SystemTranslationModifier(
            translationSessionConfigAny: translationSessionConfigAny,
            lyricsService: lyricsService,
            translationTrigger: localTranslationTrigger
        ))
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
                // 🔑 已改用 BottomFadeMask，不需要模糊背景
                Color.clear.frame(height: 1).allowsHitTesting(false)

                SharedBottomControls(
                    currentPage: $currentPage,
                    isHovering: $isHovering,
                    showControls: $showControls,
                    isProgressBarHovering: $isProgressBarHovering,
                    dragPosition: $dragPosition
                )
                .padding(.bottom, 0)
            }
        }
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
        let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・"]
        return ellipsisPatterns.contains(trimmed) || trimmed.isEmpty
    }

    /// 🔑 检测是否有间奏（当前行结束到下一行开始 >= 5秒）
    private func checkForInterlude(at index: Int) -> (startTime: TimeInterval, endTime: TimeInterval)? {
        let lyrics = lyricsService.lyrics
        guard index + 1 < lyrics.count else { return nil }

        let currentLine = lyrics[index]
        let nextLine = lyrics[index + 1]

        // 跳过省略号行
        if isPreludeEllipsis(currentLine.text) || isPreludeEllipsis(nextLine.text) {
            return nil
        }

        // 计算间隔：下一行开始时间 - 当前行结束时间
        let gap = nextLine.startTime - currentLine.endTime
        if gap >= 5.0 {
            return (startTime: currentLine.endTime, endTime: nextLine.startTime)
        }
        return nil
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - 滚动边界 + Apple 橡皮筋
    // ═══════════════════════════════════════════════════════════════════════════════

    /// Apple UIScrollView 橡皮筋公式：f(x) = d * (1 - 1/(x*c/d + 1))
    private func rubberBand(_ offset: CGFloat, _ dimension: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        let absX = abs(offset)
        let result = (1.0 - (1.0 / ((absX * c / dimension) + 1.0))) * dimension
        return offset < 0 ? -result : result
    }

    /// 滚动边界：第一行到顶部 / 最后一行到底部
    private func scrollBounds() -> (maxUp: CGFloat, maxDown: CGFloat) {
        let totalH = calculateTotalContentHeight()
        let idx = lockedLineIndex ?? (lyricsService.currentLineIndex ?? 0)
        let curOffset = calculateAccumulatedHeight(upTo: idx)
        let containerH = lyricsContainerHeight
        let anchorY = (containerH - 120) * 0.24
        let visibleBottom = (containerH - 120) - anchorY  // 锚点以下的可见区域

        let maxUp = max(0, curOffset - anchorY)
        let maxDown = max(0, totalH - curOffset - visibleBottom)
        return (maxUp, maxDown)
    }

    /// 🔑 计算从第一行到指定行的累积高度（用于 VStack offset）
    /// 使用缓存优化，避免滚动时重复计算
    private func calculateAccumulatedHeight(upTo targetIndex: Int) -> CGFloat {
        // 🔑 如果缓存有效，直接返回缓存值
        if !heightCacheInvalidated, let cached = cachedAccumulatedHeights[targetIndex] {
            return cached
        }

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
        // 🔑 复用累积高度缓存
        return calculateAccumulatedHeight(upTo: index)
    }

    /// 🔑 同步容器高度到 @State（供 @escaping 闭包使用，GeometryProxy 不可逃逸）
    private func updateLyricsContainerHeight(_ height: CGFloat) {
        if lyricsContainerHeight != height {
            DispatchQueue.main.async { lyricsContainerHeight = height }
        }
    }

    /// 🔑 计算内容总高度（使用缓存）
    private func calculateTotalContentHeight() -> CGFloat {
        // 🔑 如果缓存有效，直接返回缓存值
        if !heightCacheInvalidated && cachedTotalContentHeight > 0 {
            return cachedTotalContentHeight
        }

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

    /// 🔑 更新高度缓存（在歌词变化或行高变化时调用）
    private func updateHeightCache() {
        let spacing: CGFloat = 6
        let defaultHeight: CGFloat = 36

        let renderedIndices = lyricsService.lyrics.enumerated()
            .filter { index, _ in index == 0 || index >= lyricsService.firstRealLyricIndex }
            .map { $0.offset }

        var accumulatedHeight: CGFloat = 0
        var newAccumulatedHeights: [Int: CGFloat] = [:]
        var totalHeight: CGFloat = 0

        for (i, lineIndex) in renderedIndices.enumerated() {
            newAccumulatedHeights[lineIndex] = accumulatedHeight
            let height = lineHeights[lineIndex] ?? defaultHeight
            totalHeight += height
            if i < renderedIndices.count - 1 {
                totalHeight += spacing
                accumulatedHeight += height + spacing
            } else {
                accumulatedHeight += height
            }
        }

        cachedAccumulatedHeights = newAccumulatedHeights
        cachedTotalContentHeight = totalHeight
        heightCacheInvalidated = false
    }

    /// 🔑 AMLL 波浪效果：触发波浪动画
    /// 真相：波浪是从屏幕当前可见区域的顶部开始的！
    /// 我们的布局中，高亮行在 anchorY (24% 位置)，所以屏幕顶部大约是高亮行往上 2-3 行
    /// 高亮行及之后的行：延迟间隔逐渐变小（甩尾加速效果）
    private func triggerWaveAnimation(from oldIndex: Int, to newIndex: Int) {
        guard !isManualScrolling else { return }

        let totalLines = lyricsService.lyrics.count
        guard totalLines > 0 else { return }

        // 🔑 取消之前未完成的波浪动画
        for workItem in waveAnimationWorkItems {
            workItem.cancel()
        }
        waveAnimationWorkItems.removeAll()

        // 获取实际渲染的行索引列表（按顺序）
        let renderedIndices = lyricsService.lyrics.enumerated()
            .filter { idx, _ in idx == 0 || idx >= lyricsService.firstRealLyricIndex }
            .map { $0.offset }

        // 🔑 AMLL 核心：波浪从当前屏幕可见区域的顶部开始
        let visibleTopLineIndex = max(0, newIndex - 3)
        let startPosition = renderedIndices.firstIndex(where: { $0 >= visibleTopLineIndex }) ?? 0

        var delay: Double = 0
        var currentDelayStep: Double = 0.05  // 基础延迟步长 50ms

        // 🔑 屏幕顶部之上的行（已滚出屏幕）：立即更新，无延迟
        for i in 0..<startPosition {
            let lineIndex = renderedIndices[i]
            lineTargetIndices[lineIndex] = newIndex
        }

        // 🔑 从屏幕顶部开始向下遍历
        for i in startPosition..<renderedIndices.count {
            let lineIndex = renderedIndices[i]

            if delay < 0.01 {
                // 🔑 屏幕顶部第一行：立即更新目标索引
                lineTargetIndices[lineIndex] = newIndex
            } else {
                // 🔑 其他行：使用 DispatchWorkItem 以便可以取消
                let workItem = DispatchWorkItem { [self] in
                    guard !isManualScrolling else { return }
                    lineTargetIndices[lineIndex] = newIndex
                }
                waveAnimationWorkItems.append(workItem)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }

            // 🔑 累加延迟
            delay += currentDelayStep

            // 🔑 AMLL 甩尾加速：高亮行及之后的行，延迟步长逐渐变小
            if lineIndex >= newIndex {
                currentDelayStep /= 1.05
            }
        }
    }

    /// 🔑 取消所有未完成的波浪动画
    private func cancelWaveAnimations() {
        for workItem in waveAnimationWorkItems {
            workItem.cancel()
        }
        waveAnimationWorkItems.removeAll()
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
    var showTranslation: Bool = false  // 🔑 是否显示翻译
    var isTranslating: Bool = false  // 🔑 是否正在翻译中

    @State private var isHovering: Bool = false
    // 🔑 内部翻译显示状态，用于实现开启时的平滑动画
    @State private var internalShowTranslation: Bool = false

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

    // 🔑 翻译文本（如果有）
    private var translationText: String? {
        guard let translation = line.translation, !translation.isEmpty else { return nil }
        return translation
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
        // 参考 AMLL/LyricFever 样式：翻译显示在原文下方
        VStack(alignment: .leading, spacing: 4) {
            // 🔑 主歌词行
            HStack(spacing: 0) {
                Text(cleanedText)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(textOpacity))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            // 🔑 翻译行 - 使用 internalShowTranslation 控制，实现开启时的平滑动画
            if internalShowTranslation, let translation = translationText {
                HStack(spacing: 0) {
                    Text(translation)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(textOpacity * 0.6))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(4)

                    Spacer(minLength: 0)
                }
            } else if showTranslation && isTranslating {
                // 🔑 翻译加载中动画
                HStack(spacing: 4) {
                    TranslationLoadingDotsView()
                    Spacer(minLength: 0)
                }
            }
        }
        // 🔑 监听 showTranslation 变化，触发内部状态更新
        .onChange(of: showTranslation) { _, newValue in
            // 🔑 开启时延迟一帧，让布局系统先完成初始计算，然后动画到新高度
            if newValue {
                // 开启：延迟一帧添加翻译视图，这样 lineOffset 的变化会被动画捕获
                DispatchQueue.main.async {
                    internalShowTranslation = true
                }
            } else {
                // 关闭：立即移除
                internalShowTranslation = false
            }
        }
        .onAppear {
            // 🔑 初始化时同步状态
            internalShowTranslation = showTranslation
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
        // 🔑 翻译动画已移至容器级别，此处不再单独设置（性能优化）
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

        // 🔑 呼吸动画：使用缓动函数让脉搏更柔和丝滑
        let rawPhase = sin(currentTime * .pi * 0.8)
        // 使用 ease-in-out 曲线：让加速和减速都更柔和
        let breathingPhase = rawPhase * abs(rawPhase)  // x * |x| 产生平方缓动效果

        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let progress = dotProgresses[dotIndex]
                let isLightingUp = progress > 0.0 && progress < 1.0
                let breathingScale: CGFloat = isLightingUp ? (1.0 + CGFloat(breathingPhase) * 0.12) : 1.0

                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .opacity(0.25 + progress * 0.75)
                    .scaleEffect((0.85 + progress * 0.15) * breathingScale)
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
            Spacer(minLength: 0)  // 🔑 左对齐
        }
        .padding(.vertical, 8)
        .opacity(overallOpacity)
        .blur(radius: overallBlur)
        .animation(.easeOut(duration: 0.2), value: isInInterlude)
    }
}

/// 翻译加载动画 - 三个渐变闪烁的点
struct TranslationLoadingDotsView: View {
    @State private var animationPhase: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(dotOpacity(for: index)))
                    .frame(width: 4, height: 4)
            }
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                animationPhase = 1
            }
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        // 创建波浪式闪烁效果
        let baseOpacity = 0.3
        let highlightOpacity = 0.7
        let phase = Double(animationPhase)

        // 每个点有不同的相位偏移
        let offset = Double(index) * 0.3
        let value = sin((phase + offset) * .pi)

        return baseOpacity + (highlightOpacity - baseOpacity) * max(0, value)
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

        // 🔑 呼吸动画：使用缓动函数让脉搏更柔和丝滑
        let rawPhase = sin(currentTime * .pi * 0.8)
        // 使用 ease-in-out 曲线：让加速和减速都更柔和
        let breathingPhase = rawPhase * abs(rawPhase)  // x * |x| 产生平方缓动效果

        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let progress = dotProgresses[index]
                    // 🔑 只有正在点亮过程中的点（0 < progress < 1）才有呼吸动画
                    let isLightingUp = progress > 0.0 && progress < 1.0
                    let breathingScale: CGFloat = isLightingUp ? (1.0 + CGFloat(breathingPhase) * 0.12) : 1.0

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

// MARK: - System Translation Modifier (macOS 15.0+)

/// 系统翻译修饰器 - 仅在 macOS 15.0+ 可用时使用
struct SystemTranslationModifier: ViewModifier {
    var translationSessionConfigAny: Any?
    let lyricsService: LyricsService
    let translationTrigger: Int

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            if let config = translationSessionConfigAny as? TranslationSession.Configuration {
                // 🔑 使用 translationTrigger 作为视图 ID
                // .translationTask 只在 config 变化时触发，但切歌时 config 可能相同（相同语言对）
                // 通过 .id() 强制重建视图，从而重新触发 .translationTask
                content
                    .translationTask(config, action: { session in
                        // 🔑 所有防重复逻辑都在 performSystemTranslation 内部处理
                        guard lyricsService.showTranslation,
                              !lyricsService.lyrics.isEmpty else { return }
                        await lyricsService.performSystemTranslation(session: session)
                    })
                    .id(translationTrigger)  // 🔑 强制在 trigger 变化时重建视图
            } else {
                content
            }
        } else {
            content
        }
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






