import AppKit
import CoreImage
import QuartzCore

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
    private var appliedBlurRadius: CGFloat = -.greatestFiniteMagnitude
    private var appliedDotBlurRadius: CGFloat = -.greatestFiniteMagnitude
    private var rasterizationEligible = false
    private var lastHoverBackgroundVisible = false
    private var lastAppliedHoverFrame: CGRect?
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

    func configure(
        row: LayerBackedLyricRow,
        configuration: LyricsLayerRendererConfiguration,
        updatesPlaybackPhase: Bool = true
    ) {
        // The monotone post-line fade floor belongs to ONE line. Reset it only when this row actually
        // takes a different line (a genuine discontinuity) — never per frame, so a backward clock
        // jitter on the SAME line can't re-light the just-faded overlay (the gap pop).
        if self.row?.displayLine.id != row.displayLine.id {
            mainPostLineFadeFloor = 1
            translationPostLineFadeFloor = 1
        }
        self.row = row
        self.configuration = configuration
        wantsLayer = true
        updateTextLayers(
            textWidth: contentTextWidth(configuration),
            updatesPlaybackPhase: updatesPlaybackPhase
        )
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
    private var parkedMainBrightOpacity: Float?
    private var parkedTranslationBrightOpacity: Float?

    // ───────────────────────────────────────────────────────────────────────────
    // Monotonic post-line karaoke fade floor. postLineFadeOut is a pure function of
    // (rawClock - lineEndTime), and updatePlaybackPhase reads the RAW lyricRenderTime,
    // so a drift-driven backward poll resync shrinks timeSinceLineEnd and RAISES the
    // fade — re-lighting a just-finished line's overlay mid-gap (the previous-line pop).
    // The floor pins the fade monotone: once it has dimmed it never brightens again,
    // until the clock is genuinely back inside the line's sung window (fade == 1).
    // ───────────────────────────────────────────────────────────────────────────
    private var mainPostLineFadeFloor: CGFloat = 1
    private var translationPostLineFadeFloor: CGFloat = 1

    func freezeParkedTextPhaseOpacity() {
        if parkedMainBrightOpacity == nil {
            parkedMainBrightOpacity = mainBrightTextLayer.isHidden ? 0 : mainBrightTextLayer.opacity
        }
        if parkedTranslationBrightOpacity == nil {
            parkedTranslationBrightOpacity = translationBrightTextLayer.isHidden ? 0 : translationBrightTextLayer.opacity
        }
        if let parkedMainBrightOpacity {
            mainBrightTextLayer.opacity = parkedMainBrightOpacity
        }
        if let parkedTranslationBrightOpacity {
            translationBrightTextLayer.opacity = parkedTranslationBrightOpacity
        }
    }

    func clearParkedTextPhaseOpacity() {
        parkedMainBrightOpacity = nil
        parkedTranslationBrightOpacity = nil
    }

    func beginDeactivationFade() {
        mainDeactivationOverlayBaseline = parkedMainBrightOpacity
            ?? (mainBrightTextLayer.isHidden ? 0 : mainBrightTextLayer.opacity)
        translationDeactivationOverlayBaseline = parkedTranslationBrightOpacity
            ?? (translationBrightTextLayer.isHidden ? 0 : translationBrightTextLayer.opacity)
        clearParkedTextPhaseOpacity()
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
        clearParkedTextPhaseOpacity()
        // Restore the resting opacity. updateDeactivationFade scaled the bright overlays toward 0 as
        // the line receded; leaving them at that residual fraction made a still-mounted row relight
        // from the dim value when it was shown again (the "dim-then-relight"). 1 is the same resting
        // value prepareForReuse uses, and updatePlaybackPhase assumes it on re-activation.
        mainBrightTextLayer.opacity = 1
        translationBrightTextLayer.opacity = 1
    }

    func finalizeDeactivationState(renderTime: TimeInterval) {
        endDeactivationFade()
        clearSweepState()
        applyInactivePlaybackLayerState()
        if let row {
            updateDotsPhase(row: row, currentTime: renderTime)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        #if DEBUG
        debugPrepareForReuseCount += 1
        #endif
        row = nil
        configuration = nil
        isHovering = false
        onHoverChanged = nil
        onHoverBackgroundVisible = nil
        onTap = nil
        mainDeactivationOverlayBaseline = nil
        translationDeactivationOverlayBaseline = nil
        clearParkedTextPhaseOpacity()
        mainPostLineFadeFloor = 1
        translationPostLineFadeFloor = 1
        // Clear the scale/position transform too. layout() re-asserts positioningTransform on every
        // commit; if a recycled row keeps the previous row's scale, the next mount flashes that old
        // size for one frame before applyFrame writes the new scale (the seek size-pop).
        setPositioning(.identity)
        layer?.opacity = 0
        backgroundLayer.isHidden = true
        lastHoverBackgroundVisible = false
        lastAppliedHoverFrame = nil
        layer?.filters = nil
        appliedBlurRadius = -.greatestFiniteMagnitude
        rasterizationEligible = false
        refreshRasterization()
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
        // The base-layer opacity reset below (opacity = 1) is only safe because the
        // compensation flags reset with it — a recycled row must start uncompensated.
        mainDimCompensationActive = false
        translationDimCompensationActive = false
        lastDimBaseTier = 0.35
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
            refreshRasterization()
            return quantizedRadius
        }
        // A FRESH CIFilter per radius change is load-bearing, not waste: Core Animation
        // treats a filter attached to a layer as immutable — mutating the attached instance
        // and reassigning the same object can be silently ignored by the render server, so
        // rows keep their mount-time blur forever (user-visible: blur deepens as the song
        // scrolls on until the centered lyrics are unreadable). Filters cannot be verified
        // headlessly (only the render server applies them); do not "optimize" this back to
        // a reused instance.
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(Double(quantizedRadius), forKey: kCIInputRadiusKey)
        layer?.filters = filter.map { [$0] }
        refreshRasterization()
        return quantizedRadius
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Blur economy (rasterization of settled blurred rows)
    //
    // A resident CIGaussianBlur is re-evaluated by the compositor on EVERY recomposite of
    // the surface — during the active line's karaoke sweep, every static blurred row bills
    // WindowServer per frame (measured +38 CPU points on M1). Rasterizing a settled,
    // non-active, blurred row caches its blurred bitmap in the render server; recomposite
    // becomes a texture blit. Frame-origin moves do NOT invalidate the cache, so rasterized
    // rows stay cheap while translating during scroll. The renderer supplies the motion
    // verdict (only it sees the visual motion state); the row vetoes while a repeating dot
    // animation is live in its subtree (each animation frame would invalidate the cache,
    // which costs more than the live filter).
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // Temporary same-build A/B switch for the WindowServer measurement; remove after acceptance.
    private static let rasterizationDisabledByEnv =
        ProcessInfo.processInfo.environment["NANOPOD_BLUR_RASTER_OFF"] != nil

    func applyRasterizationPolicy(isSettled: Bool, isActive: Bool) {
        rasterizationEligible = isSettled && !isActive
        refreshRasterization()
    }

    private var hasLiveDotAnimation: Bool {
        !translationLoadingDotContainerLayer.isHidden || !dotContainerLayer.isHidden
    }

    private func refreshRasterization() {
        let desired = rasterizationEligible
            && appliedBlurRadius > 0.001
            && !hasLiveDotAnimation
            && !Self.rasterizationDisabledByEnv
        guard let layer, layer.shouldRasterize != desired else { return }
        if desired {
            // Same contentsScale convention as commonInit; without it the cache renders at 1x.
            layer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
        }
        layer.shouldRasterize = desired
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

    /// True when the hover background is actually painted for this row. Tests assert it clears once
    /// the row is no longer under the cursor (the "hover bg stuck after the row moved away" bug).
    var debugHoverBackgroundVisible: Bool { isHovering && !backgroundLayer.isHidden }

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

    /// True when the translation carries a karaoke sweep (bright overlay has text to reveal).
    /// LINE-LEVEL songs must keep this false: they have no word timeline, so a "sweep" there
    /// degrades into the whole-block gradient wipe (contract core rule 3 violation, regression
    /// history cfb5308 → cfc152c fix → 7653221 bare revert).
    var debugTranslationSweepEngaged: Bool { translationBrightTextLayer.string != nil }

    var debugTranslationTextLayerHidden: Bool { translationTextLayer.isHidden }

    /// Animation keys attached to the translation base layer. Implicit-action leaks show up
    /// here as property-name keys ("position", "bounds", ...) that no renderer code ever adds.
    var debugTranslationTextLayerAnimationKeys: [String] { translationTextLayer.animationKeys() ?? [] }

    var debugPreludeDotCenterYInSuperview: CGFloat {
        frame.minY + dotContainerLayer.position.y
    }
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

    /// Dim-base continuity channels (NativeLyricsDimBaseContinuityTests). The effective
    /// on-screen dim brightness is the PRODUCT rowOpacity × baseLayerOpacity × attrAlpha;
    /// the tests pin that product across handoff frames, so each factor is exposed.
    var debugMainBaseLayerOpacity: Float { mainTextLayer.opacity }
    var debugMainBaseAttrAlpha: CGFloat { Self.firstRunForegroundAlpha(mainTextLayer) }
    var debugTranslationBaseLayerOpacity: Float { translationTextLayer.opacity }
    var debugTranslationBaseAttrAlpha: CGFloat { Self.firstRunForegroundAlpha(translationTextLayer) }

    private static func firstRunForegroundAlpha(_ layer: CATextLayer) -> CGFloat {
        guard let attributed = layer.string as? NSAttributedString, attributed.length > 0,
              let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        else { return 1 }
        return color.alphaComponent
    }

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
    private(set) var debugPlaybackPhaseUpdateCount = 0
    // Active-line translation sweep truth captured on the last updatePlaybackPhase. `expected` is
    // what the model wants (partial mid-line), `applied` is what the renderer actually clipped to,
    // `brightOverlayPresent` is whether the sung overlay layer is even carrying text. A word-synced
    // active line that renders "fully bright instantly" shows up here as overlay absent OR applied==1.
    private(set) var debugLastTranslationExpectedProgress: CGFloat?
    private(set) var debugLastTranslationAppliedProgress: CGFloat?
    private(set) var debugLastTranslationBrightOverlayPresent = false
    /// The translation sung-overlay opacity (mirrors debugMainBrightOpacity). The deactivation fade
    /// scales it toward 0 as a line recedes; a teardown that forgets to restore it to 1 makes a
    /// re-shown row relight from the residual fraction. The reuse-state test reads it.
    var debugTranslationBrightOpacity: Float { translationBrightTextLayer.isHidden ? 0 : translationBrightTextLayer.opacity }
    #endif


    // The row's on-screen position lives in a manual layer transform (not the view frame, so a
    // pure position change never triggers a text re-measure). AppKit's layout pass resets a
    // layer-backed view's transform to identity — proven by NativeLyricsRevealGateTests — which
    // snaps the row to the top for one frame (the load-correlated 花屏: more layout passes under
    // high CPU → more resets). Store the intended transform and re-assert it on every layout.
    private(set) var positioningTransform: CGAffineTransform = .identity
    /// Counts REAL per-frame layer mutations (transform + row opacity). A SETTLED row that keeps
    /// re-writing its layer every frame forces a re-composite — and with a CIGaussianBlur filter
    /// attached to a past line, that per-frame re-composite is the "refresh flicker". The headless
    /// NativeLyricsRenderChurnTests pins this to 0 across steady frames.
    private(set) var layerMutationCount = 0
    /// Per-frame write ATTEMPTS (before the redundancy guard). attempts >> count on steady frames is
    /// the reproduction: the render path re-writes every frame; the guard is what stops the re-composite.
    private(set) var layerMutationAttempts = 0
    func setPositioning(_ transform: CGAffineTransform) {
        layerMutationAttempts += 1
        // Track the intended transform for layout()'s re-assertion regardless of whether we write now.
        positioningTransform = transform
        // Guard on the ACTUAL layer transform, NOT a tracked ivar. AppKit resets a layer-backed view's
        // transform to identity on its own layout/commit passes, desyncing the ivar from the layer. The
        // old ivar guard then skipped re-applying the scale after such a reset, so a settled previous
        // line's scale popped to 1.0 and stuck (the "scale pop"; NativeLyricsHandoffDesyncTests). Reading
        // the layer is cheap and keeps this churn-safe: an already-correct layer still skips the write.
        guard layer?.affineTransform() != transform else { return }
        layer?.setAffineTransform(transform)
        layerMutationCount += 1
    }
    func setRowOpacity(_ opacity: Float, dimBaseBrightness: Float) {
        layerMutationAttempts += 1
        lastDimBaseTier = dimBaseBrightness
        if layer?.opacity != opacity {
            layer?.opacity = opacity
            layerMutationCount += 1
        }
        applyDimBaseCompensation()
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Dim-base compensation (defect 3, second root cause — the brightness step).
    // The dim base of a sweeping row must read at the SAME effective brightness as
    // an inactive row (dimBaseBrightness, normally 0.35), while the ROW opacity
    // springs 0.35→1.0 through a handoff. Attributed alphas are state-independent
    // (baked at the inactive look), so the tier is expressed here: the base layers'
    // opacity is the tier divided by the current row opacity, re-derived on every
    // row-opacity write. At the activation frame (row opacity still 0.35) the
    // compensation is exactly 1 — identical to the inactive rendering — so the
    // product is continuous by construction and only the bright sweep moves.
    private var mainDimCompensationActive = false
    private var translationDimCompensationActive = false
    private var lastDimBaseTier: Float = 0.35

    private func applyDimBaseCompensation() {
        let rowOpacity = layer?.opacity ?? 1
        let compensated = min(1, lastDimBaseTier / max(rowOpacity, 0.001))
        let mainValue: Float = mainDimCompensationActive ? compensated : 1
        if mainTextLayer.opacity != mainValue {
            mainTextLayer.opacity = mainValue
            layerMutationCount += 1
        }
        let translationValue: Float = translationDimCompensationActive ? compensated : 1
        if translationTextLayer.opacity != translationValue {
            translationTextLayer.opacity = translationValue
            layerMutationCount += 1
        }
    }

    /// The effective dim alpha the compensated base currently renders at — the single
    /// source for sibling layers (emphasis glyphs) that must match the base's dim level.
    private func dimBaseEffectiveAlpha() -> CGFloat {
        CGFloat(mainTextLayer.opacity)
    }

    #if DEBUG
    /// The tracked positioning-transform scale (what setPositioning believes is applied). Tests compare
    /// this against the ACTUAL layer transform to catch a stale layer the churn guard refuses to correct.
    var debugPositioningScale: CGFloat {
        sqrt(positioningTransform.a * positioningTransform.a + positioningTransform.c * positioningTransform.c)
    }
    private(set) var debugPrepareForReuseCount = 0
    #endif

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
            y = NativeLyricsRowMeasurement.preludeDotContainerTopInset
            layoutDotContainer(frame: CGRect(
                x: textX,
                y: y,
                width: textWidth,
                height: NativeLyricsRowMeasurement.preludeDotContainerHeight
            ))
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

    // No per-row tracking area. The surface (NativeLyricsSurfaceView) is the SINGLE hover authority:
    // it hit-tests the cursor against each row's real frame and drives setPointerHovering. A per-row
    // tracking area could fire mouseEntered but not mouseExited when the row slid out from under a
    // stationary cursor (its frame moved, the mouse did not), so the hover background stuck. The surface
    // re-resolves hover on every layout pass instead, which tracks the geometry frame-by-frame.

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

    private func updateTextLayers(
        textWidth: CGFloat,
        updatesPlaybackPhase: Bool = true
    ) {
        guard let row, let configuration else { return }
        if row.isPrelude {
            mainDimCompensationActive = false
            translationDimCompensationActive = false
            applyDimBaseCompensation()
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
            if updatesPlaybackPhase {
                updatePlaybackPhase(configuration: configuration)
            }
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
        let isActive = row.index == configuration.effectiveTextActiveIndex && configuration.musicController.isPlaying
        let appliesMainSweep = isActive && row.displayLine.line.hasSyllableSync && !plan.wordRuns.isEmpty
        // The attributed alpha is STATE-INDEPENDENT (always the inactive look). The dim tier of a
        // sweeping row rides mainTextLayer.opacity via applyDimBaseCompensation, in lockstep with
        // the row-opacity spring — an instant alpha re-bake here multiplied against the mid-spring
        // row opacity was the handoff brightness dip (defect 3, second root cause).
        let mainAlpha: CGFloat = 1
        mainDimCompensationActive = appliesMainSweep
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
            // Sweep the translation ONLY for word-timed songs (match appliesMainSweep's gating).
            // A line-level song has no word timeline, so a "sweep" degrades into one gradient
            // mask wiping the whole translation block — contract core rule 3 violation. This
            // gate was fixed in cfc152c and lost to the bare revert 7653221; the revert's
            // actual suspect was the loop-idling half of that commit, which stays out.
            let appliesTranslationSweep = isActive && row.displayLine.line.hasSyllableSync
            // Same state-independent bake as the main text: the sweep dim tier is expressed via
            // translationTextLayer.opacity (applyDimBaseCompensation), never an alpha re-bake.
            let translationBaseAlpha = plan.constants.currentTranslationOpacityFactor
            translationDimCompensationActive = appliesTranslationSweep
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
            translationDimCompensationActive = false
            startTranslationLoadingDots()
            hideTranslationSweepMaskLayers()
        } else if configuration.showTranslation && isTranslationFailureVisible(row: row, configuration: configuration) {
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            translationDimCompensationActive = false
            hideTranslationLoadingDots()
            hideTranslationSweepMaskLayers()
        } else {
            translationTextLayer.string = nil
            translationBrightTextLayer.string = nil
            translationDimCompensationActive = false
            hideTranslationLoadingDots()
            hideTranslationSweepMaskLayers()
        }
        // Flags are final for this pass — bring the base layers' compensated opacity in line
        // with the CURRENT row opacity now, so a settled row (no setRowOpacity traffic) still
        // picks up an activation/deactivation the same frame it re-renders.
        applyDimBaseCompensation()
        interludeTextLayer.string = nil
        // Interlude dots are rendered by the surfaceInterludeDots OVERLAY (positioned at the gap
        // centre, tracks the manual-scroll offset). The per-row dotContainerLayer is ONLY for the
        // prelude (handled in the isPrelude early-return above). Leaving it visible for interlude
        // rows produced a SECOND, un-laid-out set of dots (collapsed at the row origin) that
        // overlapped the overlay during manual scroll. Keep it hidden here.
        dotContainerLayer.isHidden = true
        if updatesPlaybackPhase,
           let textSample = updatePlaybackPhase(configuration: configuration) {
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
        // Churn guard: the on-reposition re-resolution can call this every frame while a row stays
        // hovered. Writing the layer each time re-composites it (the render-churn class this session
        // killed). Skip the write when the value is unchanged — frame tracks bounds (constant), isHidden
        // only flips on a hover transition. cornerRadius is a constant set once in commonInit.
        let frame = Self.hoverBackgroundFrame(in: bounds)
        if lastAppliedHoverFrame != frame {
            backgroundLayer.frame = frame
            lastAppliedHoverFrame = frame
        }
        if lastHoverBackgroundVisible != visible {
            backgroundLayer.isHidden = !visible
        }
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
        #if DEBUG
        debugPlaybackPhaseUpdateCount += 1
        #endif
        // Phase timing MUST come from the shared monotonic clock (phaseRenderTime), never the raw
        // SB clock: a backward resync dip at line start collapses the active plan to progress 0
        // for a frame — the handoff style flash (docs/defect-recordings/2026-07-11).
        let renderTime = configuration.phaseRenderTime()
        let isActive = row.index == configuration.effectiveTextActiveIndex && configuration.musicController.isPlaying

        var sample: NativeLyricsTextPhaseSample?
        if managesTransaction {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        #if LOCAL_DEVELOPER_BUILD
        do {
            let hasTranslation = row.displayLine.line.translation != nil
            if DebugConfig.probeSinksEnabled, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_sweep.log") {
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
            #if DEBUG
            debugLastTranslationExpectedProgress = plan.translation?.progress
            debugLastTranslationAppliedProgress = appliedTranslation?.progress
            debugLastTranslationBrightOverlayPresent =
                !translationBrightTextLayer.isHidden && translationBrightTextLayer.string != nil
            #endif
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
            applyInactivePlaybackLayerState()
        }
        updateDotsPhase(row: row, currentTime: renderTime)
        if managesTransaction {
            CATransaction.commit()
        }
        return sample
    }

    private func applyInactivePlaybackLayerState() {
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
        // Pin the post-line fade monotone so a backward clock step can't re-light the overlay. The
        // floor only falls here; it is reset solely by the line-key / explicit-seek guard at the top.
        mainPostLineFadeFloor = min(mainPostLineFadeFloor, plan.mainPostLineFade)
        mainBrightTextLayer.opacity = Float(mainPostLineFadeFloor)
        mainBrightTextLayer.isHidden = plan.mainSweepProgress <= 0.001 || mainPostLineFadeFloor <= 0.001
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
        translationPostLineFadeFloor = min(translationPostLineFadeFloor, translation.postLineFade)
        translationBrightTextLayer.opacity = Float(translationPostLineFadeFloor)
        translationBrightTextLayer.isHidden = translation.progress <= 0.001 || translationPostLineFadeFloor <= 0.001
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
                if DebugConfig.probeSinksEnabled, let fh = FileHandle(forWritingAtPath: "/tmp/nanopod_sweep.log") {
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
                    // Emphasis glyphs are SIBLINGS of the compensated base (mainEmphasisLayer),
                    // so their dim endpoint must be fed the base's current effective alpha.
                    dimAlpha: dimBaseEffectiveAlpha(),
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
            alpha: 1,
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
            alpha: 1
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
        // Dim glyph copies live INSIDE mainTextLayer and inherit its compensated opacity —
        // bake them at full alpha, exactly like the whole-line base string they stand in for.
        let dimColor = NSColor.white.withAlphaComponent(1).cgColor
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
        refreshRasterization()
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
        refreshRasterization()
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
        refreshRasterization()
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
        // Fresh instance per change — attached filters are immutable to CA; see applyBlurRadius.
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(Double(quantizedRadius), forKey: kCIInputRadiusKey)
        dotContainerLayer.filters = filter.map { [$0] }
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
        refreshRasterization()
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
            currentTime: currentTime ?? configuration.phaseRenderTime(),
            isActive: row.index == configuration.effectiveTextActiveIndex && configuration.musicController.isPlaying,
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
