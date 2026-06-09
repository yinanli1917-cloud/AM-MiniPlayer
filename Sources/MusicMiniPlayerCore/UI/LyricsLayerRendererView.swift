import AppKit
import CoreImage
import CoreVideo
import QuartzCore
import SwiftUI

private let nativeLyricContentLeadingInset: CGFloat = 32
private let nativeLyricContentTrailingInset: CGFloat = 32
private let nativeLyricAutoVisibleRowRadius = 12
private let nativeLyricManualVisibleRowRadius = 12
private let nativeLyricTextFrameInterval: TimeInterval = 1.0 / 60.0
private let nativeLyricFrameSummaryInterval: TimeInterval = 10
private let nativeLyricsTopOverlayReservedHeight: CGFloat = 56
private let nativeLyricsTopLeadingReservedWidth: CGFloat = 150
private let nativeLyricsTopTrailingReservedWidth: CGFloat = 72
private let nativeLyricsBottomControlsReservedHeight: CGFloat = 148

private struct NativeLyricsInterludeBlendState: Equatable {
    private(set) var value: CGFloat
    private(set) var target: CGFloat
    private var startValue: CGFloat
    private var startedAt: CFTimeInterval
    private var delay: TimeInterval
    private let duration: TimeInterval = 2.5

    init(value: CGFloat = 0, now: CFTimeInterval = CACurrentMediaTime()) {
        self.value = value
        target = value
        startValue = value
        startedAt = now
        delay = 0
    }

    var isSettled: Bool {
        abs(value - target) < 0.001
    }

    mutating func setTarget(_ nextTarget: CGFloat, now: CFTimeInterval) -> Bool {
        let clampedTarget = min(1, max(0, nextTarget))
        guard abs(target - clampedTarget) > 0.001 else { return false }
        value = currentValue(at: now)
        target = clampedTarget
        startValue = value
        startedAt = now
        delay = clampedTarget > value ? 0.5 : 0
        return true
    }

    mutating func value(at now: CFTimeInterval) -> CGFloat {
        value = currentValue(at: now)
        if isSettled {
            value = target
        }
        return value
    }

    private func currentValue(at now: CFTimeInterval) -> CGFloat {
        let elapsed = max(0, now - startedAt - delay)
        guard elapsed > 0 else { return startValue }
        if elapsed >= duration { return target }
        let t = CGFloat(elapsed / duration)
        let eased = 1 - pow(1 - t, 3)
        return startValue + (target - startValue) * eased
    }
}

private final class NativeLyricsDisplayLinkScheduler {
    private let lock = NSLock()
    private var isTickQueued = false
    private var latestDisplayInterval: TimeInterval?
    private var latestDisplayTimestamp: TimeInterval?

    func enqueue(
        displayInterval: TimeInterval?,
        displayTimestamp: TimeInterval?,
        perform: @escaping (TimeInterval?, TimeInterval?) -> Void
    ) {
        var shouldQueue = false
        lock.lock()
        latestDisplayInterval = displayInterval
        latestDisplayTimestamp = displayTimestamp
        if !isTickQueued {
            isTickQueued = true
            shouldQueue = true
        }
        lock.unlock()

        guard shouldQueue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let payload = self.consumeQueuedTick()
            perform(payload.displayInterval, payload.displayTimestamp)
        }
    }

    func reset() {
        lock.lock()
        isTickQueued = false
        latestDisplayInterval = nil
        latestDisplayTimestamp = nil
        lock.unlock()
    }

    private func consumeQueuedTick() -> (displayInterval: TimeInterval?, displayTimestamp: TimeInterval?) {
        lock.lock()
        let payload: (displayInterval: TimeInterval?, displayTimestamp: TimeInterval?) = (
            latestDisplayInterval,
            latestDisplayTimestamp
        )
        latestDisplayInterval = nil
        latestDisplayTimestamp = nil
        isTickQueued = false
        lock.unlock()
        return payload
    }
}

private final class NativeLyricsSweepMaskLineLayer: CALayer {
    private let solidLayer = CALayer()
    private let fadeLayer = CALayer()

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        masksToBounds = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        solidLayer.backgroundColor = NSColor.black.cgColor
        solidLayer.contentsScale = contentsScale
        fadeLayer.contents = Self.fadeImage
        fadeLayer.contentsGravity = .resize
        fadeLayer.minificationFilter = .linear
        fadeLayer.magnificationFilter = .linear
        fadeLayer.contentsScale = contentsScale
        addSublayer(solidLayer)
        addSublayer(fadeLayer)
    }

    @discardableResult
    func apply(wavefrontX: CGFloat, fadeHalfPoint: CGFloat, width: CGFloat) -> CGFloat {
        let width = max(1, width)
        let height = max(1, bounds.height)
        let left = wavefrontX - fadeHalfPoint
        let right = wavefrontX + fadeHalfPoint
        if right <= 0 {
            opacity = 0
            solidLayer.frame = .zero
            fadeLayer.frame = .zero
            return 0
        }

        opacity = 1
        if left >= width {
            solidLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            fadeLayer.frame = .zero
            return width
        }

        let clampedLeft = max(0, min(width, left))
        let clampedRight = max(0, min(width, right))
        solidLayer.frame = CGRect(x: 0, y: 0, width: clampedLeft, height: height)
        fadeLayer.frame = CGRect(
            x: clampedLeft,
            y: 0,
            width: max(0, clampedRight - clampedLeft),
            height: height
        )
        return (clampedLeft + clampedRight) / 2
    }

    private static let fadeImage: CGImage = {
        let width = 64
        let height = 1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGImage.emptyMaskPixel
        }
        let colors = [
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else {
            return CGImage.emptyMaskPixel
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: 0),
            options: []
        )
        return context.makeImage() ?? CGImage.emptyMaskPixel
    }()
}

private extension CGImage {
    static let emptyMaskPixel: CGImage = {
        var pixel: UInt32 = 0
        let data = Data(bytes: &pixel, count: MemoryLayout<UInt32>.size)
        let provider = CGDataProvider(data: data as CFData)
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider!,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }()
}

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
    let surfaceController: NativeLyricsSurfaceController
    let musicController: MusicController
    let onLineTap: (LyricLine) -> Void
    let onDirectSnapConsumed: (UUID) -> Void
    let onManualScrollStarted: (Int) -> Void
    let onManualScrollDelta: (CGFloat, CGFloat) -> Void
    let onManualScrollEnded: () -> Void
    let onManualScrollRecovered: () -> Void
    let onManualScrollChromeReset: (() -> Void)?
    let onHeightMeasured: (Int, CGFloat) -> Void
    let lineMotionSamplingEnabled: Bool
    let lineMotionFocusedSamplingUntil: Date
    let lineMotionFirstRealDisplayIndex: Int
    let onLineMotionFrames: ([Int: CGRect], NativeLyricsPresentationSnapshot, Date?, TimeInterval?) -> Void

    func makeNSView(context: Context) -> NativeLyricsSurfaceView {
        let view = NativeLyricsSurfaceView()
        surfaceController.attach(view)
        return view
    }

    func updateNSView(_ nsView: NativeLyricsSurfaceView, context: Context) {
        surfaceController.attach(nsView)
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
                onManualScrollChromeReset: onManualScrollChromeReset,
                onHeightMeasured: onHeightMeasured,
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

@MainActor
final class NativeLyricsSurfaceController {
    private weak var surfaceView: NativeLyricsSurfaceView?

    func attach(_ view: NativeLyricsSurfaceView) {
        surfaceView = view
    }

    @discardableResult
    func captureLineMotionFrames(timestamp: Date, playbackTime: TimeInterval) -> Bool {
        surfaceView?.captureLineMotionFrames(timestamp: timestamp, playbackTime: playbackTime) ?? false
    }
}

struct LyricsLayerRendererConfiguration {
    let rows: [LayerBackedLyricRow]
    let currentIndex: Int
    let anchorY: CGFloat
    let rowWidth: CGFloat
    let renderedIndices: [Int]
    var accumulatedHeights: [Int: CGFloat]
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
    let onManualScrollChromeReset: (() -> Void)?
    let onHeightMeasured: (Int, CGFloat) -> Void
    let lineMotionSamplingEnabled: Bool
    let lineMotionFocusedSamplingUntil: Date
    let lineMotionFirstRealDisplayIndex: Int
    let onLineMotionFrames: ([Int: CGRect], NativeLyricsPresentationSnapshot, Date?, TimeInterval?) -> Void
    var nativeManualScrollSnapshot: NativeLyricsManualScrollSnapshot? = nil
    var nativeDirectSnapIndex: Int? = nil
    var nativeDirectSnapReason: LyricsPresentationDirectSnapReason? = nil
    var nativeSemanticCurrentIndex: Int? = nil
    var nativeScrollTargetIndex: Int? = nil
    var nativeHotActiveIndices: Set<Int> = []
    var nativeBufferedActiveIndices: Set<Int> = []

    var effectiveCurrentIndex: Int {
        nativeDirectSnapIndex
            ?? nativeManualScrollSnapshot?.frozenDisplayIndex
            ?? nativeSemanticCurrentIndex
            ?? currentIndex
    }

    var effectiveScrollTargetIndex: Int {
        nativeDirectSnapIndex
            ?? nativeManualScrollSnapshot?.frozenDisplayIndex
            ?? nativeScrollTargetIndex
            ?? effectiveCurrentIndex
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

private class _FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class NativeLyricsSurfaceView: NSView {
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private var configuration: LyricsLayerRendererConfiguration?
    private let presentationEngine = LyricsPresentationEngine()
    private var rowViews: [String: NativeLyricsRowView] = [:]
    private var rowViewReusePool: [NativeLyricsRowView] = []
    private var rowIDByIndex: [Int: String] = [:]
    private var rowRenderKeys: [String: RowRenderKey] = [:]
    private var visualParitySignatures: [String: VisualParitySignature] = [:]
    private var rowFrameParitySignatures: [String: RowFrameParitySignature] = [:]
    private var visualStates: [Int: NativeLyricsVisualMotionState] = [:]
    private var interludeBlendStates: [Int: NativeLyricsInterludeBlendState] = [:]
    nonisolated(unsafe) private let displayLinkScheduler = NativeLyricsDisplayLinkScheduler()
    private var rowTapHandlers: [Int: () -> Void] = [:]
    private var measuredHeightsByIndex: [Int: CGFloat] = [:]
    private var displayLink: CVDisplayLink?
    private var lastPresentationTick: CFTimeInterval?
    private var lastFrameCadenceTick: CFTimeInterval?
    private var frameSummaryStartedAt: CFTimeInterval?
    private var frameCadence = NativeLyricsFrameCadenceAccumulator()
    private var renderTelemetry = NativeLyricsRenderTelemetryAccumulator()
    private var manualScrollState = NativeLyricsManualScrollState()
    private var manualPresentationNeedsApply = false
    private var manualScrollEndTimer: Timer?
    private var manualScrollRecoveryTimer: Timer?
    private var nativeLineAdvanceTimer: Timer?
    private var nativeLineAdvanceTimerTargetPlaybackTime: TimeInterval?
    private var nativeLineMotionSamplingTimer: Timer?
    private var lastNativeLineMotionSampleAt: Date = .distantPast
    private var nativeSemanticCurrentIndex: Int?
    private var nativeTimelineState: NativeLyricsTimelinePolicy.AMLLState?
    private var pausedSemanticLocked = false
    private var lastObservedSeekGeneration: Int = 0
    private var lastTextPhaseUpdateAt: CFTimeInterval?
    private var lastScrollWheelTime: CFTimeInterval = 0
    private var hoveredRowIndex: Int?
    private var surfaceTrackingArea: NSTrackingArea?
    private var localEventMonitor: Any?
    private var lastConfigureEventSignature: String?
    private var consumedDirectSnapRequestIDs: Set<UUID> = []
    private var lastConfiguredTextPhaseIndex: Int?
    private var pendingTapToLineSettleTiming: (targetIndex: Int, startedAt: CFTimeInterval, deadline: CFTimeInterval)?
    private let surfaceInterludeOverlay: NSView = {
        let v = _FlippedView()
        return v
    }()
    private let surfaceInterludeDotContainer = CALayer()
    private let surfaceInterludeDots: [CALayer] = (0..<3).map { _ in CALayer() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        setupSurfaceInterludeDots()
        installLocalEventMonitor()
    }

    private func setupSurfaceInterludeDots() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let dotSize = NativeLyricsDotPhasePlan.baseDotSize
        surfaceInterludeOverlay.wantsLayer = true
        surfaceInterludeOverlay.layer?.masksToBounds = false
        surfaceInterludeOverlay.alphaValue = 0
        addSubview(surfaceInterludeOverlay)
        surfaceInterludeDotContainer.masksToBounds = false
        surfaceInterludeDotContainer.contentsScale = scale
        for dot in surfaceInterludeDots {
            dot.contentsScale = scale
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = NSColor.white.cgColor
            dot.masksToBounds = false
            surfaceInterludeDotContainer.addSublayer(dot)
        }
        surfaceInterludeOverlay.layer?.addSublayer(surfaceInterludeDotContainer)
    }

    private func updateSurfaceInterludeDots(
        configuration: LyricsLayerRendererConfiguration,
        snap: Bool
    ) {
        guard let interludeIndex = configuration.interludeAfterIndex,
              let row = configuration.rows.first(where: { $0.index == interludeIndex }),
              let interlude = row.interlude else {
            surfaceInterludeOverlay.alphaValue = 0
            return
        }
        let baseY: CGFloat
        if snap {
            baseY = snapY(for: row, configuration: configuration)
        } else {
            baseY = presentationEngine.presentation(for: row.index)?.y
                ?? snapY(for: row, configuration: configuration)
        }
        let rowHeight = measuredHeightsByIndex[row.index] ?? 36
        let y = baseY + configuration.effectiveManualOffset + rowHeight + 8
        surfaceInterludeOverlay.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let dotSize = NativeLyricsDotPhasePlan.baseDotSize
        let spacing = NativeLyricsDotPhasePlan.baseDotSpacing
        let totalWidth = dotSize * CGFloat(surfaceInterludeDots.count)
            + spacing * CGFloat(max(0, surfaceInterludeDots.count - 1))
        let containerX = nativeLyricContentLeadingInset
        surfaceInterludeDotContainer.bounds = CGRect(x: 0, y: 0, width: totalWidth, height: dotSize)
        surfaceInterludeDotContainer.position = CGPoint(x: containerX + totalWidth / 2, y: y + dotSize / 2)
        var x: CGFloat = 0
        let currentTime = configuration.musicController.lyricRenderTime()
        let plan = NativeLyricsDotPhasePlan.make(
            startTime: interlude.startTime,
            endTime: interlude.endTime,
            currentTime: currentTime,
            gateByTimeRange: true
        )
        surfaceInterludeOverlay.alphaValue = CGFloat(plan.overallOpacity)
        if plan.blur > 0.01 {
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(Double(plan.blur), forKey: kCIInputRadiusKey)
            surfaceInterludeDotContainer.filters = filter.map { [$0] }
        } else {
            surfaceInterludeDotContainer.filters = nil
        }
        for (index, dot) in surfaceInterludeDots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.position = CGPoint(x: x + dotSize / 2, y: dotSize / 2)
            dot.cornerRadius = dotSize / 2
            dot.opacity = Float(plan.opacities[index])
            dot.setAffineTransform(CGAffineTransform(scaleX: plan.scales[index], y: plan.scales[index]))
            dot.isHidden = false
            x += dotSize + spacing
        }
    }

    private func installLocalEventMonitor() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .mouseMoved]) { [weak self] event in
            guard let self,
                  self.window === event.window,
                  self.shouldHandleLocalEvent(event) else {
                return event
            }
            switch event.type {
            case .scrollWheel:
                return self.handleNativeScrollWheel(event) ? nil : event
            case .leftMouseDown:
                return self.handleNativeMouseDown(event) ? nil : event
            case .mouseMoved:
                self.updateNativeHoverFromEvent(event)
                return event
            default:
                return event
            }
        }
    }

    private func removeLocalEventMonitor() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func containsWindowPoint(_ windowPoint: CGPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        return bounds.insetBy(dx: -4, dy: -4).contains(point)
    }

    private func shouldHandleLocalEvent(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -4, dy: -4).contains(point) {
            if event.type == .scrollWheel { return true }
            if let configuration,
               isPointInReservedOverlayZone(point, configuration: configuration) {
                return manualScrollState.isActive
            }
            return true
        }
        return event.type == .scrollWheel && manualScrollState.isActive
    }

    private func deferParentCallback(_ callback: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            callback()
        }
    }


    func configure(_ configuration: LyricsLayerRendererConfiguration) {
        installLocalEventMonitor()
        if let previous = self.configuration?.trackContext,
           !Self.isSameTrackIdentity(previous, configuration.trackContext) {
            cancelManualScrollTimers()
            cancelNativeLineAdvanceTimer()
            manualScrollState.reset()
            manualPresentationNeedsApply = false
            visualStates.removeAll()
            interludeBlendStates.removeAll()
            measuredHeightsByIndex.removeAll()
            nativeSemanticCurrentIndex = nil
            nativeTimelineState = nil
            pausedSemanticLocked = false
            lastTextPhaseUpdateAt = nil
        }
        self.configuration = configuration

        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        updateNativeLineMotionSamplingTimer(configuration: runtimeConfiguration)
        consumeDirectSnapRequestIfNeeded(runtimeConfiguration)
        recordConfigureEventIfNeeded(configuration: runtimeConfiguration)
        presentationEngine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: runtimeConfiguration.effectiveCurrentIndex,
                scrollTargetIndex: runtimeConfiguration.effectiveScrollTargetIndex,
                hotActiveIndices: runtimeConfiguration.nativeHotActiveIndices,
                bufferedActiveIndices: runtimeConfiguration.nativeBufferedActiveIndices,
                isManualScrolling: runtimeConfiguration.effectiveIsManualScrolling,
                renderedIndices: runtimeConfiguration.renderedIndices,
                anchorY: runtimeConfiguration.anchorY,
                accumulatedHeights: runtimeConfiguration.accumulatedHeights,
                lineInterval: runtimeConfiguration.lineInterval,
                hasSyllableSync: runtimeConfiguration.hasSyllableSync,
                isInterludeActive: runtimeConfiguration.interludeAfterIndex != nil,
                trackContext: runtimeConfiguration.trackContext,
                isWaveTimelineDiagnosticsEnabled: runtimeConfiguration.isWaveTimelineDiagnosticsEnabled
                    || DiagnosticsService.shared.isLyricWaveTimelineEnabled,
                playbackMode: runtimeConfiguration.playbackMode
            ),
            onTargetsChanged: { [weak self] in
                self?.startPresentationLoop()
            }
        )

        let shouldSnap = runtimeConfiguration.playbackMode != .natural
        let shouldSnapVisuals = shouldSnapVisualState(configuration: runtimeConfiguration)
        let visualTargetsChanged = reconcileVisibleRowViews(
            runtimeConfiguration: runtimeConfiguration,
            snapPositions: shouldSnap,
            snapVisuals: shouldSnapVisuals
        )
        if shouldSnap {
            if hasActiveTextAnimation(configuration: runtimeConfiguration) {
                startPresentationLoop()
            } else {
                stopPresentationLoopIfIdle()
            }
        }
        if visualTargetsChanged || hasActiveVisualMotion {
            startPresentationLoop()
        } else if !shouldSnap && (presentationEngine.hasActiveMotion || hasActiveTextAnimation(configuration: runtimeConfiguration)) {
            startPresentationLoop()
        }

        scheduleNativeLineAdvanceTimerIfNeeded(configuration: runtimeConfiguration)
    }

    @discardableResult
    private func reconcileVisibleRowViews(
        runtimeConfiguration: LyricsLayerRendererConfiguration,
        snapPositions: Bool,
        snapVisuals: Bool
    ) -> Bool {
        let visibleRows = visibleRows(for: runtimeConfiguration)
        let nextIDs = Set(visibleRows.map(\.id))
        var unmountedCount = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, view) in rowViews where !nextIDs.contains(id) {
            view.layer?.removeAllAnimations()
            view.removeFromSuperview()
            rowViews[id] = nil
            rowRenderKeys[id] = nil
            visualParitySignatures[id] = nil
            view.prepareForReuse()
            if rowViewReusePool.count < 80 {
                rowViewReusePool.append(view)
            }
            unmountedCount += 1
        }
        rowIDByIndex = Dictionary(uniqueKeysWithValues: visibleRows.map { ($0.index, $0.id) })
        rowTapHandlers = rowTapHandlers.filter { rowIndex, _ in
            visibleRows.contains { $0.index == rowIndex }
        }
        let visibleIndexSet = Set(visibleRows.map(\.index))
        visualStates = visualStates.filter { visibleIndexSet.contains($0.key) }
        interludeBlendStates = interludeBlendStates.filter { visibleIndexSet.contains($0.key) }

        let visualTargetsChanged = syncVisualTargets(
            runtimeConfiguration: runtimeConfiguration,
            visibleRows: visibleRows,
            snap: snapVisuals
        )
        let previousTextPhaseIndex = lastConfiguredTextPhaseIndex
        let activeTextPhaseIndex = runtimeConfiguration.effectiveCurrentIndex
        let textPhaseIndexChanged = previousTextPhaseIndex != activeTextPhaseIndex
        var mountedCount = 0
        do {
            for row in visibleRows {
                let view = rowViews[row.id] ?? rowViewReusePool.popLast() ?? NativeLyricsRowView()
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
                applyFrame(for: row, view: view, configuration: runtimeConfiguration, snap: snapPositions)
            }
        }
        CATransaction.commit()
        lastConfiguredTextPhaseIndex = activeTextPhaseIndex
        renderTelemetry.recordLifecycle(
            mounted: mountedCount,
            unmounted: unmountedCount,
            mountedRows: rowViews.count,
            renderedRows: visibleRows.count
        )
        return visualTargetsChanged
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
        // Stable positions: seed every not-yet-mounted row with its exact height ESTIMATE
        // (≈ the eventual measured height, same TextKit), so the accumulated offsets never fall
        // back to the flat 36pt default. That default made each incoming row snap ~30px the instant
        // it mounted and measured (the "排版来回改" jitter + cold-start blank). The estimate matches
        // the later measurement, so the row does not reflow when it actually mounts.
        for row in runtimeConfiguration.rows where measuredHeightsByIndex[row.index] == nil {
            measuredHeightsByIndex[row.index] = NativeLyricsRowMeasurement.estimatedHeight(
                for: row,
                rowWidth: runtimeConfiguration.rowWidth,
                showTranslation: runtimeConfiguration.showTranslation,
                isTranslating: runtimeConfiguration.isTranslating,
                pendingTranslationLineIndices: runtimeConfiguration.pendingTranslationLineIndices
            )
        }
        runtimeConfiguration.accumulatedHeights = NativeLyricsHeightAccumulator.accumulatedHeights(
            renderedIndices: runtimeConfiguration.renderedIndices,
            configuredAccumulatedHeights: runtimeConfiguration.accumulatedHeights,
            measuredHeights: measuredHeightsByIndex,
            interludeAfterIndex: runtimeConfiguration.interludeAfterIndex
        )
        synchronizeNativeSemanticIndex(configuration: &runtimeConfiguration)
        return runtimeConfiguration
    }

    private func synchronizeNativeSemanticIndex(
        configuration: inout LyricsLayerRendererConfiguration
    ) {
        guard configuration.playbackMode == .natural else {
            let snapIndex = configuration.effectiveCurrentIndex
            nativeSemanticCurrentIndex = snapIndex
            nativeTimelineState = NativeLyricsTimelinePolicy.AMLLState(
                playbackTime: configuration.musicController.lyricRenderTime(),
                hotGroups: [snapIndex],
                bufferedGroups: [snapIndex],
                scrollToIndex: snapIndex,
                semanticIndex: snapIndex
            )
            configuration.nativeSemanticCurrentIndex = snapIndex
            configuration.nativeScrollTargetIndex = snapIndex
            configuration.nativeHotActiveIndices = [snapIndex]
            configuration.nativeBufferedActiveIndices = [snapIndex]
            // Keep the seek token in sync: this branch already snapped, so a seek that happened in
            // snap mode must not re-fire when natural playback resumes.
            lastObservedSeekGeneration = configuration.musicController.seekGeneration
            cancelNativeLineAdvanceTimer()
            return
        }
        let isPlaying = configuration.musicController.isPlaying
        let seekToken = configuration.musicController.seekGeneration
        let explicitSeek = seekToken != lastObservedSeekGeneration
        if !isPlaying && !explicitSeek && pausedSemanticLocked && nativeSemanticCurrentIndex != nil {
            lastObservedSeekGeneration = seekToken
            configuration.nativeSemanticCurrentIndex = nativeSemanticCurrentIndex!
            if let ts = nativeTimelineState {
                configuration.nativeScrollTargetIndex = ts.scrollToIndex
                configuration.nativeHotActiveIndices = ts.hotGroups
                configuration.nativeBufferedActiveIndices = ts.bufferedGroups
            }
            scheduleNativeLineAdvanceTimerIfNeeded(configuration: configuration)
            return
        }
        if !isPlaying && !pausedSemanticLocked {
            pausedSemanticLocked = true
        } else if isPlaying && pausedSemanticLocked {
            pausedSemanticLocked = false
        }
        let playbackTime = configuration.musicController.lyricRenderTime()
        let provisional = NativeLyricsTimelinePolicy.amllState(
            at: playbackTime,
            rows: configuration.rows,
            fallback: configuration.currentIndex,
            previous: nativeTimelineState,
            isSeeking: false
        )
        let liveIndex = provisional.semanticIndex
        lastObservedSeekGeneration = seekToken
        let isSeek = NativeLyricsSeekClassifier.isSeek(
            previousIndex: nativeSemanticCurrentIndex,
            liveIndex: liveIndex,
            explicitSeek: explicitSeek
        )
        // On a seek, recompute with the buffered trail reset so the scroll snaps to the new line
        // instead of dragging the previous bright lines (and waving) toward it.
        let timelineState = isSeek
            ? NativeLyricsTimelinePolicy.amllState(
                at: playbackTime,
                rows: configuration.rows,
                fallback: configuration.currentIndex,
                previous: nativeTimelineState,
                isSeeking: true
            )
            : provisional
        let resolvedIndex = timelineState.semanticIndex
        if isSeek, nativeSemanticCurrentIndex != nil, nativeSemanticCurrentIndex != resolvedIndex {
            presentationEngine.update(
                LyricsPresentationEngineConfiguration(
                    currentIndex: resolvedIndex,
                    scrollTargetIndex: timelineState.scrollToIndex,
                    hotActiveIndices: timelineState.hotGroups,
                    bufferedActiveIndices: timelineState.bufferedGroups,
                    isManualScrolling: configuration.effectiveIsManualScrolling,
                    renderedIndices: configuration.renderedIndices,
                    anchorY: configuration.anchorY,
                    accumulatedHeights: configuration.accumulatedHeights,
                    lineInterval: lineInterval(around: resolvedIndex, rows: configuration.rows),
                    hasSyllableSync: configuration.rows.first(where: { $0.index == resolvedIndex })?.displayLine.line.hasSyllableSync ?? configuration.hasSyllableSync,
                    isInterludeActive: configuration.interludeAfterIndex != nil,
                    trackContext: configuration.trackContext,
                    isWaveTimelineDiagnosticsEnabled: configuration.isWaveTimelineDiagnosticsEnabled || DiagnosticsService.shared.isLyricWaveTimelineEnabled,
                    playbackMode: .directSnap(.seek)
                ),
                onTargetsChanged: { [weak self] in
                    self?.startPresentationLoop()
                }
            )
        }
        nativeTimelineState = timelineState
        nativeSemanticCurrentIndex = resolvedIndex
        configuration.nativeSemanticCurrentIndex = resolvedIndex
        configuration.nativeScrollTargetIndex = timelineState.scrollToIndex
        configuration.nativeHotActiveIndices = timelineState.hotGroups
        configuration.nativeBufferedActiveIndices = timelineState.bufferedGroups
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
        if let manualViewportIndex = manualViewportIndex(for: configuration) {
            var manualIndices = Set(NativeLyricsVisibleRowSelector.visibleIndices(
                allIndices: configuration.renderedIndices,
                currentIndex: manualViewportIndex,
                activeTargetIndices: [],
                radius: nativeLyricManualVisibleRowRadius
            ))
            manualIndices.insert(configuration.effectiveCurrentIndex)
            manualIndices.insert(configuration.effectiveScrollTargetIndex)
            manualIndices.formUnion(configuration.nativeBufferedActiveIndices)
            manualIndices.formUnion(geometryVisibleRowIndices(for: configuration))
            return configuration.rows.filter { manualIndices.contains($0.index) }
        }
        let visibleIndices = Set(NativeLyricsVisibleRowSelector.visibleIndices(
            allIndices: configuration.renderedIndices,
            currentIndex: configuration.effectiveScrollTargetIndex,
            activeTargetIndices: Set(presentationEngine.lineTargetIndices.keys)
                .union(configuration.nativeBufferedActiveIndices)
                .union([configuration.effectiveCurrentIndex]),
            radius: nativeLyricAutoVisibleRowRadius
        )).union(geometryVisibleRowIndices(for: configuration))
        return configuration.rows.filter { visibleIndices.contains($0.index) }
    }

    private func geometryVisibleRowIndices(
        for configuration: LyricsLayerRendererConfiguration
    ) -> Set<Int> {
        let viewportPadding: CGFloat = 120
        let viewport = CGRect(
            x: 0,
            y: -viewportPadding,
            width: max(1, bounds.width),
            height: max(1, bounds.height) + viewportPadding * 2
        )
        return Set(configuration.rows.compactMap { row in
            let minY = modelY(for: row, configuration: configuration)
            let height = max(1, measuredHeightsByIndex[row.index] ?? 46)
            let frame = CGRect(x: 0, y: minY, width: configuration.rowWidth, height: height)
            return frame.intersects(viewport) ? row.index : nil
        })
    }

    private func manualViewportIndex(for configuration: LyricsLayerRendererConfiguration) -> Int? {
        guard configuration.effectiveIsManualScrolling else { return nil }
        guard let frozenOffset = configuration.accumulatedHeights[configuration.effectiveCurrentIndex] else {
            return nil
        }
        let viewportOffset = frozenOffset - configuration.effectiveManualOffset
        return configuration.renderedIndices.min { lhs, rhs in
            let lhsDistance = abs((configuration.accumulatedHeights[lhs] ?? 0) - viewportOffset)
            let rhsDistance = abs((configuration.accumulatedHeights[rhs] ?? 0) - viewportOffset)
            return lhsDistance < rhsDistance
        }
    }

    func stopAnimations() {
        removeLocalEventMonitor()
        cancelManualScrollTimers()
        cancelNativeLineAdvanceTimer()
        manualScrollState.reset()
        manualPresentationNeedsApply = false
        nativeSemanticCurrentIndex = nil
        nativeTimelineState = nil
        pausedSemanticLocked = false
        lastTextPhaseUpdateAt = nil
        pendingTapToLineSettleTiming = nil
        visualStates.removeAll()
        interludeBlendStates.removeAll()
        measuredHeightsByIndex.removeAll()
        stopNativeLineMotionSamplingTimer()
        presentationEngine.stop()
        stopPresentationLoop()
        for view in rowViews.values {
            view.layer?.removeAllAnimations()
        }
        rowViewReusePool.removeAll()
        rowIDByIndex.removeAll()
        lastConfiguredTextPhaseIndex = nil
        if let configuration {
            flushRenderTelemetry(reason: "stop-animations", track: configuration.trackContext)
        }
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

    private var hasActiveVisualMotion: Bool {
        visualStates.values.contains { !$0.isSettled }
            || interludeBlendStates.values.contains { !$0.isSettled }
    }

    private func shouldSnapVisualState(configuration: LyricsLayerRendererConfiguration) -> Bool {
        switch configuration.playbackMode {
        case .natural:
            return false
        case .directSnap(let reason):
            switch reason {
            case .initialLayout, .trackReset, .seek, .reducedMotion, .tapToLine, .manualScroll:
                return true
            }
        }
    }

    @discardableResult
    private func syncVisualTargets(
        runtimeConfiguration: LyricsLayerRendererConfiguration,
        visibleRows: [LayerBackedLyricRow]? = nil,
        snap: Bool
    ) -> Bool {
        let rows = visibleRows ?? self.visibleRows(for: runtimeConfiguration)
        let now = CACurrentMediaTime()
        var changed = false
        for row in rows {
            let target = visualTarget(for: row, configuration: runtimeConfiguration, now: now)
            if visualStates[row.index] == nil {
                visualStates[row.index] = NativeLyricsVisualMotionState(target: target)
                changed = true
            } else if snap {
                let before = visualStates[row.index]
                visualStates[row.index]?.snap(to: target)
                changed = changed || before != visualStates[row.index]
            } else {
                let wasActive = visualStates[row.index]?.target.isActive ?? false
                let isNowActive = target.isActive
                if wasActive != isNowActive {
                    visualStates[row.index]?.quickRetarget(to: target)
                    changed = true
                } else {
                    changed = visualStates[row.index]?.setTarget(target) == true || changed
                }
            }
        }
        return changed
    }

    @discardableResult
    private func advanceVisualStates(delta: TimeInterval) -> Bool {
        // Drive blur/scale/opacity on the SAME spring as line position so the depth-of-field stays
        // locked to the scroll (no past-sharper-than-upcoming lag during transitions).
        let spring = presentationEngine.currentVisualSpringParameters
        var changed = false
        for index in visualStates.keys {
            changed = visualStates[index]?.advance(delta: delta, spring: spring) == true || changed
        }
        return changed
    }

    private func visualTarget(
        for row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration,
        now: CFTimeInterval
    ) -> NativeLyricsVisualTarget {
        let isPrecedingInterlude = configuration.interludeAfterIndex == row.index
        let blend = interludeBlend(
            for: row.index,
            isPrecedingInterlude: isPrecedingInterlude,
            now: now
        )
        return NativeLyricsVisualTarget.amllTarget(
            displayIndex: row.index,
            currentIndex: configuration.effectiveCurrentIndex,
            scrollTargetIndex: configuration.effectiveScrollTargetIndex,
            hotActiveIndices: configuration.nativeHotActiveIndices,
            isManualScrolling: configuration.effectiveIsManualScrolling,
            interludeBlend: blend
        )
    }

    private func interludeBlend(
        for rowIndex: Int,
        isPrecedingInterlude: Bool,
        now: CFTimeInterval
    ) -> CGFloat {
        let nextTarget: CGFloat = isPrecedingInterlude ? 1 : 0
        if interludeBlendStates[rowIndex] == nil {
            interludeBlendStates[rowIndex] = NativeLyricsInterludeBlendState(value: 0, now: now)
        }
        _ = interludeBlendStates[rowIndex]?.setTarget(nextTarget, now: now)
        return interludeBlendStates[rowIndex]?.value(at: now) ?? nextTarget
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
        let fallbackTarget = visualTarget(for: row, configuration: configuration, now: CACurrentMediaTime())
        let visual = visualStates[row.index] ?? NativeLyricsVisualMotionState(target: fallbackTarget)
        let height = measuredHeightsByIndex[row.index] ?? max(1, view.frame.height)
        let frame = CGRect(x: 0, y: 0, width: configuration.rowWidth, height: max(1, height))

        if view.frame.size != frame.size || view.frame.origin != .zero {
            view.frame = frame
        }
        view.layer?.opacity = Float(visual.opacity)
        view.layer?.setAffineTransform(
            CGAffineTransform(translationX: 0, y: y)
                .scaledBy(x: visual.scale, y: visual.scale)
        )
        let appliedTransform = view.layer?.affineTransform() ?? .identity
        let appliedScale = sqrt(appliedTransform.a * appliedTransform.a + appliedTransform.c * appliedTransform.c)
        recordRowFrameParityIfChanged(rowID: row.id, sample: NativeLyricsRowFrameParitySample(
            expectedY: y,
            appliedY: appliedTransform.ty,
            expectedHeight: frame.height,
            appliedHeight: view.frame.height,
            expectedScale: visual.scale,
            appliedScale: appliedScale
        ))
        let appliedBlur = view.applyBlurRadius(visual.blur)
        recordVisualParityIfChanged(rowID: row.id, sample: NativeLyricsVisualParitySample(
            expectedOpacity: visual.opacity,
            appliedOpacity: CGFloat(view.layer?.opacity ?? 0),
            expectedScale: visual.scale,
            appliedScale: appliedScale,
            expectedBlurRadius: visual.blur > 0.1 ? sqrt(visual.blur) * NativeLyricsRowView.blurRenderCalibration : 0,
            appliedBlurRadius: appliedBlur,
            isActive: visual.target.isActive,
            isSettled: visual.isSettled
        ))
    }

    private func withDisabledLayerActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func modelY(
        for row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> CGFloat {
        let baseY = presentationEngine.presentation(for: row.index)?.y
            ?? snapY(for: row, configuration: configuration)
        return baseY + configuration.effectiveManualOffset
    }

    private func renderedY(
        for row: LayerBackedLyricRow,
        view: NativeLyricsRowView,
        configuration: LyricsLayerRendererConfiguration
    ) -> CGFloat {
        let fallback = modelY(for: row, configuration: configuration)
        guard let layer = view.layer else { return fallback }
        let modelY = layer.affineTransform().ty
        let hasCoreAnimation = layer.animationKeys()?.isEmpty == false
        guard hasCoreAnimation,
              let presentationY = layer.presentation()?.affineTransform().ty else {
            return modelY
        }
        return presentationY
    }

    private func currentRenderedYByIndex(
        configuration: LyricsLayerRendererConfiguration
    ) -> [Int: CGFloat] {
        Dictionary(uniqueKeysWithValues: visibleRows(for: configuration).compactMap { row in
            guard let view = rowViews[row.id] else { return nil }
            return (row.index, renderedY(for: row, view: view, configuration: configuration))
        })
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
            let y = renderedY(for: row, view: view, configuration: configuration)
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

    @discardableResult
    func captureLineMotionFrames(timestamp: Date, playbackTime: TimeInterval) -> Bool {
        guard let configuration else { return false }
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        reportLineMotionFrames(
            configuration: runtimeConfiguration,
            timestamp: timestamp,
            playbackTime: playbackTime
        )
        return true
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

    private func sampleNativeLineMotionDuringPresentationTickIfNeeded(
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        guard runtimeConfiguration.lineMotionSamplingEnabled,
              presentationEngine.hasActiveMotion else { return }

        let now = Date()
        let playbackTime = runtimeConfiguration.musicController.lyricRenderTime(at: now)
        let sortedRows = runtimeConfiguration.rows.sorted { $0.index < $1.index }
        let lyrics = sortedRows.map(\.displayLine.line)
        guard !lyrics.isEmpty else { return }
        let firstRealIndex = min(
            max(runtimeConfiguration.lineMotionFirstRealDisplayIndex, 0),
            max(lyrics.count - 1, 0)
        )
        let policyInterval = LyricMotionSamplingPolicy.sampleInterval(
            focusedWindowActive: now <= runtimeConfiguration.lineMotionFocusedSamplingUntil,
            playbackTime: playbackTime,
            lyrics: lyrics,
            firstRealIndex: firstRealIndex
        )
        let sampleInterval = min(policyInterval, LyricMotionSamplingPolicy.focusedInterval)
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
                    fallback: configuration.effectiveScrollTargetIndex
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
                ?? presentationEngine.targetIndex(for: row.index, fallback: configuration.effectiveScrollTargetIndex)
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
                frozenDisplayIndex: configuration.effectiveIsManualScrolling ? configuration.effectiveScrollTargetIndex : nil,
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
            ? configuration.effectiveScrollTargetIndex
            : presentationEngine.targetIndex(
                for: row.index,
                fallback: configuration.effectiveScrollTargetIndex
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
            self.updateSurfaceInterludeDots(configuration: runtimeConfiguration, snap: snap)
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
            view.displayLinkScheduler.enqueue(
                displayInterval: displayInterval,
                displayTimestamp: displayTimestamp
            ) { [weak view] displayInterval, displayTimestamp in
                view?.presentationTick(
                    displayInterval: displayInterval,
                    displayTimestamp: displayTimestamp
                )
            }
            return kCVReturnSuccess
        }, context)
        displayLink = link
        lastPresentationTick = nil
        lastFrameCadenceTick = nil
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
        guard pendingTapToLineSettleTiming == nil,
              !presentationEngine.hasActiveMotion,
              !hasActiveVisualMotion,
              !hasActiveTextAnimation(configuration: runtimeConfiguration),
              runtimeConfiguration.interludeAfterIndex == nil else { return }
        stopPresentationLoop()
    }

    private func stopPresentationLoop() {
        guard let activeDisplayLink = displayLink else { return }
        CVDisplayLinkStop(activeDisplayLink)
        self.displayLink = nil
        lastPresentationTick = nil
        lastFrameCadenceTick = nil
        displayLinkScheduler.reset()
        flushFrameSummary(reason: "stop")
    }

    private func presentationTick(
        displayInterval: TimeInterval?,
        displayTimestamp: TimeInterval?
    ) {
        _ = displayTimestamp
        guard let configuration else {
            stopPresentationLoop()
            return
        }
        let previousSemanticIndex = nativeSemanticCurrentIndex
        let previousTimelineState = nativeTimelineState
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        let now = CACurrentMediaTime()
        let delta = lastPresentationTick.map { max(0, now - $0) }
            ?? displayInterval
            ?? 0
        lastPresentationTick = now
        let semanticChanged = updateNativeTimelineForCurrentPlaybackIfNeeded(
            previousIndex: previousSemanticIndex,
            previousTimelineState: previousTimelineState,
            runtimeConfiguration: runtimeConfiguration
        )
        let visualTargetsChanged = shouldSyncVisualTargetsOnPresentationTick(
            semanticChanged: semanticChanged,
            runtimeConfiguration: runtimeConfiguration
        )
            ? syncVisualTargets(runtimeConfiguration: runtimeConfiguration, snap: false)
            : false
        let visualMotionChanged = advanceVisualStates(delta: delta)
        let motionChanged = presentationEngine.advance(delta: delta)
        let shouldApplyManualPresentation = manualPresentationNeedsApply
        let activeTextLineChanged = previousSemanticIndex != runtimeConfiguration.effectiveCurrentIndex
        let shouldUpdateTextPhase = shouldUpdateActiveTextPhase(
            runtimeConfiguration: runtimeConfiguration,
            now: now,
            force: activeTextLineChanged || shouldApplyManualPresentation
        )
        let shouldApplyPresentationFrame = shouldApplyManualPresentation
            || semanticChanged
            || motionChanged
            || presentationEngine.hasActiveMotion
            || visualTargetsChanged
            || visualMotionChanged
            || hasActiveVisualMotion
        manualPresentationNeedsApply = false
        withDisabledLayerActions {
            if activeTextLineChanged {
                refreshTextRowsForActiveLineChange(
                    previousIndex: previousSemanticIndex,
                    currentIndex: runtimeConfiguration.effectiveCurrentIndex,
                    runtimeConfiguration: runtimeConfiguration
                )
            }
            if shouldUpdateTextPhase {
                updateTextPhasesForCurrentConfiguration(runtimeConfiguration: runtimeConfiguration)
            }
            if shouldApplyManualPresentation {
                if presentationEngine.isNaturalWaveActive {
                    presentationEngine.update(
                        engineConfiguration(from: runtimeConfiguration),
                        onTargetsChanged: { [weak self] in
                            self?.startPresentationLoop()
                        }
                    )
                }
                applyFrames(runtimeConfiguration: runtimeConfiguration, snap: true, managesTransaction: false)
            } else if shouldApplyPresentationFrame {
                applyFrames(runtimeConfiguration: runtimeConfiguration, snap: false, managesTransaction: false)
            }
        }
        if shouldApplyPresentationFrame {
            recordFrameDelta(expectedRefreshInterval: displayInterval, now: now)
        } else {
            lastFrameCadenceTick = nil
        }
        if runtimeConfiguration.interludeAfterIndex != nil {
            withDisabledLayerActions {
                updateSurfaceInterludeDots(configuration: runtimeConfiguration, snap: false)
            }
        }
        sampleNativeLineMotionDuringPresentationTickIfNeeded(runtimeConfiguration: runtimeConfiguration)
        checkPendingTapToLineSettleTiming(now: now)
        stopPresentationLoopIfIdle(runtimeConfiguration: runtimeConfiguration)
    }

    private func refreshTextRowsForActiveLineChange(
        previousIndex: Int?,
        currentIndex: Int,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        if let previousIndex, previousIndex != currentIndex,
           let prevRow = runtimeConfiguration.rows.first(where: { $0.index == previousIndex }),
           let prevView = rowViews[prevRow.id] {
            prevView.clearSweepState()
            _ = updateContentIfNeeded(view: prevView, row: prevRow, configuration: runtimeConfiguration)
        }
        if let row = runtimeConfiguration.rows.first(where: { $0.index == currentIndex }),
           let view = rowViews[row.id] {
            _ = updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
        }
        lastConfiguredTextPhaseIndex = currentIndex
    }

    private func shouldSyncVisualTargetsOnPresentationTick(
        semanticChanged: Bool,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) -> Bool {
        semanticChanged
            || runtimeConfiguration.effectiveIsManualScrolling
            || runtimeConfiguration.interludeAfterIndex != nil
            || visualStates.isEmpty
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
        lastFrameCadenceTick = nil
        frameCadence = NativeLyricsFrameCadenceAccumulator()
    }

    private func recordFrameDelta(
        expectedRefreshInterval: TimeInterval?,
        now: CFTimeInterval
    ) {
        let delta = lastFrameCadenceTick.map { max(0, now - $0) }
            ?? expectedRefreshInterval
            ?? 0
        lastFrameCadenceTick = now
        guard delta > 0 else { return }
        frameCadence.record(delta: delta, expectedRefreshInterval: expectedRefreshInterval)
        guard let startedAt = frameSummaryStartedAt else {
            resetFrameSummary(at: now)
            return
        }
        if now - startedAt >= nativeLyricFrameSummaryInterval {
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let surfaceTrackingArea {
            removeTrackingArea(surfaceTrackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        surfaceTrackingArea = next
        addTrackingArea(next)
    }

    override func mouseMoved(with event: NSEvent) {
        updateNativeHoverFromEvent(event)
    }

    override func mouseExited(with event: NSEvent) {
        clearNativeHover()
    }

    override func mouseDown(with event: NSEvent) {
        if handleNativeMouseDown(event) { return }
        super.mouseDown(with: event)
    }

    @discardableResult
    private func handleNativeMouseDown(_ event: NSEvent) -> Bool {
        guard let configuration else {
            return false
        }
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        let point = convert(event.locationInWindow, from: nil)
        guard !isPointInReservedOverlayZone(point, configuration: runtimeConfiguration) else {
            return false
        }
        let hit = runtimeConfiguration.rows
            .compactMap { row -> (Int, CGRect)? in
                guard let view = rowViews[row.id] else { return nil }
                let y = renderedY(for: row, view: view, configuration: runtimeConfiguration)
                return (row.index, CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height))
            }
            .sorted { lhs, rhs in abs(lhs.1.midY - point.y) < abs(rhs.1.midY - point.y) }
            .first { _, frame in frame.contains(point) }

        if let index = hit?.0, let handler = rowTapHandlers[index] {
            handler()
            return true
        }
        if manualScrollState.isActive,
           let hoveredRowIndex,
           let row = runtimeConfiguration.rows.first(where: { $0.index == hoveredRowIndex }),
           let view = rowViews[row.id] {
            let y = renderedY(for: row, view: view, configuration: runtimeConfiguration)
            let hoverFrame = CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height)
                .insetBy(dx: 0, dy: -24)
            if hoverFrame.contains(point),
               let handler = rowTapHandlers[hoveredRowIndex] {
                handler()
                return true
            }
        }
        return false
    }

    private func updateNativeHoverFromEvent(_ event: NSEvent) {
        guard let configuration else { return }
        let point = convert(event.locationInWindow, from: nil)
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        guard !isPointInReservedOverlayZone(point, configuration: runtimeConfiguration) else {
            clearNativeHover()
            return
        }
        updateNativeHover(from: point, configuration: runtimeConfiguration)
    }

    private func clearNativeHover() {
        guard let hoveredRowIndex else { return }
        if let configuration,
           let row = runtimeConfiguration(from: configuration).rows.first(where: { $0.index == hoveredRowIndex }),
           let view = rowViews[row.id] {
            view.setPointerHovering(false)
        }
        self.hoveredRowIndex = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if handleNativeScrollWheel(event) { return }
        super.scrollWheel(with: event)
    }

    @discardableResult
    private func handleNativeScrollWheel(_ event: NSEvent) -> Bool {
        guard let configuration else {
            renderTelemetry.recordIgnoredManualScroll(reason: .outOfBounds)
            return false
        }
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        let point = convert(event.locationInWindow, from: nil)
        let isInsideSurface = bounds.insetBy(dx: -4, dy: -4).contains(point)
        guard isInsideSurface || manualScrollState.isActive else {
            renderTelemetry.recordIgnoredManualScroll(reason: .outOfBounds)
            return false
        }
        let absX = abs(event.scrollingDeltaX)
        let absY = abs(event.scrollingDeltaY)
        guard absY >= 0.1, !(absX > absY * 1.5 && absX > 1.0) else {
            renderTelemetry.recordIgnoredManualScroll(reason: .horizontal)
            return false
        }

        let isMomentum = event.momentumPhase != []
        if isMomentum && !manualScrollState.isActive {
            renderTelemetry.recordIgnoredManualScroll(reason: .momentumWithoutOwnership)
            return true
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            scheduleNativeScrollEnd(delay: 2.0)
            return true
        }

        let deltaY = event.scrollingDeltaY
        let threshold: CGFloat = isMomentum ? 0.1 : 0.5
        guard abs(deltaY) >= threshold else {
            renderTelemetry.recordIgnoredManualScroll(reason: .tooSmall)
            return true
        }

        let previousViewportIndex = manualViewportIndex(for: runtimeConfiguration)
        let isNewGesture = event.phase == .began
        beginNativeManualScrollIfNeeded(configuration: runtimeConfiguration)
        if isNewGesture && manualScrollState.isActive {
            let onChromeReset = configuration.onManualScrollChromeReset
            deferParentCallback { onChromeReset?() }
        }
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
            bounds: manualScrollBounds(for: runtimeConfiguration)
        )
        let updatedRuntimeConfiguration = self.runtimeConfiguration(from: configuration)
        let updatedViewportIndex = manualViewportIndex(for: updatedRuntimeConfiguration)
        if updatedViewportIndex != previousViewportIndex {
            _ = reconcileVisibleRowViews(
                runtimeConfiguration: updatedRuntimeConfiguration,
                snapPositions: true,
                snapVisuals: false
            )
        }
        if isInsideSurface {
            updateNativeHover(from: point, configuration: updatedRuntimeConfiguration)
        } else {
            clearNativeHover()
        }
        renderTelemetry.recordManualScrollDelta(
            deltaY: deltaY,
            velocityY: velocity,
            manualOffsetY: manualScrollState.manualOffset
        )
        queueNativeManualScrollPresentation()
        let onManualScrollDelta = configuration.onManualScrollDelta
        deferParentCallback {
            onManualScrollDelta(deltaY, velocity)
        }
        scheduleNativeScrollEnd(delay: 2.0)
        return true
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
        }
        // Spring to the tapped line from current on-screen positions instead of a hard
        // position snap. v2.8 parity: LyricLineView lets `.animation(value: fullOffset)`
        // own the transition (LyricsView.swift:1671-1672); the spring continues from where
        // the rows visually are (manual offset included) so the jump is smooth, not abrupt.
        if let configuration {
            semanticSpringRetarget(
                to: rowIndex,
                reason: .tapToLine,
                currentYByIndex: currentRenderedYByIndex(configuration: runtimeConfiguration(from: configuration))
            )
        }
        recordTapToLineSettleTiming(targetIndex: rowIndex, startedAt: startedAt)
        let onManualScrollRecovered = configuration?.onManualScrollRecovered
        let onLineTap = configuration?.onLineTap
        deferParentCallback {
            onManualScrollRecovered?()
            onLineTap?(line)
        }
    }

    private func beginNativeManualScrollIfNeeded(configuration: LyricsLayerRendererConfiguration) {
        guard !manualScrollState.isActive else { return }
        manualScrollState.begin(frozenDisplayIndex: configuration.effectiveScrollTargetIndex)
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        let shouldSnapVisuals = shouldSnapVisualState(configuration: runtimeConfiguration)
        _ = reconcileVisibleRowViews(
            runtimeConfiguration: runtimeConfiguration,
            snapPositions: true,
            snapVisuals: shouldSnapVisuals
        )
        renderTelemetry.recordManualScrollStart()
        refreshRowInteractionState(configuration: runtimeConfiguration)
        queueNativeManualScrollPresentation()
        let frozenIndex = configuration.effectiveScrollTargetIndex
        let onManualScrollStarted = configuration.onManualScrollStarted
        deferParentCallback {
            onManualScrollStarted(frozenIndex)
        }
    }

    private func endNativeManualScrollInteraction() {
        guard let configuration, manualScrollState.isActive else { return }
        manualScrollEndTimer?.invalidate()
        lastScrollWheelTime = 0
        manualScrollState.clampToBounds(manualScrollBounds(for: runtimeConfiguration(from: configuration)))
        renderTelemetry.recordManualScrollEnd()
        queueNativeManualScrollPresentation()
        let onManualScrollEnded = configuration.onManualScrollEnded
        deferParentCallback {
            onManualScrollEnded()
        }
        manualScrollRecoveryTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
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
        let scrolledConfiguration = runtimeConfiguration(from: configuration)
        let liveIndex = liveDisplayIndex(configuration: scrolledConfiguration)
        // Capture where the rows currently sit (the manual-scrolled offset) BEFORE resetting,
        // so the spring releases smoothly from that position back to the live line.
        let scrolledYByIndex = currentRenderedYByIndex(configuration: scrolledConfiguration)
        manualScrollState.reset()
        renderTelemetry.recordManualScrollRecovery()
        refreshRowInteractionState(configuration: runtimeConfiguration(from: configuration))
        // Spring-release to the live line (v2.8 parity) instead of an abrupt hard snap.
        semanticSpringRetarget(to: liveIndex, reason: .manualScroll, currentYByIndex: scrolledYByIndex)
        let onManualScrollRecovered = configuration.onManualScrollRecovered
        deferParentCallback {
            onManualScrollRecovered()
        }
    }

    private func queueNativeManualScrollPresentation() {
        manualPresentationNeedsApply = true
        startPresentationLoop()
    }

    private func forceDirectSnap(to index: Int, reason: LyricsPresentationDirectSnapReason) {
        guard let configuration else { return }
        renderTelemetry.recordDirectSnap(reason: reason)
        var runtimeConfiguration = runtimeConfiguration(from: configuration)
        runtimeConfiguration.nativeDirectSnapIndex = index
        runtimeConfiguration.nativeDirectSnapReason = reason
        runtimeConfiguration.nativeSemanticCurrentIndex = index
        runtimeConfiguration.nativeScrollTargetIndex = index
        runtimeConfiguration.nativeHotActiveIndices = [index]
        runtimeConfiguration.nativeBufferedActiveIndices = [index]
        nativeSemanticCurrentIndex = index
        nativeTimelineState = NativeLyricsTimelinePolicy.AMLLState(
            playbackTime: runtimeConfiguration.musicController.lyricRenderTime(),
            hotGroups: [index],
            bufferedGroups: [index],
            scrollToIndex: index,
            semanticIndex: index
        )
        refreshRowInteractionState(configuration: runtimeConfiguration)
        presentationEngine.update(
            engineConfiguration(from: runtimeConfiguration),
            onTargetsChanged: { [weak self] in
                self?.startPresentationLoop()
            }
        )
        let visualTargetsChanged = reconcileVisibleRowViews(
            runtimeConfiguration: runtimeConfiguration,
            snapPositions: true,
            snapVisuals: shouldSnapVisualState(configuration: runtimeConfiguration)
        )
        if visualTargetsChanged || hasActiveVisualMotion || hasActiveTextAnimation(configuration: runtimeConfiguration) {
            startPresentationLoop()
        }
    }

    private func semanticSpringRetarget(
        to index: Int,
        reason: LyricsPresentationDirectSnapReason,
        currentYByIndex: [Int: CGFloat]
    ) {
        guard let configuration else { return }
        renderTelemetry.recordDirectSnap(reason: reason)
        var runtimeConfiguration = runtimeConfiguration(from: configuration)
        runtimeConfiguration.nativeDirectSnapIndex = nil
        runtimeConfiguration.nativeDirectSnapReason = nil
        runtimeConfiguration.nativeSemanticCurrentIndex = index
        runtimeConfiguration.nativeScrollTargetIndex = index
        runtimeConfiguration.nativeHotActiveIndices = [index]
        runtimeConfiguration.nativeBufferedActiveIndices = [index]
        nativeSemanticCurrentIndex = index
        refreshRowInteractionState(configuration: runtimeConfiguration)
        presentationEngine.retargetFromCurrentPresentation(
            to: index,
            configuration: engineConfiguration(from: runtimeConfiguration),
            currentYByIndex: currentYByIndex,
            onTargetsChanged: { [weak self] in
                self?.startPresentationLoop()
            }
        )
        let visualTargetsChanged = syncVisualTargets(
            runtimeConfiguration: runtimeConfiguration,
            snap: false
        )
        withDisabledLayerActions {
            for row in visibleRows(for: runtimeConfiguration) {
                guard let view = rowViews[row.id] else { continue }
                updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
                applyFrame(for: row, view: view, configuration: runtimeConfiguration, snap: false)
            }
        }
        if visualTargetsChanged || presentationEngine.hasActiveMotion || hasActiveVisualMotion || hasActiveTextAnimation(configuration: runtimeConfiguration) {
            startPresentationLoop()
        }
    }

    private func recordTapToLineSettleTiming(targetIndex: Int, startedAt: CFTimeInterval) {
        pendingTapToLineSettleTiming = (
            targetIndex: targetIndex,
            startedAt: startedAt,
            deadline: startedAt + 0.25
        )
        checkPendingTapToLineSettleTiming(now: CACurrentMediaTime())
        if pendingTapToLineSettleTiming != nil {
            startPresentationLoop()
        }
    }

    private func checkPendingTapToLineSettleTiming(now: CFTimeInterval) {
        guard let pending = pendingTapToLineSettleTiming else { return }
        guard let configuration else { return }
        var runtimeConfiguration = runtimeConfiguration(from: configuration)
        runtimeConfiguration.nativeDirectSnapIndex = pending.targetIndex
        runtimeConfiguration.nativeDirectSnapReason = .tapToLine
        runtimeConfiguration.nativeSemanticCurrentIndex = pending.targetIndex
        runtimeConfiguration.nativeScrollTargetIndex = pending.targetIndex
        runtimeConfiguration.nativeHotActiveIndices = [pending.targetIndex]
        runtimeConfiguration.nativeBufferedActiveIndices = [pending.targetIndex]
        guard let row = runtimeConfiguration.rows.first(where: { $0.index == pending.targetIndex }),
              let view = rowViews[row.id] else {
            if now >= pending.deadline {
                let elapsed = CGFloat(max(0, now - pending.startedAt))
                renderTelemetry.recordTapToLineTiming(latency: elapsed, settleTime: elapsed)
                pendingTapToLineSettleTiming = nil
            }
            return
        }
        let expectedY = snapY(for: row, configuration: runtimeConfiguration)
        let appliedY = renderedY(for: row, view: view, configuration: runtimeConfiguration)
        guard abs(appliedY - expectedY) <= 0.5 || now >= pending.deadline else { return }
        let elapsed = CGFloat(max(0, now - pending.startedAt))
        renderTelemetry.recordTapToLineTiming(latency: elapsed, settleTime: elapsed)
        pendingTapToLineSettleTiming = nil
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
                let y = renderedY(for: row, view: view, configuration: configuration)
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
        previousTimelineState: NativeLyricsTimelinePolicy.AMLLState?,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) -> Bool {
        guard runtimeConfiguration.playbackMode == .natural else {
            scheduleNativeLineAdvanceTimerIfNeeded(configuration: runtimeConfiguration)
            return false
        }
        let nextIndex = runtimeConfiguration.effectiveCurrentIndex
        guard previousIndex != nextIndex
            || Self.hasTimelineTargetChange(previousTimelineState, nativeTimelineState) else {
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

    private static func hasTimelineTargetChange(
        _ lhs: NativeLyricsTimelinePolicy.AMLLState?,
        _ rhs: NativeLyricsTimelinePolicy.AMLLState?
    ) -> Bool {
        lhs?.hotGroups != rhs?.hotGroups
            || lhs?.bufferedGroups != rhs?.bufferedGroups
            || lhs?.scrollToIndex != rhs?.scrollToIndex
            || lhs?.semanticIndex != rhs?.semanticIndex
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
        let previousTimelineState = nativeTimelineState
        let changed = updateNativeTimelineForCurrentPlaybackIfNeeded(
            previousIndex: previousSemanticIndex,
            previousTimelineState: previousTimelineState,
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
        let scrollTargetIndex = configuration.effectiveScrollTargetIndex
        return LyricsPresentationEngineConfiguration(
            currentIndex: currentIndex,
            scrollTargetIndex: scrollTargetIndex,
            hotActiveIndices: configuration.nativeHotActiveIndices,
            bufferedActiveIndices: configuration.nativeBufferedActiveIndices,
            isManualScrolling: configuration.effectiveIsManualScrolling,
            renderedIndices: configuration.renderedIndices,
            anchorY: configuration.anchorY,
            accumulatedHeights: configuration.accumulatedHeights,
            lineInterval: lineInterval(around: scrollTargetIndex, rows: configuration.rows)
                ?? lineInterval(around: currentIndex, rows: configuration.rows)
                ?? configuration.lineInterval,
            hasSyllableSync: configuration.rows.first(where: { $0.index == currentIndex })?.displayLine.line.hasSyllableSync ?? configuration.hasSyllableSync,
            isInterludeActive: configuration.interludeAfterIndex != nil,
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
        let currentIndex = configuration.effectiveScrollTargetIndex
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

    private func isPointInReservedOverlayZone(
        _ point: CGPoint,
        configuration: LyricsLayerRendererConfiguration
    ) -> Bool {
        guard configuration.controlsVisible else { return false }
        let bottomY = max(0, bounds.height - nativeLyricsBottomControlsReservedHeight)
        let reservedRects = [
            CGRect(x: 0, y: 0, width: nativeLyricsTopLeadingReservedWidth, height: nativeLyricsTopOverlayReservedHeight),
            CGRect(
                x: max(0, bounds.width - nativeLyricsTopTrailingReservedWidth),
                y: 0,
                width: nativeLyricsTopTrailingReservedWidth,
                height: nativeLyricsTopOverlayReservedHeight
            ),
            CGRect(x: 0, y: bottomY, width: bounds.width, height: nativeLyricsBottomControlsReservedHeight)
        ]
        return reservedRects.contains(where: { $0.contains(point) })
    }

    private func liveDisplayIndex(configuration: LyricsLayerRendererConfiguration) -> Int {
        let renderTime = configuration.musicController.lyricRenderTime()
        let state = NativeLyricsTimelinePolicy.amllState(
            at: renderTime,
            rows: configuration.rows,
            fallback: configuration.effectiveCurrentIndex,
            previous: nativeTimelineState,
            isSeeking: true
        )
        return state.scrollToIndex
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
            let awaitingTranslation = LyricLineTranslationLayoutPolicy.isAwaitingTranslation(
                index: row.displayLine.sourceIndex,
                line: row.sourceLine,
                pendingLineIndices: configuration.pendingTranslationLineIndices,
                isTranslating: configuration.isTranslating,
                segmentIndex: row.displayLine.segmentIndex
            )
            self.isAwaitingTranslation = awaitingTranslation
            self.translationFailed = configuration.translationFailed
                && row.index == configuration.effectiveCurrentIndex
                && awaitingTranslation
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

    private struct RowFrameParitySignature: Equatable {
        let yError: Int
        let heightError: Int
        let scaleError: Int

        init(_ sample: NativeLyricsRowFrameParitySample) {
            yError = Self.quantize(sample.yError, scale: 10)
            heightError = Self.quantize(sample.heightError, scale: 10)
            scaleError = Self.quantize(sample.scaleError, scale: 1000)
        }

        private static func quantize(_ value: CGFloat, scale: CGFloat) -> Int {
            Int((value * scale).rounded(.toNearestOrAwayFromZero))
        }
    }

    private func recordVisualParityIfChanged(rowID: String, sample: NativeLyricsVisualParitySample) {
        guard sample.isSettled || sample.isActive else { return }
        let signature = VisualParitySignature(sample)
        guard visualParitySignatures[rowID] != signature else { return }
        visualParitySignatures[rowID] = signature
        renderTelemetry.recordVisualParity(sample)
    }

    private func recordRowFrameParityIfChanged(rowID: String, sample: NativeLyricsRowFrameParitySample) {
        let signature = RowFrameParitySignature(sample)
        guard rowFrameParitySignatures[rowID] != signature else { return }
        rowFrameParitySignatures[rowID] = signature
        renderTelemetry.recordRowFrameParity(sample)
    }

    fileprivate func recordHoverBackgroundParity(_ sample: NativeLyricsHoverParitySample) {
        renderTelemetry.recordHoverParity(sample)
    }

    fileprivate func recordDotPhase(_ sample: NativeLyricsDotPhaseSample) {
        renderTelemetry.recordDotPhase(sample)
    }

    fileprivate func recordTextPhase(_ sample: NativeLyricsTextPhaseSample) {
        renderTelemetry.recordTextPhase(sample)
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

    private func shouldUpdateActiveTextPhase(
        runtimeConfiguration: LyricsLayerRendererConfiguration,
        now: CFTimeInterval,
        force: Bool
    ) -> Bool {
        if force {
            lastTextPhaseUpdateAt = now
            return true
        }
        guard hasActiveTextAnimation(configuration: runtimeConfiguration) else {
            return false
        }
        guard let lastTextPhaseUpdateAt else {
            self.lastTextPhaseUpdateAt = now
            return true
        }
        guard now - lastTextPhaseUpdateAt >= nativeLyricTextFrameInterval else {
            return false
        }
        self.lastTextPhaseUpdateAt = now
        return true
    }

    private func hasActiveTextAnimation(configuration: LyricsLayerRendererConfiguration) -> Bool {
        guard configuration.musicController.isPlaying else { return false }
        guard let activeRow = activeTextPhaseRow(for: configuration)?.0
            ?? configuration.rows.first(where: { $0.index == configuration.effectiveCurrentIndex }) else {
            return false
        }
        if activeRow.displayLine.line.hasSyllableSync
            || activeRow.interlude != nil
            || activeRow.isPrelude {
            return true
        }
        if configuration.showTranslation,
           let translation = activeRow.displayLine.line.translation,
           !translation.isEmpty {
            return true
        }
        return false
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

final class NativeLyricsRowView: NSView {
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private let backgroundLayer = CALayer()
    private let mainTextLayer = CATextLayer()
    private let mainBrightTextLayer = CATextLayer()
    private let mainBaseRevealMaskLayer = CALayer()
    private let mainSweepMaskLayer = CAGradientLayer()
    private let mainPerRunSweepMaskLayer = CALayer()
    private let mainEmphasisLayer = CALayer()
    private let translationTextLayer = CATextLayer()
    private let translationBrightTextLayer = CATextLayer()
    private let translationSweepMaskLayer = CAGradientLayer()
    private let translationPerLineSweepMaskLayer = CALayer()
    private let translationLoadingDotContainerLayer = CALayer()
    private let translationLoadingDotLayers: [CALayer] = (0..<3).map { _ in CALayer() }
    private let interludeTextLayer = CATextLayer()
    private let dotContainerLayer = CALayer()
    private let dotLayers: [CALayer] = (0..<3).map { _ in CALayer() }
    private var trackingAreaRef: NSTrackingArea?
    private var row: LayerBackedLyricRow?
    private var configuration: LyricsLayerRendererConfiguration?
    private var isHovering = false
    private var mainPerRunSweepLineLayers: [NativeLyricsSweepMaskLineLayer] = []
    private var mainBaseRevealLineLayers: [NativeLyricsSweepMaskLineLayer] = []
    private var cachedMainSweepLayoutKey: SweepLayoutCacheKey?
    private var cachedMainSweepLinePlan: [NativeLyricsTextSweepVisualLinePlan] = []
    private var cachedTextGlyphGeometryBounds: CGRect?
    private var cachedTextGlyphGeometryMetrics: TextGlyphGeometryMetrics?
    private var cachedTranslationSweepLayoutKey: TranslationSweepLayoutCacheKey?
    private var cachedTranslationSweepLinePlan: [NativeLyricsTranslationSweepVisualLinePlan] = []
    private var translationSweepLineLayers: [NativeLyricsSweepMaskLineLayer] = []
    private var emphasisGlyphLayers: [CATextLayer] = []
    private var emphasisGlyphLayerSignatures: [EmphasisGlyphLayerSignature?] = []
    private var activeHiddenEmphasisSignature: String?
    // v2.8 per-word cascade: non-emphasis words render as per-glyph layers so each WORD can float by
    // its own baseFloatY (rolling rise), while brightness still comes from the shared sweep mask. The
    // dim glyphs parent to mainTextLayer (always visible), the bright glyphs to mainBrightTextLayer
    // (masked by the sweep — so a 2pt float never disturbs the horizontal wavefront).
    private var mainDimWordGlyphLayers: [CATextLayer] = []
    private var mainBrightWordGlyphLayers: [CATextLayer] = []
    private var mainWordGlyphLayerSignatures: [EmphasisGlyphLayerSignature?] = []
    private var lastMainSweepWavefrontX: [Int: CGFloat] = [:]
    private var lastTranslationSweepWavefrontX: [Int: CGFloat] = [:]
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
    // CATextLayer clips text tight to its bounds: at frame height == usedRect.height the LAST wrapped
    // line's bottom pixels (CJK strokes / descenders) get shaved. Pad the rendered text-layer height so
    // the glyph bottoms have room. The row's stacking offset still uses the true (un-padded) height, so
    // line positions and the gap before the translation are unchanged — the pad lives in the existing
    // 8pt bottom slack of measuredHeight.
    private static let textBottomClipPad: CGFloat = 6
    /// Calibration for the sqrt-compressed CIGaussianBlur curve. The rendered radius is
    /// `sqrt(logicalBlur) * calibration`, so near lines get visible blur while far lines
    /// saturate instead of fogging. Tunable.
    static let blurRenderCalibration: CGFloat = 1.0
    private static let translationLoadingDotSize: CGFloat = NativeLyricsTranslationLoadingDotPhasePlan.dotSize
    private static let translationLoadingDotSpacing: CGFloat = NativeLyricsTranslationLoadingDotPhasePlan.dotSpacing
    private static let translationLoadingRowHeight: CGFloat = 8

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
        updateTextLayers(textWidth: contentTextWidth(configuration))
        updateHoverBackground()
        needsLayout = true
    }

    func clearSweepState() {
        mainBrightTextLayer.mask = nil
        mainPerRunSweepMaskLayer.frame = .zero
        hidePerRunSweepMaskLayers()
        translationBrightTextLayer.mask = nil
        translationPerLineSweepMaskLayer.frame = .zero
        lastMainSweepWavefrontX.removeAll()
        lastTranslationSweepWavefrontX.removeAll()
    }

    func refreshInteractionState(configuration: LyricsLayerRendererConfiguration) {
        self.configuration = configuration
        updateHoverBackground()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        row = nil
        configuration = nil
        isHovering = false
        onHoverChanged = nil
        onHoverBackgroundVisible = nil
        onTap = nil
        layer?.opacity = 0
        backgroundLayer.isHidden = true
        lastHoverBackgroundVisible = false
        layer?.filters = nil
        appliedBlurRadius = -.greatestFiniteMagnitude
        cachedMainSweepLayoutKey = nil
        cachedMainSweepLinePlan = []
        lastMainSweepWavefrontX.removeAll()
        lastTranslationSweepWavefrontX.removeAll()
        cachedTextGlyphGeometryBounds = nil
        cachedTextGlyphGeometryMetrics = nil
        cachedTranslationSweepLayoutKey = nil
        cachedTranslationSweepLinePlan = []
        cachedStaticTextPlanKey = nil
        cachedStaticTextPlan = nil
        activeHiddenEmphasisSignature = nil
        [
            mainTextLayer,
            mainBrightTextLayer,
            translationTextLayer,
            translationBrightTextLayer,
            interludeTextLayer
        ].forEach { textLayer in
            textLayer.string = nil
            textLayer.isHidden = true
            textLayer.opacity = 1
            textLayer.setAffineTransform(.identity)
            textLayer.shadowOpacity = 0
            textLayer.shadowRadius = 0
            textLayer.shadowOffset = .zero
        }
        mainTextLayer.mask = nil
        mainBrightTextLayer.mask = mainSweepMaskLayer
        translationBrightTextLayer.mask = translationSweepMaskLayer
        mainSweepMaskLayer.locations = [0, 0, 0, 1]
        translationSweepMaskLayer.locations = [0, 0, 0, 1]
        hideBaseRevealMaskLayers()
        hidePerRunSweepMaskLayers()
        hideTranslationSweepMaskLayers()
        hideEmphasisGlyphLayers()
        hideMainWordGlyphLayers()
        hideTranslationLoadingDots()
        hideDotLayers()
    }

    @discardableResult
    func applyBlurRadius(_ radius: CGFloat) -> CGFloat {
        let logicalBlur = radius > 0.1 ? radius : 0
        let calibrated = logicalBlur > 0 ? sqrt(logicalBlur) * Self.blurRenderCalibration : 0
        let effectiveRadius = calibrated > 0.1 ? calibrated : 0
        let quantizedRadius = (effectiveRadius * 2).rounded(.toNearestOrAwayFromZero) / 2
        guard abs(appliedBlurRadius - quantizedRadius) > 0.001 else { return quantizedRadius }
        appliedBlurRadius = quantizedRadius
        guard quantizedRadius > 0 else {
            layer?.filters = nil
            return quantizedRadius
        }
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(Double(quantizedRadius), forKey: kCIInputRadiusKey)
        layer?.filters = filter.map { [$0] }
        return quantizedRadius
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Single source of truth for the content width
    //
    // The text-layout width MUST come from `configuration.rowWidth` — which is KNOWN at
    // configure time — and never from `bounds.width`, which is .zero on a fresh view and
    // stale on a pooled one before `applyFrame`/`layout()` runs. `applyFrame` sets the
    // view frame to exactly `configuration.rowWidth`, so this value equals the post-layout
    // `bounds.width - insets`. Routing wrapping, frame, and height through this one helper
    // is what stops the baked line-breaks from disagreeing with the laid-out frame (the
    // horizontal-clip + blank-row bug).
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private func contentTextWidth(_ configuration: LyricsLayerRendererConfiguration) -> CGFloat {
        max(1, configuration.rowWidth - nativeLyricContentLeadingInset - nativeLyricContentTrailingInset)
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
        } else if configuration.showTranslation && isAwaitingTranslation(row: row, configuration: configuration) {
            height += plan.constants.mainFontSize * 0.33 + Self.translationLoadingRowHeight
        }
        return ceil(height)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Rendering-truth read-back (tests only)
    //
    // The metrics/parity pipeline only validates plan->layer fidelity (we set an opacity,
    // then read it back). It never reads the ACTUAL rendered TEXT, so horizontal clipping
    // and blank rows slipped through every "green" diagnostic. These read-backs expose the
    // real committed string + frame so a deterministic test can assert that the baked line
    // breaks match the laid-out width (no clip, no empty row). Not used by production code.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    #if DEBUG
    var debugMainTextLayerString: String? {
        if let attributed = mainTextLayer.string as? NSAttributedString { return attributed.string }
        return mainTextLayer.string as? String
    }

    var debugMainTextLayerFrame: CGRect { mainTextLayer.frame }

    var debugMainTextLayerHidden: Bool { mainTextLayer.isHidden }

    func debugForceLayout() { layoutSubtreeIfNeeded() }

    /// Drives the active main phase at a controlled time (bypassing the live player clock) and
    /// returns the per-word float telemetry, so tests can prove each word floats by its OWN amount
    /// (spread > 0 = the cascade) instead of one collapsed line-level value.
    @MainActor
    func debugActiveMainPhaseWordFloat(currentTime: TimeInterval) -> (sampleCount: Int, floatSpread: CGFloat)? {
        guard let row else { return nil }
        // Force an active plan: the preview MusicController reports isPlaying == false, which would
        // zero every baseFloatY. We want the genuine per-word float at this time.
        let plan = NativeLyricsTextRenderPlan.make(
            configuration: .init(line: row.displayLine.line, currentTime: currentTime, isActive: true)
        )
        guard row.displayLine.line.hasSyllableSync, !plan.wordRuns.isEmpty else { return nil }
        let metrics = applyActiveMainPhase(plan: plan, currentTime: currentTime)
        return (metrics.mainWordFloatSampleCount, metrics.mainWordFloatSpread)
    }
    #endif


    override func layout() {
        super.layout()
        guard let row, let configuration else { return }
        let textX = nativeLyricContentLeadingInset
        // Single source of truth (same value updateTextLayers baked against). Deriving the frame
        // width from configuration.rowWidth instead of bounds.width removes the last bounds-timing
        // hazard, so the frame can never disagree with the baked line-breaks even on the first pass.
        let textWidth = contentTextWidth(configuration)
        let plan = textRenderPlan(row: row, configuration: configuration)
        backgroundLayer.frame = Self.hoverBackgroundFrame(in: bounds)
        var y: CGFloat = 8
        if row.isPrelude {
            mainTextLayer.frame = .zero
            mainBrightTextLayer.frame = mainTextLayer.frame
            mainSweepMaskLayer.frame = mainBrightTextLayer.bounds
            mainBaseRevealMaskLayer.frame = mainTextLayer.bounds
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
        mainTextLayer.frame = CGRect(x: textX, y: y, width: textWidth, height: mainHeight + Self.textBottomClipPad)
        mainBrightTextLayer.frame = mainTextLayer.frame
        mainSweepMaskLayer.frame = mainBrightTextLayer.bounds
        mainBaseRevealMaskLayer.frame = mainTextLayer.bounds
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
            translationTextLayer.frame = CGRect(x: textX, y: y, width: textWidth, height: translationExpectedHeight + Self.textBottomClipPad)
            translationBrightTextLayer.frame = translationTextLayer.frame
            translationSweepMaskLayer.frame = translationBrightTextLayer.bounds
            translationPerLineSweepMaskLayer.frame = translationBrightTextLayer.bounds
            translationFrameHeightError = abs(translationTextLayer.frame.height - translationExpectedHeight)
            translationFrameWidthError = abs(translationTextLayer.frame.width - textWidth)
            y += translationExpectedHeight
            hideTranslationLoadingDots()
        } else if configuration.showTranslation && isAwaitingTranslation(row: row, configuration: configuration) {
            translationTextLayer.frame = .zero
            translationBrightTextLayer.frame = .zero
            translationSweepMaskLayer.frame = .zero
            translationPerLineSweepMaskLayer.frame = .zero
            y += plan.constants.mainFontSize * 0.33
            layoutTranslationLoadingDots(frame: CGRect(
                x: textX,
                y: y,
                width: textWidth,
                height: Self.translationLoadingRowHeight
            ))
            y += Self.translationLoadingRowHeight
        } else {
            translationTextLayer.frame = .zero
            translationBrightTextLayer.frame = .zero
            translationSweepMaskLayer.frame = .zero
            translationPerLineSweepMaskLayer.frame = .zero
            hideTranslationLoadingDots()
        }
        interludeTextLayer.frame = .zero
        if !row.isPrelude { hideDotLayers() }
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

    static func displayWrapped(_ text: String, width: CGFloat, font: NSFont, lineSpacing: CGFloat = 0) -> String {
        guard width > 1, text.count > 1, !text.contains("\n") else { return text }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: text,
            attributes: [.font: font, .paragraphStyle: paragraph]
        ))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let ns = text as NSString
        var lines: [String] = []
        var glyphIndex = 0
        let glyphCount = manager.numberOfGlyphs
        while glyphIndex < glyphCount {
            var lineGlyphRange = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let charRange = manager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            var line = ns.substring(with: charRange)
            if line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
        guard lines.count > 1 else { return text }
        return lines.joined(separator: "\n")
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
            translationLoadingDotContainerLayer,
            interludeTextLayer,
            dotContainerLayer
        ].forEach {
            $0.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            $0.masksToBounds = false
            layer?.addSublayer($0)
        }
        dotLayers.forEach { dot in
            dot.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            dot.cornerRadius = NativeLyricsDotPhasePlan.baseDotSize / 2
            dot.backgroundColor = NSColor.white.cgColor
            dotContainerLayer.addSublayer(dot)
        }
        dotContainerLayer.isHidden = true
        translationLoadingDotLayers.forEach { dot in
            dot.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            dot.cornerRadius = Self.translationLoadingDotSize / 2
            dot.backgroundColor = NSColor.white.cgColor
            translationLoadingDotContainerLayer.addSublayer(dot)
        }
        translationLoadingDotContainerLayer.isHidden = true
        mainBrightTextLayer.mask = mainSweepMaskLayer
        mainBaseRevealMaskLayer.masksToBounds = false
        mainBaseRevealMaskLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
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

    private func updateTextLayers(textWidth: CGFloat) {
        guard let row, let configuration else { return }
        if row.isPrelude {
            mainTextLayer.string = nil
            mainBrightTextLayer.string = nil
            mainTextLayer.mask = nil
            hideBaseRevealMaskLayers()
            hideEmphasisGlyphLayers()
            hideMainWordGlyphLayers()
            activeHiddenEmphasisSignature = nil
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            hideTranslationLoadingDots()
            hideTranslationSweepMaskLayers()
            interludeTextLayer.string = nil
            dotContainerLayer.isHidden = false
            updatePlaybackPhase(configuration: configuration)
            return
        }

        let plan = textRenderPlan(row: row, configuration: configuration)
        let isActive = row.index == configuration.effectiveCurrentIndex && configuration.musicController.isPlaying
        let appliesMainSweep = isActive && row.displayLine.line.hasSyllableSync && !plan.wordRuns.isEmpty
        let mainAlpha = appliesMainSweep ? plan.constants.dimAlpha : 1
        // v2.8 karaoke: the dim base text stays fully visible at dimAlpha at ALL times; only
        // the bright overlay sweeps over it. Masking the base made unsung words invisible until
        // the wavefront reached them — the "从无到有 / words materialize from nothing" bug.
        mainTextLayer.mask = nil
        hideBaseRevealMaskLayers()
        // Single source of truth: wrap at the KNOWN configuration width, never the not-yet-laid-out
        // bounds.width (which is .zero on a fresh view / stale on a pooled one). This is the exact
        // width layout() will use, so the baked line-breaks always match the rendered frame.
        let displayTextWidth = textWidth
        let wrappedMainText = Self.displayWrapped(
            plan.displayText,
            width: displayTextWidth,
            font: .systemFont(ofSize: plan.constants.mainFontSize, weight: .semibold)
        )
        mainTextLayer.string = attributedText(
            wrappedMainText,
            fontSize: plan.constants.mainFontSize,
            alpha: mainAlpha
        )
        // The reuse pool hides every text layer in prepareForReuse() to kill stale content during
        // the transition. The dim BASE must be restored here for every non-prelude row, or a row that
        // ever passed through the pool stays invisible forever — the panel empties out as playback
        // recycles rows, and the active line shows only its sung (bright) portion. Restore it now.
        mainTextLayer.isHidden = false
        mainBrightTextLayer.string = appliesMainSweep
            ? attributedText(wrappedMainText, fontSize: plan.constants.mainFontSize, alpha: plan.constants.brightAlpha)
            : nil
        activeHiddenEmphasisSignature = nil
        hideEmphasisGlyphLayers()
        if let translation = plan.translation {
            let appliesTranslationSweep = isActive
            let translationBaseAlpha = appliesTranslationSweep
                ? translation.dimAlpha
                : plan.constants.currentTranslationOpacityFactor
            let wrappedTranslationText = Self.displayWrapped(
                translation.text,
                width: displayTextWidth,
                font: .systemFont(ofSize: plan.constants.translationFontSize, weight: .semibold),
                lineSpacing: plan.constants.translationLineSpacing
            )
            translationTextLayer.string = attributedText(
                wrappedTranslationText,
                fontSize: plan.constants.translationFontSize,
                alpha: translationBaseAlpha,
                lineSpacing: plan.constants.translationLineSpacing
            )
            translationTextLayer.isHidden = false
            translationBrightTextLayer.string = appliesTranslationSweep
                ? attributedText(
                    wrappedTranslationText,
                    fontSize: plan.constants.translationFontSize,
                    alpha: translation.brightAlpha,
                    lineSpacing: plan.constants.translationLineSpacing
                )
                : nil
            if !appliesTranslationSweep {
                hideTranslationSweepMaskLayers()
            }
        } else if configuration.showTranslation && isAwaitingTranslation(row: row, configuration: configuration) {
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            startTranslationLoadingDots()
            hideTranslationSweepMaskLayers()
        } else if configuration.showTranslation && isTranslationFailureVisible(row: row, configuration: configuration) {
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            hideTranslationLoadingDots()
            hideTranslationSweepMaskLayers()
        } else {
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            hideTranslationLoadingDots()
            hideTranslationSweepMaskLayers()
        }
        interludeTextLayer.string = nil
        dotContainerLayer.isHidden = row.interlude == nil
        if let textSample = updatePlaybackPhase(configuration: configuration) {
            (superview as? NativeLyricsSurfaceView)?.recordTextPhase(textSample)
        }
    }

    private func isAwaitingTranslation(
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> Bool {
        LyricLineTranslationLayoutPolicy.isAwaitingTranslation(
            index: row.displayLine.sourceIndex,
            line: row.sourceLine,
            pendingLineIndices: configuration.pendingTranslationLineIndices,
            isTranslating: configuration.isTranslating,
            segmentIndex: row.displayLine.segmentIndex
        )
    }

    private func isTranslationFailureVisible(
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> Bool {
        configuration.translationFailed
            && row.index == configuration.effectiveCurrentIndex
            && isAwaitingTranslation(row: row, configuration: configuration)
    }

    private func updateHoverBackground() {
        let visible = isHovering && row?.displayLine.line.text != "⋯"
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
        #if LOCAL_DEVELOPER_BUILD
        do {
            let hasTranslation = row.displayLine.line.translation != nil
            if let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_sweep.log") {
                fh.seekToEndOfFile()
                fh.write("[Phase] isActive=\(isActive) isPlaying=\(configuration.musicController.isPlaying) idx=\(row.index) curIdx=\(configuration.effectiveCurrentIndex) hasTrans=\(hasTranslation)\n".data(using: .utf8)!)
                fh.closeFile()
            }
        }
        #endif
        if isActive {
            let plan = textRenderPlan(
                row: row,
                configuration: configuration,
                currentTime: renderTime
            )
            let expectsPerRunSweep = row.displayLine.line.hasSyllableSync && !plan.wordRuns.isEmpty
            let appliedMainProgress = expectsPerRunSweep
                ? applyActiveMainPhase(plan: plan, currentTime: renderTime)
                : applyStaticActiveTextPhase(plan: plan)
            let appliedTranslation = plan.translation != nil
                ? applyActiveTranslationPhase(plan: plan)
                : nil
            if plan.translation == nil {
                translationBrightTextLayer.isHidden = true
                hideTranslationSweepMaskLayers()
            }
            let expectsNoLineLevelMainSweep = !expectsPerRunSweep
            let appliesLineLevelMainSweep = expectsNoLineLevelMainSweep
                && mainBrightTextLayer.string != nil
                && !mainBrightTextLayer.isHidden
            let expectsNoLineLevelTranslationSweep = false
            let appliesLineLevelTranslationSweep = !expectsPerRunSweep
                && plan.translation != nil
                && translationBrightTextLayer.string != nil
                && !translationBrightTextLayer.isHidden
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
                    expectsNoLineLevelMainSweep: expectsNoLineLevelMainSweep,
                    appliesLineLevelMainSweep: appliesLineLevelMainSweep,
                    expectsNoLineLevelTranslationSweep: expectsNoLineLevelTranslationSweep,
                    appliesLineLevelTranslationSweep: appliesLineLevelTranslationSweep,
                    expectsBaseReveal: expectsPerRunSweep,
                    appliesBaseReveal: appliedMainProgress.appliedBaseReveal,
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
                    baseRevealLineCoverageGapCount: appliedMainProgress.baseRevealLineCoverageGapCount,
                    baseRevealWavefrontErrorMax: appliedMainProgress.baseRevealWavefrontErrorMax,
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
                    translationTextFrameHeightErrorMax: appliedMainProgress.translationTextFrameHeightErrorMax,
                    mainWordFloatSampleCount: appliedMainProgress.mainWordFloatSampleCount,
                    mainWordFloatSpread: appliedMainProgress.mainWordFloatSpread
                )
            }
        } else {
            mainBrightTextLayer.isHidden = true
            mainBrightTextLayer.mask = mainSweepMaskLayer
            mainTextLayer.mask = nil
            hideBaseRevealMaskLayers()
            hidePerRunSweepMaskLayers()
            hideEmphasisGlyphLayers()
            hideMainWordGlyphLayers()
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

    private struct MainTextPhaseAppliedMetrics {
        let progress: CGFloat
        let appliedPerRunSweep: Bool
        let appliedBaseReveal: Bool
        let appliedPerGlyphEmphasis: Bool
        let expectedEmphasisGlyphCount: Int
        let appliedEmphasisGlyphCount: Int
        let appliedEmphasisGlyphMotionCount: Int
        let maxAppliedEmphasisScale: CGFloat
        let maxAppliedEmphasisLiftMagnitude: CGFloat
        let maxAppliedEmphasisGlowOpacity: CGFloat
        let maxAppliedEmphasisAlpha: CGFloat
        let textLayoutCoverageGapCount: Int
        let expectedSweepLineCount: Int
        let appliedSweepLineCount: Int
        let sweepLineCoverageGapCount: Int
        let sweepWavefrontErrorMax: CGFloat
        let baseRevealLineCoverageGapCount: Int
        let baseRevealWavefrontErrorMax: CGFloat
        let emphasisGlyphPositionSampleCount: Int
        let emphasisGlyphPositionErrorMax: CGFloat
        let emphasisGlyphScaleErrorMax: CGFloat
        let emphasisGlyphAlphaErrorMax: CGFloat
        let emphasisGlyphGlowErrorMax: CGFloat
        let textGlyphGeometrySampleCount: Int
        let textGlyphGeometryCoverageGapCount: Int
        let textGlyphGeometryPositionErrorMax: CGFloat
        let lineLayoutSampleCount: Int
        let lineLayoutHeightErrorMax: CGFloat
        let lineLayoutWidthErrorMax: CGFloat
        let mainTextFrameHeightErrorMax: CGFloat
        let translationTextFrameHeightErrorMax: CGFloat
        let mainWordFloatSampleCount: Int
        let mainWordFloatSpread: CGFloat
    }

    private func applyActiveMainPhase(
        plan: NativeLyricsTextRenderPlan,
        currentTime: TimeInterval
    ) -> MainTextPhaseAppliedMetrics {
        let activeRun = plan.wordRuns.last { $0.startTime <= currentTime }
            ?? plan.wordRuns.first
        let linePlan = mainSweepLinePlan(for: plan, bounds: mainBrightTextLayer.bounds)
        let emphasisOrders = Self.activeEmphasisOrders(plan: plan)
        // v2.8 per-word cascade: once the line is laid out, every word is drawn by per-glyph layers so
        // each WORD floats by its OWN baseFloatY (rolling rise, AMLL base float). Non-emphasis glyphs
        // parent to the dim and bright text layers — the bright ones inherit the sweep mask, so a 2pt
        // float never disturbs the horizontal wavefront and brightness stays a smooth gradient.
        // Emphasis words keep their dedicated scale/glow glyph layers. The whole-line text layers then
        // draw nothing. Before layout (bounds are .zero on a fresh/pooled row) we fall back to the
        // single whole-line text + a collapsed line-level float, so the dim base is never blank
        // (the 从无到有 guard).
        let geometryReady = mainBrightTextLayer.bounds.width > 1
            && mainBrightTextLayer.bounds.height > 1
            && !linePlan.isEmpty
        let wordFloatResult: MainWordFloatAppliedMetrics
        if geometryReady {
            if mainTextLayer.string != nil { mainTextLayer.string = nil }
            if mainBrightTextLayer.string != nil { mainBrightTextLayer.string = nil }
            activeHiddenEmphasisSignature = nil
            mainTextLayer.setAffineTransform(.identity)
            mainBrightTextLayer.setAffineTransform(.identity)
            wordFloatResult = applyMainWordFloatGlyphLayers(
                plan: plan,
                currentTime: currentTime,
                linePlan: linePlan,
                emphasisOrders: emphasisOrders
            )
        } else {
            hideMainWordGlyphLayers()
            let floatTransform = CGAffineTransform(translationX: 0, y: plan.activeLineFloatY(at: currentTime))
            mainTextLayer.setAffineTransform(floatTransform)
            mainBrightTextLayer.setAffineTransform(floatTransform)
            wordFloatResult = .inactive
        }
        mainBrightTextLayer.opacity = Float(plan.mainPostLineFade)
        mainBrightTextLayer.isHidden = plan.mainSweepProgress <= 0.001 || plan.mainPostLineFade <= 0.001
        let sweepResult = updatePerRunSweepMask(
            plan: plan,
            currentTime: currentTime,
            bounds: mainBrightTextLayer.bounds,
            linePlan: linePlan
        )
        // Base-reveal is intentionally NOT applied: the dim base stays fully visible (v2.8
        // karaoke). Skipping the mask update also avoids per-frame base-mask layout work.
        let baseRevealResult = PerRunSweepAppliedMetrics(
            applied: false, expectedLineCount: 0, appliedLineCount: 0,
            coverageGapCount: 0, wavefrontErrorMax: 0
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
        let emphasisResult = applyEmphasisGlyphLayers(
            plan: plan,
            currentTime: currentTime,
            linePlan: linePlan,
            emphasisOrders: emphasisOrders,
            managesContainerText: !geometryReady
        )
        if emphasisResult.applied {
            clearEmphasis(from: mainBrightTextLayer)
        } else if let activeRun, activeRun.emphasis.glowOpacity > 0 {
            mainBrightTextLayer.shadowColor = NSColor.white.cgColor
            mainBrightTextLayer.shadowOpacity = Float(min(1, activeRun.emphasis.glowOpacity))
            mainBrightTextLayer.shadowRadius = activeRun.emphasis.glowRadius
            mainBrightTextLayer.shadowOffset = CGSize(width: 0, height: activeRun.emphasis.liftY + activeRun.emphasis.floatY)
        } else {
            clearEmphasis(from: mainBrightTextLayer)
        }
        let glyphGeometryResult = textGlyphGeometryMetrics(
            plan: plan,
            linePlan: linePlan,
            bounds: mainBrightTextLayer.bounds
        )
        let layoutResult = lastLineLayoutMetrics
        return MainTextPhaseAppliedMetrics(
            progress: appliedProgress,
            appliedPerRunSweep: sweepResult.applied,
            appliedBaseReveal: baseRevealResult.applied,
            appliedPerGlyphEmphasis: emphasisResult.applied,
            expectedEmphasisGlyphCount: emphasisResult.expectedGlyphCount,
            appliedEmphasisGlyphCount: emphasisResult.appliedGlyphCount,
            appliedEmphasisGlyphMotionCount: emphasisResult.appliedMotionGlyphCount,
            maxAppliedEmphasisScale: emphasisResult.maxScale,
            maxAppliedEmphasisLiftMagnitude: emphasisResult.maxLiftMagnitude,
            maxAppliedEmphasisGlowOpacity: emphasisResult.maxGlowOpacity,
            maxAppliedEmphasisAlpha: emphasisResult.maxAlpha,
            textLayoutCoverageGapCount: emphasisResult.layoutCoverageGapCount,
            expectedSweepLineCount: sweepResult.expectedLineCount,
            appliedSweepLineCount: sweepResult.appliedLineCount,
            sweepLineCoverageGapCount: sweepResult.coverageGapCount,
            sweepWavefrontErrorMax: sweepResult.wavefrontErrorMax,
            baseRevealLineCoverageGapCount: baseRevealResult.coverageGapCount,
            baseRevealWavefrontErrorMax: baseRevealResult.wavefrontErrorMax,
            emphasisGlyphPositionSampleCount: emphasisResult.positionSampleCount,
            emphasisGlyphPositionErrorMax: emphasisResult.positionErrorMax,
            emphasisGlyphScaleErrorMax: emphasisResult.scaleErrorMax,
            emphasisGlyphAlphaErrorMax: emphasisResult.alphaErrorMax,
            emphasisGlyphGlowErrorMax: emphasisResult.glowErrorMax,
            textGlyphGeometrySampleCount: glyphGeometryResult.sampleCount,
            textGlyphGeometryCoverageGapCount: glyphGeometryResult.coverageGapCount,
            textGlyphGeometryPositionErrorMax: glyphGeometryResult.positionErrorMax,
            lineLayoutSampleCount: layoutResult.sampleCount,
            lineLayoutHeightErrorMax: layoutResult.heightErrorMax,
            lineLayoutWidthErrorMax: layoutResult.widthErrorMax,
            mainTextFrameHeightErrorMax: layoutResult.mainFrameHeightError,
            translationTextFrameHeightErrorMax: layoutResult.translationFrameHeightError,
            mainWordFloatSampleCount: wordFloatResult.sampleCount,
            mainWordFloatSpread: wordFloatResult.floatSpread
        )
    }

    private func applyStaticActiveTextPhase(plan: NativeLyricsTextRenderPlan) -> MainTextPhaseAppliedMetrics {
        hideMainWordGlyphLayers()
        mainTextLayer.setAffineTransform(.identity)
        mainBrightTextLayer.setAffineTransform(.identity)
        mainBrightTextLayer.isHidden = true
        mainBrightTextLayer.mask = mainSweepMaskLayer
        mainTextLayer.mask = nil
        hideBaseRevealMaskLayers()
        hidePerRunSweepMaskLayers()
        hideEmphasisGlyphLayers()
        activeHiddenEmphasisSignature = nil
        clearEmphasis(from: mainBrightTextLayer)
        let layoutResult = lastLineLayoutMetrics
        return MainTextPhaseAppliedMetrics(
            progress: plan.mainSweepProgress,
            appliedPerRunSweep: false,
            appliedBaseReveal: false,
            appliedPerGlyphEmphasis: false,
            expectedEmphasisGlyphCount: 0,
            appliedEmphasisGlyphCount: 0,
            appliedEmphasisGlyphMotionCount: 0,
            maxAppliedEmphasisScale: 1,
            maxAppliedEmphasisLiftMagnitude: 0,
            maxAppliedEmphasisGlowOpacity: 0,
            maxAppliedEmphasisAlpha: 0,
            textLayoutCoverageGapCount: 0,
            expectedSweepLineCount: 0,
            appliedSweepLineCount: 0,
            sweepLineCoverageGapCount: 0,
            sweepWavefrontErrorMax: 0,
            baseRevealLineCoverageGapCount: 0,
            baseRevealWavefrontErrorMax: 0,
            emphasisGlyphPositionSampleCount: 0,
            emphasisGlyphPositionErrorMax: 0,
            emphasisGlyphScaleErrorMax: 0,
            emphasisGlyphAlphaErrorMax: 0,
            emphasisGlyphGlowErrorMax: 0,
            textGlyphGeometrySampleCount: 0,
            textGlyphGeometryCoverageGapCount: 0,
            textGlyphGeometryPositionErrorMax: 0,
            lineLayoutSampleCount: layoutResult.sampleCount,
            lineLayoutHeightErrorMax: layoutResult.heightErrorMax,
            lineLayoutWidthErrorMax: layoutResult.widthErrorMax,
            mainTextFrameHeightErrorMax: layoutResult.mainFrameHeightError,
            translationTextFrameHeightErrorMax: layoutResult.translationFrameHeightError,
            mainWordFloatSampleCount: 0,
            mainWordFloatSpread: 0
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
        guard let configuration else { return nil }
        let textWidth = contentTextWidth(configuration)
        let translationHeight = measuredTextHeight(
            translation.text,
            width: textWidth,
            font: .systemFont(ofSize: plan.constants.translationFontSize, weight: .semibold),
            lineSpacing: plan.constants.translationLineSpacing
        )
        let bounds = CGRect(x: 0, y: 0, width: textWidth, height: translationHeight + Self.textBottomClipPad)
        return updateTranslationSweepMask(
            translation: translation,
            constants: plan.constants,
            bounds: bounds
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
            let rawWavefrontX = max(line.wavefrontX, lastMainSweepWavefrontX[index] ?? -.greatestFiniteMagnitude)
            lastMainSweepWavefrontX[index] = rawWavefrontX
            let expectedLocalWavefront = rawWavefrontX - line.maskRect.minX
            let appliedLocalWavefront = applySweepMask(
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

    private var translationSweepDiagRowID: String?

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

        #if LOCAL_DEVELOPER_BUILD
        do {
            let rowID = row?.id ?? "?"
            if translationSweepDiagRowID != rowID {
                translationSweepDiagRowID = rowID
                if let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_sweep.log") {
                    fh.seekToEndOfFile()
                    let text = translation.text.prefix(60)
                    fh.write("[SweepDiag] row=\(rowID) text=\"\(text)\" bounds=\(bounds) planCount=\(linePlan.count) linesCount=\(lines.count) progress=\(String(format: "%.3f", translation.progress)) maskUsed=\(lines.isEmpty ? "gradient" : "perLine")\n".data(using: .utf8)!)
                    for (i, p) in linePlan.enumerated() {
                        fh.write("  plan[\(i)] rect=\(p.rect) width=\(String(format: "%.1f", p.width))\n".data(using: .utf8)!)
                    }
                    for (i, l) in lines.enumerated() {
                        fh.write("  line[\(i)] maskRect=\(l.maskRect) wavefrontX=\(String(format: "%.1f", l.wavefrontX))\n".data(using: .utf8)!)
                    }
                    fh.closeFile()
                }
            }
        }
        #endif

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
            let rawWavefrontX = max(line.wavefrontX, lastTranslationSweepWavefrontX[index] ?? -.greatestFiniteMagnitude)
            lastTranslationSweepWavefrontX[index] = rawWavefrontX
            let expectedLocalWavefront = rawWavefrontX - line.maskRect.minX
            let appliedLocalWavefront = applySweepMask(
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
            partial + visibleGlyphCount(in: run.text)
        }
        let visualRuns = linePlan.flatMap(\.runs)
        let appliedGlyphCount = visualRuns.reduce(0) { $0 + $1.glyphs.count }
        let missingRunCount = max(0, plan.wordRuns.count - Set(visualRuns.map(\.order)).count)
        let geometryBounds = linePlan.reduce(CGRect.null) { partial, line in
            partial.union(line.maskRect)
        }
        let containmentBounds = geometryBounds.isNull ? bounds : geometryBounds
        var positionErrorMax: CGFloat = 0
        for visualRun in visualRuns {
            for glyph in visualRun.glyphs {
                let overflow = max(
                    max(0, containmentBounds.minX - glyph.rect.minX),
                    max(0, glyph.rect.maxX - containmentBounds.maxX),
                    max(0, containmentBounds.minY - glyph.rect.minY),
                    max(0, glyph.rect.maxY - containmentBounds.maxY)
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

    private func visibleGlyphCount(in text: String) -> Int {
        let nsText = text as NSString
        guard nsText.length > 0 else { return 0 }
        var count = 0
        for offset in 0..<nsText.length {
            let character = nsText.substring(with: NSRange(location: offset, length: 1))
            if !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        return count
    }

    /// The word orders that render as dedicated emphasis (scale/glow) glyph layers — AMLL holds long
    /// words. Shared by the emphasis renderer and the per-word float renderer (which draws the
    /// complement), so the two partitions never overlap or leave a gap.
    static func activeEmphasisOrders(plan: NativeLyricsTextRenderPlan) -> Set<Int> {
        Set(plan.wordRuns.enumerated().compactMap { order, run in
            (run.isEmphasis || run.emphasis != .inactive) ? order : nil
        })
    }

    private func applyEmphasisGlyphLayers(
        plan: NativeLyricsTextRenderPlan,
        currentTime: TimeInterval,
        linePlan: [NativeLyricsTextSweepVisualLinePlan],
        emphasisOrders: Set<Int>,
        managesContainerText: Bool
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
        guard !emphasisOrders.isEmpty else {
            // managesContainerText is the pre-layout fallback: the whole-line text is the live render,
            // so restore it. When per-word glyph layers own the line, the caller already blanked it.
            if managesContainerText { restoreMainTextIfNeeded(plan: plan) }
            hideEmphasisGlyphLayers()
            return (false, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        }

        if managesContainerText { applyHiddenEmphasisText(plan: plan, hiddenOrders: emphasisOrders) }

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
                ? partial + max(1, visibleGlyphCount(in: item.element.text))
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

    private struct MainWordFloatAppliedMetrics {
        let sampleCount: Int
        /// max − min applied float across the line. > 0 proves the words floated by DISTINCT amounts
        /// (the cascade), so a regression back to one collapsed line-level value is caught.
        let floatSpread: CGFloat
        static let inactive = MainWordFloatAppliedMetrics(sampleCount: 0, floatSpread: 0)
    }

    /// v2.8 per-word cascade: draw every NON-emphasis word as per-glyph layers floated by that word's
    /// own `baseFloatY`. The dim glyphs (always visible) parent to `mainTextLayer`; the bright glyphs
    /// parent to `mainBrightTextLayer` and so inherit the sweep mask — brightness stays a smooth
    /// gradient and the 2pt float never shifts the horizontal wavefront. Position carries the float
    /// (scale stays 1 → no top-clip). Emphasis (long) words are skipped; they keep their own
    /// scale/glow glyph layers, so the two partitions cover the line without overlap or gap.
    private func applyMainWordFloatGlyphLayers(
        plan: NativeLyricsTextRenderPlan,
        currentTime: TimeInterval,
        linePlan: [NativeLyricsTextSweepVisualLinePlan],
        emphasisOrders: Set<Int>
    ) -> MainWordFloatAppliedMetrics {
        let floats = plan.perWordFloatY(at: currentTime)
        var inputs: [(glyph: NativeLyricsTextSweepVisualRun.Glyph, floatY: CGFloat)] = []
        for line in linePlan {
            for run in line.runs where !emphasisOrders.contains(run.order) {
                let floatY = run.order < floats.count ? floats[run.order] : 0
                for glyph in run.glyphs {
                    inputs.append((glyph, floatY))
                }
            }
        }
        guard !inputs.isEmpty else {
            hideMainWordGlyphLayers()
            return .inactive
        }
        ensureMainWordGlyphLayerCount(inputs.count)
        let fontSize = plan.constants.mainFontSize
        let dimColor = NSColor.white.withAlphaComponent(plan.constants.dimAlpha).cgColor
        let brightColor = NSColor.white.withAlphaComponent(plan.constants.brightAlpha).cgColor
        var minFloat = CGFloat.greatestFiniteMagnitude
        var maxFloat = -CGFloat.greatestFiniteMagnitude
        for (index, input) in inputs.enumerated() {
            let glyph = input.glyph
            let dimLayer = mainDimWordGlyphLayers[index]
            let brightLayer = mainBrightWordGlyphLayers[index]
            dimLayer.isHidden = false
            brightLayer.isHidden = false
            let signature = EmphasisGlyphLayerSignature(glyph: glyph, fontSize: fontSize)
            if mainWordGlyphLayerSignatures.indices.contains(index),
               mainWordGlyphLayerSignatures[index] != signature {
                mainWordGlyphLayerSignatures[index] = signature
                // CATextLayer clips text tight to its bounds — at exactly glyph.rect.size the bottom
                // ink of CJK strokes / descenders is shaved (same trap the whole-line layer pads
                // around). The view is flipped (y-down), so glyph.rect.minY is the top: extend the box
                // DOWNWARD by textBottomClipPad (keeping the top edge fixed) for room below the glyph.
                for layer in [dimLayer, brightLayer] {
                    layer.string = glyph.text
                    layer.bounds = CGRect(
                        origin: .zero,
                        size: CGSize(width: glyph.rect.width, height: glyph.rect.height + Self.textBottomClipPad)
                    )
                }
            }
            dimLayer.foregroundColor = dimColor
            brightLayer.foregroundColor = brightColor
            // Center sits pad/2 below the glyph midY so the taller box keeps its TOP at glyph.rect.minY
            // (text stays exactly where the whole-line layer drew it; only the bottom gains room).
            let centerY = glyph.rect.midY + Self.textBottomClipPad / 2 + input.floatY
            let position = CGPoint(x: glyph.rect.midX, y: centerY)
            dimLayer.position = position
            brightLayer.position = position
            let appliedFloat = position.y - glyph.rect.midY - Self.textBottomClipPad / 2
            minFloat = min(minFloat, appliedFloat)
            maxFloat = max(maxFloat, appliedFloat)
        }
        for index in inputs.count..<mainDimWordGlyphLayers.count {
            mainDimWordGlyphLayers[index].isHidden = true
            mainBrightWordGlyphLayers[index].isHidden = true
        }
        return MainWordFloatAppliedMetrics(
            sampleCount: inputs.count,
            floatSpread: maxFloat - minFloat
        )
    }

    private func ensureMainWordGlyphLayerCount(_ count: Int) {
        guard mainDimWordGlyphLayers.count < count else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let fontSize = NativeLyricsTextConstants().mainFontSize
        while mainDimWordGlyphLayers.count < count {
            let dimLayer = makeWordGlyphLayer(scale: scale, fontSize: fontSize)
            let brightLayer = makeWordGlyphLayer(scale: scale, fontSize: fontSize)
            mainTextLayer.addSublayer(dimLayer)
            mainBrightTextLayer.addSublayer(brightLayer)
            mainDimWordGlyphLayers.append(dimLayer)
            mainBrightWordGlyphLayers.append(brightLayer)
            mainWordGlyphLayerSignatures.append(nil)
        }
    }

    private func makeWordGlyphLayer(scale: CGFloat, fontSize: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = scale
        layer.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        layer.fontSize = fontSize
        layer.isWrapped = false
        layer.alignmentMode = .center
        layer.truncationMode = .none
        layer.masksToBounds = false
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return layer
    }

    private func hideMainWordGlyphLayers() {
        for layer in mainDimWordGlyphLayers { layer.isHidden = true }
        for layer in mainBrightWordGlyphLayers { layer.isHidden = true }
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
        let floatDu = du * 1.4
        let floatDelay = max(0, charDelay - 0.4)
        let t2 = CGFloat(min(1, max(0, (currentTime - run.startTime - floatDelay) / floatDu)))
        let tailWeight = currentTime >= run.startTime && t2 > 0 && t2 < 1
            ? sin(t2 * .pi) * 0.8
            : 0
        let emphasisWeight = max(easing, tailWeight)
        let scale = 1 + emphasisWeight * 0.1 * run.emphasis.amount
        let relativeIndex = CGFloat(glyphCount) / 2 - CGFloat(glyph.index)
        let spreadX = -emphasisWeight * 0.03 * run.emphasis.amount * relativeIndex * 24
        let charFloat: CGFloat = (t2 > 0 && t2 < 1) ? -sin(t2 * .pi) * 1.2 : 0
        let liftY = -emphasisWeight * 0.6 * run.emphasis.amount
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
        let glowOpacity = emphasisWeight * run.emphasis.blurLevel
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
            let layer = NativeLyricsSweepMaskLineLayer()
            layer.contentsScale = scale
            mainPerRunSweepMaskLayer.addSublayer(layer)
            mainPerRunSweepLineLayers.append(layer)
        }
    }

    private func hidePerRunSweepMaskLayers() {
        for layer in mainPerRunSweepLineLayers {
            layer.isHidden = true
        }
        lastMainSweepWavefrontX.removeAll()
        lastTranslationSweepWavefrontX.removeAll()
    }

    private func hideBaseRevealMaskLayers() {
        for layer in mainBaseRevealLineLayers {
            layer.isHidden = true
        }
    }

    private func ensureTranslationSweepMaskLayerCount(_ count: Int) {
        guard translationSweepLineLayers.count < count else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        while translationSweepLineLayers.count < count {
            let layer = NativeLyricsSweepMaskLineLayer()
            layer.contentsScale = scale
            translationPerLineSweepMaskLayer.addSublayer(layer)
            translationSweepLineLayers.append(layer)
        }
    }

    private func hideTranslationSweepMaskLayers() {
        for layer in translationSweepLineLayers {
            layer.isHidden = true
        }
    }

    private func applySweepMask(
        _ mask: NativeLyricsSweepMaskLineLayer,
        wavefrontX: CGFloat,
        fadeHalfPoint: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        mask.apply(wavefrontX: wavefrontX, fadeHalfPoint: fadeHalfPoint, width: width)
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
        let dotSize = NativeLyricsDotPhasePlan.baseDotSize
        let spacing = NativeLyricsDotPhasePlan.baseDotSpacing
        let totalWidth = dotSize * CGFloat(dotLayers.count) + spacing * CGFloat(max(0, dotLayers.count - 1))
        var x: CGFloat = 0
        dotContainerLayer.bounds = CGRect(x: 0, y: 0, width: totalWidth, height: dotSize)
        dotContainerLayer.position = CGPoint(x: frame.minX + totalWidth / 2, y: frame.midY)
        for dot in dotLayers {
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.position = CGPoint(x: x + dotSize / 2, y: dotSize / 2)
            dot.cornerRadius = dotSize / 2
            x += dotSize + spacing
        }
    }

    private func layoutTranslationLoadingDots(frame: CGRect) {
        translationLoadingDotContainerLayer.frame = frame
        let dotSize = Self.translationLoadingDotSize
        let spacing = Self.translationLoadingDotSpacing
        let totalWidth = dotSize * CGFloat(translationLoadingDotLayers.count)
            + spacing * CGFloat(max(0, translationLoadingDotLayers.count - 1))
        var x: CGFloat = 0
        let y = max(0, (frame.height - dotSize) / 2)
        for dot in translationLoadingDotLayers {
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.position = CGPoint(x: x + dotSize / 2, y: y + dotSize / 2)
            dot.cornerRadius = dotSize / 2
            x += dotSize + spacing
        }
        translationLoadingDotContainerLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: max(frame.width, totalWidth),
            height: frame.height
        )
    }

    private func startTranslationLoadingDots() {
        translationLoadingDotContainerLayer.isHidden = false
        translationLoadingDotContainerLayer.opacity = 1
        let forwardSamples = (0...20).map { CGFloat($0) / 20.0 }
        let reverseSamples = Array(forwardSamples.dropLast().dropFirst().reversed())
        let phases = forwardSamples + reverseSamples
        let keyTimes = phases.indices.map { NSNumber(value: Double($0) / Double(max(1, phases.count - 1))) }
        for (index, dot) in translationLoadingDotLayers.enumerated() {
            dot.isHidden = false
            dot.removeAnimation(forKey: "translationLoadingOpacity")
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = phases.map {
                NSNumber(value: Double(NativeLyricsTranslationLoadingDotPhasePlan.dotOpacity(index: index, animationPhase: $0)))
            }
            animation.keyTimes = keyTimes
            animation.duration = NativeLyricsTranslationLoadingDotPhasePlan.animationDuration * 2
            animation.repeatCount = .infinity
            animation.calculationMode = .linear
            dot.opacity = Float(NativeLyricsTranslationLoadingDotPhasePlan.dotOpacity(
                index: index,
                animationPhase: 0
            ))
            dot.add(animation, forKey: "translationLoadingOpacity")
        }
    }

    private func hideTranslationLoadingDots() {
        translationLoadingDotContainerLayer.isHidden = true
        translationLoadingDotContainerLayer.opacity = 0
        for dot in translationLoadingDotLayers {
            dot.isHidden = true
            dot.opacity = 0
            dot.removeAllAnimations()
            dot.setAffineTransform(.identity)
        }
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
        hideDotLayers()
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
        // v2.8 parity: each dot scales individually as it fills (container stays
        // identity); only the dot currently lighting up breathes.
        dotContainerLayer.setAffineTransform(.identity)
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
            appliedScale: dotLayers.map { CGFloat($0.affineTransform().a) },
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
        dotContainerLayer.setAffineTransform(.identity)
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
            staticOpacity: 1,
            showTranslation: configuration.showTranslation
        )
    }

    private func attributedText(
        _ text: String,
        fontSize: CGFloat,
        alpha: CGFloat,
        lineSpacing: CGFloat? = nil
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        paragraph.lineSpacing = lineSpacing ?? 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: paragraph
        ]
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
        for range in NativeLyricsHiddenTextMask.ranges(
            in: text,
            hiddenOrders: hiddenOrders,
            wordRuns: wordRuns
        ) {
            attributed.addAttribute(
                .foregroundColor,
                value: NSColor.clear,
                range: range
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
        NativeLyricsTextMeasurement.measuredTextHeight(
            text,
            width: width,
            font: font,
            lineSpacing: lineSpacing
        )
    }
}
