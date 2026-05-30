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
    let musicController: MusicController
    let onLineTap: (LyricLine) -> Void
    let onHeightMeasured: (Int, CGFloat) -> Void
    let lineMotionFrameCaptureActive: Bool
    let onLineMotionFrames: ([Int: CGRect], [Int: Int]) -> Void

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
                musicController: musicController,
                onLineTap: onLineTap,
                onHeightMeasured: onHeightMeasured,
                lineMotionFrameCaptureActive: lineMotionFrameCaptureActive,
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
    let musicController: MusicController
    let onLineTap: (LyricLine) -> Void
    let onHeightMeasured: (Int, CGFloat) -> Void
    let lineMotionFrameCaptureActive: Bool
    let onLineMotionFrames: ([Int: CGRect], [Int: Int]) -> Void

    var playbackMode: LyricsPresentationPlaybackMode {
        if reduceMotion { return .directSnap(.reducedMotion) }
        if isManualScrolling { return .directSnap(.manualScroll) }
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
    private var rowRenderKeys: [String: RowRenderKey] = [:]
    private var rowTapHandlers: [Int: () -> Void] = [:]
    private var measuredHeightsByIndex: [Int: CGFloat] = [:]
    private var displayLink: CVDisplayLink?
    private var lastPresentationTick: CFTimeInterval?
    private var frameSummaryStartedAt: CFTimeInterval?
    private var frameCadence = NativeLyricsFrameCadenceAccumulator()
    private var renderTelemetry = NativeLyricsRenderTelemetryAccumulator()

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
        self.configuration = configuration
        presentationEngine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: configuration.currentIndex,
                renderedIndices: configuration.renderedIndices,
                anchorY: configuration.anchorY,
                accumulatedHeights: configuration.accumulatedHeights,
                lineInterval: configuration.lineInterval,
                hasSyllableSync: configuration.hasSyllableSync,
                trackContext: configuration.trackContext,
                isWaveTimelineDiagnosticsEnabled: configuration.isWaveTimelineDiagnosticsEnabled,
                playbackMode: configuration.playbackMode
            ),
            onTargetsChanged: { [weak self] in
                self?.startPresentationLoop()
            }
        )

        let nextIDs = Set(configuration.rows.map(\.id))
        var unmountedCount = 0
        for (id, view) in rowViews where !nextIDs.contains(id) {
            view.layer?.removeAllAnimations()
            view.removeFromSuperview()
            rowViews[id] = nil
            rowRenderKeys[id] = nil
            measuredHeightsByIndex.removeValue(forKey: view.displayIndex)
            unmountedCount += 1
        }
        rowTapHandlers = rowTapHandlers.filter { rowIndex, _ in
            configuration.rows.contains { $0.index == rowIndex }
        }

        let shouldSnap = configuration.playbackMode != .natural
        var mountedCount = 0
        for row in configuration.rows {
            let view = rowViews[row.id] ?? NativeLyricsRowView()
            if rowViews[row.id] == nil {
                rowViews[row.id] = view
                addSubview(view)
                mountedCount += 1
            }
            rowTapHandlers[row.index] = { configuration.onLineTap(row.displayLine.line) }
            updateContentIfNeeded(view: view, row: row, configuration: configuration)
            if let textSample = view.updatePlaybackPhase(configuration: configuration) {
                renderTelemetry.recordTextPhase(textSample)
            }
            applyFrame(for: row, view: view, configuration: configuration, snap: shouldSnap)
        }
        renderTelemetry.recordLifecycle(
            mounted: mountedCount,
            unmounted: unmountedCount,
            mountedRows: rowViews.count,
            renderedRows: configuration.rows.count
        )

        if shouldSnap {
            if hasActiveTextAnimation(configuration: configuration) {
                startPresentationLoop()
            } else {
                stopPresentationLoopIfIdle()
            }
        } else if presentationEngine.hasActiveMotion || hasActiveTextAnimation(configuration: configuration) {
            startPresentationLoop()
        }

        if configuration.lineMotionFrameCaptureActive {
            reportLineMotionFrames(configuration: configuration)
        }
    }

    func stopAnimations() {
        presentationEngine.stop()
        stopPresentationLoop()
        for view in rowViews.values {
            view.layer?.removeAllAnimations()
        }
    }

    private func updateContentIfNeeded(
        view: NativeLyricsRowView,
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) {
        let key = RowRenderKey(row: row, configuration: configuration)
        let needsContentUpdate = rowRenderKeys[row.id] != key
        if needsContentUpdate {
            renderTelemetry.recordContentUpdate()
            rowRenderKeys[row.id] = key
            view.configure(row: row, configuration: configuration)
        }

        let height = view.measuredHeight(width: configuration.rowWidth)
        let heightChanged = abs((measuredHeightsByIndex[row.index] ?? 0) - height) > 2
        renderTelemetry.recordHeightMeasurement(changed: heightChanged)
        if heightChanged {
            measuredHeightsByIndex[row.index] = height
            DispatchQueue.main.async {
                configuration.onHeightMeasured(row.index, height)
            }
        }
    }

    private func applyFrame(
        for row: LayerBackedLyricRow,
        view: NativeLyricsRowView,
        configuration: LyricsLayerRendererConfiguration,
        snap: Bool
    ) {
        let y = snap
            ? snapY(for: row, configuration: configuration)
            : (presentationEngine.presentation(for: row.index)?.y ?? snapY(for: row, configuration: configuration))
        let visual = presentationEngine.presentation(for: row.index)
        let opacity = visual?.opacity ?? (row.index == configuration.currentIndex ? 1 : 0.35)
        let scale = visual?.scale ?? (row.index == configuration.currentIndex ? 1 : 0.95)
        let blur = visual?.blur ?? (row.index == configuration.currentIndex ? 0 : CGFloat(abs(row.index - configuration.currentIndex)) * 1.5)
        let height = measuredHeightsByIndex[row.index] ?? max(1, view.frame.height)
        let frame = CGRect(x: 0, y: 0, width: configuration.rowWidth, height: max(1, height))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if view.frame.size != frame.size || view.frame.origin != .zero {
            view.frame = frame
        }
        view.layer?.opacity = Float(opacity)
        view.layer?.setAffineTransform(
            CGAffineTransform(translationX: 0, y: y)
                .scaledBy(x: scale, y: scale)
        )
        applyBlur(blur, to: view.layer)
        CATransaction.commit()
    }

    private func applyBlur(_ radius: CGFloat, to layer: CALayer?) {
        guard let layer else { return }
        guard radius > 0.1 else {
            layer.filters = nil
            return
        }
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(Double(min(radius, 12)), forKey: kCIInputRadiusKey)
        layer.filters = filter.map { [$0] }
    }

    private func reportLineMotionFrames(configuration: LyricsLayerRendererConfiguration) {
        var frames: [Int: CGRect] = [:]
        for row in configuration.rows {
            guard let view = rowViews[row.id] else { continue }
            guard view.frame.height > 0 else { continue }
            let y = presentationEngine.presentation(for: row.index)?.y ?? snapY(for: row, configuration: configuration)
            frames[row.index] = CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height)
        }
        recordNativeMotionMetrics(frames: frames, configuration: configuration)
        DispatchQueue.main.async {
            configuration.onLineMotionFrames(frames, self.presentationEngine.lineTargetIndices)
        }
    }

    private func recordNativeMotionMetrics(
        frames: [Int: CGRect],
        configuration: LyricsLayerRendererConfiguration
    ) {
        guard !frames.isEmpty else { return }
        let metricRows = configuration.rows.compactMap { row -> NativeLyricsMotionMetricRow? in
            guard let frame = frames[row.index], frame.height > 0 else { return nil }
            let targetIndex = presentationEngine.targetIndex(
                for: row.index,
                fallback: configuration.lineTargetIndices[row.index] ?? configuration.currentIndex
            )
            let rowOffset = configuration.accumulatedHeights[row.index] ?? 0
            let targetOffset = configuration.accumulatedHeights[targetIndex] ?? 0
            let targetMinY = configuration.anchorY - targetOffset + rowOffset
            return NativeLyricsMotionMetricRow(
                displayIndex: row.index,
                targetIndex: targetIndex,
                renderedMinY: frame.minY,
                renderedHeight: frame.height,
                targetMinY: targetMinY,
                velocityY: presentationEngine.presentation(for: row.index)?.velocity ?? 0
            )
        }
        guard !metricRows.isEmpty else { return }
        let visibleTopY: CGFloat = 42
        let visibleBottomY = max(visibleTopY + 1, bounds.height - 120)
        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: metricRows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: configuration.currentIndex,
                visibleTopY: visibleTopY,
                visibleBottomY: visibleBottomY,
                isManualScrolling: configuration.isManualScrolling,
                frozenDisplayIndex: configuration.isManualScrolling ? configuration.currentIndex : nil
            )
        )
        renderTelemetry.recordMotion(metrics)
    }

    private func snapY(
        for row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> CGFloat {
        let targetIndex = configuration.isManualScrolling
            ? configuration.currentIndex
            : presentationEngine.targetIndex(
                for: row.index,
                fallback: configuration.lineTargetIndices[row.index] ?? configuration.currentIndex
            )
        let rowOffset = configuration.accumulatedHeights[row.index] ?? 0
        let targetOffset = configuration.accumulatedHeights[targetIndex] ?? 0
        return configuration.anchorY - targetOffset + rowOffset
    }

    private func applyFramesForCurrentConfiguration(snap: Bool) {
        guard let configuration else { return }
        for row in configuration.rows {
            guard let view = rowViews[row.id] else { continue }
            applyFrame(for: row, view: view, configuration: configuration, snap: snap)
        }
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
        guard !presentationEngine.hasActiveMotion,
              configuration.map({ !hasActiveTextAnimation(configuration: $0) }) ?? true else { return }
        stopPresentationLoop()
    }

    private func stopPresentationLoop() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
        lastPresentationTick = nil
        flushFrameSummary(reason: "stop")
    }

    private func presentationTick(
        displayInterval: TimeInterval?,
        displayTimestamp: TimeInterval?
    ) {
        guard configuration != nil else {
            stopPresentationLoop()
            return
        }
        let now = CACurrentMediaTime()
        let tickTimestamp = displayTimestamp ?? now
        let delta = lastPresentationTick.map { max(0, tickTimestamp - $0) }
            ?? displayInterval
            ?? 0
        lastPresentationTick = tickTimestamp
        recordFrameDelta(delta, expectedRefreshInterval: displayInterval, now: now)
        _ = presentationEngine.advance(delta: delta)
        updateTextPhasesForCurrentConfiguration()
        applyFramesForCurrentConfiguration(snap: false)
        if configuration?.lineMotionFrameCaptureActive == true, let configuration {
            reportLineMotionFrames(configuration: configuration)
        }
        stopPresentationLoopIfIdle()
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
        let point = convert(event.locationInWindow, from: nil)
        let hit = configuration.rows
            .compactMap { row -> (Int, CGRect)? in
                guard let view = rowViews[row.id] else { return nil }
                let y = presentationEngine.presentation(for: row.index)?.y
                    ?? snapY(for: row, configuration: configuration)
                return (row.index, CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height))
            }
            .sorted { lhs, rhs in abs(lhs.1.midY - point.y) < abs(rhs.1.midY - point.y) }
            .first { _, frame in frame.contains(point) }

        if let index = hit?.0, let handler = rowTapHandlers[index] {
            handler()
            return
        }
        super.mouseDown(with: event)
    }

    private struct RowRenderKey: Equatable {
        let row: LayerBackedLyricRow
        let isCurrent: Bool
        let isPlaying: Bool
        let isManualScrolling: Bool
        let showTranslation: Bool
        let isAwaitingTranslation: Bool
        let translationFailed: Bool
        let isPrecedingInterlude: Bool
        let rowWidth: CGFloat

        init(row: LayerBackedLyricRow, configuration: LyricsLayerRendererConfiguration) {
            self.row = row
            self.isCurrent = row.index == configuration.currentIndex
            self.isPlaying = configuration.musicController.isPlaying
            self.isManualScrolling = configuration.isManualScrolling
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

    private func updateTextPhasesForCurrentConfiguration() {
        guard let configuration else { return }
        for row in configuration.rows {
            guard let view = rowViews[row.id] else { continue }
            if let textSample = view.updatePlaybackPhase(configuration: configuration) {
                renderTelemetry.recordTextPhase(textSample)
            }
        }
    }

    private func hasActiveTextAnimation(configuration: LyricsLayerRendererConfiguration) -> Bool {
        guard configuration.musicController.isPlaying else { return false }
        guard let activeRow = configuration.rows.first(where: { $0.index == configuration.currentIndex }) else {
            return false
        }
        return activeRow.displayLine.line.hasSyllableSync
            || (configuration.showTranslation && activeRow.displayLine.line.translation?.isEmpty == false)
            || activeRow.interlude != nil
            || activeRow.isPrelude
    }
}

private final class NativeLyricsRowView: NSView {
    override var isFlipped: Bool { true }

    private let backgroundLayer = CALayer()
    private let mainTextLayer = CATextLayer()
    private let mainBrightTextLayer = CATextLayer()
    private let mainSweepMaskLayer = CAGradientLayer()
    private let translationTextLayer = CATextLayer()
    private let translationBrightTextLayer = CATextLayer()
    private let translationSweepMaskLayer = CAGradientLayer()
    private let interludeTextLayer = CATextLayer()
    private var trackingAreaRef: NSTrackingArea?
    private var row: LayerBackedLyricRow?
    private var configuration: LyricsLayerRendererConfiguration?
    private var isHovering = false

    var displayIndex: Int { row?.index ?? -1 }

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

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard let row, let configuration else { return 1 }
        let textWidth = max(1, width - nativeLyricContentLeadingInset - nativeLyricContentTrailingInset)
        if row.isPrelude {
            return 46
        }
        let plan = NativeLyricsTextRenderPlan.make(configuration: textConfiguration(row: row, configuration: configuration))
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
                font: .systemFont(ofSize: plan.constants.translationFontSize, weight: .semibold)
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
        let plan = NativeLyricsTextRenderPlan.make(configuration: textConfiguration(row: row, configuration: configuration))
        backgroundLayer.frame = bounds.insetBy(dx: 24, dy: 2)
        var y: CGFloat = 8
        if row.isPrelude {
            mainTextLayer.frame = CGRect(x: textX, y: y, width: textWidth, height: 30)
            mainBrightTextLayer.frame = mainTextLayer.frame
            mainSweepMaskLayer.frame = mainBrightTextLayer.bounds
            translationTextLayer.frame = .zero
            translationBrightTextLayer.frame = .zero
            translationSweepMaskLayer.frame = .zero
            interludeTextLayer.frame = .zero
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
        y += mainHeight
        if let translation = plan.translation {
            y += plan.constants.mainFontSize * 0.33
            let translationHeight = measuredTextHeight(
                translation.text,
                width: textWidth,
                font: .systemFont(ofSize: plan.constants.translationFontSize, weight: .semibold)
            )
            translationTextLayer.frame = CGRect(x: textX, y: y, width: textWidth, height: translationHeight)
            translationBrightTextLayer.frame = translationTextLayer.frame
            translationSweepMaskLayer.frame = translationBrightTextLayer.bounds
            y += translationHeight
        } else {
            translationTextLayer.frame = .zero
            translationBrightTextLayer.frame = .zero
            translationSweepMaskLayer.frame = .zero
        }
        if row.interlude != nil {
            interludeTextLayer.frame = CGRect(x: textX, y: y + 8, width: 80, height: 24)
        } else {
            interludeTextLayer.frame = .zero
        }
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
        isHovering = true
        updateHoverBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverBackground()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        [
            backgroundLayer,
            mainTextLayer,
            mainBrightTextLayer,
            translationTextLayer,
            translationBrightTextLayer,
            interludeTextLayer
        ].forEach {
            $0.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            $0.masksToBounds = false
            layer?.addSublayer($0)
        }
        mainBrightTextLayer.mask = mainSweepMaskLayer
        translationBrightTextLayer.mask = translationSweepMaskLayer
        backgroundLayer.cornerRadius = 12
        backgroundLayer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
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
            mainTextLayer.string = attributedText(
                "•••",
                fontSize: 24,
                alpha: 0.7
            )
            mainBrightTextLayer.string = nil
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            interludeTextLayer.string = nil
            return
        }

        let plan = NativeLyricsTextRenderPlan.make(configuration: textConfiguration(row: row, configuration: configuration))
        let isActive = row.index == configuration.currentIndex && configuration.musicController.isPlaying
        let mainAlpha = isActive ? plan.constants.dimAlpha : (row.index == configuration.currentIndex ? 1 : 0.35)
        mainTextLayer.string = attributedText(
            plan.displayText,
            fontSize: plan.constants.mainFontSize,
            alpha: mainAlpha
        )
        mainBrightTextLayer.string = isActive
            ? attributedText(plan.displayText, fontSize: plan.constants.mainFontSize, alpha: plan.constants.brightAlpha)
            : nil
        if let translation = plan.translation {
            let translationBaseAlpha = isActive ? translation.dimAlpha : translation.opacity
            translationTextLayer.string = attributedText(
                translation.text,
                fontSize: plan.constants.translationFontSize,
                alpha: translationBaseAlpha
            )
            translationBrightTextLayer.string = isActive
                ? attributedText(translation.text, fontSize: plan.constants.translationFontSize, alpha: translation.brightAlpha)
                : nil
        } else if configuration.showTranslation && configuration.isTranslating {
            translationTextLayer.string = attributedText("•••", fontSize: 16, alpha: 0.45)
            translationBrightTextLayer.string = nil
        } else if configuration.showTranslation && configuration.translationFailed && row.index == configuration.currentIndex {
            translationTextLayer.string = attributedText("Translation unavailable", fontSize: 14, alpha: 0.3)
            translationBrightTextLayer.string = nil
        } else {
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
        }
        interludeTextLayer.string = row.interlude == nil ? nil : attributedText("•••", fontSize: 20, alpha: 0.45)
        updatePlaybackPhase(configuration: configuration)
    }

    private func updateHoverBackground() {
        backgroundLayer.isHidden = !(isHovering && configuration?.isManualScrolling == true && row?.displayLine.line.text != "⋯")
    }

    @discardableResult
    func updatePlaybackPhase(configuration: LyricsLayerRendererConfiguration) -> NativeLyricsTextPhaseSample? {
        guard let row else { return nil }
        let renderTime = configuration.musicController.lyricRenderTime()
        let isActive = row.index == configuration.currentIndex && configuration.musicController.isPlaying
        let plan = NativeLyricsTextRenderPlan.make(configuration: textConfiguration(
            row: row,
            configuration: configuration,
            currentTime: renderTime
        ))

        var sample: NativeLyricsTextPhaseSample?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isActive {
            let appliedMainProgress = applyActiveMainPhase(plan: plan, currentTime: renderTime)
            let appliedTranslationProgress = applyActiveTranslationPhase(plan: plan)
            sample = NativeLyricsTextPhaseSample(
                hasSyllableSync: row.displayLine.line.hasSyllableSync,
                wordRunCount: plan.wordRuns.count,
                mainExpectedProgress: plan.mainSweepProgress,
                mainAppliedProgress: appliedMainProgress,
                translationExpectedProgress: plan.translation?.progress,
                translationAppliedProgress: appliedTranslationProgress
            )
        } else {
            mainBrightTextLayer.isHidden = true
            translationBrightTextLayer.isHidden = true
            mainTextLayer.setAffineTransform(.identity)
            mainBrightTextLayer.setAffineTransform(.identity)
            clearEmphasis(from: mainBrightTextLayer)
        }
        updateInterludePhase(row: row, currentTime: renderTime)
        CATransaction.commit()
        return sample
    }

    private func applyActiveMainPhase(plan: NativeLyricsTextRenderPlan, currentTime: TimeInterval) -> CGFloat {
        let activeRun = plan.wordRuns.last { $0.startTime <= currentTime }
            ?? plan.wordRuns.first
        let y = activeRun?.baseFloatY ?? 0
        mainTextLayer.setAffineTransform(CGAffineTransform(translationX: 0, y: y))
        mainBrightTextLayer.setAffineTransform(CGAffineTransform(translationX: 0, y: y))
        mainBrightTextLayer.opacity = Float(plan.mainPostLineFade)
        mainBrightTextLayer.isHidden = plan.mainSweepProgress <= 0.001 || plan.mainPostLineFade <= 0.001
        let appliedProgress = updateSweepMask(
            mainSweepMaskLayer,
            progress: plan.mainSweepProgress,
            fadeHalfPoint: plan.constants.fadeHalfPoint,
            bounds: mainBrightTextLayer.bounds
        )
        if let activeRun, activeRun.emphasis.glowOpacity > 0 {
            mainBrightTextLayer.shadowColor = NSColor.white.cgColor
            mainBrightTextLayer.shadowOpacity = Float(min(1, activeRun.emphasis.glowOpacity))
            mainBrightTextLayer.shadowRadius = activeRun.emphasis.glowRadius
            mainBrightTextLayer.shadowOffset = CGSize(width: 0, height: activeRun.emphasis.liftY + activeRun.emphasis.floatY)
        } else {
            clearEmphasis(from: mainBrightTextLayer)
        }
        return appliedProgress
    }

    private func applyActiveTranslationPhase(plan: NativeLyricsTextRenderPlan) -> CGFloat? {
        guard let translation = plan.translation else {
            translationBrightTextLayer.isHidden = true
            return nil
        }
        translationBrightTextLayer.opacity = Float(translation.postLineFade)
        translationBrightTextLayer.isHidden = translation.progress <= 0.001 || translation.postLineFade <= 0.001
        return updateSweepMask(
            translationSweepMaskLayer,
            progress: translation.progress,
            fadeHalfPoint: translation.fadeHalfPoint,
            bounds: translationBrightTextLayer.bounds
        )
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

    private func updateInterludePhase(row: LayerBackedLyricRow, currentTime: TimeInterval) {
        guard let interlude = row.interlude else {
            interludeTextLayer.opacity = 1
            return
        }
        let duration = max(0.1, interlude.endTime - interlude.startTime)
        let progress = CGFloat(min(1, max(0, (currentTime - interlude.startTime) / duration)))
        let breathe = 0.45 + 0.35 * sin(progress * .pi * 2)
        interludeTextLayer.opacity = Float(max(0.2, min(0.8, breathe)))
    }

    private func textConfiguration(
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration,
        currentTime: TimeInterval? = nil
    ) -> NativeLyricsTextRenderPlan.Configuration {
        NativeLyricsTextRenderPlan.Configuration(
            line: row.displayLine.line,
            currentTime: currentTime ?? configuration.musicController.lyricRenderTime(),
            isActive: row.index == configuration.currentIndex && configuration.musicController.isPlaying,
            staticOpacity: row.index == configuration.currentIndex ? 1 : 0.35,
            showTranslation: configuration.showTranslation
        )
    }

    private func attributedText(_ text: String, fontSize: CGFloat, alpha: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha)
            ]
        )
    }

    private func measuredTextHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(1, ceil(rect.height))
    }
}
