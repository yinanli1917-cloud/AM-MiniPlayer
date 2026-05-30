import AppKit
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
        for (id, view) in rowViews where !nextIDs.contains(id) {
            view.layer?.removeAllAnimations()
            view.removeFromSuperview()
            rowViews[id] = nil
            rowRenderKeys[id] = nil
            measuredHeightsByIndex.removeValue(forKey: view.displayIndex)
        }
        rowTapHandlers = rowTapHandlers.filter { rowIndex, _ in
            configuration.rows.contains { $0.index == rowIndex }
        }

        let shouldSnap = configuration.playbackMode != .natural
        for row in configuration.rows {
            let view = rowViews[row.id] ?? NativeLyricsRowView()
            if rowViews[row.id] == nil {
                rowViews[row.id] = view
                addSubview(view)
            }
            rowTapHandlers[row.index] = { configuration.onLineTap(row.displayLine.line) }
            updateContentIfNeeded(view: view, row: row, configuration: configuration)
            applyFrame(for: row, view: view, configuration: configuration, snap: shouldSnap)
        }

        if shouldSnap {
            stopPresentationLoopIfIdle()
        } else if presentationEngine.hasActiveMotion {
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
            rowRenderKeys[row.id] = key
            view.configure(row: row, configuration: configuration)
        }

        let height = view.measuredHeight(width: configuration.rowWidth)
        if abs((measuredHeightsByIndex[row.index] ?? 0) - height) > 2 {
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
        DispatchQueue.main.async {
            configuration.onLineMotionFrames(frames, self.presentationEngine.lineTargetIndices)
        }
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
        guard !presentationEngine.hasActiveMotion else { return }
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
        resetFrameSummary(at: endedAt)
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
        let isManualScrolling: Bool
        let showTranslation: Bool
        let isAwaitingTranslation: Bool
        let translationFailed: Bool
        let isPrecedingInterlude: Bool
        let rowWidth: CGFloat
        let wordFillBucket: Int

        init(row: LayerBackedLyricRow, configuration: LyricsLayerRendererConfiguration) {
            self.row = row
            self.isCurrent = row.index == configuration.currentIndex
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
            self.wordFillBucket = Int((configuration.musicController.wordFillTime * 20).rounded())
        }
    }
}

private final class NativeLyricsRowView: NSView {
    override var isFlipped: Bool { true }

    private let backgroundLayer = CALayer()
    private let mainTextLayer = CATextLayer()
    private let translationTextLayer = CATextLayer()
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
            translationTextLayer.frame = .zero
            interludeTextLayer.frame = .zero
            return
        }

        let mainHeight = measuredTextHeight(
            plan.displayText,
            width: textWidth,
            font: .systemFont(ofSize: plan.constants.mainFontSize, weight: .semibold)
        )
        mainTextLayer.frame = CGRect(x: textX, y: y, width: textWidth, height: mainHeight)
        y += mainHeight
        if let translation = plan.translation {
            y += plan.constants.mainFontSize * 0.33
            let translationHeight = measuredTextHeight(
                translation.text,
                width: textWidth,
                font: .systemFont(ofSize: plan.constants.translationFontSize, weight: .semibold)
            )
            translationTextLayer.frame = CGRect(x: textX, y: y, width: textWidth, height: translationHeight)
            y += translationHeight
        } else {
            translationTextLayer.frame = .zero
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
        [backgroundLayer, mainTextLayer, translationTextLayer, interludeTextLayer].forEach {
            $0.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            $0.masksToBounds = false
            layer?.addSublayer($0)
        }
        backgroundLayer.cornerRadius = 12
        backgroundLayer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        backgroundLayer.isHidden = true
        [mainTextLayer, translationTextLayer, interludeTextLayer].forEach { textLayer in
            textLayer.isWrapped = true
            textLayer.alignmentMode = .left
            textLayer.truncationMode = .none
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
            translationTextLayer.string = nil
            interludeTextLayer.string = nil
            return
        }

        let plan = NativeLyricsTextRenderPlan.make(configuration: textConfiguration(row: row, configuration: configuration))
        let mainAlpha = row.index == configuration.currentIndex ? 1 : 0.35
        mainTextLayer.string = attributedText(
            plan.displayText,
            fontSize: plan.constants.mainFontSize,
            alpha: mainAlpha
        )
        if let translation = plan.translation {
            translationTextLayer.string = attributedText(
                translation.text,
                fontSize: plan.constants.translationFontSize,
                alpha: translation.opacity
            )
        } else if configuration.showTranslation && configuration.isTranslating {
            translationTextLayer.string = attributedText("•••", fontSize: 16, alpha: 0.45)
        } else if configuration.showTranslation && configuration.translationFailed && row.index == configuration.currentIndex {
            translationTextLayer.string = attributedText("Translation unavailable", fontSize: 14, alpha: 0.3)
        } else {
            translationTextLayer.string = nil
        }
        interludeTextLayer.string = row.interlude == nil ? nil : attributedText("•••", fontSize: 20, alpha: 0.45)
    }

    private func updateHoverBackground() {
        backgroundLayer.isHidden = !(isHovering && configuration?.isManualScrolling == true && row?.displayLine.line.text != "⋯")
    }

    private func textConfiguration(
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> NativeLyricsTextRenderPlan.Configuration {
        NativeLyricsTextRenderPlan.Configuration(
            line: row.displayLine.line,
            currentTime: configuration.musicController.wordFillTime,
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
