/**
 * [INPUT]: 依赖 MusicController, LyricsService, LyricLineView, SharedBottomControls
 * [OUTPUT]: 导出 LyricsView
 * [POS]: UI 的 歌词全屏视图
 */
import SwiftUI
import AppKit
import Combine
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
    var frozenDisplayIndex: Int? = nil      // 手动滚动时冻结的高亮行索引
}

/// 行高度 + 累积高度缓存
private struct CacheState {
    var lineHeights: [Int: CGFloat] = [:]
    var cachedTotalContentHeight: CGFloat = 0
    var cachedAccumulatedHeights: [Int: CGFloat] = [:]
    var heightCacheInvalidated = true
    var lyricsContainerHeight: CGFloat = 300
    /// Cached renderedIndices — invalidated only when lyrics change
    var renderedIndicesCached: [Int] = []
    var renderedIndicesValid = false
}

/// AMLL wave animation state (GCD-driven: each line's target mutated independently via asyncAfter)
private struct WaveState {
    var lastCurrentIndex: Int = -1
    /// Per-line target index — updated staggered via GCD, read in body for offset calculation
    var lineTargetIndices: [Int: Int] = [:]
    /// Pending DispatchWorkItems for cancellation on seek/track-change
    var workItems: [DispatchWorkItem] = []
}

private struct DisplayLyricLine: Identifiable, Equatable {
    let id: String
    let sourceIndex: Int
    let segmentIndex: Int
    let segmentCount: Int
    let line: LyricLine

    var isLastSegment: Bool { segmentIndex == segmentCount - 1 }
}

private let lyricLineMotionCoordinateSpace = "nanoPod.lyrics.lineMotion"
private let lyricLineMotionSampleInterval: TimeInterval = 0.25
private let lyricLineMotionBoundarySampleInterval: TimeInterval = 0.40
private let lyricLineMotionIdleSampleInterval: TimeInterval = 2.50
private let lyricLineMotionPageSwitchSampleDuration: TimeInterval = 0.95
private let lyricLineMotionTrackSwitchSampleDuration: TimeInterval = 1.25
private let lyricLineMotionLineAdvanceSampleDuration: TimeInterval = 0.85
private let lyricLineLayoutSettleDuration: TimeInterval = 0.65
private let lyricInitialRenderVisibleRange = 4
private let lyricSteadyRenderVisibleRange = 6
private let lyricPageSwitchTranslationDeferDuration: TimeInterval = 0.55
private let lyricMinimumGeneratedSegmentDuration: TimeInterval = 1.65
private let lyricContentLeadingInset: CGFloat = 32
private let lyricContentTrailingInset: CGFloat = 20

struct LyricWaveTiming {
    static let defaultBaseDelay: TimeInterval = 0.08
    static let minimumBaseDelay: TimeInterval = 0.024
    static let settlePadding: TimeInterval = 0.20
    static let maxLineIntervalFraction: TimeInterval = 0.72
    static let tailAccelerationFactor: TimeInterval = 1.05

    static func baseDelay(
        for indices: [Int],
        startPosition: Int,
        newIndex: Int,
        lineInterval: TimeInterval?
    ) -> TimeInterval {
        guard indices.indices.contains(startPosition) else { return defaultBaseDelay }
        guard let lineInterval, lineInterval.isFinite, lineInterval > 0 else {
            return defaultBaseDelay
        }

        let defaultDuration = waveDuration(
            for: indices,
            startPosition: startPosition,
            newIndex: newIndex,
            baseDelay: defaultBaseDelay
        )
        let targetDuration = max(minimumBaseDelay, lineInterval * maxLineIntervalFraction)
        guard defaultDuration > targetDuration else { return defaultBaseDelay }

        let scalableDuration = max(defaultDuration - settlePadding, minimumBaseDelay)
        let targetScalableDuration = max(targetDuration - settlePadding, minimumBaseDelay)
        let scale = targetScalableDuration / scalableDuration
        return max(minimumBaseDelay, defaultBaseDelay * scale)
    }

    static func waveDuration(
        for indices: [Int],
        startPosition: Int,
        newIndex: Int,
        baseDelay: TimeInterval
    ) -> TimeInterval {
        guard indices.indices.contains(startPosition) else { return settlePadding }

        var delay: TimeInterval = 0
        var nextDelay = baseDelay
        for i in startPosition..<indices.count {
            delay += nextDelay
            if indices[i] >= newIndex {
                nextDelay /= tailAccelerationFactor
            }
        }
        return delay + settlePadding
    }
}

struct LyricMotionSamplingPolicy {
    static let focusedInterval = lyricLineMotionSampleInterval
    static let boundaryInterval = lyricLineMotionBoundarySampleInterval
    static let idleInterval = lyricLineMotionIdleSampleInterval
    static let boundaryLead: TimeInterval = 0.10
    static let boundaryTrail: TimeInterval = 0.75

    static func activeIndex(
        at playbackTime: TimeInterval,
        lyrics: [LyricLine],
        firstRealIndex: Int
    ) -> Int? {
        guard !lyrics.isEmpty else { return nil }
        let boundedFirstRealIndex = min(max(firstRealIndex, 0), lyrics.count - 1)
        if playbackTime < lyrics[boundedFirstRealIndex].startTime {
            return 0
        }

        var result: Int?
        for index in boundedFirstRealIndex..<lyrics.count {
            if playbackTime >= lyrics[index].startTime {
                result = index
            } else {
                break
            }
        }
        return result
    }

    static func isNearLineBoundary(
        playbackTime: TimeInterval,
        lyrics: [LyricLine],
        firstRealIndex: Int
    ) -> Bool {
        guard !lyrics.isEmpty else { return false }
        let start = min(max(firstRealIndex, 0), lyrics.count - 1)
        for index in start..<lyrics.count {
            let delta = playbackTime - lyrics[index].startTime
            if delta >= -boundaryLead && delta <= boundaryTrail {
                return true
            }
            if delta < -boundaryLead {
                return false
            }
        }
        return false
    }

    static func sampleInterval(
        focusedWindowActive: Bool,
        playbackTime: TimeInterval,
        lyrics: [LyricLine],
        firstRealIndex: Int
    ) -> TimeInterval {
        if focusedWindowActive { return focusedInterval }
        if isNearLineBoundary(playbackTime: playbackTime, lyrics: lyrics, firstRealIndex: firstRealIndex) {
            return boundaryInterval
        }
        return idleInterval
    }
}

enum LyricLineTranslationLayoutPolicy {
    static func pendingLineIndices(in lyrics: [LyricLine]) -> Set<Int> {
        Set(LyricsService.translationEligibleLineIndices(in: lyrics, onlyMissingTranslations: true))
    }

    static func isAwaitingTranslation(
        index: Int,
        line: LyricLine,
        pendingLineIndices: Set<Int>,
        isTranslating: Bool
    ) -> Bool {
        isTranslating && !line.hasTranslation && pendingLineIndices.contains(index)
    }
}

private struct LyricLineMotionCaptureRequest: Equatable {
    let requestedAt: Date
    let playbackTime: TimeInterval
}

private struct LyricLineMotionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct LyricLineMotionSamplingProbe: View {
    let interval: TimeInterval
    let onTick: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(Timer.publish(every: interval, on: .main, in: .common).autoconnect()) { _ in
                onTick()
            }
    }
}

// MARK: - LyricsView

public struct LyricsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    @StateObject private var diagnostics = DiagnosticsService.shared
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
    @State private var isAudioOutputMenuPresented = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var lineAdvanceTimer: Timer? = nil
    @State private var pendingTrackLyricsFetchTask: Task<Void, Never>? = nil
    @State private var suppressInitialLineMotion = false
    @State private var lineMotionSuppressionGeneration = 0
    @State private var pendingLineHeightResetForNextPayload = false
    @State private var lastLineMotionSampleAt: Date = .distantPast
    @State private var latestLineMotionFrames: [Int: CGRect] = [:]
    @State private var latestLineMotionAnchorY: CGFloat = 0
    @State private var latestLineMotionDisplayIndex: Int = 0
    @State private var lineMotionSamplingActive = false
    @State private var lineMotionSamplingUntil: Date = .distantPast
    @State private var lineMotionFrameCaptureActive = false
    @State private var pendingLineMotionCapture: LyricLineMotionCaptureRequest?
    @State private var lastLineBoundaryLagEventAt: Date = .distantPast
    @State private var lastLineBoundaryLagSignature: String?
    @State private var heightCacheUpdateScheduled = false
    @State private var displayCurrentLineIndex: Int? = nil
    @State private var cachedDisplayLines: [DisplayLyricLine] = []
    @State private var cachedDisplayLyrics: [LyricLine] = []
    @State private var cachedFirstRealDisplayIndex: Int = 0

    // ── 翻译状态 ──
    @State private var translationSessionConfigAny: Any?
    @State private var localTranslationTrigger: Int = 0
    @State private var translationConfigGeneration = 0
    @State private var translationPreflightTask: Task<Void, Never>?

    // ── 无障碍 ──
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        .overlay(alignment: .topLeading) { diagnosticLineMotionProbe }
        .overlay(bottomControlsOverlay)
        .modifier(FloatingMenuBackdropBlur(
            isActive: isAudioOutputMenuPresented,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion
        ))
        .overlay(alignment: .topLeading) { musicButtonOverlay }
        .overlay(alignment: .topTrailing) { windowButtonsOverlay }
        .onHover { hovering in handleHover(hovering) }
        // ── onChange: 页面切换 ──
        .onChange(of: currentPage) { _, newPage in
            if newPage != .lyrics {
                pendingTrackLyricsFetchTask?.cancel()
                pendingTrackLyricsFetchTask = nil
                lineAdvanceTimer?.invalidate()
                lineAdvanceTimer = nil
                translationPreflightTask?.cancel()
                translationPreflightTask = nil
                translationSessionConfigAny = nil
                lineMotionFrameCaptureActive = false
                pendingLineMotionCapture = nil
                latestLineMotionFrames.removeAll()
            }
            if newPage == .lyrics {
                isHovering = true
                animateControlsIn()
                updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
                scheduleNextLineAdvanceTimer()
                startLineMotionSamplingWindow(duration: lyricLineMotionPageSwitchSampleDuration)
            }
        }
        // ── onAppear + 歌曲切换 ──
        .onAppear {
            debugPrint("📝 [LyricsView] onAppear - track: '\(musicController.currentTrackTitle)' by '\(musicController.currentArtist)'\n")
            refreshDisplayLineCache()
            suppressLineMotionDuringLayoutSettlement(duration: lyricLineLayoutSettleDuration)
            startLineMotionSamplingWindow(duration: lyricLineMotionPageSwitchSampleDuration)
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration,
                                      album: musicController.currentAlbum)
            if #available(macOS 15.0, *) {
                scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
            }
        }
        .onChange(of: musicController.currentTrackTitle) {
            debugPrint("📝 [LyricsView] onChange(currentTrackTitle) - track: '\(musicController.currentTrackTitle)' by '\(musicController.currentArtist)'\n")
            cancelWaveAnimations()
            wave.lineTargetIndices.removeAll()
            wave.lastCurrentIndex = -1
            cache.heightCacheInvalidated = true
            cache.renderedIndicesValid = false
            cachedDisplayLines.removeAll()
            cachedDisplayLyrics.removeAll()
            cachedFirstRealDisplayIndex = 0
            displayCurrentLineIndex = nil
            pendingLineHeightResetForNextPayload = true
            // 🔑 Reset manual scroll state — prevents stuck isManualScrolling
            // when track changes during a manual scroll (timer would fire on stale state)
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
            lineAdvanceTimer?.invalidate()
            lineAdvanceTimer = nil
            scroll.isManualScrolling = false
            lyricsService.isManualScrolling = false
            scroll.manualScrollOffset = 0
            scroll.rawScrollOffset = 0
            scroll.frozenDisplayIndex = nil
            scroll.lockedLineIndex = nil
            latestLineMotionFrames.removeAll()
            lineMotionFrameCaptureActive = false
            pendingLineMotionCapture = nil
            suppressLineMotionDuringLayoutSettlement(duration: 0.65)
            scheduleTrackChangeLyricsFetch()
        }
        .onChange(of: musicController.currentAlbum) { _, newAlbum in
            guard currentPage == .lyrics else { return }
            guard !newAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            pendingLineHeightResetForNextPayload = true
            scheduleTrackChangeLyricsFetch()
        }
        // currentTime → lyrics line index update moved to MusicController.interpolateTime()
        // to avoid triggering SwiftUI body re-evaluations 10x/sec via onChange
        // ── onChange: 翻译相关 ──
        .onChange(of: lyricsService.lyrics) { _, newLyrics in
            let newCount = newLyrics.count
            refreshDisplayLineCache()
            if #available(macOS 15.0, *), newCount > 0 {
                scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
            }
            if newCount > 0, pendingLineHeightResetForNextPayload {
                cache.lineHeights.removeAll()
                pendingLineHeightResetForNextPayload = false
            }
            updateHeightCache()
            if newCount > 0 {
                updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
                scheduleNextLineAdvanceTimer()
                suppressLineMotionDuringLayoutSettlement(duration: lyricLineLayoutSettleDuration)
                startLineMotionSamplingWindow(duration: lyricLineMotionTrackSwitchSampleDuration)
            }
        }
        .onChange(of: musicController.isPlaying) { _, isPlaying in
            if isPlaying {
                scheduleNextLineAdvanceTimer()
            } else {
                lineAdvanceTimer?.invalidate()
                lineAdvanceTimer = nil
            }
        }
        .onChange(of: diagnostics.isEnabled) { _, isEnabled in
            if isEnabled {
                startLineMotionSamplingWindow(duration: lyricLineMotionPageSwitchSampleDuration)
            } else {
                lineMotionSamplingActive = false
                lineMotionFrameCaptureActive = false
                pendingLineMotionCapture = nil
                latestLineMotionFrames.removeAll()
            }
        }
        .onChange(of: lyricsService.isLoading) { oldValue, newValue in
            if #available(macOS 15.0, *) {
                if oldValue && !newValue && !lyricsService.lyrics.isEmpty {
                    scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
                }
            }
        }
        .onChange(of: lyricsService.translationLanguage) { _, _ in
            if #available(macOS 15.0, *) {
                scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
            }
        }
        .onChange(of: lyricsService.showTranslation) { _, newValue in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                cache.heightCacheInvalidated = true
            }
            if #available(macOS 15.0, *), newValue {
                scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
            }
        }
        .onChange(of: lyricsService.translationRequestTrigger) { _, newValue in
            if #available(macOS 15.0, *) {
                scheduleTranslationRequest(after: lyricPageSwitchTranslationDeferDuration, trigger: newValue)
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
            guard let newSourceIndex = newValue else { return }
            if cachedDisplayLyrics.isEmpty {
                let newIndex = displayIndex(forSourceIndex: newSourceIndex)
                let oldIndex = oldValue.map { displayIndex(forSourceIndex: $0) } ?? wave.lastCurrentIndex
                displayCurrentLineIndex = newIndex
                if newIndex != wave.lastCurrentIndex && !scroll.isManualScrolling {
                    triggerWaveAnimation(from: oldIndex, to: newIndex)
                    wave.lastCurrentIndex = newIndex
                    startLineMotionSamplingWindow(duration: lyricLineMotionLineAdvanceSampleDuration)
                }
            } else {
                updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
            }
            scheduleNextLineAdvanceTimer()
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
        .onReceive(musicController.timePublisher.$currentTime) { _ in
            guard currentPage == .lyrics else { return }
            updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
            scheduleNextLineAdvanceTimer()
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
        Color.clear
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var diagnosticLineMotionProbe: some View {
        if lineMotionMonitoringEnabled {
            LyricLineMotionSamplingProbe(interval: lyricLineMotionSampleInterval) {
                requestLatestLyricLineMotionCapture()
            }
            .allowsHitTesting(false)
        }
    }

    private var loadingView: some View {
        ProgressView()
            .accessibilityLabel("加载歌词中")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundColor(.white)
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
                    album: musicController.currentAlbum,
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
    }

    private var lineMotionMonitoringEnabled: Bool {
        diagnostics.isEnabled && currentPage == .lyrics && !lyricsService.lyrics.isEmpty
    }

    private var scrollableLyricsContent: some View {
        let lyricsViewID = "\(musicController.currentTrackTitle)-\(musicController.currentArtist)"

        return GeometryReader { geo in
            let displayLines = cachedDisplayLines
            let displayLyrics = cachedDisplayLyrics
            let firstRealDisplayIndex = cachedFirstRealDisplayIndex
            let containerHeight = geo.size.height
            let controlBarHeight: CGFloat = 120
            let liveIndex = displayCurrentLineIndex
                ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0, in: displayLines)
            // AMLL: 高亮瞬时切换，位移通过 wave spring 过渡
            let displayIndex = scroll.isManualScrolling
                ? (scroll.frozenDisplayIndex ?? liveIndex)
                : liveIndex
            let isLineWaveActive = !wave.workItems.isEmpty
            let _ = updateLyricsContainerHeight(containerHeight)
            let anchorY = (containerHeight - controlBarHeight) * 0.24
            let pendingTranslationLineIndices = lyricsService.showTranslation
                ? LyricLineTranslationLayoutPolicy.pendingLineIndices(in: lyricsService.lyrics)
                : []

            // Visibility culling: only during steady auto-play with all heights measured
            let visibleRange = 12
            let cullingMeasurementThreshold = min(renderedIndices.count, max(8, visibleRange * 2))
            let hasEnoughMeasuredHeights = cache.lineHeights.count >= cullingMeasurementThreshold
            let shouldCull = !scroll.isManualScrolling && hasEnoughMeasuredHeights

            ZStack(alignment: .topLeading) {
                ForEach(Array(displayLines.enumerated()), id: \.element.id) { index, displayLine in
                    let line = displayLine.line
                    let sourceLine = lyricsService.lyrics.indices.contains(displayLine.sourceIndex)
                        ? lyricsService.lyrics[displayLine.sourceIndex]
                        : line
                    if index == 0 || index >= firstRealDisplayIndex {
                        let isVisible = !shouldCull || abs(index - displayIndex) <= visibleRange

                        if isVisible {
                            let lineOffset = calculateLineOffset(
                                index: index, currentIndex: displayIndex, anchorY: anchorY
                            )
                            let fullOffset = lineOffset + calculateAccumulatedHeight(upTo: index)

                            lyricLineContent(
                                line: line,
                                index: index,
                                currentIndex: displayIndex,
                                sourceIndex: displayLine.sourceIndex,
                                isLastSegment: displayLine.isLastSegment,
                                isAwaitingTranslation: LyricLineTranslationLayoutPolicy.isAwaitingTranslation(
                                    index: displayLine.sourceIndex,
                                    line: sourceLine,
                                    pendingLineIndices: pendingTranslationLineIndices,
                                    isTranslating: lyricsService.isTranslating
                                )
                            )
                                .background(lineHeightTracker(index: index))
                                .allowsHitTesting(true)
                                .offset(y: fullOffset)
                                .animation(
                                    scroll.isManualScrolling || reduceMotion || (suppressInitialLineMotion && !isLineWaveActive) ? nil : .interpolatingSpring(
                                        mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0
                                    ),
                                    value: scroll.isManualScrolling ? 0 : fullOffset
                                )
                                .background(lineMotionTracker(index: index))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(y: scroll.manualScrollOffset)
            .coordinateSpace(name: lyricLineMotionCoordinateSpace)
            .onPreferenceChange(LyricLineMotionFramePreferenceKey.self) { frames in
                guard lineMotionFrameCaptureActive else {
                    if !latestLineMotionFrames.isEmpty {
                        latestLineMotionFrames.removeAll()
                    }
                    return
                }
                if latestLineMotionFrames != frames {
                    latestLineMotionFrames = frames
                }
                latestLineMotionAnchorY = anchorY
                latestLineMotionDisplayIndex = displayIndex
                guard !frames.isEmpty else { return }
                guard let capture = pendingLineMotionCapture else { return }
                pendingLineMotionCapture = nil
                recordLyricLineMotion(
                    frames: frames,
                    anchorY: anchorY,
                    containerHeight: containerHeight,
                    controlBarHeight: controlBarHeight,
                    displayIndex: displayIndex,
                    displayLines: displayLines,
                    displayLyrics: displayLyrics,
                    firstRealDisplayIndex: firstRealDisplayIndex,
                    playbackTime: capture.playbackTime,
                    timestamp: capture.requestedAt
                )
                DispatchQueue.main.async {
                    lineMotionFrameCaptureActive = false
                    latestLineMotionFrames.removeAll()
                }
            }
        }
        .modifier(BottomFadeMask(isActive: showControls, steepFade: scroll.isManualScrolling))
        .id(lyricsViewID)
        .contentShape(Rectangle())
        .scrollDetectionWithVelocity(
            onScrollStarted: { handleScrollStarted() },
            onScrollEnded: { handleScrollEnded() },
            onScrollWithVelocity: { deltaY, velocity in handleScrollDelta(deltaY, velocity: velocity) },
            isEnabled: currentPage == .lyrics
        )
    }

    // MARK: - Lyric Line Helpers

    @ViewBuilder
    private func lyricLineContent(
        line: LyricLine,
        index: Int,
        currentIndex: Int,
        sourceIndex: Int,
        isLastSegment: Bool,
        isAwaitingTranslation: Bool
    ) -> some View {
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
                    timePublisher: musicController.timePublisher
                )
                .frame(height: 30)
                .padding(.leading, lyricContentLeadingInset)
                .padding(.trailing, lyricContentTrailingInset)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    LyricLineView(
                        line: line,
                        index: index,
                        currentIndex: currentIndex,
                        isScrolling: scroll.isManualScrolling,
                        musicController: musicController,
                        onTap: { handleLineTap(line: line) },
                        showTranslation: lyricsService.showTranslation,
                        isTranslating: isAwaitingTranslation,
                        translationFailed: lyricsService.translationFailed && isAwaitingTranslation,
                        isPrecedingInterlude: lyricsService.interludeAfterIndex == index
                    )
                    .padding(.leading, lyricContentLeadingInset)
                    .padding(.trailing, lyricContentTrailingInset)

                    if isLastSegment, let interludeInfo = checkForInterlude(at: sourceIndex) {
                        PreludeDotsView(
                            startTime: interludeInfo.startTime,
                            endTime: interludeInfo.endTime,
                            timePublisher: musicController.timePublisher,
                            gateByTimeRange: true
                        )
                        .padding(.leading, lyricContentLeadingInset)
                        .padding(.trailing, lyricContentTrailingInset)
                    }
                }
            }
    }

    private func lineHeightTracker(index: Int) -> some View {
        GeometryReader { lineGeo in
            Color.clear.onAppear {
                let h = lineGeo.size.height
                if abs((cache.lineHeights[index] ?? 0) - h) > 2.0 {
                    cache.lineHeights[index] = h
                    cache.heightCacheInvalidated = true
                    scheduleHeightCacheUpdate()
                }
            }
            .onChange(of: lineGeo.size.height) { _, newHeight in
                // 忽略 ≤2pt 的微小变化（scale 动画引起的抖动）
                if abs((cache.lineHeights[index] ?? 0) - newHeight) > 2.0 {
                    cache.lineHeights[index] = newHeight
                    cache.heightCacheInvalidated = true
                    scheduleHeightCacheUpdate()
                }
            }
        }
    }

    @ViewBuilder
    private func lineMotionTracker(index: Int) -> some View {
        if lineMotionFrameCaptureActive {
            GeometryReader { lineGeo in
                Color.clear.preference(
                    key: LyricLineMotionFramePreferenceKey.self,
                    value: [index: lineGeo.frame(in: .named(lyricLineMotionCoordinateSpace))]
                )
            }
        }
    }

    private func requestLatestLyricLineMotionCapture() {
        let now = Date()
        if lineMotionSamplingActive && now > lineMotionSamplingUntil {
            lineMotionSamplingActive = false
        }
        guard lineMotionMonitoringEnabled else { return }
        let playbackTime = musicController.lyricRenderTime(at: now)
        let sampleInterval = LyricMotionSamplingPolicy.sampleInterval(
            focusedWindowActive: lineMotionSamplingActive,
            playbackTime: playbackTime,
            lyrics: lyricsService.lyrics,
            firstRealIndex: lyricsService.firstRealLyricIndex
        )
        guard now.timeIntervalSince(lastLineMotionSampleAt) >= sampleInterval else { return }
        lastLineMotionSampleAt = now

        let capture = LyricLineMotionCaptureRequest(requestedAt: now, playbackTime: playbackTime)
        pendingLineMotionCapture = capture
        lineMotionFrameCaptureActive = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            guard pendingLineMotionCapture == capture else { return }
            pendingLineMotionCapture = nil
            lineMotionFrameCaptureActive = false
            latestLineMotionFrames.removeAll()
        }
    }

    private func startLineMotionSamplingWindow(duration: TimeInterval) {
        guard diagnostics.isEnabled else { return }
        let until = Date().addingTimeInterval(duration)
        if until > lineMotionSamplingUntil {
            lineMotionSamplingUntil = until
        }
        lineMotionSamplingActive = true
        lastLineMotionSampleAt = .distantPast

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            if Date() >= lineMotionSamplingUntil {
                lineMotionSamplingActive = false
            }
        }
    }

    private func suppressLineMotionDuringLayoutSettlement(duration: TimeInterval) {
        lineMotionSuppressionGeneration += 1
        let generation = lineMotionSuppressionGeneration
        suppressInitialLineMotion = true

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard lineMotionSuppressionGeneration == generation else { return }
            suppressInitialLineMotion = false
        }
    }

    private func recordLyricLineMotion(
        frames: [Int: CGRect],
        anchorY: CGFloat,
        containerHeight: CGFloat,
        controlBarHeight: CGFloat,
        displayIndex: Int,
        displayLines: [DisplayLyricLine],
        displayLyrics: [LyricLine],
        firstRealDisplayIndex: Int,
        playbackTime: TimeInterval,
        timestamp: Date
    ) {
        guard currentPage == .lyrics, diagnostics.isEnabled, !frames.isEmpty else { return }

        let lyrics = displayLyrics
        guard !lyrics.isEmpty else { return }
        guard lyricsService.displayedLyricsBelongTo(
            title: musicController.currentTrackTitle,
            artist: musicController.currentArtist,
            duration: musicController.duration,
            album: musicController.currentAlbum
        ) else { return }

        let track = musicController.diagnosticsTrackContext()
        let activeIndex = LyricMotionSamplingPolicy.activeIndex(
            at: playbackTime,
            lyrics: lyrics,
            firstRealIndex: firstRealDisplayIndex
        ) ?? lyricsService.currentLineIndex ?? displayIndex
        let sorted = frames
            .filter { index, frame in
                displayLines.indices.contains(index) && frame.height > 0
            }
            .sorted { $0.key < $1.key }

        struct MotionPartial {
            let index: Int
            let displayLine: DisplayLyricLine
            let line: LyricLine
            let frame: CGRect
            let targetIndex: Int
            let appliedOffsetY: Double
            let targetMinY: Double
            let targetMidY: Double
            let waveOffsetY: Double
        }

        let immediateLineOffset = anchorY - calculateAccumulatedHeight(upTo: displayIndex)
        let partials: [MotionPartial] = sorted.map { index, frame in
            let displayLine = displayLines[index]
            let line = displayLine.line
            let targetIndex = scroll.isManualScrolling
                ? (scroll.lockedLineIndex ?? displayIndex)
                : (wave.lineTargetIndices[index] ?? displayIndex)
            let lineOffset = calculateLineOffset(index: index, currentIndex: displayIndex, anchorY: anchorY)
            let fullOffset = lineOffset + calculateAccumulatedHeight(upTo: index)
            let appliedOffsetY = Double(fullOffset + scroll.manualScrollOffset)
            let targetMinY = Double(frame.minY) + appliedOffsetY
            let targetMidY = targetMinY + Double(frame.height / 2)
            return MotionPartial(
                index: index,
                displayLine: displayLine,
                line: line,
                frame: frame,
                targetIndex: targetIndex,
                appliedOffsetY: appliedOffsetY,
                targetMinY: targetMinY,
                targetMidY: targetMidY,
                waveOffsetY: Double(lineOffset - immediateLineOffset)
            )
        }

        var samples: [DiagnosticLyricLineMotionSample] = []
        samples.reserveCapacity(partials.count)
        var previousRenderedMidY: Double?
        var previousTargetMidY: Double?
        let visibleTopY = 42.0
        let visibleBottomY = max(
            visibleTopY + 1,
            Double(containerHeight - (showControls || isAudioOutputMenuPresented ? controlBarHeight : 20))
        )
        for partial in partials {
            let renderedMinY = Double(partial.frame.minY) + partial.appliedOffsetY
            let renderedMidY = Double(partial.frame.midY) + partial.appliedOffsetY
            let renderedMaxY = renderedMinY + Double(partial.frame.height)
            let lineTopClipY = max(0, visibleTopY - renderedMinY)
            let lineBottomClipY = max(0, renderedMaxY - visibleBottomY)
            let isActiveLine = partial.index == activeIndex
            let observedDelta = previousRenderedMidY.map { renderedMidY - $0 }
            let expectedDelta = previousTargetMidY.map { partial.targetMidY - $0 }
            let deltaError: Double? = {
                guard let observedDelta, let expectedDelta else { return nil }
                return observedDelta - expectedDelta
            }()
            samples.append(DiagnosticLyricLineMotionSample(
                timestamp: timestamp,
                page: "lyrics",
                trackTitle: track.title,
                trackArtist: track.artist,
                lineIndex: partial.index,
                lineID: partial.line.id.uuidString,
                lineStartTime: partial.line.startTime,
                lineEndTime: partial.line.endTime,
                playbackTime: playbackTime,
                activeIndex: activeIndex,
                displayIndex: displayIndex,
                targetIndex: partial.targetIndex,
                renderedMinY: renderedMinY,
                renderedMidY: renderedMidY,
                renderedHeight: Double(partial.frame.height),
                targetMinY: partial.targetMinY,
                targetMidY: partial.targetMidY,
                targetErrorY: renderedMinY - partial.targetMinY,
                observedInterLineDeltaY: observedDelta,
                expectedInterLineDeltaY: expectedDelta,
                interLineDeltaErrorY: deltaError,
                waveOffsetY: partial.waveOffsetY,
                manualScrollOffsetY: Double(scroll.manualScrollOffset),
                isManualScrolling: scroll.isManualScrolling,
                isInitialMotionSuppressed: suppressInitialLineMotion,
                visibleTopY: visibleTopY,
                visibleBottomY: visibleBottomY,
                lineTopClipY: lineTopClipY,
                lineBottomClipY: lineBottomClipY,
                activeTopClipY: isActiveLine ? lineTopClipY : 0,
                activeBottomClipY: isActiveLine ? lineBottomClipY : 0,
                controlsVisible: showControls || isAudioOutputMenuPresented
            ))
            previousRenderedMidY = renderedMidY
            previousTargetMidY = partial.targetMidY
        }

        let activeTargetIndex = partials.first { $0.index == activeIndex }?.targetIndex
            ?? wave.lineTargetIndices[activeIndex]
            ?? displayIndex
        recordLineBoundaryLagIfNeeded(
            activeIndex: activeIndex,
            displayIndex: displayIndex,
            targetIndex: activeTargetIndex,
            displayLyrics: lyrics,
            playbackTime: playbackTime,
            track: track,
            timestamp: timestamp
        )

        diagnostics.recordLyricsLineMotionSamples(samples)

        let visibleTranslationPartials = partials.filter {
            shouldConsiderVisibleTranslationLine($0.line.text)
        }
        if lyricsService.showTranslation,
           !lyricsService.isTranslating {
            let missingTranslatedSourcePartial = visibleTranslationPartials.first { partial in
                guard !partial.line.hasTranslation,
                      partial.displayLine.segmentCount > 1,
                      lyrics.indices.contains(partial.displayLine.sourceIndex) else {
                    return false
                }
                return lyrics[partial.displayLine.sourceIndex].hasTranslation
            }
            let missingCurrentPartial = visibleTranslationPartials.first {
                $0.index == displayIndex && !$0.line.hasTranslation
            }
            guard let currentPartial = missingTranslatedSourcePartial ?? missingCurrentPartial else {
                return
            }
            let visibleTranslatedLineCount = visibleTranslationPartials.filter { $0.line.hasTranslation }.count
            let visibleMissingTranslationLineCount = visibleTranslationPartials.count - visibleTranslatedLineCount
            let eligibleLineIndices = Set(LyricsService.translationEligibleLineIndices(
                in: lyrics,
                onlyMissingTranslations: false
            ))
            let sourceLineHasTranslation = lyrics.indices.contains(currentPartial.displayLine.sourceIndex)
                ? lyrics[currentPartial.displayLine.sourceIndex].hasTranslation
                : false
            diagnostics.recordLyricsVisibleTranslationGap(
                track: track,
                lineIndex: currentPartial.index,
                sourceLineIndex: currentPartial.displayLine.sourceIndex,
                segmentIndex: currentPartial.displayLine.segmentIndex,
                segmentCount: currentPartial.displayLine.segmentCount,
                displayIndex: displayIndex,
                activeIndex: activeIndex,
                playbackTime: playbackTime,
                lineStartTime: currentPartial.line.startTime,
                lineEndTime: currentPartial.line.endTime,
                totalLineCount: lyrics.count,
                visibleLineCount: visibleTranslationPartials.count,
                visibleTranslatedLineCount: visibleTranslatedLineCount,
                visibleMissingTranslationLineCount: visibleMissingTranslationLineCount,
                sourceLineHasTranslation: sourceLineHasTranslation,
                lineIsTranslationEligible: eligibleLineIndices.contains(currentPartial.displayLine.sourceIndex),
                lineIsVocable: isVocableLine(currentPartial.line.text),
                showTranslation: lyricsService.showTranslation,
                canTranslate: lyricsService.canTranslate,
                translationFailed: lyricsService.translationFailed
            )
        }
    }

    private func recordLineBoundaryLagIfNeeded(
        activeIndex: Int,
        displayIndex: Int,
        targetIndex: Int,
        displayLyrics: [LyricLine],
        playbackTime: TimeInterval,
        track: DiagnosticTrackContext,
        timestamp: Date
    ) {
        guard displayLyrics.indices.contains(activeIndex) else { return }
        let displayLagLines = activeIndex - displayIndex
        let targetLagLines = activeIndex - targetIndex
        guard displayLagLines != 0 || targetLagLines != 0 else { return }

        let boundaryLatency = max(0, playbackTime - displayLyrics[activeIndex].startTime)
        guard boundaryLatency >= 0.025 else { return }

        let signature = "\(track.title)|\(track.artist)|\(activeIndex)|\(displayIndex)|\(targetIndex)"
        guard signature != lastLineBoundaryLagSignature
                || timestamp.timeIntervalSince(lastLineBoundaryLagEventAt) >= 1.0 else {
            return
        }

        lastLineBoundaryLagSignature = signature
        lastLineBoundaryLagEventAt = timestamp
        diagnostics.recordEvent(
            "lyrics.autoscroll.boundaryLag",
            detail: "Active lyric advanced before the rendered scroll target caught up",
            track: track,
            metrics: [
                "playbackTime": playbackTime,
                "activeIndex": Double(activeIndex),
                "displayIndex": Double(displayIndex),
                "targetIndex": Double(targetIndex),
                "displayLagLines": Double(displayLagLines),
                "targetLagLines": Double(targetLagLines),
                "boundaryLatencySeconds": boundaryLatency
            ]
        )
    }

    private func shouldConsiderVisibleTranslationLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !isPreludeEllipsis(trimmed),
              !isInstrumentalNotice(trimmed),
              !isStandaloneLyricsRoleMarker(trimmed) else {
            return false
        }
        return true
    }

    private func calculateLineOffset(index: Int, currentIndex: Int, anchorY: CGFloat) -> CGFloat {
        if scroll.isManualScrolling {
            let frozenTargetIndex = scroll.lockedLineIndex ?? currentIndex
            return anchorY - calculateAccumulatedHeight(upTo: frozenTargetIndex)
        } else {
            // GCD wave: each line's target is updated independently via asyncAfter.
            // Lines not yet flipped retain the previous wave's target (= oldIndex),
            // creating the stagger. Fallback to currentIndex for lines never in a wave.
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
                    timePublisher: musicController.timePublisher,
                    currentPage: $currentPage,
                    isHovering: $isHovering,
                    showControls: $showControls,
                    isProgressBarHovering: $isProgressBarHovering,
                    dragPosition: $dragPosition,
                    translationButton: lyricsService.canTranslate
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

    @ViewBuilder
    private var musicButtonOverlay: some View {
        if (showControls || isAudioOutputMenuPresented) && currentPage == .lyrics {
            MusicButtonView()
                .accessibilityLabel("打开 Music")
                .padding(12)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var windowButtonsOverlay: some View {
        if (showControls || isAudioOutputMenuPresented) && currentPage == .lyrics {
            HStack(spacing: 8) {
                if onExpand != nil {
                    ExpandButtonView(onExpand: onExpand!)
                        .accessibilityLabel("展开")
                } else {
                    AudioOutputSwitcherView(
                        onMenuPresentedChanged: handleAudioOutputMenuPresentation
                    )
                }
            }
            .transition(.opacity)
            .padding(12)
        }
    }

    // MARK: - 交互处理

    private func animateControlsIn() {
        controlsBlurAmount = 10
        controlsOffsetY = 30
        let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
        let controlsAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)
        withAnimation(controlsAnim) {
            showControls = true
            controlsBlurAmount = 0
            controlsOffsetY = 0
        }
    }

    private func animateControlsOut() {
        let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
        let controlsAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)
        withAnimation(controlsAnim) {
            showControls = false
            controlsBlurAmount = 10
            controlsOffsetY = 30
        }
    }

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        if !hovering {
            if isAudioOutputMenuPresented { return }
            animateControlsOut()
        } else if !scroll.isManualScrolling {
            animateControlsIn()
        }
    }

    private func handleAudioOutputMenuPresentation(_ presented: Bool) {
        isAudioOutputMenuPresented = presented
        guard !presented, !isHovering else { return }
        animateControlsOut()
    }

    private func handleLineTap(line: LyricLine) {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        lineAdvanceTimer?.invalidate()
        lineAdvanceTimer = nil
        // Sync line index to tapped position BEFORE unfreezing
        // Prevents double-jump: frozen → old liveIndex → tapped line
        lyricsService.updateCurrentTime(line.startTime)
        updateDisplayCurrentLineIndex(at: line.startTime)
        // Sync wave state so the next natural line advance doesn't see a stale lastCurrentIndex
        if let idx = displayCurrentLineIndex {
            wave.lastCurrentIndex = idx
        }
        // Cancel pending wave work items and set all targets to new index (instant jump)
        for item in wave.workItems { item.cancel() }
        wave.workItems.removeAll()
        let newIdx = displayCurrentLineIndex ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0)
        for idx in renderedIndices { wave.lineTargetIndices[idx] = newIdx }
        // Unfreeze — no withAnimation! The .animation(value: fullOffset) on each line
        // handles the spring transition naturally when fullOffset changes.
        scroll.isManualScrolling = false
        lyricsService.isManualScrolling = false
        scroll.lockedLineIndex = nil
        scroll.frozenDisplayIndex = nil
        scroll.rawScrollOffset = 0
        scroll.manualScrollOffset = 0
        musicController.seek(to: line.startTime)
        scheduleNextLineAdvanceTimer()
    }

    private func scheduleTrackChangeLyricsFetch() {
        pendingTrackLyricsFetchTask?.cancel()
        let title = musicController.currentTrackTitle
        let artist = musicController.currentArtist
        let duration = musicController.duration
        let album = musicController.currentAlbum

        pendingTrackLyricsFetchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard currentPage == .lyrics else { return }
            guard musicController.currentTrackTitle == title,
                  musicController.currentArtist == artist else { return }
            lyricsService.fetchLyrics(for: title,
                                      artist: artist,
                                      duration: duration,
                                      album: album)
        }
    }

    private func handleExternalManualScroll(_ newValue: Bool) {
        guard newValue && !scroll.isManualScrolling else { return }

        if cache.heightCacheInvalidated { updateHeightCache() }
        let currentIdx = displayCurrentLineIndex ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0)
        scroll.lockedLineIndex = currentIdx
        scroll.frozenDisplayIndex = currentIdx  // 冻结高亮行
        scroll.isManualScrolling = true
        scroll.lastVelocity = 0
        scroll.scrollLocked = false
        scroll.hasTriggeredSlowScroll = false

        autoScrollTimer?.invalidate()
        lineAdvanceTimer?.invalidate()
        lineAdvanceTimer = nil
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [self] _ in
            // Sync wave to latest line index BEFORE unfreezing
            updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
            let newIdx = displayCurrentLineIndex ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0)
            wave.lastCurrentIndex = newIdx
            // Set all targets to current index so spring transitions correctly
            for idx in renderedIndices { wave.lineTargetIndices[idx] = newIdx }
            scroll.lockedLineIndex = nil
            scroll.rawScrollOffset = 0
            withAnimation(.interpolatingSpring(
                mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0
            )) {
                scroll.frozenDisplayIndex = nil
                scroll.isManualScrolling = false
                lyricsService.isManualScrolling = false
                scroll.manualScrollOffset = 0
            }
            scroll.scrollLocked = false
            scroll.hasTriggeredSlowScroll = false
            scheduleNextLineAdvanceTimer()
        }
        RunLoop.main.add(autoScrollTimer!, forMode: .common)
    }

    // MARK: - 滚动处理

    private func handleScrollStarted() {
        autoScrollTimer?.invalidate()
        lineAdvanceTimer?.invalidate()
        lineAdvanceTimer = nil
        if cache.heightCacheInvalidated { updateHeightCache() }

        let currentIdx = displayCurrentLineIndex ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0)
        scroll.lockedLineIndex = currentIdx
        scroll.frozenDisplayIndex = currentIdx  // 冻结高亮行
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
            // Sync wave to latest line index BEFORE unfreezing
            updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
            let newIdx = displayCurrentLineIndex ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0)
            wave.lastCurrentIndex = newIdx
            for idx in renderedIndices { wave.lineTargetIndices[idx] = newIdx }

            scroll.lockedLineIndex = nil
            scroll.rawScrollOffset = 0
            withAnimation(.interpolatingSpring(
                mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0
            )) {
                // Unfreeze highlight and manual scroll flag atomically
                // Prevents intermediate state where frozenDisplayIndex=nil but isManualScrolling=true
                scroll.frozenDisplayIndex = nil
                scroll.isManualScrolling = false
                lyricsService.isManualScrolling = false
                scroll.manualScrollOffset = 0
            }
            scroll.scrollLocked = false
            scroll.hasTriggeredSlowScroll = false

            // 恢复后如果鼠标在窗口内则显示控件
            if isHovering { animateControlsIn() }
            scheduleNextLineAdvanceTimer()
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

    private func updateTranslationSessionConfig(trigger: Int? = nil) {
        if #available(macOS 15.0, *) {
            let generation = translationConfigGeneration
            translationPreflightTask?.cancel()
            translationSessionConfigAny = nil
            translationPreflightTask = Task { @MainActor in
                guard currentPage == .lyrics, lyricsService.showTranslation else { return }
                guard let config = await lyricsService.silentSystemTranslationConfiguration() else { return }
                guard !Task.isCancelled, translationConfigGeneration == generation else { return }

                translationSessionConfigAny = config
                if let trigger {
                    localTranslationTrigger = trigger
                }
            }
        }
    }

    private func scheduleTranslationSessionConfigUpdate(after delay: TimeInterval) {
        translationConfigGeneration += 1
        let generation = translationConfigGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard translationConfigGeneration == generation else { return }
            guard currentPage == .lyrics, lyricsService.showTranslation else { return }
            updateTranslationSessionConfig()
        }
    }

    private func scheduleTranslationRequest(after delay: TimeInterval, trigger: Int) {
        translationConfigGeneration += 1
        let generation = translationConfigGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard translationConfigGeneration == generation else { return }
            guard currentPage == .lyrics, lyricsService.showTranslation else { return }
            updateTranslationSessionConfig(trigger: trigger)
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

    private func makeDisplayLyricLines(from lyrics: [LyricLine]) -> [DisplayLyricLine] {
        var result: [DisplayLyricLine] = []
        result.reserveCapacity(lyrics.count)

        for (sourceIndex, line) in lyrics.enumerated() {
            if isPreludeEllipsis(line.text) || isInstrumentalNotice(line.text) {
                result.append(DisplayLyricLine(
                    id: "\(line.id.uuidString)-0",
                    sourceIndex: sourceIndex,
                    segmentIndex: 0,
                    segmentCount: 1,
                    line: line
                ))
                continue
            }

            let wordSegments = line.hasSyllableSync
                ? LyricDisplaySegmenter.wordSegments(for: line.words, options: .mainLyric)
                : []
            let textSegments = wordSegments.isEmpty
                ? LyricDisplaySegmenter.segments(for: line.text, options: .mainLyric)
                : wordSegments.map { displayText(forWords: $0) }
            let segmentCount = max(textSegments.count, 1)
            if shouldKeepDisplayLineUnsplit(line, generatedSegmentCount: segmentCount) {
                result.append(DisplayLyricLine(
                    id: "\(line.id.uuidString)-0",
                    sourceIndex: sourceIndex,
                    segmentIndex: 0,
                    segmentCount: 1,
                    line: line
                ))
                continue
            }
            let translationSegments = line.translation.map {
                LyricDisplaySegmenter.balancedSegments(
                    for: $0,
                    count: segmentCount,
                    options: .translation
                )
            } ?? []
            for segmentIndex in 0..<segmentCount {
                let timing = displayTiming(
                    for: line,
                    segmentIndex: segmentIndex,
                    segmentCount: segmentCount,
                    wordSegment: wordSegments.indices.contains(segmentIndex) ? wordSegments[segmentIndex] : []
                )
                let segmentLine = LyricLine(
                    text: textSegments.indices.contains(segmentIndex) ? textSegments[segmentIndex] : line.text,
                    startTime: timing.start,
                    endTime: timing.end,
                    words: wordSegments.indices.contains(segmentIndex) ? wordSegments[segmentIndex] : [],
                    translation: translationSegments.indices.contains(segmentIndex)
                        ? translationSegments[segmentIndex]
                        : line.translation
                )
                result.append(DisplayLyricLine(
                    id: "\(line.id.uuidString)-\(segmentIndex)",
                    sourceIndex: sourceIndex,
                    segmentIndex: segmentIndex,
                    segmentCount: segmentCount,
                    line: segmentLine
                ))
            }
        }

        return result
    }

    private func shouldKeepDisplayLineUnsplit(
        _ line: LyricLine,
        generatedSegmentCount: Int
    ) -> Bool {
        guard generatedSegmentCount > 1 else { return true }
        let duration = line.endTime - line.startTime
        guard duration.isFinite, duration > 0 else { return false }
        return duration / Double(generatedSegmentCount) < lyricMinimumGeneratedSegmentDuration
    }

    private func displayText(forWords words: [LyricWord]) -> String {
        LyricDisplaySegmenter.displayText(forWords: words)
    }

    private func displayTiming(
        for line: LyricLine,
        segmentIndex: Int,
        segmentCount: Int,
        wordSegment: [LyricWord]
    ) -> (start: TimeInterval, end: TimeInterval) {
        if let first = wordSegment.first, let last = wordSegment.last, last.endTime > first.startTime {
            return (first.startTime, last.endTime)
        }

        let duration = max(0, line.endTime - line.startTime)
        guard segmentCount > 1, duration > 0 else { return (line.startTime, line.endTime) }
        let segmentDuration = duration / Double(segmentCount)
        let start = line.startTime + segmentDuration * Double(segmentIndex)
        let end = segmentIndex == segmentCount - 1 ? line.endTime : start + segmentDuration
        return (start, end)
    }

    private func displayFirstRealLyricIndex(in displayLines: [DisplayLyricLine]) -> Int {
        displayLines.firstIndex { $0.sourceIndex >= lyricsService.firstRealLyricIndex }
            ?? min(lyricsService.firstRealLyricIndex, max(0, displayLines.count - 1))
    }

    private func refreshDisplayLineCache() {
        let displayLines = makeDisplayLyricLines(from: lyricsService.lyrics)
        let firstRealDisplayIndex = displayFirstRealLyricIndex(in: displayLines)
        cachedDisplayLines = displayLines
        cachedDisplayLyrics = displayLines.map(\.line)
        cachedFirstRealDisplayIndex = firstRealDisplayIndex
        displayCurrentLineIndex = displayIndex(
            forSourceIndex: lyricsService.currentLineIndex ?? lyricsService.firstRealLyricIndex,
            in: displayLines
        )
        cache.renderedIndicesCached = makeRenderedIndices(in: displayLines, firstRealIndex: firstRealDisplayIndex)
        cache.renderedIndicesValid = true
        cache.heightCacheInvalidated = true
    }

    private func displayIndex(forSourceIndex sourceIndex: Int) -> Int {
        displayIndex(forSourceIndex: sourceIndex, in: cachedDisplayLines)
    }

    private func displayIndex(forSourceIndex sourceIndex: Int, in displayLines: [DisplayLyricLine]) -> Int {
        displayLines.firstIndex { $0.sourceIndex == sourceIndex } ?? 0
    }

    private func scheduleNextLineAdvanceTimer() {
        lineAdvanceTimer?.invalidate()
        lineAdvanceTimer = nil

        guard currentPage == .lyrics,
              musicController.isPlaying,
              !scroll.isManualScrolling,
              !cachedDisplayLyrics.isEmpty else {
            return
        }

        let now = Date()
        let playbackTime = musicController.lyricRenderTime(at: now)
        let currentIndex = LyricMotionSamplingPolicy.activeIndex(
            at: playbackTime,
            lyrics: cachedDisplayLyrics,
            firstRealIndex: cachedFirstRealDisplayIndex
        ) ?? cachedFirstRealDisplayIndex
        let nextStartIndex = min(max(currentIndex + 1, cachedFirstRealDisplayIndex), cachedDisplayLyrics.count)
        guard nextStartIndex < cachedDisplayLyrics.count else { return }

        guard let nextLine = cachedDisplayLyrics[nextStartIndex...].first(where: {
            $0.startTime > playbackTime + 0.006
        }) else {
            return
        }

        let delay = max(0.006, nextLine.startTime - playbackTime)
        let timer = Timer(timeInterval: delay, repeats: false) { [self] _ in
            guard currentPage == .lyrics else { return }
            updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
            scheduleNextLineAdvanceTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        lineAdvanceTimer = timer
    }

    private func updateDisplayCurrentLineIndex(at playbackTime: TimeInterval) {
        let displayLines = cachedDisplayLines
        guard !displayLines.isEmpty else {
            displayCurrentLineIndex = nil
            return
        }
        let newIndex = LyricMotionSamplingPolicy.activeIndex(
            at: playbackTime,
            lyrics: cachedDisplayLyrics,
            firstRealIndex: cachedFirstRealDisplayIndex
        )
        guard displayCurrentLineIndex != newIndex else { return }
        let oldIndex = displayCurrentLineIndex ?? wave.lastCurrentIndex
        displayCurrentLineIndex = newIndex
        guard let newIndex, !scroll.isManualScrolling else { return }
        triggerWaveAnimation(from: oldIndex, to: newIndex)
        wave.lastCurrentIndex = newIndex
        startLineMotionSamplingWindow(duration: lyricLineMotionLineAdvanceSampleDuration)
    }

    // MARK: - 滚动边界 + 橡皮筋

    private func rubberBand(_ x: CGFloat, _ d: CGFloat) -> CGFloat {
        let result = (1.0 - (1.0 / ((abs(x) * 0.55 / d) + 1.0))) * d
        return x < 0 ? -result : result
    }

    private func scrollBounds() -> (maxUp: CGFloat, maxDown: CGFloat) {
        let idx = scroll.lockedLineIndex ?? (displayCurrentLineIndex ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0))
        let curOffset = calculateAccumulatedHeight(upTo: idx)
        let anchorY = (cache.lyricsContainerHeight - 120) * 0.24
        let visibleBottom = (cache.lyricsContainerHeight - 120) - anchorY
        return (max(0, curOffset - anchorY),
                max(0, calculateTotalContentHeight() - curOffset - visibleBottom))
    }

    // MARK: - 高度计算 + 缓存

    /// Self-caching: computes once, serves from cache until invalidated
    private var renderedIndices: [Int] {
        if cache.renderedIndicesValid {
            return cache.renderedIndicesCached
        }
        return makeRenderedIndices()
    }

    private func makeRenderedIndices() -> [Int] {
        makeRenderedIndices(in: cachedDisplayLines, firstRealIndex: cachedFirstRealDisplayIndex)
    }

    private func makeRenderedIndices(in displayLines: [DisplayLyricLine], firstRealIndex: Int) -> [Int] {
        displayLines.enumerated()
            .filter { index, _ in index == 0 || index >= firstRealIndex }
            .map { $0.offset }
    }

    private func refreshRenderedIndicesCache() {
        cache.renderedIndicesCached = makeRenderedIndices()
        cache.renderedIndicesValid = true
    }

    private func calculateAccumulatedHeight(upTo targetIndex: Int) -> CGFloat {
        if !cache.heightCacheInvalidated, let cached = cache.cachedAccumulatedHeights[targetIndex] {
            return cached
        }

        let spacing: CGFloat = 6, defaultHeight: CGFloat = 36
        var totalHeight: CGFloat = 0
        let indices = renderedIndices
        guard let targetPosition = indices.firstIndex(of: targetIndex) else { return 0 }
        if cache.lineHeights.isEmpty {
            return CGFloat(targetPosition) * (defaultHeight + spacing)
        }
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

        let spacing: CGFloat = 6, defaultHeight: CGFloat = 46
        let indices = renderedIndices
        var totalHeight: CGFloat = 0
        for (i, lineIndex) in indices.enumerated() {
            totalHeight += cache.lineHeights[lineIndex] ?? defaultHeight
            if i < indices.count - 1 { totalHeight += spacing }
        }
        return totalHeight
    }

    /// body 入口调用，确保高度缓存有效（避免 O(N²) 逐行重算）
    private func ensureHeightCache() {
        if cache.heightCacheInvalidated { updateHeightCache() }
    }

    private func updateHeightCache() {
        let spacing: CGFloat = 6
        let defaultHeight: CGFloat = 36
        let indices = makeRenderedIndices()

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

        cache.renderedIndicesCached = indices
        cache.renderedIndicesValid = true
        cache.cachedAccumulatedHeights = newAccumulatedHeights
        cache.cachedTotalContentHeight = totalHeight
        cache.heightCacheInvalidated = false
    }

    private func scheduleHeightCacheUpdate() {
        guard !heightCacheUpdateScheduled else { return }
        heightCacheUpdateScheduled = true
        DispatchQueue.main.async {
            heightCacheUpdateScheduled = false
            if cache.heightCacheInvalidated {
                updateHeightCache()
            }
        }
    }

    // MARK: - AMLL 波浪动画（纯计算驱动）

    /// AMLL wave animation — GCD-driven stagger.
    /// Each line's target is updated independently via DispatchWorkItem + asyncAfter.
    /// Each mutation triggers a SwiftUI body re-evaluation, starting that line's spring
    /// at a genuinely different wall-clock time — creating natural stagger.
    private func triggerWaveAnimation(from oldIndex: Int, to newIndex: Int) {
        guard !scroll.isManualScrolling else { return }
        let lyrics = cachedDisplayLyrics
        guard !lyrics.isEmpty else { return }

        // Cancel pending work items from previous wave
        for item in wave.workItems { item.cancel() }
        wave.workItems.removeAll()

        let indices = renderedIndices.filter {
            abs($0 - newIndex) <= 14 || abs($0 - oldIndex) <= 14
        }
        guard !indices.isEmpty else { return }

        // Skip wave on large jumps (seeks) or accessibility
        let isLargeJump = abs(newIndex - oldIndex) > 4
        if reduceMotion || isLargeJump {
            for idx in indices { wave.lineTargetIndices[idx] = newIndex }
            return
        }

        // Wave starts from 3 lines above the new current line
        let visibleTopLineIndex = max(0, newIndex - 3)
        let startPosition = indices.firstIndex(where: { $0 >= visibleTopLineIndex }) ?? 0

        let lineInterval = estimatedLineInterval(around: newIndex, in: lyrics)
        var delay: TimeInterval = 0
        var baseDelay = LyricWaveTiming.baseDelay(
            for: indices,
            startPosition: startPosition,
            newIndex: newIndex,
            lineInterval: lineInterval
        )

        // Above visible top: instant update
        for i in 0..<startPosition {
            wave.lineTargetIndices[indices[i]] = newIndex
        }

        // Visible lines: staggered via GCD asyncAfter
        for i in startPosition..<indices.count {
            let lineIndex = indices[i]

            if delay < 0.01 {
                // First visible line: immediate
                wave.lineTargetIndices[lineIndex] = newIndex
            } else {
                let workItem = DispatchWorkItem { [self] in
                    guard !scroll.isManualScrolling else { return }
                    wave.lineTargetIndices[lineIndex] = newIndex
                }
                wave.workItems.append(workItem)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }

            delay += baseDelay
            // AMLL tail acceleration: lines past current get progressively faster
            if lineIndex >= newIndex { baseDelay /= LyricWaveTiming.tailAccelerationFactor }
        }

        let finalSettleDelay = delay + LyricWaveTiming.settlePadding
        let settleWorkItem = DispatchWorkItem { [self] in
            guard wave.lastCurrentIndex == newIndex else { return }
            wave.workItems.removeAll()
            guard !scroll.isManualScrolling else { return }

            var keep = Set<Int>()
            for idx in renderedIndices where abs(idx - newIndex) <= 18 {
                keep.insert(idx)
                if wave.lineTargetIndices[idx] != newIndex {
                    wave.lineTargetIndices[idx] = newIndex
                }
            }
            wave.lineTargetIndices = wave.lineTargetIndices.filter { keep.contains($0.key) }
        }
        wave.workItems.append(settleWorkItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + finalSettleDelay, execute: settleWorkItem)
    }

    private func estimatedLineInterval(around index: Int, in lyrics: [LyricLine]) -> TimeInterval? {
        guard lyrics.indices.contains(index) else { return nil }

        if index + 1 < lyrics.count {
            let nextGap = lyrics[index + 1].startTime - lyrics[index].startTime
            if nextGap.isFinite, nextGap > 0 {
                return nextGap
            }
        }

        let ownDuration = lyrics[index].endTime - lyrics[index].startTime
        return ownDuration.isFinite && ownDuration > 0 ? ownDuration : nil
    }

    private func cancelWaveAnimations() {
        for item in wave.workItems { item.cancel() }
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
