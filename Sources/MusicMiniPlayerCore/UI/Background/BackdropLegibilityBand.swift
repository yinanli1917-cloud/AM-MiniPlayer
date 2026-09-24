import Foundation

/**
 * [INPUT]: Depends on ArtworkVisualMetrics / ArtworkBackgroundToneMap (FluidGradientBackground.swift)
 *          and ArtworkContrastPolicy.Resolution (MicroInteractionFeel.swift) as the tone-mapped
 *          inputs it predicts a background luminance from; no other module coupling.
 * [OUTPUT]: Exports BackdropLegibilityBand — a pure luminance-band correction (darken/lift) plus
 *           the analytic pipeline replicas (`fluidBackdropToneLuminance`,
 *           `fullscreenBottomBandToneLuminance`) that predict the on-screen background luminance
 *           at the two call sites, reused by both production code and tests. Also exports the
 *           point-B-only TINTED variant (`TintedCorrection`, `pointBTint`, `resolveTinted`,
 *           `applyTinted`, `bottomBandScrimGradientStops`) — research/progressive-blur-2026-09-23.md
 *           — which blends toward an artwork-derived dark tint instead of pure black.
 * [POS]: Shared legibility-band utility living alongside FluidGradientBackground.swift; consumed by
 *        FluidGradientBackground (point A, black-scrim model, unchanged) and MiniPlayerView's
 *        fullscreen album bottom band (point B, tinted-blend + progressive-blur model) to keep
 *        white foregrounds legible against any artwork-derived background.
 */

// research/spec-2026-09-22-backdrop-legibility.md — 背景明度带（Backdrop luminance band）.
//
// One rule, no per-control patching: any region where a white foreground sits on an
// artwork-derived background gets the SAME pure correction. Contrast is computed the
// WCAG way (sRGB linearized first, not the raw gamma value) against a fixed white
// (relative luminance 1.0) foreground:
//
//   contrast = (1.0 + 0.05) / (linearRelativeLuminance(background) + 0.05)
//
// - Ceiling: background must not be so bright that contrast drops below
//   `backdropLegibilityCeilingContrast` (4.5:1, WCAG AA body text). Above it, darken with
//   a black scrim down to exactly the ceiling.
// - Floor: background must not be so dark that contrast climbs above
//   `backdropLegibilityFloorContrast` (12:1) — a harsh floor is corrected by lifting the
//   background (hue-preserving `.brightness` addition, not a screen-white wash) down to
//   exactly the floor.
// - In-band: zero correction, byte-identical appearance.
//
// Both correction formulas solve for the EXACT boundary value, so `resolve` is continuous
// by construction: right at either boundary the correction is 0, and it grows smoothly as
// the background moves further out of band — never a hard step.
public enum BackdropLegibilityBand {
    /// The correction to layer on top of an already-computed background: `darkenOpacity`
    /// is a black scrim opacity (background too bright), `liftAmount` is a `.brightness`-style
    /// additive lift (background too dark). At most one is non-zero at a time.
    public struct Correction: Equatable {
        public let darkenOpacity: Double
        public let liftAmount: Double

        public static let zero = Correction(darkenOpacity: 0, liftAmount: 0)

        public init(darkenOpacity: Double, liftAmount: Double) {
            self.darkenOpacity = darkenOpacity
            self.liftAmount = liftAmount
        }
    }

    // MARK: - WCAG relative luminance (sRGB gamma <-> linear)

    /// sRGB EOTF: gamma-encoded component (0...1) -> linear component.
    public static func srgbToLinear(_ component: Double) -> Double {
        let c = min(max(component, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Inverse sRGB EOTF: linear component -> gamma-encoded component (0...1).
    public static func linearToSRGB(_ component: Double) -> Double {
        let c = min(max(component, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    /// WCAG contrast ratio of a pure-white foreground (relative luminance 1.0) against a
    /// grayscale background whose sRGB gamma value is `gammaLuminance`.
    public static func whiteContrastRatio(gammaLuminance: Double) -> Double {
        let backgroundLinear = srgbToLinear(gammaLuminance)
        return (1.0 + 0.05) / (backgroundLinear + 0.05)
    }

    // MARK: - Band function

    /// The pure band correction. Input: the background's PRE-correction sRGB gamma
    /// luminance (whatever the existing tone-map/C5 pipeline already produced). Output:
    /// the darken/lift to add on top. No SwiftUI, no I/O.
    public static func resolve(
        backgroundLuminance: Double,
        ceilingContrast: Double = MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast,
        floorContrast: Double = MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast
    ) -> Correction {
        let x = min(max(backgroundLuminance, 0), 1)
        let ceilingLuminance = boundaryGammaLuminance(forContrast: ceilingContrast)
        let floorLuminance = boundaryGammaLuminance(forContrast: floorContrast)

        if x > ceilingLuminance {
            // Black scrim: new = x * (1 - alpha). Solve alpha so new == ceilingLuminance
            // exactly — the minimal darken that restores the ceiling contrast.
            let alpha = x > 0 ? 1 - (ceilingLuminance / x) : 0
            return Correction(darkenOpacity: min(max(alpha, 0), 1), liftAmount: 0)
        }

        if x < floorLuminance {
            // Hue-preserving lift: new = x + lift. Solve lift so new == floorLuminance
            // exactly — the minimal lift that relaxes the floor contrast.
            let lift = floorLuminance - x
            return Correction(darkenOpacity: 0, liftAmount: max(lift, 0))
        }

        return .zero
    }

    /// Applies a `Correction` to a background luminance the same way the two call sites
    /// do (darken via black-scrim multiply, lift via additive brightness), for tests that
    /// need the FINAL on-screen value rather than the correction alone.
    public static func apply(_ luminance: Double, _ correction: Correction) -> Double {
        let darkened = luminance * (1 - correction.darkenOpacity)
        let lifted = darkened + correction.liftAmount
        return min(max(lifted, 0), 1)
    }

    /// The sRGB gamma luminance at which `whiteContrastRatio` equals exactly `contrast`.
    private static func boundaryGammaLuminance(forContrast contrast: Double) -> Double {
        let linear = (1.0 + 0.05) / max(contrast, 0.0001) - 0.05
        return linearToSRGB(max(linear, 0))
    }

    // MARK: - Channel-correct model (research/spec-2026-09-22-backdrop-legibility.md
    // colour sweep review)
    //
    // `resolve(backgroundLuminance:)` above treats the background as a single gamma
    // scalar — exact for actually-gray content (R==G==B), where mixing-then-linearizing
    // and linearizing-then-mixing agree. For a SATURATED colour they do not: sRGB
    // linearization is nonlinear, so `srgbToLinear(0.2126r + 0.7152g + 0.0722b)` (mix
    // gamma values, then linearize) is a different number from
    // `0.2126*linear(r) + 0.7152*linear(g) + 0.0722*linear(b)` (linearize each channel,
    // then mix — the actual WCAG definition). Measured divergence for solid saturated
    // covers: pure red claimed 12.0:1 (at the floor) but the true per-channel contrast was
    // only 4.79:1; pure magenta claimed 12.0:1 but was actually 4.35:1 — BELOW the 4.5
    // ceiling, i.e. the scalar model would ship an under-corrected, illegible background.
    //
    // `.contrast()`/`.brightness()`/the black-overlay and white-screen blends are all
    // genuinely PER-CHANNEL operations on the real image (SwiftUI applies each to R, G, B
    // independently) — `fluidBackdropToneColor`/`fullscreenBottomBandToneColor` replicate
    // that. The band correction (darken multiply / lift add) is ALSO uniform across
    // channels in the real compositor, so `resolveChannelCorrect` solves for the single
    // alpha/delta that, applied to all three channels, lands the TRUE (per-channel
    // linearized, Rec.709-combined) relative luminance exactly on the ceiling/floor
    // boundary. There is no closed form for three nonlinear channels combined, so this
    // solves numerically via bisection (the mapping is monotonic in both directions, so
    // bisection always converges) — this is what makes the fix generic: it takes any RGB
    // triple, no per-colour branches.

    public struct RGBColor: Equatable {
        public let r: Double
        public let g: Double
        public let b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = min(max(r, 0), 1)
            self.g = min(max(g, 0), 1)
            self.b = min(max(b, 0), 1)
        }
    }

    /// TRUE WCAG relative luminance: linearize EACH channel first, then combine via
    /// Rec.709 weights — this is what `whiteContrastRatio(gammaLuminance:)` only
    /// approximates correctly for gray input.
    public static func relativeLuminance(_ color: RGBColor) -> Double {
        0.2126 * srgbToLinear(color.r) + 0.7152 * srgbToLinear(color.g) + 0.0722 * srgbToLinear(color.b)
    }

    /// WCAG contrast ratio of a pure-white foreground against a background whose TRUE
    /// (already-linear) relative luminance is `relativeLuminance`.
    public static func whiteContrastRatio(relativeLuminance: Double) -> Double {
        (1.0 + 0.05) / (max(relativeLuminance, 0) + 0.05)
    }

    /// Channel-correct band correction: solves for the darken/lift that, applied
    /// UNIFORMLY to all three channels (matching how the black-scrim multiply / brightness
    /// add actually composite), brings `preCorrection`'s TRUE relative luminance to
    /// exactly the ceiling/floor boundary. Generic for any hue — see the file-level note.
    public static func resolveChannelCorrect(
        preCorrection: RGBColor,
        ceilingContrast: Double = MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast,
        floorContrast: Double = MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast
    ) -> Correction {
        let contrast = whiteContrastRatio(relativeLuminance: relativeLuminance(preCorrection))

        if contrast < ceilingContrast {
            // Darkening (alpha up) monotonically RAISES contrast: f(0) < 0, f(1) > 0.
            let alpha = bisectRoot(low: 0, high: 1) { alpha in
                let darkened = RGBColor(
                    r: preCorrection.r * (1 - alpha),
                    g: preCorrection.g * (1 - alpha),
                    b: preCorrection.b * (1 - alpha)
                )
                return whiteContrastRatio(relativeLuminance: relativeLuminance(darkened)) - ceilingContrast
            }
            return Correction(darkenOpacity: alpha, liftAmount: 0)
        }

        if contrast > floorContrast {
            // Lifting (delta up) monotonically LOWERS contrast: f(0) < 0, f(1) > 0 for
            // f(delta) = floorContrast - contrast(delta).
            let delta = bisectRoot(low: 0, high: 1) { delta in
                let lifted = RGBColor(
                    r: preCorrection.r + delta,
                    g: preCorrection.g + delta,
                    b: preCorrection.b + delta
                )
                return floorContrast - whiteContrastRatio(relativeLuminance: relativeLuminance(lifted))
            }
            return Correction(darkenOpacity: 0, liftAmount: delta)
        }

        return .zero
    }

    /// Applies a `Correction` to an RGB background the same way the compositor does:
    /// darken via uniform multiply, lift via uniform additive brightness.
    public static func apply(_ color: RGBColor, _ correction: Correction) -> RGBColor {
        RGBColor(
            r: color.r * (1 - correction.darkenOpacity) + correction.liftAmount,
            g: color.g * (1 - correction.darkenOpacity) + correction.liftAmount,
            b: color.b * (1 - correction.darkenOpacity) + correction.liftAmount
        )
    }

    /// Bisection root-finder for a monotonically non-decreasing `f` with `f(low) <= 0 <=
    /// f(high)` (callers construct `f` so this holds by construction — see call sites).
    private static func bisectRoot(low: Double, high: Double, iterations: Int = 60, _ f: (Double) -> Double) -> Double {
        if f(low) >= 0 { return low }
        if f(high) <= 0 { return high }
        var lo = low
        var hi = high
        for _ in 0..<iterations {
            let mid = (lo + hi) / 2
            if f(mid) < 0 { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Point A pipeline, per channel (see the channel-correct model note above) — the
    /// same contrast/brightness/screen/shade/C5 chain as `fluidBackdropToneLuminance`,
    /// applied independently to R, G, B.
    static func fluidBackdropToneColor(
        artworkAverageColor: RGBColor,
        tone: ArtworkBackgroundToneMap,
        contrastResolution: ArtworkContrastPolicy.Resolution,
        applyContrastDarken: Bool,
        textureBrightnessOverride: Double? = nil
    ) -> RGBColor {
        func channel(_ x: Double) -> Double {
            fluidBackdropToneLuminance(
                artworkAverageLuminance: x, tone: tone, contrastResolution: contrastResolution,
                applyContrastDarken: applyContrastDarken, textureBrightnessOverride: textureBrightnessOverride
            )
        }
        return RGBColor(r: channel(artworkAverageColor.r), g: channel(artworkAverageColor.g), b: channel(artworkAverageColor.b))
    }

    /// Point B pipeline, per channel — the same contrast/brightness/dimming chain as
    /// `fullscreenBottomBandToneLuminance`, applied independently to R, G, B, then the
    /// conservative per-channel max against the raw cover-bottom-row colour.
    static func fullscreenBottomBandToneColor(
        coverBottomRowColor: RGBColor,
        artworkAverageColor: RGBColor,
        tone: ArtworkBackgroundToneMap
    ) -> RGBColor {
        func layer1Channel(_ x: Double) -> Double {
            let x1 = applyContrast(x, tone.textureContrast)
            let x2 = applyBrightness(x1, tone.textureBrightness)
            return min(max(applyBlackOverlay(x2, opacity: tone.textureDimmingOpacity), 0), 1)
        }
        // Conservatively pick whichever of layer1 / raw-cover has the higher TRUE relative
        // luminance overall (not per-channel-independently, which could invent an
        // out-of-gamut hue) — matches `fullscreenBottomBandToneLuminance`'s `max(...)`.
        let layer1 = RGBColor(r: layer1Channel(artworkAverageColor.r), g: layer1Channel(artworkAverageColor.g), b: layer1Channel(artworkAverageColor.b))
        let layer1Lum = relativeLuminance(layer1)
        let coverLum = relativeLuminance(coverBottomRowColor)
        return layer1Lum >= coverLum ? layer1 : coverBottomRowColor
    }

    // MARK: - Point A: FluidGradientBackground pipeline (analytic replica)

    /// Replicates `FluidGradientBackground`'s existing (pre-band) compositing chain as a
    /// pure function, so both the view and the tests compute the identical number:
    /// blurred artwork -> `.contrast(tone.textureContrast)` -> `.brightness(tone.textureBrightness)`
    /// -> white screen-blend lift -> black shade -> (tuned-arm only) C5 extra darken.
    /// Intermediate steps are NOT clamped (the compositor works in extended range before
    /// the final display clamp) — only the returned value is clamped to 0...1.
    /// `textureBrightnessOverride`, when provided, replaces `tone.textureBrightness` at
    /// the `.brightness()` step — this is how a floor-correction lift is FOLDED into the
    /// existing brightness modifier (see `innerBrightnessDelta`) instead of adding a new
    /// resident compositing filter on top.
    static func fluidBackdropToneLuminance(
        artworkAverageLuminance: Double,
        tone: ArtworkBackgroundToneMap,
        contrastResolution: ArtworkContrastPolicy.Resolution,
        applyContrastDarken: Bool,
        textureBrightnessOverride: Double? = nil
    ) -> Double {
        let x1 = applyContrast(artworkAverageLuminance, tone.textureContrast)
        let x2 = applyBrightness(x1, textureBrightnessOverride ?? tone.textureBrightness)
        let x3 = applyWhiteScreen(x2, opacity: tone.liftOpacity)
        let x4 = applyBlackOverlay(x3, opacity: tone.shadeOpacity)
        let x5 = applyContrastDarken ? applyBlackOverlay(x4, opacity: contrastResolution.darkenOpacity) : x4
        return min(max(x5, 0), 1)
    }

    /// Folds a floor-correction lift into the EXISTING inner `.brightness(tone.textureBrightness)`
    /// step instead of adding a new resident filter/modifier on top of the composited
    /// subtree — this project has measured that the render server re-evaluates every
    /// resident compositing filter (blur/brightness/contrast/...) on each recomposite
    /// regardless of its value (CLAUDE.md Performance Traps, "Resident CIGaussianBlur"),
    /// so an always-present `.brightness(liftAmount)` wrapper would cost WindowServer time
    /// even when `liftAmount == 0`.
    ///
    /// Everything AFTER that inner brightness step is affine in its output x2:
    /// `final = (a + (1-a)*x2) * (1-s) * (1-d)`, where `a` = `tone.liftOpacity` (white
    /// screen-blend), `s` = `tone.shadeOpacity` (black overlay), `d` = the C5 darken
    /// opacity (0 when not applied). To raise `final` by `liftAmount`, x2 must rise by
    /// `liftAmount / ((1-a)*(1-s)*(1-d))` — i.e. that amount must be ADDED to
    /// `tone.textureBrightness` at the existing modifier, not layered on afterwards.
    static func innerBrightnessDelta(
        liftAmount: Double,
        tone: ArtworkBackgroundToneMap,
        contrastResolution: ArtworkContrastPolicy.Resolution,
        applyContrastDarken: Bool
    ) -> Double {
        guard liftAmount > 0 else { return 0 }
        let a = tone.liftOpacity
        let s = tone.shadeOpacity
        let d = applyContrastDarken ? contrastResolution.darkenOpacity : 0
        let denominator = (1 - a) * (1 - s) * (1 - d)
        guard denominator > 0.0001 else { return 0 }
        return liftAmount / denominator
    }

    // MARK: - Point B: fullscreen album bottom band (analytic replica)

    /// Replicates the fullscreen album page's bottom band background: the Layer-1 blurred
    /// backing image (`.contrast` -> `.brightness` -> `textureDimmingOpacity` black overlay,
    /// no shade) is only what shows through once the hero cover has faded out via the
    /// 100pt mask gradient. Nearer the top of that gradient the SHARP, unblurred,
    /// uncorrected cover is still what's behind the text/controls. Conservatively (per
    /// spec) the worse (brighter) of the two is used.
    static func fullscreenBottomBandToneLuminance(
        coverBottomRowLuminance: Double,
        artworkAverageLuminance: Double,
        tone: ArtworkBackgroundToneMap
    ) -> Double {
        let x1 = applyContrast(artworkAverageLuminance, tone.textureContrast)
        let x2 = applyBrightness(x1, tone.textureBrightness)
        let layer1 = applyBlackOverlay(x2, opacity: tone.textureDimmingOpacity)
        let clampedLayer1 = min(max(layer1, 0), 1)
        let clampedCover = min(max(coverBottomRowLuminance, 0), 1)
        return max(clampedLayer1, clampedCover)
    }

    /// Point B's bottom scrim shape: FULL `darkenOpacity` across the flat zone nearest
    /// the bottom edge (must cover every real foreground element — title in hover mode,
    /// shuffle/repeat row, SharedBottomControls — none of which sit at the very bottom
    /// pixel, so a plain 0->darken ramp across the whole band under-darkens exactly where
    /// the controls are), fading to 0 across the fade zone above the flat zone via a
    /// SMOOTHSTEP ease (not linear — research/progressive-blur-2026-09-23.md), clear
    /// beyond both. Smoothstep's derivative is exactly 0 at both ends of the fade zone,
    /// matching the flat zone's own slope (0, it's constant) below and the clear zone's
    /// slope (0, it's constant zero) above — so the whole curve is C1-continuous with no
    /// kink at either zone boundary. A plain linear ramp is only C0 (continuous VALUE, but
    /// its slope jumps from 0 to -darkenOpacity/fadeHeight right at the flat boundary and
    /// back to 0 at the top) — a slope discontinuity reads as a visible edge to the eye
    /// even though no value ever jumps, which is what the founder's "visible top edge"
    /// complaint was actually seeing. `distanceAboveBottom` and the two heights are in
    /// device points.
    static func bottomBandScrimOpacity(
        distanceAboveBottom: Double,
        darkenOpacity: Double,
        flatHeight: Double = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFlatHeight),
        fadeHeight: Double = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFadeHeight)
    ) -> Double {
        guard darkenOpacity > 0 else { return 0 }
        if distanceAboveBottom <= flatHeight { return darkenOpacity }
        let t = min(max((distanceAboveBottom - flatHeight) / max(fadeHeight, 0.0001), 0), 1)
        if t >= 1 { return 0 }
        let eased = t * t * (3 - 2 * t) // smoothstep: eased(0)=0, eased(1)=1, zero slope at both ends
        return darkenOpacity * (1 - eased)
    }

    /// Densely samples `bottomBandScrimOpacity`'s eased curve (at `darkenOpacity` == 1, i.e.
    /// the normalized 0...1 shape) into `LinearGradient`-ready stops, top (location 0) to
    /// bottom (location 1). SwiftUI's `LinearGradient` only interpolates LINEARLY between
    /// its own stops, so a handful of hand-picked stops would silently reintroduce the same
    /// kind of slope kink the pure function was just fixed to not have — enough samples
    /// (`sampleCount`) make the piecewise-linear render visually indistinguishable from the
    /// smooth analytic curve, and keeps the rendered gradient and the tested pure function
    /// the same shape by construction rather than two independently-hand-tuned curves that
    /// can drift apart. Callers scale `opacityFraction` by the real `darkenOpacity`/
    /// `blendOpacity` and use `location` directly as the `Gradient.Stop` location.
    public static func bottomBandScrimGradientStops(
        sampleCount: Int = 24,
        flatHeight: Double = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFlatHeight),
        fadeHeight: Double = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFadeHeight)
    ) -> [(location: Double, opacityFraction: Double)] {
        let totalHeight = flatHeight + fadeHeight
        guard totalHeight > 0, sampleCount > 1 else { return [(0, 0), (1, 1)] }
        return (0...sampleCount).map { i in
            let location = Double(i) / Double(sampleCount) // 0 = top of band, 1 = bottom edge
            let distanceAboveBottom = totalHeight * (1 - location)
            let opacityFraction = bottomBandScrimOpacity(
                distanceAboveBottom: distanceAboveBottom, darkenOpacity: 1.0,
                flatHeight: flatHeight, fadeHeight: fadeHeight
            )
            return (location, opacityFraction)
        }
    }

    // MARK: - Point B: pure-SwiftUI progressive blur recipe (research/progressive-blur-2026-09-23.md,
    // round 2 — NOT the Metal `.layerEffect` shader: this machine's Xcode has no Metal
    // Toolchain (`xcrun metal` fails with "missing Metal Toolchain"), so `.metal` files
    // never compile to a usable .metallib (the unused ProgressiveBlur.metal and its
    // `ShaderLibrary.bundle(Bundle.module)` modifiers were removed 2026-09-23), and a
    // SwiftPM `Bundle.module` in the shipped app resolves only via build_app.sh's
    // resource-bundle gate. Instead: a small stack of blurred image copies, radii increasing toward
    // the bottom, each one revealed only within its OWN smoothstep-shaped band (reusing
    // `bottomBandScrimOpacity`'s envelope math) — drawn back-to-front from weakest (widest
    // reveal, all the way from the top of the band down to the bottom edge) to strongest
    // (narrowest reveal, only right at the bottom edge, drawn LAST so it wins there). The
    // step-wise composite approximates a continuous 0-at-top -> max-at-bottom blur ramp.

    /// One layer of the pure-SwiftUI progressive-blur stack: `radius` for `.blur(radius:)`,
    /// `flatHeight`/`fadeHeight` are this layer's OWN reveal span — pass directly as
    /// `bottomBandScrimGradientStops(flatHeight:fadeHeight:)`'s parameters to build its mask.
    public struct HeroBlurLayer: Equatable {
        public let radius: CGFloat
        public let flatHeight: Double
        public let fadeHeight: Double

        public init(radius: CGFloat, flatHeight: Double, fadeHeight: Double) {
            self.radius = radius
            self.flatHeight = flatHeight
            self.fadeHeight = fadeHeight
        }
    }

    /// Builds `layerCount` layers, radius `k * maxRadius / layerCount` for k = 1...layerCount
    /// (weakest first). Layer k's reveal span reaches `bandHeight * (layerCount - k + 1) /
    /// layerCount` above the bottom edge — layer 1 (weakest) spans the WHOLE band, layer
    /// `layerCount` (strongest, == `maxRadius`) spans only `bandHeight / layerCount` right at
    /// the bottom edge. Composed in ARRAY ORDER (weakest first / drawn at the back, strongest
    /// last / drawn on top) by the caller, the visible radius at any point is therefore the
    /// STRONGEST layer whose span reaches that point — i.e. it increases monotonically toward
    /// the bottom edge. Each layer's own ramp (from `bottomBandScrimOpacity`) is smoothstep-
    /// eased, so neighbouring layers cross-fade smoothly rather than stepping abruptly.
    public static func heroBottomBandBlurLayers(
        layerCount: Int = MicroInteractionFeel.Tokens.backdropLegibilityBottomBandBlurLayerCount,
        maxRadius: CGFloat = MicroInteractionFeel.Tokens.backdropLegibilityBottomBandBlurRadius,
        bandHeight: Double = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFlatHeight)
            + Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFadeHeight)
    ) -> [HeroBlurLayer] {
        guard layerCount > 0, bandHeight > 0, maxRadius > 0 else { return [] }
        return (1...layerCount).map { k in
            let cutoff = bandHeight * Double(layerCount - k + 1) / Double(layerCount)
            let rampWidth = min(bandHeight / Double(layerCount), cutoff)
            let flatHeight = max(cutoff - rampWidth, 0)
            let fadeHeight = max(cutoff - flatHeight, 0.0001)
            let radius = maxRadius * CGFloat(k) / CGFloat(layerCount)
            return HeroBlurLayer(radius: radius, flatHeight: flatHeight, fadeHeight: fadeHeight)
        }
    }

    // MARK: - Point B: artwork-tinted variant (research/progressive-blur-2026-09-23.md)
    //
    // Replaces the flat `Color.black` scrim with a blend toward a DARK, ARTWORK-DERIVED
    // tint (never literal black) plus (production-side, MiniPlayerView) a progressive blur
    // of the hero cover itself. Blur alone cannot lower luminance (a blurred white pixel is
    // still white), so the WCAG contrast requirement still has to come entirely from this
    // blend — blending toward a black tint is exactly the tint=(0,0,0) special case of
    // blending toward any RGB tint, so the ceiling-darken math generalizes to a single
    // bisection-on-alpha solve parameterized by the tint colour, reusing the same channel-
    // correct machinery as `resolveChannelCorrect` above. Point A is UNCHANGED — it still
    // uses `Correction`/`resolveChannelCorrect`/pure black.

    /// Point B's correction result when blending toward an artwork tint instead of black.
    public struct TintedCorrection: Equatable {
        /// Blend-toward-`tint` alpha (0...1), needed when the background is too bright.
        public let blendOpacity: Double
        /// Additive `.brightness`-style lift, needed when the background is too dark — a
        /// dark tint cannot fix a too-dark background, so this falls back to the same
        /// hue-preserving lift the untinted model uses (unrendered at point B today, same
        /// as before this change — see research doc).
        public let liftAmount: Double
        public let tint: RGBColor

        public static func zero(tint: RGBColor) -> TintedCorrection {
            TintedCorrection(blendOpacity: 0, liftAmount: 0, tint: tint)
        }

        public init(blendOpacity: Double, liftAmount: Double, tint: RGBColor) {
            self.blendOpacity = blendOpacity
            self.liftAmount = liftAmount
            self.tint = tint
        }
    }

    /// Derives point B's scrim tint from the artwork's own average colour: a fixed shade
    /// factor darkens it while preserving hue, so the scrim always reads as "this cover's
    /// own shadow" rather than a flat neutral slab. Never returns literal (0,0,0) unless
    /// the artwork itself averages to literal black (`shadeFactor * 0 == 0` either way).
    public static func pointBTint(
        from artworkAverageColor: RGBColor,
        shadeFactor: Double = MicroInteractionFeel.Tokens.backdropLegibilityBottomBandTintShadeFactor
    ) -> RGBColor {
        RGBColor(
            r: artworkAverageColor.r * shadeFactor,
            g: artworkAverageColor.g * shadeFactor,
            b: artworkAverageColor.b * shadeFactor
        )
    }

    /// Uniform per-channel blend toward `tint` by `alpha` — the same shape as the real
    /// compositor's colour-over-colour blend (SwiftUI applies this per channel).
    public static func blend(_ from: RGBColor, toward tint: RGBColor, alpha: Double) -> RGBColor {
        let a = min(max(alpha, 0), 1)
        return RGBColor(
            r: from.r * (1 - a) + tint.r * a,
            g: from.g * (1 - a) + tint.g * a,
            b: from.b * (1 - a) + tint.b * a
        )
    }

    /// Channel-correct tinted band correction: solves for the blend alpha (bright case) or
    /// additive lift (dark case) that brings `preCorrection`'s TRUE relative luminance to
    /// exactly the ceiling/floor boundary — identical bisection strategy to
    /// `resolveChannelCorrect`, generalized from "blend toward black" to "blend toward any
    /// tint". Generic for any hue of `preCorrection` OR `tint`.
    public static func resolveTinted(
        preCorrection: RGBColor,
        tint: RGBColor,
        ceilingContrast: Double = MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast,
        floorContrast: Double = MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast
    ) -> TintedCorrection {
        let contrast = whiteContrastRatio(relativeLuminance: relativeLuminance(preCorrection))

        if contrast < ceilingContrast {
            // Blending toward a strictly-darker tint monotonically RAISES contrast.
            let alpha = bisectRoot(low: 0, high: 1) { alpha in
                let blended = blend(preCorrection, toward: tint, alpha: alpha)
                return whiteContrastRatio(relativeLuminance: relativeLuminance(blended)) - ceilingContrast
            }
            return TintedCorrection(blendOpacity: alpha, liftAmount: 0, tint: tint)
        }

        if contrast > floorContrast {
            // Lifting (delta up) monotonically LOWERS contrast, independent of the tint.
            let delta = bisectRoot(low: 0, high: 1) { delta in
                let lifted = RGBColor(r: preCorrection.r + delta, g: preCorrection.g + delta, b: preCorrection.b + delta)
                return floorContrast - whiteContrastRatio(relativeLuminance: relativeLuminance(lifted))
            }
            return TintedCorrection(blendOpacity: 0, liftAmount: delta, tint: tint)
        }

        return .zero(tint: tint)
    }

    /// Applies a `TintedCorrection` to an RGB background the way the compositor does:
    /// blend toward the tint, then additive lift, both uniform across channels.
    public static func applyTinted(_ color: RGBColor, _ correction: TintedCorrection) -> RGBColor {
        let blended = blend(color, toward: correction.tint, alpha: correction.blendOpacity)
        return RGBColor(
            r: blended.r + correction.liftAmount,
            g: blended.g + correction.liftAmount,
            b: blended.b + correction.liftAmount
        )
    }

    // MARK: - SwiftUI modifier formulas (see spec's 解析模型)

    private static func applyContrast(_ x: Double, _ c: Double) -> Double {
        (x - 0.5) * c + 0.5
    }

    private static func applyBrightness(_ x: Double, _ b: Double) -> Double {
        x + b
    }

    private static func applyBlackOverlay(_ x: Double, opacity: Double) -> Double {
        x * (1 - opacity)
    }

    private static func applyWhiteScreen(_ x: Double, opacity: Double) -> Double {
        x + opacity * (1 - x)
    }
}
