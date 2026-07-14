import AppKit
import CoreImage
import CoreVideo
import QuartzCore
import SwiftUI

let nativeLyricContentLeadingInset: CGFloat = 32
let nativeLyricContentTrailingInset: CGFloat = 32
private let nativeLyricAutoVisibleRowRadius = 12
private let nativeLyricManualVisibleRowRadius = 12
private let nativeLyricTextFrameInterval: TimeInterval = 1.0 / 60.0
private let nativeLyricFrameSummaryInterval: TimeInterval = 10
private let nativeLyricsTopOverlayReservedHeight: CGFloat = 56
private let nativeLyricsTopLeadingReservedWidth: CGFloat = 150
private let nativeLyricsTopTrailingReservedWidth: CGFloat = 72
private let nativeLyricsBottomControlsReservedHeight: CGFloat = 148

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
    var nativeTextActiveIndex: Int? = nil
    // Monotonic phase clock (defect-A fix, 2026-07-12). The semantic index is protected from the
    // SB clock's backward resync dips by the renderer's monotonic clock, but the TEXT PHASE
    // (karaoke sweep, translation reveal, bright overlays, dots) read the RAW clock — so in the
    // first ~0.3s of every line a backward dip pulled the raw time before the line start,
    // collapsed the active plan to progress 0 (overlay hidden / style reverted) and the next
    // forward frame re-lit it: the 2-3 style flashes per handoff on the 2026-07-11 recording.
    // Every phase-side consumer must read time through this closure so position and style
    // channels share ONE clock. nil (tests building bare configs) falls back to the raw clock.
    var nativePhaseClock: (() -> TimeInterval)? = nil

    func phaseRenderTime() -> TimeInterval {
        nativePhaseClock?() ?? musicController.lyricRenderTime()
    }

    var effectiveCurrentIndex: Int {
        nativeDirectSnapIndex
            ?? nativeManualScrollSnapshot?.frozenDisplayIndex
            ?? nativeSemanticCurrentIndex
            ?? currentIndex
    }

    var effectiveTextActiveIndex: Int {
        nativeTextActiveIndex ?? effectiveCurrentIndex
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
    nonisolated(unsafe) private let displayLinkScheduler = NativeLyricsDisplayLinkScheduler()
    private var rowTapHandlers: [Int: () -> Void] = [:]
    private var measuredHeightsByIndex: [Int: CGFloat] = [:]
    private var displayLink: CVDisplayLink?
    private var lastPresentationTick: CFTimeInterval?
    #if LOCAL_DEVELOPER_BUILD
    private var lastLoopStopVetoLog: CFTimeInterval = 0
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
    #if DEBUG
    // In-memory presentation census (testable). Records the APPLIED render values per row on every
    // applyFrame paint, so a headless test can run censusOscillates over each channel and catch a
    // channel that rises-then-falls within the window — a stumble / flicker / refresh — which the
    // settled-VALUE probes are blind to. The live file-sink census is LOCAL_DEVELOPER_BUILD only.
    struct DebugCensusTrack {
        var opacity: [CGFloat] = []
        var target: [CGFloat] = []
        var scale: [CGFloat] = []
        var blur: [CGFloat] = []
        var y: [CGFloat] = []
        var bright: [CGFloat] = []
        // Translation channels: bright-overlay opacity plus the sweep's expected vs applied
        // progress (-1 when no translation phase ran). A frozen `transApplied` while
        // `transExpected` advances is the stuck-full-reveal signature (defect-B class).
        var transBright: [CGFloat] = []
        var transExpected: [CGFloat] = []
        var transApplied: [CGFloat] = []
    }
    private(set) var debugCensusByIndex: [Int: DebugCensusTrack] = [:]
    private(set) var debugSemanticTrace: [Int] = []
    private(set) var debugClockTrace: [TimeInterval] = []
    var debugCensusEnabled = false
    func debugResetCensus() { debugCensusByIndex = [:]; debugSemanticTrace = []; debugClockTrace = [] }
    #endif
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
    // AMLL-aligned monotonic render clock: the last time value the surface was driven with. Backward
    // poll jitter is held at this peak so amllState never re-derives an earlier (brighter) hot set; an
    // explicit seek or a beyond-threshold backward jump follows it. nil until the first frame inits it.
    private var nativeRenderClock: TimeInterval?
    private var pausedSemanticLocked = false
    private var lastObservedSeekGeneration: Int = 0
    private var lastTextPhaseUpdateAt: CFTimeInterval?
    private var textActiveByRowIndex: [Int: Bool] = [:]
    private var lastScrollWheelTime: CFTimeInterval = 0
    private var hoveredRowIndex: Int?
    // Last cursor position inside the surface (surface-space), or nil when the cursor is outside the
    // surface / over a reserved overlay zone. The surface is the SINGLE hover authority: rows have no
    // tracking areas of their own, so when a row slides out from under a stationary cursor (line-advance
    // / scroll) AppKit fires no mouseExited. Re-resolving hover from this stored point on every layout
    // pass closes that gap — a moving row's hover follows the geometry, not stale enter/exit events.
    private var lastKnownCursorPoint: CGPoint?
    private var surfaceTrackingArea: NSTrackingArea?
    private var localEventMonitor: Any?
    private var lastConfigureEventSignature: String?
    private var lastAppliedConfigureSignature: String?
    #if DEBUG
    var debugSkipDedupe = false
    /// A/B seam: when true, visualCurrentIndex binds the visual demotion to the SEMANTIC line index
    /// (pre-1e1ffbf), instead of the scroll wave's per-row targetIndex (current). Headless-only.
    static var debugForceSemanticVisualIndex = false
    /// Headless seam for the tap-hit tests: enters manual-scroll state without synthesizing
    /// phase-tagged scroll-wheel events (NSEvent cannot fabricate those).
    func debugBeginManualScroll() {
        guard let configuration else { return }
        beginNativeManualScrollIfNeeded(configuration: runtimeConfiguration(from: configuration))
    }
    var debugManualScrollActive: Bool { manualScrollState.isActive }
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
    private var debugBypassInitialRevealGate = false
    var debugInitialMeasurementsPending: Bool {
        get { initialMeasurementsPending }
        set {
            initialMeasurementsPending = newValue
            debugBypassInitialRevealGate = !newValue
        }
    }
    /// Look up a mounted row view by its semantic index (tests assert per-row render state
    /// after driving the real configure → reconcile pipeline).
    func debugRowView(forIndex index: Int) -> NativeLyricsRowView? {
        guard let id = rowIDByIndex[index] else { return nil }
        return rowViews[id]
    }
    /// The renderer's resolved semantic (active) line index — what the surface believes is current.
    var debugNativeSemanticIndex: Int? { nativeSemanticCurrentIndex }
    /// The row index the surface currently believes the cursor is over (single hover authority).
    var debugHoveredRowIndex: Int? { hoveredRowIndex }
    /// Drives the geometry hover resolver from a fixed surface-space point (headless: no NSEvent).
    /// Mirrors updateNativeHoverFromEvent so tests exercise the SAME single-authority hover path,
    /// including seeding lastKnownCursorPoint for the on-reposition re-resolution.
    func debugMoveCursor(to point: CGPoint) {
        guard let configuration else { return }
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        guard !isPointInReservedOverlayZone(point, configuration: runtimeConfiguration) else {
            clearNativeHover()
            return
        }
        lastKnownCursorPoint = point
        updateNativeHover(from: point, configuration: runtimeConfiguration)
    }
    /// The interlude overlay dots' centre X positions (in the dot container's coordinate space).
    /// Tests assert these stay horizontally spaced — i.e. the "三个点重合" overlap can't recur.
    var debugInterludeDotCenterXs: [CGFloat] {
        surfaceInterludeDots.map { $0.position.x }
    }

    func debugNativePresentationSnapshot(lineIndices: [Int]) -> NativeLyricsPresentationSnapshot? {
        guard let configuration else { return nil }
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        return nativePresentationSnapshot(lineIndices: lineIndices, configuration: runtimeConfiguration)
    }

    func debugNativeVisualTarget(forIndex index: Int) -> NativeLyricsVisualTarget? {
        guard let configuration else { return nil }
        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        guard let row = runtimeConfiguration.rows.first(where: { $0.index == index }) else { return nil }
        let presentationSnapshot = nativePresentationSnapshot(lineIndices: [index], configuration: runtimeConfiguration)
        return visualTarget(for: row, configuration: runtimeConfiguration, presentationSnapshot: presentationSnapshot)
    }
    #endif

    private func armInitialRevealGate() {
        #if DEBUG
        if debugBypassInitialRevealGate {
            initialMeasurementsPending = false
            initialRevealTicksRemaining = 0
            return
        }
        #endif
        initialMeasurementsPending = true
        initialRevealTicksRemaining = 2
    }
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

    private func frameSnapMode(
        for configuration: LyricsLayerRendererConfiguration,
        now: CFTimeInterval = CACurrentMediaTime()
    ) -> NativeLyricsSnapMode {
        NativeLyricsSnapMode.resolve(
            playbackMode: configuration.playbackMode,
            isWithinAppearWindow: now < forceSnapUntil
        )
    }

    private let surfaceInterludeOverlay: NSView = {
        let v = _FlippedView()
        return v
    }()
    private let surfaceInterludeDotContainer = CALayer().lyricsInert()
    private let surfaceInterludeDots: [CALayer] = (0..<3).map { _ in CALayer().lyricsInert() }
    private var appliedSurfaceDotBlurRadius: CGFloat = -.greatestFiniteMagnitude

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        if let activeDisplayLink = displayLink {
            CVDisplayLinkStop(activeDisplayLink)
        }
        nativeLineAdvanceTimer?.invalidate()
        manualScrollEndTimer?.invalidate()
        manualScrollRecoveryTimer?.invalidate()
        nativeLineMotionSamplingTimer?.invalidate()
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
        let currentTime = configuration.phaseRenderTime()
        let plan = NativeLyricsDotPhasePlan.make(
            startTime: interlude.startTime,
            endTime: interlude.endTime,
            currentTime: currentTime,
            gateByTimeRange: true
        )
        surfaceInterludeOverlay.alphaValue = CGFloat(plan.overallOpacity)
        applySurfaceDotBlurRadius(plan.blur)
        for (index, dot) in surfaceInterludeDots.enumerated() {
            dot.opacity = Float(plan.opacities[index])
            dot.setAffineTransform(CGAffineTransform(scaleX: plan.scales[index], y: plan.scales[index]))
            dot.isHidden = false
        }
    }

    // Quantized + guarded like NativeLyricsRowView.applyDotBlurRadius: this runs on every
    // applyFrames pass while an interlude is configured, and an unguarded filters rewrite
    // re-composites the container each frame even when the radius has not changed.
    private func applySurfaceDotBlurRadius(_ radius: CGFloat) {
        let effectiveRadius = radius > 0.1 ? radius : 0
        let quantizedRadius = (effectiveRadius * 4).rounded(.toNearestOrAwayFromZero) / 4
        guard abs(appliedSurfaceDotBlurRadius - quantizedRadius) > 0.001 else { return }
        appliedSurfaceDotBlurRadius = quantizedRadius
        guard quantizedRadius > 0 else {
            surfaceInterludeDotContainer.filters = nil
            return
        }
        // Fresh instance per change — attached filters are immutable to CA; see
        // NativeLyricsRowView.applyBlurRadius.
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(Double(quantizedRadius), forKey: kCIInputRadiusKey)
        surfaceInterludeDotContainer.filters = filter.map { [$0] }
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
        // controlsVisible arms the bottom reserved tap zone. Omitting it deduped the
        // "controls faded out" reconfigure whenever nothing else changed (frozen index
        // during manual scroll = exactly that), so the invisible controls kept eating
        // taps in the bottom region — the "taps dead in reserved zones" report.
        s += "|cv\(c.controlsVisible ? 1 : 0)"
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
            measuredHeightsByIndex.removeAll()
            lastAppliedYByIndex.removeAll()
            nativeSemanticCurrentIndex = nil
            nativeTimelineState = nil
            pausedSemanticLocked = false
            lastTextPhaseUpdateAt = nil
            deferredDeactivationIndex = nil
            armInitialRevealGate()
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
            armInitialRevealGate()
            #if LOCAL_DEVELOPER_BUILD
            bloomTrajUntil = CACurrentMediaTime() + 2.0
            bloomTrajArmedAt = CACurrentMediaTime()
            #endif
        }
        if self.configuration == nil {
            armInitialRevealGate()
        }
        self.configuration = configuration
        #if LOCAL_DEVELOPER_BUILD
        DebugLogger.log("RendererConfigure", "track='\(configuration.trackContext.title.prefix(20))' rows=\(configuration.rows.count) rendered=\(configuration.renderedIndices.count) curIdx=\(configuration.effectiveCurrentIndex) mode=\(configuration.playbackMode)")
        #endif

        let runtimeConfiguration = runtimeConfiguration(from: configuration)
        updateNativeLineMotionSamplingTimer(configuration: runtimeConfiguration)
        consumeDirectSnapRequestIfNeeded(runtimeConfiguration)
        recordConfigureEventIfNeeded(configuration: runtimeConfiguration)
        let snapMode = frameSnapMode(for: runtimeConfiguration)
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
                playbackMode: snapMode.playbackMode
            ),
            onTargetsChanged: { [weak self] in
                self?.startPresentationLoop()
            }
        )

        let shouldSnap = snapMode.snapsPositions
        let shouldSnapVisuals = snapMode.snapsVisuals
        let visualTargetsChanged = reconcileVisibleRowViews(
            runtimeConfiguration: runtimeConfiguration,
            snapPositions: shouldSnap,
            snapVisuals: shouldSnapVisuals
        )
        if shouldSnap {
            if hasActiveTextAnimation(configuration: runtimeConfiguration) || snapMode.keepsPresentationLoopAlive {
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
        // The reconcile repositioned rows on its own transaction (the presentation loop may not run
        // for a static/paused re-configure). Re-resolve hover so it tracks the geometry even without
        // a presentation tick.
        withDisabledLayerActions { reresolveHoverAfterLayout() }
    }

    #if LOCAL_DEVELOPER_BUILD
    /// Objective bloom measurement. Logs the active row's absolute on-screen Y and every
    /// input that determines it, one line per call, during the `bloomTrajUntil` window.
    /// Direct-file sink so the path/format literals survive Release stripping if ever needed.
    private func appendBloomTraj(phase: String, configuration: LyricsLayerRendererConfiguration) {
        let now = CACurrentMediaTime()
        guard now < bloomTrajUntil else { return }
        guard DebugConfig.probeSinksEnabled, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_traj.log") else { return }
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
            appliedY = lastAppliedYByIndex[curIdx]
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
        let currentIndexSet = Set(runtimeConfiguration.rows.map(\.index))
        visualStates = visualStates.filter { currentIndexSet.contains($0.key) }
        let visualTargetsChanged = syncVisualTargets(
            runtimeConfiguration: runtimeConfiguration,
            visibleRows: visibleRows,
            snap: snapVisuals
        )
        let presentationSnapshot = nativePresentationSnapshot(
            lineIndices: visibleRows.map(\.index),
            configuration: runtimeConfiguration
        )
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
                    continue
                }
                let rowTextConfiguration = configurationForTextPhase(
                    for: row,
                    configuration: runtimeConfiguration,
                    presentationSnapshot: presentationSnapshot
                )
                updateTextActivation(
                    for: row,
                    textConfiguration: rowTextConfiguration,
                    runtimeConfiguration: runtimeConfiguration
                )
                updateParkedTextPhaseFreeze(
                    for: row,
                    textConfiguration: rowTextConfiguration,
                    runtimeConfiguration: runtimeConfiguration
                )
                if row.index == deferredDeactivationIndex {
                    continue
                }
                _ = updateContentIfNeeded(view: view, row: row, configuration: rowTextConfiguration)
            }
            let renderSnapshot = nativeFrameRenderSnapshot(
                rows: visibleRows,
                configuration: runtimeConfiguration,
                snap: snapPositions
            )
            for row in visibleRows {
                guard let view = rowViews[row.id] else { continue }
                // Set the row's frame FIRST, then (for the active row only) force its text
                // sublayers to lay out BEFORE applying the karaoke phase. updatePlaybackPhase's
                // per-word sweep needs the bright text-layer bounds; if it runs while the bounds
                // are still .zero (a freshly mounted or pooled row whose frame was just assigned)
                // applyActiveMainPhase falls back to the whole-line (line-level) sweep — the
                // "word-level lyrics inexplicably become line-level" symptom. Laying the active
                // row out here makes geometryReady true on the very first phase application.
                applyFrame(for: row, view: view, configuration: runtimeConfiguration, renderSnapshot: renderSnapshot)
                guard row.index != deferredDeactivationIndex else { continue }
                let rowTextConfiguration = configurationForTextPhase(
                    for: row,
                    configuration: runtimeConfiguration,
                    presentationSnapshot: presentationSnapshot
                )
                if shouldDriveTextPhase(row: row, textConfiguration: rowTextConfiguration, runtimeConfiguration: runtimeConfiguration) {
                    if view.frame.size != .zero {
                        view.layoutSubtreeIfNeeded()
                    }
                    if let textSample = view.updatePlaybackPhase(configuration: rowTextConfiguration) {
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
        DebugLogger.log("BLoomDiag", "ovl=\(ovlCount) rows=\(visibleRows.count) curIdx=\(runtimeConfiguration.effectiveCurrentIndex) mounted=\(mountedCount) unmounted=\(unmountedCount)")
        #endif
        #if LOCAL_DEVELOPER_BUILD
        // Bloom probe (direct-file sink survives release stripping; touch /tmp/nanopod_bloom.log
        // to arm). One line per reconcile records, at the actual bloom moment:
        //   zeroGeo = visible rows whose bright text layer is NOT laid out (bounds≈0) → these
        //             render at origin + full blur = the "overlapping heavily blurred" bloom;
        //   ySpread/avgGap = how spread the row Ys are (small spread = rows bunched/overlapping);
        //   maxBlur = peak depth-of-field blur; ovl = simultaneous bright overlays.
        // The combination tells us which bloom mechanism is real instead of guessing.
        if DebugConfig.probeSinksEnabled, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_bloom.log") {
            let zeroGeo = rowViews.values.filter { $0.debugMainBrightBoundsEmpty }.count
            let ys = visibleRows.compactMap { lastAppliedYByIndex[$0.index] }
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
            fh.write("[Bloom] curIdx=\(runtimeConfiguration.effectiveCurrentIndex) rows=\(visibleRows.count) ovl=\(ovlCount) zeroGeo=\(zeroGeo) ySpread=\(Int(ySpread)) presSpread=\(Int(presSpread)) anims=\(anims) avgGap=\(Int(avgGap)) maxBlur=\(String(format: "%.1f", maxBlur)) snap=\(snapPositions) initPending=\(initialMeasurementsPending)\n".data(using: .utf8)!)
            fh.closeFile()
        }
        #endif
        CATransaction.commit()
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
        if let interludeIdx = runtimeConfiguration.interludeAfterIndex,
           let row = runtimeConfiguration.rows.first(where: { $0.index == interludeIdx }) {
            let blend = interludeBlend(for: row, configuration: runtimeConfiguration)
            let interludeRowHeight = measuredHeightsByIndex[interludeIdx] ?? 36
            runtimeConfiguration.anchorY -= NativeLyricsSnapMath.interludeAnchorAdvance(
                blend: blend,
                rowHeight: interludeRowHeight
            )
        }
        synchronizeNativeSemanticIndex(configuration: &runtimeConfiguration)
        return runtimeConfiguration
    }

    private func synchronizeNativeSemanticIndex(
        configuration: inout LyricsLayerRendererConfiguration
    ) {
        // Install the monotonic phase clock: advance the shared peak on every read so the
        // presentation loop's per-tick phase updates (which run between configure() calls) get
        // fresh, never-backward time. A backward step beyond the resync tolerance is a real
        // discontinuity and is followed; synchronize itself re-anchors on explicit seeks below.
        let musicController = configuration.musicController
        configuration.nativePhaseClock = { [weak self] in
            let raw = musicController.lyricRenderTime()
            guard let self else { return raw }
            let held = NativeLyricsSeekClassifier.monotonicTime(
                previous: self.nativeRenderClock ?? raw,
                rawTime: raw,
                explicitSeek: false,
                seekThreshold: Self.resyncRewindTolerance
            )
            self.nativeRenderClock = held.value
            return held.value
        }
        guard configuration.playbackMode == .natural else {
            let snapIndex = configuration.effectiveCurrentIndex
            // A snap (seek / tap / direct snap) is a deliberate discontinuity: reset the monotonic
            // clock to the snapped time so natural playback resumes without holding against a stale peak.
            let snapTime = configuration.musicController.lyricRenderTime()
            nativeRenderClock = snapTime
            nativeSemanticCurrentIndex = snapIndex
            nativeTimelineState = NativeLyricsTimelinePolicy.AMLLState(
                playbackTime: snapTime,
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
        // AMLL alignment: drive the timeline off a MONOTONIC clock instead of the raw SB clock. A
        // backward poll-resync dip within the seek window holds at the peak, so amllState re-derives
        // the SAME hot set — no receded line regrows to the harmony tier (the "previous line pops").
        // This subsumes the old isResyncRewind hold: there is nothing to "hold" once the input can't
        // move backward. An explicit seek or a beyond-window backward jump reports .seek and resets.
        let rawTime = configuration.musicController.lyricRenderTime()
        let clock = NativeLyricsSeekClassifier.monotonicTime(
            previous: nativeRenderClock ?? rawTime,
            rawTime: rawTime,
            explicitSeek: explicitSeek,
            seekThreshold: Self.resyncRewindTolerance
        )
        nativeRenderClock = clock.value
        let playbackTime = clock.value
        let provisional = NativeLyricsTimelinePolicy.amllState(
            at: playbackTime,
            rows: configuration.rows,
            fallback: configuration.currentIndex,
            previous: nativeTimelineState,
            isSeeking: false
        )
        let liveIndex = provisional.semanticIndex
        lastObservedSeekGeneration = seekToken
        // .seek = an explicit progress-bar seek OR an external backward scrub beyond the window. Both
        // are real discontinuities that must reset the buffered trail. A forward jump of >1 line is
        // also a seek (index monotonicity) and is caught by isSeek below.
        let isSeek = clock.step == .seek
            || NativeLyricsSeekClassifier.isSeek(
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
        configuration: LyricsLayerRendererConfiguration,
        updatesPlaybackPhase: Bool = true
    ) -> Bool {
        let key = RowRenderKey(row: row, configuration: configuration)
        let needsContentUpdate = rowRenderKeys[row.id] != key
        if needsContentUpdate {
            renderTelemetry.recordContentUpdate()
            rowRenderKeys[row.id] = key
            view.configure(
                row: row,
                configuration: configuration,
                updatesPlaybackPhase: updatesPlaybackPhase
            )
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
    }

    @discardableResult
    private func syncVisualTargets(
        runtimeConfiguration: LyricsLayerRendererConfiguration,
        visibleRows: [LayerBackedLyricRow]? = nil,
        snap: Bool
    ) -> Bool {
        let rows = visualRowsToSync(
            visibleRows: visibleRows ?? self.visibleRows(for: runtimeConfiguration),
            configuration: runtimeConfiguration
        )
        let presentationSnapshot = nativePresentationSnapshot(
            lineIndices: rows.map(\.index),
            configuration: runtimeConfiguration
        )
        var changed = false
        for row in rows {
            let target = visualTarget(
                for: row,
                configuration: runtimeConfiguration,
                presentationSnapshot: presentationSnapshot
            )
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

    private func visualRowsToSync(
        visibleRows: [LayerBackedLyricRow],
        configuration: LyricsLayerRendererConfiguration
    ) -> [LayerBackedLyricRow] {
        var rowsByIndex = Dictionary(uniqueKeysWithValues: visibleRows.map { ($0.index, $0) })
        let allRowsByIndex = Dictionary(uniqueKeysWithValues: configuration.rows.map { ($0.index, $0) })
        for index in visualStates.keys where rowsByIndex[index] == nil {
            rowsByIndex[index] = allRowsByIndex[index]
        }
        return rowsByIndex.values.sorted { $0.index < $1.index }
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
        presentationSnapshot: NativeLyricsPresentationSnapshot
    ) -> NativeLyricsVisualTarget {
        let visualCurrentIndex = visualCurrentIndex(
            for: row,
            configuration: configuration,
            presentationSnapshot: presentationSnapshot
        )
        let visualHotActiveIndices = visualCurrentIndex == presentationSnapshot.semanticIndex
            ? presentationSnapshot.hotActiveIndices
            : [visualCurrentIndex]
        return NativeLyricsVisualTarget.amllTarget(
            displayIndex: row.index,
            currentIndex: visualCurrentIndex,
            scrollTargetIndex: visualCurrentIndex,
            hotActiveIndices: visualHotActiveIndices,
            isManualScrolling: configuration.effectiveIsManualScrolling,
            interludeBlend: interludeBlend(for: row, configuration: configuration),
            gapRecedeBlend: gapRecedeBlend(for: row, configuration: configuration)
        )
    }

    private func visualCurrentIndex(
        for row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration,
        presentationSnapshot: NativeLyricsPresentationSnapshot
    ) -> Int {
        #if DEBUG
        // A/B seam: forces the pre-1e1ffbf behavior (visual demotion bound to the SEMANTIC line index
        // instead of the scroll wave's per-row targetIndex). Lets a headless test measure both handoff
        // behaviors in one build. Never set in production.
        if NativeLyricsSurfaceView.debugForceSemanticVisualIndex {
            return presentationSnapshot.semanticIndex
        }
        #endif
        guard configuration.playbackMode == .natural,
              !configuration.effectiveIsManualScrolling,
              configuration.interludeAfterIndex == nil,
              presentationEngine.isNaturalWaveActive else {
            return presentationSnapshot.semanticIndex
        }
        return presentationSnapshot.targetIndices[row.index] ?? presentationSnapshot.scrollTargetIndex
    }

    private func configurationForTextPhase(
        for row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration,
        presentationSnapshot: NativeLyricsPresentationSnapshot
    ) -> LyricsLayerRendererConfiguration {
        var textConfiguration = configuration
        // The ACTIVE-text PHASE (karaoke sweep, translation reveal, active/dim decision) follows the
        // SEMANTIC singing line — NOT the scroll wave's per-row visual target. Binding phase to the
        // wave (1e1ffbf) suppressed the singing line's sweep for the whole wave duration (A/B proof:
        // singing-line translation absent 1258/1258 frames wave-bound vs 3/1258 semantic). POSITION /
        // movement still follows the wave via visualTarget; only the phase input is decoupled here.
        textConfiguration.nativeTextActiveIndex = presentationSnapshot.semanticIndex
        return textConfiguration
    }

    private func shouldDriveTextPhase(
        row: LayerBackedLyricRow,
        textConfiguration: LyricsLayerRendererConfiguration,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) -> Bool {
        row.index == textConfiguration.effectiveTextActiveIndex
            && textConfiguration.effectiveTextActiveIndex == runtimeConfiguration.effectiveCurrentIndex
    }

    private func updateTextActivation(
        for row: LayerBackedLyricRow,
        textConfiguration: LyricsLayerRendererConfiguration,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        let isActive = row.index == textConfiguration.effectiveTextActiveIndex
            && textConfiguration.musicController.isPlaying
        let wasActive = textActiveByRowIndex[row.index] ?? false
        textActiveByRowIndex[row.index] = isActive
        guard wasActive != isActive else { return }
        if wasActive && !isActive {
            beginDeferredDeactivation(index: row.index, runtimeConfiguration: runtimeConfiguration)
        }
        if isActive {
            lastConfiguredTextPhaseIndex = row.index
        }
    }

    private func updateParkedTextPhaseFreeze(
        for row: LayerBackedLyricRow,
        textConfiguration: LyricsLayerRendererConfiguration,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        guard let rowID = rowIDByIndex[row.index],
              let view = rowViews[rowID] else {
            return
        }
        let isParkedFinishedLine = row.index == textConfiguration.effectiveTextActiveIndex
            && textConfiguration.effectiveTextActiveIndex != runtimeConfiguration.effectiveCurrentIndex
            && textConfiguration.musicController.isPlaying
        if isParkedFinishedLine {
            view.freezeParkedTextPhaseOpacity()
        } else if row.index != deferredDeactivationIndex {
            view.clearParkedTextPhaseOpacity()
        }
    }

    private func refreshTextActivation(
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        let visibleRows = visibleRows(for: runtimeConfiguration)
        let liveIndices = Set(runtimeConfiguration.rows.map(\.index))
        textActiveByRowIndex = textActiveByRowIndex.filter { liveIndices.contains($0.key) }
        let presentationSnapshot = nativePresentationSnapshot(
            lineIndices: visibleRows.map(\.index),
            configuration: runtimeConfiguration
        )
        for row in visibleRows {
            let rowTextConfiguration = configurationForTextPhase(
                for: row,
                configuration: runtimeConfiguration,
                presentationSnapshot: presentationSnapshot
            )
            updateTextActivation(
                for: row,
                textConfiguration: rowTextConfiguration,
                runtimeConfiguration: runtimeConfiguration
            )
            updateParkedTextPhaseFreeze(
                for: row,
                textConfiguration: rowTextConfiguration,
                runtimeConfiguration: runtimeConfiguration
            )
        }
    }

    private func interludeBlend(
        for row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> CGFloat {
        guard configuration.interludeAfterIndex == row.index, let interlude = row.interlude else {
            return 0
        }
        return NativeLyricsDotPhasePlan.interludeBlend(
            startTime: interlude.startTime,
            endTime: interlude.endTime,
            currentTime: configuration.phaseRenderTime()
        )
    }

    /// Ordinary-gap fold (defect 2): once this row's line is sung out and the post-line
    /// remnant faded, it relaxes into the inactive form IN PLACE (no blur — distinct from
    /// the interlude fold, where the dots take the centre and the row becomes a dist-1
    /// past line). Computed for every row but only CONSUMED by amllTarget's hot branch;
    /// past rows' nonzero values are inert.
    private func gapRecedeBlend(
        for row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration
    ) -> CGFloat {
        guard configuration.interludeAfterIndex != row.index, !row.isPrelude else { return 0 }
        let line = row.displayLine.line
        let lineEnd = max(line.endTime, line.words.last?.endTime ?? 0)
        return NativeLyricsDotPhasePlan.gapRecedeBlend(
            lineEndTime: lineEnd,
            currentTime: configuration.phaseRenderTime()
        )
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

    private struct NativeLyricsFrameRowSnapshot {
        let requestedY: CGFloat
        let y: CGFloat
        let height: CGFloat
        let visual: NativeLyricsVisualMotionState
        let snap: Bool
        let engineBacked: Bool
    }

    private struct NativeLyricsFrameRenderSnapshot {
        let rowsByIndex: [Int: NativeLyricsFrameRowSnapshot]
    }

    private func nativeFrameRenderSnapshot(
        rows: [LayerBackedLyricRow],
        configuration: LyricsLayerRendererConfiguration,
        snap: Bool
    ) -> NativeLyricsFrameRenderSnapshot {
        var rowsByIndex: [Int: NativeLyricsFrameRowSnapshot] = [:]
        let presentationSnapshot = nativePresentationSnapshot(
            lineIndices: rows.map(\.index),
            configuration: configuration
        )
        for row in rows {
            let engineState = snap ? nil : presentationEngine.presentation(for: row.index)
            let baseY = NativeLyricsSnapMath.renderY(
                snap: snap,
                engineY: engineState?.y,
                snappedY: presentationSnapshot.targetMinYByIndex[row.index]
                    ?? snapY(for: row, configuration: configuration)
            )
            let requestedY = baseY + configuration.effectiveManualOffset
            var y = requestedY
            // Teleport guard: a settled row must never jump a large distance for a single
            // tick in natural mode, whatever upstream produced the value (engine entry
            // momentarily missing → snapY fallback, or a configure carrying mid-update
            // heights). Step toward the new value instead; real springs converge well
            // under the cap, glitch spikes get absorbed and self-correct next tick.
            if !snap, let previous = lastAppliedYByIndex[row.index] {
                let delta = requestedY - previous
                if abs(delta) > Self.naturalModeMaxYStepPerTick {
                    y = previous + Self.naturalModeMaxYStepPerTick * (delta > 0 ? 1 : -1)
                    #if LOCAL_DEVELOPER_BUILD
                    noteTeleportClamp(
                        rowID: row.id,
                        rowIndex: row.index,
                        requestedY: requestedY,
                        previousY: previous,
                        engineBacked: engineState != nil
                    )
                    #endif
                }
            }
            lastAppliedYByIndex[row.index] = y
            let visual: NativeLyricsVisualMotionState
            if let state = visualStates[row.index] {
                visual = state
            } else {
                let fallbackTarget = visualTarget(
                    for: row,
                    configuration: configuration,
                    presentationSnapshot: presentationSnapshot
                )
                visual = NativeLyricsVisualMotionState(target: fallbackTarget)
            }
            let fallbackHeight = rowViews[row.id].map { max(1, $0.frame.height) } ?? 1
            let height = measuredHeightsByIndex[row.index] ?? fallbackHeight
            rowsByIndex[row.index] = NativeLyricsFrameRowSnapshot(
                requestedY: requestedY,
                y: y,
                height: height,
                visual: visual,
                snap: snap,
                engineBacked: snap || engineState != nil
            )
        }
        return NativeLyricsFrameRenderSnapshot(rowsByIndex: rowsByIndex)
    }

    /// lyricRenderTime (the clock the renderer reads) may step BACKWARD by up to the clock's own
    /// non-seek window when a poll resync corrects interpolation overshoot. MusicController treats a
    /// backward jump as a real seek only above ~2s (it hard-syncs there); anything below is resync
    /// jitter the clock silently applies. A non-explicit backward index move within THIS window is
    /// therefore jitter, not a seek — the renderer holds the active line instead of snapping back to a
    /// just-demoted one (the dim→bright revert guard). This must match the clock's 2s seek threshold,
    /// NOT the interpolateTime 0.5s currentTime allowance (which governs a different, forward-only
    /// lyric path); the old 0.5s value let 0.5–2s poll overshoots — increasingly common as drift
    /// accumulates over a long track — escape the hold and re-light the just-passed line.
    static let resyncRewindTolerance: TimeInterval = 2.0

    private func applyFrame(
        for row: LayerBackedLyricRow,
        view: NativeLyricsRowView,
        configuration: LyricsLayerRendererConfiguration,
        renderSnapshot: NativeLyricsFrameRenderSnapshot
    ) {
        guard let rowSnapshot = renderSnapshot.rowsByIndex[row.index] else { return }
        let y = rowSnapshot.y
        let visual = rowSnapshot.visual
        let height = rowSnapshot.height
        // Position the row by its FRAME origin (AppKit preserves it across the commit), not a layer
        // transform translation (which AppKit resets to the origin on every commit = the bloom).
        let frame = CGRect(x: 0, y: y, width: configuration.rowWidth, height: max(1, height))

        if view.frame != frame {
            view.frame = frame
        }
        let appliedOpacity = initialMeasurementsPending ? 0 : Float(visual.opacity)
        // Row Y is carried by the view FRAME (set above), which AppKit preserves across the commit;
        // the old per-row "unpositioned" hide existed only because the previous transform-based Y was
        // reset to the origin by AppKit on every commit, so a just-mounted row briefly painted at the
        // top. Frame positioning removes that origin state entirely, so the hide is no longer needed.
        view.setRowOpacity(appliedOpacity, dimBaseBrightness: Float(visual.target.dimBaseBrightness))
        // The transform now carries ONLY scale — never translation. (Translation here was the bug:
        // AppKit's commit-time layout resets a layer-backed view's transform to identity, dropping the
        // row to the origin for a frame; the frame does not get reset.)
        view.setPositioning(CGAffineTransform(scaleX: visual.scale, y: visual.scale))
        let appliedTransform = view.layer?.affineTransform() ?? .identity
        let appliedScale = sqrt(appliedTransform.a * appliedTransform.a + appliedTransform.c * appliedTransform.c)
        recordRowFrameParityIfChanged(rowID: row.id, sample: NativeLyricsRowFrameParitySample(
            expectedY: y,
            appliedY: view.frame.origin.y,
            expectedHeight: frame.height,
            appliedHeight: view.frame.height,
            expectedScale: visual.scale,
            appliedScale: appliedScale
        ))
        let appliedBlur = view.applyBlurRadius(visual.blur)
        view.applyRasterizationPolicy(isSettled: visual.isSettled, isActive: visual.target.isActive)
        #if DEBUG
        if debugCensusEnabled {
            var track = debugCensusByIndex[row.index] ?? DebugCensusTrack()
            track.opacity.append(visual.opacity)
            track.target.append(visual.target.opacity)
            track.scale.append(visual.scale)
            track.blur.append(appliedBlur)
            track.y.append(y)
            track.bright.append(CGFloat(view.debugMainBrightOpacity))
            track.transBright.append(CGFloat(view.debugTranslationBrightOpacity))
            track.transExpected.append(view.debugLastTranslationExpectedProgress ?? -1)
            track.transApplied.append(view.debugLastTranslationAppliedProgress ?? -1)
            debugCensusByIndex[row.index] = track
        }
        #endif
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
            y: rowSnapshot.requestedY,
            opacity: visual.opacity,
            blur: appliedBlur,
            scale: visual.scale,
            snap: rowSnapshot.snap,
            engineBacked: rowSnapshot.engineBacked
        )
        #endif
    }

    /// Last y actually applied per display index (release builds too — feeds the teleport guard).
    /// Preserved across row unmount/remount and cleared on track-identity reset.
    private var lastAppliedYByIndex: [Int: CGFloat] = [:]

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
            semanticIndex: configuration.effectiveCurrentIndex,
            scrollTargetIndex: configuration.effectiveScrollTargetIndex,
            hotActiveIndices: configuration.nativeHotActiveIndices,
            bufferedActiveIndices: configuration.nativeBufferedActiveIndices,
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
            #if DEBUG
            if self.debugCensusEnabled {
                self.debugSemanticTrace.append(self.nativeSemanticCurrentIndex ?? -1)
                self.debugClockTrace.append(self.nativeRenderClock ?? -1)
            }
            #endif
            let rowsToApply = self.rowViews.values.compactMap(\.currentRow)
            let renderSnapshot = self.nativeFrameRenderSnapshot(
                rows: rowsToApply,
                configuration: runtimeConfiguration,
                snap: snap
            )
            for view in self.rowViews.values {
                guard let row = view.currentRow else { continue }
                self.applyFrame(
                    for: row,
                    view: view,
                    configuration: runtimeConfiguration,
                    renderSnapshot: renderSnapshot
                )
            }
            self.updateSurfaceInterludeDots(configuration: runtimeConfiguration, snap: snap)
            // Rows just moved — re-resolve hover so it follows the geometry under a stationary cursor.
            self.reresolveHoverAfterLayout()
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
        guard DebugConfig.probeSinksEnabled, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_census.log") else { return }
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
        #if LOCAL_DEVELOPER_BUILD
        // Restart-storm diagnosis: pair with "LoopStop" lines; the caller frames name
        // who keeps resurrecting the loop on a paused panel.
        DebugLogger.log("LoopStart", Thread.callStackSymbols.dropFirst(2).prefix(3).joined(separator: " | "))
        #endif
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
    private func stopPresentationLoopIfIdle(runtimeConfiguration: LyricsLayerRendererConfiguration) {
        let snapMode = frameSnapMode(for: runtimeConfiguration)
        let vetoes = NativeLyricsLoopIdleDecision.vetoes(
            keepsAppearWindowAlive: snapMode.keepsPresentationLoopAlive,
            hasPendingTapSettle: pendingTapToLineSettleTiming != nil,
            hasEngineMotion: presentationEngine.hasActiveMotion,
            hasVisualMotion: hasActiveVisualMotion,
            hasActiveTextAnimation: hasActiveTextAnimation(configuration: runtimeConfiguration),
            hasInterlude: runtimeConfiguration.interludeAfterIndex != nil,
            hasDeferredDeactivation: deferredDeactivationIndex != nil,
            isPlaying: runtimeConfiguration.musicController.isPlaying
        )
        guard vetoes.isEmpty else {
            #if LOCAL_DEVELOPER_BUILD
            let now = CACurrentMediaTime()
            if now - lastLoopStopVetoLog > 2 {
                lastLoopStopVetoLog = now
                DebugLogger.log("LoopStopVeto", "\(vetoes.joined(separator: ",")) isPlaying=\(runtimeConfiguration.musicController.isPlaying) deferred=\(deferredDeactivationIndex.map(String.init) ?? "nil") cur=\(runtimeConfiguration.effectiveCurrentIndex)")
            }
            #endif
            return
        }
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
        #if LOCAL_DEVELOPER_BUILD
        DebugLogger.log("LoopStop", "presentation loop stopped")
        #endif
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
        let snapMode = frameSnapMode(for: runtimeConfiguration, now: now)
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
        let motionChanged = presentationEngine.advance(delta: delta)
        let visualTargetsChanged = shouldSyncVisualTargetsOnPresentationTick(
            semanticChanged: semanticChanged,
            runtimeConfiguration: runtimeConfiguration
        )
            ? syncVisualTargets(runtimeConfiguration: runtimeConfiguration, snap: false)
            : false
        let visualMotionChanged = advanceVisualStates(delta: delta)
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
                if lag > 0.25, DebugConfig.probeSinksEnabled, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_sync.log") {
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
            || snapMode.keepsPresentationLoopAlive
        manualPresentationNeedsApply = false
        withDisabledLayerActions {
            refreshTextActivation(runtimeConfiguration: runtimeConfiguration)
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
        if now < bloomPresentationDiagUntil, DebugConfig.probeSinksEnabled, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_bloom.log") {
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
           DebugConfig.probeSinksEnabled,
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
            let y = lastAppliedYByIndex[row.index] ?? 0
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

    private func beginDeferredDeactivation(
        index: Int,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        if let oldDeferred = deferredDeactivationIndex, oldDeferred != index {
            forceFinalizeDeactivation(index: oldDeferred, runtimeConfiguration: runtimeConfiguration)
        }
        guard deferredDeactivationIndex != index else { return }
        deferredDeactivationIndex = index
        if let id = rowIDByIndex[index] {
            rowViews[id]?.beginDeactivationFade()
        }
    }

    private func forceFinalizeDeactivation(index: Int, runtimeConfiguration: LyricsLayerRendererConfiguration) {
        deferredDeactivationIndex = nil
        guard let row = runtimeConfiguration.rows.first(where: { $0.index == index }),
              let view = rowViews[row.id] else { return }
        _ = updateContentIfNeeded(
            view: view,
            row: row,
            configuration: runtimeConfiguration,
            updatesPlaybackPhase: false
        )
        view.finalizeDeactivationState(renderTime: runtimeConfiguration.phaseRenderTime())
    }

    private func finalizeDeferredDeactivation(runtimeConfiguration: LyricsLayerRendererConfiguration) {
        guard let idx = deferredDeactivationIndex else { return }
        if NativeLyricsLoopIdleDecision.shouldCancelDeferredDeactivation(
            deferredIndex: idx,
            currentIndex: runtimeConfiguration.effectiveCurrentIndex
        ) {
            // The row is current again (pause-mid-handoff revert): hand it back to
            // normal activation — finalizing would strip the active overlay;
            // waiting would veto the loop stop forever. endDeactivationFade
            // restores the resting overlay opacity updatePlaybackPhase assumes.
            deferredDeactivationIndex = nil
            if let id = rowIDByIndex[idx] {
                rowViews[id]?.endDeactivationFade()
            }
            return
        }
        if let state = visualStates[idx] {
            guard state.opacity < 0.38 else { return }
        }
        deferredDeactivationIndex = nil
        guard let row = runtimeConfiguration.rows.first(where: { $0.index == idx }),
              let view = rowViews[row.id] else { return }
        _ = updateContentIfNeeded(
            view: view,
            row: row,
            configuration: runtimeConfiguration,
            updatesPlaybackPhase: false
        )
        view.finalizeDeactivationState(renderTime: runtimeConfiguration.phaseRenderTime())
    }

    private func shouldSyncVisualTargetsOnPresentationTick(
        semanticChanged: Bool,
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) -> Bool {
        semanticChanged
            || runtimeConfiguration.effectiveIsManualScrolling
            || runtimeConfiguration.interludeAfterIndex != nil
            || presentationEngine.isNaturalWaveActive
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
                return (row.index, rowHitFrame(view))
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
            let hoverFrame = rowHitFrame(view).insetBy(dx: 0, dy: -24)
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
        lastKnownCursorPoint = point
        updateNativeHover(from: point, configuration: runtimeConfiguration)
    }

    private func clearNativeHover() {
        lastKnownCursorPoint = nil
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
        let snapMode = frameSnapMode(for: runtimeConfiguration)
        _ = reconcileVisibleRowViews(
            runtimeConfiguration: runtimeConfiguration,
            snapPositions: snapMode.snapsPositions,
            snapVisuals: snapMode.snapsVisuals
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
        let snapMode = frameSnapMode(for: runtimeConfiguration)
        let visualTargetsChanged = reconcileVisibleRowViews(
            runtimeConfiguration: runtimeConfiguration,
            snapPositions: snapMode.snapsPositions,
            snapVisuals: snapMode.snapsVisuals
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
            let rows = visibleRows(for: runtimeConfiguration)
            for row in rows {
                guard let view = rowViews[row.id] else { continue }
                updateContentIfNeeded(view: view, row: row, configuration: runtimeConfiguration)
            }
            let renderSnapshot = nativeFrameRenderSnapshot(
                rows: rows,
                configuration: runtimeConfiguration,
                snap: false
            )
            for row in rows {
                guard let view = rowViews[row.id] else { continue }
                applyFrame(
                    for: row,
                    view: view,
                    configuration: runtimeConfiguration,
                    renderSnapshot: renderSnapshot
                )
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

    // ───────────────────────────────────────────────────────────────────────────
    // Pointer hit-testing uses the row's real on-screen FRAME. Rows are positioned by
    // frame origin (applyFrame sets view.frame; the layer transform carries scale ONLY),
    // so renderedY — which reads the transform ty — is ~0 for every row and must NOT be
    // used here. Reading ty made the geometry hover/click path resolve every row at y≈0,
    // i.e. dead: the app highlighted only via the per-row tracking areas, which is why the
    // hover background could stick when a row slid out from under a stationary cursor.
    // ───────────────────────────────────────────────────────────────────────────
    private func rowHitFrame(_ view: NativeLyricsRowView) -> CGRect { view.frame }

    private func updateNativeHover(from point: CGPoint, configuration: LyricsLayerRendererConfiguration) {
        let hoveredIndex = visibleRows(for: configuration)
            .compactMap { row -> (Int, CGRect)? in
                guard let view = rowViews[row.id] else { return nil }
                return (row.index, rowHitFrame(view))
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

    /// Re-resolve hover from the last cursor position after a layout pass repositioned the rows.
    /// Rows have no tracking areas of their own — the surface is the single hover authority — so a row
    /// sliding out from under a stationary cursor (line-advance / scroll moves the frame, not the mouse)
    /// gets no mouseExited. Re-running the geometry hit-test here makes hover follow the geometry: the
    /// vacated row releases its background, the row now under the cursor lights up. No-op when the cursor
    /// is outside the surface / over a reserved zone (lastKnownCursorPoint == nil), so idle playback with
    /// no hover pays nothing.
    private func reresolveHoverAfterLayout() {
        guard let point = lastKnownCursorPoint, let configuration else { return }
        updateNativeHover(from: point, configuration: runtimeConfiguration(from: configuration))
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
        // display-link uses (syncVisualTargets + refreshTextActivation +
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
        let snapMode = frameSnapMode(for: configuration)
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
            playbackMode: snapMode.playbackMode
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
            self.isCurrent = row.index == configuration.effectiveTextActiveIndex
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
                && row.index == configuration.effectiveTextActiveIndex
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

    func recordHoverBackgroundParity(_ sample: NativeLyricsHoverParitySample) {
        renderTelemetry.recordHoverParity(sample)
    }

    func recordDotPhase(_ sample: NativeLyricsDotPhaseSample) {
        renderTelemetry.recordDotPhase(sample)
    }

    func recordTextPhase(_ sample: NativeLyricsTextPhaseSample) {
        renderTelemetry.recordTextPhase(sample)
    }

    private func updateTextPhasesForCurrentConfiguration(
        runtimeConfiguration: LyricsLayerRendererConfiguration
    ) {
        let visibleRows = visibleRows(for: runtimeConfiguration)
        let presentationSnapshot = nativePresentationSnapshot(
            lineIndices: visibleRows.map(\.index),
            configuration: runtimeConfiguration
        )
        guard let (row, view, textConfiguration) = activeTextPhaseRow(
            for: runtimeConfiguration,
            visibleRowList: visibleRows,
            presentationSnapshot: presentationSnapshot
        ) else { return }
        guard shouldDriveTextPhase(
            row: row,
            textConfiguration: textConfiguration,
            runtimeConfiguration: runtimeConfiguration
        ) else { return }
        // updatePlaybackPhase decides per-word (syllable) sweep vs whole-line sweep from the
        // bright text-layer's BOUNDS. When a row becomes text-active, updateContentIfNeeded may
        // have just changed this row's content (needsLayout), and AppKit lays text sublayers out
        // ASYNCHRONOUSLY — so without forcing layout here we read .zero/stale bounds, geometryReady
        // comes out false, and the row degrades to line-level (the random "时不时逐字、时不时逐行"
        // toggle). Force the active row's layout BEFORE reading its geometry for the phase — same
        // ordering fix as the reconcile path.
        if view.frame.size != .zero {
            view.layoutSubtreeIfNeeded()
        }
        guard let textSample = view.updatePlaybackPhase(configuration: textConfiguration, managesTransaction: false) else {
            return
        }
        renderTelemetry.recordTextPhase(textSample)
    }

    private func activeTextPhaseRow(
        for configuration: LyricsLayerRendererConfiguration,
        visibleRowList: [LayerBackedLyricRow]? = nil,
        presentationSnapshot: NativeLyricsPresentationSnapshot? = nil
    ) -> (LayerBackedLyricRow, NativeLyricsRowView, LyricsLayerRendererConfiguration)? {
        let rows = visibleRowList ?? visibleRows(for: configuration)
        let snapshot = presentationSnapshot ?? nativePresentationSnapshot(
            lineIndices: rows.map(\.index),
            configuration: configuration
        )
        var fallback: (LayerBackedLyricRow, NativeLyricsRowView, LyricsLayerRendererConfiguration)?
        for row in rows {
            let rowTextConfiguration = configurationForTextPhase(
                for: row,
                configuration: configuration,
                presentationSnapshot: snapshot
            )
            guard row.index == rowTextConfiguration.effectiveTextActiveIndex,
                  let rowID = rowIDByIndex[row.index],
                  let view = rowViews[rowID],
                  view.currentRow?.index == row.index else {
                continue
            }
            let candidate = (row, view, rowTextConfiguration)
            if shouldDriveTextPhase(row: row, textConfiguration: rowTextConfiguration, runtimeConfiguration: configuration) {
                return candidate
            }
            if fallback == nil {
                fallback = candidate
            }
        }
        return fallback
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
        let activeTuple = activeTextPhaseRow(for: configuration)
        if let (row, _, textConfiguration) = activeTuple,
           !shouldDriveTextPhase(row: row, textConfiguration: textConfiguration, runtimeConfiguration: configuration) {
            return false
        }
        guard let activeRow = activeTuple?.0
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
