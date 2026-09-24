import Foundation

/**
 * [INPUT]: Depends on ArtworkVisualMetrics / ArtworkBackgroundToneMap (FluidGradientBackground.swift)
 *          and ArtworkContrastPolicy.Resolution (MicroInteractionFeel.swift) as the tone-mapped
 *          inputs it predicts a background luminance from; no other module coupling.
 * [OUTPUT]: Exports BackdropLegibilityBand — a pure luminance-band correction (darken/lift) plus
 *           the analytic pipeline replica (`fluidBackdropToneLuminance`) that predicts the
 *           on-screen background luminance for FluidGradientBackground (point A), reused by both
 *           production code and tests. Also exports the generic channel-correct primitives
 *           (`RGBColor`, `relativeLuminance`, `whiteContrastRatio(relativeLuminance:)`,
 *           `resolveChannelCorrect`, `fluidBackdropToneColor`) that any other legibility
 *           correction (e.g. the fullscreen album page's own bottom-band fix, see
 *           FullscreenBottomBandLegibility.swift) can reuse without re-deriving WCAG math.
 * [POS]: Shared legibility-band utility living alongside FluidGradientBackground.swift; consumed
 *        by FluidGradientBackground (point A) to keep white foregrounds legible against any
 *        artwork-derived background. A rejected point-B design (black/tinted scrim + stacked
 *        progressive blur, research/progressive-blur-2026-09-23.md) previously lived here and
 *        was removed 2026-09-23 after the founder rejected it (commit b58b4e6) — see that
 *        research file for the historical record.
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
