/**
 * [INPUT]: Depends on MusicController, LyricsService, SharedBottomControls
 * [OUTPUT]: Exports LyricsView
 * [POS]: Full-screen lyrics UI
 */
import SwiftUI
import AppKit
import Combine
import Translation

// MARK: - Accessibility

// MARK: - State Structs

/// Manual scroll state.
private struct ScrollState {
    var isManualScrolling = false
    var manualScrollOffset: CGFloat = 0     // Display offset, including rubber banding.
    var rawScrollOffset: CGFloat = 0        // Raw accumulated offset, excluding rubber banding.
    var scrollLocked = false
    var hasTriggeredSlowScroll = false
    var lockedLineIndex: Int? = nil
    var frozenDisplayIndex: Int? = nil      // Highlighted row index frozen during manual scroll.
}

/// Row height and accumulated-height cache.
private struct CacheState {
    var lineHeights: [Int: CGFloat] = [:]
    var cachedTotalContentHeight: CGFloat = 0
    var cachedAccumulatedHeights: [Int: CGFloat] = [:]
    var heightCacheInvalidated = true
    var lyricsContainerHeight: CGFloat = 300
    var nativeEstimatedRowWidth: CGFloat = 0
    /// Plan A (2026-09-22): the lyrics column width `makeDisplayLyricLines`
    /// last split against. Defaults to the app's first-launch window width
    /// (MusicMiniPlayerApp.swift windowSize=250) so the very first split --
    /// before GeometryReader ever reports the real width -- is already a
    /// reasonable guess rather than "no width at all" (which would force
    /// every line to stay unsplit until the real width arrives).
    var segmentationRowWidth: CGFloat = 250
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
    /// Batched diagnostics for the current wave. Writing diagnostics from each
    /// row fire path perturbs the same main-queue timing it is trying to measure.
    var pendingTimelineSamples: [DiagnosticLyricWaveTimelineSample] = []
    var sequence: Int = 0
}

private let lyricLineMotionCoordinateSpace = "nanoPod.lyrics.lineMotion"
private let lyricLineMotionSampleInterval: TimeInterval = 0.25
private let lyricLineMotionBoundarySampleInterval: TimeInterval = 0.20
private let lyricLineMotionIdleSampleInterval: TimeInterval = 2.50
private let lyricLineMotionPageSwitchSampleDuration: TimeInterval = 0.95
private let lyricLineMotionTrackSwitchSampleDuration: TimeInterval = 1.25
private let lyricLineMotionLineAdvanceSampleDuration: TimeInterval = 0.85
private let lyricLineMotionCaptureTimeout: TimeInterval = 0.45
private let lyricLineMotionCaptureMissEventInterval: TimeInterval = 3.0
private let lyricLineLayoutSettleDuration: TimeInterval = 0.65
private let lyricInitialRenderVisibleRange = 4
private let lyricSteadyRenderVisibleRange = 6
// A5 (2026-09): was 0.55s — an artificial floor on every translation request,
// stacked on top of the (now memoized, see TranslationAvailabilityMemo) system
// availability check. The generation-counter debounce in
// scheduleTranslationSessionConfigUpdate already
// coalesces bursts from the several onChange sites that call it (track
// change, translationLanguage change, showTranslation toggle, translation
// trigger) — a burst within this window collapses to the LAST call because
// each call bumps `translationConfigGeneration` and only the latest
// `asyncAfter` survives the generation check. 50ms is enough to absorb that
// burst without reading as a perceptible delay.
private let lyricPageSwitchTranslationDeferDuration: TimeInterval = 0.05
private let lyricContentLeadingInset: CGFloat = 32
private let lyricContentTrailingInset: CGFloat = 32

struct LyricWaveTiming {
    struct StaggerTarget {
        let lineIndex: Int
        let delay: TimeInterval
    }

    static let defaultBaseDelay: TimeInterval = 0.08
    static let minimumBaseDelay: TimeInterval = 0.024
    static let settlePadding: TimeInterval = 0.20
    static let maxLineIntervalFraction: TimeInterval = 0.72
    static let tailAccelerationFactor: TimeInterval = 1.05
    static let largeJumpThreshold = 4

    /// `topDown` is the shipping order: rows fire in ascending index order, top to
    /// bottom, outgoing row before incoming row. `syncPair` (feel A/B, `nanopod://
    /// debug/feel/wave/sync`) starts the outgoing row i and incoming row i+1 on the
    /// SAME frame and spreads the wave outward from that pair in both directions.
    enum Shape: Equatable {
        case topDown
        case syncPair
    }

    static func targetRadius(lineInterval: TimeInterval?, hasSyllableSync: Bool) -> Int {
        14
    }

    static func targetIndices(
        renderedIndices: [Int],
        oldIndex: Int,
        newIndex: Int,
        radius: Int,
        existingTargetIndices: some Sequence<Int>
    ) -> [Int] {
        let existing = Set(existingTargetIndices)
        return renderedIndices.filter {
            abs($0 - newIndex) <= radius
                || abs($0 - oldIndex) <= radius
                || existing.contains($0)
            }
    }

    static func staggerSchedule(
        for indices: [Int],
        newIndex: Int,
        lineInterval: TimeInterval? = nil,
        shape: Shape = .topDown
    ) -> [StaggerTarget] {
        switch shape {
        case .topDown:
            return topDownSchedule(for: indices, newIndex: newIndex, lineInterval: lineInterval)
        case .syncPair:
            return syncPairSchedule(for: indices, newIndex: newIndex, lineInterval: lineInterval)
        }
    }

    private static func topDownSchedule(
        for indices: [Int],
        newIndex: Int,
        lineInterval: TimeInterval?
    ) -> [StaggerTarget] {
        guard !indices.isEmpty else { return [] }

        let visibleTopLineIndex = max(0, newIndex - 3)
        let startPosition = indices.firstIndex(where: { $0 >= visibleTopLineIndex }) ?? 0
        var delay: TimeInterval = 0
        var baseDelay = baseDelay(
            for: indices,
            startPosition: startPosition,
            newIndex: newIndex,
            lineInterval: lineInterval
        )
        var schedule: [StaggerTarget] = []

        if startPosition > 0 {
            for i in 0..<startPosition {
                schedule.append(StaggerTarget(lineIndex: indices[i], delay: 0))
            }
        }

        for i in startPosition..<indices.count {
            let lineIndex = indices[i]
            schedule.append(StaggerTarget(lineIndex: lineIndex, delay: delay))
            delay += baseDelay
            if lineIndex >= newIndex {
                baseDelay /= tailAccelerationFactor
            }
        }

        return schedule
    }

    /// `sync` feel arm: outgoing row (newIndex-1) and incoming row (newIndex) both
    /// fire on the boundary frame (delay 0); the wave spreads outward from that
    /// pair in both directions at `baseDelay` per row. Rows below the pair never
    /// accelerate (mirrors how topDown never accelerates before `newIndex`); rows
    /// above the pair use the same tail-acceleration rule as topDown (divide the
    /// increment by `tailAccelerationFactor` after each row at/above `newIndex`).
    /// Rows outside the lead-in radius get delay 0, same as topDown.
    private static func syncPairSchedule(
        for indices: [Int],
        newIndex: Int,
        lineInterval: TimeInterval?
    ) -> [StaggerTarget] {
        guard !indices.isEmpty else { return [] }
        let sorted = indices.sorted()

        let visibleTopLineIndex = max(0, newIndex - 3)
        let startPosition = sorted.firstIndex(where: { $0 >= visibleTopLineIndex }) ?? 0
        let baseDelay = baseDelay(
            for: sorted,
            startPosition: startPosition,
            newIndex: newIndex,
            lineInterval: lineInterval
        )

        var delayByIndex: [Int: TimeInterval] = [:]
        for i in 0..<startPosition {
            delayByIndex[sorted[i]] = 0
        }

        guard let oldPos = sorted.firstIndex(of: newIndex - 1),
              let newPos = sorted.firstIndex(of: newIndex) else {
            // No adjacent boundary pair in this rendered window (edge case, e.g. a
            // seek landed newIndex outside `indices`) — fall back to flat zero for
            // everything past the lead-in, same shape as an all-radius topDown miss.
            for i in startPosition..<sorted.count where delayByIndex[sorted[i]] == nil {
                delayByIndex[sorted[i]] = 0
            }
            return sorted.map { StaggerTarget(lineIndex: $0, delay: delayByIndex[$0] ?? 0) }
        }

        delayByIndex[sorted[oldPos]] = 0
        delayByIndex[sorted[newPos]] = 0

        // Downward: i-1, i-2, ... toward the lead-in cutoff. Constant baseDelay,
        // no tail acceleration (matches topDown, which never accelerates below newIndex).
        if oldPos > startPosition {
            var downDelay: TimeInterval = 0
            var p = oldPos - 1
            while p >= startPosition {
                downDelay += baseDelay
                delayByIndex[sorted[p]] = downDelay
                if p == startPosition { break }
                p -= 1
            }
        }

        // Upward: i+2, i+3, ... with the same tail-acceleration rule topDown applies
        // from newIndex onward.
        if newPos + 1 < sorted.count {
            var upDelay: TimeInterval = 0
            var upBase = baseDelay
            for p in (newPos + 1)..<sorted.count {
                upDelay += upBase
                delayByIndex[sorted[p]] = upDelay
                upBase /= tailAccelerationFactor
            }
        }

        return sorted.map { StaggerTarget(lineIndex: $0, delay: delayByIndex[$0] ?? 0) }
    }

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

    static func seededTargetsForNaturalAdvance(
        existingTargets: [Int: Int],
        indices: [Int],
        oldIndex: Int
    ) -> [Int: Int] {
        var targets = existingTargets
        for index in indices {
            targets[index] = oldIndex
        }
        return targets
    }
}

struct LyricLineAdvanceTiming {
    static let scheduledTargetReuseTolerance: TimeInterval = 0.012
    static let minimumTimerDelay: TimeInterval = 0.006

    static func shouldReuseScheduledTimer(
        existingTarget: TimeInterval?,
        nextTarget: TimeInterval,
        timerActive: Bool
    ) -> Bool {
        guard timerActive, let existingTarget else { return false }
        return abs(existingTarget - nextTarget) <= scheduledTargetReuseTolerance
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
        isTranslating: Bool,
        segmentIndex: Int = 0
    ) -> Bool {
        guard segmentIndex == 0 else { return false }
        return isTranslating && !line.hasTranslation && pendingLineIndices.contains(index)
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

private struct LyricLineMotionSamplingProbe: NSViewRepresentable {
    let interval: TimeInterval
    let onTick: () -> Void

    final class Coordinator {
        var interval: TimeInterval
        var onTick: () -> Void
        private var timer: Timer?

        init(interval: TimeInterval, onTick: @escaping () -> Void) {
            self.interval = interval
            self.onTick = onTick
        }

        func start() {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.onTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func update(interval: TimeInterval, onTick: @escaping () -> Void) {
            let shouldRestart = abs(self.interval - interval) > 0.001
            self.interval = interval
            self.onTick = onTick
            if shouldRestart {
                stop()
                start()
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(interval: interval, onTick: onTick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setFrameSize(.zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(interval: interval, onTick: onTick)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }
}

// MARK: - LyricsView

public struct LyricsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    private let diagnostics = DiagnosticsService.shared
    @Binding var currentPage: PlayerPage
    var openWindow: OpenWindowAction?
    var onHide: (() -> Void)?
    var onExpand: (() -> Void)?

    // Grouping state.
    @State private var scroll = ScrollState()
    @State private var cache = CacheState()
    @State private var wave = WaveState()

    // UI state.
    @State private var isHovering = false
    @State private var isProgressBarHovering = false
    @State private var dragPosition: CGFloat? = nil
    @State private var showControls = true
    @State private var bottomControlsMounted = true
    @State private var controlsBlurAmount: CGFloat = 0
    @State private var controlsOffsetY: CGFloat = 0
    @State private var isAudioOutputMenuPresented = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var lineAdvanceTimer: Timer? = nil
    @State private var lineAdvanceTimerTargetPlaybackTime: TimeInterval? = nil
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
    @State private var lastLineMotionCaptureMissEventAt: Date = .distantPast
    @State private var cachedPendingTranslationLineIndices: Set<Int> = []
    @State private var heightCacheUpdateScheduled = false
    @State private var nativeHeightPrimingScheduled = false
    @State private var displayCurrentLineIndex: Int? = nil
    @State private var cachedDisplayLines: [DisplayLyricLine] = []
    @State private var cachedDisplayLyrics: [LyricLine] = []
    @State private var cachedFirstRealDisplayIndex: Int = 0
    @State private var cachedLayerRows: [LayerBackedLyricRow] = []
    @State private var cachedLayerRowsTrackKey: String = ""
    /// Evidence-log throttle (2026-09-22): the stale-rows gate below is
    /// evaluated every body render, but this timestamp ensures the actual
    /// DebugLogger call — the only I/O — fires at most once per 3s while the
    /// gate stays open, never per-frame. See research/diagnosis-2026-09-22-blank-lyrics-page.md.
    @State private var staleCacheGateEvidenceLoggedAt: Date = .distantPast
    /// Fingerprint of the inputs that produced the last committed rows. The
    /// staged lyrics load drives onChange(lyrics) AND onChange(displayState),
    /// each of which calls refreshDisplayLineCache(); without a dedup the same
    /// logical state is committed 2-3x (verified in the stage log: byte-
    /// identical commits 1-4ms apart) and every redundant commit re-pokes the
    /// native surface = a visible "refresh". 0 = nothing committed yet.
    @State private var lastCommittedRowsFingerprint: Int = 0
    /// Plan A (2026-09-22, docs/lyrics-ux-contract.md §E): the split decision
    /// for a long line now needs the REAL lyrics column width (real
    /// NSLayoutManager wrap, not a unit estimate) -- so unlike the other
    /// inputs in `displayLineInputFingerprint`, a width change alone must be
    /// able to trigger a rebuild even though `lyrics`/`showTranslation`/etc.
    /// haven't changed. `hasEstablishedSegmentationWidth` lets the FIRST width
    /// this view instance observes (e.g. right after a track loads) apply
    /// immediately with no debounce -- only a width CHANGE afterwards (live
    /// window resizing) is debounced, so a fresh song never briefly renders
    /// against a guessed default width and then visibly reflows.
    @State private var hasEstablishedSegmentationWidth = false
    @State private var lyricsSegmentationWidthGeneration: Int = 0
    private let lyricsSegmentationWidthDebounceDuration: TimeInterval = 0.15
    @State private var contentTransitionOpacity: Double = 1
    // "向下生长" intro: the whole lyrics page drops down into place + fades on every track load.
    // Paired with contentTransitionOpacity and animated together in refreshDisplayLineCache. This
    // lives at the SwiftUI container level (a pure .offset transform) — deliberately OUTSIDE the
    // native renderer's per-row reveal path, so it cannot reintroduce the track-switch bloom.
    @State private var contentTransitionOffset: CGFloat = 0
    @State private var cachedNativeRenderedIndices: [Int] = []
    @State private var nativeLyricsManualScrollActive = false
    @State private var nativeLyricsDirectSnapRequest: NativeLyricsDirectSnapRequest?
    @State private var nativeLyricsSurfaceController = NativeLyricsSurfaceController()
    @State private var lastRendererModeEventSignature: String?
    // Translation state.
    @State private var translationSessionConfigAny: Any?
    @State private var translationConfigGeneration = 0
    @State private var translationPreflightTask: Task<Void, Never>?

    // Accessibility.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // Settings.
    @State private var fullscreenAlbumCover: Bool = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")
    @State private var diagnosticsEnabledSnapshot: Bool = DiagnosticsService.shared.isEnabled
    @State private var lineMotionDiagnosticsEnabledSnapshot: Bool = DiagnosticsService.shared.isLineMotionGeometryEnabled
    @State private var lyricWaveTimelineDiagnosticsEnabledSnapshot: Bool = DiagnosticsService.shared.isLyricWaveTimelineEnabled

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
                // One state, one view (review #5). The old isLoading/error/
                // lyrics.isEmpty chain let "loading" win over freshly applied
                // cached lyrics; the service's state machine now guarantees
                // content is never demoted back to a spinner.
                switch lyricsService.displayState {
                case .searching:
                    loadingView
                case .deepSearching:
                    deepSearchingView
                case .networkUnreachable:
                    errorView(lyricsService.error ?? LyricsService.networkUnreachableErrorMessage)
                case .noLyrics:
                    // The terminal verdict's specific wording must survive —
                    // "Instrumental track" is information, not an error; only
                    // a wordless miss falls back to the generic empty state.
                    if let verdictText = lyricsService.error, !verdictText.isEmpty {
                        errorView(verdictText)
                    } else {
                        emptyStateView
                    }
                case .content:
                    // Safety net mirroring the old chain's empty-lyrics branch
                    // (reachable only via debug fixtures).
                    if lyricsService.lyrics.isEmpty {
                        emptyStateView
                    } else {
                        scrollableLyricsContent
                    }
                }
            }
            // Song-switch choreography. Two layers of protection against the switch
            // flash (old lyrics → 1-2 frames of bare/stale panel → new content):
            // 1. The identity term: the very first render after a track change still
            //    carries the OLD rows cache (SwiftUI runs onChange after body), and the
            //    stale-rows gate blanks the surface that frame — rendering it at
            //    opacity 0 makes that frame invisible. The mismatch lasts until the
            //    cache rebuilds for the new track (1-3 frames).
            // 2. contentTransitionOpacity: dipped to 0 on the title change, faded back
            //    in by refreshDisplayLineCache once the new track's state is ready —
            //    so spinner/lyrics enter with a soft fade instead of popping.
            .opacity(trackCacheMatchesCurrentTrack ? contentTransitionOpacity : 0)
            // "向下生长": the page enters shifted up and settles down (paired with the fade above).
            .offset(y: trackCacheMatchesCurrentTrack ? contentTransitionOffset : 0)
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
        // Page-switch changes.
        .onChange(of: currentPage) { _, newPage in
            if newPage != .lyrics {
                bottomControlsMounted = false
                pendingTrackLyricsFetchTask?.cancel()
                pendingTrackLyricsFetchTask = nil
                lineAdvanceTimer?.invalidate()
                lineAdvanceTimer = nil
                lineAdvanceTimerTargetPlaybackTime = nil
                translationPreflightTask?.cancel()
                translationPreflightTask = nil
                // 缺陷1修复（2026-09-14）：这里曾经把 translationSessionConfigAny
                // 清空，导致 TranslationTaskHostView 的 .translationTask 被拆除。
                // 但 TranslationTaskHostView 本身跟页面无关，一直挂在视图树里
                // （829行 .background），A5 的设计意图就是"一个 session 撑全程，
                // 换歌不重建"——离开歌词页把它清空，直接违反这个意图：回到歌词页
                // 没有任何地方会重建它，此后不管换多少首歌，翻译请求都 yield 到
                // 一个没有活跃消费者的 stream 上，永久失效直到用户手动切一次语言
                // 或翻译开关。不再清空，session 跟着 songID/语言/开关变化才重建
                // （见下面 newPage == .lyrics 分支 + onChange(translationLanguage/
                // showTranslation) 三处既有触发点）。
                lineMotionFrameCaptureActive = false
                pendingLineMotionCapture = nil
                latestLineMotionFrames.removeAll()
                nativeLyricsManualScrollActive = false
            }
            if newPage == .lyrics {
                isHovering = true
                bottomControlsMounted = true
                animateControlsIn()
                recordLyricsRendererModeEvent(reason: "page")
                updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
                scheduleNextLineAdvanceTimer()
                startLineMotionSamplingWindow(duration: lyricLineMotionPageSwitchSampleDuration)
                // 缺陷1修复：首次进入歌词页（session 还从未建立过，比如启动后
                // 默认停在封面页、翻译开关此前一直没被切换过）在这里兜底建一次。
                // session 一旦建立，上面的分支不再清空它，之后换页不需要重复
                // 触发；updateTranslationSessionConfig 内部按配置是否真的变化
                // 短路，重复调用无副作用。
                if #available(macOS 15.0, *) {
                    scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
                }
            }
        }
        // Initial mount and track changes.
        .onAppear {
            debugPrint("📝 [LyricsView] onAppear - track: '\(musicController.currentTrackTitle)' by '\(musicController.currentArtist)'\n")
            refreshDiagnosticsRuntimeState(applyLifecycle: false)
            recordLyricsRendererModeEvent(reason: "appear")
            refreshDisplayLineCache()
            refreshPendingTranslationLineIndices()
            suppressLineMotionDuringLayoutSettlement(duration: lyricLineLayoutSettleDuration)
            startLineMotionSamplingWindow(duration: lyricLineMotionPageSwitchSampleDuration)
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration,
                                      album: musicController.currentAlbum,
                                      persistentID: musicController.currentPersistentID)
            if #available(macOS 15.0, *) {
                scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
            }
        }
        .onChange(of: musicController.currentTrackTitle) {
            debugPrint("📝 [LyricsView] onChange(currentTrackTitle) - track: '\(musicController.currentTrackTitle)' by '\(musicController.currentArtist)'\n")
            if currentPage == .lyrics {
                recordLyricsRendererModeEvent(reason: "track")
            }
            cancelWaveAnimations()
            wave.lineTargetIndices.removeAll()
            wave.lastCurrentIndex = -1
            cache.heightCacheInvalidated = true
            cache.renderedIndicesValid = false
            cachedDisplayLines.removeAll()
            cachedDisplayLyrics.removeAll()
            cachedLayerRows.removeAll()
            cachedLayerRowsTrackKey = ""
            lastCommittedRowsFingerprint = 0
            // Start the new track's content dark AND shifted up; refreshDisplayLineCache fades it
            // in while settling it down ("向下生长" intro). Set with no animation here (content is
            // invisible at opacity 0), so only the reveal animates.
            contentTransitionOpacity = 0
            contentTransitionOffset = -18
            cachedNativeRenderedIndices.removeAll()
            cachedFirstRealDisplayIndex = 0
            displayCurrentLineIndex = nil
            pendingLineHeightResetForNextPayload = true
            // Reset manual scroll state to prevent stuck isManualScrolling
            // when track changes during a manual scroll (timer would fire on stale state)
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
            lineAdvanceTimer?.invalidate()
            lineAdvanceTimer = nil
            lineAdvanceTimerTargetPlaybackTime = nil
            scroll.isManualScrolling = false
            lyricsService.isManualScrolling = false
            scroll.manualScrollOffset = 0
            scroll.rawScrollOffset = 0
            scroll.frozenDisplayIndex = nil
            scroll.lockedLineIndex = nil
            nativeLyricsManualScrollActive = false
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
        .onChange(of: lyricsService.displayState) { _, _ in
            // A no-lyrics → no-lyrics track switch republishes nothing on `lyrics`
            // ([] == []), which would leave the identity gate mismatched — and the
            // content dark — forever. Every fetch transitions the display state,
            // so re-tag the cache for the current track here whenever the gate
            // is stale.
            if !trackCacheMatchesCurrentTrack {
                refreshDisplayLineCache()
                refreshPendingTranslationLineIndices()
            }
        }
        // Translation changes.
        .onChange(of: lyricsService.lyrics) { oldLyrics, newLyrics in
            let translationOnly = LyricsService.isTranslationOnlyWriteback(
                previous: oldLyrics, next: newLyrics
            )
            let newCount = newLyrics.count
            refreshDisplayLineCache()
            refreshPendingTranslationLineIndices()
            if newCount > 0, pendingLineHeightResetForNextPayload {
                cache.lineHeights.removeAll()
                pendingLineHeightResetForNextPayload = false
            }
            if translationOnly {
                cache.heightCacheInvalidated = true
            }
            updateHeightCache()
            guard newCount > 0, !translationOnly else { return }
            updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
            scheduleNextLineAdvanceTimer()
            suppressLineMotionDuringLayoutSettlement(duration: lyricLineLayoutSettleDuration)
            startLineMotionSamplingWindow(duration: lyricLineMotionTrackSwitchSampleDuration)
        }
        .onChange(of: musicController.isPlaying) { _, isPlaying in
            if isPlaying {
                scheduleNextLineAdvanceTimer()
            } else {
                lineAdvanceTimer?.invalidate()
                lineAdvanceTimer = nil
                lineAdvanceTimerTargetPlaybackTime = nil
            }
        }

        .onChange(of: lyricsService.translationLanguage) { _, _ in
            if #available(macOS 15.0, *) {
                scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
            }
        }
        .onChange(of: lyricsService.showTranslation) { _, newValue in
            refreshPendingTranslationLineIndices()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                cache.heightCacheInvalidated = true
            }
            if #available(macOS 15.0, *), newValue {
                scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)
            }
        }
        .onChange(of: lyricsService.translationRequestTrigger) { _, _ in
            if #available(macOS 15.0, *) {
                // Coalescing now lives in LyricsService.requestTranslation()
                // (TranslationRequestCoalescer, fake-clock tested) instead of
                // a view-level generation-counter defer — the request is
                // enqueued onto the live translation session's request
                // stream, not used to rebuild the session/host.
                lyricsService.requestTranslation()
            }
        }
        // Phase 2 piece translations (2026-09-22): a per-piece on-device
        // translation landed in PieceTranslationCache. Rebuild the display
        // lines so the newly-cached text is picked up -- `forceRebuild`
        // because `lyrics` itself didn't change, so the ordinary fingerprint
        // dedup would otherwise skip this. Row ids are unaffected (same
        // segmentation), so this is the same cheap translation-only
        // reconfigure path late whole-line translations already use (see
        // LyricsLateTranslationInsertTests / configureSignature's
        // translation hash) -- no full rebuild, no flicker.
        .onChange(of: lyricsService.pieceTranslationVersion) { _, _ in
            refreshDisplayLineCache(forceRebuild: true)
        }
        .onChange(of: lyricsService.isTranslating) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                cache.heightCacheInvalidated = true
            }
        }
        // Scroll, wave, and error changes.
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
                    if !lyricsLayerRendererActive {
                        triggerWaveAnimation(from: oldIndex, to: newIndex)
                    }
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
        // Settings changes.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let newValue = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")
            if newValue != fullscreenAlbumCover {
                withAnimation(.easeInOut(duration: 0.3)) { fullscreenAlbumCover = newValue }
            }
            refreshDiagnosticsRuntimeState(applyLifecycle: true)
        }
        .onReceive(musicController.timePublisher.$currentTime) { _ in
            guard currentPage == .lyrics else { return }
            guard !lyricsLayerRendererActive else { return }
            updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
            scheduleNextLineAdvanceTimer()
        }
        .background(TranslationTaskHostView(
            translationSessionConfigAny: translationSessionConfigAny,
            lyricsService: lyricsService
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
        if lineMotionMonitoringEnabled && !lyricsLayerRendererActive {
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

    /// Deep-search phase: the quick foreground burst found nothing and the
    /// authoritative backfill is still running. Same spinner as loadingView
    /// plus a label, so the wait reads as labeled progress instead of an
    /// anonymous stall (review #5). The wait itself is bounded: the backfill
    /// is hard-capped at AuthoritativeBackfillBudget.overall (9s, review
    /// #6+#7), so this view's lifetime matches a ceiling the pipeline
    /// actually enforces.
    private var deepSearchingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Searching more sources…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在搜索更多歌词来源")
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
                    persistentID: musicController.currentPersistentID,
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
        lineMotionDiagnosticsEnabledSnapshot && currentPage == .lyrics && !lyricsService.lyrics.isEmpty
    }

    private var lyricsLayerRendererActive: Bool {
        LyricsRendererMode.current == .native
    }

    private var isAnyLyricsManualScrolling: Bool {
        scroll.isManualScrolling || nativeLyricsManualScrollActive
    }

    private func refreshDiagnosticsRuntimeState(applyLifecycle: Bool) {
        let previousEnabled = diagnosticsEnabledSnapshot
        let previousLineMotionEnabled = lineMotionDiagnosticsEnabledSnapshot
        let nextEnabled = diagnostics.isEnabled
        let nextLineMotionEnabled = diagnostics.isLineMotionGeometryEnabled

        diagnosticsEnabledSnapshot = nextEnabled
        lineMotionDiagnosticsEnabledSnapshot = nextLineMotionEnabled
        lyricWaveTimelineDiagnosticsEnabledSnapshot = diagnostics.isLyricWaveTimelineEnabled

        guard applyLifecycle else { return }

        if nextEnabled && !previousEnabled {
            startLineMotionSamplingWindow(duration: lyricLineMotionPageSwitchSampleDuration)
        } else if !nextEnabled && previousEnabled {
            lineMotionSamplingActive = false
            lineMotionFrameCaptureActive = false
            pendingLineMotionCapture = nil
            latestLineMotionFrames.removeAll()
        } else if nextLineMotionEnabled && !previousLineMotionEnabled {
            startLineMotionSamplingWindow(duration: lyricLineMotionPageSwitchSampleDuration)
        }
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
            let layerActive = LyricsRendererMode.current == .native
            // AMLL: highlight switches immediately; Y movement transitions through the wave spring.
            let displayIndex = !layerActive && scroll.isManualScrolling
                ? (scroll.frozenDisplayIndex ?? liveIndex)
                : liveIndex
            let isLineWaveActive = !wave.workItems.isEmpty
            let _ = updateLyricsContainerHeight(containerHeight)
            let _ = updateLyricsSegmentationWidthIfNeeded(geo.size.width)
            // Clamp the active-line anchor so a tall wrapped line keeps its sung text visible:
            // never lifted above the top header inset, and pulled above the bottom controls
            // when it still fits. The native height cache primes ASYNCHRONOUSLY, so a freshly
            // activated tall line can momentarily be missing from the cache and fall back to the
            // small default height — anchoring it at the base position where its lower sublines
            // render behind the controls and disappear. Measure it synchronously in that case.
            let activeLineHeight: CGFloat = {
                if cache.lineHeights[displayIndex] != nil {
                    return calculateAccumulatedHeight(upTo: displayIndex + 1)
                        - calculateAccumulatedHeight(upTo: displayIndex)
                }
                guard let activeRow = cachedLayerRows.first(where: { $0.index == displayIndex }) else {
                    return calculateAccumulatedHeight(upTo: displayIndex + 1)
                        - calculateAccumulatedHeight(upTo: displayIndex)
                }
                return NativeLyricsRowMeasurement.estimatedHeight(
                    for: activeRow,
                    rowWidth: geo.size.width,
                    showTranslation: lyricsService.showTranslation,
                    isTranslating: lyricsService.isTranslating,
                    pendingTranslationLineIndices: cachedPendingTranslationLineIndices
                )
            }()
            // 42 == the renderer's visibleTopY: the top header/fade band the active line's top
            // must stay below so the sung main text never clips behind it.
            let anchorY = LyricsAnchorPolicy.anchorY(
                containerHeight: containerHeight,
                controlBarHeight: controlBarHeight,
                activeLineHeight: activeLineHeight,
                topInset: 42
            )
            let pendingTranslationLineIndices = cachedPendingTranslationLineIndices
            // Visibility culling: only during steady auto-play with all heights measured
            let visibleRange = 12
            let cullingMeasurementThreshold = min(renderedIndices.count, max(8, visibleRange * 2))
            let hasEnoughMeasuredHeights = cache.lineHeights.count >= cullingMeasurementThreshold
            let shouldCull = !scroll.isManualScrolling && hasEnoughMeasuredHeights
            let activeWaveIndices = Set(wave.lineTargetIndices.keys)
            let visibleIndices = displayLines.enumerated().compactMap { index, _ -> Int? in
                guard index == 0 || index >= firstRealDisplayIndex else { return nil }
                guard !shouldCull || abs(index - displayIndex) <= visibleRange || activeWaveIndices.contains(index) else {
                    return nil
                }
                return index
            }
            // Rows built for ANOTHER track must never render under the new track's identity.
            // SwiftUI runs onChange(currentTrackTitle) AFTER the body, so the first render
            // after a track change evaluates with the NEW title but the OLD cached rows —
            // the surface then mounts one frame of the previous song's lyrics (stale-rows
            // flash at track-change teardown). Gate on the identity the cache was built for
            // and feed an empty list until refreshDisplayLineCache rebuilds it.
            let cacheIsCurrentTrack = cachedLayerRowsTrackKey == Self.layerRowsTrackKey(for: musicController)
            let _ = logStaleCacheGateEvidenceIfNeeded(cacheIsCurrentTrack: cacheIsCurrentTrack)
            let allLayerRows = cacheIsCurrentTrack ? cachedLayerRows : []
            let nativeRenderedIndices = cacheIsCurrentTrack ? cachedNativeRenderedIndices : []
            let layerHeightIndices = Set(nativeRenderedIndices + [displayIndex] + Array(activeWaveIndices))
            let layerAccumulatedHeights = Dictionary(uniqueKeysWithValues: layerHeightIndices.map {
                ($0, cache.cachedAccumulatedHeights[$0] ?? calculateAccumulatedHeight(upTo: $0))
            })
            let _ = primeNativeRowHeightsIfNeeded(
                rowWidth: geo.size.width,
                rows: allLayerRows,
                pendingTranslationLineIndices: pendingTranslationLineIndices
            )

            Group {
                if layerActive {
                    NativeLyricsSurface(
                        rows: allLayerRows,
                        currentIndex: displayIndex,
                        anchorY: anchorY,
                        rowWidth: geo.size.width,
                        renderedIndices: nativeRenderedIndices,
                        accumulatedHeights: layerAccumulatedHeights,
                        lineTargetIndices: wave.lineTargetIndices,
                        lineInterval: estimatedLineInterval(around: displayIndex, in: displayLyrics),
                        hasSyllableSync: displayLyrics.indices.contains(displayIndex) && displayLyrics[displayIndex].hasSyllableSync,
                        trackContext: musicController.diagnosticsTrackContext(),
                        isWaveTimelineDiagnosticsEnabled: lyricWaveTimelineDiagnosticsEnabledSnapshot,
                        isManualScrolling: false,
                        reduceMotion: reduceMotion,
                        suppressInitialMotion: suppressInitialLineMotion && !isLineWaveActive,
                        pendingTranslationLineIndices: pendingTranslationLineIndices,
                        showTranslation: lyricsService.showTranslation,
                        isTranslating: lyricsService.isTranslating,
                        translationFailed: lyricsService.translationFailed,
                        interludeAfterIndex: lyricsService.interludeAfterIndex,
                        directSnapRequest: nativeLyricsDirectSnapRequest,
                        controlsVisible: showControls || isAudioOutputMenuPresented,
                        surfaceController: nativeLyricsSurfaceController,
                        musicController: musicController,
                        onLineTap: { line in handleLineTap(line: line, requestNativeDirectSnap: false) },
                        onDirectSnapConsumed: { requestID in
                            if nativeLyricsDirectSnapRequest?.id == requestID {
                                nativeLyricsDirectSnapRequest = nil
                            }
                        },
                        onManualScrollStarted: { frozenIndex in
                            handleNativeManualScrollStarted(frozenDisplayIndex: frozenIndex)
                        },
                        onManualScrollDelta: { deltaY, velocity in
                            handleNativeScrollChromeDelta(deltaY, velocity: velocity)
                        },
                        onManualScrollEnded: {
                            handleNativeManualScrollEnded()
                        },
                        onManualScrollRecovered: {
                            handleNativeManualScrollRecovered()
                        },
                        onManualScrollChromeReset: {
                            scroll.scrollLocked = false
                            scroll.hasTriggeredSlowScroll = false
                        },
                        onHeightMeasured: { index, height in
                            if abs((cache.lineHeights[index] ?? 0) - height) > 2.0 {
                                cache.lineHeights[index] = height
                                cache.heightCacheInvalidated = true
                                scheduleHeightCacheUpdate()
                            }
                        },
                        lineMotionSamplingEnabled: lineMotionMonitoringEnabled,
                        lineMotionFocusedSamplingUntil: lineMotionSamplingUntil,
                        lineMotionFirstRealDisplayIndex: firstRealDisplayIndex,
                        onLineMotionFrames: { frames, nativePresentationSnapshot, nativeSampleTimestamp, nativeSamplePlaybackTime in
                            let capture = pendingLineMotionCapture
                            if capture != nil {
                                pendingLineMotionCapture = nil
                            }
                            let sampleTimestamp = capture?.requestedAt ?? nativeSampleTimestamp ?? Date()
                            let samplePlaybackTime = capture?.playbackTime
                                ?? nativeSamplePlaybackTime
                                ?? musicController.lyricRenderTime(at: sampleTimestamp)
                            let nativeManualSnapshot = nativePresentationSnapshot.manualScrollSnapshot
                            let nativeDisplayIndex = nativeManualSnapshot?.frozenDisplayIndex ?? displayIndex
                            recordLyricLineMotion(
                                frames: frames,
                                anchorY: anchorY,
                                containerHeight: containerHeight,
                                controlBarHeight: controlBarHeight,
                                displayIndex: nativeDisplayIndex,
                                displayLines: displayLines,
                                displayLyrics: displayLyrics,
                                firstRealDisplayIndex: firstRealDisplayIndex,
                                playbackTime: samplePlaybackTime,
                                timestamp: sampleTimestamp,
                                framesIncludeLineOffset: true,
                                presentationTargetIndices: nativePresentationSnapshot.targetIndices,
                                nativeManualScrollSnapshot: nativeManualSnapshot,
                                nativePresentationSnapshot: nativePresentationSnapshot
                            )
                            if capture != nil {
                                DispatchQueue.main.async {
                                    lineMotionFrameCaptureActive = false
                                    latestLineMotionFrames.removeAll()
                                }
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: lyricLineMotionCoordinateSpace)
            .onPreferenceChange(LyricLineMotionFramePreferenceKey.self) { frames in
                guard lineMotionFrameCaptureActive, !layerActive else {
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
        .modifier(BottomFadeMask(isActive: showControls, steepFade: isAnyLyricsManualScrolling))
        .id(lyricsViewID)
        .contentShape(Rectangle())
        .scrollDetectionWithVelocity(
            onScrollStarted: { handleScrollStarted() },
            onScrollEnded: { handleScrollEnded() },
            onScrollWithVelocity: { deltaY, velocity in handleScrollDelta(deltaY, velocity: velocity) },
            isEnabled: currentPage == .lyrics && !lyricsLayerRendererActive
        )
    }

    // MARK: - Lyric Line Helpers

    private func makeLayerBackedRows(from displayLines: [DisplayLyricLine]) -> [LayerBackedLyricRow] {
        LyricLayerRowBuilder.makeRows(
            from: displayLines,
            sourceLines: lyricsService.lyrics,
            firstRealLyricIndex: lyricsService.firstRealLyricIndex
        )
    }


    private func refreshPendingTranslationLineIndices() {
        cachedPendingTranslationLineIndices = lyricsService.showTranslation
            ? LyricLineTranslationLayoutPolicy.pendingLineIndices(in: lyricsService.lyrics)
            : []
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

        if lyricsLayerRendererActive {
            let captured = nativeLyricsSurfaceController.captureLineMotionFrames(
                timestamp: now,
                playbackTime: playbackTime
            )
            if !captured {
                recordLineMotionCaptureMissIfNeeded(timestamp: now, playbackTime: playbackTime)
            }
            return
        }

        let capture = LyricLineMotionCaptureRequest(requestedAt: now, playbackTime: playbackTime)
        pendingLineMotionCapture = capture
        lineMotionFrameCaptureActive = true

        DispatchQueue.main.asyncAfter(deadline: .now() + lyricLineMotionCaptureTimeout) {
            guard pendingLineMotionCapture == capture else { return }
            pendingLineMotionCapture = nil
            lineMotionFrameCaptureActive = false
            latestLineMotionFrames.removeAll()
            recordLineMotionCaptureMissIfNeeded(timestamp: Date(), playbackTime: playbackTime)
        }
    }

    private func recordLineMotionCaptureMissIfNeeded(timestamp: Date, playbackTime: TimeInterval) {
        guard timestamp.timeIntervalSince(lastLineMotionCaptureMissEventAt) >= lyricLineMotionCaptureMissEventInterval else {
            return
        }
        lastLineMotionCaptureMissEventAt = timestamp
        diagnostics.recordLyricsLineMotionCaptureMiss(
            track: musicController.diagnosticsTrackContext(),
            playbackTime: playbackTime,
            lyricLineCount: cachedDisplayLyrics.count,
            displayLineCount: cachedDisplayLines.count,
            displayIndex: displayCurrentLineIndex ?? -1,
            monitoringEnabled: lineMotionMonitoringEnabled
        )
    }

    private func startLineMotionSamplingWindow(duration: TimeInterval) {
        guard diagnosticsEnabledSnapshot else { return }
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
        timestamp: Date,
        framesIncludeLineOffset: Bool = false,
        presentationTargetIndices: [Int: Int]? = nil,
        nativeManualScrollSnapshot: NativeLyricsManualScrollSnapshot? = nil,
        nativePresentationSnapshot: NativeLyricsPresentationSnapshot? = nil
    ) {
        guard currentPage == .lyrics, diagnosticsEnabledSnapshot, !frames.isEmpty else { return }

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
            let baseMidY: Double
            let targetMinY: Double
            let targetMidY: Double
            let waveOffsetY: Double
        }

        let effectiveManualOffset = nativeManualScrollSnapshot?.manualOffset ?? scroll.manualScrollOffset
        let effectiveManualScrolling = scroll.isManualScrolling || nativeManualScrollSnapshot?.isActive == true
        let effectiveFrozenIndex = nativeManualScrollSnapshot?.frozenDisplayIndex ?? scroll.lockedLineIndex
        let immediateLineOffset = anchorY - calculateAccumulatedHeight(upTo: displayIndex)
        let partials: [MotionPartial] = sorted.map { index, frame in
            let displayLine = displayLines[index]
            let line = displayLine.line
            let targetIndex = effectiveManualScrolling
                ? (effectiveFrozenIndex ?? displayIndex)
                : (presentationTargetIndices?[index] ?? wave.lineTargetIndices[index] ?? displayIndex)
            let accumulatedHeight = calculateAccumulatedHeight(upTo: index)
            let lineOffset = calculateLineOffset(
                index: index,
                currentIndex: displayIndex,
                anchorY: anchorY,
                targetIndices: presentationTargetIndices
            )
            let fullOffset = lineOffset + accumulatedHeight
            let appliedOffsetY = framesIncludeLineOffset
                ? 0
                : Double(fullOffset + effectiveManualOffset)
            let nativeTargetMinY = nativePresentationSnapshot?.targetMinYByIndex[index]
            let targetLineOffset = nativeTargetMinY.map { $0 - accumulatedHeight } ?? lineOffset
            let baseMidY = Double(accumulatedHeight) + Double(frame.height / 2)
            let targetMinY = framesIncludeLineOffset
                ? Double((nativeTargetMinY ?? fullOffset) + effectiveManualOffset)
                : Double(accumulatedHeight) + Double(immediateLineOffset + effectiveManualOffset)
            let targetMidY = targetMinY + Double(frame.height / 2)
            return MotionPartial(
                index: index,
                displayLine: displayLine,
                line: line,
                frame: frame,
                targetIndex: targetIndex,
                appliedOffsetY: appliedOffsetY,
                baseMidY: baseMidY,
                targetMinY: targetMinY,
                targetMidY: targetMidY,
                waveOffsetY: Double(targetLineOffset - immediateLineOffset)
            )
        }

        var samples: [DiagnosticLyricLineMotionSample] = []
        samples.reserveCapacity(partials.count)
        var previousRenderedMidY: Double?
        var previousBaseMidY: Double?
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
            let expectedDelta = previousBaseMidY.map { partial.baseMidY - $0 }
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
                velocityY: Double(nativePresentationSnapshot?.velocityYByIndex[partial.index] ?? 0),
                observedInterLineDeltaY: observedDelta,
                expectedInterLineDeltaY: expectedDelta,
                interLineDeltaErrorY: deltaError,
                waveOffsetY: partial.waveOffsetY,
                manualScrollOffsetY: Double(effectiveManualOffset),
                isManualScrolling: effectiveManualScrolling,
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
            previousBaseMidY = partial.baseMidY
        }

        let activeTargetIndex = partials.first { $0.index == activeIndex }?.targetIndex
            ?? presentationTargetIndices?[activeIndex]
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

        if lyricsService.showTranslation,
           !lyricsService.isTranslating {
            let visibleTranslationPartials = partials.filter {
                shouldConsiderVisibleTranslationLine($0.line.text)
            }
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

    private func calculateLineOffset(
        index: Int,
        currentIndex: Int,
        anchorY: CGFloat,
        targetIndices: [Int: Int]? = nil
    ) -> CGFloat {
        if scroll.isManualScrolling {
            let frozenTargetIndex = scroll.lockedLineIndex ?? currentIndex
            return anchorY - calculateAccumulatedHeight(upTo: frozenTargetIndex)
        } else {
            // GCD wave: each line's target is updated independently via asyncAfter.
            // Lines not yet flipped retain the previous wave's target (= oldIndex),
            // creating the stagger. Fallback to currentIndex for lines never in a wave.
            let lineTargetIndex = targetIndices?[index] ?? wave.lineTargetIndices[index] ?? currentIndex
            return anchorY - calculateAccumulatedHeight(upTo: lineTargetIndex)
        }
    }

    // MARK: - Overlay Components

    private var bottomControlsOverlay: some View {
        VStack {
            Spacer()
            if shouldMountBottomControls {
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
                .transition(.opacity)
            }
        }
        .allowsHitTesting(showControls)
        .opacity(showControls ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showControls)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controlsBlurAmount)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controlsOffsetY)
    }

    private var shouldMountBottomControls: Bool {
        currentPage == .lyrics
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

    // MARK: - Interaction Handling

    private func animateControlsIn() {
        bottomControlsMounted = true
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
        } else if !isAnyLyricsManualScrolling {
            animateControlsIn()
        }
    }

    private func handleAudioOutputMenuPresentation(_ presented: Bool) {
        isAudioOutputMenuPresented = presented
        guard !presented, !isHovering else { return }
        animateControlsOut()
    }

    private func recordLyricsRendererModeEvent(reason: String) {
        guard diagnosticsEnabledSnapshot else { return }
        let resolution = LyricsRendererMode.currentResolution
        let mode = resolution.mode
        let signature = [
            reason,
            mode.rawValue,
            resolution.source,
            resolution.rawValue ?? "nil",
            musicController.currentTrackTitle,
            musicController.currentArtist
        ].joined(separator: "|")
        guard signature != lastRendererModeEventSignature else { return }
        lastRendererModeEventSignature = signature
        diagnostics.recordEvent(
            "lyrics.rendererMode",
            detail: "Lyrics renderer mode selected (\(reason), mode: \(mode.rawValue), source: \(resolution.source), raw: \(resolution.rawValue ?? "nil"))",
            track: musicController.diagnosticsTrackContext(),
            metrics: [
                "isNative": mode == .native ? 1 : 0
            ]
        )
    }

    private func handleLineTap(line: LyricLine, requestNativeDirectSnap: Bool = true) {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        cancelLineAdvanceTimer()
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
        if lyricsLayerRendererActive && requestNativeDirectSnap {
            nativeLyricsDirectSnapRequest = NativeLyricsDirectSnapRequest(
                displayIndex: newIdx,
                reason: .tapToLine
            )
        }
        // Unfreeze — no withAnimation! The .animation(value: fullOffset) on each line
        // handles the spring transition naturally when fullOffset changes.
        scroll.isManualScrolling = false
        lyricsService.isManualScrolling = false
        nativeLyricsManualScrollActive = false
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
                                      album: album,
                                      persistentID: musicController.currentPersistentID)
        }
    }

    private func handleExternalManualScroll(_ newValue: Bool) {
        guard !lyricsLayerRendererActive else { return }
        guard newValue && !scroll.isManualScrolling else { return }

        if cache.heightCacheInvalidated { updateHeightCache() }
        let currentIdx = displayCurrentLineIndex ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0)
        scroll.lockedLineIndex = currentIdx
        scroll.frozenDisplayIndex = currentIdx  // Freeze the highlighted row.
        scroll.isManualScrolling = true
        scroll.scrollLocked = false
        scroll.hasTriggeredSlowScroll = false

        autoScrollTimer?.invalidate()
        cancelLineAdvanceTimer()
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

    // MARK: - Scroll Handling

    private func handleScrollStarted() {
        autoScrollTimer?.invalidate()
        cancelLineAdvanceTimer()
        if cache.heightCacheInvalidated { updateHeightCache() }

        let currentIdx = displayCurrentLineIndex ?? displayIndex(forSourceIndex: lyricsService.currentLineIndex ?? 0)
        scroll.lockedLineIndex = currentIdx
        scroll.frozenDisplayIndex = currentIdx  // Freeze the highlighted row.
        scroll.rawScrollOffset = scroll.manualScrollOffset
        scroll.isManualScrolling = true
        lyricsService.isManualScrolling = true
        scroll.scrollLocked = false
        scroll.hasTriggeredSlowScroll = false
    }

    private func handleScrollEnded() {
        // Bounce back to bounds immediately after release.
        let (maxUp, maxDown) = scrollBounds()
        if scroll.rawScrollOffset > maxUp || scroll.rawScrollOffset < -maxDown {
            scroll.rawScrollOffset = min(maxUp, max(-maxDown, scroll.rawScrollOffset))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                scroll.manualScrollOffset = scroll.rawScrollOffset
            }
        }

        // Spring back to the currently playing row after 2 seconds.
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

            // After recovery, show controls if the mouse is still inside the window.
            if isHovering { animateControlsIn() }
            scheduleNextLineAdvanceTimer()
        }
    }

    private func handleScrollDelta(_ deltaY: CGFloat, velocity: CGFloat) {
        // Apple-style rubber banding.
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

        handleScrollChromeDelta(deltaY, velocity: velocity)
    }

    private func handleScrollChromeDelta(_ deltaY: CGFloat, velocity: CGFloat) {
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
    }

    private func handleNativeScrollChromeDelta(_ deltaY: CGFloat, velocity: CGFloat) {
        // NOTE: must NOT write any @State here per scroll event. `scroll` is a struct in
        // @State, so any field write invalidates this view → SwiftUI re-runs body + a full
        // NSHostingView layout pass on the next display cycle. At a scroll's event rate (and
        // doubled at 120 Hz) that re-layout dominates scroll-time CPU. handleScrollChromeDelta
        // only mutates `scroll` on genuine show/hide transitions, which is fine.
        handleScrollChromeDelta(deltaY, velocity: velocity)
    }

    private func handleNativeManualScrollStarted(frozenDisplayIndex: Int) {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        cancelLineAdvanceTimer()
        if cache.heightCacheInvalidated { updateHeightCache() }
        nativeLyricsManualScrollActive = true
        lyricsService.isManualScrolling = true
        scroll.lockedLineIndex = frozenDisplayIndex
        scroll.frozenDisplayIndex = frozenDisplayIndex
        scroll.scrollLocked = false
        scroll.hasTriggeredSlowScroll = false
    }

    private func handleNativeManualScrollEnded() {
    }

    private func handleNativeManualScrollRecovered() {
        nativeLyricsManualScrollActive = false
        lyricsService.isManualScrolling = false
        scroll.lockedLineIndex = nil
        scroll.frozenDisplayIndex = nil
        scroll.scrollLocked = false
        scroll.hasTriggeredSlowScroll = false
        updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
        if let idx = displayCurrentLineIndex {
            wave.lastCurrentIndex = idx
        }
        scheduleNextLineAdvanceTimer()
        if isHovering { animateControlsIn() }
    }

    // MARK: - Translation

    // A5 part 1: the host below now keeps ONE TranslationSession alive across
    // songs — `translationTask` only tears the session down when THIS config
    // value actually changes (source/target language pair), never on a plain
    // "please translate now" request. So `updateTranslationSessionConfig`
    // only needs to run when the language pair might have changed; per-song
    // translation requests go straight to `lyricsService.requestTranslation()`
    // (see the `translationRequestTrigger` onChange above), which enqueues
    // onto the live session's request stream instead of rebuilding it.
    private func updateTranslationSessionConfig() {
        if #available(macOS 15.0, *) {
            let generation = translationConfigGeneration
            translationPreflightTask?.cancel()
            // No interim nil: tearing the config down before the preflight
            // resolved restarted the translationTask twice per update.
            DebugLogger.log("LyricsView", "🈺 translation config update gen=\(generation)")
            translationPreflightTask = Task { @MainActor in
                guard currentPage == .lyrics, lyricsService.showTranslation else { return }
                guard let config = await lyricsService.silentSystemTranslationConfiguration() else { return }
                guard !Task.isCancelled, translationConfigGeneration == generation else { return }

                let configChanged = (translationSessionConfigAny as? TranslationSession.Configuration) != config
                if configChanged {
                    // The OLD session's queue must never serve the NEW
                    // session/language — drop anything buffered before the
                    // swap so a stale request can't publish onto the wrong
                    // config's translations.
                    lyricsService.resetTranslationRequestStream()
                }
                translationSessionConfigAny = config
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

    // MARK: - Utilities

    private func isPreludeEllipsis(_ text: String) -> Bool {
        LyricPreludeGlyph.isEllipsis(text)
    }

    // Plan A (2026-09-22, founder-approved; docs/lyrics-ux-contract.md §E,
    // research/long-line-eval-2026-09-22.md): the split trigger is now the
    // RENDERER'S OWN real NSLayoutManager wrap at the CURRENT lyrics column
    // width (`LyricDisplayLineMeasurement`, called through
    // `LyricDisplaySegmenter.realWrapPieces`/`realWrapWordPieces`), not the
    // old unit-based estimate. Prelude/instrumental/background rows are
    // unchanged (never split). Word-level (hasSyllableSync) rows now DO
    // split -- each piece carries its own real `LyricWord`s, so its timing
    // is exact, never estimated. Line-level pieces get proportional (not
    // equal) timing, with short pieces folded into a neighbour. The full
    // translation attaches to the FIRST piece only; later pieces carry none
    // (never chopped mid-sentence to match an unrelated split count).
    // Phase 2 (2026-09-22 founder decision, overrides the interim "translation
    // on the first piece only"): every split piece gets its own translation
    // via LyricPieceTranslation's three tiers -- clause-aligned pairing,
    // then a cached async per-piece on-device translation, then (only while
    // neither of those is available) the full translation on the first
    // piece. `pieceCacheLookup`/`pendingPieceTranslationTexts` thread the
    // tier-2 cache and the async-registration list through the whole
    // function without a per-line allocation of the cache closure.
    private func makeDisplayLyricLines(from lyrics: [LyricLine], rowWidth: CGFloat) -> [DisplayLyricLine] {
        var result: [DisplayLyricLine] = []
        result.reserveCapacity(lyrics.count)

        let pieceSourceCode = lyricsService.resolvedTranslationSourceLanguageCode
        let pieceTargetCode = LyricsService.normalizedSystemTranslationLanguage(lyricsService.translationLanguage)
        let pieceCacheLookup: (String) -> String? = { text in
            guard let pieceSourceCode else { return nil }
            return PieceTranslationCache.shared.translation(for: text, source: pieceSourceCode, target: pieceTargetCode)
        }
        var pendingPieceTranslationTexts: [String] = []

        for (sourceIndex, line) in lyrics.enumerated() {
            if isPreludeEllipsis(line.text) || isInstrumentalNotice(line.text) || line.isBackground {
                result.append(DisplayLyricLine(
                    id: "\(sourceIndex)-0",
                    sourceIndex: sourceIndex,
                    segmentIndex: 0,
                    segmentCount: 1,
                    line: line
                ))
                continue
            }

            if line.hasSyllableSync {
                let wordGroups = LyricDisplaySegmenter.realWrapWordPieces(for: line.words, rowWidth: rowWidth)
                guard !shouldKeepDisplayLineUnsplit(pieceCount: wordGroups.count) else {
                    result.append(DisplayLyricLine(
                        id: "\(sourceIndex)-0",
                        sourceIndex: sourceIndex,
                        segmentIndex: 0,
                        segmentCount: 1,
                        line: line
                    ))
                    continue
                }
                let segmentCount = wordGroups.count
                let groupTexts = wordGroups.map { LyricDisplaySegmenter.displayText(forWords: $0) }
                let (pieceTranslations, pieceTiers) = LyricPieceTranslation.pieceTranslations(
                    originalPieces: groupTexts,
                    fullTranslation: line.translation,
                    cache: pieceCacheLookup
                )
                for (segmentIndex, group) in wordGroups.enumerated() {
                    // Timing error vs. the source data is exactly zero by
                    // construction: start/end come straight from the group's
                    // own real word timestamps, never estimated.
                    let start = group.first?.startTime ?? line.startTime
                    let end = group.last?.endTime ?? line.endTime
                    if pieceTiers[segmentIndex] == .none {
                        pendingPieceTranslationTexts.append(groupTexts[segmentIndex])
                    }
                    let segmentLine = LyricLine(
                        text: groupTexts[segmentIndex],
                        startTime: start,
                        endTime: end,
                        words: group,
                        translation: pieceTranslations[segmentIndex],
                        isBackground: false
                    )
                    result.append(DisplayLyricLine(
                        id: "\(sourceIndex)-\(segmentIndex)",
                        sourceIndex: sourceIndex,
                        segmentIndex: segmentIndex,
                        segmentCount: segmentCount,
                        line: segmentLine
                    ))
                }
                continue
            }

            let textPieces = LyricDisplaySegmenter.realWrapPieces(for: line.text, rowWidth: rowWidth)
            let timedPieces = displayTiming(for: line, textPieces: textPieces, rowWidth: rowWidth)
            guard !shouldKeepDisplayLineUnsplit(pieceCount: timedPieces.count) else {
                result.append(DisplayLyricLine(
                    id: "\(sourceIndex)-0",
                    sourceIndex: sourceIndex,
                    segmentIndex: 0,
                    segmentCount: 1,
                    line: line
                ))
                continue
            }
            let segmentCount = timedPieces.count
            let (pieceTranslations, pieceTiers) = LyricPieceTranslation.pieceTranslations(
                originalPieces: timedPieces.map(\.text),
                fullTranslation: line.translation,
                cache: pieceCacheLookup
            )
            for (segmentIndex, piece) in timedPieces.enumerated() {
                if pieceTiers[segmentIndex] == .none {
                    pendingPieceTranslationTexts.append(piece.text)
                }
                let segmentLine = LyricLine(
                    text: piece.text,
                    startTime: piece.startTime,
                    endTime: piece.endTime,
                    words: [],
                    translation: pieceTranslations[segmentIndex],
                    isBackground: false
                )
                result.append(DisplayLyricLine(
                    id: "\(sourceIndex)-\(segmentIndex)",
                    sourceIndex: sourceIndex,
                    segmentIndex: segmentIndex,
                    segmentCount: segmentCount,
                    line: segmentLine
                ))
            }
        }

        if pieceSourceCode != nil, lyricsService.isSystemTranslationSource, !pendingPieceTranslationTexts.isEmpty {
            lyricsService.registerPendingPieceTranslations(pendingPieceTranslationTexts)
        }

        return result
    }

    /// A line stays a single, unsplit display row whenever the real-wrap /
    /// proportional-timing pipeline above produced only one piece (nothing
    /// needed splitting, or a duration-driven merge collapsed everything
    /// back down to one).
    private func shouldKeepDisplayLineUnsplit(pieceCount: Int) -> Bool {
        pieceCount <= 1
    }

    /// Line-level-only: proportional (character-length-weighted) timing for
    /// `textPieces`, with short-duration pieces folded into a neighbour --
    /// see `LyricDisplaySegmenter.proportionalTiming`. Word-level pieces
    /// never go through this path; their timing comes directly from real
    /// word timestamps in `makeDisplayLyricLines` above.
    private func displayTiming(for line: LyricLine, textPieces: [String], rowWidth: CGFloat) -> [LyricTimedPiece] {
        LyricDisplaySegmenter.proportionalTiming(for: textPieces, lineStart: line.startTime, lineEnd: line.endTime, rowWidth: rowWidth)
    }

    private func displayFirstRealLyricIndex(in displayLines: [DisplayLyricLine]) -> Int {
        displayLines.firstIndex { $0.sourceIndex >= lyricsService.firstRealLyricIndex }
            ?? min(lyricsService.firstRealLyricIndex, max(0, displayLines.count - 1))
    }

    /// Identity the layer-row cache is valid for; compared at body time (see the
    /// stale-rows gate in scrollableLyricsContent).
    static func layerRowsTrackKey(for controller: MusicController) -> String {
        controller.currentTrackTitle + "|" + controller.currentArtist
    }

    private var trackCacheMatchesCurrentTrack: Bool {
        cachedLayerRowsTrackKey == Self.layerRowsTrackKey(for: musicController)
    }

    /// Hash of every input that determines the committed rows. Same inputs ⇒
    /// same rows ⇒ a commit would be a no-op reconcile that still re-pokes the
    /// native surface. LyricLine.id is a fresh UUID per object, so we hash the
    /// content (text + translation) explicitly, never the line identity.
    private func displayLineInputFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(Self.layerRowsTrackKey(for: musicController))
        hasher.combine(lyricsService.showTranslation)
        hasher.combine(lyricsService.firstRealLyricIndex)
        hasher.combine(lyricsService.interludeAfterIndex)
        let lyrics = lyricsService.lyrics
        hasher.combine(lyrics.count)
        for line in lyrics {
            hasher.combine(line.text)
            hasher.combine(line.translation)
        }
        return hasher.finalize()
    }

    /// Evidence log (2026-09-22, research/diagnosis-2026-09-22-blank-lyrics-page.md):
    /// the stale-rows gate at the `cacheIsCurrentTrack` call site is exactly
    /// where a "torn identity" episode is visible from the UI side. This is a
    /// plain function call (not a bare `if` in the @ViewBuilder body, which
    /// would be swept into `buildIf`/`buildEither` and need to return a View),
    /// so it runs as an ordinary side-effecting statement on every body pass.
    /// The condition itself is a cheap Date/String comparison (no I/O); the
    /// actual DebugLogger call and the state write are deferred one runloop
    /// tick (avoids "modifying state during view update") and throttled to at
    /// most once per 3s via `staleCacheGateEvidenceLoggedAt` — never per-frame
    /// I/O even if body re-evaluates often.
    private func logStaleCacheGateEvidenceIfNeeded(cacheIsCurrentTrack: Bool) {
        guard !cacheIsCurrentTrack, lyricsService.lyrics.isEmpty,
              Date().timeIntervalSince(staleCacheGateEvidenceLoggedAt) > 3.0 else { return }
        let staleKey = cachedLayerRowsTrackKey
        let currentKey = Self.layerRowsTrackKey(for: musicController)
        let rowCount = lyricsService.lyrics.count
        let state = lyricsService.displayState
        DispatchQueue.main.async {
            staleCacheGateEvidenceLoggedAt = Date()
            DebugLogger.log("LyricsView", "⚠️ Stale layer-rows cache gate open >3s: cachedLayerRowsTrackKey='\(staleKey)' currentKey='\(currentKey)' rows=\(rowCount) displayState=\(state)")
        }
    }

    /// - Parameter forceRebuild: bypasses the dedup guard below. Used ONLY by
    ///   `updateLyricsSegmentationWidthIfNeeded` (Plan A, 2026-09-22): a width
    ///   change alone must be able to rebuild the split even though
    ///   `lyrics`/`showTranslation`/etc. (the fingerprint's other inputs)
    ///   haven't changed. Every other call site passes `false` (default) and
    ///   keeps today's dedup behavior unchanged.
    private func refreshDisplayLineCache(forceRebuild: Bool = false) {
        // ---- Dedup guard ----------------------------------------------------
        // The staged load fires onChange(lyrics) AND onChange(displayState),
        // each calling here; the stage log showed the same logical state
        // committed 2-3x (byte-identical, 1-4ms apart). A redundant commit
        // re-pokes the native surface for no reason = a visible "refresh".
        // Bail when the inputs that determine the rows are unchanged.
        let inputFingerprint = displayLineInputFingerprint()
        guard forceRebuild || inputFingerprint != lastCommittedRowsFingerprint else { return }
        lastCommittedRowsFingerprint = inputFingerprint

        let displayLines = makeDisplayLyricLines(from: lyricsService.lyrics, rowWidth: cache.segmentationRowWidth)
        let firstRealDisplayIndex = displayFirstRealLyricIndex(in: displayLines)
        cachedDisplayLines = displayLines
        cachedDisplayLyrics = displayLines.map(\.line)
        cachedFirstRealDisplayIndex = firstRealDisplayIndex
        let layerRows = makeLayerBackedRows(from: displayLines).filter { row in
            row.index == 0 || row.index >= firstRealDisplayIndex
        }
        cachedLayerRows = layerRows
        cachedLayerRowsTrackKey = Self.layerRowsTrackKey(for: musicController)
        // The new track's state is ready (even if it's just the loading/empty layout): reveal the
        // content container with the "向下生长" intro — fade in while settling down from the upward
        // offset. A gentle spring gives the organic "grow/descend" feel (tunable). Both properties
        // animate in the same transaction so the drop and fade stay in sync.
        if contentTransitionOpacity < 1 || contentTransitionOffset != 0 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                contentTransitionOpacity = 1
                contentTransitionOffset = 0
            }
        }
        cachedNativeRenderedIndices = layerRows.map(\.index)
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

    private func cancelLineAdvanceTimer() {
        lineAdvanceTimer?.invalidate()
        lineAdvanceTimer = nil
        lineAdvanceTimerTargetPlaybackTime = nil
    }

    private func scheduleNextLineAdvanceTimer() {
        guard currentPage == .lyrics,
              musicController.isPlaying,
              !isAnyLyricsManualScrolling,
              !cachedDisplayLyrics.isEmpty else {
            cancelLineAdvanceTimer()
            return
        }

        let now = Date()
        let playbackTime = musicController.lyricRenderTime(at: now)
        let currentIndex = LyricMotionSamplingPolicy.activeIndex(
            at: playbackTime,
            lyrics: cachedDisplayLyrics,
            firstRealIndex: cachedFirstRealDisplayIndex
        ) ?? cachedFirstRealDisplayIndex
        let searchStartIndex = min(max(currentIndex + 1, cachedFirstRealDisplayIndex), cachedDisplayLyrics.count)
        guard searchStartIndex < cachedDisplayLyrics.count else {
            cancelLineAdvanceTimer()
            return
        }

        guard let nextStartIndex = cachedDisplayLyrics[searchStartIndex...].firstIndex(where: {
            $0.startTime > playbackTime + 0.006
        }) else {
            cancelLineAdvanceTimer()
            return
        }
        let nextLine = cachedDisplayLyrics[nextStartIndex]

        if LyricLineAdvanceTiming.shouldReuseScheduledTimer(
            existingTarget: lineAdvanceTimerTargetPlaybackTime,
            nextTarget: nextLine.startTime,
            timerActive: lineAdvanceTimer != nil
        ) {
            return
        }

        cancelLineAdvanceTimer()
        let delay = max(0.006, nextLine.startTime - playbackTime)
        let timer = Timer(timeInterval: delay, repeats: false) { [self] _ in
            lineAdvanceTimer = nil
            lineAdvanceTimerTargetPlaybackTime = nil
            guard currentPage == .lyrics else { return }
            updateDisplayCurrentLineIndex(at: musicController.lyricRenderTime())
            scheduleNextLineAdvanceTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        lineAdvanceTimer = timer
        lineAdvanceTimerTargetPlaybackTime = nextLine.startTime
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
        if let newIndex, !scroll.isManualScrolling, !lyricsLayerRendererActive {
            seedWaveTargetsForLineAdvance(from: oldIndex, to: newIndex)
        }
        displayCurrentLineIndex = newIndex
        guard let newIndex, !scroll.isManualScrolling else { return }
        if !lyricsLayerRendererActive {
            triggerWaveAnimation(from: oldIndex, to: newIndex)
        }
        wave.lastCurrentIndex = newIndex
        startLineMotionSamplingWindow(duration: lyricLineMotionLineAdvanceSampleDuration)
    }

    private func seedWaveTargetsForLineAdvance(from oldIndex: Int, to newIndex: Int) {
        let targetRadius = LyricWaveTiming.targetRadius(
            lineInterval: nil,
            hasSyllableSync: cachedDisplayLyrics.indices.contains(newIndex) && cachedDisplayLyrics[newIndex].hasSyllableSync
        )
        let indices = LyricWaveTiming.targetIndices(
            renderedIndices: renderedIndices,
            oldIndex: oldIndex,
            newIndex: newIndex,
            radius: targetRadius,
            existingTargetIndices: wave.lineTargetIndices.keys
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            wave.lineTargetIndices = LyricWaveTiming.seededTargetsForNaturalAdvance(
                existingTargets: wave.lineTargetIndices,
                indices: indices,
                oldIndex: oldIndex
            )
        }
    }

    // MARK: - Scroll Bounds And Rubber Banding

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

    // MARK: - Height Calculation And Cache

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
        let interludeGap: CGFloat = NativeLyricsHeightAccumulator.interludeGapHeight
        let interludeIdx = lyricsService.interludeAfterIndex
        var totalHeight: CGFloat = 0
        let indices = renderedIndices
        guard let targetPosition = indices.firstIndex(of: targetIndex) else { return 0 }
        if cache.lineHeights.isEmpty {
            return CGFloat(targetPosition) * (defaultHeight + spacing)
        }
        for i in 0..<targetPosition {
            totalHeight += (cache.lineHeights[indices[i]] ?? defaultHeight) + spacing
            if indices[i] == interludeIdx {
                totalHeight += interludeGap
            }
        }
        return totalHeight
    }

    private func updateLyricsContainerHeight(_ height: CGFloat) {
        if cache.lyricsContainerHeight != height {
            DispatchQueue.main.async { cache.lyricsContainerHeight = height }
        }
    }

    /// Plan A (2026-09-22): the split trigger now needs the real lyrics
    /// column width. The FIRST width this view instance observes applies
    /// immediately (no debounce -- there is nothing to coalesce yet, and
    /// delaying it would make every fresh song render unsplit-then-reflow).
    /// Any width CHANGE after that (a live window resize) is debounced via a
    /// generation counter (same pattern as `scheduleTranslationSessionConfigUpdate`)
    /// so a resize drag rebuilds display lines once it settles, not once per
    /// frame of the drag.
    private func updateLyricsSegmentationWidthIfNeeded(_ width: CGFloat) {
        guard width > 1 else { return }
        let rounded = width.rounded(.toNearestOrAwayFromZero)
        guard abs(rounded - cache.segmentationRowWidth) > 0.5 else { return }

        guard hasEstablishedSegmentationWidth else {
            DispatchQueue.main.async {
                hasEstablishedSegmentationWidth = true
                cache.segmentationRowWidth = rounded
                refreshDisplayLineCache(forceRebuild: true)
            }
            return
        }

        lyricsSegmentationWidthGeneration += 1
        let generation = lyricsSegmentationWidthGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + lyricsSegmentationWidthDebounceDuration) {
            guard lyricsSegmentationWidthGeneration == generation else { return } // superseded mid-debounce
            guard abs(rounded - cache.segmentationRowWidth) > 0.5 else { return } // already applied
            cache.segmentationRowWidth = rounded
            refreshDisplayLineCache(forceRebuild: true)
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

    /// Called from body entry to keep the height cache valid and avoid O(N²) row rescans.
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

    private func primeNativeRowHeightsIfNeeded(
        rowWidth: CGFloat,
        rows: [LayerBackedLyricRow],
        pendingTranslationLineIndices: Set<Int>
    ) {
        guard LyricsRendererMode.current == .native else { return }
        guard rowWidth > 1, !rows.isEmpty else { return }
        let roundedWidth = rowWidth.rounded(.toNearestOrAwayFromZero)
        let widthChanged = abs(cache.nativeEstimatedRowWidth - roundedWidth) > 0.5
        let needsPriming = widthChanged
            || cache.heightCacheInvalidated
            || rows.contains { cache.lineHeights[$0.index] == nil }
        guard needsPriming, !nativeHeightPrimingScheduled else { return }

        nativeHeightPrimingScheduled = true
        let showTranslation = lyricsService.showTranslation
        let isTranslating = lyricsService.isTranslating
        DispatchQueue.main.async {
            nativeHeightPrimingScheduled = false
            guard currentPage == .lyrics else { return }
            var changed = false
            cache.nativeEstimatedRowWidth = roundedWidth
            for row in rows {
                let estimated = NativeLyricsRowMeasurement.estimatedHeight(
                    for: row,
                    rowWidth: roundedWidth,
                    showTranslation: showTranslation,
                    isTranslating: isTranslating,
                    pendingTranslationLineIndices: pendingTranslationLineIndices
                )
                if abs((cache.lineHeights[row.index] ?? 0) - estimated) > 2.0 {
                    cache.lineHeights[row.index] = estimated
                    changed = true
                }
            }
            if changed {
                cache.heightCacheInvalidated = true
                updateHeightCache()
            }
        }
    }

    // MARK: - AMLL Wave Animation (Calculation-Driven)

    /// Legacy SwiftUI fallback wave: each row receives the new target at a staggered wall-clock time.
    /// The native renderer translates the same timing law into its frame-driven presentation engine.
    private func triggerWaveAnimation(from oldIndex: Int, to newIndex: Int) {
        guard !scroll.isManualScrolling else { return }
        let lyrics = cachedDisplayLyrics
        guard !lyrics.isEmpty else { return }

        let existingTargetIndices = wave.lineTargetIndices.keys
        for item in wave.workItems { item.cancel() }
        wave.workItems.removeAll()
        flushPendingLyricWaveTimelineSamples(deferred: true)

        let lineInterval = estimatedLineInterval(around: newIndex, in: lyrics)
        let hasSyllableSync = lyrics.indices.contains(newIndex) && lyrics[newIndex].hasSyllableSync
        let targetRadius = LyricWaveTiming.targetRadius(
            lineInterval: lineInterval,
            hasSyllableSync: hasSyllableSync
        )
        let indices = LyricWaveTiming.targetIndices(
            renderedIndices: renderedIndices,
            oldIndex: oldIndex,
            newIndex: newIndex,
            radius: targetRadius,
            existingTargetIndices: existingTargetIndices
        )
        guard !indices.isEmpty else { return }

        // Natural lyric advancement must not take the direct-scroll path. User
        // seeks and manual-scroll returns already seed targets outside this
        // function; this path is reserved for the protected top-to-bottom wave.
        if reduceMotion {
            let updateTargets = {
                for idx in indices { wave.lineTargetIndices[idx] = newIndex }
                wave.lineTargetIndices = wave.lineTargetIndices.filter { key, _ in
                    abs(key - newIndex) <= max(targetRadius, 12)
                }
            }
            var jumpTransaction = Transaction()
            jumpTransaction.disablesAnimations = true
            withTransaction(jumpTransaction, updateTargets)
            return
        }

        let schedule = LyricWaveTiming.staggerSchedule(
            for: indices,
            newIndex: newIndex,
            lineInterval: lineInterval
        )
        wave.sequence += 1
        let waveID = wave.sequence
        let scheduledAt = Date()
        let track = musicController.diagnosticsTrackContext()
        let renderedCount = renderedIndices.count

        if lyricWaveTimelineDiagnosticsEnabledSnapshot {
            wave.pendingTimelineSamples = schedule.map { target in
                DiagnosticLyricWaveTimelineSample(
                    timestamp: scheduledAt,
                    page: "lyrics",
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    waveID: waveID,
                    phase: "scheduled",
                    lineIndex: target.lineIndex,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    displayIndex: newIndex,
                    scheduledDelay: target.delay,
                    actualDelay: 0,
                    lineInterval: lineInterval,
                    targetRadius: targetRadius,
                    scheduleCount: schedule.count,
                    renderedCount: renderedCount,
                    isActiveLine: target.lineIndex == newIndex
                )
            }
        }

        var finalScheduledDelay: TimeInterval = 0
        for target in schedule {
            let lineIndex = target.lineIndex
            finalScheduledDelay = target.delay

            if target.delay < 0.01 {
                wave.lineTargetIndices[lineIndex] = newIndex
                if lyricWaveTimelineDiagnosticsEnabledSnapshot {
                    let firedAt = Date()
                    wave.pendingTimelineSamples.append(DiagnosticLyricWaveTimelineSample(
                        timestamp: firedAt,
                        page: "lyrics",
                        trackTitle: track.title,
                        trackArtist: track.artist,
                        waveID: waveID,
                        phase: "fired",
                        lineIndex: lineIndex,
                        oldIndex: oldIndex,
                        newIndex: newIndex,
                        displayIndex: newIndex,
                        scheduledDelay: target.delay,
                        actualDelay: firedAt.timeIntervalSince(scheduledAt),
                        lineInterval: lineInterval,
                        targetRadius: targetRadius,
                        scheduleCount: schedule.count,
                        renderedCount: renderedCount,
                        isActiveLine: lineIndex == newIndex
                    ))
                }
            } else {
                let scheduledDelay = target.delay
                let workItem = DispatchWorkItem { [self] in
                    guard !scroll.isManualScrolling else { return }
                    wave.lineTargetIndices[lineIndex] = newIndex
                    if lyricWaveTimelineDiagnosticsEnabledSnapshot {
                        let firedAt = Date()
                        wave.pendingTimelineSamples.append(DiagnosticLyricWaveTimelineSample(
                            timestamp: firedAt,
                            page: "lyrics",
                            trackTitle: track.title,
                            trackArtist: track.artist,
                            waveID: waveID,
                            phase: "fired",
                            lineIndex: lineIndex,
                            oldIndex: oldIndex,
                            newIndex: newIndex,
                            displayIndex: newIndex,
                            scheduledDelay: scheduledDelay,
                            actualDelay: firedAt.timeIntervalSince(scheduledAt),
                            lineInterval: lineInterval,
                            targetRadius: targetRadius,
                            scheduleCount: schedule.count,
                            renderedCount: renderedCount,
                            isActiveLine: lineIndex == newIndex
                        ))
                    }
                }
                wave.workItems.append(workItem)
                DispatchQueue.main.asyncAfter(deadline: .now() + scheduledDelay, execute: workItem)
            }
        }

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
            flushPendingLyricWaveTimelineSamples(deferred: false)
        }
        wave.workItems.append(settleWorkItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + finalScheduledDelay + LyricWaveTiming.settlePadding, execute: settleWorkItem)
    }

    private func flushPendingLyricWaveTimelineSamples(deferred: Bool) {
        guard lyricWaveTimelineDiagnosticsEnabledSnapshot, !wave.pendingTimelineSamples.isEmpty else {
            wave.pendingTimelineSamples.removeAll()
            return
        }

        let samples = wave.pendingTimelineSamples
        wave.pendingTimelineSamples.removeAll()
        if deferred {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                diagnostics.recordLyricsWaveTimelineSamples(samples)
            }
        } else {
            diagnostics.recordLyricsWaveTimelineSamples(samples)
        }
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
        flushPendingLyricWaveTimelineSamples(deferred: true)
    }
}

// MARK: - Preview

// MARK: - TranslationTaskHostView (macOS 15.0+)
// Zero-size INVISIBLE host for the system translation session. It must never
// wrap visible content — that was true before A5 too. A5 part 1 removes the
// `.id(trigger)` that used to sit here: recreating this host's identity on
// EVERY requested translation pass tore down the TranslationSession (and
// paid the framework's model warm-up) per request, not per language change.
// Now `translationTask` reacts only to `activeConfig` (the source/target
// language pair) changing; the action closure starts one long-lived loop
// (`serveTranslationRequests`) that keeps consuming "please translate now"
// signals for as long as the session stays valid, so the SECOND song in the
// same language reuses the already-warmed session.

struct TranslationTaskHostView: View {
    var translationSessionConfigAny: Any?
    let lyricsService: LyricsService

    var body: some View {
        if #available(macOS 15.0, *) {
            TranslationTaskHostCore(
                configAny: translationSessionConfigAny,
                lyricsService: lyricsService
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationTaskHostCore: View {
    let configAny: Any?
    let lyricsService: LyricsService

    var body: some View {
        // Each session gets its OWN zero-size host view. 2026-09-20 regression: stacking a second
        // `.translationTask` on the same `Color.clear` (the explicit-ko session) left the primary
        // auto-detect loop never starting — translate button pressed, no "Starting translation"
        // ever logged. One translationTask per view; siblings in a ZStack.
        ZStack {
            Color.clear
                .translationTask(activeConfig, action: { session in
                    // No outer showTranslation/lyrics gate here: this closure
                    // only restarts when `activeConfig` (the language pair)
                    // changes, so a one-time gate evaluated at start would stay
                    // stuck if the user toggles showTranslation off then back on
                    // without the language changing — serveTranslationRequests
                    // must loop unconditionally; performSystemTranslation
                    // re-checks showTranslation/lyrics on every request already.
                    await lyricsService.serveTranslationRequests(with: session)
                })
            // Second, invisible session with an EXPLICIT Korean source —
            // script-determined (ScriptRunSegmenter classifies Hangul), not
            // NLLanguageRecognizer-guessed. Used only for Hangul runs inside
            // mixed-script lines; this task just warms/holds the session and
            // hands it to LyricsService.koreanRunTranslationExecutor.
            Color.clear
                .translationTask(koreanRunConfig, action: { session in
                    await lyricsService.updateKoreanRunTranslationExecutor(session)
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                    }
                    await lyricsService.updateKoreanRunTranslationExecutor(nil)
                })
        }
    }

    private var activeConfig: TranslationSession.Configuration {
        if let config = configAny as? TranslationSession.Configuration {
            return config
        }
        // Transient bootstrap value before the first real per-song source
        // resolves (`LyricsService.silentSystemTranslationConfiguration`,
        // 2026-09-22 fix) — `.translationTask` needs SOME non-nil value to
        // bind to immediately, but `serveTranslationRequests` never actually
        // translates through it (showTranslation/lyrics gates in
        // `performSystemTranslation` hold off until real content + a real
        // config are ready, and `updateTranslationSessionConfig` swaps this
        // out for the resolved config within one run-loop turn). Every
        // `TranslationSession.Configuration` in the app must carry an
        // explicit, non-nil `source` — never `source: nil`, which is what
        // re-introduces the system language-picker popup — so this
        // placeholder gets one too, even though it is essentially never live.
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        )
    }

    private var koreanRunConfig: TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: Locale.Language(identifier: "ko"),
            target: activeConfig.target
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
