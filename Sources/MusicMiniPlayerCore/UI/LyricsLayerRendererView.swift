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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Implicit-animation hygiene
//
// Every layer this renderer creates is INERT: property changes apply instantly, never via
// Core Animation's implicit 0.25s default actions. All intended motion comes from (a)
// per-tick property sets driven by the presentation engine, or (b) explicit CAAnimations
// added by name (the translation loading dots) — explicit adds bypass the action search,
// so they keep working.
//
// WHY layer-level and not call-site CATransaction wraps: these are manual sublayers of
// layer-backed NSViews. AppKit only suppresses implicit actions for a view's OWN backing
// layer. Text/mask/dot sublayer frames are assigned inside NSView.layout(), which AppKit
// runs in its own, un-wrapped transaction — no amount of call-site wrapping covers it.
// Un-blocked, a translation layer whose committed frame is .zero implicitly animates
// position+bounds from the origin when its real frame arrives ("drifts in from top-left"),
// reflows ghost mid-flight, and per-tick wavefront/dot sets each spawn an interrupted
// animation (smear/lag). The delegate is the FIRST stop in CA's action search, so
// returning NSNull() kills every implicit action without enumerating keys.
// Guarded by NativeLyricsImplicitAnimationTests.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsInertLayerDelegate: NSObject, CALayerDelegate {
    static let shared = NativeLyricsInertLayerDelegate()
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

extension CALayer {
    /// Marks this renderer-managed layer as inert (no implicit actions) and returns it,
    /// so creation sites read `CATextLayer().lyricsInert()`.
    func lyricsInert() -> Self {
        delegate = NativeLyricsInertLayerDelegate.shared
        return self
    }
}

private final class NativeLyricsSweepMaskLineLayer: CALayer {
    private let solidLayer = CALayer().lyricsInert()
    private let fadeLayer = CALayer().lyricsInert()

    // Mask line layers are created in per-tick batches; short-circuit the whole action
    // search at the class level instead of relying on the delegate slot.
    override func action(forKey event: String) -> CAAction? { NSNull() }

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
    // var so the renderer can advance the anchor during an interlude (so the dots take the active
    // centre and the preceding line recedes — the interlude behaving like a real lyric line).
    var anchorY: CGFloat
    let rowWidth: CGFloat
    // var so the renderer can self-heal a transient track-switch frame where rows arrived but
    // renderedIndices did not (empty indices collapse every row to Y=0 = the bloom). See the
    // derive in runtimeConfiguration(from:).
    var renderedIndices: [Int]
    var accumulatedHeights: [Int: CGFloat]
    let lineTargetIndices: [Int: Int]
    let lineInterval: TimeInterval?
    let hasSyllableSync: Bool
    let trackContext: DiagnosticTrackContext
    let isWaveTimelineDiagnosticsEnabled: Bool
    let isManualScrolling: Bool
    let reduceMotion: Bool
    // var so the renderer can FORCE-snap the first frames after a track switch. The SwiftUI side
    // lets a freshly-scheduled line wave defeat its own suppression (`&& !isLineWaveActive`), which
    // drops the renderer into natural mode and lets the engine spring the new rows in from the top
    // = the "lines stacked at top, then slide down" bloom. See runtimeConfiguration(from:).
    var suppressInitialMotion: Bool
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
    #if LOCAL_DEVELOPER_BUILD
    private var lastImplicitAnimationAuditLog: [String: CFTimeInterval] = [:]
    private var implicitAnimationAuditTickCounter = 0
    private var visualTrajectories: [String: [VisualTrajectorySample]] = [:]
    private var lastTrajectoryDump: [String: CFTimeInterval] = [:]
    private var lastTrajectoryPrune: CFTimeInterval = 0
    #endif
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
    private var lastAppliedConfigureSignature: String?
    #if DEBUG
    var debugSkipDedupe = false
    #endif
    private var initialMeasurementsPending = true
    // Reveal gate. Freshly-mounted rows are positioned ONLY by their layer transform, so for the
    // first display cycle after mount the presentation layer still shows the pre-commit identity
    // (every row at the top) for ~1 frame — a brief stacked/blurred flash even though the model is
    // already spread. Keep the rows at opacity 0 for this many presentation ticks after a mount so
    // they are only revealed once the loop has committed a real, spread frame. Counted down in
    // presentationTick; a fallback in configure reveals immediately when no loop will run.
    private var initialRevealTicksRemaining = 0
    #if DEBUG
    var debugInitialMeasurementsPending: Bool {
        get { initialMeasurementsPending }
        set { initialMeasurementsPending = newValue }
    }
    /// Look up a mounted row view by its semantic index (tests assert per-row render state
    /// after driving the real configure → reconcile pipeline).
    func debugRowView(forIndex index: Int) -> NativeLyricsRowView? {
        guard let id = rowIDByIndex[index] else { return nil }
        return rowViews[id]
    }
    /// The interlude overlay dots' centre X positions (in the dot container's coordinate space).
    /// Tests assert these stay horizontally spaced — i.e. the "三个点重合" overlap can't recur.
    var debugInterludeDotCenterXs: [CGFloat] {
        surfaceInterludeDots.map { $0.position.x }
    }
    #endif
    private var consumedDirectSnapRequestIDs: Set<UUID> = []
    private var lastConfiguredTextPhaseIndex: Int?
    private var deferredDeactivationIndex: Int?
    // Window (CACurrentMediaTime deadline) during which presentationTick logs the PRESENTATION
    // layer's row spread vs the model — to catch a bloom that lives in the on-screen animation
    // (model correct, layers still animating in) which the reconcile model-Y probe is blind to.
    private var bloomPresentationDiagUntil: CFTimeInterval = 0
    // Window after a track switch during which the renderer FORCES snap mode (directSnap) so the
    // new track's rows appear at their settled positions instead of the engine springing them in
    // from the top (the "stacked at top → slide down" bloom). Set on the track-change wipe;
    // applied by forcing suppressInitialMotion in runtimeConfiguration(from:).
    private var forceSnapUntil: CFTimeInterval = 0
    // ───────────────────────────────────────────────────────────────────────────
    // Bloom trajectory probe (LOCAL_DEVELOPER_BUILD only). Captures the ABSOLUTE
    // on-screen Y of the active row per configure + per frame during the appear
    // window, alongside the inputs that determine it (anchorY, engine y/targetY,
    // playbackMode, forceSnap). This is the objective measurement of the "stacked
    // at top → slide down" bloom: it shows EXACTLY which value travels 0→anchorY.
    // ───────────────────────────────────────────────────────────────────────────
    private var bloomTrajUntil: CFTimeInterval = 0
    private var bloomTrajArmedAt: CFTimeInterval = 0
    // #2c dim-line blink probe state (LOCAL_DEVELOPER_BUILD).
    private var dimProbeIndex: Int?
    private var dimProbeUntil: CFTimeInterval = 0
    private var pendingTapToLineSettleTiming: (targetIndex: Int, startedAt: CFTimeInterval, deadline: CFTimeInterval)?
    private let surfaceInterludeOverlay: NSView = {
        let v = _FlippedView()
        return v
    }()
    private let surfaceInterludeDotContainer = CALayer().lyricsInert()
    private let surfaceInterludeDots: [CALayer] = (0..<3).map { _ in CALayer().lyricsInert() }

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
        let spacing = NativeLyricsDotPhasePlan.baseDotSpacing
        surfaceInterludeOverlay.wantsLayer = true
        surfaceInterludeOverlay.layer?.masksToBounds = false
        surfaceInterludeOverlay.alphaValue = 0
        addSubview(surfaceInterludeOverlay)
        surfaceInterludeDotContainer.masksToBounds = false
        surfaceInterludeDotContainer.contentsScale = scale
        // ── Static dot layout — set ONCE, never re-derived per frame ──────────────────────────
        // The three dots' bounds + horizontal spacing are CONSTANT. Re-writing them every frame in
        // updateSurfaceInterludeDots meant that any frame that mutated the container WITHOUT re-
        // running the spacing loop (e.g. a manual-scroll reconcile path) could leave the dots at a
        // collapsed/origin position — the "三个点重合" overlap. Pinning the layout here makes the
        // dots structurally incapable of collapsing; the per-frame update only touches dynamic
        // state (overall Y, opacity, scale, blur).
        let totalWidth = dotSize * CGFloat(surfaceInterludeDots.count)
            + spacing * CGFloat(max(0, surfaceInterludeDots.count - 1))
        surfaceInterludeDotContainer.bounds = CGRect(x: 0, y: 0, width: totalWidth, height: dotSize)
        var x: CGFloat = 0
        for dot in surfaceInterludeDots {
            dot.contentsScale = scale
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.position = CGPoint(x: x + dotSize / 2, y: dotSize / 2)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = NSColor.white.cgColor
            dot.masksToBounds = false
            surfaceInterludeDotContainer.addSublayer(dot)
            x += dotSize + spacing
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
        // Centre the dots in the reserved interlude gap. baseY already carries the interlude anchor
        // advance (runtimeConfiguration), so at full interlude this lands exactly on the active
        // centre; before/after it sits centred in the gap below the preceding line.
        let y = baseY + configuration.effectiveManualOffset + rowHeight
            + NativeLyricsHeightAccumulator.interludeGapHeight / 2 - NativeLyricsDotPhasePlan.baseDotSize / 2
        surfaceInterludeOverlay.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let dotSize = NativeLyricsDotPhasePlan.baseDotSize
        let containerX = nativeLyricContentLeadingInset
        // The container bounds and per-dot positions are STATIC (set once in setupSurfaceInterludeDots),
        // so they can never collapse here. Only the group's screen position (Y travels with the gap),
        // opacity, scale and blur are dynamic.
        surfaceInterludeDotContainer.position = CGPoint(
            x: containerX + surfaceInterludeDotContainer.bounds.width / 2,
            y: y + dotSize / 2
        )
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
            dot.opacity = Float(plan.opacities[index])
            dot.setAffineTransform(CGAffineTransform(scaleX: plan.scales[index], y: plan.scales[index]))
            dot.isHidden = false
        }
    }

    private func installLocalEventMonitor() {
        guard localEventMonitor == nil else { return }
        // Left-mouse-down is deliberately NOT in the local monitor. Tap-to-jump is handled by the
        // surface's own mouseDown: which goes through proper AppKit hit testing: reserved overlay
        // zones pass through (calls super, event reaches the SwiftUI responder chain), and clicks
        // on lyrics rows fire the tap handler. Intercepting at the app level created a timing bug:
        // the first click of a hover entered before configuration.controlsVisible propagated, so
        // the zone check failed and the click was eaten — triggering tap-to-jump through the
        // buttons/controls the user was aiming for (the "click-through" bug).
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self,
                  self.window === event.window,
                  self.shouldHandleLocalEvent(event) else {
                return event
            }
            switch event.type {
            case .scrollWheel:
                return self.handleNativeScrollWheel(event) ? nil : event
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


    private static func configureSignature(_ c: LyricsLayerRendererConfiguration) -> String {
        // Every render-affecting field. If two configs share this, re-running the full row
        // reconcile is pure churn — the source of the staged-load flash storm.
        var s = "n\(c.rows.count)|f\(c.rows.first?.id ?? "-")|l\(c.rows.last?.id ?? "-")"
        s += "|i\(c.effectiveCurrentIndex)|r\(c.renderedIndices.count)|h\(c.accumulatedHeights.count)"
        s += "|a\(Int(c.anchorY))|w\(Int(c.rowWidth))|il\(c.interludeAfterIndex ?? -1)"
        s += "|m\(String(describing: c.playbackMode))|ms\(c.isManualScrolling ? 1 : 0)"
        s += "|tr\(c.showTranslation ? 1 : 0)\(c.isTranslating ? 1 : 0)\(c.translationFailed ? 1 : 0)"
        s += "|pt\(c.pendingTranslationLineIndices.count)|sy\(c.hasSyllableSync ? 1 : 0)"
        s += "|rm\(c.reduceMotion ? 1 : 0)|si\(c.suppressInitialMotion ? 1 : 0)"
        return s
    }

    func configure(_ configuration: LyricsLayerRendererConfiguration) {
        installLocalEventMonitor()
        let isTrackChange = self.configuration.map {
            !Self.isSameTrackIdentity($0.trackContext, configuration.trackContext)
        } ?? false
        // Coalesce the reconfigure storm: SwiftUI calls updateNSView→configure on every body
        // re-eval (a dozen onChange handlers + per-tick time). During an uncached staged load
        // (blank → first match → refined match) most of those carry IDENTICAL structure; re-running
        // the row reconcile each time is what flashes. Skip structural duplicates. A real track
        // change, line advance, measurement update, or translation change all change the signature.
        let signature = Self.configureSignature(configuration)
        #if DEBUG
        if !debugSkipDedupe, !isTrackChange, signature == lastAppliedConfigureSignature {
            return
        }
        #else
        if !isTrackChange, signature == lastAppliedConfigureSignature {
            return
        }
        #endif
        lastAppliedConfigureSignature = signature
        if let previous = self.configuration?.trackContext,
           !Self.isSameTrackIdentity(previous, configuration.trackContext) {
            cancelManualScrollTimers()
            cancelNativeLineAdvanceTimer()
            manualScrollState.reset()
            manualPresentationNeedsApply = false
            // Drop the engine's cross-track state so the new track snaps to position on frame 0
            // instead of briefly placing rows at ty=0 (the presentation-layer overlap bloom,
            // confirmed via the bloom probe: presSpread=0 while the model ySpread was normal).
            presentationEngine.resetForTrackChange()
            forceSnapUntil = CACurrentMediaTime() + 0.8
            visualStates.removeAll()
            interludeBlendStates.removeAll()
            measuredHeightsByIndex.removeAll()
            lastAppliedYByRowID.removeAll()
            nativeSemanticCurrentIndex = nil
            nativeTimelineState = nil
            pausedSemanticLocked = false
            lastTextPhaseUpdateAt = nil
            deferredDeactivationIndex = nil
            initialMeasurementsPending = true
            initialRevealTicksRemaining = 2
            #if LOCAL_DEVELOPER_BUILD
            bloomPresentationDiagUntil = CACurrentMediaTime() + 1.5
            bloomTrajUntil = CACurrentMediaTime() + 2.0
            bloomTrajArmedAt = CACurrentMediaTime()
            DebugLogger.log("RendererReset", "track='\(configuration.trackContext.title.prefix(20))' rows=\(configuration.rows.count) — full wipe (visualStates/measuredHeights cleared)")
            #endif
        }
        // Lyrics for an UNCACHED track arrive seconds after the track wipe (fetch latency) — long
        // after the wipe's 0.8s force-snap window expired, and the empty-row configures in between
        // re-set the engine's lastCurrentIndex, so by the time the rows finally appear the engine
        // no longer snaps and springs them in from the top instead = the slide-down bloom (verified
        // in the user's screen recording). Re-arm the engine snap + force-snap window at the exact
        // moment the rows first appear (empty → non-empty), which is when they actually get positioned.
        if (self.configuration?.rows.isEmpty ?? true) && !configuration.rows.isEmpty {
            presentationEngine.resetForTrackChange()
            forceSnapUntil = CACurrentMediaTime() + 0.8
            // Rows are mounting NOW (empty → non-empty). Hide them until the loop commits a spread
            // frame so the first-frame pre-commit identity never shows as a stacked flash.
            initialMeasurementsPending = true
            initialRevealTicksRemaining = 2
            #if LOCAL_DEVELOPER_BUILD
            bloomTrajUntil = CACurrentMediaTime() + 2.0
            bloomTrajArmedAt = CACurrentMediaTime()
            #endif
        }
        if self.configuration == nil {
            initialMeasurementsPending = true
            initialRevealTicksRemaining = 2
        }
        self.configuration = configuration
        #if LOCAL_DEVELOPER_BUILD
        DebugLogger.log("RendererConfigure", "track='\(configuration.trackContext.title.prefix(20))' rows=\(configuration.rows.count) rendered=\(configuration.renderedIndices.count) curIdx=\(configuration.effectiveCurrentIndex) mode=\(configuration.playbackMode)")
        #endif

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
            if hasActiveTextAnimation(configuration: runtimeConfiguration) || isWithinAppearWindow {
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
        #if LOCAL_DEVELOPER_BUILD
        appendBloomTraj(phase: "cfg", configuration: runtimeConfiguration)
        // Post-commit sample: during the force-snap window the presentation LOOP is not running,
        // so the only in-window samples are these configure-time ones — taken mid-CATransaction,
        // where presentation() still reads the pre-commit identity. Re-read on the NEXT runloop
        // turn (after the transaction commits) to get the TRUE on-screen Y. If cfg-post still
        // shows presSpread=0 it is a real collapse; if it shows the model spread the cfg reading
        // was a pre-commit artifact.
        if CACurrentMediaTime() < bloomTrajUntil {
            let cfg = runtimeConfiguration
            DispatchQueue.main.async { [weak self] in
                self?.appendBloomTraj(phase: "cfg-post", configuration: cfg)
            }
        }
        #endif
        // Reveal policy. The reconcile just positioned the rows (model spread), but the presentation
        // layer needs one committed display cycle before it reflects those positions. When the
        // presentation loop is running it performs the reveal after that cycle (initialRevealTicksRemaining,
        // counted down in presentationTick). When NO loop will run (static/paused lyrics, or a plain
        // re-configure with no pending reveal), reveal immediately so rows never stay hidden.
        if initialRevealTicksRemaining == 0 || displayLink == nil {
            initialMeasurementsPending = false
            initialRevealTicksRemaining = 0
        }
    }

    #if LOCAL_DEVELOPER_BUILD
    /// Objective bloom measurement. Logs the active row's absolute on-screen Y and every
    /// input that determines it, one line per call, during the `bloomTrajUntil` window.
    /// Direct-file sink so the path/format literals survive Release stripping if ever needed.
    private func appendBloomTraj(phase: String, configuration: LyricsLayerRendererConfiguration) {
        let now = CACurrentMediaTime()
        guard now < bloomTrajUntil else { return }
        guard let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_traj.log") else { return }
        let t = Int((now - bloomTrajArmedAt) * 1000)
        let curIdx = configuration.effectiveCurrentIndex
        let anchorY = configuration.anchorY
        let engine = presentationEngine.presentation(for: curIdx)
        let engineY = engine?.y
        let engineTgt = engine?.targetY
        // Absolute on-screen Y of the active row = its presentation layer transform ty.
        var presY: CGFloat?
        var appliedY: CGFloat?
        if let id = rowIDByIndex[curIdx] {
            appliedY = lastAppliedYByRowID[id]
            if let layer = rowViews[id]?.layer {
                presY = layer.presentation()?.affineTransform().ty ?? layer.affineTransform().ty
            }
        }
        func f(_ v: CGFloat?) -> String { v.map { String(format: "%.1f", $0) } ?? "nil" }
        let forceSnap = now < forceSnapUntil
        // Cross-row spread: the "stacked at top → spread out" symptom is a collapse of the
        // ON-SCREEN row spread, invisible to the active-only sample above. Capture model spread
        // (appY min/max) vs presentation-layer spread (presY min/max) + active animation count
        // + zero-geometry (un-laid-out bright text = full blur) across every mounted row.
        var appYs: [CGFloat] = []
        var presYs: [CGFloat] = []
        var anims = 0
        var zeroGeo = 0
        for (_, view) in rowViews {
            guard let layer = view.layer else { continue }
            appYs.append(layer.affineTransform().ty)
            presYs.append(layer.presentation()?.affineTransform().ty ?? layer.affineTransform().ty)
            anims += layer.animationKeys()?.count ?? 0
            if view.debugMainBrightBoundsEmpty { zeroGeo += 1 }
        }
        let appSpread = (appYs.max() ?? 0) - (appYs.min() ?? 0)
        let presSpread = (presYs.max() ?? 0) - (presYs.min() ?? 0)
        let presTop = presYs.min() ?? 0
        // Height bookkeeping at this instant: snapY returns anchorY for EVERY row when the
        // accumulated offsets are missing/flat — the all-rows-stacked collapse. accH/rIdx/measH
        // counts vs rows.count show whether the heights cover the rows; tgtOff/rowOff are the
        // active row's offsets that feed snapY = anchorY - tgtOff + rowOff.
        let accH = configuration.accumulatedHeights.count
        let rIdx = configuration.renderedIndices.count
        let measH = measuredHeightsByIndex.count
        let tgtOff = configuration.accumulatedHeights[curIdx]
        let line = "[Traj] t=\(t) ph=\(phase) cur=\(curIdx) anchorY=\(f(anchorY)) engY=\(f(engineY)) engTgt=\(f(engineTgt)) appY=\(f(appliedY)) presY=\(f(presY)) | mRows=\(rowViews.count) appSpread=\(Int(appSpread)) presSpread=\(Int(presSpread)) presTop=\(Int(presTop)) anims=\(anims) zeroGeo=\(zeroGeo) | accH=\(accH) rIdx=\(rIdx) measH=\(measH) tgtOff=\(f(tgtOff)) | mode=\(configuration.playbackMode) forceSnap=\(forceSnap) rows=\(configuration.rows.count) initPend=\(initialMeasurementsPending)\n"
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    }
    #endif

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
            lastAppliedYByRowID[id] = nil
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
                let isDeferredDeactivation = row.index == deferredDeactivationIndex
                if isDeferredDeactivation {
                    applyFrame(for: row, view: view, configuration: runtimeConfiguration, snap: snapPositions)
                    continue
                }
                let contentUpdated = updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
                let needsActivationRefresh = textPhaseIndexChanged
                    && (row.index == activeTextPhaseIndex || row.index == previousTextPhaseIndex)
                if needsActivationRefresh && !contentUpdated {
                    view.configure(row: row, configuration: runtimeConfiguration)
                }
                // Set the row's frame FIRST, then (for the active row only) force its text
                // sublayers to lay out BEFORE applying the karaoke phase. updatePlaybackPhase's
                // per-word sweep needs the bright text-layer bounds; if it runs while the bounds
                // are still .zero (a freshly mounted or pooled row whose frame was just assigned)
                // applyActiveMainPhase falls back to the whole-line (line-level) sweep — the
                // "word-level lyrics inexplicably become line-level" symptom. Laying the active
                // row out here makes geometryReady true on the very first phase application.
                applyFrame(for: row, view: view, configuration: runtimeConfiguration, snap: snapPositions)
                if row.index == activeTextPhaseIndex {
                    if view.frame.size != .zero {
                        view.layoutSubtreeIfNeeded()
                    }
                    if let textSample = view.updatePlaybackPhase(configuration: runtimeConfiguration) {
                        renderTelemetry.recordTextPhase(textSample)
                    }
                }
            }
        }
        // Synchronous layout BEFORE the commit: applyFrame set each row view's frame, but
        // text sublayer frames are computed inside NSView.layout(), which AppKit runs
        // asynchronously on the next layout pass. Without forcing layout NOW, all text
        // sublayers render at frame .zero (new views) or stale positions (recycled) for
        // the first display frame — and with CIGaussianBlur on every row, the mispositioned
        // text at every row creates the "overlapping, bright, heavily blurred" first-frame
        // bloom. Force layout into THIS transaction so the display never sees the stale state.
        for (_, view) in rowViews where view.frame.size != .zero {
            view.layoutSubtreeIfNeeded()
        }
        // Bloom diagnostic: count rows carrying the karaoke bright overlay. >1 means
        // multiple rows are rendering full-brightness text simultaneously — the bloom
        // signature. Logged in the LOCAL_DEVELOPER_BUILD configuration (build_app.sh).
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        let ovlCount = rowViews.values.filter { $0.debugMainBrightOverlayActive }.count
        DebugLogger.log("BLoomDiag", "ovl=\(ovlCount) rows=\(visibleRows.count) curIdx=\(activeTextPhaseIndex) mounted=\(mountedCount) unmounted=\(unmountedCount)")
        #endif
        #if LOCAL_DEVELOPER_BUILD
        // Bloom probe (direct-file sink survives release stripping; touch /tmp/nanopod_bloom.log
        // to arm). One line per reconcile records, at the actual bloom moment:
        //   zeroGeo = visible rows whose bright text layer is NOT laid out (bounds≈0) → these
        //             render at origin + full blur = the "overlapping heavily blurred" bloom;
        //   ySpread/avgGap = how spread the row Ys are (small spread = rows bunched/overlapping);
        //   maxBlur = peak depth-of-field blur; ovl = simultaneous bright overlays.
        // The combination tells us which bloom mechanism is real instead of guessing.
        if let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_bloom.log") {
            let zeroGeo = rowViews.values.filter { $0.debugMainBrightBoundsEmpty }.count
            let ys = visibleRows.compactMap { lastAppliedYByRowID[$0.id] }
            let ySpread = (ys.max() ?? 0) - (ys.min() ?? 0)
            let avgGap = ys.count > 1 ? ySpread / CGFloat(ys.count - 1) : 0
            let maxBlur = visibleRows.compactMap { visualStates[$0.index]?.blur }.max() ?? 0
            // On-screen (presentation layer) state of the mounted rows — what the EYE sees,
            // possibly mid-animation, vs the model above. presSpread collapsing toward 0 while
            // ySpread is normal = the rows overlap ON SCREEN (animating in) = the real bloom.
            // Rows are positioned by layer.setAffineTransform(translationY:), NOT layer.position —
            // so the on-screen Y is the presentation layer's transform ty.
            var presYs: [CGFloat] = []
            var anims = 0
            for (_, view) in rowViews {
                guard let layer = view.layer else { continue }
                presYs.append(layer.presentation()?.affineTransform().ty ?? layer.affineTransform().ty)
                anims += layer.animationKeys()?.count ?? 0
            }
            let presSpread = (presYs.max() ?? 0) - (presYs.min() ?? 0)
            fh.seekToEndOfFile()
            fh.write("[Bloom] curIdx=\(activeTextPhaseIndex) rows=\(visibleRows.count) ovl=\(ovlCount) zeroGeo=\(zeroGeo) ySpread=\(Int(ySpread)) presSpread=\(Int(presSpread)) anims=\(anims) avgGap=\(Int(avgGap)) maxBlur=\(String(format: "%.1f", maxBlur)) snap=\(snapPositions) initPending=\(initialMeasurementsPending)\n".data(using: .utf8)!)
            fh.closeFile()
        }
        #endif
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
        // ROOT FIX for the track-switch bloom (verified via the bloom probe: rows=42, ySpread=0,
        // maxBlur=9 on the first frame after a switch). A configure can arrive with `rows`
        // populated but `renderedIndices` still empty (the two cross into the NSViewRepresentable
        // on slightly different ticks). With NO indices the height accumulator returns {}, EVERY
        // row falls back to Y=0, and the viewport selector then counts ALL rows as on-screen —
        // dozens of lines stacked at the top, each at full depth-of-field blur = the "initial
        // overlapping heavily blurred" bloom. renderedIndices is, by construction, exactly
        // rows.map(\.index) (LyricsView.refreshDisplayLineCache sets it that way), so deriving it
        // here when it is missing is exact, not a heuristic — it just closes the one-frame gap.
        if runtimeConfiguration.renderedIndices.isEmpty && !runtimeConfiguration.rows.isEmpty {
            runtimeConfiguration.renderedIndices = runtimeConfiguration.rows.map(\.index)
        }
        // For the first ~0.8s after a track switch, FORCE snap mode (directSnap) regardless of what
        // the SwiftUI side sent. Otherwise a line wave scheduled for the new track's first line
        // defeats suppressInitialMotion (`&& !isLineWaveActive`), the renderer runs natural mode, and
        // the engine springs the rows in from the top = the "stacked at top → slide down" bloom.
        // While forced, playbackMode == .directSnap so both the engine and applyFrame snap to the
        // settled positions; by the time the window ends the engine is parked there, so natural mode
        // resumes without a jump.
        if CACurrentMediaTime() < forceSnapUntil {
            runtimeConfiguration.suppressInitialMotion = true
        }
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
        // Interlude scroll advance — makes the interlude behave like a real lyric line. While an
        // interlude is active, advance the anchor so the gap reserved after the preceding line
        // reaches the active centre: the three dots take the centre, the preceding line recedes
        // above, the rows below stay below — exactly a line in the wave. Living in the anchor
        // (not a post-engine offset) keeps the interlude→next-line handoff a small spring, not a
        // reset jump. Ramped smoothly by interludeBlend.
        if let interludeIdx = runtimeConfiguration.interludeAfterIndex {
            let blend = interludeBlend(for: interludeIdx, isPrecedingInterlude: true, now: CACurrentMediaTime())
            let interludeRowHeight = measuredHeightsByIndex[interludeIdx] ?? 36
            runtimeConfiguration.anchorY -= blend * (interludeRowHeight + NativeLyricsHeightAccumulator.interludeGapHeight / 2)
        }
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
        // A sub-tolerance backward time correction (poll resync overshoot) just pulled the live index
        // back across a line boundary. That is NOT a seek — snapping back would reactivate the
        // just-demoted line at full brightness (the dim→bright revert). Hold the active line: keep the
        // prior semantic index + timeline so the demoted line keeps dimming from where it already was.
        if NativeLyricsSeekClassifier.isResyncRewind(
            previousIndex: nativeSemanticCurrentIndex,
            liveIndex: liveIndex,
            previousPlaybackTime: nativeTimelineState?.playbackTime,
            playbackTime: playbackTime,
            explicitSeek: explicitSeek,
            tolerance: Self.resyncRewindTolerance
        ) {
            if let heldIndex = nativeSemanticCurrentIndex {
                configuration.nativeSemanticCurrentIndex = heldIndex
            }
            if let held = nativeTimelineState {
                configuration.nativeScrollTargetIndex = held.scrollToIndex
                configuration.nativeHotActiveIndices = held.hotGroups
                configuration.nativeBufferedActiveIndices = held.bufferedGroups
            }
            #if LOCAL_DEVELOPER_BUILD
            DebugLogger.log("RewindHold", String(format: "held idx=%d (live=%d) backStep=%.3fs — jitter, not a seek (was the dim→bright revert)",
                nativeSemanticCurrentIndex ?? -1, liveIndex, (nativeTimelineState?.playbackTime ?? playbackTime) - playbackTime))
            #endif
            return
        }
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

    /// Largest per-tick position change a row may take in NATURAL mode. Springs peak
    /// around 25pt/tick on the biggest tap-to-jump scrolls; 60pt/tick (≈3600pt/s) is
    /// far above any legitimate motion but well below the one-tick teleports produced
    /// by engine-window/model handoff glitches (observed: 105-230pt for one tick,
    /// rendering as a misplaced blurred line for a frame). Snap modes are exempt —
    /// they teleport by design.
    private static let naturalModeMaxYStepPerTick: CGFloat = 60
    // A row's presentation transform sits at its un-positioned default (top — proven py≈0 in the
    // render census) for the first frame after it mounts, while its MODEL Y is already correct
    // (far). Core Animation paints it there, blurred — the line-switch "blurred row flash" and,
    // when many rows mount on a seek, the blurred pile. Suppress that single frame: once the
    // presentation Y reaches the model Y (next commit) the row reveals at the right place. The
    // census showed settled rows diverge ≤10px and normally-springing rows ≤150px, while
    // just-mounted rows diverge >150 (stuck at 0/edge) — so this threshold cleanly separates
    // "not yet positioned" from "legitimately moving". Tunable knob.
    static let unpositionedDivergenceThreshold: CGFloat = 150
    /// True when a row has not yet been positioned on screen (its presentation Y is still far
    /// from its model Y) — so it must not paint this frame. A nil presentation (never rendered)
    /// counts as unpositioned.
    static func isRowUnpositioned(presentationY: CGFloat?, modelY: CGFloat) -> Bool {
        guard let presentationY else { return true }
        return abs(presentationY - modelY) > unpositionedDivergenceThreshold
    }

    /// Interpolated playback time may drift backward by up to this much for a poll resync to correct
    /// overshoot (matches the interpolateTime backward-correction allowance). A non-explicit backward
    /// index move within this window is resync jitter — the renderer holds the active line instead of
    /// snapping back to a just-demoted one (the dim→bright revert guard).
    private static let resyncRewindTolerance: TimeInterval = 0.5

    private func applyFrame(
        for row: LayerBackedLyricRow,
        view: NativeLyricsRowView,
        configuration: LyricsLayerRendererConfiguration,
        snap: Bool
    ) {
        let engineState = snap ? nil : presentationEngine.presentation(for: row.index)
        let baseY = snap
            ? snapY(for: row, configuration: configuration)
            : (engineState?.y ?? snapY(for: row, configuration: configuration))
        let requestedY = baseY + configuration.effectiveManualOffset
        var y = requestedY
        // Teleport guard: a settled row must never jump a large distance for a single
        // tick in natural mode, whatever upstream produced the value (engine entry
        // momentarily missing → snapY fallback, or a configure carrying mid-update
        // heights). Step toward the new value instead; real springs converge well
        // under the cap, glitch spikes get absorbed and self-correct next tick.
        if !snap, let previous = lastAppliedYByRowID[row.id] {
            let delta = requestedY - previous
            if abs(delta) > Self.naturalModeMaxYStepPerTick {
                y = previous + Self.naturalModeMaxYStepPerTick * (delta > 0 ? 1 : -1)
                #if LOCAL_DEVELOPER_BUILD
                noteTeleportClamp(rowID: row.id, rowIndex: row.index, requestedY: requestedY, previousY: previous, engineBacked: engineState != nil)
                #endif
            }
        }
        lastAppliedYByRowID[row.id] = y
        let fallbackTarget = visualTarget(for: row, configuration: configuration, now: CACurrentMediaTime())
        let visual = visualStates[row.index] ?? NativeLyricsVisualMotionState(target: fallbackTarget)
        let height = measuredHeightsByIndex[row.index] ?? max(1, view.frame.height)
        let frame = CGRect(x: 0, y: 0, width: configuration.rowWidth, height: max(1, height))

        if view.frame.size != frame.size || view.frame.origin != .zero {
            view.frame = frame
        }
        var appliedOpacity = initialMeasurementsPending ? 0 : Float(visual.opacity)
        // Suppress a just-mounted row for the one frame its presentation layer is still at its
        // un-positioned default (top) while the model Y is already far — otherwise it paints there
        // blurred (the line-switch flash / seek pile, proven in the presentation census). Natural
        // mode only; deliberate snaps are handled by the existing reveal gates. Once the
        // presentation Y catches up to the model Y (next commit) the row reveals at the right place.
        if !snap, Self.isRowUnpositioned(presentationY: view.layer?.presentation()?.affineTransform().ty, modelY: y) {
            appliedOpacity = 0
        }
        view.layer?.opacity = appliedOpacity
        view.setPositioning(
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
        #if LOCAL_DEVELOPER_BUILD
        // Record the RAW requested y (pre-clamp) so upstream anomalies stay fully
        // visible in VisualSpike dumps even though the screen shows the clamped value.
        recordVisualTrajectory(
            rowID: row.id,
            rowIndex: row.index,
            y: requestedY,
            opacity: visual.opacity,
            blur: appliedBlur,
            scale: visual.scale,
            snap: snap,
            engineBacked: snap || engineState != nil
        )
        #endif
    }

    /// Last y actually applied per row (release builds too — feeds the teleport guard).
    /// Pruned on row unmount and cleared on track-identity reset.
    private var lastAppliedYByRowID: [String: CGFloat] = [:]

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
                // Same seam as snapY: honor the manual-scroll target-index override
                // the old fallback ignored, so the diagnostic snapshot agrees with
                // the renderer's live snap target.
                let targetIndex = NativeLyricsSnapMath.targetIndex(
                    isManualScrolling: configuration.effectiveIsManualScrolling,
                    scrollTargetIndex: configuration.effectiveScrollTargetIndex,
                    engineTargetIndex: presentationEngine.targetIndex(
                        for: index,
                        fallback: configuration.effectiveScrollTargetIndex
                    )
                )
                targetIndices[index] = targetIndex
                targetMinYByIndex[index] = NativeLyricsSnapMath.targetY(
                    rowIndex: index,
                    targetIndex: targetIndex,
                    anchorY: configuration.anchorY,
                    accumulatedHeights: configuration.accumulatedHeights
                )
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
        let targetIndex = NativeLyricsSnapMath.targetIndex(
            isManualScrolling: configuration.effectiveIsManualScrolling,
            scrollTargetIndex: configuration.effectiveScrollTargetIndex,
            engineTargetIndex: presentationEngine.targetIndex(
                for: row.index,
                fallback: configuration.effectiveScrollTargetIndex
            )
        )
        return NativeLyricsSnapMath.targetY(
            rowIndex: row.index,
            targetIndex: targetIndex,
            anchorY: configuration.anchorY,
            accumulatedHeights: configuration.accumulatedHeights
        )
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
            #if LOCAL_DEVELOPER_BUILD
            self.recordAggregateBrightness(configuration: runtimeConfiguration, snap: snap)
            self.appendBloomTraj(phase: snap ? "frm-s" : "frm", configuration: runtimeConfiguration)
            self.recordPresentationCensus(snap: snap)
            #endif
        }
        if managesTransaction {
            withDisabledLayerActions(applyFrames)
        } else {
            applyFrames()
        }
    }

    /// Smooth motion moves a channel in ONE direction (or holds). A stumble / flicker / repeat
    /// is a channel that BOTH rises and falls (beyond epsilon) inside a short window — it
    /// hesitated, doubled back, or oscillated. Returns true for that signature. Pure + tested.
    static func censusOscillates(_ values: [CGFloat], epsilon: CGFloat) -> Bool {
        guard values.count >= 3 else { return false }
        var rose = false
        var fell = false
        for i in 1..<values.count {
            let d = values[i] - values[i - 1]
            if d > epsilon { rose = true }
            if d < -epsilon { fell = true }
        }
        return rose && fell
    }

    #if LOCAL_DEVELOPER_BUILD
    // ───────────────────────────────────────────────────────────────────────────
    // Presentation census (render-truth probe). The model probes read clean, yet the owner
    // sees flashing, stumbling, hesitating, repeating motion. Those are PRESENTATION-layer
    // anomalies. Each paint we read every mounted row's presentation state across ALL visible
    // channels — Y, opacity, blur, karaoke-bright, scale — keep a short per-row history, and
    // dump whenever ANY channel OSCILLATES (rises and falls within the window = a stumble /
    // flicker / repeat), or two rows overlap on screen. Direct file sink (survives release
    // stripping); arm with:  touch /tmp/nanopod_census.log
    // ───────────────────────────────────────────────────────────────────────────
    private var censusFrameCounter = 0
    private struct CensusTrack { var y: [CGFloat] = []; var op: [CGFloat] = []; var blur: [CGFloat] = []; var bright: [CGFloat] = []; var scale: [CGFloat] = [] }
    private var censusTracks: [Int: CensusTrack] = [:]
    private func recordPresentationCensus(snap: Bool) {
        guard let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_census.log") else { return }
        defer { fh.closeFile() }
        censusFrameCounter += 1
        let window = 6
        var live = Set<Int>()
        var anomalies: [String] = []
        struct CRow { let idx: Int; let content: String; let presY: CGFloat; let presOp: Float; let h: CGFloat }
        var rows: [CRow] = []
        for (_, view) in rowViews {
            guard let row = view.currentRow else { continue }
            live.insert(row.index)
            let y = view.debugPresentationY
            let op = CGFloat(view.debugPresentationOpacity)
            let blur = view.debugAppliedBlurRadius
            let bright = CGFloat(view.debugMainBrightOpacity)
            let scale = view.debugPresentationScale
            var t = censusTracks[row.index] ?? CensusTrack()
            t.y.append(y); t.op.append(op); t.blur.append(blur); t.bright.append(bright); t.scale.append(scale)
            if t.y.count > window {
                t.y.removeFirst(); t.op.removeFirst(); t.blur.removeFirst(); t.bright.removeFirst(); t.scale.removeFirst()
            }
            censusTracks[row.index] = t
            // Oscillation = the stumble / flicker signature. Skip deliberate snaps.
            if !snap {
                func fmt(_ v: [CGFloat], _ f: String) -> String { v.map { String(format: f, $0) }.joined(separator: ",") }
                var ch: [String] = []
                if Self.censusOscillates(t.op, epsilon: 0.05) { ch.append("OP[\(fmt(t.op, "%.2f"))]") }
                if Self.censusOscillates(t.bright, epsilon: 0.05) { ch.append("BRIGHT[\(fmt(t.bright, "%.2f"))]") }
                if Self.censusOscillates(t.blur, epsilon: 1.0) { ch.append("BLUR[\(fmt(t.blur, "%.1f"))]") }
                if Self.censusOscillates(t.y, epsilon: 12) { ch.append("Y[\(fmt(t.y, "%.0f"))]") }
                if Self.censusOscillates(t.scale, epsilon: 0.02) { ch.append("SCALE[\(fmt(t.scale, "%.3f"))]") }
                if !ch.isEmpty { anomalies.append("idx\(row.index)'\(view.debugContentPrefix)' \(ch.joined(separator: " "))") }
            }
            rows.append(CRow(idx: row.index, content: view.debugContentPrefix, presY: y, presOp: Float(op), h: measuredHeightsByIndex[row.index] ?? view.frame.height))
        }
        censusTracks = censusTracks.filter { live.contains($0.key) }
        guard !rows.isEmpty else { return }
        // On-screen overlap between two readable rows (the "two lines stacked" signature).
        let vis = rows.filter { $0.presOp > 0.25 }
        for i in 0..<vis.count {
            for j in (i + 1)..<vis.count {
                let a = vis[i], b = vis[j]
                let overlap = max(0, min(a.presY + a.h, b.presY + b.h) - max(a.presY, b.presY))
                if overlap / max(1, min(a.h, b.h)) > 0.4 {
                    anomalies.append("OVERLAP \(a.idx)'\(a.content)'x\(b.idx)'\(b.content)'#\(Int(overlap))")
                }
            }
        }
        let heartbeat = censusFrameCounter % 180 == 0
        guard !anomalies.isEmpty || heartbeat else { return }
        fh.seekToEndOfFile()
        if anomalies.isEmpty {
            let detail = rows.sorted { $0.idx < $1.idx }.map { String(format: "%d'%@'y%.0f op%.2f", $0.idx, $0.content, $0.presY, $0.presOp) }.joined(separator: " ")
            fh.write("[Census] hb n=\(rows.count) | \(detail)\n".data(using: .utf8)!)
        } else {
            fh.write("[Census] f\(censusFrameCounter)\(snap ? " SNAP" : "") | \(anomalies.joined(separator: " ; "))\n".data(using: .utf8)!)
        }
    }
    #endif

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

    /// The post-track-switch "appear" window. While true, freshly-mounted rows are positioned
    /// ONLY by their layer transform (frame.origin stays 0,0); AppKit's first layout pass after the
    /// mount collapses those transforms, and in directSnap mode the engine has no motion so the
    /// loop would stop and never re-apply them — leaving every row stacked at the top, heavily
    /// blurred, until natural mode resumes ~0.8 s later (the "bloom", confirmed on-device). Keep the
    /// loop alive and re-applying for the whole window so the rows stay at their settled positions.
    private var isWithinAppearWindow: Bool { CACurrentMediaTime() < forceSnapUntil }

    private func stopPresentationLoopIfIdle(runtimeConfiguration: LyricsLayerRendererConfiguration) {
        guard !isWithinAppearWindow,
              pendingTapToLineSettleTiming == nil,
              !presentationEngine.hasActiveMotion,
              !hasActiveVisualMotion,
              !hasActiveTextAnimation(configuration: runtimeConfiguration),
              runtimeConfiguration.interludeAfterIndex == nil,
              deferredDeactivationIndex == nil else { return }
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
        // Reveal gate countdown: hold the just-mounted rows hidden until the loop has committed a
        // spread frame, then reveal them already in position (no first-frame stacked flash). The
        // tick that reaches 0 applies frames at real opacity in THIS pass, after the prior tick's
        // spread positions have committed to the presentation layer.
        if initialRevealTicksRemaining > 0 {
            initialRevealTicksRemaining -= 1
            if initialRevealTicksRemaining == 0 {
                initialMeasurementsPending = false
            }
        }
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
        #if LOCAL_DEVELOPER_BUILD
        // #2a lag detector: when the active line finally advances, record how far past the new
        // line's own start time the playback clock already was (= how late the refresh landed)
        // and via which path. displayInterval == nil ⇒ the idle line-advance Timer fired (the
        // path most exposed to main-thread contention); a positive lag here is the "song
        // progresses while lyrics fail to refresh" symptom captured with a number + a source.
        if activeTextLineChanged, runtimeConfiguration.playbackMode == .natural {
            let newIdx = runtimeConfiguration.effectiveCurrentIndex
            if let newStart = runtimeConfiguration.rows.first(where: { $0.index == newIdx })?.displayLine.line.startTime {
                let lag = configuration.musicController.lyricRenderTime() - newStart
                if lag > 0.25, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_sync.log") {
                    let src = displayInterval == nil ? "idleTimer" : "displayLink"
                    fh.seekToEndOfFile()
                    fh.write("[SyncLag] lag=\(String(format: "%.2f", lag))s idx=\(previousSemanticIndex.map(String.init) ?? "nil")→\(newIdx) src=\(src)\n".data(using: .utf8)!)
                    fh.closeFile()
                }
            }
        }
        #endif
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
            // During the appear window re-apply every tick: the rows have no engine motion in
            // directSnap mode, but AppKit keeps collapsing their transforms after the mount, so
            // they must be re-pinned each frame until natural mode (with its springs) takes over.
            || isWithinAppearWindow
        manualPresentationNeedsApply = false
        withDisabledLayerActions {
            if activeTextLineChanged {
                refreshTextRowsForActiveLineChange(
                    previousIndex: previousSemanticIndex,
                    currentIndex: runtimeConfiguration.effectiveCurrentIndex,
                    runtimeConfiguration: runtimeConfiguration
                )
            }
            // Fade the receding line's bright sung-overlay toward 0 in step with its opacity recede,
            // so it never snaps off at finalization (#2c blink). Progress maps the row's current
            // opacity (active ≈1.0 → past ≈0.35) onto [1,0]; finalizeDeferredDeactivation then clears
            // the (already near-invisible) overlay + mask once the row settles.
            if let deferredIdx = deferredDeactivationIndex,
               let id = rowIDByIndex[deferredIdx],
               let view = rowViews[id] {
                let opacity = visualStates[deferredIdx]?.opacity ?? 1.0
                let progress = max(0, min(1, (opacity - 0.35) / 0.65))
                view.updateDeactivationFade(progress: progress)
            }
            finalizeDeferredDeactivation(runtimeConfiguration: runtimeConfiguration)
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
        #if LOCAL_DEVELOPER_BUILD
        auditImplicitAnimationsIfNeeded(now: now)
        // Presentation-layer bloom probe: during the post-track-switch window, log what the rows
        // look like ON SCREEN (presentation layers), not just in the model. presSpread = on-screen
        // vertical spread of the mounted rows; mpDiv = max |model − presentation| per row; anims =
        // total live animations. If presSpread collapses toward 0 (or mpDiv/anims spike) while the
        // model probe reports a normal spread, the bloom is an on-screen transient, not the model.
        if now < bloomPresentationDiagUntil, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_bloom.log") {
            var presYs: [CGFloat] = []
            var mpDiv: CGFloat = 0
            var anims = 0
            var blurred = 0
            for (_, view) in rowViews {
                guard let layer = view.layer else { continue }
                let modelY = layer.position.y
                let presY = layer.presentation()?.position.y ?? modelY
                presYs.append(presY)
                mpDiv = max(mpDiv, abs(modelY - presY))
                anims += layer.animationKeys()?.count ?? 0
                if (layer.presentation()?.filters?.isEmpty == false) || (layer.filters?.isEmpty == false) { blurred += 1 }
            }
            let presSpread = (presYs.max() ?? 0) - (presYs.min() ?? 0)
            fh.seekToEndOfFile()
            fh.write("[BloomPres] presSpread=\(Int(presSpread)) mpDiv=\(Int(mpDiv)) anims=\(anims) blurred=\(blurred) rows=\(rowViews.count)\n".data(using: .utf8)!)
            fh.closeFile()
        }
        // #2c dim-line blink probe: on each line advance, track the JUST-RECEDED line for ~1.2s and
        // log its row opacity + bright-overlay opacity per tick. A clean recede is monotonic; a blink
        // shows as opacity rising after it started to fall, or the bright overlay jumping.
        if activeTextLineChanged, let prev = previousSemanticIndex {
            dimProbeIndex = prev
            dimProbeUntil = now + 1.2
        }
        if now < dimProbeUntil, let idx = dimProbeIndex,
           let id = rowIDByIndex[idx], let view = rowViews[id],
           let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_dim.log") {
            let rowOp = view.debugRowLayerOpacity
            let brightOp = view.debugMainBrightOpacity
            let deferred = idx == deferredDeactivationIndex
            fh.seekToEndOfFile()
            fh.write("[Dim] idx=\(idx) cur=\(runtimeConfiguration.effectiveCurrentIndex) rowOp=\(String(format: "%.3f", rowOp)) brightOp=\(String(format: "%.3f", brightOp)) deferred=\(deferred)\n".data(using: .utf8)!)
            fh.closeFile()
        }
        #endif
        stopPresentationLoopIfIdle(runtimeConfiguration: runtimeConfiguration)
    }

    #if LOCAL_DEVELOPER_BUILD
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Implicit-animation auditor (diagnosis tooling)
    //
    // One-frame glitches are nearly impossible to capture by eye or screenshots. Any
    // animation attached to a renderer layer that we did not add by name is an
    // implicit-action leak; the auditor turns each into a deterministic log line with
    // the layer path + offending keys. Sampled every 15 ticks (≈4 Hz at 60 Hz): an
    // implicit action lives 0.25 s, so every leak is observed at least once. Each
    // unique signature logs at most once per 2 s to keep the log readable.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private static let explicitAnimationKeys: Set<String> = ["translationLoadingOpacity", "translationGrowIn"]

    private func auditImplicitAnimationsIfNeeded(now: CFTimeInterval) {
        implicitAnimationAuditTickCounter += 1
        guard implicitAnimationAuditTickCounter % 15 == 0, let root = layer else { return }
        var stack: [(CALayer, String)] = [(root, "surface")]
        while let (current, path) = stack.popLast() {
            let stray = (current.animationKeys() ?? []).filter { !Self.explicitAnimationKeys.contains($0) }
            if !stray.isEmpty {
                let signature = "\(path)<\(type(of: current))>:\(stray.sorted().joined(separator: ","))"
                let last = lastImplicitAnimationAuditLog[signature] ?? 0
                if now - last > 2 {
                    lastImplicitAnimationAuditLog[signature] = now
                    DebugLogger.log("ImplicitAnimLeak", signature)
                }
            }
            if let mask = current.mask { stack.append((mask, path + ".mask")) }
            for (i, sub) in (current.sublayers ?? []).enumerated() { stack.append((sub, path + ".\(i)")) }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Visual trajectory recorder (self-flagging diagnosis)
    //
    // The implicit-animation auditor catches stray ANIMATIONS; this recorder catches
    // wrong VALUES: a row rendered for 1-2 ticks at the wrong y / blur / opacity and
    // then corrected (the "heavily blurred line flashes" class — invisible to the
    // auditor because every property set is legitimate, just transiently wrong).
    // Per visible row we keep a short ring of applied values per tick and flag
    // jump-and-revert trajectories:
    //   - mount flash: first tick differs wildly from the immediately-settled value
    //   - spike: a big step out followed by a big step back within a few ticks
    // Snap modes (track change, direct snap, manual scroll release) legitimately
    // teleport rows, so samples recorded with snap=true never trigger flags.
    // Each flag dumps the trajectory + context once per row per 2s.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private struct VisualTrajectorySample {
        let time: CFTimeInterval
        let y: CGFloat
        let opacity: CGFloat
        let blur: CGFloat
        let scale: CGFloat
        let snap: Bool
        /// Whether the y came from the presentation engine (vs the snapY model
        /// fallback) — distinguishes engine-entry-drop glitches from model skew.
        let engineBacked: Bool
    }

    // Objective aggregate-brightness sensor. The reported glitches ("overlapping bright
    // text at the start", "dim→suddenly bright revert", a blur flash) could be driven by
    // opacity, blur, spatial stacking, or a reflow — we do NOT assume which. Each frame we
    // log ALL dimensions as scalars and only when a frame looks abnormal, so the time-series
    // spike's SIGNATURE attributes the cause. Numbers, never visual judgement.
    private var aggLastRowCount: Int = 0
    private var aggLastMaxBlur: CGFloat = 0
    private var aggFrameCounter: Int = 0

    private func recordAggregateBrightness(
        configuration: LyricsLayerRendererConfiguration,
        snap: Bool
    ) {
        aggFrameCounter += 1
        let rows = visibleRows(for: configuration)
        struct R { let idx: Int; let op: CGFloat; let blur: CGFloat; let top: CGFloat; let bot: CGFloat; let overlay: Bool }
        var rs: [R] = []
        for row in rows {
            guard let st = visualStates[row.index] else { continue }
            let y = lastAppliedYByRowID[row.id] ?? 0
            let h = measuredHeightsByIndex[row.index] ?? 0
            // The actual applied opacity (the row's visual-spring output), plus the bright karaoke
            // overlay — the channel model-opacity misses. >1 overlay at once = the bloom signature.
            let overlay = rowViews[row.id]?.debugMainBrightOverlayActive ?? false
            rs.append(R(idx: row.index, op: st.opacity, blur: st.blur, top: y, bot: y + h, overlay: overlay))
        }
        guard !rs.isEmpty else { return }
        let overlayCount = rs.filter { $0.overlay }.count
        let brightCount = rs.filter { $0.op > 0.6 }.count
        let sumO = rs.reduce(0) { $0 + $1.op }
        let maxBlur = rs.map(\.blur).max() ?? 0
        // Spatial stacking: two non-faint rows physically overlapping in Y → additive light.
        var stack: CGFloat = 0
        var stackPair = ""
        for i in 0..<rs.count {
            for j in (i + 1)..<rs.count where rs[i].op > 0.3 && rs[j].op > 0.3 {
                let overlap = max(0, min(rs[i].bot, rs[j].bot) - max(rs[i].top, rs[j].top))
                let minH = max(1, min(rs[i].bot - rs[i].top, rs[j].bot - rs[j].top))
                let score = min(rs[i].op, rs[j].op) * (overlap / minH)
                if score > stack { stack = score; stackPair = "\(rs[i].idx)\u{00D7}\(rs[j].idx)" }
            }
        }
        let blurJump = abs(maxBlur - aggLastMaxBlur)
        let rowChurn = rs.count != aggLastRowCount
        // >1 bright overlay = the bloom signature (multiple lines carry the karaoke-bright glyphs).
        let abnormal = brightCount >= 2 || overlayCount >= 2 || stack > 0.05 || blurJump > 6 || rowChurn
        let heartbeat = aggFrameCounter % 60 == 0
        defer { aggLastRowCount = rs.count; aggLastMaxBlur = maxBlur }
        guard abnormal || heartbeat else { return }
        let detail = rs.filter { $0.op > 0.3 || $0.overlay }
            .sorted { $0.idx < $1.idx }
            .map { String(format: "%d:o%.2f:b%.1f%@:y%.0f-%.0f", $0.idx, $0.op, $0.blur, $0.overlay ? ":OVL" : "", $0.top, $0.bot) }
            .joined(separator: " ")
        DebugLogger.log("AggBright", String(format: "bright=%d ovl=%d sumO=%.2f maxBlur=%.1f stack=%.2f(%@) rows=%d%@ | %@",
            brightCount, overlayCount, sumO, maxBlur, stack, stackPair.isEmpty ? "-" : stackPair, rs.count,
            snap ? " SNAP" : "", detail))
    }

    private func recordVisualTrajectory(
        rowID: String,
        rowIndex: Int,
        y: CGFloat,
        opacity: CGFloat,
        blur: CGFloat,
        scale: CGFloat,
        snap: Bool,
        engineBacked: Bool
    ) {
        let now = CACurrentMediaTime()
        var ring = visualTrajectories[rowID] ?? []
        ring.append(VisualTrajectorySample(time: now, y: y, opacity: opacity, blur: blur, scale: scale, snap: snap, engineBacked: engineBacked))
        if ring.count > 24 { ring.removeFirst(ring.count - 24) }
        visualTrajectories[rowID] = ring
        detectTrajectoryAnomaly(rowID: rowID, rowIndex: rowIndex, ring: ring, now: now)

        // Bound the dictionary: drop rows that haven't been applied for 5s.
        if now - lastTrajectoryPrune > 5 {
            lastTrajectoryPrune = now
            visualTrajectories = visualTrajectories.filter { now - ($0.value.last?.time ?? 0) < 5 }
        }
    }

    private func noteTeleportClamp(rowID: String, rowIndex: Int, requestedY: CGFloat, previousY: CGFloat, engineBacked: Bool) {
        let now = CACurrentMediaTime()
        let last = lastTrajectoryDump["clamp:" + rowID] ?? 0
        guard now - last > 2 else { return }
        lastTrajectoryDump["clamp:" + rowID] = now
        DebugLogger.log("TeleportClamp", "row[\(rowIndex)] \(rowID) requested \(Int(previousY))→\(Int(requestedY)) (Δ\(Int(requestedY - previousY))) source=\(engineBacked ? "engine" : "snapY-fallback")")
    }

    private func detectTrajectoryAnomaly(rowID: String, rowIndex: Int, ring: [VisualTrajectorySample], now: CFTimeInterval) {
        guard ring.count >= 3 else { return }
        let s = ring.suffix(4)
        let a = Array(s)
        // Only consider windows where the row was visible and not in a snap mode.
        guard a.allSatisfy({ !$0.snap }), a.contains(where: { $0.opacity > 0.05 }) else { return }
        let last = a.count - 1

        var reasons: [String] = []
        // Jump-and-revert on y: one step >40pt that comes >60% back within the window.
        for i in 1..<last {
            let out = a[i].y - a[i - 1].y
            let back = a[last].y - a[i].y
            if abs(out) > 40, abs(back) > abs(out) * 0.6, out.sign != back.sign {
                reasons.append("y \(Int(a[i - 1].y))→\(Int(a[i].y))→\(Int(a[last].y))")
                break
            }
        }
        // Blur flash: rendered radius spikes by >3.5 and reverts.
        for i in 1..<last {
            let out = a[i].blur - a[i - 1].blur
            let back = a[last].blur - a[i].blur
            if abs(out) > 3.5, abs(back) > abs(out) * 0.6, out.sign != back.sign {
                reasons.append("blur \(String(format: "%.1f→%.1f→%.1f", a[i - 1].blur, a[i].blur, a[last].blur))")
                break
            }
        }
        // Opacity flash: visible→invisible→visible (or inverse) inside the window.
        for i in 1..<last {
            let out = a[i].opacity - a[i - 1].opacity
            let back = a[last].opacity - a[i].opacity
            if abs(out) > 0.5, abs(back) > 0.4, out.sign != back.sign {
                reasons.append("opacity \(String(format: "%.2f→%.2f→%.2f", a[i - 1].opacity, a[i].opacity, a[last].opacity))")
                break
            }
        }
        // Opacity revert (the past-line brighten glitch): a line that ENDS dim (< 0.55)
        // but bumps UP by > 0.12 somewhere mid-window and falls back. The 0.5 flash
        // threshold above misses it, and the wobble plays out over ~8-12 ticks (wider
        // than the 4-sample window), so scan a longer window. Generic — fires for any
        // dimming line whose brightness reverses, whatever drives it upstream.
        let revertWindow = Array(ring.suffix(12))
        if revertWindow.count >= 5,
           let endO = revertWindow.last?.opacity, endO < 0.55,
           let startO = revertWindow.first?.opacity,
           let peakIdx = revertWindow.indices.max(by: { revertWindow[$0].opacity < revertWindow[$1].opacity }) {
            let peak = revertWindow[peakIdx].opacity
            if peakIdx != 0, peakIdx != revertWindow.count - 1,
               peak > startO + 0.12, peak > endO + 0.12 {
                reasons.append("opacityRevert \(String(format: "%.2f↑%.2f↓%.2f", startO, peak, endO))")
            }
        }
        guard !reasons.isEmpty else { return }
        let lastDump = lastTrajectoryDump[rowID] ?? 0
        guard now - lastDump > 2 else { return }
        lastTrajectoryDump[rowID] = now

        let trajectory = ring.suffix(14).map {
            String(format: "(t%+.0fms y%.0f o%.2f b%.1f s%.2f %@%@)",
                   ($0.time - now) * 1000, $0.y, $0.opacity, $0.blur, $0.scale,
                   $0.engineBacked ? "E" : "M", $0.snap ? " S" : "")
        }.joined(separator: " ")
        let ctx = configuration.map {
            "idx=\($0.effectiveCurrentIndex) rows=\($0.rows.count) track='\($0.trackContext.title.prefix(24))'"
        } ?? "no-config"
        DebugLogger.log("VisualSpike", "row[\(rowIndex)] \(rowID) \(reasons.joined(separator: " + ")) | \(ctx) | \(trajectory)")
    }
    #endif

    private func refreshTextRowsForActiveLineChange(
        previousIndex: Int?,
        currentIndex: Int,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        if let oldDeferred = deferredDeactivationIndex, oldDeferred != currentIndex {
            forceFinalizeDeactivation(index: oldDeferred, runtimeConfiguration: runtimeConfiguration)
        }
        if let previousIndex, previousIndex != currentIndex {
            if previousIndex == deferredDeactivationIndex {
                // already deferred
            } else {
                deferredDeactivationIndex = previousIndex
                // Capture the receding line's bright-overlay opacity so it can fade out smoothly
                // with the recede instead of staying frozen and snapping to 0 at finalization (#2c).
                if let id = rowIDByIndex[previousIndex] {
                    rowViews[id]?.beginDeactivationFade()
                }
            }
        }
        if let row = runtimeConfiguration.rows.first(where: { $0.index == currentIndex }),
           let view = rowViews[row.id] {
            _ = updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
        }
        lastConfiguredTextPhaseIndex = currentIndex
    }

    private func forceFinalizeDeactivation(index: Int, runtimeConfiguration: LyricsLayerRendererConfiguration) {
        deferredDeactivationIndex = nil
        guard let row = runtimeConfiguration.rows.first(where: { $0.index == index }),
              let view = rowViews[row.id] else { return }
        view.endDeactivationFade()
        view.clearSweepState()
        view.updatePlaybackPhase(configuration: runtimeConfiguration, managesTransaction: false)
        _ = updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
    }

    private func finalizeDeferredDeactivation(runtimeConfiguration: LyricsLayerRendererConfiguration) {
        guard let idx = deferredDeactivationIndex else { return }
        let settled: Bool
        if let state = visualStates[idx] {
            settled = state.isSettled || state.opacity < 0.38
        } else {
            settled = true
        }
        guard settled else { return }
        deferredDeactivationIndex = nil
        guard let row = runtimeConfiguration.rows.first(where: { $0.index == idx }),
              let view = rowViews[row.id] else { return }
        view.endDeactivationFade()
        view.clearSweepState()
        view.updatePlaybackPhase(configuration: runtimeConfiguration, managesTransaction: false)
        _ = updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
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
        guard configuration != nil else { return }
        // Run a FULL presentation tick, not a partial position-only update. The previous handler
        // advanced the timeline + engine (position → new line centered) and applied frames, but
        // never re-synced the per-row VISUAL targets (opacity/blur) or the text phase (karaoke
        // highlight). When a line advanced via this idle-line timer (the presentation loop is
        // stopped between line changes) rather than an active display-link tick, the previous
        // line's visual + highlight targets were left untouched — so it stayed fully bright while
        // the new line centered: the intermittent "current line not updated / highlight stuck on
        // the previous line" bug. presentationTick() captures previousSemanticIndex BEFORE
        // runtimeConfiguration mutates it, so it detects the change and runs the same path the
        // display-link uses (syncVisualTargets + refreshTextRowsForActiveLineChange +
        // updateTextPhases + applyFrames) and re-arms the next line-advance timer. One code path,
        // both channels (position + visuals) advance together.
        presentationTick(displayInterval: nil, displayTimestamp: nil)
        startPresentationLoop()
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
        guard let (_, view) = activeTextPhaseRow(for: runtimeConfiguration) else { return }
        // updatePlaybackPhase decides per-word (syllable) sweep vs whole-line sweep from the
        // bright text-layer's BOUNDS. On a per-line advance, refreshTextRowsForActiveLineChange
        // may have just changed this row's content (needsLayout), and AppKit lays text sublayers
        // out ASYNCHRONOUSLY — so without forcing layout here we read .zero/stale bounds,
        // geometryReady comes out false, and the row degrades to line-level (the random
        // "时不时逐字、时不时逐行" toggle). Force the active row's layout BEFORE reading its
        // geometry for the phase — same ordering fix as the reconcile path.
        if view.frame.size != .zero {
            view.layoutSubtreeIfNeeded()
        }
        guard let textSample = view.updatePlaybackPhase(configuration: runtimeConfiguration, managesTransaction: false) else {
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

    private let backgroundLayer = CALayer().lyricsInert()
    private let mainTextLayer = CATextLayer().lyricsInert()
    private let mainBrightTextLayer = CATextLayer().lyricsInert()
    private let mainBaseRevealMaskLayer = CALayer().lyricsInert()
    private let mainSweepMaskLayer = CAGradientLayer().lyricsInert()
    private let mainPerRunSweepMaskLayer = CALayer().lyricsInert()
    private let mainEmphasisLayer = CALayer().lyricsInert()
    private let translationTextLayer = CATextLayer().lyricsInert()
    private let translationBrightTextLayer = CATextLayer().lyricsInert()
    private let translationSweepMaskLayer = CAGradientLayer().lyricsInert()
    private let translationPerLineSweepMaskLayer = CALayer().lyricsInert()
    private let translationLoadingDotContainerLayer = CALayer().lyricsInert()
    private let translationLoadingDotLayers: [CALayer] = (0..<3).map { _ in CALayer().lyricsInert() }
    private let interludeTextLayer = CATextLayer().lyricsInert()
    private let dotContainerLayer = CALayer().lyricsInert()
    private let dotLayers: [CALayer] = (0..<3).map { _ in CALayer().lyricsInert() }
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
    // Per-frame memo for the active translation's measured height. applyActiveTranslationPhase runs
    // every display-link tick during playback; the height depends only on (text, width, font) which
    // are constant while a line is active — only the sweep PROGRESS changes per frame. Re-running the
    // full NSLayoutManager/NSTypesetter each frame was ~37% of the per-frame main-thread cost.
    private struct ActiveTranslationHeightKey: Equatable {
        let text: String
        let width: CGFloat
        let fontSize: CGFloat
        let lineSpacing: CGFloat
    }
    private var cachedActiveTranslationHeightKey: ActiveTranslationHeightKey?
    private var cachedActiveTranslationHeight: CGFloat = 0
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
    // ─────────────────────────────────────────────────────────────────────
    // layout() memoization. layout() runs on every CATransaction commit for
    // any view AppKit considers dirty — i.e. every presentation tick during
    // scroll/playback. Its body re-measures text via NSLayoutManager (two
    // measuredTextHeight calls) and reassigns every text-layer frame. Those
    // outputs depend ONLY on the inputs captured below; when none changed the
    // re-layout is pure waste (it was ~85% of main-thread time during scroll).
    // Early-return on an identical key so repeated layouts are ~free.
    private struct LineLayoutCacheKey: Equatable {
        let boundsWidth: CGFloat
        let boundsHeight: CGFloat
        let textWidth: CGFloat
        let isPrelude: Bool
        let displayText: String
        let constants: NativeLyricsTextConstants
        let showTranslation: Bool
        let translation: String?
        let awaitingTranslation: Bool
    }
    private var lastLineLayoutCacheKey: LineLayoutCacheKey?
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

    // ───────────────────────────────────────────────────────────────────────────
    // Deactivation overlay fade (#2c). A line that just lost focus is "deferred":
    // its karaoke sweep MASK is preserved (so the highlight does not reset) while the
    // row recedes, but updatePlaybackPhase is skipped — so the bright sung-overlay
    // stays frozen at its active opacity and then snaps to 0 when the deferral
    // finalizes (a brightness step on the receding line = the "blink"). beginDeactivationFade
    // captures the overlay's current opacity; updateDeactivationFade scales it toward 0 with
    // the recede so the highlight fades out smoothly instead of popping.
    // ───────────────────────────────────────────────────────────────────────────
    private var mainDeactivationOverlayBaseline: Float?
    private var translationDeactivationOverlayBaseline: Float?

    func beginDeactivationFade() {
        mainDeactivationOverlayBaseline = mainBrightTextLayer.isHidden ? 0 : mainBrightTextLayer.opacity
        translationDeactivationOverlayBaseline = translationBrightTextLayer.isHidden ? 0 : translationBrightTextLayer.opacity
    }

    func updateDeactivationFade(progress: CGFloat) {
        let f = Float(max(0, min(1, progress)))
        if let base = mainDeactivationOverlayBaseline {
            mainBrightTextLayer.opacity = base * f
        }
        if let base = translationDeactivationOverlayBaseline {
            translationBrightTextLayer.opacity = base * f
        }
    }

    func endDeactivationFade() {
        mainDeactivationOverlayBaseline = nil
        translationDeactivationOverlayBaseline = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        row = nil
        configuration = nil
        isHovering = false
        onHoverChanged = nil
        onHoverBackgroundVisible = nil
        onTap = nil
        mainDeactivationOverlayBaseline = nil
        translationDeactivationOverlayBaseline = nil
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
        cachedActiveTranslationHeightKey = nil
        cachedStaticTextPlanKey = nil
        cachedStaticTextPlan = nil
        lastLineLayoutCacheKey = nil
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

    /// Invokes layout() directly, bypassing AppKit's `needsLayout` gate. AppKit calls layout()
    /// on every commit while a view is dirty; this reproduces that repeated invocation so the
    /// layout() memoization can be asserted (an unchanged re-layout must not re-measure text).
    func debugInvokeLayoutDirectly() { layout() }

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

    var debugTranslationTextLayerFrame: CGRect { translationTextLayer.frame }

    var debugTranslationTextLayerHidden: Bool { translationTextLayer.isHidden }

    /// Animation keys attached to the translation base layer. Implicit-action leaks show up
    /// here as property-name keys ("position", "bounds", ...) that no renderer code ever adds.
    var debugTranslationTextLayerAnimationKeys: [String] { translationTextLayer.animationKeys() ?? [] }
    #endif

    // Available to both the unit tests (DEBUG) and the in-app brightness diagnostic
    // (LOCAL_DEVELOPER_BUILD release build). The karaoke bright overlay (full-brightAlpha
    // glyphs) is meant for ONE active line; if several rows carry it at once the panel blooms
    // (the #1 initial-load / rapid-switch overlap), and if a demoted line keeps it the line
    // flashes bright (the #3 revert). Counting it is the channel the model-opacity sensor missed.
    #if DEBUG || LOCAL_DEVELOPER_BUILD
    var debugMainBrightOverlayActive: Bool {
        mainBrightTextLayer.string != nil && !mainBrightTextLayer.isHidden
    }

    var debugRowLayerOpacity: Float { layer?.opacity ?? 1 }

    /// Bright karaoke-overlay opacity + presence. The #2c "dim line blinks while receding" suspect
    /// is the deferred-deactivation clearing this overlay abruptly (a brightness step) while the row
    /// is still partly visible. Sampling it per tick across a line advance shows whether the recede
    /// is monotonic (clean) or has a brighten-then-dim step (blink).
    var debugMainBrightOpacity: Float { mainBrightTextLayer.isHidden ? 0 : mainBrightTextLayer.opacity }

    /// True when the bright text layer has NOT been laid out yet (bounds ≈ .zero). A row in
    /// this state renders its text at frame origin + full depth-of-field blur — exactly the
    /// "overlapping heavily blurred" first-frame bloom. Used by the reconcile bloom probe to
    /// count how many visible rows escape the layout barrier on a track switch.
    var debugMainBrightBoundsEmpty: Bool {
        mainBrightTextLayer.bounds.width <= 1 || mainBrightTextLayer.bounds.height <= 1
    }

    // ── Presentation census accessors (render-truth probe) ──
    /// First few characters the MAIN (dim) text layer is actually showing — so the census can
    /// say WHICH line a blurred painted row belongs to (duplicate? stale? neighbor?).
    var debugContentPrefix: String {
        let s = (mainTextLayer.string as? NSAttributedString)?.string ?? (mainTextLayer.string as? String) ?? ""
        return String(s.prefix(6))
    }
    /// The CIGaussianBlur radius actually applied to this row's layer (the depth-of-field blur).
    var debugAppliedBlurRadius: CGFloat { max(0, appliedBlurRadius) }
    /// The PRESENTATION-layer on-screen Y (transform ty) — what Core Animation is rendering NOW,
    /// which can diverge from the committed model Y during a transition.
    var debugPresentationY: CGFloat { (layer?.presentation()?.affineTransform().ty) ?? (layer?.affineTransform().ty ?? 0) }
    var debugModelY: CGFloat { layer?.affineTransform().ty ?? 0 }
    var debugPresentationOpacity: Float { layer?.presentation()?.opacity ?? layer?.opacity ?? 0 }
    /// The PRESENTATION-layer scale (from the transform) — a stumbling scale oscillation reads as
    /// the active line "breathing" / jittering.
    var debugPresentationScale: CGFloat {
        let t = layer?.presentation()?.affineTransform() ?? layer?.affineTransform() ?? .identity
        return sqrt(t.a * t.a + t.c * t.c)
    }

    /// The per-run-sweep decision from the most recent ACTIVE updatePlaybackPhase. `true` =
    /// per-word karaoke wavefront; `false` = whole-line (line-level) sweep. For a row WITH
    /// syllable sync this must be `true`; if it is `false` the active line degraded to
    /// line-level because its text geometry was not laid out when the phase was computed.
    private(set) var debugLastAppliedActivePerRunSweep = false
    #endif


    // The row's on-screen position lives in a manual layer transform (not the view frame, so a
    // pure position change never triggers a text re-measure). AppKit's layout pass resets a
    // layer-backed view's transform to identity — proven by NativeLyricsRevealGateTests — which
    // snaps the row to the top for one frame (the load-correlated 花屏: more layout passes under
    // high CPU → more resets). Store the intended transform and re-assert it on every layout.
    private(set) var positioningTransform: CGAffineTransform = .identity
    func setPositioning(_ transform: CGAffineTransform) {
        positioningTransform = transform
        layer?.setAffineTransform(transform)
    }

    override func layout() {
        super.layout()
        // Re-assert the positioning transform AppKit's layout just reset (see above).
        layer?.setAffineTransform(positioningTransform)
        guard let row, let configuration else { return }
        let textX = nativeLyricContentLeadingInset
        // Single source of truth (same value updateTextLayers baked against). Deriving the frame
        // width from configuration.rowWidth instead of bounds.width removes the last bounds-timing
        // hazard, so the frame can never disagree with the baked line-breaks even on the first pass.
        let textWidth = contentTextWidth(configuration)
        // Memoization gate: build the key from cheap/cached inputs (staticTextPlan is cached) and
        // skip the whole layout body when nothing that affects it changed. layout() is invoked on
        // every commit; the body's NSLayoutManager measurement + frame writes are idempotent, so an
        // unchanged re-run produces identical frames — pure waste during scroll/playback.
        let staticPlan = staticTextPlan(for: row)
        let cacheKey = LineLayoutCacheKey(
            boundsWidth: bounds.width,
            boundsHeight: bounds.height,
            textWidth: textWidth,
            isPrelude: row.isPrelude,
            displayText: staticPlan.displayText,
            constants: staticPlan.constants,
            showTranslation: configuration.showTranslation,
            translation: row.displayLine.line.translation,
            awaitingTranslation: configuration.showTranslation
                && isAwaitingTranslation(row: row, configuration: configuration)
        )
        if cacheKey == lastLineLayoutCacheKey { return }
        lastLineLayoutCacheKey = cacheKey
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

        // "向下生长" gate: translation is async (Apple Translation framework, ~0.7s after the
        // lyrics show). While awaiting, this row shows the loading dots. When the translation
        // text then arrives we want it to grow in gently (fade + slide down) instead of popping.
        // Capture whether we were awaiting BEFORE this update mutates the dots/text below — the
        // dots-visible → translation transition is exactly the async arrival, and never fires on a
        // fresh scroll-mount of an already-translated row (dots never showed there).
        let wasAwaitingTranslation = !translationLoadingDotContainerLayer.isHidden

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
            // Async translation just arrived for this row → grow it in (fade + slide down).
            if wasAwaitingTranslation {
                playTranslationGrowIn(on: translationTextLayer)
                if !translationBrightTextLayer.isHidden, translationBrightTextLayer.string != nil {
                    playTranslationGrowIn(on: translationBrightTextLayer)
                }
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
        // Interlude dots are rendered by the surfaceInterludeDots OVERLAY (positioned at the gap
        // centre, tracks the manual-scroll offset). The per-row dotContainerLayer is ONLY for the
        // prelude (handled in the isPrelude early-return above). Leaving it visible for interlude
        // rows produced a SECOND, un-laid-out set of dots (collapsed at the row origin) that
        // overlapped the overlay during manual scroll. Keep it hidden here.
        dotContainerLayer.isHidden = true
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
            #if DEBUG || LOCAL_DEVELOPER_BUILD
            debugLastAppliedActivePerRunSweep = appliedMainProgress.appliedPerRunSweep
            #endif
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
        // Memoized: only re-measure when the translation text / width / font actually change, not on
        // every per-frame sweep tick (the height is constant while the line is active).
        let heightKey = ActiveTranslationHeightKey(
            text: translation.text,
            width: textWidth,
            fontSize: plan.constants.translationFontSize,
            lineSpacing: plan.constants.translationLineSpacing
        )
        let translationHeight: CGFloat
        if let cached = cachedActiveTranslationHeightKey, cached == heightKey {
            translationHeight = cachedActiveTranslationHeight
        } else {
            translationHeight = measuredTextHeight(
                translation.text,
                width: textWidth,
                font: .systemFont(ofSize: plan.constants.translationFontSize, weight: .semibold),
                lineSpacing: plan.constants.translationLineSpacing
            )
            cachedActiveTranslationHeightKey = heightKey
            cachedActiveTranslationHeight = translationHeight
        }
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
            let layer = CATextLayer().lyricsInert()
            layer.contentsScale = scale
            layer.font = NSFont.systemFont(ofSize: NativeLyricsTextConstants().mainFontSize, weight: .semibold)
            layer.fontSize = NativeLyricsTextConstants().mainFontSize
            layer.isWrapped = false
            layer.alignmentMode = .center
            layer.truncationMode = .none
            layer.masksToBounds = false
            layer.isHidden = true
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
            dimLayer.isHidden = true
            brightLayer.isHidden = true
            mainTextLayer.addSublayer(dimLayer)
            mainBrightTextLayer.addSublayer(brightLayer)
            mainDimWordGlyphLayers.append(dimLayer)
            mainBrightWordGlyphLayers.append(brightLayer)
            mainWordGlyphLayerSignatures.append(nil)
        }
    }

    private func makeWordGlyphLayer(scale: CGFloat, fontSize: CGFloat) -> CATextLayer {
        let layer = CATextLayer().lyricsInert()
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
            layer.isHidden = true
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
            layer.isHidden = true
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

    // Animation key for the translation "grow in" reveal. Must stay listed in the implicit-anim
    // allowlists (the presentationTick auditor `explicitAnimationKeys` and the
    // NativeLyricsImplicitAnimationTests allowlist) so this DELIBERATE animation is not flagged as
    // a stray implicit-action leak.
    static let translationGrowInAnimationKey = "translationGrowIn"

    /// "向下生长" reveal for an async-arriving translation: fade the text up from transparent while
    /// sliding it down a few points into its (already-correct) frame. Explicit named animation, so it
    /// bypasses the .lyricsInert action gate and never drifts (the frame is set instantly elsewhere —
    /// only opacity + a settle offset animate). Tunable: duration / slide distance.
    private func playTranslationGrowIn(on layer: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = layer.opacity
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -8.0
        slide.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: Self.translationGrowInAnimationKey)
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
