import Foundation

/**
 * [INPUT]: Depends on ArtworkVisualMetrics / ArtworkBackgroundToneMap (FluidGradientBackground.swift)
 *          and ArtworkContrastPolicy.Resolution (MicroInteractionFeel.swift) as the tone-mapped
 *          inputs it predicts a background luminance from; no other module coupling.
 * [OUTPUT]: Exports BackdropLegibilityBand — a pure luminance-band correction (darken/lift) plus
 *           the analytic pipeline replicas (`fluidBackdropToneLuminance`,
 *           `fullscreenBottomBandToneLuminance`) that predict the on-screen background luminance
 *           at the two call sites, reused by both production code and tests.
 * [POS]: Shared legibility-band utility living alongside FluidGradientBackground.swift; consumed by
 *        FluidGradientBackground (point A) and MiniPlayerView's fullscreen album bottom band
 *        (point B) to keep white foregrounds legible against any artwork-derived background.
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
    /// the controls are), fading LINEARLY to 0 across the fade zone above the flat zone,
    /// clear beyond both. `distanceAboveBottom` and the two heights are in device points.
    static func bottomBandScrimOpacity(
        distanceAboveBottom: Double,
        darkenOpacity: Double,
        flatHeight: Double = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFlatHeight),
        fadeHeight: Double = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFadeHeight)
    ) -> Double {
        guard darkenOpacity > 0 else { return 0 }
        if distanceAboveBottom <= flatHeight { return darkenOpacity }
        let fadeProgress = (distanceAboveBottom - flatHeight) / max(fadeHeight, 0.0001)
        if fadeProgress >= 1 { return 0 }
        return darkenOpacity * (1 - fadeProgress)
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
