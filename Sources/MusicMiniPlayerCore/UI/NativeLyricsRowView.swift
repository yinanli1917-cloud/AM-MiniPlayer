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
    // Restore source for the whole-line base+bright strings: the active
    // word-cascade nils the layer strings (per-word glyphs carry the base),
    // and every path that leaves the cascade must be able to put them back —
    // a hide path without a restore rendered a fully blank row (2026-07-19).
    private var wholeLineMainString: NSAttributedString?
    private var wholeLineBrightString: NSAttributedString?
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
    // Sweep-ghost fix (2026-09-12): mirrors activeHiddenEmphasisSignature but tracks which
    // NON-emphasis word orders are currently blanked out of the whole-line dim base because
    // they are floating (see applyFloatingHiddenBase / applyMainWordFloatGlyphLayers).
    private var activeFloatingHiddenSignature: String?
    // v2.8 per-word cascade: non-emphasis words render as per-glyph layers so each WORD can float by
    // its own baseFloatY (rolling rise), while brightness still comes from the shared sweep mask. The
    // dim glyphs parent to mainTextLayer (always visible), the bright glyphs to mainBrightTextLayer
    // (masked by the sweep — so a 2pt float never disturbs the horizontal wavefront).
    private var mainDimWordGlyphLayers: [CATextLayer] = []
    private var mainBrightWordGlyphLayers: [CATextLayer] = []
    private var mainWordGlyphLayerSignatures: [EmphasisGlyphLayerSignature?] = []
    // feel/emphasis v28/amll arms (2026-09-17): index-aligned with mainBrightWordGlyphLayers.
    // `amll` mounts a pre-rendered (offline, non-resident) blurred-bitmap sibling directly below
    // the matching bright tile for a glyph currently inside its emphasis glow window; its
    // position/transform are copied from that SAME bright tile at the same call site
    // (applyMainWordFloatGlyphLayers), so it can never be independently wrong. `current`/`v28`
    // never populate this pool.
    private var mainEmphasisGlowLayers: [CALayer] = []
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
    /// Top padding before the main lyric text starts — `layout()`'s `mainTextLayer.frame.minY`.
    /// Named (was a bare `8` literal) so `verticalScalePivotY` below can share the exact same
    /// value layout() actually uses, instead of risking the two drifting apart.
    private static let mainTextTopInset: CGFloat = 8
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
        let brightAlpha: CGFloat
        // 2026-09-20 (3p): the resolved font NAME is part of the signature — when it changes
        // (a different character resolves to a different concrete font, or the shared layout
        // rebuilds), the tile must re-set `.font`, not just `.string`/`.bounds`. Included in
        // Equatable so a signature-unchanged frame is still a true no-op (the common case).
        let fontName: String

        init(
            glyph: NativeLyricsTextSweepVisualRun.Glyph, fontSize: CGFloat, brightAlpha: CGFloat = 1,
            fontName: String
        ) {
            text = glyph.text
            width = glyph.rect.width.rounded(.toNearestOrAwayFromZero)
            height = glyph.rect.height.rounded(.toNearestOrAwayFromZero)
            self.fontSize = fontSize
            self.brightAlpha = (brightAlpha * 1000).rounded(.toNearestOrAwayFromZero) / 1000
            self.fontName = fontName
        }
    }

    /// 2026-09-20 (3p root-cause fix, verified on the founder's machine): the per-glyph tiles must
    /// paint with the SAME concrete font AppKit's layout resolved for that character (CJK fallback
    /// lands on `.PingFangUIDisplaySC-Semibold`), not the generic system font, or the bright
    /// outline never coincides with the dim outline beneath it (persistent double edge on every
    /// swept glyph). `NSTextStorage.fixAttributes` performs exactly that font substitution and
    /// writes the resolved font back into the attribute; cached per (text, size) per row.
    private var resolvedFontStorageKey: String?
    private var resolvedFontStorage: NSTextStorage?
    private func resolvedGlyphFont(text: String, characterIndex: Int, fallbackSize: CGFloat) -> NSFont {
        let key = "\(fallbackSize)|\(text)"
        if resolvedFontStorageKey != key {
            let storage = NSTextStorage(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: fallbackSize, weight: .semibold)]
            )
            storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
            resolvedFontStorage = storage
            resolvedFontStorageKey = key
        }
        if let storage = resolvedFontStorage,
           characterIndex >= 0, characterIndex < storage.length,
           let font = storage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont {
            return font
        }
        return NSFont.systemFont(ofSize: fallbackSize, weight: .semibold)
    }

    /// v2.8-style single-pass active line renderer (see NativeLyricsActiveLineDrawLayer).
    let activeLineDrawLayer = NativeLyricsActiveLineDrawLayer()
    private var singlePassActive = false
    private var singlePassPrewarmKey: String?
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
            mainWasTextActiveLastPhase = false
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
    // Tracks the text-activation state `updatePlaybackPhase` observed LAST TIME it ran on this
    // view (regardless of role/config churn in between) — the activation-edge detector the fade
    // floor reset above relies on. Never true after `prepareForReuse`/a fresh mount, so a
    // recycled view can't inherit a stale "already active" reading from whatever line it used
    // to represent.
    private var mainWasTextActiveLastPhase = false

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
        let __t0 = CFAbsoluteTimeGetCurrent(); defer { NativeLyricsSurfaceView.tickPhaseAccum["updateDeactivationFade", default: 0] += (CFAbsoluteTimeGetCurrent() - __t0) * 1000 }
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
        wholeLineMainString = nil
        wholeLineBrightString = nil
        isHovering = false
        onHoverChanged = nil
        onHoverBackgroundVisible = nil
        onTap = nil
        mainDeactivationOverlayBaseline = nil
        translationDeactivationOverlayBaseline = nil
        clearParkedTextPhaseOpacity()
        mainPostLineFadeFloor = 1
        translationPostLineFadeFloor = 1
        mainWasTextActiveLastPhase = false
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
        activeFloatingHiddenSignature = nil
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
        mainWordGlyphLayerSignatures = Array(repeating: nil, count: mainWordGlyphLayerSignatures.count)
        debugWordGlyphColorAssignCount = 0
        hideTranslationLoadingDots()
        hideDotLayers()
    }

    @discardableResult
    func applyBlurRadius(_ radius: CGFloat) -> CGFloat {
        let logicalBlur = radius > 0.1 && !NativeLyricsFeelParity.depthBlurDisabled ? radius : 0
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

    // 2026-09-18 (3h round, item 1 final form — founder-dictated after the activation-bound fix
    // still measured the old 1.5-2.0s delay via the kept `hasActiveMotion` safety net): a
    // deactivated row is rasterized from the SAME frame it deactivates, unconditionally, including
    // through any position motion that follows. This is safe because blur is a STEPPED channel
    // (`NativeLyricsVisualMotionState.setTarget` snaps `blur = nextTarget.blur` the instant a row's
    // target changes — no springing left to race), so the only things that change DURING a
    // deactivated row's subsequent motion are its FRAME (position) and its LAYER OPACITY — both of
    // which are applied AFTER rasterization (CA composites the cached bitmap at wherever the layer
    // currently is, at whatever opacity it currently has; neither triggers a recapture). There is
    // no "still in flight, captured a stale/blurry snapshot" window left to protect (f1b8d8f's own
    // repro is rewritten to assert the NEW contract — shouldRasterize itself must not flip during
    // motion, not "must not rasterize" — see LyricsRenderDefects20260918ReproTests). The one-time
    // bitmap-vs-live-vector visual difference this flip can produce (if it is ever the actual
    // artifact — undetectable headlessly, only the render server applies rasterization) now lands
    // on the SAME frame as the deactivation's own much larger visual transition, never isolated in
    // dead calm afterward.
    func applyRasterizationPolicy(isActive: Bool) {
        rasterizationEligible = !isActive
        refreshRasterization()
    }

    private var hasLiveDotAnimation: Bool {
        !translationLoadingDotContainerLayer.isHidden || !dotContainerLayer.isHidden
    }

    // 2026-09-18: no manual off-then-on recapture dance anymore. CA invalidates and regenerates a
    // rasterized layer's cached bitmap automatically whenever the layer's own content (or a
    // sublayer's) actually needs display — a genuine blur-radius or geometry change already
    // triggers that through the normal `setNeedsDisplay`-on-property-change path, same as any other
    // CALayer property. The manual signature-based toggle this used to do (RasterizationSignature,
    // "force a FRESH capture: toggling off then on...") existed to fix 2026-09-17's CJK
    // trailing-word ghost — but that bug's actual cause was `shouldRasterize` staying TRUE through
    // the window a row's TEXT PHASE went live (a stale snapshot kept compositing behind fresh live
    // tile writes), which is fixed by `rasterizationEligible = !isActive` itself (isActive folds in
    // `isTextPhaseActiveThisFrame`, revoking rasterization the SAME frame text goes live — see the
    // call site in LyricsLayerRendererView.applyFrame, and NativeLyricsRasterizationSignatureTests'
    // invariant (a), kept and still green). The toggle was never load-bearing for that fix.
    private func refreshRasterization() {
        let desired = rasterizationEligible
            && appliedBlurRadius > 0.001
            && !hasLiveDotAnimation
            && !NativeLyricsFeelParity.rasterizationDisabled
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
    // 2026-09-18 fix (founder real-machine LineGaps evidence, research/repro-2026-09-18-
    // lyrics-render-3d.md §4 third round): the 0.95<->1.00 active/inactive scale used to pivot Y
    // at the row's geometric CENTER (`frame.height / 2`) — chosen, per NativeLyricsRowScale's own
    // doc comment, to fix a DIFFERENT, earlier bug (pivoting near the top made CJK wrapped lines
    // visibly gain/lose 行距 as the scale sprang). But centering the pivot means the row's FIRST
    // (topmost) line of text — the line the founder is actually looking at, having just finished
    // singing it — moves by `firstLineOffsetFromCenter * |Δscale|` every single activation/
    // deactivation: for a typical 40pt single-line row that is ≈1pt, matching the founder's
    // reported "each line change nudges 1-2px" and "the just-finished line's settle position
    // doesn't match where it lands as the previous line" exactly.
    //
    // Fix (coordinator-approved): pivot Y at the FIRST LINE'S TEXT BASELINE instead — the
    // baseline the founder is reading stays bit-for-bit fixed across the scale toggle; the
    // shrink/expand now visibly extends DOWNWARD (into wrap-lines 2/3+ and the translation line,
    // if any) instead of being distributed above and below a row center nobody is looking at.
    // `mainTextTopInset` (8pt) is the same value `layout()` uses for `mainTextLayer.frame.minY`;
    // `font.ascender` is the standard distance from a line's top to its own baseline for the
    // default (non-custom) line height NSLayoutManager uses here (confirmed: `measuredTextHeight`
    // does not set a custom line-height multiple). X pivot (`nativeLyricContentLeadingInset`,
    // the 2026-09-17 C1 fix) is UNCHANGED — orthogonal axis, not touched here.
    //
    // Falls back to the row's own vertical center for non-text rows (the prelude dots row) —
    // "first line baseline" has no meaning there, and this is deliberately scoped to the
    // founder-reported text-row regression, not a blanket re-anchor of every row kind.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    var verticalScalePivotY: CGFloat {
        guard let row, !row.isPrelude, let configuration else {
            return bounds.height / 2
        }
        let plan = textRenderPlan(row: row, configuration: configuration)
        let font = NSFont.systemFont(ofSize: plan.constants.mainFontSize, weight: .semibold)
        return Self.mainTextTopInset + font.ascender
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

    var debugActiveLineDrawLayerHidden: Bool { activeLineDrawLayer.isHidden }

    var debugVisibleDimWordGlyphCount: Int {
        mainDimWordGlyphLayers.filter { !$0.isHidden }.count
    }

    var debugVisibleBrightWordGlyphCount: Int {
        mainBrightWordGlyphLayers.filter { !$0.isHidden }.count
    }

    /// Sweep-ghost diagnostic: dim/bright glyph tile pairs, index-aligned (both loops in
    /// `applyMainWordFloatGlyphLayers` build `inputs` in the same order, so index i's dim and
    /// bright layer represent the SAME glyph). `dimHidden` distinguishes "no tile drawn — the
    /// whole-line base is still showing this glyph, unfloated" from "tile drawn and floated".
    var debugMainWordGlyphPairs: [(dimPositionY: CGFloat, brightPositionY: CGFloat, dimHidden: Bool)] {
        zip(mainDimWordGlyphLayers, mainBrightWordGlyphLayers).map {
            ($0.position.y, $1.position.y, $0.isHidden)
        }
    }

    /// Repro/regression instrumentation (defect 1, emphasis words, 2026-09-14 founder report).
    /// `applyMainWordFloatGlyphLayers` still SKIPS emphasis-order runs entirely (`where
    /// !emphasisOrders.contains(run.order)`) — emphasis words render exclusively through
    /// `emphasisGlyphLayers` — but as of the 2026-09-14 fix `floatingOrders` (fed to
    /// `applyFloatingHiddenBase`) DOES include an emphasis word's order while its animation is
    /// actively displacing it (liftY/floatY nonzero or scale != 1), so the whole-line dim base is
    /// blanked for it the same way an ordinary floating word is. Reports each emphasis glyph
    /// layer's applied Y/scale, index-aligned to `emphasisGlyphLayers`, for tests to compare
    /// against the (now correctly hidden) dim-base rest position.
    var debugEmphasisGlyphLayerPositions: [(appliedPositionY: CGFloat, appliedScale: CGFloat, isHidden: Bool)] {
        emphasisGlyphLayers.map { layer in
            let t = layer.affineTransform()
            return (layer.position.y, sqrt(t.a * t.a + t.c * t.c), layer.isHidden)
        }
    }

    /// True when NOTHING in the legacy `emphasisGlyphLayers` pool is currently visible — the
    /// feel/emphasis `v28`/`amll` contrast arms must never populate this pool (they fold emphasis
    /// words into the ordinary per-word tile pipeline instead), so this pins "no second
    /// independently-positioned object" directly (`NativeLyricsEmphasisFeelParityTests`).
    var debugEmphasisGlyphLayerPoolAllHidden: Bool {
        emphasisGlyphLayers.allSatisfy(\.isHidden)
    }

    /// feel/emphasis `v28`: shadowOpacity currently applied to each `mainBrightWordGlyphLayers`
    /// tile — the glow for this arm is a real CALayer shadow on the SAME object that carries the
    /// sharp glyph (never a second layer), so this is the whole observable glow signal for it.
    var debugMainBrightWordGlyphShadowOpacities: [Float] {
        mainBrightWordGlyphLayers.map(\.shadowOpacity)
    }

    /// feel/emphasis `amll`: true only if NONE of the glow sibling layers carry a live
    /// `layer.filters` entry — the glow bitmap must be `layer.contents` (a cached, offline-
    /// rendered CGImage), never a resident CIFilter attached to the layer.
    var debugEmphasisGlowLayersHaveNoLiveFilters: Bool {
        mainEmphasisGlowLayers.allSatisfy { $0.filters == nil || $0.filters?.isEmpty == true }
    }

    /// feel/emphasis `amll`: index-aligned (bright tile position/scale, glow sibling
    /// position/scale, glow visible/opacity) pairs, sourced from `mainBrightWordGlyphLayers` /
    /// `mainEmphasisGlowLayers`. The glow's position/transform are copied from the bright tile at
    /// the same call site (`applyEmphasisGlowOnSharedTile`), so this pair should read IDENTICAL
    /// whenever the glow is visible — that equality is the structural guarantee against ghosting.
    var debugEmphasisGlowTilePairs: [(
        brightPosition: CGPoint, glowPosition: CGPoint,
        brightScale: CGFloat, glowScale: CGFloat,
        glowVisible: Bool, glowOpacity: Float
    )] {
        zip(mainBrightWordGlyphLayers, mainEmphasisGlowLayers).map { bright, glow in
            let bt = bright.affineTransform()
            let gt = glow.affineTransform()
            return (
                bright.position, glow.position,
                sqrt(bt.a * bt.a + bt.c * bt.c), sqrt(gt.a * gt.a + gt.c * gt.c),
                !glow.isHidden, glow.opacity
            )
        }
    }

    /// True when `mainTextLayer.string` (the whole-line dim base) has BLANKED the character range
    /// belonging to word `order` — i.e. something subtracted it the way `applyFloatingHiddenBase`
    /// subtracts an ordinary floating word. `nil` when the layer has no attributed string or the
    /// order is out of range. Character offset is derived the same way
    /// `NativeLyricsHiddenTextMask.ranges` locates a word's range: sequential concatenation of
    /// `plan.wordRuns[i].text`.
    func debugMainTextLayerIsWordHidden(order: Int, plan: NativeLyricsTextRenderPlan) -> Bool? {
        guard let attributed = mainTextLayer.string as? NSAttributedString else { return nil }
        guard plan.wordRuns.indices.contains(order) else { return nil }
        var location = 0
        for (index, run) in plan.wordRuns.enumerated() {
            let length = (run.text as NSString).length
            if index == order {
                guard location < attributed.length else { return nil }
                guard let color = attributed.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor else {
                    return nil
                }
                return color.alphaComponent < 0.01
            }
            location += length
        }
        return nil
    }

    /// Same check as `debugMainTextLayerIsWordHidden` but against `mainBrightTextLayer` — the
    /// sweep/karaoke overlay layer that `emphasisGlyphLayers` are mounted onto as sublayers
    /// (`mainEmphasisLayer` parents into it). 2026-09-15 repro: unlike `mainTextLayer` (fixed
    /// 2026-09-14, `applyFloatingHiddenBase`), NOTHING ever hides an emphasis word's glyph range
    /// in `mainBrightTextLayer.string` while `geometryReady == true` (the normal, majority-of-
    /// playback-time path) — `applyHiddenEmphasisText` (the one function that hides BOTH layers)
    /// only runs when `managesContainerText` (`!geometryReady`) is true. `mainPerRunSweepMaskLayer`
    /// reveals `mainBrightTextLayer`'s own text for that word once the sweep wavefront passes it,
    /// at the word's static rest position — simultaneously with the floating/scaled/glowing
    /// `emphasisGlyphLayers` copy on top. This accessor exists to make that gap directly
    /// observable from tests, not to change any rendering behavior.
    func debugMainBrightTextLayerIsWordHidden(order: Int, plan: NativeLyricsTextRenderPlan) -> Bool? {
        guard let attributed = mainBrightTextLayer.string as? NSAttributedString else { return nil }
        guard plan.wordRuns.indices.contains(order) else { return nil }
        var location = 0
        for (index, run) in plan.wordRuns.enumerated() {
            let length = (run.text as NSString).length
            if index == order {
                guard location < attributed.length else { return nil }
                guard let color = attributed.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor else {
                    return nil
                }
                return color.alphaComponent < 0.01
            }
            location += length
        }
        return nil
    }

    var debugDimCompensationActive: Bool { mainDimCompensationActive }

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
        // Force an active plan at this time so tests can prove each word floats by
        // its OWN amount (spread > 0 = the cascade) instead of one collapsed value.
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

    /// Repro instrumentation (defect 3, 2026-09-14 founder report: prelude dots parked at the
    /// panel's top-left instead of centred like the active line). Mirrors the Y accessor above —
    /// the dot cluster's centre X in the ROW's own coordinate space, so a test can compare it
    /// against the row's content leading inset / width without guessing at CALayer internals.
    var debugPreludeDotCenterX: CGFloat { dotContainerLayer.position.x }
    var debugPreludeDotContainerHidden: Bool { dotContainerLayer.isHidden }
    var debugPreludeDotContainerOpacity: Float { dotContainerLayer.opacity }

    /// Cross-hierarchy position readback for annotated diagrams (defect 3, 2026-09-14). Walks
    /// the REAL CALayer tree (`CALayer.convert(_:to:)`, which correctly folds in any ancestor
    /// `setAffineTransform` — e.g. the row's own `positioningTransform` — unlike hand-adding
    /// `frame.minX/minY`) so the returned point matches exactly where `CALayer.render(in:)` would
    /// actually paint the dots, in `targetLayer`'s coordinate space (pass the hosting surface's
    /// own `.layer` to get surface-space coordinates for a full-panel screenshot annotation).
    func debugDotContainerCenter(in targetLayer: CALayer) -> CGPoint {
        dotContainerLayer.superlayer?.convert(dotContainerLayer.position, to: targetLayer) ?? .zero
    }

    /// Same cross-hierarchy conversion for the main (dim) text layer's own centre — used as the
    /// "current line's text horizontal centre" reference line in the defect-3 diagram.
    func debugMainTextLayerCenter(in targetLayer: CALayer) -> CGPoint {
        let localCenter = CGPoint(x: mainTextLayer.frame.midX, y: mainTextLayer.frame.midY)
        return mainTextLayer.superlayer?.convert(localCenter, to: targetLayer) ?? .zero
    }
    #endif

    // Available to both the unit tests (DEBUG) and the in-app brightness diagnostic
    // (LOCAL_DEVELOPER_BUILD release build). The karaoke bright overlay (full-brightAlpha
    // glyphs) is meant for ONE active line; if several rows carry it at once the panel blooms
    // (the #1 initial-load / rapid-switch overlap), and if a demoted line keeps it the line
    // flashes bright (the #3 revert). Counting it is the channel the model-opacity sensor missed.
    /// Bright karaoke-overlay opacity. Compiled into every build (including plain release):
    /// the ActiveBrightness probe in LyricsLayerRendererView reads it under DebugLogger's
    /// runtime switch, not a compile-time gate. The #2c "dim line blinks while receding"
    /// suspect is the deferred-deactivation clearing this overlay abruptly (a brightness
    /// step) while the row is still partly visible. Sampling it per tick across a line
    /// advance shows whether the recede is monotonic (clean) or has a brighten-then-dim
    /// step (blink).
    var debugMainBrightOpacity: Float { mainBrightTextLayer.isHidden ? 0 : mainBrightTextLayer.opacity }
    var debugMainBrightWordGlyphOpacities: [Float] { mainBrightWordGlyphLayers.map { $0.isHidden ? 0 : $0.opacity } }

    /// The CIGaussianBlur radius actually applied to this row's layer (the depth-of-field blur).
    /// Compiled into every build for the same reason as `debugMainBrightOpacity` above — the
    /// LineGaps probe reads it under DebugLogger's runtime switch.
    var debugAppliedBlurRadius: CGFloat { max(0, appliedBlurRadius) }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Row-dump probe (founder 2026-09-18, CJK trailing-word ghost follow-up,
    // nanopod://debug/rowdump). One-shot, on-demand text-sublayer inventory for the row —
    // every layer that can carry visible glyphs, so a founder who sees a duplicate/ghosted
    // character on screen can dump the exact layer tree at that instant and hand back
    // evidence instead of a description. Compiled into EVERY build (including plain
    // release), same discipline as `debugMainBrightOpacity`/`debugAppliedBlurRadius` above —
    // this reads plain CALayer properties, no DEBUG-only state, and does no I/O itself (the
    // caller writes the returned lines to disk, matching NativeLyricsMaskTrace's own
    // "armed at the call site, not the accessor" split).
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    func rowDumpLines(role: String) -> [String] {
        var lines: [String] = []
        let rowText = row?.displayLine.line.text ?? "?"
        let rowID = row?.displayLine.id ?? "?"
        lines.append("row role=\(role) id=\(rowID) text=\"\(rowText.prefix(12))\"")
        func describe(_ label: String, _ layer: CALayer?) {
            guard let layer else { return }
            let string = (layer as? CATextLayer)?.string as? NSAttributedString
            let stringPrefix = string?.string.prefix(8).description
                ?? (layer as? CATextLayer)?.string as? String
            let isBitmapContents = layer.contents != nil
            let t = layer.affineTransform()
            // 2026-09-19 founder follow-up: the model layer (what this whole dump otherwise
            // reads) can commit a value the render server has not caught up to yet — an
            // implicit-animation leak (see banned-patterns.md) that only shows up on the
            // PRESENTATION layer, the tree Core Animation is actually compositing on screen right
            // now. Printing both side by side turns "model says X, screen looked like Y" from an
            // unfalsifiable eyewitness report into a captured discrepancy. `superlayer` names the
            // actual parent this layer composites under — confirms/refutes whether a layer still
            // lives under the opacity-bearing ancestor its dim tier depends on (e.g. a dim glyph
            // tile that got reparented off mainTextLayer would no longer inherit its 0.35).
            let presentationOpacity = layer.presentation()?.opacity
            let presentationOpacityText = presentationOpacity.map { String($0) } ?? "nil(no-presentation)"
            let superlayerName = layer.superlayer.map { "\(type(of: $0))" } ?? "nil"
            lines.append(
                "  \(label) class=\(type(of: layer)) frame=\(layer.frame) opacity=\(layer.opacity) "
                    + "presentationOpacity=\(presentationOpacityText) superlayer=\(superlayerName) "
                    + "hidden=\(layer.isHidden) string=\(stringPrefix.map { "\"\($0)\"" } ?? "nil") "
                    + "contentsIsBitmap=\(isBitmapContents) shouldRasterize=\(layer.shouldRasterize) "
                    + "transform=(a:\(t.a) b:\(t.b) c:\(t.c) d:\(t.d) tx:\(t.tx) ty:\(t.ty))"
            )
        }
        describe("mainTextLayer(dim-base)", mainTextLayer)
        describe("mainBrightTextLayer(line-level-bright)", mainBrightTextLayer)
        describe("mainEmphasisLayer", mainEmphasisLayer)
        describe("activeLineDrawLayer", activeLineDrawLayer)
        for entry in activeLineDrawLayer.recentInputs.suffix(240) {
            let floats = entry.floats.map { String(format: "%.2f", $0) }.joined(separator: ",")
            let waves = entry.waves.map { String(format: "%.1f", $0) }.joined(separator: ",")
            lines.append(String(format: "  singlePass t=%.0f dim=%.3f bright=%.3f floats=[%@] waves=[%@]", entry.wall, entry.dim, entry.bright, floats, waves))
        }
        for (i, l) in mainDimWordGlyphLayers.enumerated() where !l.isHidden {
            describe("mainDimWordGlyphLayers[\(i)]", l)
        }
        for (i, l) in mainBrightWordGlyphLayers.enumerated() where !l.isHidden {
            describe("mainBrightWordGlyphLayers[\(i)]", l)
        }
        for (i, l) in emphasisGlyphLayers.enumerated() where !l.isHidden {
            describe("emphasisGlyphLayers[\(i)](legacy-current-arm)", l)
        }
        for (i, l) in mainEmphasisGlowLayers.enumerated() where !l.isHidden {
            describe("mainEmphasisGlowLayers[\(i)]", l)
        }
        return lines
    }

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
    /// Index of the word currently under the sweep (`-1` if none). Paired with
    /// `debugLastWholeLineHighlight` for the 2026-08-27 mask-trace probe.
    private(set) var debugLastActiveWordIndex: Int = -1
    /// True when the active word-level line is showing whole-line bright instead of
    /// the per-word mask (the "整行直接高亮" signature).
    private(set) var debugLastWholeLineHighlight = false
    private(set) var debugPlaybackPhaseUpdateCount = 0
    // Active-line translation sweep truth captured on the last updatePlaybackPhase. `expected` is
    // what the model wants (partial mid-line), `applied` is what the renderer actually clipped to,
    // `brightOverlayPresent` is whether the sung overlay layer is even carrying text. A word-synced
    // active line that renders "fully bright instantly" shows up here as overlay absent OR applied==1.
    private(set) var debugLastTranslationExpectedProgress: CGFloat?
    private(set) var debugLastTranslationAppliedProgress: CGFloat?
    private(set) var debugLastTranslationBrightOverlayPresent = false
    // Active-line MAIN sweep truth captured on the last updatePlaybackPhase (mirrors the translation
    // trio). `expected` = model wavefront fraction; `applied` = what the renderer clipped to;
    // `perRunSweep` = whether the per-word mask engaged (true) or the whole-line gradient fallback ran
    // (false, e.g. bounds not yet laid out). "整行已高亮 / mask lost" shows up as brightOverlayPresent
    // with applied≈1 while expected is small, or perRunSweep=false while expected per-run sweep.
    private(set) var debugLastMainExpectedProgress: CGFloat?
    private(set) var debugLastMainAppliedProgress: CGFloat?
    private(set) var debugLastMainBrightOverlayPresent = false
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
    /// Counts CATextLayer.foregroundColor writes on the per-glyph karaoke copies.
    /// A settled sweep must not re-assign color every frame — that dirties the layer
    /// and forces CoreText to typeset again (measured 2026-08-27: CATextLayer drawInContext
    /// dominated presentationTick).
    private(set) var debugWordGlyphColorAssignCount = 0
    /// 2026-09-21 switch-window probe accessors (release-safe, read-only).
    var probeMainTextFrame: CGRect { mainTextLayer.frame }
    var probeMainTextPresentationFrame: CGRect { mainTextLayer.presentation()?.frame ?? mainTextLayer.frame }
    var probeActiveDrawFrame: CGRect { activeLineDrawLayer.frame }
    var probeActiveDrawHidden: Bool { activeLineDrawLayer.isHidden }
    var probeMainTextHidden: Bool { mainTextLayer.isHidden }
    var probeRasterized: Bool { layer?.shouldRasterize ?? false }

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
        var y: CGFloat = Self.mainTextTopInset
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
        activeLineDrawLayer.frame = mainTextLayer.frame
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

    /// Sweep-ghost fix: the RAW-text character ranges `displayWrapped` breaks the line into (its
    /// wrap points, computed the same way, minus each fragment's trailing space). Shared with
    /// `attributedDisplayWrapped` below so the hidden-ranges variant of the dim base wraps
    /// IDENTICALLY to `wholeLineMainString` — same fragment count, same fragment content — instead
    /// of accidentally re-wrapping the (unwrapped) `plan.displayText` and shifting the line height.
    private static func wrapLineRanges(for text: String, width: CGFloat, font: NSFont) -> [NSRange]? {
        guard width > 1, text.count > 1, !text.contains("\n") else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
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
        var ranges: [NSRange] = []
        var glyphIndex = 0
        let glyphCount = manager.numberOfGlyphs
        while glyphIndex < glyphCount {
            var lineGlyphRange = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            var charRange = manager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            if charRange.length > 0,
               ns.substring(with: NSRange(location: charRange.location + charRange.length - 1, length: 1)) == " " {
                charRange.length -= 1
            }
            ranges.append(charRange)
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
        guard ranges.count > 1 else { return nil }
        return ranges
    }

    /// Wraps an ALREADY-ATTRIBUTED string (e.g. one with hidden-range glyphs colored `.clear`) the
    /// same way `displayWrapped` wraps plain text — same wrap points (from `rawText`), fragments
    /// re-joined with `\n` — while preserving every existing per-character attribute (the hidden
    /// ranges' color). Falls back to the input unchanged when the raw text doesn't wrap.
    private static func attributedDisplayWrapped(
        _ attributed: NSAttributedString,
        rawText: String,
        width: CGFloat,
        font: NSFont
    ) -> NSAttributedString {
        guard let ranges = wrapLineRanges(for: rawText, width: width, font: font) else { return attributed }
        let result = NSMutableAttributedString()
        for (index, range) in ranges.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            guard range.location + range.length <= attributed.length else { return attributed }
            result.append(attributed.attributedSubstring(from: range))
        }
        return result
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
        activeLineDrawLayer.isHidden = true
        layer?.addSublayer(activeLineDrawLayer)
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
            wholeLineMainString = nil
            wholeLineBrightString = nil
            mainTextLayer.mask = nil
            hideBaseRevealMaskLayers()
            hideEmphasisGlyphLayers()
            hideMainWordGlyphLayers()
            activeHiddenEmphasisSignature = nil
            activeFloatingHiddenSignature = nil
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
        let isActive = NativeLyricsTextActivation.isLineTextActive(
            rowIndex: row.index,
            textActiveIndex: configuration.effectiveTextActiveIndex
        )
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
        wholeLineMainString = attributedText(
            wrappedMainText,
            fontSize: plan.constants.mainFontSize,
            alpha: mainAlpha
        )
        mainTextLayer.string = wholeLineMainString
        // The reuse pool hides every text layer in prepareForReuse() to kill stale content during
        // the transition. The dim BASE must be restored here for every non-prelude row, or a row that
        // ever passed through the pool stays invisible forever — the panel empties out as playback
        // recycles rows, and the active line shows only its sung (bright) portion. Restore it now.
        mainTextLayer.isHidden = false
        wholeLineBrightString = appliesMainSweep
            ? attributedText(wrappedMainText, fontSize: plan.constants.mainFontSize, alpha: plan.constants.brightAlpha)
            : nil
        mainBrightTextLayer.string = wholeLineBrightString
        activeHiddenEmphasisSignature = nil
        activeFloatingHiddenSignature = nil
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
        let __t0 = CFAbsoluteTimeGetCurrent(); defer { NativeLyricsSurfaceView.tickPhaseAccum["updatePlaybackPhase", default: 0] += (CFAbsoluteTimeGetCurrent() - __t0) * 1000 }
        guard let row else { return nil }
        #if DEBUG
        debugPlaybackPhaseUpdateCount += 1
        #endif
        // A genuine playback discontinuity (explicit seek / tap-to-line / direct snap) is the
        // same class of event `configure()` already treats as a reason to reset the monotone
        // post-line karaoke fade floor (see mainPostLineFadeFloor's declaration comment) — except
        // configure() only fires that reset when THIS VIEW gets reassigned to a DIFFERENT row.
        // A row view that stays mounted across a seek (the common case: nearby rows are never
        // recycled through prepareForReuse) never took that path, so a floor already pinned near
        // 0 from before the seek stayed pinned forever, even after seeking back into that same
        // line's own span where the freshly computed fade is 1 — the karaoke highlight overlay
        // never returned (2026-09-17: "seek back into an already-sung line loses its highlight").
        if configuration.nativeSeekDiscontinuityOccurred {
            mainPostLineFadeFloor = 1
            translationPostLineFadeFloor = 1
        }
        // Phase timing MUST come from the shared monotonic clock (phaseRenderTime), never the raw
        // SB clock: a backward resync dip at line start collapses the active plan to progress 0
        // for a frame — the handoff style flash (docs/defect-recordings/2026-07-11).
        let renderTime = configuration.phaseRenderTime()
        let isActive = NativeLyricsTextActivation.isLineTextActive(
            rowIndex: row.index,
            textActiveIndex: configuration.effectiveTextActiveIndex
        )
        // 2026-09-19 real-device repro (row dump + mask trace, "想爱 就不能害怕会有伤痕"):
        // the `nativeSeekDiscontinuityOccurred` reset above only fires for rows that actually
        // get `updatePlaybackPhase` called on them during the exact tick the flag is true — a
        // transient, one-frame signal. A row that sits mounted-but-inactive (e.g. representing
        // an upcoming line that hasn't been promoted to "active" yet) can miss that tick
        // entirely, so a floor pinned near 0 from a PREVIOUS activation of this same line
        // survives, and the row's karaoke overlay never lights when it naturally becomes
        // active again — independent of whether a seek ever happened.
        // Fix at the clock/activation-edge level instead of the transient flag: the floor must
        // be armed to 1 whenever this row is (re)entering its own active window, detected two
        // ways — (a) the activation EDGE (this row was not text-active last update and is now),
        // which catches every promotion path regardless of how it happened, and (b) the render
        // clock sitting before this line's own start (a landing seek can put a row directly into
        // "active" mid-span without ever crossing a false→true edge on this exact view). Gating
        // on the edge (not every active frame) is required — resetting on every tick a row is
        // active is the previously-banned `.initialLayout`-style repeat-snap that relit an
        // ALREADY-CORRECTLY-fading previous line (see docs/defect-recordings, 2026-09-17).
        if isActive {
            let justEnteredActiveWindow = !mainWasTextActiveLastPhase
            let renderTimeBeforeLineStart = renderTime < row.displayLine.line.startTime
            if justEnteredActiveWindow || renderTimeBeforeLineStart {
                mainPostLineFadeFloor = 1
                translationPostLineFadeFloor = 1
            }
        }
        mainWasTextActiveLastPhase = isActive

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
            // 2026-09-19 real-device repro (rowdump "想爱 就不能害怕会有伤痕"): the dim-base
            // compensation flags (`mainDimCompensationActive`/`translationDimCompensationActive`)
            // used to be written ONLY inside `updateTextLayers` (called from `configure()`, which
            // runs at mount/reuse — not every frame). A row promoted to active purely through the
            // per-frame `updatePlaybackPhase` path (the common case: the render loop reassigns
            // roles without a fresh `configure()` when the row's own content didn't change) kept
            // whatever flag value was baked in when it was last configured — often `false` from
            // when it was configured as an upcoming/inactive row — so `applyDimBaseCompensation`
            // forced the dim base to full opacity (uncompensated) even while genuinely active and
            // swept: the whole line read as fully bright with no per-word mask. Recompute both
            // flags from the CURRENT activation state on every phase update, not just at
            // configure-time, so an activation transition that skips `configure()` still corrects
            // the compensation the same frame.
            mainDimCompensationActive = expectsPerRunSweep
            translationDimCompensationActive = isActive
                && row.displayLine.line.hasSyllableSync
                && plan.translation != nil
            applyDimBaseCompensation()
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
            debugLastMainExpectedProgress = plan.mainSweepProgress
            debugLastMainAppliedProgress = appliedMainProgress.progress
            debugLastMainBrightOverlayPresent =
                !mainBrightTextLayer.isHidden && mainBrightTextLayer.string != nil
            #endif
            #if DEBUG || LOCAL_DEVELOPER_BUILD
            if expectsPerRunSweep {
                debugLastActiveWordIndex = plan.wordRuns.lastIndex(where: { $0.startTime <= renderTime }) ?? 0
            } else {
                debugLastActiveWordIndex = -1
            }
            debugLastWholeLineHighlight = expectsPerRunSweep
                && !appliedMainProgress.appliedPerRunSweep
                && !mainBrightTextLayer.isHidden
                && mainBrightTextLayer.string != nil
            #endif
            // 2026-09-14: NativeLyricsMaskTrace now also arms via a UserDefaults switch (the
            // founder cannot pass an environment variable when launching from Finder), so this
            // call must run in EVERY build configuration, not just DEBUG/LOCAL_DEVELOPER_BUILD —
            // the trace itself still defaults to off (checked inside `record`, zero I/O when
            // disarmed). Recomputes the same two values locally instead of reading the
            // DEBUG-only stored properties above, which don't exist in a plain release build.
            let maskTraceWordIndex = expectsPerRunSweep
                ? (plan.wordRuns.lastIndex(where: { $0.startTime <= renderTime }) ?? 0)
                : -1
            let maskTraceWholeLineHighlight = expectsPerRunSweep
                && !appliedMainProgress.appliedPerRunSweep
                && !mainBrightTextLayer.isHidden
                && mainBrightTextLayer.string != nil
            // 2026-09-19 real-device repro blind spot: neither `wholeLineHighlight` (bright visible
            // with no mask) nor `brightUnmaskedIncomplete` (bright visible + incomplete) catch the
            // OPPOSITE shape actually seen on device — the bright overlay entirely HIDDEN
            // (mainPostLineFadeFloor pinned to 0 from a stale prior activation) while the active
            // line's expected sweep progress is partway through. That row silently renders as
            // dim-only with no karaoke overlay at all; record it as its own field so a future
            // real-device session doesn't require a live repro to notice it again.
            let maskTraceBrightHiddenWhileSweeping = expectsPerRunSweep
                && plan.mainSweepProgress > 0.001
                && plan.mainSweepProgress < 0.999
                && mainBrightTextLayer.isHidden
            NativeLyricsMaskTrace.record(
                rowID: row.displayLine.id,
                wordIndex: maskTraceWordIndex,
                wholeLineHighlight: maskTraceWholeLineHighlight,
                perRunSweep: appliedMainProgress.appliedPerRunSweep,
                expected: plan.mainSweepProgress,
                applied: appliedMainProgress.progress,
                mainBrightOverlayPresent: !mainBrightTextLayer.isHidden && mainBrightTextLayer.string != nil,
                mainBrightOpacity: debugMainBrightOpacity,
                brightHiddenWhileSweeping: maskTraceBrightHiddenWhileSweeping
            )
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
            // Same staleness fix as the active branch above: a row demoted from active purely via
            // the per-frame role reassignment (no fresh `configure()`) must not keep reading as
            // "sweep in progress" for dim-compensation purposes.
            mainDimCompensationActive = false
            translationDimCompensationActive = false
            applyDimBaseCompensation()
            applyInactivePlaybackLayerState()
        }
        updateDotsPhase(row: row, currentTime: renderTime)
        if managesTransaction {
            CATransaction.commit()
        }
        return sample
    }

    private func applyInactivePlaybackLayerState() {
        let __t0 = CFAbsoluteTimeGetCurrent(); defer { NativeLyricsSurfaceView.tickPhaseAccum["applyInactivePlaybackLayerState", default: 0] += (CFAbsoluteTimeGetCurrent() - __t0) * 1000 }
        leaveSinglePassActiveLine()
        // Leaving the active word-cascade: the whole-line base must come back
        // before the per-word/emphasis glyphs hide, or the row goes blank.
        if mainTextLayer.string == nil, let wholeLineMainString {
            mainTextLayer.string = wholeLineMainString
            mainBrightTextLayer.string = wholeLineBrightString
        }
        mainBrightTextLayer.isHidden = true
        mainBrightTextLayer.mask = mainSweepMaskLayer
        mainTextLayer.mask = nil
        hideBaseRevealMaskLayers()
        hidePerRunSweepMaskLayers()
        hideEmphasisGlyphLayers()
        hideMainWordGlyphLayers()
        activeHiddenEmphasisSignature = nil
        activeFloatingHiddenSignature = nil
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
        let __t0 = CFAbsoluteTimeGetCurrent(); defer { NativeLyricsSurfaceView.tickPhaseAccum["applyActiveMainPhase", default: 0] += (CFAbsoluteTimeGetCurrent() - __t0) * 1000 }
        let activeRun = plan.wordRuns.last { $0.startTime <= currentTime }
            ?? plan.wordRuns.first
        // 2026-09-18 (stage bundle 3i, item 3 — CJK trailing-line ghost): the dim base
        // (`applyFloatingHiddenBase`, below) wraps against `contentTextWidth(configuration)` —
        // `configuration.rowWidth` minus insets, documented at its own declaration as the
        // "single source of truth ... never bounds.width, which can be stale/zero on a fresh
        // view [or] pooled one before layout() runs". The bright per-glyph sweep layout used to
        // read `mainBrightTextLayer.bounds.width` instead — exactly the quantity that comment
        // warns against — so a `configure()` at a NEW rowWidth landing before the next AppKit
        // layout pass catches `bounds` up to it (a dropped/delayed frame; `layout()`'s own
        // memoization gate means this is not guaranteed to run synchronously with configure())
        // made the two systems wrap the SAME text against DIFFERENT widths for one or more
        // ticks: the dim base commits to its new wrap immediately, the bright per-glyph tiles
        // stay laid out for the OLD width until `bounds` catches up. The dim base's newly
        // revealed trailing line then has no bright tile drawn over it at all — a dim-only
        // (0.35 opacity), blurred-looking duplicate of the row's own trailing text. Route both
        // through the exact same width source so they can never disagree.
        let sweepBounds: CGRect
        if let configuration {
            sweepBounds = CGRect(x: 0, y: 0, width: contentTextWidth(configuration), height: mainBrightTextLayer.bounds.height)
        } else {
            sweepBounds = mainBrightTextLayer.bounds
        }
        let linePlan = mainSweepLinePlan(for: plan, bounds: sweepBounds)
        let emphasisOrders = Self.activeEmphasisOrders(plan: plan)
        // v2.8 Canvas: dim base is one laid-out string (pass 1); only the bright overlay
        // is per-glyph so words can float (pass 2). Nilling the dim string and retessellating
        // it as CATextLayer tiles was the activation 行距/字距 jump (founder 2026-08-27).
        // Before layout (bounds are .zero on a fresh/pooled row) we keep the whole-line dim
        // and hide the sung overlay, so the dim base is never blank (the 从无到有 guard).
        // `geometryReady`'s WIDTH check stays on the real `bounds` (not `contentTextWidth`,
        // which is always > 0 regardless of layout state) — it is asking "has this row been
        // laid out at all yet", not "what width should wrapping use".
        let geometryReady = mainBrightTextLayer.bounds.width > 1
            && mainBrightTextLayer.bounds.height > 1
            && !linePlan.isEmpty
        let keepWholeLineDim = NativeLyricsFeelParity.keepsWholeLineDimBase
        if geometryReady, NativeLyricsFeelParity.activeLineRenderer == .singlePass {
            return applySinglePassActiveLine(plan: plan, currentTime: currentTime, linePlan: linePlan, sweepBounds: sweepBounds)
        }
        let wordFloatResult: MainWordFloatAppliedMetrics
        // Sweep-ghost fix: non-emphasis words that are ACTUALLY floating (baseFloatY != 0)
        // must not also show through the whole-line dim base — that second, unfloated copy
        // is the reported double image on swept CJK glyphs. A word at floatY == 0 (not yet
        // started) is left alone: it coincides exactly with the whole-line glyph already, so
        // there is nothing to hide and no tile needed (also keeps the activation-instant
        // layout tests, which sample at floatY == 0, unaffected).
        //
        // 2026-09-14 founder report: the SAME double image on emphasis words ("WHAT IT'S ALL
        // ABOU[T]") — applyEmphasisGlyphLayers draws a separate scale/lift/glow glyph for
        // emphasis-order words, but this set used to unconditionally EXCLUDE emphasisOrders, so
        // an emphasis word's whole-line dim-base copy was NEVER hidden while it animated. Extend
        // the same "hide only while actually displaced" rule to emphasis words: liftY/floatY
        // nonzero or scale != 1 means the emphasis animation is currently moving the glyph away
        // from its rest position, so the base copy must be blanked exactly like a floating
        // ordinary word. amount == 0 (outside the emphasis window) leaves the word coincident
        // with the base, matching the existing floatY == 0 exemption above.
        // 2026-09-18 (3h round, item 6, founder-dictated fix): `NativeLyricsEmphasisPlan.scale`
        // (1 + emphasisWeight*0.1*amount, up to ~1.12x — confirmed by
        // NativeLyricsEmphasisHollowOverlapTests) enlarges the bright tile around its own centre,
        // so a scale > 1 makes the rendered tile wider than the STATIC (unscaled) hollow cut for
        // just this word's own characters — the overflow bleeds onto the immediately adjacent
        // word's still-full-opacity dim ink (the "edge blur/double image" shape the founder
        // described). Hollow the SAME neighbour character(s) too, using the identical `scale`
        // value already computed for the bright layer (no separate calculation) as the trigger.
        // This is safe, not just "hides the symptom": `applyMainWordFloatGlyphLayers` already
        // builds a per-glyph dim tile for EVERY word in the line (not only floating ones) —
        // widening `floatingOrders` to include the neighbour makes its dim tile become VISIBLE at
        // its own REST position (`floatY` is 0 for a word that hasn't started), which is exactly
        // where the whole-line base was drawing it — a clean 1:1 ink replacement, not a new gap.
        let floatingOrders: Set<Int> = keepWholeLineDim
            ? Set(plan.wordRuns.enumerated().flatMap { order, run -> [Int] in
                  if emphasisOrders.contains(order) {
                      let isActiveEmphasis = run.emphasis.liftY != 0
                          || run.emphasis.floatY != 0
                          || run.emphasis.scale != 1
                      guard isActiveEmphasis else { return [] }
                      var orders = [order]
                      if run.emphasis.scale > 1.001 {
                          if order > 0 { orders.append(order - 1) }
                          if order < plan.wordRuns.count - 1 { orders.append(order + 1) }
                      }
                      return orders
                  }
                  return run.baseFloatY != 0 ? [order] : []
              })
            : []
        if geometryReady {
            if keepWholeLineDim {
                applyFloatingHiddenBase(plan: plan, floatingOrders: floatingOrders)
            } else if mainTextLayer.string != nil {
                mainTextLayer.string = nil
                activeFloatingHiddenSignature = nil
            }
            if mainBrightTextLayer.string != nil { mainBrightTextLayer.string = nil }
            activeHiddenEmphasisSignature = nil
            if mainTextLayer.affineTransform() != .identity {
                mainTextLayer.setAffineTransform(.identity)
            }
            if mainBrightTextLayer.affineTransform() != .identity {
                mainBrightTextLayer.setAffineTransform(.identity)
            }
            // Pin the post-line fade monotone BEFORE the per-glyph pass (moved up from below,
            // 2026-09-19 founder-dictated fix) so the bright tiles it paints this SAME frame use
            // the floored value too — a backward clock step can't re-light them, and their fade
            // stays in lockstep with `mainBrightTextLayer`'s own opacity.
            //
            // 2026-09-19 real-device repro (/tmp/nanopod_debug.log 18:10:55 "position jump
            // 215.4s→83.7s" during a pause/play mash; 18:11:36 `bright=0.000 eff=0.000` on a row
            // whose line is still genuinely active, minutes later): the floor's semantics only
            // hold AFTER the line has ended. A transient interpolated-clock reading that briefly
            // reports a time WELL PAST this line's own end (a pause/resume mash's position
            // correction landing on a stale sample, or any other momentary bad read) makes
            // `plan.mainPostLineFade` compute as fully decayed for that ONE frame — `min` then
            // crushes the floor to ~0, and since nothing else re-arms it (this row never took a
            // line-change/seek/activation-edge, because the clock recovers a frame later and the
            // line is STILL genuinely active), the floor stays crushed forever: the karaoke
            // overlay reads permanently invisible for the rest of that line. The floor's monotone
            // "never rises" guarantee is only meant to apply to the post-line GAP, never to time
            // that is legitimately still inside the line's own sung window — so re-arm it to 1
            // unconditionally whenever `currentTime` sits at or before this line's own end.
            //
            // FOUNDER-FLAGGED TRADE-OFF: a row has no signal available here to tell "this line is
            // still genuinely playing" (this bug) apart from "the surface has already moved past
            // this line and is parking it through the post-line gap, and a non-explicit backward
            // jitter happens to land before its end" (the older, narrower scenario
            // `NativeLyricsGapHandoffTests.test_overlayRelightsOnBackwardJitterAcrossLineEnd_founderAcceptedTradeoff`
            // exercises) — `configuration.effectiveCurrentIndex` does NOT distinguish them (it
            // stays on this row throughout the post-line gap too). This fix accepts reopening the
            // older, narrower case to close the newer, worse one (see that test's header comment
            // for the full trade-off write-up); a real reconciliation needs a signal this row does
            // not currently have (e.g. whether the surface has begun this row's deferred
            // deactivation) plumbed through from the surface, out of scope for this pass.
            let mainLineEnd = plan.wordRuns.last?.endTime ?? currentTime
            if currentTime <= mainLineEnd {
                mainPostLineFadeFloor = 1
            } else {
                mainPostLineFadeFloor = min(mainPostLineFadeFloor, plan.mainPostLineFade)
            }
            wordFloatResult = applyMainWordFloatGlyphLayers(
                plan: plan,
                currentTime: currentTime,
                linePlan: linePlan,
                emphasisOrders: emphasisOrders,
                floatsDimBase: !keepWholeLineDim,
                floatingOrders: floatingOrders
            )
        } else {
            // Geometry is not ready (fresh/pooled/offscreen row). A whole-line bright
            // overlay plus a zero-size gradient mask reads as "整行已高亮 / mask lost".
            // Keep the dim base, hide the sung overlay, wait for layout.
            hideMainWordGlyphLayers()
            hidePerRunSweepMaskLayers()
            mainBrightTextLayer.mask = nil
            mainBrightTextLayer.string = nil
            mainBrightTextLayer.isHidden = true
            mainTextLayer.setAffineTransform(.identity)
            mainBrightTextLayer.setAffineTransform(.identity)
            wordFloatResult = .inactive
            let layoutResult = lastLineLayoutMetrics
            return MainTextPhaseAppliedMetrics(
                progress: 0,
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
        // Floor already pinned above (before the per-glyph pass, with the same "still inside the
        // line ⇒ force 1" guard) when geometryReady; the non-geometry-ready branch returns early
        // and never reaches here, so this is a no-op re-assertion in that case, kept as a safety
        // net if a future call path reaches this line without having gone through the pin above.
        let mainLineEndSafetyNet = plan.wordRuns.last?.endTime ?? currentTime
        if currentTime <= mainLineEndSafetyNet {
            mainPostLineFadeFloor = 1
        } else {
            mainPostLineFadeFloor = min(mainPostLineFadeFloor, plan.mainPostLineFade)
        }
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
        // feel/emphasis v28/amll (2026-09-17): emphasis words are folded into the per-glyph tile
        // pipeline (applyMainWordFloatGlyphLayers, above) instead of the separate emphasisGlyphLayers
        // pool. Forcing an empty emphasisOrders set here routes through applyEmphasisGlyphLayers'
        // own existing "no emphasis words" early-out, which already hides that pool correctly.
        let tilesOwnEmphasis = !emphasisOrders.isEmpty && NativeLyricsFeelParity.emphasisMode != .current
        let emphasisResult = applyEmphasisGlyphLayers(
            plan: plan,
            currentTime: currentTime,
            linePlan: linePlan,
            emphasisOrders: tilesOwnEmphasis ? [] : emphasisOrders,
            managesContainerText: !geometryReady
        )
        if tilesOwnEmphasis {
            // The per-glyph tile pipeline already rendered this line's emphasis glow on/beside each
            // glyph's own tile. A shadow painted on the WHOLE-LINE mainBrightTextLayer here too would
            // be a second, independently-positioned glow source — the exact class of ghost this arm
            // exists to eliminate — so it must stay clean.
            clearEmphasis(from: mainBrightTextLayer)
        } else if emphasisResult.applied {
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
        leaveSinglePassActiveLine()
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
        activeFloatingHiddenSignature = nil
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
        // Same "still inside the line ⇒ force 1" guard as `mainPostLineFadeFloor` above (same
        // founder-flagged trade-off documented there) — a transient bad clock read past this
        // line's own end must not permanently crush the translation overlay either.
        if translation.currentTime <= translation.lineEndTime {
            translationPostLineFadeFloor = 1
        } else {
            translationPostLineFadeFloor = min(translationPostLineFadeFloor, translation.postLineFade)
        }
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
                    displayText: plan.displayText,
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

    /// Sweep-ghost fix: keeps `mainTextLayer` as the ONE laid-out whole-line string (so wrap-line
    /// height/tracking never change on activation — the 08-27 constraint pinned by
    /// NativeLyricsActiveLineSpacingTests) while making the glyph ranges of currently-displaced
    /// words transparent in it — ordinary words floating by `baseFloatY`, AND (as of 2026-09-14)
    /// emphasis words whose scale/lift/float animation is actively moving them. Those words'
    /// visible dim ink then comes ONLY from the per-glyph dim tile in
    /// `applyMainWordFloatGlyphLayers` (ordinary words) or the emphasis glyph layer in
    /// `applyEmphasisGlyphLayers` (emphasis words) — eliminating the second, undisplaced copy
    /// underneath (the reported double image, both on swept CJK glyphs and on emphasized English
    /// words like "about"). Gated by a signature so this only rewrites the string when the set of
    /// floating words actually changes (once per word boundary), not every frame.
    private func applyFloatingHiddenBase(
        plan: NativeLyricsTextRenderPlan,
        floatingOrders: Set<Int>
    ) {
        let signature = floatingOrders.isEmpty
            ? "\(plan.displayText)|float|"
            : "\(plan.displayText)|float|\(floatingOrders.sorted().map(String.init).joined(separator: ","))"
        guard activeFloatingHiddenSignature != signature else { return }
        activeFloatingHiddenSignature = signature
        guard !floatingOrders.isEmpty else {
            if let wholeLineMainString {
                mainTextLayer.string = wholeLineMainString
            }
            return
        }
        // Hidden ranges are computed against the RAW (unwrapped) displayText — matches
        // NativeLyricsHiddenTextMask's assumption that displayText is exactly the concatenation of
        // word-run texts. Re-wrap the result with the SAME wrap points `wholeLineMainString` used
        // (from `configuration`'s known width — never bounds.width, which can be stale/zero) so the
        // 08-27 constraint (wrap-line count / height / tracking never change on activation) holds.
        let hiddenRaw = attributedText(
            plan.displayText,
            fontSize: plan.constants.mainFontSize,
            alpha: 1,
            hiddenOrders: floatingOrders,
            wordRuns: plan.wordRuns
        )
        guard let configuration else {
            mainTextLayer.string = hiddenRaw
            return
        }
        mainTextLayer.string = Self.attributedDisplayWrapped(
            hiddenRaw,
            rawText: plan.displayText,
            width: contentTextWidth(configuration),
            font: .systemFont(ofSize: plan.constants.mainFontSize, weight: .semibold)
        )
    }

    // MARK: - Single-pass active line (v2.8 model)

    /// 2026-09-20 line-switch hitch (tick probe: the activation frame cost 5–9ms + 2 dropped
    /// frames): the surface calls this on the row AFTER the active one every tick, so the next
    /// line's layout, run bitmaps and layers exist before activation; the activation frame only
    /// toggles visibility and positions cached images.
    func prewarmSinglePassIfNeeded() {
        guard let row, let configuration,
              row.displayLine.line.hasSyllableSync,
              NativeLyricsFeelParity.activeLineRenderer == .singlePass else { return }
        let width = contentTextWidth(configuration)
        guard width > 1 else { return }
        let prewarmKey = "\(row.id)|\(width)"
        guard singlePassPrewarmKey != prewarmKey else { return }
        singlePassPrewarmKey = prewarmKey
        let plan = textRenderPlan(row: row, configuration: configuration)
        let linePlan = mainSweepLinePlan(for: plan, bounds: CGRect(x: 0, y: 0, width: width, height: max(1, mainTextLayer.bounds.height)))
        var runs: [(charRange: NSRange, rect: CGRect)] = []
        for line in linePlan {
            for visualRun in line.runs {
                guard let first = visualRun.glyphs.first, let last = visualRun.glyphs.last else { continue }
                runs.append((NSRange(location: first.characterIndex, length: last.characterIndex - first.characterIndex + 1), visualRun.rect))
            }
        }
        activeLineDrawLayer.prewarm(text: plan.displayText, width: width, fontSize: plan.constants.mainFontSize, runs: runs)
    }

    private func leaveSinglePassActiveLine() {
        guard singlePassActive else { return }
        singlePassActive = false
        activeLineDrawLayer.isHidden = true
        mainTextLayer.isHidden = false
    }

    private func applySinglePassActiveLine(
        plan: NativeLyricsTextRenderPlan,
        currentTime: TimeInterval,
        linePlan: [NativeLyricsTextSweepVisualLinePlan],
        sweepBounds: CGRect
    ) -> MainTextPhaseAppliedMetrics {
        let __t0 = CFAbsoluteTimeGetCurrent(); defer { NativeLyricsSurfaceView.tickPhaseAccum["applySinglePassActiveLine", default: 0] += (CFAbsoluteTimeGetCurrent() - __t0) * 1000 }
        singlePassActive = true
        // Everything the tile path would have shown is off: one layer owns the active line.
        if mainTextLayer.string == nil, let wholeLineMainString { mainTextLayer.string = wholeLineMainString }
        mainTextLayer.isHidden = true
        mainBrightTextLayer.isHidden = true
        mainBrightTextLayer.mask = nil
        hideMainWordGlyphLayers()
        hideEmphasisGlyphLayers()
        hidePerRunSweepMaskLayers()
        hideBaseRevealMaskLayers()
        activeHiddenEmphasisSignature = nil
        activeFloatingHiddenSignature = nil
        activeLineDrawLayer.isHidden = false
        activeLineDrawLayer.frame = mainTextLayer.frame

        // Karaoke post-line fade floor: inside the line's own span the overlay is always fully
        // lit; it only ratchets down after the last word ends (2026-09-19 founder-verified rule).
        let mainLineEnd = plan.wordRuns.last?.endTime ?? currentTime
        if currentTime <= mainLineEnd {
            mainPostLineFadeFloor = 1
        } else {
            mainPostLineFadeFloor = min(mainPostLineFadeFloor, plan.mainPostLineFade)
        }

        activeLineDrawLayer.prepareLayout(
            text: plan.displayText,
            width: sweepBounds.width,
            fontSize: plan.constants.mainFontSize
        )
        let maskLines = NativeLyricsTextSweepLayout.maskLines(
            from: linePlan,
            fadeHalfPoint: plan.constants.fadeHalfPoint,
            currentTime: currentTime
        )
        var runs: [NativeLyricsActiveLineDrawLayer.RunInput] = []
        for (lineIndex, line) in linePlan.enumerated() {
            for visualRun in line.runs {
                guard let first = visualRun.glyphs.first, let last = visualRun.glyphs.last else { continue }
                let charRange = NSRange(location: first.characterIndex, length: last.characterIndex - first.characterIndex + 1)
                let wordRun = visualRun.order < plan.wordRuns.count ? plan.wordRuns[visualRun.order] : nil
                let emphasis = wordRun?.emphasis ?? .inactive
                let isEmphasis = wordRun.map { $0.isEmphasis || $0.emphasis != .inactive } ?? false
                runs.append(.init(
                    lineIndex: lineIndex,
                    charRange: charRange,
                    rect: visualRun.rect,
                    floatY: wordRun?.baseFloatY ?? 0,
                    isEmphasis: isEmphasis,
                    scale: isEmphasis ? emphasis.scale : 1,
                    liftY: isEmphasis ? emphasis.liftY : 0,
                    glowOpacity: isEmphasis ? emphasis.glowOpacity : 0,
                    glowRadius: isEmphasis ? min(0.3 * plan.constants.mainFontSize, emphasis.blurLevel * 0.3 * plan.constants.mainFontSize) : 0
                ))
            }
        }
        let lines = maskLines.map { NativeLyricsActiveLineDrawLayer.LineInput(maskRect: $0.maskRect, wavefrontX: $0.wavefrontX) }
        // Dim alpha rides the same compensated channel the whole-line base uses (0.35 tier ÷ row
        // opacity), so brightness stays continuous across the activation spring.
        let dimAlpha = CGFloat(mainTextLayer.opacity)
        activeLineDrawLayer.update(.init(
            runs: runs,
            lines: lines,
            dimAlpha: dimAlpha,
            brightAlpha: plan.constants.brightAlpha * mainPostLineFadeFloor,
            fadeHalfPoint: plan.constants.fadeHalfPoint
        ))
        return MainTextPhaseAppliedMetrics(
            progress: plan.mainSweepProgress,
            appliedPerRunSweep: true,
            appliedBaseReveal: false,
            appliedPerGlyphEmphasis: runs.contains { $0.isEmphasis },
            expectedEmphasisGlyphCount: 0,
            appliedEmphasisGlyphCount: 0,
            appliedEmphasisGlyphMotionCount: 0,
            maxAppliedEmphasisScale: runs.map(\.scale).max() ?? 1,
            maxAppliedEmphasisLiftMagnitude: runs.map { abs($0.liftY) }.max() ?? 0,
            maxAppliedEmphasisGlowOpacity: runs.map(\.glowOpacity).max() ?? 0,
            maxAppliedEmphasisAlpha: plan.constants.brightAlpha * mainPostLineFadeFloor,
            textLayoutCoverageGapCount: 0,
            expectedSweepLineCount: linePlan.count,
            appliedSweepLineCount: lines.count,
            sweepLineCoverageGapCount: max(0, linePlan.count - lines.count),
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
            lineLayoutSampleCount: 0,
            lineLayoutHeightErrorMax: 0,
            lineLayoutWidthErrorMax: 0,
            mainTextFrameHeightErrorMax: 0,
            translationTextFrameHeightErrorMax: 0,
            mainWordFloatSampleCount: 0,
            mainWordFloatSpread: 0
        )
    }

    private func restoreMainTextIfNeeded(plan: NativeLyricsTextRenderPlan) {
        guard activeHiddenEmphasisSignature != nil else { return }
        activeHiddenEmphasisSignature = nil
        activeFloatingHiddenSignature = nil
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

    private struct EmphasisGlowBitmapKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let blurRadius: CGFloat
    }

    // Offline (non-resident) blurred glyph bitmaps for the feel/emphasis `amll` arm. Rendered ONCE
    // per (text, fontSize, blurRadius) and cached — never attached as a live `layer.filters` CIFilter
    // (banned-patterns.md: a stored CIFilter's mutated inputRadius is silently ignored by the render
    // server; a fresh instance per change is required, but a fresh instance EVERY FRAME is the
    // resident-blur WindowServer cost this arm exists to avoid). Assigning a cached CGImage to
    // `layer.contents` costs nothing to composite while the layer sits hidden between emphasis words.
    private static var emphasisGlowBitmapCache: [EmphasisGlowBitmapKey: (image: CGImage, size: CGSize)] = [:]
    private static let emphasisGlowCIContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func emphasisGlowBitmap(
        text: String, fontSize: CGFloat, blurRadius: CGFloat
    ) -> (image: CGImage, size: CGSize)? {
        guard blurRadius > 0.05, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // Blur radius is a smooth per-frame ramp, not a discrete set of values; round to the nearest
        // 0.5pt (visually indistinguishable) so the cache stays small across a whole emphasis window.
        let roundedRadius = (blurRadius * 2).rounded() / 2
        let key = EmphasisGlowBitmapKey(text: text, fontSize: fontSize, blurRadius: roundedRadius)
        if let cached = emphasisGlowBitmapCache[key] { return cached }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let glyphSize = attributed.size()
        guard glyphSize.width > 0, glyphSize.height > 0 else { return nil }
        // Pad for the blur's spread so it is not clipped at the bitmap edge.
        let pad = ceil(roundedRadius * 3)
        let canvasSize = CGSize(width: glyphSize.width + pad * 2, height: glyphSize.height + pad * 2)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = max(1, Int((canvasSize.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((canvasSize.height * scale).rounded(.up)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: CGPoint(x: pad, y: pad))
        NSGraphicsContext.restoreGraphicsState()
        guard let sharpImage = context.makeImage() else { return nil }
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(CIImage(cgImage: sharpImage), forKey: kCIInputImageKey)
        filter.setValue(roundedRadius * scale, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let cgImage = emphasisGlowCIContext.createCGImage(
                output, from: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
              )
        else { return nil }
        let result = (image: cgImage, size: canvasSize)
        emphasisGlowBitmapCache[key] = result
        return result
    }

    /// v2.8 per-word cascade: draw every NON-emphasis word as per-glyph layers floated by that word's
    /// own `baseFloatY`. The dim glyphs (always visible) parent to `mainTextLayer`; the bright glyphs
    /// parent to `mainBrightTextLayer` and so inherit the sweep mask — brightness stays a smooth
    /// gradient and the 2pt float never shifts the horizontal wavefront. Position carries the float
    /// (scale stays 1 → no top-clip).
    ///
    /// Emphasis words: under the `current` feel/emphasis arm they are skipped here entirely — they
    /// keep their own separate scale/glow glyph layers (`applyEmphasisGlyphLayers`), so the two
    /// partitions cover the line without overlap or gap. Under `v28`/`amll` (2026-09-17, founder-
    /// approved contrast arm for the emphasis ghost, research/repro-2026-09-17-lyrics-render-3c.md
    /// §B) emphasis words are folded INTO this same per-glyph tile instead — one positioned object
    /// per glyph, never two — with the intensification (scale/lift) applied as an extra transform on
    /// that SAME bright tile, and the glow rendered either as a real shadow on that same tile (`v28`)
    /// or a position-copied blurred-bitmap sibling (`amll`); see `applyEmphasisGlyphOnSharedTile`.
    private func applyMainWordFloatGlyphLayers(
        plan: NativeLyricsTextRenderPlan,
        currentTime: TimeInterval,
        linePlan: [NativeLyricsTextSweepVisualLinePlan],
        emphasisOrders: Set<Int>,
        floatsDimBase: Bool,
        floatingOrders: Set<Int> = []
    ) -> MainWordFloatAppliedMetrics {
        let floats = plan.perWordFloatY(at: currentTime)
        let tilesOwnEmphasis = !emphasisOrders.isEmpty && NativeLyricsFeelParity.emphasisMode != .current
        struct Input {
            let glyph: NativeLyricsTextSweepVisualRun.Glyph
            let floatY: CGFloat
            let isFloatingWord: Bool
            let emphasis: EmphasisGlyphExpectedMetrics?
        }
        var inputs: [Input] = []
        for line in linePlan {
            let wavefront = tilesOwnEmphasis
                ? NativeLyricsTextSweepLayout.wavefrontX(
                    for: line, fadeHalfPoint: plan.constants.fadeHalfPoint, currentTime: currentTime
                  )
                : 0
            for run in line.runs where tilesOwnEmphasis || !emphasisOrders.contains(run.order) {
                let floatY = run.order < floats.count ? floats[run.order] : 0
                // `floatsDimBase` (the `layer` A/B arm) always tessellates every non-emphasis word as
                // a dim tile. The default (whole-line dim base) arm shows a dim tile ONLY for a word
                // that is actually floating — `applyFloatingHiddenBase` blanks that same word's range
                // out of the whole-line string, so exactly one visible copy of the glyph exists, at
                // the SAME floated position as the bright tile (no ghost).
                let isFloatingWord = floatsDimBase || floatingOrders.contains(run.order)
                let isEmphasisRun = tilesOwnEmphasis && emphasisOrders.contains(run.order) && run.order < plan.wordRuns.count
                if isEmphasisRun {
                    let wordRun = plan.wordRuns[run.order]
                    let glyphCount = max(1, run.glyphs.count)
                    let duration = max(0, wordRun.endTime - wordRun.startTime)
                    let du = max(1.0, duration) * (run.order == plan.wordRuns.count - 1 ? 1.2 : 1.0)
                    for glyph in run.glyphs {
                        let expected = expectedEmphasisGlyphMetrics(
                            glyph: glyph, run: wordRun, glyphCount: glyphCount, du: du,
                            wavefrontX: wavefront, fadeHalfPoint: plan.constants.fadeHalfPoint,
                            brightAlpha: plan.constants.brightAlpha * plan.mainPostLineFade,
                            dimAlpha: dimBaseEffectiveAlpha(), currentTime: currentTime
                        )
                        inputs.append(Input(glyph: glyph, floatY: floatY, isFloatingWord: isFloatingWord, emphasis: expected))
                    }
                } else {
                    for glyph in run.glyphs {
                        inputs.append(Input(glyph: glyph, floatY: floatY, isFloatingWord: isFloatingWord, emphasis: nil))
                    }
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
            let isFloatingWord = input.isFloatingWord
            let dimLayer = mainDimWordGlyphLayers[index]
            let brightLayer = mainBrightWordGlyphLayers[index]
            let glowLayer = mainEmphasisGlowLayers[index]
            dimLayer.isHidden = !isFloatingWord
            brightLayer.isHidden = false
            // 2026-09-20 (3p): pull the SAME concrete font the shared NSLayoutManager already
            // resolved for THIS character, instead of an independently re-derived generic system
            // font — see `resolvedGlyphFont`'s doc comment for the founder-reported real-device
            // root cause (persistent double-edge ghost on every swept CJK glyph).
            let resolvedFont = resolvedGlyphFont(text: plan.displayText, characterIndex: glyph.characterIndex, fallbackSize: fontSize)
            let signature = EmphasisGlyphLayerSignature(
                glyph: glyph,
                fontSize: fontSize,
                brightAlpha: plan.constants.brightAlpha,
                fontName: resolvedFont.fontName
            )
            if mainWordGlyphLayerSignatures.indices.contains(index),
               mainWordGlyphLayerSignatures[index] != signature {
                mainWordGlyphLayerSignatures[index] = signature
                // CATextLayer clips text tight to its bounds — at exactly glyph.rect.size the bottom
                // ink of CJK strokes / descenders is shaved (same trap the whole-line layer pads
                // around). The view is flipped (y-down), so glyph.rect.minY is the top: extend the box
                // DOWNWARD by textBottomClipPad (keeping the top edge fixed) for room below the glyph.
                // Always write BOTH layers here (even though the dim tile may render hidden this
                // frame): the dim tile can become visible on a LATER frame without this signature
                // changing (same glyph/size/alpha/font), and it must already carry the right
                // text/color/font.
                for layer in [dimLayer, brightLayer] {
                    layer.string = glyph.text
                    layer.font = resolvedFont
                    layer.fontSize = fontSize
                    layer.bounds = CGRect(
                        origin: .zero,
                        size: CGSize(width: glyph.rect.width, height: glyph.rect.height + Self.textBottomClipPad)
                    )
                }
                dimLayer.foregroundColor = dimColor
                brightLayer.foregroundColor = brightColor
                debugWordGlyphColorAssignCount += 2
            }
            // Center sits pad/2 below the glyph midY so the taller box keeps its TOP at glyph.rect.minY
            // (text stays exactly where the whole-line layer drew it; only the bottom gains room).
            // The dim tile floats in lockstep with the bright tile whenever it is the one standing in
            // for the (now-blanked) whole-line glyph — otherwise it sits at rest, coincident with the
            // whole-line copy that is still showing through (floatY == 0 there anyway).
            let padHalf = Self.textBottomClipPad / 2
            let dimCenterY = glyph.rect.midY + padHalf + (isFloatingWord ? input.floatY : 0)
            dimLayer.position = CGPoint(x: glyph.rect.midX, y: dimCenterY)
            if let emphasis = input.emphasis {
                // v28/amll: the emphasis position formula already includes baseFloatY + the per-
                // glyph cascade (charFloat/liftY/spreadX) — apply it directly to THIS tile instead of
                // the plain `floats[order]` float, and add the intensification scale as a transform
                // on the SAME object, so it is geometrically impossible for the glow/scale to land
                // anywhere but exactly where the sharp glyph itself is.
                brightLayer.position = CGPoint(x: emphasis.position.x, y: emphasis.position.y + padHalf)
                brightLayer.setAffineTransform(CGAffineTransform(scaleX: emphasis.scale, y: emphasis.scale))
                applyEmphasisGlowOnSharedTile(
                    brightLayer: brightLayer, glowLayer: glowLayer, glyph: glyph,
                    fontSize: fontSize, expected: emphasis
                )
            } else {
                brightLayer.position = CGPoint(x: glyph.rect.midX, y: glyph.rect.midY + padHalf + input.floatY)
                if brightLayer.affineTransform() != .identity { brightLayer.setAffineTransform(.identity) }
                if brightLayer.shadowOpacity != 0 {
                    brightLayer.shadowOpacity = 0
                    brightLayer.shadowRadius = 0
                }
                glowLayer.isHidden = true
                // 2026-09-18 instrumentation (stage bundle 3g item 3, research/repro-2026-09-18-
                // lyrics-render-3g.md): a genuine repro attempt for the founder's "CJK trailing
                // glyph ghost" found the DIM/BRIGHT tile pair always position-matched in every
                // synthetic scenario tried — but this line is the one place they could legitimately
                // desync: `dimLayer`'s Y only adds `input.floatY` when `isFloatingWord` (line 2862's
                // `!isFloatingWord` gate, using `floatingOrders` computed from `run.baseFloatY` in
                // `applyActiveMainPhase`), while `brightLayer`'s Y ALWAYS adds `input.floatY`
                // (`plan.perWordFloatY(at:)`, a separately-evaluated quantity). If those two float
                // sources ever disagree on WHETHER a word counts as "floating" while both still
                // report a nonzero `floatY` for it, the bright tile visibly floats away from its dim
                // twin while `dimLayer.isHidden` stays false (both visible, offset) — exactly the
                // reported "same character with a blurred duplicate offset down-right" shape. Not
                // reproduced synthetically; this records the specific desync condition on-device so
                // the next real-occurrence session has evidence instead of another blind repro
                // attempt. Shares NativeLyricsMaskTrace's isArmed gate/output file — zero I/O by
                // default, same discipline as every other production-safe probe in this file.
                if !isFloatingWord, input.floatY != 0 {
                    NativeLyricsMaskTrace.recordWordFloatDesync(
                        rowID: row?.displayLine.id ?? "?",
                        glyphIndex: index,
                        glyphText: glyph.text,
                        floatY: input.floatY
                    )
                }
            }
            let appliedFloat = brightLayer.position.y - glyph.rect.midY - padHalf
            minFloat = min(minFloat, appliedFloat)
            maxFloat = max(maxFloat, appliedFloat)
        }
        for index in inputs.count..<mainDimWordGlyphLayers.count {
            mainDimWordGlyphLayers[index].isHidden = true
            mainBrightWordGlyphLayers[index].isHidden = true
            mainEmphasisGlowLayers[index].isHidden = true
        }
        return MainWordFloatAppliedMetrics(
            sampleCount: inputs.count,
            floatSpread: maxFloat - minFloat
        )
    }

    /// Applies the `v28`/`amll` glow treatment to an emphasis glyph that is sharing the ordinary
    /// per-word bright tile (never a second independently-positioned layer). `v28`: a real
    /// `CALayer.shadow*` on `brightLayer` itself — cannot desync because it IS that layer. `amll`: a
    /// pre-rendered blurred-bitmap sibling (`glowLayer`) whose position/transform are copied from
    /// `brightLayer` in this SAME call (never computed independently), opacity riding
    /// `expected.glowOpacity`, mounted only while that glyph is inside its emphasis window.
    private func applyEmphasisGlowOnSharedTile(
        brightLayer: CATextLayer,
        glowLayer: CALayer,
        glyph: NativeLyricsTextSweepVisualRun.Glyph,
        fontSize: CGFloat,
        expected: EmphasisGlyphExpectedMetrics
    ) {
        switch NativeLyricsFeelParity.emphasisMode {
        case .current:
            glowLayer.isHidden = true
        case .v28:
            glowLayer.isHidden = true
            if expected.glowOpacity > 0.001 {
                brightLayer.shadowColor = NSColor.white.cgColor
                brightLayer.shadowOpacity = Float(min(1, expected.glowOpacity))
                brightLayer.shadowRadius = expected.shadowRadius
                brightLayer.shadowOffset = .zero
            } else {
                brightLayer.shadowOpacity = 0
                brightLayer.shadowRadius = 0
            }
        case .amll:
            if brightLayer.shadowOpacity != 0 {
                brightLayer.shadowOpacity = 0
                brightLayer.shadowRadius = 0
            }
            guard expected.glowOpacity > 0.001,
                  let bitmap = Self.emphasisGlowBitmap(text: glyph.text, fontSize: fontSize, blurRadius: expected.shadowRadius)
            else {
                glowLayer.isHidden = true
                return
            }
            glowLayer.isHidden = false
            glowLayer.contents = bitmap.image
            glowLayer.bounds = CGRect(origin: .zero, size: bitmap.size)
            // Position/transform are COPIED from the sharp tile that was just written above — the
            // sibling can never be independently wrong because it never computes its own position.
            glowLayer.position = brightLayer.position
            glowLayer.setAffineTransform(brightLayer.affineTransform())
            glowLayer.opacity = Float(min(1, expected.glowOpacity))
        }
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
            // Glow sibling for the amll arm — inserted BELOW its bright tile so the sharp glyph
            // always paints on top of its own soft halo. contents-only layer (a pre-rendered
            // bitmap image, never a live CIFilter), so it costs nothing to composite while hidden.
            let glowLayer = CALayer().lyricsInert()
            glowLayer.contentsScale = scale
            glowLayer.masksToBounds = false
            glowLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            glowLayer.isHidden = true
            mainBrightTextLayer.insertSublayer(glowLayer, below: brightLayer)
            mainEmphasisGlowLayers.append(glowLayer)
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
        for layer in mainEmphasisGlowLayers {
            layer.isHidden = true
            layer.shadowOpacity = 0
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
        displayText: String,
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
        // 2026-09-20 (3p): same fix as the main word-tile pool — pull the concrete font the
        // shared layout already resolved for this character (see `resolvedGlyphFont`'s doc).
        let resolvedFont = resolvedGlyphFont(text: displayText, characterIndex: glyph.characterIndex, fallbackSize: fontSize)
        let signature = EmphasisGlyphLayerSignature(
            glyph: glyph, fontSize: fontSize, fontName: resolvedFont.fontName
        )
        if emphasisGlyphLayerSignatures.indices.contains(layerIndex),
           emphasisGlyphLayerSignatures[layerIndex] != signature {
            emphasisGlyphLayerSignatures[layerIndex] = signature
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer.font = resolvedFont
            layer.fontSize = fontSize
            layer.string = glyph.text
            layer.bounds = CGRect(origin: .zero, size: glyph.rect.size)
        } else if layer.string == nil {
            layer.font = resolvedFont
            layer.fontSize = fontSize
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
        let __t0 = CFAbsoluteTimeGetCurrent(); defer { NativeLyricsSurfaceView.tickPhaseAccum["mainSweepLinePlan", default: 0] += (CFAbsoluteTimeGetCurrent() - __t0) * 1000 }
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
            isActive: NativeLyricsTextActivation.isLineTextActive(
                rowIndex: row.index,
                textActiveIndex: configuration.effectiveTextActiveIndex
            ),
            staticOpacity: 1,
            showTranslation: configuration.showTranslation,
            wordFloatReleaseTime: configuration.nativeWordFloatReleaseTime
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
        // 2026-09-20 (founder screen recording: "切行时字突然变粗"): CATextLayer's own CJK
        // fallback and NSLayoutManager's fallback pick DIFFERENT PingFang variants, so a row's
        // weight jumped the moment it switched between the whole-line base and the active-line
        // bitmaps. Resolve the concrete per-character font here (same `fixAttributes` AppKit's
        // layout performs) so every path draws the identical font.
        let storage = NSTextStorage(string: text, attributes: attributes)
        storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
        return NSAttributedString(attributedString: storage)
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
