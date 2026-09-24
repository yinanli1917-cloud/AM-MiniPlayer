import Foundation

/**
 * [INPUT]: Depends on BackdropLegibilityBand's channel-correct WCAG primitives (RGBColor,
 *          relativeLuminance, whiteContrastRatio(relativeLuminance:), resolveChannelCorrect)
 *          and ArtworkBackgroundToneMap (FluidGradientBackground.swift) — the same tone chain
 *          MiniPlayerView's fullscreen Layer 1 (blurred backing image) already renders.
 * [OUTPUT]: Exports FullscreenBottomBandLegibility — a pure function that decides, for the
 *           fullscreen album page's bottom band ONLY, (1) whether the hero-cover fade needs to
 *           extend further up the screen so the real title/shuffle-repeat/controls sit over
 *           Layer 1 instead of the sharp cover, and (2) how much extra darkening Layer 1's OWN
 *           tone controls (brightness / dimming overlay) need on top, so a white foreground at
 *           those positions reaches >= 4.5:1 contrast. Produces absolute parameter VALUES
 *           (blendHeight, Layer 1 brightness/dim opacity, mask-gradient stops) that
 *           MiniPlayerView hands straight to its EXISTING `.brightness()` / `.overlay()` /
 *           `LinearGradient` calls — no new view types, no new resident filters.
 * [POS]: Sibling to BackdropLegibilityBand.swift; point-B-only (fullscreen album bottom band).
 *        Consumed by MiniPlayerView.floatingArtwork's fullscreen branch. A rejected point-B
 *        design (black/tinted scrim + stacked progressive blur) previously lived in
 *        BackdropLegibilityBand.swift and was removed 2026-09-23 (commit b58b4e6) after the
 *        founder rejected it for burying his hand-tuned look — see
 *        research/progressive-blur-2026-09-23.md. This file extends that hand-tuned design
 *        (moves ITS OWN fade + darkens ITS OWN Layer 1) instead of adding anything on top.
 */
public enum FullscreenBottomBandLegibility {

    // MARK: - Critical text/control positions
    //
    // Distance above the window's BOTTOM edge (device points) of the highest real foreground
    // element in each of MiniPlayerView.albumOverlayContent's two mutually-exclusive states
    // (hover vs non-hover). Derived directly from that view's own layout constants — never a
    // hand-measured pixel offset — so these can't silently drift out of sync with the layout:
    // `.position(x:y:)` centres a view at its anchor, so the visual TOP of a text row sits
    // `textTopSafetyMargin` above the anchor (an approximation of half the row's rendered
    // line-height, since SwiftUI gives no other way to ask for it purely).

    /// Matches `albumOverlayContent`'s and `floatingArtwork`'s own local `controlsHeight`.
    public static let controlsHeight: Double = 80
    /// `shuffleRepeatCluster` row's `.padding(.bottom, 4)`.
    public static let shuffleRowBottomPadding: Double = 4
    /// `shuffleRepeatCluster`'s button size (`.frame(width: 24, height: 24)`).
    public static let shuffleRowHeight: Double = 24
    /// Hover-mode title's `y` offset below `controlsHeight`: `4 + 16`.
    public static let hoverTitleBottomOffset: Double = 4 + 16
    /// Non-hover fullscreen title's `y` offset from the bottom edge: `12 + 18 + 8`.
    public static let nonHoverTitleBottomOffset: Double = 12 + 18 + 8
    /// Non-hover fullscreen artist's `y` offset from the bottom edge: `12 + 8`.
    public static let nonHoverArtistBottomOffset: Double = 12 + 8
    /// Approximates the text row's rendered height above its `.position()` anchor.
    public static let textTopSafetyMargin: Double = 8

    public static var hoverTitleTopDistance: Double { controlsHeight + hoverTitleBottomOffset + textTopSafetyMargin }
    public static var shuffleRowTopDistance: Double { controlsHeight + shuffleRowBottomPadding + shuffleRowHeight + textTopSafetyMargin }
    public static var nonHoverTitleTopDistance: Double { nonHoverTitleBottomOffset + textTopSafetyMargin }
    public static var nonHoverArtistTopDistance: Double { nonHoverArtistBottomOffset + textTopSafetyMargin }

    /// All four positions a white foreground must stay legible at — hover and non-hover are
    /// mutually exclusive on screen, but the correction is computed once per artwork change
    /// (not per hover toggle), so it must cover whichever state is showing.
    public static var criticalTextTopDistances: [Double] {
        [hoverTitleTopDistance, shuffleRowTopDistance, nonHoverTitleTopDistance, nonHoverArtistTopDistance]
    }

    /// `MiniPlayerView.floatingArtwork`'s existing fixed `blendHeight` — the baseline this
    /// correction only ever extends, never shrinks.
    public static let baselineBlendHeight: Double = 100

    // MARK: - Correction result

    /// Absolute parameter values ready to hand to MiniPlayerView's EXISTING modifiers.
    /// `needsCorrection == false` means every value here reproduces the ORIGINAL 62877a4
    /// rendering exactly (`blendHeight == baselineBlendHeight`, Layer 1's brightness/dim
    /// opacity unchanged) — in-band and dark covers must always hit this branch.
    public struct Correction: Equatable {
        public let needsCorrection: Bool
        /// Total height of the hero-cover mask region (device points).
        public let blendHeight: CGFloat
        /// Height, from the bottom edge, over which the sharp cover is FULLY hidden (mask
        /// visibility 0) — covers every `criticalTextTopDistances` entry when correction is
        /// needed; 0 when it is not.
        public let hiddenCoverHeight: Double
        /// Height of the eased ramp ABOVE `hiddenCoverHeight` back to fully showing the cover.
        public let fadeHeight: Double
        /// Value for the existing `.brightness(tone.textureBrightness)` call on Layer 1.
        public let layer1Brightness: Double
        /// Value for the existing `.overlay(Color.black.opacity(tone.textureDimmingOpacity))`
        /// call on Layer 1.
        public let layer1DimOpacity: Double

        public init(needsCorrection: Bool, blendHeight: CGFloat, hiddenCoverHeight: Double, fadeHeight: Double, layer1Brightness: Double, layer1DimOpacity: Double) {
            self.needsCorrection = needsCorrection
            self.blendHeight = blendHeight
            self.hiddenCoverHeight = hiddenCoverHeight
            self.fadeHeight = fadeHeight
            self.layer1Brightness = layer1Brightness
            self.layer1DimOpacity = layer1DimOpacity
        }

        static func unchanged(tone: ArtworkBackgroundToneMap) -> Correction {
            Correction(
                needsCorrection: false,
                blendHeight: CGFloat(baselineBlendHeight),
                hiddenCoverHeight: 0,
                fadeHeight: 0,
                layer1Brightness: tone.textureBrightness,
                layer1DimOpacity: tone.textureDimmingOpacity
            )
        }
    }

    // MARK: - Pure chain replicas (mirrors MiniPlayerView.floatingArtwork's fullscreen Layer 1)

    private static func applyContrast(_ x: Double, _ c: Double) -> Double { (x - 0.5) * c + 0.5 }
    private static func applyBrightness(_ x: Double, _ b: Double) -> Double { x + b }
    private static func applyBlackOverlay(_ x: Double, opacity: Double) -> Double { x * (1 - opacity) }

    /// Layer 1's own colour: `.contrast` -> `.brightness` -> `Color.black.opacity(dim)` overlay
    /// (no shade, no C5 — those are Point A only), per channel, with optional overrides for the
    /// brightness/dim parameters (used while solving the correction below).
    static func layer1Color(
        artworkAverageColor: BackdropLegibilityBand.RGBColor,
        tone: ArtworkBackgroundToneMap,
        brightnessOverride: Double? = nil,
        dimOpacityOverride: Double? = nil
    ) -> BackdropLegibilityBand.RGBColor {
        func channel(_ x: Double) -> Double {
            let x1 = applyContrast(x, tone.textureContrast)
            let x2 = applyBrightness(x1, brightnessOverride ?? tone.textureBrightness)
            return min(max(applyBlackOverlay(x2, opacity: dimOpacityOverride ?? tone.textureDimmingOpacity), 0), 1)
        }
        return BackdropLegibilityBand.RGBColor(
            r: channel(artworkAverageColor.r),
            g: channel(artworkAverageColor.g),
            b: channel(artworkAverageColor.b)
        )
    }

    /// The composite colour actually behind a point `distanceAboveBottom` device points above
    /// the bottom edge: `MiniPlayerView.floatingArtwork`'s hero-cover mask is a plain linear
    /// ramp over `blendHeight` (clear nearest the bottom edge, i.e. Layer 1 fully shows; black
    /// at the top of the ramp, i.e. the sharp cover fully shows), so the sharp cover's own
    /// visibility at that point is `min(distanceAboveBottom / blendHeight, 1)`.
    public static func compositeColor(
        distanceAboveBottom: Double,
        coverColor: BackdropLegibilityBand.RGBColor,
        layer1: BackdropLegibilityBand.RGBColor,
        blendHeight: Double
    ) -> BackdropLegibilityBand.RGBColor {
        let coverVisibility = blendHeight > 0 ? min(max(distanceAboveBottom / blendHeight, 0), 1) : 1
        return BackdropLegibilityBand.RGBColor(
            r: coverColor.r * coverVisibility + layer1.r * (1 - coverVisibility),
            g: coverColor.g * coverVisibility + layer1.g * (1 - coverVisibility),
            b: coverColor.b * coverVisibility + layer1.b * (1 - coverVisibility)
        )
    }

    // MARK: - The solve

    /// Resolves the full correction for a given cover. `needsCorrection` is driven by the
    /// ACTUAL band math: does any real text/control position fail the ceiling contrast TODAY
    /// (baseline `blendHeight`, baseline Layer 1 tone)? If not — in-band or a dark cover — every
    /// output reproduces the original rendering exactly.
    ///
    /// When correction IS needed:
    /// 1. The fade moves up: `hiddenCoverHeight` grows to cover every critical position, so the
    ///    sharp cover is completely replaced by Layer 1 there (no partial blend to reason about).
    /// 2. Layer 1's OWN tone (brightness/dim) darkens `resolveChannelCorrect`'s exact minimal
    ///    amount — zero if Layer 1 alone already clears the ceiling once the cover is hidden.
    static func resolve(
        artworkAverageColor: BackdropLegibilityBand.RGBColor,
        coverBottomRowColor: BackdropLegibilityBand.RGBColor,
        tone: ArtworkBackgroundToneMap,
        ceilingContrast: Double = MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast,
        fadeHeight: Double = Double(MicroInteractionFeel.Tokens.fullscreenHeroFadeExtensionHeight)
    ) -> Correction {
        let baselineLayer1 = layer1Color(artworkAverageColor: artworkAverageColor, tone: tone)

        // Conservatively pick whichever of the average / bottom-row colour has the HIGHER
        // true relative luminance overall (not per-channel-independently, which could invent
        // an out-of-gamut hue) — same principle the removed point-B design used for its own
        // layer1-vs-cover conservatism. `coverBottomRowColor` comes from
        // `NSImage.controlAreaMaxColor()`, whose `CIAreaAverage` render path returns a
        // linear-light sample (its consumers have always compared it only against other
        // outputs of the SAME function, so this never showed up before): for a uniform
        // gamma-0.50 swatch it reports ~0.22, not ~0.50. Taking the max against the reliable
        // gamma-space `artworkAverageColor` means this pre-existing quirk in a shared,
        // out-of-scope utility can only make the gate MORE conservative, never silently
        // under-trigger for a genuinely bright cover.
        let averageLuminance = BackdropLegibilityBand.relativeLuminance(artworkAverageColor)
        let bottomRowLuminance = BackdropLegibilityBand.relativeLuminance(coverBottomRowColor)
        let effectiveCoverColor = averageLuminance >= bottomRowLuminance ? artworkAverageColor : coverBottomRowColor

        let needsCorrection = criticalTextTopDistances.contains { distance in
            let composite = compositeColor(
                distanceAboveBottom: distance, coverColor: effectiveCoverColor,
                layer1: baselineLayer1, blendHeight: baselineBlendHeight
            )
            let contrast = BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(composite))
            return contrast < ceilingContrast
        }

        guard needsCorrection else { return .unchanged(tone: tone) }

        // 1) Move the fade: hide the sharp cover completely behind every critical position.
        let hiddenCoverHeight = criticalTextTopDistances.max() ?? baselineBlendHeight
        let blendHeight = hiddenCoverHeight + fadeHeight

        // 2) Darken Layer 1 itself just enough (channel-correct) — zero if it's already there.
        let layer1Correction = BackdropLegibilityBand.resolveChannelCorrect(preCorrection: baselineLayer1, ceilingContrast: ceilingContrast)
        let foldedDimOpacity = 1 - (1 - tone.textureDimmingOpacity) * (1 - layer1Correction.darkenOpacity)
        // Brightness sits BEFORE the dim overlay in the chain, so a lift must be scaled up by
        // the overlay's own attenuation to land exactly right after it — same reasoning as
        // BackdropLegibilityBand.innerBrightnessDelta, folding into the SAME existing
        // `.brightness()` call rather than adding a new resident modifier.
        let brightnessDenominator = max(1 - tone.textureDimmingOpacity, 0.0001)
        let foldedBrightness = tone.textureBrightness
            + (layer1Correction.liftAmount > 0 ? layer1Correction.liftAmount / brightnessDenominator : 0)

        return Correction(
            needsCorrection: true,
            blendHeight: CGFloat(blendHeight),
            hiddenCoverHeight: hiddenCoverHeight,
            fadeHeight: fadeHeight,
            layer1Brightness: foldedBrightness,
            layer1DimOpacity: foldedDimOpacity
        )
    }

    // MARK: - Mask shape (for MiniPlayerView's existing LinearGradient)

    /// The hero-cover mask's visibility (0 = fully hidden -> Layer 1 shows; 1 = fully shown) at
    /// `distanceAboveBottom`, given a resolved `Correction`. When `needsCorrection` is false this
    /// reduces to the EXACT baseline linear ramp (`distanceAboveBottom / baselineBlendHeight`) —
    /// not the eased shape below — so an in-band/dark cover keeps the original 62877a4 look.
    /// When `needsCorrection` is true: 0 across the flat `hiddenCoverHeight` zone, smoothstep-
    /// eased 0->1 across `fadeHeight` above it, 1 beyond — C1-continuous at both boundaries (zero
    /// slope on both sides), so there is never a hard edge in the fade.
    public static func coverVisibility(distanceAboveBottom: Double, correction: Correction) -> Double {
        guard correction.needsCorrection else {
            return baselineBlendHeight > 0 ? min(max(distanceAboveBottom / baselineBlendHeight, 0), 1) : 1
        }
        let t = min(max((distanceAboveBottom - correction.hiddenCoverHeight) / max(correction.fadeHeight, 0.0001), 0), 1)
        return t * t * (3 - 2 * t) // smoothstep: eased(0)=0, eased(1)=1, zero slope at both ends
    }

    /// Densely samples `coverVisibility` into `LinearGradient`-ready stops — location 0 is the
    /// TOP of the mask region (`distanceAboveBottom == blendHeight`, matching the original
    /// gradient's `.black` stop at location 0), location 1 is the bottom edge (matching the
    /// original's `.clear` stop at location 1.0). Sampling a LINEAR function this way reproduces
    /// it exactly (linear interpolation between collinear points IS the same line), so the
    /// `needsCorrection == false` case renders byte-identically to the original 2-stop gradient
    /// without a separate code path — only the `true` case's curve actually differs in shape.
    public static func maskGradientStops(correction: Correction, sampleCount: Int = 24) -> [(location: Double, coverVisibility: Double)] {
        let totalHeight = Double(correction.blendHeight)
        guard totalHeight > 0, sampleCount > 1 else { return [(0, 1), (1, 0)] }
        return (0...sampleCount).map { i in
            let location = Double(i) / Double(sampleCount)
            let distanceAboveBottom = totalHeight * (1 - location)
            return (location, coverVisibility(distanceAboveBottom: distanceAboveBottom, correction: correction))
        }
    }
}
