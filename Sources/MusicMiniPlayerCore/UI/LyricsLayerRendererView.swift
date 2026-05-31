import AppKit
import CoreImage
import CoreVideo
import QuartzCore
import SwiftUI

private let nativeLyricContentLeadingInset: CGFloat = 32
private let nativeLyricContentTrailingInset: CGFloat = 20

struct NativeLyricsSurface: NSViewRepresentable {
    let rows: [LayerBackedLyricRow]
    let currentIndex: Int
    let anchorY: CGFloat
    let rowWidth: CGFloat
    let renderedIndices: [Int]
    let accumulatedHeights: [Int: CGFloat]
    let lineTargetIndices: [Int: Int]
    let lineInterval: TimeInterval?
    let hasSyllableSync: Bool
    let trackContext: DiagnosticTrackContext
    let isWaveTimelineDiagnosticsEnabled: Bool
    let isManualScrolling: Bool
    let reduceMotion: Bool
    let suppressInitialMotion: Bool
    let pendingTranslationLineIndices: Set<Int>
    let showTranslation: Bool
    let isTranslating: Bool
    let translationFailed: Bool
    let interludeAfterIndex: Int?
    let directSnapRequest: NativeLyricsDirectSnapRequest?
    let controlsVisible: Bool
    let musicController: MusicController
    let onLineTap: (LyricLine) -> Void
    let onDirectSnapConsumed: (UUID) -> Void
    let onManualScrollStarted: (Int) -> Void
    let onManualScrollDelta: (CGFloat, CGFloat) -> Void
    let onManualScrollEnded: () -> Void
    let onManualScrollRecovered: () -> Void
    let onHeightMeasured: (Int, CGFloat) -> Void
    let lineMotionFrameCaptureActive: Bool
    let lineMotionFrameCaptureSequence: Int
    let lineMotionSamplingEnabled: Bool
    let lineMotionFocusedSamplingUntil: Date
    let lineMotionFirstRealDisplayIndex: Int
    let onLineMotionFrames: ([Int: CGRect], NativeLyricsPresentationSnapshot, Date?, TimeInterval?) -> Void

    func makeNSView(context: Context) -> NativeLyricsSurfaceView {
        NativeLyricsSurfaceView()
    }

    func updateNSView(_ nsView: NativeLyricsSurfaceView, context: Context) {
        nsView.configure(
            LyricsLayerRendererConfiguration(
                rows: rows,
                currentIndex: currentIndex,
                anchorY: anchorY,
                rowWidth: max(1, rowWidth),
                renderedIndices: renderedIndices,
                accumulatedHeights: accumulatedHeights,
                lineTargetIndices: lineTargetIndices,
                lineInterval: lineInterval,
                hasSyllableSync: hasSyllableSync,
                trackContext: trackContext,
                isWaveTimelineDiagnosticsEnabled: isWaveTimelineDiagnosticsEnabled,
                isManualScrolling: isManualScrolling,
                reduceMotion: reduceMotion,
                suppressInitialMotion: suppressInitialMotion,
                pendingTranslationLineIndices: pendingTranslationLineIndices,
                showTranslation: showTranslation,
                isTranslating: isTranslating,
                translationFailed: translationFailed,
                interludeAfterIndex: interludeAfterIndex,
                directSnapRequest: directSnapRequest,
                controlsVisible: controlsVisible,
                musicController: musicController,
                onLineTap: onLineTap,
                onDirectSnapConsumed: onDirectSnapConsumed,
                onManualScrollStarted: onManualScrollStarted,
                onManualScrollDelta: onManualScrollDelta,
                onManualScrollEnded: onManualScrollEnded,
                onManualScrollRecovered: onManualScrollRecovered,
                onHeightMeasured: onHeightMeasured,
                lineMotionFrameCaptureActive: lineMotionFrameCaptureActive,
                lineMotionFrameCaptureSequence: lineMotionFrameCaptureSequence,
                lineMotionSamplingEnabled: lineMotionSamplingEnabled,
                lineMotionFocusedSamplingUntil: lineMotionFocusedSamplingUntil,
                lineMotionFirstRealDisplayIndex: lineMotionFirstRealDisplayIndex,
                onLineMotionFrames: onLineMotionFrames
            )
        )
    }

    static func dismantleNSView(_ nsView: NativeLyricsSurfaceView, coordinator: ()) {
        nsView.stopAnimations()
    }
}

struct LyricsLayerRendererConfiguration {
    let rows: [LayerBackedLyricRow]
    let currentIndex: Int
    let anchorY: CGFloat
    let rowWidth: CGFloat
    let renderedIndices: [Int]
    let accumulatedHeights: [Int: CGFloat]
    let lineTargetIndices: [Int: Int]
    let lineInterval: TimeInterval?
    let hasSyllableSync: Bool
    let trackContext: DiagnosticTrackContext
    let isWaveTimelineDiagnosticsEnabled: Bool
    let isManualScrolling: Bool
    let reduceMotion: Bool
    let suppressInitialMotion: Bool
    let pendingTranslationLineIndices: Set<Int>
    let showTranslation: Bool
    let isTranslating: Bool
    let translationFailed: Bool
    let interludeAfterIndex: Int?
    let directSnapRequest: NativeLyricsDirectSnapRequest?
    let controlsVisible: Bool
    let musicController: MusicController
    let onLineTap: (LyricLine) -> Void
    let onDirectSnapConsumed: (UUID) -> Void
    let onManualScrollStarted: (Int) -> Void
    let onManualScrollDelta: (CGFloat, CGFloat) -> Void
    let onManualScrollEnded: () -> Void
    let onManualScrollRecovered: () -> Void
    let onHeightMeasured: (Int, CGFloat) -> Void
    let lineMotionFrameCaptureActive: Bool
    let lineMotionFrameCaptureSequence: Int
    let lineMotionSamplingEnabled: Bool
    let lineMotionFocusedSamplingUntil: Date
    let lineMotionFirstRealDisplayIndex: Int
    let onLineMotionFrames: ([Int: CGRect], NativeLyricsPresentationSnapshot, Date?, TimeInterval?) -> Void
    var nativeManualScrollSnapshot: NativeLyricsManualScrollSnapshot? = nil
    var nativeDirectSnapIndex: Int? = nil
    var nativeDirectSnapReason: LyricsPresentationDirectSnapReason? = nil
    var nativeSemanticCurrentIndex: Int? = nil

    var effectiveCurrentIndex: Int {
        nativeDirectSnapIndex
            ?? nativeManualScrollSnapshot?.frozenDisplayIndex
            ?? nativeSemanticCurrentIndex
            ?? currentIndex
    }

    var effectiveManualOffset: CGFloat {
        nativeManualScrollSnapshot?.manualOffset ?? 0
    }

    var effectiveIsManualScrolling: Bool {
        nativeManualScrollSnapshot?.isActive == true || isManualScrolling
    }

    var playbackMode: LyricsPresentationPlaybackMode {
        if let nativeDirectSnapReason { return .directSnap(nativeDirectSnapReason) }
        if reduceMotion { return .directSnap(.reducedMotion) }
        if effectiveIsManualScrolling { return .directSnap(.manualScroll) }
        if suppressInitialMotion { return .directSnap(.initialLayout) }
        return .natural
    }
}

@MainActor
final class NativeLyricsSurfaceView: NSView {
    override var isFlipped: Bool { true }

    private var configuration: LyricsLayerRendererConfiguration?
    private let presentationEngine = LyricsPresentationEngine()
    private var rowViews: [String: NativeLyricsRowView] = [:]
    private var rowIDByIndex: [Int: String] = [:]
    private var rowRenderKeys: [String: RowRenderKey] = [:]
    private var visualParitySignatures: [String: VisualParitySignature] = [:]
    private var rowTapHandlers: [Int: () -> Void] = [:]
    private var measuredHeightsByIndex: [Int: CGFloat] = [:]
    private var displayLink: CVDisplayLink?
    private var lastPresentationTick: CFTimeInterval?
    private var frameSummaryStartedAt: CFTimeInterval?
    private var frameCadence = NativeLyricsFrameCadenceAccumulator()
    private var renderTelemetry = NativeLyricsRenderTelemetryAccumulator()
    private var manualScrollState = NativeLyricsManualScrollState()
    private var manualScrollEndTimer: Timer?
    private var manualScrollRecoveryTimer: Timer?
    private var nativeLineAdvanceTimer: Timer?
    private var nativeLineAdvanceTimerTargetPlaybackTime: TimeInterval?
    private var nativeLineMotionSamplingTimer: Timer?
    private var lastNativeLineMotionSampleAt: Date = .distantPast
    private var nativeSemanticCurrentIndex: Int?
    private var lastScrollWheelTime: CFTimeInterval = 0
    private var hoveredRowIndex: Int?
    private var lastConfigureEventSignature: String?
    private var consumedDirectSnapRequestIDs: Set<UUID> = []
    private var lastReportedLineMotionCaptureSequence: Int = -1
    private var lastConfiguredTextPhaseIndex: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    func configure(_ configuration: LyricsLayerRendererConfiguration) {
        if let previous = self.configuration?.trackContext,
           !Self.isSameTrackIdentity(previous, configuration.trackContext) {
            cancelManualScrollTimers()
            cancelNativeLineAdvanceTimer()
            manualScrollState.reset()
            nativeSemanticCurrentIndex = nil
        }
        self.configuration = configuration
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        updateNativeLineMotionSamplingTimer(configuration: runtimeConfiguration)
        consumeDirectSnapRequestIfNeeded(runtimeConfiguration)
        recordConfigureEventIfNeeded(configuration: runtimeConfiguration)
        presentationEngine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: runtimeConfiguration.effectiveCurrentIndex,
                renderedIndices: runtimeConfiguration.renderedIndices,
                anchorY: runtimeConfiguration.anchorY,
                accumulatedHeights: runtimeConfiguration.accumulatedHeights,
                lineInterval: runtimeConfiguration.lineInterval,
                hasSyllableSync: runtimeConfiguration.hasSyllableSync,
                trackContext: runtimeConfiguration.trackContext,
                isWaveTimelineDiagnosticsEnabled: runtimeConfiguration.isWaveTimelineDiagnosticsEnabled
                    || DiagnosticsService.shared.isLyricWaveTimelineEnabled,
                playbackMode: runtimeConfiguration.playbackMode
            ),
            onTargetsChanged: { [weak self] in
                self?.startPresentationLoop()
            }
        )

        let visibleRows = visibleRows(for: runtimeConfiguration)
        let nextIDs = Set(visibleRows.map(\.id))
        var unmountedCount = 0
        for (id, view) in rowViews where !nextIDs.contains(id) {
            view.layer?.removeAllAnimations()
            view.removeFromSuperview()
            rowViews[id] = nil
            rowRenderKeys[id] = nil
            visualParitySignatures[id] = nil
            measuredHeightsByIndex.removeValue(forKey: view.displayIndex)
            unmountedCount += 1
        }
        rowIDByIndex = Dictionary(uniqueKeysWithValues: visibleRows.map { ($0.index, $0.id) })
        rowTapHandlers = rowTapHandlers.filter { rowIndex, _ in
            visibleRows.contains { $0.index == rowIndex }
        }

        let shouldSnap = runtimeConfiguration.playbackMode != .natural
        let previousTextPhaseIndex = lastConfiguredTextPhaseIndex
        let activeTextPhaseIndex = runtimeConfiguration.effectiveCurrentIndex
        let textPhaseIndexChanged = previousTextPhaseIndex != activeTextPhaseIndex
        var mountedCount = 0
        withDisabledLayerActions {
            for row in visibleRows {
                let view = rowViews[row.id] ?? NativeLyricsRowView()
                if rowViews[row.id] == nil {
                    rowViews[row.id] = view
                    addSubview(view)
                    mountedCount += 1
                }
                view.onHoverChanged = { [weak self] hovering in
                    self?.renderTelemetry.recordHover(hovering: hovering)
                }
                view.onHoverBackgroundVisible = { [weak self] in
                    self?.renderTelemetry.recordHoverBackgroundVisible()
                }
                let tapHandler: () -> Void = { [weak self] in
                    self?.handleNativeLineTap(rowIndex: row.index, line: row.displayLine.line)
                }
                view.onTap = tapHandler
                rowTapHandlers[row.index] = tapHandler
                let contentUpdated = updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
                let needsActivationRefresh = textPhaseIndexChanged
                    && (row.index == activeTextPhaseIndex || row.index == previousTextPhaseIndex)
                if needsActivationRefresh && !contentUpdated {
                    view.configure(row: row, configuration: runtimeConfiguration)
                } else if row.index == activeTextPhaseIndex,
                          !contentUpdated,
                          let textSample = view.updatePlaybackPhase(configuration: runtimeConfiguration) {
                    renderTelemetry.recordTextPhase(textSample)
                }
                applyFrame(for: row, view: view, configuration: runtimeConfiguration, snap: shouldSnap)
            }
        }
        lastConfiguredTextPhaseIndex = activeTextPhaseIndex
        renderTelemetry.recordLifecycle(
            mounted: mountedCount,
            unmounted: unmountedCount,
            mountedRows: rowViews.count,
            renderedRows: visibleRows.count
        )

        if shouldSnap {
            if hasActiveTextAnimation(configuration: runtimeConfiguration) {
                startPresentationLoop()
            } else {
                stopPresentationLoopIfIdle()
            }
        } else if presentationEngine.hasActiveMotion || hasActiveTextAnimation(configuration: runtimeConfiguration) {
            startPresentationLoop()
        }

        reportPendingLineMotionFramesIfNeeded(configuration: runtimeConfiguration)
        scheduleNativeLineAdvanceTimerIfNeeded(configuration: runtimeConfiguration)
    }

    private func runtimeConfiguration(
        from configuration: LyricsLayerRendererConfiguration
    ) -> LyricsLayerRendererConfiguration {
        var runtimeConfiguration = configuration
        runtimeConfiguration.nativeManualScrollSnapshot = manualScrollState.activeSnapshot
        if let request = configuration.directSnapRequest,
           !consumedDirectSnapRequestIDs.contains(request.id) {
            runtimeConfiguration.nativeDirectSnapIndex = request.displayIndex
            runtimeConfiguration.nativeDirectSnapReason = request.reason
        }
        synchronizeNativeSemanticIndex(configuration: &runtimeConfiguration)
        return runtimeConfiguration
    }

    private func synchronizeNativeSemanticIndex(
        configuration: inout LyricsLayerRendererConfiguration
    ) {
        guard configuration.playbackMode == .natural else {
            nativeSemanticCurrentIndex = configuration.effectiveCurrentIndex
            configuration.nativeSemanticCurrentIndex = nativeSemanticCurrentIndex
            cancelNativeLineAdvanceTimer()
            return
        }
        let playbackTime = configuration.musicController.lyricRenderTime()
        let liveIndex = NativeLyricsTimelinePolicy.liveDisplayIndex(
            at: playbackTime,
            rows: configuration.rows,
            fallback: configuration.currentIndex
        )
        if let current = nativeSemanticCurrentIndex,
           current != liveIndex,
           abs(liveIndex - current) > 1 {
            presentationEngine.update(
                LyricsPresentationEngineConfiguration(
                    currentIndex: liveIndex,
                    renderedIndices: configuration.renderedIndices,
                    anchorY: configuration.anchorY,
                    accumulatedHeights: configuration.accumulatedHeights,
                    lineInterval: lineInterval(around: liveIndex, rows: configuration.rows),
                    hasSyllableSync: configuration.rows.first(where: { $0.index == liveIndex })?.displayLine.line.hasSyllableSync ?? configuration.hasSyllableSync,
                    trackContext: configuration.trackContext,
                    isWaveTimelineDiagnosticsEnabled: configuration.isWaveTimelineDiagnosticsEnabled || DiagnosticsService.shared.isLyricWaveTimelineEnabled,
                    playbackMode: .directSnap(.seek)
                ),
                onTargetsChanged: { [weak self] in
                    self?.startPresentationLoop()
                }
            )
        }
        nativeSemanticCurrentIndex = liveIndex
        configuration.nativeSemanticCurrentIndex = liveIndex
    }

    private func consumeDirectSnapRequestIfNeeded(_ configuration: LyricsLayerRendererConfiguration) {
        guard let request = configuration.directSnapRequest,
              configuration.nativeDirectSnapIndex == request.displayIndex,
              !consumedDirectSnapRequestIDs.contains(request.id) else {
            return
        }
        consumedDirectSnapRequestIDs.insert(request.id)
        DispatchQueue.main.async {
            configuration.onDirectSnapConsumed(request.id)
        }
    }

    private func recordConfigureEventIfNeeded(configuration: LyricsLayerRendererConfiguration) {
        guard DiagnosticsService.shared.isEnabled else { return }
        let signature = [
            configuration.trackContext.title,
            configuration.trackContext.artist,
            "\(configuration.rows.count)",
            "\(configuration.renderedIndices.count)"
        ].joined(separator: "|")
        guard signature != lastConfigureEventSignature else { return }
        lastConfigureEventSignature = signature
        DiagnosticsService.shared.recordEvent(
            "lyrics.nativeRenderer.configure",
            detail: "Native lyrics surface configured",
            track: configuration.trackContext,
            metrics: [
                "rowCount": Double(configuration.rows.count),
                "renderedIndexCount": Double(configuration.renderedIndices.count),
                "currentIndex": Double(configuration.effectiveCurrentIndex),
                "isManualScrolling": configuration.effectiveIsManualScrolling ? 1 : 0,
                "nativeTimelineIndex": Double(configuration.nativeSemanticCurrentIndex ?? -1),
                "waveTimelineEnabled": DiagnosticsService.shared.isLyricWaveTimelineEnabled ? 1 : 0
            ]
        )
    }

    private func visibleRows(for configuration: LyricsLayerRendererConfiguration) -> [LayerBackedLyricRow] {
        let visibleIndices = Set(NativeLyricsVisibleRowSelector.visibleIndices(
            allIndices: configuration.renderedIndices,
            currentIndex: configuration.effectiveCurrentIndex,
            activeTargetIndices: presentationEngine.lineTargetIndices.keys,
            radius: 14
        ))
        return configuration.rows.filter { visibleIndices.contains($0.index) }
    }

    func stopAnimations() {
        cancelManualScrollTimers()
        cancelNativeLineAdvanceTimer()
        manualScrollState.reset()
        nativeSemanticCurrentIndex = nil
        stopNativeLineMotionSamplingTimer()
        presentationEngine.stop()
        stopPresentationLoop()
        for view in rowViews.values {
            view.layer?.removeAllAnimations()
        }
        rowIDByIndex.removeAll()
        lastConfiguredTextPhaseIndex = nil
    }

    @discardableResult
    private func updateContentIfNeeded(
        view: NativeLyricsRowView,
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> Bool {
        let key = RowRenderKey(row: row, configuration: configuration)
        let needsContentUpdate = rowRenderKeys[row.id] != key
        if needsContentUpdate {
            renderTelemetry.recordContentUpdate()
            rowRenderKeys[row.id] = key
            view.configure(row: row, configuration: configuration)
        }

        guard needsContentUpdate || measuredHeightsByIndex[row.index] == nil else { return false }
        let height = view.measuredHeight(width: configuration.rowWidth)
        let heightChanged = abs((measuredHeightsByIndex[row.index] ?? 0) - height) > 2
        renderTelemetry.recordHeightMeasurement(changed: heightChanged)
        if heightChanged {
            measuredHeightsByIndex[row.index] = height
            DispatchQueue.main.async {
                configuration.onHeightMeasured(row.index, height)
            }
        }
        return needsContentUpdate
    }

    private func applyFrame(
        for row: LayerBackedLyricRow,
        view: NativeLyricsRowView,
        configuration: LyricsLayerRendererConfiguration,
        snap: Bool
    ) {
        let baseY = snap
            ? snapY(for: row, configuration: configuration)
            : (presentationEngine.presentation(for: row.index)?.y ?? snapY(for: row, configuration: configuration))
        let y = baseY + configuration.effectiveManualOffset
        let currentIndex = configuration.effectiveCurrentIndex
        let isCurrent = row.index == currentIndex
        let opacity: CGFloat = isCurrent ? 1 : 0.35
        let scale: CGFloat = isCurrent ? 1 : 0.95
        let blur: CGFloat = isCurrent ? 0 : CGFloat(abs(row.index - currentIndex)) * 1.5
        let height = measuredHeightsByIndex[row.index] ?? max(1, view.frame.height)
        let frame = CGRect(x: 0, y: 0, width: configuration.rowWidth, height: max(1, height))

        if view.frame.size != frame.size || view.frame.origin != .zero {
            view.frame = frame
        }
        view.layer?.opacity = Float(opacity)
        view.layer?.setAffineTransform(
            CGAffineTransform(translationX: 0, y: y)
                .scaledBy(x: scale, y: scale)
        )
        let appliedTransform = view.layer?.affineTransform() ?? .identity
        let appliedScale = sqrt(appliedTransform.a * appliedTransform.a + appliedTransform.c * appliedTransform.c)
        renderTelemetry.recordRowFrameParity(NativeLyricsRowFrameParitySample(
            expectedY: y,
            appliedY: appliedTransform.ty,
            expectedHeight: frame.height,
            appliedHeight: view.frame.height,
            expectedScale: scale,
            appliedScale: appliedScale
        ))
        let appliedBlur = view.applyBlurRadius(blur)
        recordVisualParityIfChanged(rowID: row.id, sample: NativeLyricsVisualParitySample(
            expectedOpacity: opacity,
            appliedOpacity: CGFloat(view.layer?.opacity ?? 0),
            expectedScale: scale,
            appliedScale: appliedScale,
            expectedBlurRadius: blur > 0.1 ? blur : 0,
            appliedBlurRadius: appliedBlur,
            isActive: row.index == currentIndex
        ))
    }

    private func withDisabledLayerActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func reportPendingLineMotionFramesIfNeeded(configuration: LyricsLayerRendererConfiguration) {
        guard configuration.lineMotionFrameCaptureSequence >= 0,
              configuration.lineMotionFrameCaptureSequence != lastReportedLineMotionCaptureSequence else { return }
        lastReportedLineMotionCaptureSequence = configuration.lineMotionFrameCaptureSequence
        reportLineMotionFrames(configuration: configuration)
    }

    private func reportLineMotionFrames(
        configuration: LyricsLayerRendererConfiguration,
        timestamp: Date? = nil,
        playbackTime: TimeInterval? = nil
    ) {
        var frames: [Int: CGRect] = [:]
        for row in visibleRows(for: configuration) {
            guard let view = rowViews[row.id] else { continue }
            guard view.frame.height > 0 else { continue }
            let baseY = presentationEngine.presentation(for: row.index)?.y ?? snapY(for: row, configuration: configuration)
            let y = baseY + configuration.effectiveManualOffset
            frames[row.index] = CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height)
        }
        recordNativeMotionMetrics(frames: frames, configuration: configuration)
        let presentationSnapshot = nativePresentationSnapshot(
            lineIndices: frames.keys,
            configuration: configuration
        )
        DispatchQueue.main.async {
            configuration.onLineMotionFrames(
                frames,
                presentationSnapshot,
                timestamp,
                playbackTime
            )
        }
    }

    private func updateNativeLineMotionSamplingTimer(configuration: LyricsLayerRendererConfiguration) {
        guard configuration.lineMotionSamplingEnabled else {
            stopNativeLineMotionSamplingTimer()
            return
        }
        guard nativeLineMotionSamplingTimer == nil else { return }
        lastNativeLineMotionSampleAt = .distantPast
        let timer = Timer(timeInterval: LyricMotionSamplingPolicy.focusedInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleNativeLineMotionIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nativeLineMotionSamplingTimer = timer
    }

    private func stopNativeLineMotionSamplingTimer() {
        nativeLineMotionSamplingTimer?.invalidate()
        nativeLineMotionSamplingTimer = nil
        lastNativeLineMotionSampleAt = .distantPast
    }

    private func sampleNativeLineMotionIfNeeded() {
        guard let baseConfiguration = configuration else {
            stopNativeLineMotionSamplingTimer()
            return
        }
        let runtimeConfiguration = runtimeConfiguration(from: baseConfiguration)
        guard runtimeConfiguration.lineMotionSamplingEnabled else {
            stopNativeLineMotionSamplingTimer()
            return
        }

        let now = Date()
        let playbackTime = runtimeConfiguration.musicController.lyricRenderTime(at: now)
        let sortedRows = runtimeConfiguration.rows.sorted { $0.index < $1.index }
        let lyrics = sortedRows.map(\.displayLine.line)
        guard !lyrics.isEmpty else { return }
        let firstRealIndex = min(
            max(runtimeConfiguration.lineMotionFirstRealDisplayIndex, 0),
            max(lyrics.count - 1, 0)
        )
        let sampleInterval = LyricMotionSamplingPolicy.sampleInterval(
            focusedWindowActive: now <= runtimeConfiguration.lineMotionFocusedSamplingUntil,
            playbackTime: playbackTime,
            lyrics: lyrics,
            firstRealIndex: firstRealIndex
        )
        guard now.timeIntervalSince(lastNativeLineMotionSampleAt) >= sampleInterval else { return }
        lastNativeLineMotionSampleAt = now

        reportLineMotionFrames(
            configuration: runtimeConfiguration,
            timestamp: now,
            playbackTime: playbackTime
        )
    }

    private func nativePresentationSnapshot(
        lineIndices: some Sequence<Int>,
        configuration: LyricsLayerRendererConfiguration
    ) -> NativeLyricsPresentationSnapshot {
        var targetMinYByIndex: [Int: CGFloat] = [:]
        var velocityYByIndex: [Int: CGFloat] = [:]
        var targetIndices: [Int: Int] = [:]
        for index in lineIndices {
            if let presentation = presentationEngine.presentation(for: index) {
                targetIndices[index] = presentation.targetIndex
                targetMinYByIndex[index] = presentation.targetY
                velocityYByIndex[index] = presentation.velocity
            } else {
                let targetIndex = presentationEngine.targetIndex(
                    for: index,
                    fallback: configuration.effectiveCurrentIndex
                )
                targetIndices[index] = targetIndex
                let rowOffset = configuration.accumulatedHeights[index] ?? 0
                let targetOffset = configuration.accumulatedHeights[targetIndex] ?? 0
                targetMinYByIndex[index] = configuration.anchorY - targetOffset + rowOffset
            }
        }
        return NativeLyricsPresentationSnapshot(
            targetIndices: targetIndices,
            targetMinYByIndex: targetMinYByIndex,
            velocityYByIndex: velocityYByIndex,
            manualScrollSnapshot: configuration.nativeManualScrollSnapshot
        )
    }

    private func recordNativeMotionMetrics(
        frames: [Int: CGRect],
        configuration: LyricsLayerRendererConfiguration
    ) {
        guard !frames.isEmpty else { return }
        let metricRows = visibleRows(for: configuration).compactMap { row -> NativeLyricsMotionMetricRow? in
            guard let frame = frames[row.index], frame.height > 0 else { return nil }
            let presentation = presentationEngine.presentation(for: row.index)
            let targetIndex = presentation?.targetIndex
                ?? presentationEngine.targetIndex(for: row.index, fallback: configuration.effectiveCurrentIndex)
            let targetMinY = (presentation?.targetY ?? snapY(for: row, configuration: configuration))
                + configuration.effectiveManualOffset
            return NativeLyricsMotionMetricRow(
                displayIndex: row.index,
                targetIndex: targetIndex,
                renderedMinY: frame.minY,
                renderedHeight: frame.height,
                targetMinY: targetMinY,
                velocityY: presentation?.velocity ?? 0
            )
        }
        guard !metricRows.isEmpty else { return }
        let visibleTopY: CGFloat = 42
        let visibleBottomY = max(visibleTopY + 1, bounds.height - (configuration.controlsVisible ? 120 : 20))
        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: metricRows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: configuration.effectiveCurrentIndex,
                visibleTopY: visibleTopY,
                visibleBottomY: visibleBottomY,
                isManualScrolling: configuration.effectiveIsManualScrolling,
                frozenDisplayIndex: configuration.effectiveIsManualScrolling ? configuration.effectiveCurrentIndex : nil,
                participatingWaveDisplayIndices: Set(presentationEngine.lineTargetIndices.keys),
                isNaturalWaveActive: presentationEngine.isNaturalWaveActive,
                isDirectSnap: configuration.playbackMode != .natural
            )
        )
        renderTelemetry.recordMotion(metrics)
    }

    private func snapY(
        for row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> CGFloat {
        let targetIndex = configuration.effectiveIsManualScrolling
            ? configuration.effectiveCurrentIndex
            : presentationEngine.targetIndex(
                for: row.index,
                fallback: configuration.effectiveCurrentIndex
            )
        let rowOffset = configuration.accumulatedHeights[row.index] ?? 0
        let targetOffset = configuration.accumulatedHeights[targetIndex] ?? 0
        return configuration.anchorY - targetOffset + rowOffset
    }

    private func applyFrames(
        runtimeConfiguration: LyricsLayerRendererConfiguration,
        snap: Bool,
        managesTransaction: Bool = true
    ) {
        let applyFrames = {
            for view in self.rowViews.values {
                guard let row = view.currentRow else { continue }
                self.applyFrame(for: row, view: view, configuration: runtimeConfiguration, snap: snap)
            }
        }
        if managesTransaction {
            withDisabledLayerActions(applyFrames)
        } else {
            applyFrames()
        }
    }

    private func applyFramesForCurrentConfiguration(snap: Bool, managesTransaction: Bool = true) {
        guard let configuration else { return }
        applyFrames(
            runtimeConfiguration: runtimeConfiguration(from: configuration),
            snap: snap,
            managesTransaction: managesTransaction
        )
    }

    private func startPresentationLoop() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else {
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, outputTime, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let view = Unmanaged<NativeLyricsSurfaceView>
                .fromOpaque(context)
                .takeUnretainedValue()
            let timestamp = outputTime.pointee
            let displayInterval = NativeLyricsSurfaceView.refreshInterval(from: timestamp)
            let displayTimestamp = NativeLyricsSurfaceView.frameTimestamp(from: timestamp)
            DispatchQueue.main.async {
                view.presentationTick(
                    displayInterval: displayInterval,
                    displayTimestamp: displayTimestamp
                )
            }
            return kCVReturnSuccess
        }, context)
        displayLink = link
        lastPresentationTick = nil
        resetFrameSummary()
        CVDisplayLinkStart(link)
    }

    private func stopPresentationLoopIfIdle() {
        guard let configuration else {
            stopPresentationLoop()
            return
        }
        stopPresentationLoopIfIdle(runtimeConfiguration: runtimeConfiguration(from: configuration))
    }

    private func stopPresentationLoopIfIdle(runtimeConfiguration: LyricsLayerRendererConfiguration) {
        guard !presentationEngine.hasActiveMotion,
              !hasActiveTextAnimation(configuration: runtimeConfiguration) else { return }
        stopPresentationLoop()
    }

    private func stopPresentationLoop() {
        guard let activeDisplayLink = displayLink else { return }
        CVDisplayLinkStop(activeDisplayLink)
        self.displayLink = nil
        lastPresentationTick = nil
        flushFrameSummary(reason: "stop")
    }

    private func presentationTick(
        displayInterval: TimeInterval?,
        displayTimestamp: TimeInterval?
    ) {
        guard let configuration else {
            stopPresentationLoop()
            return
        }
        let previousSemanticIndex = nativeSemanticCurrentIndex
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        let now = CACurrentMediaTime()
        let tickTimestamp = displayTimestamp ?? now
        let delta = lastPresentationTick.map { max(0, tickTimestamp - $0) }
            ?? displayInterval
            ?? 0
        lastPresentationTick = tickTimestamp
        recordFrameDelta(delta, expectedRefreshInterval: displayInterval, now: now)
        let semanticChanged = updateNativeTimelineForCurrentPlaybackIfNeeded(
            previousIndex: previousSemanticIndex,
            runtimeConfiguration: runtimeConfiguration
        )
        let motionChanged = presentationEngine.advance(delta: delta)
        withDisabledLayerActions {
            updateTextPhasesForCurrentConfiguration(runtimeConfiguration: runtimeConfiguration)
            if semanticChanged || motionChanged || presentationEngine.hasActiveMotion {
                applyFrames(runtimeConfiguration: runtimeConfiguration, snap: false, managesTransaction: false)
            }
        }
        reportPendingLineMotionFramesIfNeeded(configuration: runtimeConfiguration)
        stopPresentationLoopIfIdle(runtimeConfiguration: runtimeConfiguration)
    }

    nonisolated private static func refreshInterval(from timestamp: CVTimeStamp) -> TimeInterval? {
        guard timestamp.videoTimeScale > 0, timestamp.videoRefreshPeriod > 0 else { return nil }
        return Double(timestamp.videoRefreshPeriod) / Double(timestamp.videoTimeScale)
    }

    nonisolated private static func frameTimestamp(from timestamp: CVTimeStamp) -> TimeInterval? {
        guard timestamp.videoTimeScale > 0 else { return nil }
        return Double(timestamp.videoTime) / Double(timestamp.videoTimeScale)
    }

    private func resetFrameSummary(at now: CFTimeInterval = CACurrentMediaTime()) {
        frameSummaryStartedAt = now
        frameCadence = NativeLyricsFrameCadenceAccumulator()
    }

    private func recordFrameDelta(
        _ delta: TimeInterval,
        expectedRefreshInterval: TimeInterval?,
        now: CFTimeInterval
    ) {
        guard delta > 0 else { return }
        frameCadence.record(delta: delta, expectedRefreshInterval: expectedRefreshInterval)
        guard let startedAt = frameSummaryStartedAt else {
            resetFrameSummary(at: now)
            return
        }
        if now - startedAt >= 1.0 {
            flushFrameSummary(reason: "interval", endedAt: now)
        }
    }

    private func flushFrameSummary(
        reason: String,
        endedAt: CFTimeInterval = CACurrentMediaTime()
    ) {
        let summary = frameCadence.summary()
        guard summary.frameSampleCount > 0 else {
            if DiagnosticsService.shared.isEnabled, let configuration {
                flushRenderTelemetry(reason: "\(reason)-no-frame", track: configuration.trackContext)
            }
            resetFrameSummary(at: endedAt)
            return
        }
        guard DiagnosticsService.shared.isEnabled, let configuration else {
            resetFrameSummary(at: endedAt)
            return
        }

        DiagnosticsService.shared.recordEvent(
            "lyrics.presentationFrame.summary",
            detail: "Native lyrics surface frame cadence summary (\(reason))",
            track: configuration.trackContext,
            metrics: [
                "frameSampleCount": Double(summary.frameSampleCount),
                "expectedRefreshIntervalMs": (summary.expectedRefreshInterval ?? 0) * 1000,
                "expectedFPS": summary.expectedFPS,
                "effectiveFPS": summary.effectiveFPS,
                "frameDeltaP50Ms": summary.frameDeltaP50 * 1000,
                "frameDeltaP95Ms": summary.frameDeltaP95 * 1000,
                "frameDeltaP99Ms": summary.frameDeltaP99 * 1000,
                "frameDeltaMaxMs": summary.frameDeltaMax * 1000,
                "longestFrameStallMs": summary.longestFrameStall * 1000,
                "droppedFramesOver1_5xRefresh": Double(summary.droppedFramesOverOnePointFiveRefresh),
                "droppedFramesOver2xRefresh": Double(summary.droppedFramesOverTwoRefresh),
                "tickJitterP50Ms": summary.tickJitterP50 * 1000,
                "tickJitterP95Ms": summary.tickJitterP95 * 1000,
                "tickJitterMaxMs": summary.tickJitterMax * 1000
            ]
        )
        flushRenderTelemetry(reason: reason, track: configuration.trackContext)
        resetFrameSummary(at: endedAt)
    }

    private func flushRenderTelemetry(reason: String, track: DiagnosticTrackContext) {
        guard renderTelemetry.hasSamples else { return }
        let summary = renderTelemetry.summary()
        DiagnosticsService.shared.recordEvent(
            "lyrics.nativeRenderer.summary",
            detail: "Native lyrics renderer workload, text phase, and motion summary (\(reason))",
            track: track,
            metrics: summary.metrics
        )
        renderTelemetry = NativeLyricsRenderTelemetryAccumulator()
    }

    override func mouseDown(with event: NSEvent) {
        guard let configuration else {
            super.mouseDown(with: event)
            return
        }
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        let point = convert(event.locationInWindow, from: nil)
        let hit = runtimeConfiguration.rows
            .compactMap { row -> (Int, CGRect)? in
                guard let view = rowViews[row.id] else { return nil }
                let baseY = presentationEngine.presentation(for: row.index)?.y
                    ?? snapY(for: row, configuration: runtimeConfiguration)
                let y = baseY + runtimeConfiguration.effectiveManualOffset
                return (row.index, CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height))
            }
            .sorted { lhs, rhs in abs(lhs.1.midY - point.y) < abs(rhs.1.midY - point.y) }
            .first { _, frame in frame.contains(point) }

        if let index = hit?.0, let handler = rowTapHandlers[index] {
            handler()
            return
        }
        if manualScrollState.isActive,
           let hoveredRowIndex,
           let handler = rowTapHandlers[hoveredRowIndex] {
            handler()
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let configuration else {
            renderTelemetry.recordIgnoredManualScroll(reason: .outOfBounds)
            super.scrollWheel(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -4, dy: -4).contains(point) else {
            renderTelemetry.recordIgnoredManualScroll(reason: .outOfBounds)
            super.scrollWheel(with: event)
            return
        }
        let absX = abs(event.scrollingDeltaX)
        let absY = abs(event.scrollingDeltaY)
        guard absY >= 0.1, !(absX > absY * 1.5 && absX > 1.0) else {
            renderTelemetry.recordIgnoredManualScroll(reason: .horizontal)
            super.scrollWheel(with: event)
            return
        }

        let isMomentum = event.momentumPhase != []
        if isMomentum && !manualScrollState.isActive {
            renderTelemetry.recordIgnoredManualScroll(reason: .momentumWithoutOwnership)
            return
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            endNativeManualScrollInteraction()
            return
        }

        let deltaY = event.scrollingDeltaY
        let threshold: CGFloat = isMomentum ? 0.1 : 0.5
        guard abs(deltaY) >= threshold else {
            renderTelemetry.recordIgnoredManualScroll(reason: .tooSmall)
            return
        }

        beginNativeManualScrollIfNeeded(configuration: configuration)
        let now = CACurrentMediaTime()
        let velocity: CGFloat
        if lastScrollWheelTime > 0 {
            let timeDelta = now - lastScrollWheelTime
            velocity = timeDelta > 0 && timeDelta < 0.5 ? deltaY / CGFloat(timeDelta) : 0
        } else {
            velocity = 0
        }
        lastScrollWheelTime = now

        manualScrollEndTimer?.invalidate()
        manualScrollRecoveryTimer?.invalidate()
        manualScrollState.apply(
            deltaY: deltaY,
            velocity: velocity,
            bounds: manualScrollBounds(for: runtimeConfiguration(from: configuration))
        )
        updateNativeHover(from: point, configuration: runtimeConfiguration(from: configuration))
        renderTelemetry.recordManualScrollDelta(
            deltaY: deltaY,
            velocityY: velocity,
            manualOffsetY: manualScrollState.manualOffset
        )
        configuration.onManualScrollDelta(deltaY, velocity)
        applyNativeManualScrollPresentation()
        scheduleNativeScrollEnd(delay: isMomentum ? 0.4 : 0.16)
    }

    private func handleNativeLineTap(rowIndex: Int, line: LyricLine) {
        let startedAt = CACurrentMediaTime()
        let currentIndex = configuration?.effectiveCurrentIndex ?? rowIndex
        renderTelemetry.recordTapToLine(
            targetDistance: rowIndex - currentIndex,
            duringManualScroll: manualScrollState.isActive
        )
        cancelManualScrollTimers()
        if manualScrollState.isActive {
            manualScrollState.reset()
            renderTelemetry.recordManualScrollRecovery()
            if let configuration {
                refreshRowInteractionState(configuration: runtimeConfiguration(from: configuration))
            }
            configuration?.onManualScrollRecovered()
        }
        forceDirectSnap(to: rowIndex, reason: .tapToLine)
        recordTapToLineSettleTiming(targetIndex: rowIndex, startedAt: startedAt)
        configuration?.onLineTap(line)
    }

    private func beginNativeManualScrollIfNeeded(configuration: LyricsLayerRendererConfiguration) {
        guard !manualScrollState.isActive else { return }
        manualScrollState.begin(frozenDisplayIndex: configuration.effectiveCurrentIndex)
        renderTelemetry.recordManualScrollStart()
        refreshRowInteractionState(configuration: runtimeConfiguration(from: configuration))
        configuration.onManualScrollStarted(configuration.effectiveCurrentIndex)
        applyNativeManualScrollPresentation()
    }

    private func endNativeManualScrollInteraction() {
        guard let configuration, manualScrollState.isActive else { return }
        manualScrollEndTimer?.invalidate()
        lastScrollWheelTime = 0
        manualScrollState.clampToBounds(manualScrollBounds(for: runtimeConfiguration(from: configuration)))
        renderTelemetry.recordManualScrollEnd()
        configuration.onManualScrollEnded()
        applyNativeManualScrollPresentation()
        manualScrollRecoveryTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.recoverNativeManualScroll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualScrollRecoveryTimer = timer
    }

    private func scheduleNativeScrollEnd(delay: TimeInterval) {
        manualScrollEndTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.endNativeManualScrollInteraction()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualScrollEndTimer = timer
    }

    private func recoverNativeManualScroll() {
        guard let configuration, manualScrollState.isActive else { return }
        cancelManualScrollTimers()
        let liveIndex = liveDisplayIndex(configuration: configuration)
        manualScrollState.reset()
        renderTelemetry.recordManualScrollRecovery()
        refreshRowInteractionState(configuration: runtimeConfiguration(from: configuration))
        configuration.onManualScrollRecovered()
        forceDirectSnap(to: liveIndex, reason: .manualScroll)
    }

    private func applyNativeManualScrollPresentation() {
        guard let configuration else { return }
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        if presentationEngine.isNaturalWaveActive {
            presentationEngine.update(
                engineConfiguration(from: runtimeConfiguration),
                onTargetsChanged: { [weak self] in
                    self?.startPresentationLoop()
                }
            )
        }
        applyFrames(runtimeConfiguration: runtimeConfiguration, snap: true)
        if runtimeConfiguration.lineMotionFrameCaptureActive {
            reportLineMotionFrames(configuration: runtimeConfiguration)
        }
    }

    private func forceDirectSnap(to index: Int, reason: LyricsPresentationDirectSnapReason) {
        guard let configuration else { return }
        renderTelemetry.recordDirectSnap(reason: reason)
        var runtimeConfiguration = runtimeConfiguration(from: configuration)
        runtimeConfiguration.nativeDirectSnapIndex = index
        runtimeConfiguration.nativeDirectSnapReason = reason
        refreshRowInteractionState(configuration: runtimeConfiguration)
        presentationEngine.update(
            engineConfiguration(from: runtimeConfiguration),
            onTargetsChanged: { [weak self] in
                self?.startPresentationLoop()
            }
        )
        withDisabledLayerActions {
            for row in visibleRows(for: runtimeConfiguration) {
                guard let view = rowViews[row.id] else { continue }
                updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
                applyFrame(for: row, view: view, configuration: runtimeConfiguration, snap: true)
            }
        }
        if hasActiveTextAnimation(configuration: runtimeConfiguration) {
            startPresentationLoop()
        }
    }

    private func recordTapToLineSettleTiming(targetIndex: Int, startedAt: CFTimeInterval) {
        guard let configuration else { return }
        var runtimeConfiguration = runtimeConfiguration(from: configuration)
        runtimeConfiguration.nativeDirectSnapIndex = targetIndex
        runtimeConfiguration.nativeDirectSnapReason = .tapToLine
        guard let row = runtimeConfiguration.rows.first(where: { $0.index == targetIndex }),
              let view = rowViews[row.id] else { return }
        let expectedY = presentationEngine.presentation(for: row.index)?.targetY
            ?? snapY(for: row, configuration: runtimeConfiguration)
        let appliedY = view.layer?.affineTransform().ty ?? .greatestFiniteMagnitude
        guard abs(appliedY - expectedY) <= 0.5 else { return }
        let elapsed = CGFloat(max(0, CACurrentMediaTime() - startedAt))
        renderTelemetry.recordTapToLineTiming(latency: elapsed, settleTime: elapsed)
    }

    private func refreshRowInteractionState(configuration: LyricsLayerRendererConfiguration) {
        for view in rowViews.values {
            view.refreshInteractionState(configuration: configuration)
        }
    }

    private func updateNativeHover(from point: CGPoint, configuration: LyricsLayerRendererConfiguration) {
        let hoveredIndex = visibleRows(for: configuration)
            .compactMap { row -> (Int, CGRect)? in
                guard let view = rowViews[row.id] else { return nil }
                let baseY = presentationEngine.presentation(for: row.index)?.y
                    ?? snapY(for: row, configuration: configuration)
                let y = baseY + configuration.effectiveManualOffset
                return (row.index, CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height))
            }
            .sorted { lhs, rhs in abs(lhs.1.midY - point.y) < abs(rhs.1.midY - point.y) }
            .first { _, frame in frame.contains(point) }?
            .0

        guard hoveredIndex != hoveredRowIndex else {
            if let hoveredIndex,
               let row = configuration.rows.first(where: { $0.index == hoveredIndex }),
               let view = rowViews[row.id] {
                view.refreshInteractionState(configuration: configuration)
            }
            return
        }

        if let previous = hoveredRowIndex,
           let row = configuration.rows.first(where: { $0.index == previous }),
           let view = rowViews[row.id] {
            view.setPointerHovering(false)
        }
        if let hoveredIndex,
           let row = configuration.rows.first(where: { $0.index == hoveredIndex }),
           let view = rowViews[row.id] {
            view.refreshInteractionState(configuration: configuration)
            view.setPointerHovering(true)
        }
        hoveredRowIndex = hoveredIndex
    }

    @discardableResult
    private func updateNativeTimelineForCurrentPlaybackIfNeeded(
        previousIndex: Int?,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) -> Bool {
        guard runtimeConfiguration.playbackMode == .natural else {
            scheduleNativeLineAdvanceTimerIfNeeded(configuration: runtimeConfiguration)
            return false
        }
        let nextIndex = runtimeConfiguration.effectiveCurrentIndex
        guard previousIndex != nextIndex else {
            scheduleNativeLineAdvanceTimerIfNeeded(configuration: runtimeConfiguration)
            return false
        }
        presentationEngine.update(
            engineConfiguration(from: runtimeConfiguration),
            onTargetsChanged: { [weak self] in
                self?.startPresentationLoop()
            }
        )
        scheduleNativeLineAdvanceTimerIfNeeded(configuration: runtimeConfiguration)
        return true
    }

    private func scheduleNativeLineAdvanceTimerIfNeeded(
        configuration: LyricsLayerRendererConfiguration
    ) {
        guard configuration.playbackMode == .natural,
              configuration.musicController.isPlaying,
              !configuration.rows.isEmpty else {
            cancelNativeLineAdvanceTimer()
            return
        }
        let playbackTime = configuration.musicController.lyricRenderTime()
        guard let nextStart = NativeLyricsTimelinePolicy.nextLineStartTime(
            after: playbackTime,
            rows: configuration.rows
        ) else {
            cancelNativeLineAdvanceTimer()
            return
        }
        if let existing = nativeLineAdvanceTimerTargetPlaybackTime,
           nativeLineAdvanceTimer != nil,
           abs(existing - nextStart) <= NativeLyricsTimelinePolicy.lineAdvanceEpsilon {
            return
        }
        cancelNativeLineAdvanceTimer()
        let delay = max(NativeLyricsTimelinePolicy.lineAdvanceEpsilon, nextStart - playbackTime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleNativeLineAdvanceTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nativeLineAdvanceTimer = timer
        nativeLineAdvanceTimerTargetPlaybackTime = nextStart
    }

    private func handleNativeLineAdvanceTimer() {
        nativeLineAdvanceTimer = nil
        nativeLineAdvanceTimerTargetPlaybackTime = nil
        guard let configuration else { return }
        let previousSemanticIndex = nativeSemanticCurrentIndex
        let changed = updateNativeTimelineForCurrentPlaybackIfNeeded(
            previousIndex: previousSemanticIndex,
            runtimeConfiguration: runtimeConfiguration(from: configuration)
        )
        if changed {
            applyFramesForCurrentConfiguration(snap: false)
            startPresentationLoop()
        }
    }

    private func cancelNativeLineAdvanceTimer() {
        nativeLineAdvanceTimer?.invalidate()
        nativeLineAdvanceTimer = nil
        nativeLineAdvanceTimerTargetPlaybackTime = nil
    }

    private func engineConfiguration(
        from configuration: LyricsLayerRendererConfiguration
    ) -> LyricsPresentationEngineConfiguration {
        let currentIndex = configuration.effectiveCurrentIndex
        return LyricsPresentationEngineConfiguration(
            currentIndex: currentIndex,
            renderedIndices: configuration.renderedIndices,
            anchorY: configuration.anchorY,
            accumulatedHeights: configuration.accumulatedHeights,
            lineInterval: lineInterval(around: currentIndex, rows: configuration.rows) ?? configuration.lineInterval,
            hasSyllableSync: configuration.rows.first(where: { $0.index == currentIndex })?.displayLine.line.hasSyllableSync ?? configuration.hasSyllableSync,
            trackContext: configuration.trackContext,
            isWaveTimelineDiagnosticsEnabled: configuration.isWaveTimelineDiagnosticsEnabled
                || DiagnosticsService.shared.isLyricWaveTimelineEnabled,
            playbackMode: configuration.playbackMode
        )
    }

    private func lineInterval(
        around index: Int,
        rows: [LayerBackedLyricRow]
    ) -> TimeInterval? {
        guard let position = rows.firstIndex(where: { $0.index == index }) else { return nil }
        let currentStart = rows[position].displayLine.line.startTime
        if position + 1 < rows.count {
            let nextStart = rows[position + 1].displayLine.line.startTime
            if nextStart > currentStart {
                return nextStart - currentStart
            }
        }
        if position > 0 {
            let previousStart = rows[position - 1].displayLine.line.startTime
            if currentStart > previousStart {
                return currentStart - previousStart
            }
        }
        return nil
    }

    private func manualScrollBounds(for configuration: LyricsLayerRendererConfiguration) -> NativeLyricsManualScrollBounds {
        let currentIndex = configuration.effectiveCurrentIndex
        let currentOffset = configuration.accumulatedHeights[currentIndex] ?? 0
        let visibleBottom = max(1, (bounds.height - 120) - configuration.anchorY)
        let totalHeight = totalContentHeight(configuration: configuration)
        return NativeLyricsManualScrollBounds(
            maxUp: max(0, currentOffset - configuration.anchorY),
            maxDown: max(0, totalHeight - currentOffset - visibleBottom),
            rubberBandDimension: max(bounds.height * 0.4, 120)
        )
    }

    private func totalContentHeight(configuration: LyricsLayerRendererConfiguration) -> CGFloat {
        var total: CGFloat = 0
        for row in configuration.rows {
            let offset = configuration.accumulatedHeights[row.index] ?? 0
            let measured = measuredHeightsByIndex[row.index] ?? 46
            total = max(total, offset + measured)
        }
        return total
    }

    private func liveDisplayIndex(configuration: LyricsLayerRendererConfiguration) -> Int {
        let renderTime = configuration.musicController.lyricRenderTime()
        let candidates = configuration.rows
            .filter { !$0.isPrelude && $0.displayLine.line.startTime <= renderTime }
            .sorted { $0.displayLine.line.startTime < $1.displayLine.line.startTime }
        return candidates.last?.index ?? configuration.currentIndex
    }

    private func cancelManualScrollTimers() {
        manualScrollEndTimer?.invalidate()
        manualScrollEndTimer = nil
        manualScrollRecoveryTimer?.invalidate()
        manualScrollRecoveryTimer = nil
        lastScrollWheelTime = 0
    }

    private struct RowRenderKey: Equatable {
        let row: LayerBackedLyricRow
        let isCurrent: Bool
        let isPlaying: Bool
        let showTranslation: Bool
        let isAwaitingTranslation: Bool
        let translationFailed: Bool
        let isPrecedingInterlude: Bool
        let rowWidth: CGFloat

        init(row: LayerBackedLyricRow, configuration: LyricsLayerRendererConfiguration) {
            self.row = row
            self.isCurrent = row.index == configuration.effectiveCurrentIndex
            self.isPlaying = configuration.musicController.isPlaying
            self.showTranslation = configuration.showTranslation
            self.isAwaitingTranslation = LyricLineTranslationLayoutPolicy.isAwaitingTranslation(
                index: row.displayLine.sourceIndex,
                line: row.sourceLine,
                pendingLineIndices: configuration.pendingTranslationLineIndices,
                isTranslating: configuration.isTranslating
            )
            self.translationFailed = configuration.translationFailed
            self.isPrecedingInterlude = configuration.interludeAfterIndex == row.index
            self.rowWidth = configuration.rowWidth
        }
    }

    private struct VisualParitySignature: Equatable {
        let expectedOpacity: Int
        let appliedOpacity: Int
        let expectedScale: Int
        let appliedScale: Int
        let expectedBlur: Int
        let appliedBlur: Int
        let isActive: Bool

        init(_ sample: NativeLyricsVisualParitySample) {
            expectedOpacity = Self.quantize(sample.expectedOpacity, scale: 1000)
            appliedOpacity = Self.quantize(sample.appliedOpacity, scale: 1000)
            expectedScale = Self.quantize(sample.expectedScale, scale: 1000)
            appliedScale = Self.quantize(sample.appliedScale, scale: 1000)
            expectedBlur = Self.quantize(sample.expectedBlurRadius, scale: 4)
            appliedBlur = Self.quantize(sample.appliedBlurRadius, scale: 4)
            isActive = sample.isActive
        }

        private static func quantize(_ value: CGFloat, scale: CGFloat) -> Int {
            Int((value * scale).rounded(.toNearestOrAwayFromZero))
        }
    }

    private func recordVisualParityIfChanged(rowID: String, sample: NativeLyricsVisualParitySample) {
        let signature = VisualParitySignature(sample)
        guard visualParitySignatures[rowID] != signature else { return }
        visualParitySignatures[rowID] = signature
        renderTelemetry.recordVisualParity(sample)
    }

    fileprivate func recordHoverBackgroundParity(_ sample: NativeLyricsHoverParitySample) {
        renderTelemetry.recordHoverParity(sample)
    }

    fileprivate func recordDotPhase(_ sample: NativeLyricsDotPhaseSample) {
        renderTelemetry.recordDotPhase(sample)
    }

    private func updateTextPhasesForCurrentConfiguration(
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        guard let (_, view) = activeTextPhaseRow(for: runtimeConfiguration),
              let textSample = view.updatePlaybackPhase(configuration: runtimeConfiguration, managesTransaction: false) else {
            return
        }
        renderTelemetry.recordTextPhase(textSample)
    }

    private func activeTextPhaseRow(
        for configuration: LyricsLayerRendererConfiguration
    ) -> (LayerBackedLyricRow, NativeLyricsRowView)? {
        let activeIndex = configuration.effectiveCurrentIndex
        if let rowID = rowIDByIndex[activeIndex],
           let view = rowViews[rowID],
           let row = view.currentRow,
           row.index == activeIndex {
            return (row, view)
        }
        guard let view = rowViews.values.first(where: { $0.currentRow?.index == activeIndex }),
              let row = view.currentRow else {
            return nil
        }
        rowIDByIndex[activeIndex] = row.id
        return (row, view)
    }

    private func hasActiveTextAnimation(configuration: LyricsLayerRendererConfiguration) -> Bool {
        guard configuration.musicController.isPlaying else { return false }
        guard let activeRow = activeTextPhaseRow(for: configuration)?.0
            ?? configuration.rows.first(where: { $0.index == configuration.effectiveCurrentIndex }) else {
            return false
        }
        return activeRow.displayLine.line.hasSyllableSync
            || (configuration.showTranslation && activeRow.displayLine.line.translation?.isEmpty == false)
            || activeRow.interlude != nil
            || activeRow.isPrelude
    }

    private static func isSameTrackIdentity(
        _ lhs: DiagnosticTrackContext,
        _ rhs: DiagnosticTrackContext
    ) -> Bool {
        let lhsID = lhs.persistentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rhsID = rhs.persistentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lhsID.isEmpty || !rhsID.isEmpty {
            return lhsID == rhsID
        }
        return normalizedTrackIdentity(lhs.title) == normalizedTrackIdentity(rhs.title)
            && normalizedTrackIdentity(lhs.artist) == normalizedTrackIdentity(rhs.artist)
            && normalizedTrackIdentity(lhs.album) == normalizedTrackIdentity(rhs.album)
            && abs(lhs.duration - rhs.duration) <= 2.0
    }

    private static func normalizedTrackIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }
}

private final class NativeLyricsRowView: NSView {
    override var isFlipped: Bool { true }

    private let backgroundLayer = CALayer()
    private let mainTextLayer = CATextLayer()
    private let mainBrightTextLayer = CATextLayer()
    private let mainSweepMaskLayer = CAGradientLayer()
    private let mainPerRunSweepMaskLayer = CALayer()
    private let mainEmphasisLayer = CALayer()
    private let translationTextLayer = CATextLayer()
    private let translationBrightTextLayer = CATextLayer()
    private let translationSweepMaskLayer = CAGradientLayer()
    private let translationPerLineSweepMaskLayer = CALayer()
    private let interludeTextLayer = CATextLayer()
    private let dotContainerLayer = CALayer()
    private let dotLayers: [CALayer] = (0..<3).map { _ in CALayer() }
    private var trackingAreaRef: NSTrackingArea?
    private var row: LayerBackedLyricRow?
    private var configuration: LyricsLayerRendererConfiguration?
    private var isHovering = false
    private var mainPerRunSweepLineLayers: [CAGradientLayer] = []
    private var cachedMainSweepLayoutKey: SweepLayoutCacheKey?
    private var cachedMainSweepLinePlan: [NativeLyricsTextSweepVisualLinePlan] = []
    private var cachedTextGlyphGeometryBounds: CGRect?
    private var cachedTextGlyphGeometryMetrics: TextGlyphGeometryMetrics?
    private var cachedTranslationSweepLayoutKey: TranslationSweepLayoutCacheKey?
    private var cachedTranslationSweepLinePlan: [NativeLyricsTranslationSweepVisualLinePlan] = []
    private var translationSweepLineLayers: [CAGradientLayer] = []
    private var emphasisGlyphLayers: [CATextLayer] = []
    private var emphasisGlyphLayerSignatures: [EmphasisGlyphLayerSignature?] = []
    private var activeHiddenEmphasisSignature: String?
    private var lastLineLayoutMetrics = LineLayoutAppliedMetrics.inactive
    private let blurFilter = CIFilter(name: "CIGaussianBlur")
    private let dotBlurFilter = CIFilter(name: "CIGaussianBlur")
    private var appliedBlurRadius: CGFloat = -.greatestFiniteMagnitude
    private var appliedDotBlurRadius: CGFloat = -.greatestFiniteMagnitude
    private var lastHoverBackgroundVisible = false
    var onHoverChanged: ((Bool) -> Void)?
    var onHoverBackgroundVisible: (() -> Void)?
    var onTap: (() -> Void)?

    var displayIndex: Int { row?.index ?? -1 }
    var currentRow: LayerBackedLyricRow? { row }

    private static let hoverBackgroundAlpha: CGFloat = 0.08
    private static let hoverBackgroundCornerRadius: CGFloat = 12

    private struct SweepLayoutCacheKey: Equatable {
        let rowID: String
        let width: CGFloat
        let fontSize: CGFloat
        let fadeHalfPoint: CGFloat

        init(rowID: String?, plan: NativeLyricsTextRenderPlan, width: CGFloat) {
            self.rowID = rowID ?? plan.displayText
            self.width = width.rounded(.toNearestOrAwayFromZero)
            fontSize = plan.constants.mainFontSize
            fadeHalfPoint = plan.constants.fadeHalfPoint
        }
    }

    private struct TranslationSweepLayoutCacheKey: Equatable {
        let rowID: String
        let text: String
        let width: CGFloat
        let fontSize: CGFloat
        let lineSpacing: CGFloat

        init(rowID: String?, translation: NativeLyricsTranslationRenderPlan, constants: NativeLyricsTextConstants, width: CGFloat) {
            self.rowID = rowID ?? translation.text
            text = translation.text
            self.width = width.rounded(.toNearestOrAwayFromZero)
            fontSize = constants.translationFontSize
            lineSpacing = constants.translationLineSpacing
        }
    }

    private struct StaticTextPlanCacheKey: Equatable {
        let rowID: String
        let text: String
        let translation: String?
        let wordCount: Int
        let firstWordStart: TimeInterval?
        let lastWordEnd: TimeInterval?

        init(row: LayerBackedLyricRow) {
            let line = row.displayLine.line
            rowID = row.id
            text = line.text
            translation = line.translation
            wordCount = line.words.count
            firstWordStart = line.words.first?.startTime
            lastWordEnd = line.words.last?.endTime
        }
    }

    private struct EmphasisGlyphLayerSignature: Equatable {
        let text: String
        let width: CGFloat
        let height: CGFloat
        let fontSize: CGFloat

        init(glyph: NativeLyricsTextSweepVisualRun.Glyph, fontSize: CGFloat) {
            text = glyph.text
            width = glyph.rect.width.rounded(.toNearestOrAwayFromZero)
            height = glyph.rect.height.rounded(.toNearestOrAwayFromZero)
            self.fontSize = fontSize
        }
    }

    private var cachedStaticTextPlanKey: StaticTextPlanCacheKey?
    private var cachedStaticTextPlan: NativeLyricsStaticTextRenderPlan?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func configure(row: LayerBackedLyricRow, configuration: LyricsLayerRendererConfiguration) {
        self.row = row
        self.configuration = configuration
        wantsLayer = true
        updateTextLayers()
        updateHoverBackground()
        needsLayout = true
    }

    func refreshInteractionState(configuration: LyricsLayerRendererConfiguration) {
        self.configuration = configuration
        updateHoverBackground()
    }

    @discardableResult
    func applyBlurRadius(_ radius: CGFloat) -> CGFloat {
        let effectiveRadius = radius > 0.1 ? radius : 0
        let quantizedRadius = (effectiveRadius * 4).rounded(.toNearestOrAwayFromZero) / 4
        guard abs(appliedBlurRadius - quantizedRadius) > 0.001 else { return quantizedRadius }
        appliedBlurRadius = quantizedRadius
        guard quantizedRadius > 0 else {
            layer?.filters = nil
            return quantizedRadius
        }
        blurFilter?.setValue(Double(quantizedRadius), forKey: kCIInputRadiusKey)
        layer?.filters = blurFilter.map { [$0] }
        return quantizedRadius
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard let row, let configuration else { return 1 }
        let textWidth = max(1, width - nativeLyricContentLeadingInset - nativeLyricContentTrailingInset)
        if row.isPrelude {
            return 46
        }
        let plan = textRenderPlan(row: row, configuration: configuration)
        let mainHeight = measuredTextHeight(
            plan.displayText,
            width: textWidth,
            font: .systemFont(ofSize: plan.constants.mainFontSize, weight: .semibold)
        )
        var height = mainHeight + 16
        if let translation = plan.translation {
            height += plan.constants.mainFontSize * 0.33
            height += measuredTextHeight(
                translation.text,
                width: textWidth,
                font: .systemFont(ofSize: plan.constants.translationFontSize, weight: .semibold),
                lineSpacing: plan.constants.translationLineSpacing
            )
        } else if configuration.showTranslation && (configuration.isTranslating || configuration.translationFailed) {
            height += 22
        }
        if row.interlude != nil {
            height += 34
        }
        return ceil(height)
    }

    override func layout() {
        super.layout()
        guard let row, let configuration else { return }
        let textX = nativeLyricContentLeadingInset
        let textWidth = max(1, bounds.width - nativeLyricContentLeadingInset - nativeLyricContentTrailingInset)
        let plan = textRenderPlan(row: row, configuration: configuration)
        backgroundLayer.frame = Self.hoverBackgroundFrame(in: bounds)
        var y: CGFloat = 8
        if row.isPrelude {
            mainTextLayer.frame = .zero
            mainBrightTextLayer.frame = mainTextLayer.frame
            mainSweepMaskLayer.frame = mainBrightTextLayer.bounds
            mainPerRunSweepMaskLayer.frame = mainBrightTextLayer.bounds
            mainEmphasisLayer.frame = mainBrightTextLayer.frame
            translationTextLayer.frame = .zero
            translationBrightTextLayer.frame = .zero
            translationSweepMaskLayer.frame = .zero
            translationPerLineSweepMaskLayer.frame = .zero
            interludeTextLayer.frame = .zero
            layoutDotContainer(frame: CGRect(x: textX, y: y, width: textWidth, height: 30))
            lastLineLayoutMetrics = .inactive
            return
        }

        let mainHeight = measuredTextHeight(
            plan.displayText,
            width: textWidth,
            font: .systemFont(ofSize: plan.constants.mainFontSize, weight: .semibold)
        )
        mainTextLayer.frame = CGRect(x: textX, y: y, width: textWidth, height: mainHeight)
        mainBrightTextLayer.frame = mainTextLayer.frame
        mainSweepMaskLayer.frame = mainBrightTextLayer.bounds
        mainPerRunSweepMaskLayer.frame = mainBrightTextLayer.bounds
        mainEmphasisLayer.frame = mainBrightTextLayer.frame
        y += mainHeight
        var translationExpectedHeight: CGFloat = 0
        var translationFrameHeightError: CGFloat = 0
        var translationFrameWidthError: CGFloat = 0
        if let translation = plan.translation {
            y += plan.constants.mainFontSize * 0.33
            translationExpectedHeight = measuredTextHeight(
                translation.text,
                width: textWidth,
                font: .systemFont(ofSize: plan.constants.translationFontSize, weight: .semibold),
                lineSpacing: plan.constants.translationLineSpacing
            )
            translationTextLayer.frame = CGRect(x: textX, y: y, width: textWidth, height: translationExpectedHeight)
            translationBrightTextLayer.frame = translationTextLayer.frame
            translationSweepMaskLayer.frame = translationBrightTextLayer.bounds
            translationPerLineSweepMaskLayer.frame = translationBrightTextLayer.bounds
            translationFrameHeightError = abs(translationTextLayer.frame.height - translationExpectedHeight)
            translationFrameWidthError = abs(translationTextLayer.frame.width - textWidth)
            y += translationExpectedHeight
        } else {
            translationTextLayer.frame = .zero
            translationBrightTextLayer.frame = .zero
            translationSweepMaskLayer.frame = .zero
            translationPerLineSweepMaskLayer.frame = .zero
        }
        if row.interlude != nil {
            interludeTextLayer.frame = CGRect(x: textX, y: y + 8, width: 80, height: 24)
            layoutDotContainer(frame: interludeTextLayer.frame)
        } else {
            interludeTextLayer.frame = .zero
            hideDotLayers()
        }
        let mainFrameHeightError = abs(mainTextLayer.frame.height - mainHeight)
        let mainFrameWidthError = abs(mainTextLayer.frame.width - textWidth)
        lastLineLayoutMetrics = LineLayoutAppliedMetrics(
            sampleCount: 1,
            heightErrorMax: max(mainFrameHeightError, translationFrameHeightError),
            widthErrorMax: max(mainFrameWidthError, translationFrameWidthError),
            mainFrameHeightError: mainFrameHeightError,
            translationFrameHeightError: translationFrameHeightError
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = next
        addTrackingArea(next)
    }

    override func mouseEntered(with event: NSEvent) {
        setPointerHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerHovering(false)
    }

    override func mouseDown(with event: NSEvent) {
        if let onTap {
            onTap()
            return
        }
        super.mouseDown(with: event)
    }

    func setPointerHovering(_ hovering: Bool) {
        guard isHovering != hovering else {
            updateHoverBackground()
            return
        }
        isHovering = hovering
        updateHoverBackground()
        onHoverChanged?(hovering)
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        [
            backgroundLayer,
            mainTextLayer,
            mainBrightTextLayer,
            mainEmphasisLayer,
            translationTextLayer,
            translationBrightTextLayer,
            interludeTextLayer,
            dotContainerLayer
        ].forEach {
            $0.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            $0.masksToBounds = false
            layer?.addSublayer($0)
        }
        dotLayers.forEach { dot in
            dot.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            dot.cornerRadius = 4
            dot.backgroundColor = NSColor.white.cgColor
            dotContainerLayer.addSublayer(dot)
        }
        dotContainerLayer.isHidden = true
        mainBrightTextLayer.mask = mainSweepMaskLayer
        mainPerRunSweepMaskLayer.masksToBounds = false
        mainPerRunSweepMaskLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        mainEmphasisLayer.masksToBounds = false
        mainEmphasisLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        translationBrightTextLayer.mask = translationSweepMaskLayer
        translationPerLineSweepMaskLayer.masksToBounds = false
        translationPerLineSweepMaskLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        backgroundLayer.cornerRadius = Self.hoverBackgroundCornerRadius
        backgroundLayer.backgroundColor = NSColor.white.withAlphaComponent(Self.hoverBackgroundAlpha).cgColor
        backgroundLayer.isHidden = true
        [mainTextLayer, mainBrightTextLayer, translationTextLayer, translationBrightTextLayer, interludeTextLayer].forEach { textLayer in
            textLayer.isWrapped = true
            textLayer.alignmentMode = .left
            textLayer.truncationMode = .none
        }
        [mainSweepMaskLayer, translationSweepMaskLayer].forEach { mask in
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.clear.cgColor,
                NSColor.clear.cgColor
            ]
            mask.locations = [0, 0, 0, 1]
        }
    }

    private func updateTextLayers() {
        guard let row, let configuration else { return }
        if row.isPrelude {
            mainTextLayer.string = nil
            mainBrightTextLayer.string = nil
            hideEmphasisGlyphLayers()
            activeHiddenEmphasisSignature = nil
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            hideTranslationSweepMaskLayers()
            interludeTextLayer.string = nil
            dotContainerLayer.isHidden = false
            updatePlaybackPhase(configuration: configuration)
            return
        }

        let plan = textRenderPlan(row: row, configuration: configuration)
        let isActive = row.index == configuration.effectiveCurrentIndex && configuration.musicController.isPlaying
        let mainAlpha = isActive ? plan.constants.dimAlpha : (row.index == configuration.effectiveCurrentIndex ? 1 : 0.35)
        mainTextLayer.string = attributedText(
            plan.displayText,
            fontSize: plan.constants.mainFontSize,
            alpha: mainAlpha
        )
        mainBrightTextLayer.string = isActive
            ? attributedText(plan.displayText, fontSize: plan.constants.mainFontSize, alpha: plan.constants.brightAlpha)
            : nil
        activeHiddenEmphasisSignature = nil
        hideEmphasisGlyphLayers()
        if let translation = plan.translation {
            let translationBaseAlpha = isActive ? translation.dimAlpha : translation.opacity
            translationTextLayer.string = attributedText(
                translation.text,
                fontSize: plan.constants.translationFontSize,
                alpha: translationBaseAlpha,
                lineSpacing: plan.constants.translationLineSpacing
            )
            translationBrightTextLayer.string = isActive
                ? attributedText(
                    translation.text,
                    fontSize: plan.constants.translationFontSize,
                    alpha: translation.brightAlpha,
                    lineSpacing: plan.constants.translationLineSpacing
                )
                : nil
        } else if configuration.showTranslation && configuration.isTranslating {
            translationTextLayer.string = attributedText("•••", fontSize: 16, alpha: 0.45)
            translationBrightTextLayer.string = nil
            hideTranslationSweepMaskLayers()
        } else if configuration.showTranslation && configuration.translationFailed && row.index == configuration.effectiveCurrentIndex {
            translationTextLayer.string = attributedText("Translation unavailable", fontSize: 14, alpha: 0.3)
            translationBrightTextLayer.string = nil
            hideTranslationSweepMaskLayers()
        } else {
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            hideTranslationSweepMaskLayers()
        }
        interludeTextLayer.string = nil
        dotContainerLayer.isHidden = row.interlude == nil
        updatePlaybackPhase(configuration: configuration)
    }

    private func updateHoverBackground() {
        let visible = isHovering && configuration?.effectiveIsManualScrolling == true && row?.displayLine.line.text != "⋯"
        backgroundLayer.frame = Self.hoverBackgroundFrame(in: bounds)
        backgroundLayer.cornerRadius = Self.hoverBackgroundCornerRadius
        backgroundLayer.isHidden = !visible
        if visible && !lastHoverBackgroundVisible {
            onHoverBackgroundVisible?()
        }
        if visible {
            let alpha = NSColor(cgColor: backgroundLayer.backgroundColor ?? NSColor.clear.cgColor)?.alphaComponent
                ?? Self.hoverBackgroundAlpha
            (superview as? NativeLyricsSurfaceView)?.recordHoverBackgroundParity(NativeLyricsHoverParitySample(
                expectedFrame: Self.hoverBackgroundFrame(in: bounds),
                appliedFrame: backgroundLayer.frame,
                expectedCornerRadius: Self.hoverBackgroundCornerRadius,
                appliedCornerRadius: backgroundLayer.cornerRadius,
                expectedAlpha: Self.hoverBackgroundAlpha,
                appliedAlpha: alpha
            ))
        }
        lastHoverBackgroundVisible = visible
    }

    private static func hoverBackgroundFrame(in bounds: CGRect) -> CGRect {
        let x = nativeLyricContentLeadingInset - 8
        let width = max(1, bounds.width - nativeLyricContentLeadingInset - nativeLyricContentTrailingInset + 16)
        return CGRect(x: x, y: 0, width: width, height: max(1, bounds.height))
    }

    @discardableResult
    func updatePlaybackPhase(
        configuration: LyricsLayerRendererConfiguration,
        managesTransaction: Bool = true
    ) -> NativeLyricsTextPhaseSample? {
        guard let row else { return nil }
        let renderTime = configuration.musicController.lyricRenderTime()
        let isActive = row.index == configuration.effectiveCurrentIndex && configuration.musicController.isPlaying

        var sample: NativeLyricsTextPhaseSample?
        if managesTransaction {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        if isActive {
            let plan = textRenderPlan(
                row: row,
                configuration: configuration,
                currentTime: renderTime
            )
            let appliedMainProgress = applyActiveMainPhase(plan: plan, currentTime: renderTime)
            let appliedTranslation = applyActiveTranslationPhase(plan: plan)
            let expectsPerRunSweep = row.displayLine.line.hasSyllableSync && !plan.wordRuns.isEmpty
            let expectsPerGlyphEmphasis = plan.wordRuns.contains { run in
                run.isEmphasis || run.emphasis != .inactive
            }
            if !expectsPerRunSweep || (mainBrightTextLayer.bounds.width > 1 && mainBrightTextLayer.bounds.height > 1) {
                sample = NativeLyricsTextPhaseSample(
                    hasSyllableSync: row.displayLine.line.hasSyllableSync,
                    wordRunCount: plan.wordRuns.count,
                    cjkWordRunCount: plan.wordRuns.filter(\.isCJK).count,
                    cjkEmphasisGlyphCount: plan.wordRuns.filter { $0.isCJK && ($0.isEmphasis || $0.emphasis != .inactive) }.count,
                    mainExpectedProgress: plan.mainSweepProgress,
                    mainAppliedProgress: appliedMainProgress.progress,
                    translationExpectedProgress: plan.translation?.progress,
                    translationAppliedProgress: appliedTranslation?.progress,
                    expectsPerRunSweep: expectsPerRunSweep,
                    appliesPerRunSweep: appliedMainProgress.appliedPerRunSweep,
                    expectsPerGlyphEmphasis: expectsPerGlyphEmphasis,
                    appliesPerGlyphEmphasis: appliedMainProgress.appliedPerGlyphEmphasis,
                    expectedEmphasisGlyphCount: appliedMainProgress.expectedEmphasisGlyphCount,
                    appliedEmphasisGlyphCount: appliedMainProgress.appliedEmphasisGlyphCount,
                    appliedEmphasisGlyphMotionCount: appliedMainProgress.appliedEmphasisGlyphMotionCount,
                    maxAppliedEmphasisScale: appliedMainProgress.maxAppliedEmphasisScale,
                    maxAppliedEmphasisLiftMagnitude: appliedMainProgress.maxAppliedEmphasisLiftMagnitude,
                    maxAppliedEmphasisGlowOpacity: appliedMainProgress.maxAppliedEmphasisGlowOpacity,
                    maxAppliedEmphasisAlpha: appliedMainProgress.maxAppliedEmphasisAlpha,
                    textLayoutCoverageGapCount: appliedMainProgress.textLayoutCoverageGapCount,
                    expectedSweepLineCount: appliedMainProgress.expectedSweepLineCount,
                    appliedSweepLineCount: appliedMainProgress.appliedSweepLineCount,
                    sweepLineCoverageGapCount: appliedMainProgress.sweepLineCoverageGapCount,
                    sweepWavefrontErrorMax: appliedMainProgress.sweepWavefrontErrorMax,
                    emphasisGlyphPositionSampleCount: appliedMainProgress.emphasisGlyphPositionSampleCount,
                    emphasisGlyphPositionErrorMax: appliedMainProgress.emphasisGlyphPositionErrorMax,
                    emphasisGlyphScaleErrorMax: appliedMainProgress.emphasisGlyphScaleErrorMax,
                    emphasisGlyphAlphaErrorMax: appliedMainProgress.emphasisGlyphAlphaErrorMax,
                    emphasisGlyphGlowErrorMax: appliedMainProgress.emphasisGlyphGlowErrorMax,
                    textGlyphGeometrySampleCount: appliedMainProgress.textGlyphGeometrySampleCount,
                    textGlyphGeometryCoverageGapCount: appliedMainProgress.textGlyphGeometryCoverageGapCount,
                    textGlyphGeometryPositionErrorMax: appliedMainProgress.textGlyphGeometryPositionErrorMax,
                    translationSweepLineSampleCount: appliedTranslation?.appliedLineCount ?? 0,
                    translationSweepLineCoverageGapCount: appliedTranslation?.coverageGapCount ?? 0,
                    translationSweepWavefrontErrorMax: appliedTranslation?.wavefrontErrorMax ?? 0,
                    lineLayoutSampleCount: appliedMainProgress.lineLayoutSampleCount,
                    lineLayoutHeightErrorMax: appliedMainProgress.lineLayoutHeightErrorMax,
                    lineLayoutWidthErrorMax: appliedMainProgress.lineLayoutWidthErrorMax,
                    mainTextFrameHeightErrorMax: appliedMainProgress.mainTextFrameHeightErrorMax,
                    translationTextFrameHeightErrorMax: appliedMainProgress.translationTextFrameHeightErrorMax
                )
            }
        } else {
            mainBrightTextLayer.isHidden = true
            mainBrightTextLayer.mask = mainSweepMaskLayer
            hidePerRunSweepMaskLayers()
            hideEmphasisGlyphLayers()
            activeHiddenEmphasisSignature = nil
            translationBrightTextLayer.isHidden = true
            hideTranslationSweepMaskLayers()
            mainTextLayer.setAffineTransform(.identity)
            mainBrightTextLayer.setAffineTransform(.identity)
            clearEmphasis(from: mainBrightTextLayer)
        }
        updateDotsPhase(row: row, currentTime: renderTime)
        if managesTransaction {
            CATransaction.commit()
        }
        return sample
    }

    private func applyActiveMainPhase(
        plan: NativeLyricsTextRenderPlan,
        currentTime: TimeInterval
    ) -> (
        progress: CGFloat,
        appliedPerRunSweep: Bool,
        appliedPerGlyphEmphasis: Bool,
        expectedEmphasisGlyphCount: Int,
        appliedEmphasisGlyphCount: Int,
        appliedEmphasisGlyphMotionCount: Int,
        maxAppliedEmphasisScale: CGFloat,
        maxAppliedEmphasisLiftMagnitude: CGFloat,
        maxAppliedEmphasisGlowOpacity: CGFloat,
        maxAppliedEmphasisAlpha: CGFloat,
        textLayoutCoverageGapCount: Int,
        expectedSweepLineCount: Int,
        appliedSweepLineCount: Int,
        sweepLineCoverageGapCount: Int,
        sweepWavefrontErrorMax: CGFloat,
        emphasisGlyphPositionSampleCount: Int,
        emphasisGlyphPositionErrorMax: CGFloat,
        emphasisGlyphScaleErrorMax: CGFloat,
        emphasisGlyphAlphaErrorMax: CGFloat,
        emphasisGlyphGlowErrorMax: CGFloat,
        textGlyphGeometrySampleCount: Int,
        textGlyphGeometryCoverageGapCount: Int,
        textGlyphGeometryPositionErrorMax: CGFloat,
        lineLayoutSampleCount: Int,
        lineLayoutHeightErrorMax: CGFloat,
        lineLayoutWidthErrorMax: CGFloat,
        mainTextFrameHeightErrorMax: CGFloat,
        translationTextFrameHeightErrorMax: CGFloat
    ) {
        let activeRun = plan.wordRuns.last { $0.startTime <= currentTime }
            ?? plan.wordRuns.first
        let y = activeRun?.baseFloatY ?? 0
        mainTextLayer.setAffineTransform(CGAffineTransform(translationX: 0, y: y))
        mainBrightTextLayer.setAffineTransform(CGAffineTransform(translationX: 0, y: y))
        mainBrightTextLayer.opacity = Float(plan.mainPostLineFade)
        mainBrightTextLayer.isHidden = plan.mainSweepProgress <= 0.001 || plan.mainPostLineFade <= 0.001
        let linePlan = mainSweepLinePlan(for: plan, bounds: mainBrightTextLayer.bounds)
        let sweepResult = updatePerRunSweepMask(
            plan: plan,
            currentTime: currentTime,
            bounds: mainBrightTextLayer.bounds,
            linePlan: linePlan
        )
        let appliedProgress: CGFloat
        if sweepResult.applied {
            appliedProgress = plan.mainSweepProgress
        } else {
            mainBrightTextLayer.mask = mainSweepMaskLayer
            hidePerRunSweepMaskLayers()
            appliedProgress = updateSweepMask(
                mainSweepMaskLayer,
                progress: plan.mainSweepProgress,
                fadeHalfPoint: plan.constants.fadeHalfPoint,
                bounds: mainBrightTextLayer.bounds
            )
        }
        if let activeRun, activeRun.emphasis.glowOpacity > 0 {
            mainBrightTextLayer.shadowColor = NSColor.white.cgColor
            mainBrightTextLayer.shadowOpacity = Float(min(1, activeRun.emphasis.glowOpacity))
            mainBrightTextLayer.shadowRadius = activeRun.emphasis.glowRadius
            mainBrightTextLayer.shadowOffset = CGSize(width: 0, height: activeRun.emphasis.liftY + activeRun.emphasis.floatY)
        } else {
            clearEmphasis(from: mainBrightTextLayer)
        }
        let emphasisResult = applyEmphasisGlyphLayers(
            plan: plan,
            currentTime: currentTime,
            linePlan: linePlan
        )
        let glyphGeometryResult = textGlyphGeometryMetrics(
            plan: plan,
            linePlan: linePlan,
            bounds: mainBrightTextLayer.bounds
        )
        let layoutResult = lastLineLayoutMetrics
        return (
            appliedProgress,
            sweepResult.applied,
            emphasisResult.applied,
            emphasisResult.expectedGlyphCount,
            emphasisResult.appliedGlyphCount,
            emphasisResult.appliedMotionGlyphCount,
            emphasisResult.maxScale,
            emphasisResult.maxLiftMagnitude,
            emphasisResult.maxGlowOpacity,
            emphasisResult.maxAlpha,
            emphasisResult.layoutCoverageGapCount,
            sweepResult.expectedLineCount,
            sweepResult.appliedLineCount,
            sweepResult.coverageGapCount,
            sweepResult.wavefrontErrorMax,
            emphasisResult.positionSampleCount,
            emphasisResult.positionErrorMax,
            emphasisResult.scaleErrorMax,
            emphasisResult.alphaErrorMax,
            emphasisResult.glowErrorMax,
            glyphGeometryResult.sampleCount,
            glyphGeometryResult.coverageGapCount,
            glyphGeometryResult.positionErrorMax,
            layoutResult.sampleCount,
            layoutResult.heightErrorMax,
            layoutResult.widthErrorMax,
            layoutResult.mainFrameHeightError,
            layoutResult.translationFrameHeightError
        )
    }

    private struct TranslationSweepAppliedMetrics {
        let progress: CGFloat
        let expectedLineCount: Int
        let appliedLineCount: Int
        let coverageGapCount: Int
        let wavefrontErrorMax: CGFloat
    }

    private func applyActiveTranslationPhase(plan: NativeLyricsTextRenderPlan) -> TranslationSweepAppliedMetrics? {
        guard let translation = plan.translation else {
            translationBrightTextLayer.isHidden = true
            return nil
        }
        translationBrightTextLayer.opacity = Float(translation.postLineFade)
        translationBrightTextLayer.isHidden = translation.progress <= 0.001 || translation.postLineFade <= 0.001
        return updateTranslationSweepMask(
            translation: translation,
            constants: plan.constants,
            bounds: translationBrightTextLayer.bounds
        )
    }

    private struct LineLayoutAppliedMetrics {
        let sampleCount: Int
        let heightErrorMax: CGFloat
        let widthErrorMax: CGFloat
        let mainFrameHeightError: CGFloat
        let translationFrameHeightError: CGFloat

        static let inactive = LineLayoutAppliedMetrics(
            sampleCount: 0,
            heightErrorMax: 0,
            widthErrorMax: 0,
            mainFrameHeightError: 0,
            translationFrameHeightError: 0
        )
    }

    private struct PerRunSweepAppliedMetrics {
        let applied: Bool
        let expectedLineCount: Int
        let appliedLineCount: Int
        let coverageGapCount: Int
        let wavefrontErrorMax: CGFloat

        static let inactive = PerRunSweepAppliedMetrics(
            applied: false,
            expectedLineCount: 0,
            appliedLineCount: 0,
            coverageGapCount: 0,
            wavefrontErrorMax: 0
        )
    }

    private func updatePerRunSweepMask(
        plan: NativeLyricsTextRenderPlan,
        currentTime: TimeInterval,
        bounds: CGRect,
        linePlan: [NativeLyricsTextSweepVisualLinePlan]
    ) -> PerRunSweepAppliedMetrics {
        guard !plan.wordRuns.isEmpty, bounds.width > 1, bounds.height > 1 else { return .inactive }
        let lines = NativeLyricsTextSweepLayout.maskLines(
            from: linePlan,
            fadeHalfPoint: plan.constants.fadeHalfPoint,
            currentTime: currentTime
        )
        guard !lines.isEmpty else {
            return PerRunSweepAppliedMetrics(
                applied: false,
                expectedLineCount: linePlan.count,
                appliedLineCount: 0,
                coverageGapCount: linePlan.count,
                wavefrontErrorMax: 0
            )
        }

        mainBrightTextLayer.mask = mainPerRunSweepMaskLayer
        mainPerRunSweepMaskLayer.frame = bounds
        ensurePerRunSweepMaskLayerCount(lines.count)
        var maxWavefrontError: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let maskLayer = mainPerRunSweepLineLayers[index]
            maskLayer.isHidden = false
            maskLayer.frame = line.maskRect
            let expectedLocalWavefront = line.wavefrontX - line.maskRect.minX
            let appliedLocalWavefront = applySweepGradient(
                maskLayer,
                wavefrontX: expectedLocalWavefront,
                fadeHalfPoint: plan.constants.fadeHalfPoint,
                width: line.maskRect.width
            )
            if expectedLocalWavefront >= plan.constants.fadeHalfPoint,
               expectedLocalWavefront <= line.maskRect.width - plan.constants.fadeHalfPoint {
                maxWavefrontError = max(maxWavefrontError, abs(appliedLocalWavefront - expectedLocalWavefront))
            }
        }
        for index in lines.count..<mainPerRunSweepLineLayers.count {
            mainPerRunSweepLineLayers[index].isHidden = true
        }
        return PerRunSweepAppliedMetrics(
            applied: true,
            expectedLineCount: linePlan.count,
            appliedLineCount: lines.count,
            coverageGapCount: max(0, linePlan.count - lines.count),
            wavefrontErrorMax: maxWavefrontError
        )
    }

    private func updateTranslationSweepMask(
        translation: NativeLyricsTranslationRenderPlan,
        constants: NativeLyricsTextConstants,
        bounds: CGRect
    ) -> TranslationSweepAppliedMetrics {
        guard bounds.width > 1, bounds.height > 1 else {
            hideTranslationSweepMaskLayers()
            return TranslationSweepAppliedMetrics(
                progress: translation.progress,
                expectedLineCount: 0,
                appliedLineCount: 0,
                coverageGapCount: translation.text.isEmpty ? 0 : 1,
                wavefrontErrorMax: 0
            )
        }
        let linePlan = translationSweepLinePlan(
            for: translation,
            constants: constants,
            bounds: bounds
        )
        let lines = NativeLyricsTranslationSweepLayout.maskLines(
            from: linePlan,
            progress: translation.progress,
            fadeHalfPoint: translation.fadeHalfPoint
        )
        guard !lines.isEmpty else {
            translationBrightTextLayer.mask = translationSweepMaskLayer
            hideTranslationSweepMaskLayers()
            let applied = updateSweepMask(
                translationSweepMaskLayer,
                progress: translation.progress,
                fadeHalfPoint: translation.fadeHalfPoint,
                bounds: bounds
            )
            return TranslationSweepAppliedMetrics(
                progress: applied,
                expectedLineCount: linePlan.count,
                appliedLineCount: 0,
                coverageGapCount: linePlan.count,
                wavefrontErrorMax: 0
            )
        }

        translationBrightTextLayer.mask = translationPerLineSweepMaskLayer
        translationPerLineSweepMaskLayer.frame = bounds
        ensureTranslationSweepMaskLayerCount(lines.count)
        var maxWavefrontError: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let maskLayer = translationSweepLineLayers[index]
            maskLayer.isHidden = false
            maskLayer.frame = line.maskRect
            let expectedLocalWavefront = line.wavefrontX - line.maskRect.minX
            let appliedLocalWavefront = applySweepGradient(
                maskLayer,
                wavefrontX: expectedLocalWavefront,
                fadeHalfPoint: translation.fadeHalfPoint,
                width: line.maskRect.width
            )
            if expectedLocalWavefront >= translation.fadeHalfPoint,
               expectedLocalWavefront <= line.maskRect.width - translation.fadeHalfPoint {
                maxWavefrontError = max(maxWavefrontError, abs(appliedLocalWavefront - expectedLocalWavefront))
            }
        }
        for index in lines.count..<translationSweepLineLayers.count {
            translationSweepLineLayers[index].isHidden = true
        }
        return TranslationSweepAppliedMetrics(
            progress: translation.progress,
            expectedLineCount: linePlan.count,
            appliedLineCount: lines.count,
            coverageGapCount: max(0, linePlan.count - lines.count),
            wavefrontErrorMax: maxWavefrontError
        )
    }

    private func translationSweepLinePlan(
        for translation: NativeLyricsTranslationRenderPlan,
        constants: NativeLyricsTextConstants,
        bounds: CGRect
    ) -> [NativeLyricsTranslationSweepVisualLinePlan] {
        let key = TranslationSweepLayoutCacheKey(
            rowID: row?.id,
            translation: translation,
            constants: constants,
            width: bounds.width
        )
        if cachedTranslationSweepLayoutKey == key {
            return cachedTranslationSweepLinePlan
        }
        let plan = NativeLyricsTranslationSweepLayout.makePlan(
            text: translation.text,
            width: bounds.width,
            fontSize: constants.translationFontSize,
            lineSpacing: constants.translationLineSpacing
        )
        cachedTranslationSweepLayoutKey = key
        cachedTranslationSweepLinePlan = plan
        return plan
    }

    private struct TextGlyphGeometryMetrics {
        let sampleCount: Int
        let coverageGapCount: Int
        let positionErrorMax: CGFloat
    }

    private func textGlyphGeometryMetrics(
        plan: NativeLyricsTextRenderPlan,
        linePlan: [NativeLyricsTextSweepVisualLinePlan],
        bounds: CGRect
    ) -> TextGlyphGeometryMetrics {
        if cachedTextGlyphGeometryBounds == bounds, let cachedTextGlyphGeometryMetrics {
            return cachedTextGlyphGeometryMetrics
        }
        let expectedGlyphCount = plan.wordRuns.reduce(0) { partial, run in
            partial + max(0, (run.text as NSString).length)
        }
        let visualRuns = linePlan.flatMap(\.runs)
        let appliedGlyphCount = visualRuns.reduce(0) { $0 + $1.glyphs.count }
        let missingRunCount = max(0, plan.wordRuns.count - Set(visualRuns.map(\.order)).count)
        var positionErrorMax: CGFloat = 0
        for visualRun in visualRuns {
            for glyph in visualRun.glyphs {
                let overflow = max(
                    max(0, -glyph.rect.minX),
                    max(0, glyph.rect.maxX - bounds.width),
                    max(0, -glyph.rect.minY),
                    max(0, glyph.rect.maxY - bounds.height)
                )
                let containmentError = visualRun.rect.insetBy(dx: -0.5, dy: -0.5).contains(glyph.rect)
                    ? 0
                    : 0.5
                positionErrorMax = max(positionErrorMax, overflow, containmentError)
            }
        }
        let metrics = TextGlyphGeometryMetrics(
            sampleCount: appliedGlyphCount,
            coverageGapCount: missingRunCount + max(0, expectedGlyphCount - appliedGlyphCount),
            positionErrorMax: positionErrorMax
        )
        cachedTextGlyphGeometryBounds = bounds
        cachedTextGlyphGeometryMetrics = metrics
        return metrics
    }

    private func applyEmphasisGlyphLayers(
        plan: NativeLyricsTextRenderPlan,
        currentTime: TimeInterval,
        linePlan: [NativeLyricsTextSweepVisualLinePlan]
    ) -> (
        applied: Bool,
        expectedGlyphCount: Int,
        appliedGlyphCount: Int,
        appliedMotionGlyphCount: Int,
        maxScale: CGFloat,
        maxLiftMagnitude: CGFloat,
        maxGlowOpacity: CGFloat,
        maxAlpha: CGFloat,
        layoutCoverageGapCount: Int,
        positionSampleCount: Int,
        positionErrorMax: CGFloat,
        scaleErrorMax: CGFloat,
        alphaErrorMax: CGFloat,
        glowErrorMax: CGFloat
    ) {
        let emphasisOrders = Set(plan.wordRuns.enumerated().compactMap { order, run in
            (run.isEmphasis || run.emphasis != .inactive) ? order : nil
        })
        guard !emphasisOrders.isEmpty else {
            restoreMainTextIfNeeded(plan: plan)
            hideEmphasisGlyphLayers()
            return (false, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        }

        applyHiddenEmphasisText(plan: plan, hiddenOrders: emphasisOrders)

        var glyphInputs: [(NativeLyricsTextSweepVisualRun, NativeLyricsWordRunPlan, CGFloat)] = []
        glyphInputs.reserveCapacity(emphasisOrders.count)
        for line in linePlan {
            let wavefront = NativeLyricsTextSweepLayout.wavefrontX(
                for: line,
                fadeHalfPoint: plan.constants.fadeHalfPoint,
                currentTime: currentTime
            )
            for visualRun in line.runs where emphasisOrders.contains(visualRun.order) {
                guard visualRun.order < plan.wordRuns.count else { continue }
                glyphInputs.append((visualRun, plan.wordRuns[visualRun.order], wavefront))
            }
        }

        let expectedGlyphCount = plan.wordRuns.enumerated().reduce(0) { partial, item in
            emphasisOrders.contains(item.offset)
                ? partial + max(1, (item.element.text as NSString).length)
                : partial
        }
        let appliedGlyphCount = glyphInputs.reduce(0) { $0 + $1.0.glyphs.count }
        let missingRunCount = emphasisOrders.subtracting(glyphInputs.map(\.0.order)).count
        let layoutCoverageGapCount = missingRunCount + max(0, expectedGlyphCount - appliedGlyphCount)
        guard appliedGlyphCount > 0 else {
            hideEmphasisGlyphLayers()
            return (false, expectedGlyphCount, 0, 0, 1, 0, 0, 0, layoutCoverageGapCount, 0, 0, 0, 0, 0)
        }

        ensureEmphasisGlyphLayerCount(appliedGlyphCount)
        var layerIndex = 0
        var appliedMotionGlyphCount = 0
        var maxScale: CGFloat = 1
        var maxLiftMagnitude: CGFloat = 0
        var maxGlowOpacity: CGFloat = 0
        var maxAlpha: CGFloat = 0
        var maxPositionError: CGFloat = 0
        var maxScaleError: CGFloat = 0
        var maxAlphaError: CGFloat = 0
        var maxGlowError: CGFloat = 0
        for (visualRun, run, wavefront) in glyphInputs {
            let glyphCount = max(1, visualRun.glyphs.count)
            let duration = max(0, run.endTime - run.startTime)
            let du = max(1.0, duration) * (visualRun.order == plan.wordRuns.count - 1 ? 1.2 : 1.0)
            for glyph in visualRun.glyphs {
                let layer = emphasisGlyphLayers[layerIndex]
                let currentLayerIndex = layerIndex
                layerIndex += 1
                let metrics = applyEmphasisGlyph(
                    layer,
                    layerIndex: currentLayerIndex,
                    glyph: glyph,
                    run: run,
                    glyphCount: glyphCount,
                    du: du,
                    wavefrontX: wavefront,
                    fadeHalfPoint: plan.constants.fadeHalfPoint,
                    brightAlpha: plan.constants.brightAlpha * plan.mainPostLineFade,
                    dimAlpha: plan.constants.dimAlpha,
                    currentTime: currentTime
                )
                if metrics.hasMotion {
                    appliedMotionGlyphCount += 1
                }
                maxScale = max(maxScale, metrics.scale)
                maxLiftMagnitude = max(maxLiftMagnitude, metrics.liftMagnitude)
                maxGlowOpacity = max(maxGlowOpacity, metrics.glowOpacity)
                maxAlpha = max(maxAlpha, metrics.alpha)
                maxPositionError = max(maxPositionError, metrics.positionError)
                maxScaleError = max(maxScaleError, metrics.scaleError)
                maxAlphaError = max(maxAlphaError, metrics.alphaError)
                maxGlowError = max(maxGlowError, metrics.glowError)
            }
        }
        for index in layerIndex..<emphasisGlyphLayers.count {
            emphasisGlyphLayers[index].isHidden = true
        }
        return (
            true,
            expectedGlyphCount,
            appliedGlyphCount,
            appliedMotionGlyphCount,
            maxScale,
            maxLiftMagnitude,
            maxGlowOpacity,
            maxAlpha,
            layoutCoverageGapCount,
            appliedGlyphCount,
            maxPositionError,
            maxScaleError,
            maxAlphaError,
            maxGlowError
        )
    }

    private func applyHiddenEmphasisText(
        plan: NativeLyricsTextRenderPlan,
        hiddenOrders: Set<Int>
    ) {
        let signature = "\(plan.displayText)|\(hiddenOrders.sorted().map(String.init).joined(separator: ","))"
        guard activeHiddenEmphasisSignature != signature else { return }
        activeHiddenEmphasisSignature = signature
        mainTextLayer.string = attributedText(
            plan.displayText,
            fontSize: plan.constants.mainFontSize,
            alpha: plan.constants.dimAlpha,
            hiddenOrders: hiddenOrders,
            wordRuns: plan.wordRuns
        )
        mainBrightTextLayer.string = attributedText(
            plan.displayText,
            fontSize: plan.constants.mainFontSize,
            alpha: plan.constants.brightAlpha,
            hiddenOrders: hiddenOrders,
            wordRuns: plan.wordRuns
        )
    }

    private func restoreMainTextIfNeeded(plan: NativeLyricsTextRenderPlan) {
        guard activeHiddenEmphasisSignature != nil else { return }
        activeHiddenEmphasisSignature = nil
        mainTextLayer.string = attributedText(
            plan.displayText,
            fontSize: plan.constants.mainFontSize,
            alpha: plan.constants.dimAlpha
        )
        mainBrightTextLayer.string = attributedText(
            plan.displayText,
            fontSize: plan.constants.mainFontSize,
            alpha: plan.constants.brightAlpha
        )
    }

    private func ensureEmphasisGlyphLayerCount(_ count: Int) {
        guard emphasisGlyphLayers.count < count else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        while emphasisGlyphLayers.count < count {
            let layer = CATextLayer()
            layer.contentsScale = scale
            layer.font = NSFont.systemFont(ofSize: NativeLyricsTextConstants().mainFontSize, weight: .semibold)
            layer.fontSize = NativeLyricsTextConstants().mainFontSize
            layer.isWrapped = false
            layer.alignmentMode = .center
            layer.truncationMode = .none
            layer.masksToBounds = false
            mainEmphasisLayer.addSublayer(layer)
            emphasisGlyphLayers.append(layer)
            emphasisGlyphLayerSignatures.append(nil)
        }
    }

    private func hideEmphasisGlyphLayers() {
        for layer in emphasisGlyphLayers {
            layer.isHidden = true
            layer.shadowOpacity = 0
            layer.setAffineTransform(.identity)
        }
    }

    private struct EmphasisGlyphAppliedMetrics {
        let scale: CGFloat
        let liftMagnitude: CGFloat
        let glowOpacity: CGFloat
        let alpha: CGFloat
        let positionError: CGFloat
        let scaleError: CGFloat
        let alphaError: CGFloat
        let glowError: CGFloat

        var hasMotion: Bool {
            scale > 1.001 || liftMagnitude > 0.001 || glowOpacity > 0.001
        }
    }

    private struct EmphasisGlyphExpectedMetrics {
        let position: CGPoint
        let scale: CGFloat
        let liftMagnitude: CGFloat
        let glowOpacity: CGFloat
        let alpha: CGFloat
        let shadowRadius: CGFloat
    }

    private func applyEmphasisGlyph(
        _ layer: CATextLayer,
        layerIndex: Int,
        glyph: NativeLyricsTextSweepVisualRun.Glyph,
        run: NativeLyricsWordRunPlan,
        glyphCount: Int,
        du: TimeInterval,
        wavefrontX: CGFloat,
        fadeHalfPoint: CGFloat,
        brightAlpha: CGFloat,
        dimAlpha: CGFloat,
        currentTime: TimeInterval
    ) -> EmphasisGlyphAppliedMetrics {
        let expected = expectedEmphasisGlyphMetrics(
            glyph: glyph,
            run: run,
            glyphCount: glyphCount,
            du: du,
            wavefrontX: wavefrontX,
            fadeHalfPoint: fadeHalfPoint,
            brightAlpha: brightAlpha,
            dimAlpha: dimAlpha,
            currentTime: currentTime
        )
        layer.isHidden = false
        let fontSize = NativeLyricsTextConstants().mainFontSize
        let signature = EmphasisGlyphLayerSignature(glyph: glyph, fontSize: fontSize)
        if emphasisGlyphLayerSignatures.indices.contains(layerIndex),
           emphasisGlyphLayerSignatures[layerIndex] != signature {
            emphasisGlyphLayerSignatures[layerIndex] = signature
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            layer.fontSize = fontSize
            layer.string = glyph.text
            layer.bounds = CGRect(origin: .zero, size: glyph.rect.size)
        } else if layer.string == nil {
            layer.string = glyph.text
            layer.bounds = CGRect(origin: .zero, size: glyph.rect.size)
        }
        layer.foregroundColor = NSColor.white.withAlphaComponent(expected.alpha).cgColor
        layer.position = expected.position
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.setAffineTransform(CGAffineTransform(scaleX: expected.scale, y: expected.scale))

        if expected.glowOpacity > 0 {
            layer.shadowColor = NSColor.white.cgColor
            layer.shadowOpacity = Float(min(1, expected.glowOpacity))
            layer.shadowRadius = expected.shadowRadius
            layer.shadowOffset = .zero
        } else {
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
            layer.shadowOffset = .zero
        }

        let appliedTransform = layer.affineTransform()
        let appliedScale = sqrt(appliedTransform.a * appliedTransform.a + appliedTransform.c * appliedTransform.c)
        let appliedAlpha = cgColorAlpha(from: layer.foregroundColor) ?? expected.alpha
        let appliedGlowOpacity = CGFloat(layer.shadowOpacity)
        return EmphasisGlyphAppliedMetrics(
            scale: appliedScale,
            liftMagnitude: expected.liftMagnitude,
            glowOpacity: appliedGlowOpacity,
            alpha: appliedAlpha,
            positionError: hypot(layer.position.x - expected.position.x, layer.position.y - expected.position.y),
            scaleError: abs(appliedScale - expected.scale),
            alphaError: abs(appliedAlpha - expected.alpha),
            glowError: abs(appliedGlowOpacity - min(1, expected.glowOpacity))
        )
    }

    private func expectedEmphasisGlyphMetrics(
        glyph: NativeLyricsTextSweepVisualRun.Glyph,
        run: NativeLyricsWordRunPlan,
        glyphCount: Int,
        du: TimeInterval,
        wavefrontX: CGFloat,
        fadeHalfPoint: CGFloat,
        brightAlpha: CGFloat,
        dimAlpha: CGFloat,
        currentTime: TimeInterval
    ) -> EmphasisGlyphExpectedMetrics {
        let charDelay = (du / 2.5 / Double(max(1, glyphCount))) * Double(glyph.index)
        let t1 = CGFloat(min(1, max(0, (currentTime - run.startTime - charDelay) / du)))
        let easing = NativeLyricsEasing.emphasis(t1)
        let scale = 1 + easing * 0.1 * run.emphasis.amount
        let relativeIndex = CGFloat(glyphCount) / 2 - CGFloat(glyph.index)
        let spreadX = -easing * 0.03 * run.emphasis.amount * relativeIndex * 24
        let floatDu = du * 1.4
        let floatDelay = max(0, charDelay - 0.4)
        let t2 = CGFloat(min(1, max(0, (currentTime - run.startTime - floatDelay) / floatDu)))
        let charFloat: CGFloat = (t2 > 0 && t2 < 1) ? -sin(t2 * .pi) * 1.2 : 0
        let liftY = -easing * 0.6 * run.emphasis.amount
        let left = wavefrontX - fadeHalfPoint
        let right = wavefrontX + fadeHalfPoint
        let brightWeight: CGFloat
        if glyph.rect.midX <= left {
            brightWeight = 1
        } else if glyph.rect.midX >= right {
            brightWeight = 0
        } else {
            brightWeight = (right - glyph.rect.midX) / max(1, right - left)
        }
        let alpha = dimAlpha + (max(dimAlpha, brightAlpha) - dimAlpha) * min(1, max(0, brightWeight))
        let glowOpacity = easing * run.emphasis.blurLevel
        return EmphasisGlyphExpectedMetrics(
            position: CGPoint(
                x: glyph.rect.midX + spreadX,
                y: glyph.rect.midY + run.baseFloatY + charFloat + liftY
            ),
            scale: scale,
            liftMagnitude: abs(charFloat + liftY),
            glowOpacity: glowOpacity,
            alpha: alpha,
            shadowRadius: min(0.3 * 24, run.emphasis.blurLevel * 0.3 * 24)
        )
    }

    private func cgColorAlpha(from value: CGColor?) -> CGFloat? {
        value?.alpha
    }

    private func mainSweepLinePlan(
        for plan: NativeLyricsTextRenderPlan,
        bounds: CGRect
    ) -> [NativeLyricsTextSweepVisualLinePlan] {
        let key = SweepLayoutCacheKey(rowID: row?.id, plan: plan, width: bounds.width)
        if cachedMainSweepLayoutKey == key {
            return cachedMainSweepLinePlan
        }
        let linePlan = NativeLyricsTextSweepLayout.makePlan(
            displayText: plan.displayText,
            wordRuns: plan.wordRuns,
            width: bounds.width,
            fontSize: plan.constants.mainFontSize,
            fadeHalfPoint: plan.constants.fadeHalfPoint
        )
        cachedMainSweepLayoutKey = key
        cachedMainSweepLinePlan = linePlan
        cachedTextGlyphGeometryBounds = nil
        cachedTextGlyphGeometryMetrics = nil
        return linePlan
    }

    private func ensurePerRunSweepMaskLayerCount(_ count: Int) {
        guard mainPerRunSweepLineLayers.count < count else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        while mainPerRunSweepLineLayers.count < count {
            let layer = CAGradientLayer()
            layer.contentsScale = scale
            layer.startPoint = CGPoint(x: 0, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 0.5)
            layer.colors = [
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.clear.cgColor,
                NSColor.clear.cgColor
            ]
            layer.locations = [0, 0, 0, 1]
            mainPerRunSweepMaskLayer.addSublayer(layer)
            mainPerRunSweepLineLayers.append(layer)
        }
    }

    private func hidePerRunSweepMaskLayers() {
        for layer in mainPerRunSweepLineLayers {
            layer.isHidden = true
        }
    }

    private func ensureTranslationSweepMaskLayerCount(_ count: Int) {
        guard translationSweepLineLayers.count < count else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        while translationSweepLineLayers.count < count {
            let layer = CAGradientLayer()
            layer.contentsScale = scale
            layer.startPoint = CGPoint(x: 0, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 0.5)
            layer.colors = [
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.clear.cgColor,
                NSColor.clear.cgColor
            ]
            layer.locations = [0, 0, 0, 1]
            translationPerLineSweepMaskLayer.addSublayer(layer)
            translationSweepLineLayers.append(layer)
        }
    }

    private func hideTranslationSweepMaskLayers() {
        for layer in translationSweepLineLayers {
            layer.isHidden = true
        }
    }

    private func applySweepGradient(
        _ mask: CAGradientLayer,
        wavefrontX: CGFloat,
        fadeHalfPoint: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        let width = max(1, width)
        let left = (wavefrontX - fadeHalfPoint) / width
        let right = (wavefrontX + fadeHalfPoint) / width
        if right <= 0 {
            mask.opacity = 0
            return 0
        }
        mask.opacity = 1
        if left >= 1 {
            mask.locations = [0, 1, 1, 1]
            return width
        }
        let clampedLeft = max(0, min(1, left))
        let clampedRight = max(0, min(1, right))
        mask.locations = [
            0,
            NSNumber(value: Double(clampedLeft)),
            NSNumber(value: Double(clampedRight)),
            1
        ]
        return ((clampedLeft + clampedRight) / 2) * width
    }

    private func updateSweepMask(
        _ mask: CAGradientLayer,
        progress: CGFloat,
        fadeHalfPoint: CGFloat,
        bounds: CGRect
    ) -> CGFloat {
        mask.frame = bounds
        let width = max(1, bounds.width)
        let leading = max(0, min(1, progress))
        let trailing = max(leading, min(1, leading + fadeHalfPoint / width))
        mask.locations = [
            0,
            NSNumber(value: Double(leading)),
            NSNumber(value: Double(trailing)),
            1
        ]
        return leading
    }

    private func clearEmphasis(from layer: CALayer) {
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
    }

    private func layoutDotContainer(frame: CGRect) {
        dotContainerLayer.frame = frame
        let dotSize: CGFloat = 8
        let spacing: CGFloat = 6
        let totalWidth = dotSize * CGFloat(dotLayers.count) + spacing * CGFloat(max(0, dotLayers.count - 1))
        var x: CGFloat = 0
        let y = max(0, (frame.height - dotSize) / 2)
        for dot in dotLayers {
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.position = CGPoint(x: x + dotSize / 2, y: y + dotSize / 2)
            dot.cornerRadius = dotSize / 2
            x += dotSize + spacing
        }
        dotContainerLayer.bounds = CGRect(x: 0, y: 0, width: max(frame.width, totalWidth), height: frame.height)
    }

    private func updateDotsPhase(row: LayerBackedLyricRow, currentTime: TimeInterval) {
        if row.isPrelude {
            applyDotPhase(
                startTime: row.displayLine.line.startTime,
                endTime: row.preludeEndTime,
                currentTime: currentTime,
                gateByTimeRange: false,
                isPrelude: true
            )
            return
        }
        guard let interlude = row.interlude else {
            hideDotLayers()
            return
        }
        applyDotPhase(
            startTime: interlude.startTime,
            endTime: interlude.endTime,
            currentTime: currentTime,
            gateByTimeRange: true,
            isPrelude: false
        )
    }

    private func applyDotPhase(
        startTime: TimeInterval,
        endTime: TimeInterval,
        currentTime: TimeInterval,
        gateByTimeRange: Bool,
        isPrelude: Bool
    ) {
        let plan = NativeLyricsDotPhasePlan.make(
            startTime: startTime,
            endTime: endTime,
            currentTime: currentTime,
            gateByTimeRange: gateByTimeRange
        )
        dotContainerLayer.isHidden = plan.overallOpacity <= 0.001
        dotContainerLayer.opacity = Float(plan.overallOpacity)
        for (index, dot) in dotLayers.enumerated() {
            let opacity = plan.opacities.indices.contains(index) ? plan.opacities[index] : 0
            let scale = plan.scales.indices.contains(index) ? plan.scales[index] : 1
            dot.opacity = Float(opacity)
            dot.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            dot.isHidden = plan.overallOpacity <= 0.001
        }
        let appliedBlur = applyDotBlurRadius(plan.blur)
        (superview as? NativeLyricsSurfaceView)?.recordDotPhase(NativeLyricsDotPhaseSample(
            isPrelude: isPrelude,
            expectedOpacity: plan.opacities,
            appliedOpacity: dotLayers.map { CGFloat($0.opacity) },
            expectedScale: plan.scales,
            appliedScale: dotLayers.map { $0.affineTransform().a },
            expectedBlur: plan.blur,
            appliedBlur: appliedBlur,
            expectedOverallOpacity: plan.overallOpacity,
            appliedOverallOpacity: CGFloat(dotContainerLayer.opacity)
        ))
    }

    @discardableResult
    private func applyDotBlurRadius(_ radius: CGFloat) -> CGFloat {
        let effectiveRadius = radius > 0.1 ? radius : 0
        let quantizedRadius = (effectiveRadius * 4).rounded(.toNearestOrAwayFromZero) / 4
        guard abs(appliedDotBlurRadius - quantizedRadius) > 0.001 else { return quantizedRadius }
        appliedDotBlurRadius = quantizedRadius
        guard quantizedRadius > 0 else {
            dotContainerLayer.filters = nil
            return quantizedRadius
        }
        dotBlurFilter?.setValue(Double(quantizedRadius), forKey: kCIInputRadiusKey)
        dotContainerLayer.filters = dotBlurFilter.map { [$0] }
        return quantizedRadius
    }

    private func hideDotLayers() {
        dotContainerLayer.isHidden = true
        dotContainerLayer.opacity = 0
        dotContainerLayer.filters = nil
        appliedDotBlurRadius = 0
        dotLayers.forEach { dot in
            dot.isHidden = true
            dot.opacity = 0
            dot.setAffineTransform(.identity)
        }
    }

    private func textRenderPlan(
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration,
        currentTime: TimeInterval? = nil
    ) -> NativeLyricsTextRenderPlan {
        NativeLyricsTextRenderPlan.make(
            configuration: textConfiguration(
                row: row,
                configuration: configuration,
                currentTime: currentTime
            ),
            staticPlan: staticTextPlan(for: row)
        )
    }

    private func staticTextPlan(for row: LayerBackedLyricRow) -> NativeLyricsStaticTextRenderPlan {
        let key = StaticTextPlanCacheKey(row: row)
        if cachedStaticTextPlanKey == key, let cachedStaticTextPlan {
            return cachedStaticTextPlan
        }
        let plan = NativeLyricsStaticTextRenderPlan.make(line: row.displayLine.line)
        cachedStaticTextPlanKey = key
        cachedStaticTextPlan = plan
        return plan
    }

    private func textConfiguration(
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration,
        currentTime: TimeInterval? = nil
    ) -> NativeLyricsTextRenderPlan.Configuration {
        NativeLyricsTextRenderPlan.Configuration(
            line: row.displayLine.line,
            currentTime: currentTime ?? configuration.musicController.lyricRenderTime(),
            isActive: row.index == configuration.effectiveCurrentIndex && configuration.musicController.isPlaying,
            staticOpacity: row.index == configuration.effectiveCurrentIndex ? 1 : 0.35,
            showTranslation: configuration.showTranslation
        )
    }

    private func attributedText(
        _ text: String,
        fontSize: CGFloat,
        alpha: CGFloat,
        lineSpacing: CGFloat? = nil
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ]
        if let lineSpacing {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            attributes[.paragraphStyle] = paragraph
        }
        return NSAttributedString(
            string: text,
            attributes: attributes
        )
    }

    private func attributedText(
        _ text: String,
        fontSize: CGFloat,
        alpha: CGFloat,
        hiddenOrders: Set<Int>,
        wordRuns: [NativeLyricsWordRunPlan]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            attributedString: attributedText(text, fontSize: fontSize, alpha: alpha)
        )
        var location = 0
        let textLength = (text as NSString).length
        for (order, run) in wordRuns.enumerated() {
            let length = (run.text as NSString).length
            defer { location += length }
            guard hiddenOrders.contains(order), length > 0, location < textLength else { continue }
            attributed.addAttribute(
                .foregroundColor,
                value: NSColor.clear,
                range: NSRange(location: location, length: min(length, textLength - location))
            )
        }
        return attributed
    }

    private func measuredTextHeight(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        lineSpacing: CGFloat? = nil
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let lineSpacing {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            attributes[.paragraphStyle] = paragraph
        }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return max(1, ceil(rect.height))
    }
}
