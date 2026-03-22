/**
 * [INPUT]: 依赖 MusicController, LyricsService, LyricLineView, SharedBottomControls
 * [OUTPUT]: 导出 LyricsView
 * [POS]: UI 的 歌词全屏视图
 */
import SwiftUI
import AppKit
import Translation

// MARK: - Accessibility

// MARK: - State Structs

/// 手动滚动相关状态
private struct ScrollState {
    var isManualScrolling = false
    var manualScrollOffset: CGFloat = 0     // 显示用（含橡皮筋）
    var rawScrollOffset: CGFloat = 0        // 原始累积（不含橡皮筋）
    var lastVelocity: CGFloat = 0
    var scrollLocked = false
    var hasTriggeredSlowScroll = false
    var lockedLineIndex: Int? = nil
}

/// 行高度 + 累积高度缓存
private struct CacheState {
    var lineHeights: [Int: CGFloat] = [:]
    var cachedTotalContentHeight: CGFloat = 0
    var cachedAccumulatedHeights: [Int: CGFloat] = [:]
    var heightCacheInvalidated = true
    var lyricsContainerHeight: CGFloat = 300
}

/// AMLL 波浪动画状态
private struct WaveState {
    var lineTargetIndices: [Int: Int] = [:]
    var lastCurrentIndex: Int = -1
    var workItems: [DispatchWorkItem] = []
}

// MARK: - LyricsView

public struct LyricsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    @Binding var currentPage: PlayerPage
    var openWindow: OpenWindowAction?
    var onHide: (() -> Void)?
    var onExpand: (() -> Void)?

    // ── 分组状态 ──
    @State private var scroll = ScrollState()
    @State private var cache = CacheState()
    @State private var wave = WaveState()

    // ── UI 状态 ──
    @State private var isHovering = false
    @State private var isProgressBarHovering = false
    @State private var dragPosition: CGFloat? = nil
    @State private var showControls = true
    @State private var controlsBlurAmount: CGFloat = 0
    @State private var controlsOffsetY: CGFloat = 0
    @State private var autoScrollTimer: Timer? = nil

    // ── 翻译状态 ──
    @State private var translationSessionConfigAny: Any?
    @State private var localTranslationTrigger: Int = 0

    // ── 无障碍 ──
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // ── 设置 ──
    @State private var fullscreenAlbumCover: Bool = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")

    public init(currentPage: Binding<PlayerPage>, openWindow: OpenWindowAction? = nil,
                onHide: (() -> Void)? = nil, onExpand: (() -> Void)? = nil) {
        self._currentPage = currentPage
        self.openWindow = openWindow
        self.onHide = onHide
        self.onExpand = onExpand
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            backgroundLayer
            VStack(spacing: 0) {
                if lyricsService.isLoading {
                    loadingView
                } else if let error = lyricsService.error {
                    errorView(error)
                } else if lyricsService.lyrics.isEmpty {
                    emptyStateView
                } else {
                    scrollableLyricsContent
                }
            }
        }
        .overlay(alignment: .topLeading) { musicButtonOverlay }
        .overlay(alignment: .topTrailing) { windowButtonsOverlay }
        .onHover { hovering in handleHover(hovering) }
        // ── onChange: 页面切换 ──
        .onChange(of: currentPage) { _, newPage in
            if newPage == .lyrics {
                isHovering = true
                animateControlsIn()
            }
        }
        // ── onAppear + 歌曲切换 ──
        .onAppear {
            debugPrint("📝 [LyricsView] onAppear - track: '\(musicController.currentTrackTitle)' by '\(musicController.currentArtist)'\n")
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration)
            if #available(macOS 15.0, *) { updateTranslationSessionConfig() }
        }
        .onChange(of: musicController.currentTrackTitle) {
            debugPrint("📝 [LyricsView] onChange(currentTrackTitle) - track: '\(musicController.currentTrackTitle)' by '\(musicController.currentArtist)'\n")
            cancelWaveAnimations()
            wave.lineTargetIndices.removeAll()
            wave.lastCurrentIndex = -1
            cache.heightCacheInvalidated = true
            cache.lineHeights.removeAll()
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration)
        }
        .onChange(of: musicController.currentTime) {
            lyricsService.updateCurrentTime(musicController.currentTime)
        }
        // ── onChange: 翻译相关 ──
        .onChange(of: lyricsService.lyrics.count) { _, newCount in
            if #available(macOS 15.0, *), newCount > 0 { updateTranslationSessionConfig() }
            cache.heightCacheInvalidated = true
        }
        .onChange(of: lyricsService.isLoading) { oldValue, newValue in
            if #available(macOS 15.0, *) {
                if oldValue && !newValue && !lyricsService.lyrics.isEmpty {
                    updateTranslationSessionConfig()
                }
            }
        }
        .onChange(of: lyricsService.translationLanguage) { _, _ in
            if #available(macOS 15.0, *) { updateTranslationSessionConfig() }
        }
        .onChange(of: lyricsService.showTranslation) { _, newValue in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                cache.heightCacheInvalidated = true
            }
            if #available(macOS 15.0, *), newValue { updateTranslationSessionConfig() }
        }
        .onChange(of: lyricsService.translationRequestTrigger) { _, newValue in
            if #available(macOS 15.0, *) {
                updateTranslationSessionConfig()
                localTranslationTrigger = newValue
            }
        }
        .onChange(of: lyricsService.isTranslating) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                cache.heightCacheInvalidated = true
            }
        }
        // ── onChange: 滚动 + 波浪 + 错误 ──
        .onChange(of: lyricsService.isManualScrolling) { _, newValue in
            handleExternalManualScroll(newValue)
        }
        .onChange(of: lyricsService.currentLineIndex) { oldValue, newValue in
            guard let newIndex = newValue else { return }
            let oldIndex = oldValue ?? wave.lastCurrentIndex
            if newIndex != wave.lastCurrentIndex && !scroll.isManualScrolling {
                triggerWaveAnimation(from: oldIndex, to: newIndex)
                wave.lastCurrentIndex = newIndex
            }
        }
        .onChange(of: lyricsService.error) { _, newError in
            if newError != nil && !musicController.userManuallyOpenedLyrics && currentPage == .lyrics {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    currentPage = .album
                }
            }
        }
        // ── onChange: 设置 ──
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let newValue = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")
            if newValue != fullscreenAlbumCover {
                withAnimation(.easeInOut(duration: 0.3)) { fullscreenAlbumCover = newValue }
            }
        }
        .modifier(SystemTranslationModifier(
            translationSessionConfigAny: translationSessionConfigAny,
            lyricsService: lyricsService,
            translationTrigger: localTranslationTrigger
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sub-views

    private var backgroundLayer: some View {
        Group {
            if fullscreenAlbumCover {
                AdaptiveFluidBackground(artwork: musicController.currentArtwork)
                    .id(musicController.currentTrackTitle)
                    .ignoresSafeArea()
            } else {
                LiquidBackgroundView(artwork: musicController.currentArtwork)
                    .ignoresSafeArea()
            }
        }
        .accessibilityHidden(true)
    }

    private var loadingView: some View {
        ProgressView()
            .accessibilityLabel("加载歌词中")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundColor(.white)
            .overlay(Group { if showControls { controlBar } })
    }

    private func errorView(_ error: String) -> some View {
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
            .accessibilityLabel("重试加载歌词")
            .accessibilityHint("点击重新获取歌词")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(Group { if showControls { controlBar } })
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.3))
            Text("No lyrics available")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("暂无歌词")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(Group { if showControls { controlBar } })
    }

    private var scrollableLyricsContent: some View {
        let lyricsViewID = "\(musicController.currentTrackTitle)-\(musicController.currentArtist)"

        return GeometryReader { geo in
            let containerHeight = geo.size.height
            let controlBarHeight: CGFloat = 120
            let currentIndex = lyricsService.currentLineIndex ?? 0
            let _ = updateLyricsContainerHeight(containerHeight)
            let anchorY = (containerHeight - controlBarHeight) * 0.24

            ZStack(alignment: .topLeading) {
                ForEach(Array(lyricsService.lyrics.enumerated()), id: \.element.id) { index, line in
                    if index == 0 || index >= lyricsService.firstRealLyricIndex {
                        let lineOffset = calculateLineOffset(
                            index: index, currentIndex: currentIndex, anchorY: anchorY
                        )

                        lyricLineContent(line: line, index: index, currentIndex: currentIndex)
                            .background(lineHeightTracker(index: index))
                            .offset(y: lineOffset + calculateAccumulatedHeight(upTo: index))
                            .animation(
                                scroll.isManualScrolling || reduceMotion ? nil : .interpolatingSpring(
                                    mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0
                                ),
                                value: {
                                    let fullOffset = lineOffset + calculateAccumulatedHeight(upTo: index)
                                    return scroll.isManualScrolling ? 0 : fullOffset
                                }()
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(y: scroll.manualScrollOffset)
        }
        .modifier(BottomFadeMask(isActive: showControls))
        .id(lyricsViewID)
        .contentShape(Rectangle())
        .scrollDetectionWithVelocity(
            onScrollStarted: { handleScrollStarted() },
            onScrollEnded: { handleScrollEnded() },
            onScrollWithVelocity: { deltaY, velocity in handleScrollDelta(deltaY, velocity: velocity) },
            isEnabled: currentPage == .lyrics
        )
        .overlay(bottomControlsOverlay)
    }

    // MARK: - Lyric Line Helpers

    private func lyricLineContent(line: LyricLine, index: Int, currentIndex: Int) -> some View {
        Group {
            if isPreludeEllipsis(line.text) {
                let nextLineStartTime: TimeInterval = {
                    if index == 0 && lyricsService.firstRealLyricIndex < lyricsService.lyrics.count {
                        return lyricsService.lyrics[lyricsService.firstRealLyricIndex].startTime
                    }
                    for nextIndex in max(index + 1, lyricsService.firstRealLyricIndex)..<lyricsService.lyrics.count {
                        let nextLine = lyricsService.lyrics[nextIndex]
                        if !isPreludeEllipsis(nextLine.text) { return nextLine.startTime }
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
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    LyricLineView(
                        line: line,
                        index: index,
                        currentIndex: currentIndex,
                        isScrolling: scroll.isManualScrolling,
                        currentTime: musicController.currentTime,
                        onTap: { handleLineTap(line: line) },
                        showTranslation: lyricsService.showTranslation,
                        isTranslating: lyricsService.isTranslating
                    )
                    .padding(.horizontal, 32)

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
    }

    private func lineHeightTracker(index: Int) -> some View {
        GeometryReader { lineGeo in
            Color.clear.onAppear {
                if cache.lineHeights[index] != lineGeo.size.height {
                    cache.lineHeights[index] = lineGeo.size.height
                    cache.heightCacheInvalidated = true
                }
            }
            .onChange(of: lineGeo.size.height) { _, newHeight in
                if cache.lineHeights[index] != newHeight {
                    cache.lineHeights[index] = newHeight
                    cache.heightCacheInvalidated = true
                }
            }
        }
    }

    private func calculateLineOffset(index: Int, currentIndex: Int, anchorY: CGFloat) -> CGFloat {
        if scroll.isManualScrolling {
            let frozenTargetIndex = scroll.lockedLineIndex ?? currentIndex
            return anchorY - calculateAccumulatedHeight(upTo: frozenTargetIndex)
        } else {
            let lineTargetIndex = wave.lineTargetIndices[index] ?? currentIndex
            return anchorY - calculateAccumulatedHeight(upTo: lineTargetIndex)
        }
    }

    // MARK: - Overlay 组件

    private var bottomControlsOverlay: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                Color.clear.frame(height: 1).allowsHitTesting(false)
                SharedBottomControls(
                    currentPage: $currentPage,
                    isHovering: $isHovering,
                    showControls: $showControls,
                    isProgressBarHovering: $isProgressBarHovering,
                    dragPosition: $dragPosition,
                    translationButton: !lyricsService.lyrics.isEmpty
                        ? AnyView(TranslationButtonView(lyricsService: lyricsService)) : nil
                )
            }
            .blur(radius: controlsBlurAmount)
            .offset(y: controlsOffsetY)
        }
        .allowsHitTesting(showControls)
        .opacity(showControls ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showControls)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controlsBlurAmount)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controlsOffsetY)
    }

    private var controlBar: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
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

    @ViewBuilder
    private var musicButtonOverlay: some View {
        if showControls {
            MusicButtonView()
                .accessibilityLabel("打开 Music")
                .padding(12)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    @ViewBuilder
    private var windowButtonsOverlay: some View {
        if showControls {
            let hideAction: () -> Void = onHide ?? {
                NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel })?.orderOut(nil)
            }
            HStack(spacing: 8) {
                if onExpand != nil {
                    ExpandButtonView(onExpand: onExpand!)
                        .accessibilityLabel("展开")
                } else {
                    HideButtonView(onHide: hideAction)
                        .accessibilityLabel("返回")
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .padding(12)
        }
    }

    // MARK: - 交互处理

    private func animateControlsIn() {
        controlsBlurAmount = 10
        controlsOffsetY = 30
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showControls = true
            controlsBlurAmount = 0
            controlsOffsetY = 0
        }
    }

    private func animateControlsOut() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showControls = false
            controlsBlurAmount = 10
            controlsOffsetY = 30
        }
    }

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        if !hovering {
            animateControlsOut()
        } else if !scroll.isManualScrolling {
            animateControlsIn()
        }
    }

    private func handleLineTap(line: LyricLine) {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        scroll.isManualScrolling = false
        lyricsService.isManualScrolling = false
        scroll.lockedLineIndex = nil
        scroll.rawScrollOffset = 0
        scroll.manualScrollOffset = 0
        musicController.seek(to: line.startTime)
    }

    private func handleExternalManualScroll(_ newValue: Bool) {
        guard newValue && !scroll.isManualScrolling else { return }

        if cache.heightCacheInvalidated { updateHeightCache() }
        let currentIdx = lyricsService.currentLineIndex ?? 0
        scroll.lockedLineIndex = currentIdx
        scroll.isManualScrolling = true
        scroll.lastVelocity = 0
        scroll.scrollLocked = false
        scroll.hasTriggeredSlowScroll = false

        autoScrollTimer?.invalidate()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [self] _ in
            scroll.isManualScrolling = false
            lyricsService.isManualScrolling = false
            scroll.lockedLineIndex = nil
            withAnimation(.interpolatingSpring(
                mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0
            )) {
                scroll.manualScrollOffset = 0
            }
            scroll.rawScrollOffset = 0
            scroll.scrollLocked = false
            scroll.hasTriggeredSlowScroll = false
        }
        RunLoop.main.add(autoScrollTimer!, forMode: .common)
    }

    // MARK: - 滚动处理

    private func handleScrollStarted() {
        autoScrollTimer?.invalidate()
        if cache.heightCacheInvalidated { updateHeightCache() }

        let currentIdx = lyricsService.currentLineIndex ?? 0
        scroll.lockedLineIndex = currentIdx
        scroll.rawScrollOffset = scroll.manualScrollOffset
        scroll.isManualScrolling = true
        lyricsService.isManualScrolling = true
        scroll.lastVelocity = 0
        scroll.scrollLocked = false
        scroll.hasTriggeredSlowScroll = false
    }

    private func handleScrollEnded() {
        // 松手后立即弹回边界
        let (maxUp, maxDown) = scrollBounds()
        if scroll.rawScrollOffset > maxUp || scroll.rawScrollOffset < -maxDown {
            scroll.rawScrollOffset = min(maxUp, max(-maxDown, scroll.rawScrollOffset))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                scroll.manualScrollOffset = scroll.rawScrollOffset
            }
        }

        // 2 秒后 spring 回当前播放行
        autoScrollTimer?.invalidate()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [self] _ in
            scroll.lockedLineIndex = nil
            scroll.rawScrollOffset = 0
            withAnimation(.interpolatingSpring(
                mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0
            )) {
                scroll.isManualScrolling = false
                lyricsService.isManualScrolling = false
                scroll.manualScrollOffset = 0
            }
            scroll.scrollLocked = false
            scroll.hasTriggeredSlowScroll = false

            // 恢复后如果鼠标在窗口内则显示控件
            if isHovering { animateControlsIn() }
        }
    }

    private func handleScrollDelta(_ deltaY: CGFloat, velocity: CGFloat) {
        // Apple 风格橡皮筋
        scroll.rawScrollOffset += deltaY
        let (maxUp, maxDown) = scrollBounds()
        let dim = max(cache.lyricsContainerHeight * 0.4, 120)

        if scroll.rawScrollOffset > maxUp {
            let overshoot = scroll.rawScrollOffset - maxUp
            scroll.rawScrollOffset = maxUp + overshoot * 0.92
            scroll.manualScrollOffset = maxUp + rubberBand(scroll.rawScrollOffset - maxUp, dim)
        } else if scroll.rawScrollOffset < -maxDown {
            let overshoot = scroll.rawScrollOffset + maxDown
            scroll.rawScrollOffset = -maxDown + overshoot * 0.92
            scroll.manualScrollOffset = -maxDown + rubberBand(scroll.rawScrollOffset + maxDown, dim)
        } else {
            scroll.manualScrollOffset = scroll.rawScrollOffset
        }

        let absVelocity = abs(velocity)
        let threshold: CGFloat = 800

        if deltaY < 0 {
            if showControls { animateControlsOut() }
            scroll.scrollLocked = true
        } else if absVelocity >= threshold {
            if !scroll.scrollLocked { scroll.scrollLocked = true }
            if showControls { animateControlsOut() }
        } else if deltaY > 0 && !scroll.scrollLocked && !scroll.hasTriggeredSlowScroll {
            scroll.hasTriggeredSlowScroll = true
            if !showControls { animateControlsIn() }
        }

        scroll.lastVelocity = absVelocity
    }

    // MARK: - 翻译

    private func updateTranslationSessionConfig() {
        if #available(macOS 15.0, *) {
            let targetLang = Locale.Language(identifier: lyricsService.translationLanguage)

            if !lyricsService.lyrics.isEmpty {
                let lyricTexts = lyricsService.lyrics.map { $0.text }
                if let sourceLang = TranslationService.detectLanguage(for: lyricTexts) {
                    translationSessionConfigAny = TranslationSession.Configuration(
                        source: sourceLang, target: targetLang
                    )
                    return
                }
            }

            translationSessionConfigAny = TranslationSession.Configuration(
                source: nil, target: targetLang
            )
        }
    }

    // MARK: - 工具函数

    private func isPreludeEllipsis(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・"]
        return ellipsisPatterns.contains(trimmed) || trimmed.isEmpty
    }

    private func checkForInterlude(at index: Int) -> (startTime: TimeInterval, endTime: TimeInterval)? {
        let lyrics = lyricsService.lyrics
        guard index + 1 < lyrics.count else { return nil }
        let currentLine = lyrics[index]
        let nextLine = lyrics[index + 1]
        if isPreludeEllipsis(currentLine.text) || isPreludeEllipsis(nextLine.text) { return nil }
        let gap = nextLine.startTime - currentLine.endTime
        return gap >= 5.0 ? (startTime: currentLine.endTime, endTime: nextLine.startTime) : nil
    }

    // MARK: - 滚动边界 + 橡皮筋

    private func rubberBand(_ x: CGFloat, _ d: CGFloat) -> CGFloat {
        let result = (1.0 - (1.0 / ((abs(x) * 0.55 / d) + 1.0))) * d
        return x < 0 ? -result : result
    }

    private func scrollBounds() -> (maxUp: CGFloat, maxDown: CGFloat) {
        let idx = scroll.lockedLineIndex ?? (lyricsService.currentLineIndex ?? 0)
        let curOffset = calculateAccumulatedHeight(upTo: idx)
        let anchorY = (cache.lyricsContainerHeight - 120) * 0.24
        let visibleBottom = (cache.lyricsContainerHeight - 120) - anchorY
        return (max(0, curOffset - anchorY),
                max(0, calculateTotalContentHeight() - curOffset - visibleBottom))
    }

    // MARK: - 高度计算 + 缓存

    private var renderedIndices: [Int] {
        lyricsService.lyrics.enumerated()
            .filter { index, _ in index == 0 || index >= lyricsService.firstRealLyricIndex }
            .map { $0.offset }
    }

    private func calculateAccumulatedHeight(upTo targetIndex: Int) -> CGFloat {
        if !cache.heightCacheInvalidated, let cached = cache.cachedAccumulatedHeights[targetIndex] {
            return cached
        }

        let spacing: CGFloat = 6, defaultHeight: CGFloat = 36
        var totalHeight: CGFloat = 0
        let indices = renderedIndices
        guard let targetPosition = indices.firstIndex(of: targetIndex) else { return 0 }
        for i in 0..<targetPosition {
            totalHeight += (cache.lineHeights[indices[i]] ?? defaultHeight) + spacing
        }
        return totalHeight
    }

    private func updateLyricsContainerHeight(_ height: CGFloat) {
        if cache.lyricsContainerHeight != height {
            DispatchQueue.main.async { cache.lyricsContainerHeight = height }
        }
    }

    private func calculateTotalContentHeight() -> CGFloat {
        if !cache.heightCacheInvalidated && cache.cachedTotalContentHeight > 0 {
            return cache.cachedTotalContentHeight
        }

        let spacing: CGFloat = 6, defaultHeight: CGFloat = 36
        let indices = renderedIndices
        var totalHeight: CGFloat = 0
        for (i, lineIndex) in indices.enumerated() {
            totalHeight += cache.lineHeights[lineIndex] ?? defaultHeight
            if i < indices.count - 1 { totalHeight += spacing }
        }
        return totalHeight
    }

    private func updateHeightCache() {
        let spacing: CGFloat = 6
        let defaultHeight: CGFloat = 36
        let indices = renderedIndices

        var accumulatedHeight: CGFloat = 0
        var newAccumulatedHeights: [Int: CGFloat] = [:]
        var totalHeight: CGFloat = 0

        for (i, lineIndex) in indices.enumerated() {
            newAccumulatedHeights[lineIndex] = accumulatedHeight
            let height = cache.lineHeights[lineIndex] ?? defaultHeight
            totalHeight += height
            if i < indices.count - 1 {
                totalHeight += spacing
                accumulatedHeight += height + spacing
            } else {
                accumulatedHeight += height
            }
        }

        cache.cachedAccumulatedHeights = newAccumulatedHeights
        cache.cachedTotalContentHeight = totalHeight
        cache.heightCacheInvalidated = false
    }

    // MARK: - AMLL 波浪动画

    private func triggerWaveAnimation(from oldIndex: Int, to newIndex: Int) {
        guard !scroll.isManualScrolling else { return }
        let totalLines = lyricsService.lyrics.count
        guard totalLines > 0 else { return }

        cancelWaveAnimations()

        let indices = renderedIndices

        // reduceMotion：跳过波浪延迟，所有行立即更新
        if reduceMotion {
            for lineIndex in indices { wave.lineTargetIndices[lineIndex] = newIndex }
            return
        }

        let visibleTopLineIndex = max(0, newIndex - 3)
        let startPosition = indices.firstIndex(where: { $0 >= visibleTopLineIndex }) ?? 0

        var delay: Double = 0
        var currentDelayStep: Double = 0.05

        // 屏幕顶部之上的行：立即更新
        for i in 0..<startPosition {
            wave.lineTargetIndices[indices[i]] = newIndex
        }

        // 从屏幕顶部开始向下遍历
        for i in startPosition..<indices.count {
            let lineIndex = indices[i]

            if delay < 0.01 {
                wave.lineTargetIndices[lineIndex] = newIndex
            } else {
                let workItem = DispatchWorkItem { [self] in
                    guard !scroll.isManualScrolling else { return }
                    wave.lineTargetIndices[lineIndex] = newIndex
                }
                wave.workItems.append(workItem)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }

            delay += currentDelayStep
            if lineIndex >= newIndex { currentDelayStep /= 1.05 }
        }
    }

    private func cancelWaveAnimations() {
        for workItem in wave.workItems { workItem.cancel() }
        wave.workItems.removeAll()
    }
}

// MARK: - Preview

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
