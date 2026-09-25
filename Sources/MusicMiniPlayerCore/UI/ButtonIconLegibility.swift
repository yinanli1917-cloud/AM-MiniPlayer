import AppKit
import CoreImage
import SwiftUI

/**
 * [INPUT]: Depends on `ArtworkVisualMetrics`/`ArtworkBackgroundToneMap` (FluidGradientBackground.swift),
 *          `BackdropLegibilityBand` (RGBColor / srgbToLinear / linearToSRGB /
 *          fluidBackdropToneColor / resolveChannelCorrect / apply) to reuse the existing
 *          RGB colour model and the fluid-backdrop analytic prediction, `ArtworkContrastPolicy` +
 *          `MicroInteractionFeel` for the exact same C5 arm the live `FluidGradientBackground`
 *          reads, and raw artwork pixels via CoreGraphics / Core Image for the fullscreen
 *          hero composite (ported from research/spikes/legibility-gallery/.../CompositeSampler.swift).
 * [OUTPUT]: Exports `ButtonIconID` (the shuffle/repeat circle buttons this mechanism drives —
 *           founder 2026-09-24 narrowed scope to ONLY these two), `ButtonIconRect` +
 *           `ButtonIconRects` (their real footprint in panel points, mirroring
 *           MiniPlayerView.swift's `shuffleRepeatCluster` layout literals), `ButtonIconTone`
 *           (white, or a solved neutral gray), `APCAContrast` (the perceptual contrast
 *           metric this mechanism judges legibility with — see 2026-09-25 note below),
 *           `ButtonIconDecision` (the APCA threshold + hysteresis rule + gray solve), and
 *           `ButtonIconLegibility.resolveAll` — the ONE mechanism the shuffle/repeat
 *           cluster asks for its icon colour.
 * [POS]: UI/ 的 shuffle/repeat 按钮图标可读性判定 — founder 2026-09-24 (verbatim intent,
 *        narrowed same day after trying the whole-button-set version): 只有 shuffle/repeat
 *        圆形按钮需要自适应；像素太亮时图标不是纯黑，而是恰好过对比度门槛的中性灰
 *        （"灰色一点就行，保持对比度就好"），越暗的背景需要的灰越深但永远不到纯黑；平滑渐变
 *        过渡，滞后区保留。播放区（SharedBottomControls）与顶部两个按钮（Music/AirPlay）都
 *        不再经过这个机制，见 SharedControls.swift / HoverableButtons.swift / AudioOutputSwitcherView.swift
 *        的原始（feature 之前）规则。
 *
 *        2026-09-25 (founder bug report — Bad Sweetheart "Damn": a saturated TEAL
 *        illustration with thin white squiggly linework and a dark red telephone near the
 *        shuffle/repeat row): the original mechanism wrongly turned the icons gray. Two
 *        independent root causes, both fixed here:
 *          (a) the sample statistic was p90-of-patch — over a small ~24pt button rect, p90
 *              is dominated by whichever sparse bright highlight strokes happen to fall
 *              inside it, not the colour a human eye reads as "the background". Replaced
 *              with `ButtonIconCompositeBitmap.dominantColor`: a small box blur (folds a
 *              thin highlight's anti-aliased edge into its surrounding dominant colour)
 *              followed by the MEDIAN-luminance pixel of the blurred patch — robust as long
 *              as highlights cover under half the patch, which any real "thin line art"
 *              cover does.
 *          (b) WCAG 2 contrast is a known-poor model for saturated mid-tone colours: it
 *              under-rates how legible white reads against a saturated hue like teal
 *              relative to how a human actually perceives it. Replaced with APCA
 *              (Accessible Perceptual Contrast Algorithm, `APCAContrast`) for this
 *              decision — the WCAG-based `BackdropLegibilityBand` machinery elsewhere in
 *              this file (the fluid-backdrop colour PREDICTION) is untouched; only the
 *              legibility JUDGEMENT of that colour changed.
 *        See `Tests/MusicMiniPlayerTests/ButtonIconLegibilityEvalTests.swift` for the
 *        labelled before/after eval (synthetic fixtures + the founder's real covers).
 *
 *        Pure functions only (no SwiftUI view code) so they are unit-testable without
 *        hosting a window — MiniPlayerView.swift calls `resolveAll` once per artwork change
 *        (never per frame) and threads the resulting per-button `ButtonIconTone` into the
 *        shuffle/repeat cluster's `foregroundStyle`.
 */

// MARK: - Button inventory

/// The two circle buttons this mechanism drives (founder 2026-09-24: narrowed from the
/// original nine-button inventory to just these). Selected-state tint colours
/// (shuffle/repeat when ON) are NOT part of this enum — those stay the existing theme-red,
/// untouched.
enum ButtonIconID: CaseIterable, Hashable {
    case shuffle
    case repeatButton
}

enum ButtonIconTone: Equatable {
    case white
    /// A neutral gray, sRGB gamma lightness 0...1 (r == g == b == lightness). Solved by
    /// `ButtonIconGraySolve.lightness` to land EXACTLY on the APCA |Lc| legibility floor
    /// (`ButtonIconDecision.grayThreshold`) against the background it was resolved for — never darker than that solve,
    /// and never 0 (pure black); see `ButtonIconGraySolve`'s own floor.
    case gray(Double)
}

/// A button's footprint in panel points. `(x, distanceFromBottom)` — bottom-origin,
/// matching `research/spikes/legibility-gallery`'s `ElementRect` / `HeroBandMath`
/// convention (NOT SwiftUI's top-down `(x, y)`) so the geometry formulas below read the
/// same way as the founder-reviewed prototype.
struct ButtonIconRect: Equatable {
    let x: CGFloat
    let distanceFromBottom: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(x: CGFloat, distanceFromBottom: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.distanceFromBottom = distanceFromBottom
        self.width = width
        self.height = height
    }
}

/// Real production rects, derived from the exact literals `MiniPlayerView.swift`'s
/// `shuffleRepeatCluster` already uses — not re-measured guesses. Identical in fullscreen
/// and non-fullscreen mode (only the composite BEHIND them differs, see
/// `ButtonIconLegibility`).
enum ButtonIconRects {
    /// `SharedBottomControls.body`: `PlaybackProgressSection().frame(height: 32)` +
    /// `VStack(spacing: 4)` + the icon-row `HStack` (max child height 30) + that VStack's
    /// own `.padding(.bottom, 16)`.
    private static let sharedBottomControlsHeight: CGFloat = 32 + 4 + 30 + 16

    /// `MiniPlayerView.albumOverlayContent`'s shuffle/repeat row: `.padding(.bottom, 4)`
    /// sits directly above `SharedBottomControls`.
    private static let shuffleRepeatRowBottomDistance: CGFloat = sharedBottomControlsHeight + 4

    /// `MiniPlayerView.shuffleRepeatCluster`: real 24x24 frames, right-aligned with
    /// `.padding(.horizontal, 32)`, `HStack(spacing: 4)` (shuffle first, repeat second).
    static func shuffle(panelSize: CGSize) -> ButtonIconRect {
        let clusterRight = panelSize.width - 32
        return ButtonIconRect(x: clusterRight - 24 - 4 - 24, distanceFromBottom: shuffleRepeatRowBottomDistance, width: 24, height: 24)
    }

    static func repeatButton(panelSize: CGSize) -> ButtonIconRect {
        let clusterRight = panelSize.width - 32
        return ButtonIconRect(x: clusterRight - 24, distanceFromBottom: shuffleRepeatRowBottomDistance, width: 24, height: 24)
    }

    static func rect(for id: ButtonIconID, panelSize: CGSize) -> ButtonIconRect {
        switch id {
        case .shuffle: return shuffle(panelSize: panelSize)
        case .repeatButton: return repeatButton(panelSize: panelSize)
        }
    }

    static func all(panelSize: CGSize) -> [ButtonIconID: ButtonIconRect] {
        Dictionary(uniqueKeysWithValues: ButtonIconID.allCases.map { ($0, rect(for: $0, panelSize: panelSize)) })
    }
}

// MARK: - Fullscreen hero composite (per-pixel, ported from the legibility gallery)

/// One RGB sample, 0...1 per channel.
struct ButtonIconRGBPixel: Equatable {
    let r: Double
    let g: Double
    let b: Double
}

/// A real per-pixel render of `MiniPlayerView.floatingArtwork`'s fullscreen composite
/// (Layer 1 blurred/toned base + Layer 2 sharp hero fading over it via the bottom mask),
/// plus a robust dominant-colour sample restricted to one button's own rect. Ported from
/// `research/spikes/legibility-gallery/.../CompositeSampler.swift` (Core Image
/// `CIGaussianBlur`, matching `NSImage+AverageColor.swift`'s established CIFilter-chain
/// pattern — SwiftUI `ImageRenderer` is this project's known flaky-test trap for
/// large-radius blur, see `lyrics_disk_preflight_and_flaky_tests.md`).
struct ButtonIconCompositeBitmap {
    let pixels: [UInt8] // RGBA8 premultiplied-last, row 0 = TOP of the image.
    let width: Int
    let height: Int
    let scale: CGFloat

    /// Blur radius (panel points) for `dominantColor`'s pre-statistic box blur — sized to
    /// fold typical cover-art linework (a couple of points thick) into its surrounding
    /// colour without smearing across most of a 24pt button.
    static let dominantColorBlurRadiusPoints: CGFloat = 3

    /// The colour a human eye reads as "the background" under `rect` — NOT an average, and
    /// NOT the old p90 sample (2026-09-24: proved wrong on a real founder-reported cover,
    /// Bad Sweetheart "Damn", a saturated teal illustration with thin white squiggly
    /// linework — p90 over a small button-sized patch is dominated by whichever sparse
    /// bright strokes happen to fall inside it). This instead:
    ///   1. box-blurs each candidate pixel with its neighbours (`dominantColorBlurRadiusPoints`)
    ///      so a thin highlight's anti-aliased edge folds into the surrounding dominant
    ///      colour instead of contributing its own peak brightness, then
    ///   2. takes the MEDIAN-luminance pixel of the blurred patch — robust to a minority of
    ///      still-bright pixels (real line-art covers a modest fraction of any small patch;
    ///      median only breaks down once a highlight covers OVER half the patch, which
    ///      does not describe "thin lines").
    /// `rect` uses `(x, distanceFromBottom)`.
    func dominantColor(rect: ButtonIconRect) -> BackdropLegibilityBand.RGBColor? {
        let colLeft = max(0, Int((rect.x * scale).rounded(.down)))
        let colRight = min(width, Int(((rect.x + rect.width) * scale).rounded(.up)))
        let rowTop = max(0, Int((CGFloat(height) - (rect.distanceFromBottom + rect.height) * scale).rounded(.down)))
        let rowBottom = min(height, Int((CGFloat(height) - rect.distanceFromBottom * scale).rounded(.up)))
        guard colRight > colLeft, rowBottom > rowTop else { return nil }

        let blurRadius = max(1, Int((Self.dominantColorBlurRadiusPoints * scale).rounded()))

        var samples: [(pixel: ButtonIconRGBPixel, luminance: Double)] = []
        samples.reserveCapacity((colRight - colLeft) * (rowBottom - rowTop))
        for row in rowTop..<rowBottom {
            for col in colLeft..<colRight {
                let blurred = boxBlurAverage(row: row, col: col, radius: blurRadius)
                let luminance = 0.2126 * blurred.r + 0.7152 * blurred.g + 0.0722 * blurred.b
                samples.append((blurred, luminance))
            }
        }
        guard !samples.isEmpty else { return nil }

        let sortedIndices = samples.indices.sorted { samples[$0].luminance < samples[$1].luminance }
        let medianIndex = sortedIndices[sortedIndices.count / 2]
        let winner = samples[medianIndex].pixel
        return BackdropLegibilityBand.RGBColor(r: winner.r, g: winner.g, b: winner.b)
    }

    /// Simple box blur (no separable-pass optimization needed — patches are ~24pt, radius
    /// is ~3pt, so this is a few thousand pixel reads per `dominantColor` call, negligible
    /// next to the composite render itself; see `ButtonIconLegibilityTests`'s cost guard).
    private func boxBlurAverage(row: Int, col: Int, radius: Int) -> ButtonIconRGBPixel {
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0
        let rowStart = max(0, row - radius)
        let rowEnd = min(height - 1, row + radius)
        let colStart = max(0, col - radius)
        let colEnd = min(width - 1, col + radius)
        guard rowEnd >= rowStart, colEnd >= colStart else { return ButtonIconRGBPixel(r: 0, g: 0, b: 0) }
        for r in rowStart...rowEnd {
            for c in colStart...colEnd {
                let offset = (r * width + c) * 4
                guard offset + 2 < pixels.count else { continue }
                sumR += Double(pixels[offset]) / 255.0
                sumG += Double(pixels[offset + 1]) / 255.0
                sumB += Double(pixels[offset + 2]) / 255.0
                count += 1
            }
        }
        guard count > 0 else { return ButtonIconRGBPixel(r: 0, g: 0, b: 0) }
        return ButtonIconRGBPixel(r: sumR / Double(count), g: sumG / Double(count), b: sumB / Double(count))
    }
}

enum ButtonIconCompositeSampler {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Renders the fullscreen hero composite at pixel resolution. `totalFadeHeight`
    /// mirrors `MiniPlayerView.floatingArtwork`'s `blendHeight` (100); the fullscreen
    /// Layer 1 pass there has no C5 extra-darken step, so `extraDarkenOpacity` is always 0
    /// (kept as a parameter only for parity with the gallery's ported signature/tests).
    static func render(
        cover: NSImage,
        tone: ArtworkBackgroundToneMap,
        extraDarkenOpacity: Double = 0,
        totalFadeHeight: CGFloat,
        panelSize: CGSize,
        scale: CGFloat = 2
    ) -> ButtonIconCompositeBitmap? {
        guard let cgImage = cover.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let outW = Int((panelSize.width * scale).rounded())
        let outH = Int((panelSize.height * scale).rounded())
        guard outW > 0, outH > 0 else { return nil }

        // "scaledToFill().frame(outW,outH).clipped()" placement, CoreGraphics' native
        // (origin bottom-left, Y-up) coordinate system — shared by the sharp draw and the
        // blur transform below since centered fill is symmetric.
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        guard imgW > 0, imgH > 0 else { return nil }
        let fillScale = max(CGFloat(outW) / imgW, CGFloat(outH) / imgH)
        let drawnW = imgW * fillScale
        let drawnH = imgH * fillScale
        let fillRect = CGRect(x: (CGFloat(outW) - drawnW) / 2, y: (CGFloat(outH) - drawnH) / 2, width: drawnW, height: drawnH)

        guard let sharpBuffer = rasterize(cgImage: cgImage, in: fillRect, outW: outW, outH: outH) else { return nil }
        guard let blurredBuffer = rasterizeBlurred(cgImage: cgImage, in: fillRect, outW: outW, outH: outH, blurRadius: 50 * scale) else { return nil }

        var final = [UInt8](repeating: 0, count: outW * outH * 4)
        let contrast = Double(tone.textureContrast)
        let brightness = Double(tone.textureBrightness)
        let dimming = Double(tone.textureDimmingOpacity)

        for row in 0..<outH {
            let distanceFromBottomPixels = Double(outH - row)
            let heroOpacity = min(1, max(0, distanceFromBottomPixels / Double(totalFadeHeight * scale)))
            for col in 0..<outW {
                let offset = (row * outW + col) * 4
                func layer1(_ x: UInt8) -> UInt8 {
                    let g = Double(x) / 255.0
                    let afterContrast = (g - 0.5) * contrast + 0.5
                    let afterBrightness = afterContrast + brightness
                    let afterDimming = afterBrightness * (1 - dimming)
                    let afterExtraDarken = afterDimming * (1 - extraDarkenOpacity)
                    return UInt8(min(255, max(0, afterExtraDarken * 255)))
                }
                for channel in 0..<3 {
                    let sharp = Double(sharpBuffer[offset + channel])
                    let layer1Value = Double(layer1(blurredBuffer[offset + channel]))
                    let blended = sharp * heroOpacity + layer1Value * (1 - heroOpacity)
                    final[offset + channel] = UInt8(min(255, max(0, blended)))
                }
                final[offset + 3] = 255
            }
        }

        return ButtonIconCompositeBitmap(pixels: final, width: outW, height: outH, scale: scale)
    }

    private static func rasterize(cgImage: CGImage, in rect: CGRect, outW: Int, outH: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: outW * outH * 4)
        guard let ctx = CGContext(
            data: &buffer, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: rect)
        return buffer
    }

    private static func rasterizeBlurred(cgImage: CGImage, in rect: CGRect, outW: Int, outH: Int, blurRadius: CGFloat) -> [UInt8]? {
        let ciImage = CIImage(cgImage: cgImage)
        guard ciImage.extent.width > 0, ciImage.extent.height > 0 else { return nil }
        let scaleX = rect.width / ciImage.extent.width
        let scaleY = rect.height / ciImage.extent.height
        let transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: rect.origin.x, ty: rect.origin.y)
        let filled = ciImage.transformed(by: transform)
        let blurred = filled.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let rendered = ciContext.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: outW, height: outH)) else { return nil }
        return rasterize(cgImage: rendered, in: CGRect(x: 0, y: 0, width: outW, height: outH), outW: outW, outH: outH)
    }
}

// MARK: - Non-fullscreen backdrop colour

/// When `fullscreenAlbumCover` is off, shuffle/repeat are only ever visible during hover —
/// at which point `MiniPlayerView.floatingArtwork`'s non-fullscreen artwork has already
/// shrunk to 0.48x width, centred ABOVE the `controlsHeight`-tall bottom band. The
/// shuffle/repeat row never falls inside that shrunk cover's box at any panel size (the
/// layout is fraction-of-geometry throughout, so the relationship is scale-invariant) — it
/// sits over `PanelBackdrop`'s fluid arm, i.e. `FluidGradientBackground`.
///
/// Rather than re-deriving that view's three-layer blurred/rotated composite (a
/// resident-filter-heavy pipeline this project has already flagged as expensive to
/// replicate per-pixel, CLAUDE.md "Resident CIGaussianBlur"), this reuses its EXISTING
/// analytic prediction (`BackdropLegibilityBand.fluidBackdropToneColor` /
/// `resolveChannelCorrect` / `apply` — the same functions `FluidGradientBackground.
/// updateTone()` calls to drive its own on-screen legibility scrim) as a single colour.
/// This is legitimate, not a shortcut: `FluidGradientBackground`'s three overlapping
/// massively-blurred (`blurRadius` ~50-80pt on a ~250pt panel) rotated layers are already
/// engineered to be near-spatially-uniform, and the SAME analytic model is the one this
/// codebase already trusts to guarantee white-foreground legibility there (WCAG band
/// ceiling 4.5:1 — a background at exactly that boundary carries an APCA |Lc| comfortably
/// above this mechanism's 45 floor, ~77 for a neutral gray and higher still for a
/// saturated hue at the same WCAG rating per the 2026-09-25 note on WCAG under-rating
/// saturated colours — see the doc comment on `resolveAll` for why this means
/// non-fullscreen icons stay white by construction, not by a hardcoded exception).
enum ButtonIconBackdropColor {
    static func predictedFluidBackdropColor(artwork: NSImage?, reduceTransparency: Bool) -> BackdropLegibilityBand.RGBColor {
        let metrics = artwork?.artworkVisualMetrics() ?? .neutral
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let legacyArtworkContrast = MicroInteractionFeel.artworkContrast == .legacy
        let contrastResolution = ArtworkContrastPolicy.resolve(
            brightness: metrics.averageLuminance,
            params: MicroInteractionFeel.artworkContrastParams,
            reduceTransparency: reduceTransparency
        )
        let preCorrection = BackdropLegibilityBand.fluidBackdropToneColor(
            artworkAverageColor: BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue),
            tone: tone,
            contrastResolution: contrastResolution,
            applyContrastDarken: !legacyArtworkContrast
        )
        let correction = BackdropLegibilityBand.resolveChannelCorrect(preCorrection: preCorrection)
        return BackdropLegibilityBand.apply(preCorrection, correction)
    }
}

// MARK: - APCA (Accessible Perceptual Contrast Algorithm)
//
// 2026-09-25: replaces WCAG 2 contrast for the shuffle/repeat white/gray JUDGEMENT (the
// fluid-backdrop colour PREDICTION elsewhere in this file still uses WCAG-based
// `BackdropLegibilityBand` machinery unchanged — only how a resolved colour's legibility is
// SCORED changed). WCAG 2's relative-luminance contrast is a known-poor perceptual model
// for saturated mid-tone colours: it under-rates how legible white actually reads against
// a saturated hue (e.g. teal), which was the second contributor (alongside the p90
// statistic bug above) to the founder's "Damn" cover false-positive.
//
// Public reference algorithm: APCA-W3 (Accessible Perceptual Contrast Algorithm,
// SAPC/APCA 0.98G — Andrew Somers / Myndex, Apache-2.0). Ported here as plain Swift (no
// dependency, no network fetch available in this environment) from the well-published
// reference constants/structure. Two things make APCA deliberately different from the
// WCAG code elsewhere in this file, both load-bearing, not omissions:
//   - `screenLuminance` uses a SIMPLE 2.4 power-law gamma, not the WCAG piecewise sRGB
//     EOTF (`BackdropLegibilityBand.srgbToLinear`) — this is part of the APCA spec itself.
//   - APCA is NOT symmetric (`lc(text:background:)` != `-lc(text: background, background: text)`
//     in general) and is signed: positive means a darker foreground on a lighter
//     background, negative the reverse. Callers here only need the magnitude.
enum APCAContrast {
    private static let normBG = 0.56
    private static let normTXT = 0.57
    private static let revTXT = 0.62
    private static let revBG = 0.65
    private static let blackThreshold = 0.022
    private static let blackClamp = 1.414
    private static let scaleBoW = 1.14
    private static let scaleWoB = 1.14
    private static let loBoWOffset = 0.027
    private static let loWoBOffset = 0.027
    private static let deltaYMin = 0.0005
    private static let loClip = 0.1

    /// APCA's own "screen luminance" Y — same Rec.709 channel weights the WCAG luminance
    /// in this file uses, but a plain `component^2.4` gamma instead of the piecewise sRGB
    /// EOTF (see the enum's doc comment: this is a deliberate APCA-spec difference).
    static func screenLuminance(_ color: BackdropLegibilityBand.RGBColor) -> Double {
        0.2126 * pow(color.r, 2.4) + 0.7152 * pow(color.g, 2.4) + 0.0722 * pow(color.b, 2.4)
    }

    /// Soft black-level clamp: real displays/eyes don't resolve near-black differences
    /// linearly, so APCA nudges very-low Y up slightly before comparing. Applied to each
    /// side's Y independently (NOT to their difference).
    private static func softClampBlack(_ y: Double) -> Double {
        y >= blackThreshold ? y : y + pow(blackThreshold - y, blackClamp)
    }

    /// Signed APCA Lc, roughly -108...108. Positive = `text` darker than `background`
    /// (dark-on-light); negative = `text` lighter (light-on-dark, the case this mechanism
    /// always uses — a white/gray icon on a photo backdrop). Callers compare `abs(lc(...))`
    /// against a guidance threshold (see `ButtonIconDecision`).
    static func lc(text: BackdropLegibilityBand.RGBColor, background: BackdropLegibilityBand.RGBColor) -> Double {
        let textY = softClampBlack(screenLuminance(text))
        let backgroundY = softClampBlack(screenLuminance(background))
        guard abs(backgroundY - textY) >= deltaYMin else { return 0 }

        let outputContrast: Double
        if backgroundY > textY {
            // Dark text on a light background.
            let s = (pow(backgroundY, normBG) - pow(textY, normTXT)) * scaleBoW
            outputContrast = s < loClip ? 0 : s - loBoWOffset
        } else {
            // Light text on a dark background (the icon-on-artwork case).
            let s = (pow(backgroundY, revBG) - pow(textY, revTXT)) * scaleWoB
            outputContrast = s > -loClip ? 0 : s + loWoBOffset
        }
        return outputContrast * 100
    }
}

// MARK: - Gray solve (founder 2026-09-24, "灰色一点就行，保持对比度就好")

/// Solves for a neutral gray icon colour that lands EXACTLY on this mechanism's APCA
/// legibility floor (`ButtonIconDecision.grayThreshold`) against a given background —
/// never a hardcoded pure black.
enum ButtonIconGraySolve {
    /// The APCA |Lc| floor this mechanism targets — same value as
    /// `ButtonIconDecision.grayThreshold`, so the gray is always "the lightest gray that
    /// still passes": any lighter gray would fall back below that floor against this exact
    /// background.
    static let targetLc: Double = ButtonIconDecision.grayThreshold

    /// A floor on the solved gray's own sRGB-gamma lightness so the result is never
    /// literally 0 (pure black), matching the founder's "灰色一点就行" (some gray is
    /// enough, never black).
    static let minimumLightness: Double = 0.02

    /// The lightest neutral gray (sRGB gamma, 0...1 — feed directly into
    /// `Color(white:)`/`ButtonIconTone.gray`) whose APCA |Lc| against `background` is
    /// exactly `targetLc`. `|lc(gray, background)|` is monotonically non-increasing as the
    /// gray lightens (a lighter icon has less contrast against the bright background that
    /// triggered this solve in the first place), so this bisects for the boundary.
    static func lightness(background: BackdropLegibilityBand.RGBColor) -> Double {
        func magnitude(_ lightness: Double) -> Double {
            abs(APCAContrast.lc(text: BackdropLegibilityBand.RGBColor(r: lightness, g: lightness, b: lightness), background: background))
        }

        // Degenerate ends: even black can't reach the target (defensively floor rather
        // than go darker), or white already reaches it (nothing to solve).
        guard magnitude(0) >= targetLc else { return minimumLightness }
        guard magnitude(1) < targetLc else { return 1 }

        var lo = 0.0 // magnitude(lo) >= targetLc, invariant maintained below
        var hi = 1.0 // magnitude(hi) < targetLc
        for _ in 0..<48 {
            let mid = (lo + hi) / 2
            if magnitude(mid) >= targetLc {
                lo = mid
            } else {
                hi = mid
            }
        }
        return max(lo, minimumLightness)
    }
}

// MARK: - Decision (APCA threshold + hysteresis + gray solve)

/// The white/gray call for one button, given the colour under it and its PREVIOUS tone.
/// Hysteresis: switching white->gray needs |Lc| to drop below `grayThreshold`; switching
/// back gray->white needs |Lc| to climb back up to >= `whiteThreshold`, so a cover that
/// sits right at the boundary does not flicker every recompute. While staying gray, the
/// exact lightness keeps tracking the current background (continuous, not frozen at the
/// moment it first flipped) so a 0.25s cross-fade (`MiniPlayerView`) reads as smooth
/// motion, never a snap.
enum ButtonIconDecision {
    /// Below this APCA |Lc|, white no longer reads clearly against the background. APCA's
    /// own published guidance places Lc ~45 at the minimum for large-scale/bold text and
    /// non-text UI components (the WCAG3 draft's "spot text / icon" tier) — shuffle/repeat
    /// are small bold glyphs, closer to that tier than to APCA's body-text minimums
    /// (Lc 60/75), so this mechanism targets 45 rather than a stricter body-text floor.
    static let grayThreshold: Double = 45
    /// |Lc| must climb back up to this before returning to white — the same proportional
    /// hysteresis margin (~1.15x) the mechanism's original WCAG 3.0/3.5 band used.
    static let whiteThreshold: Double = 52

    private static let white = BackdropLegibilityBand.RGBColor(r: 1, g: 1, b: 1)

    static func resolve(color: BackdropLegibilityBand.RGBColor, previous: ButtonIconTone) -> ButtonIconTone {
        let contrast = abs(APCAContrast.lc(text: white, background: color))
        switch previous {
        case .white:
            guard contrast < grayThreshold else { return .white }
        case .gray:
            guard contrast < whiteThreshold else { return .white }
        }
        return .gray(ButtonIconGraySolve.lightness(background: color))
    }
}

// MARK: - Top-level entry point

enum ButtonIconLegibility {
    /// `MiniPlayerView.floatingArtwork`'s fullscreen `blendHeight` literal.
    static let fullscreenHeroFadeHeight: CGFloat = 100

    /// Working resolution for the fullscreen composite: panel size x1 (not x2 — a small
    /// robust-statistic scan over a ~24pt button rect does not need retina-resolution
    /// sampling, and the render cost — CIGaussianBlur + a CGContext raster over the OUTPUT
    /// extent — scales with this, not with the source cover's own resolution, see
    /// `ButtonIconCompositeSampler.render`'s doc comment and
    /// `ButtonIconLegibilityTests.test_cost_600And1200SourceArtwork_...`.
    static let fullscreenCompositeScale: CGFloat = 1

    /// Resolves both shuffle/repeat buttons' icon tone, once (call this on artwork change
    /// or `fullscreenAlbumCover` toggle — never per frame). `previous` supplies the
    /// hysteresis state; a missing id defaults to `.white` (today's colour, so a track
    /// with no prior computation never starts gray).
    ///
    /// Fullscreen: real per-pixel hero+fade+Layer1 composite, sampled locally per button
    /// (round 1's rejected whole-cover average is NOT used here).
    ///
    /// Non-fullscreen: both buttons sit over the fluid backdrop (see
    /// `ButtonIconBackdropColor`'s doc comment), whose OWN legibility band already
    /// guarantees WCAG white-foreground contrast >= 4.5:1 — which carries an APCA |Lc|
    /// comfortably above this mechanism's 45 floor (see that doc comment for the numbers).
    /// So non-fullscreen buttons are, by that existing invariant, always resolved white;
    /// this function still runs the real prediction (not a hardcoded `.white`) so it stays
    /// correct if that band's constants ever change.
    ///
    /// THREADING (2026-09-24 review): this function does real CGContext/Core Image work
    /// (the fullscreen branch) and must never run on the main thread — the caller
    /// (`MiniPlayerView.refreshButtonIconTones`) dispatches it via `Task.detached` and
    /// only applies the result on the main actor if it is still current (cancellation +
    /// a generation token guard against a stale result from a superseded artwork/toggle
    /// landing after a newer one). This function itself stays a plain, synchronous, pure
    /// function — no actor isolation, no I/O — so it stays trivially unit-testable and
    /// callable from either context.
    static func resolveAll(
        fullscreen: Bool,
        artwork: NSImage?,
        tone: ArtworkBackgroundToneMap,
        panelSize: CGSize,
        reduceTransparency: Bool,
        previous: [ButtonIconID: ButtonIconTone]
    ) -> [ButtonIconID: ButtonIconTone] {
        guard let artwork else {
            return Dictionary(uniqueKeysWithValues: ButtonIconID.allCases.map { ($0, ButtonIconTone.white) })
        }

        if fullscreen {
            guard let bitmap = ButtonIconCompositeSampler.render(
                cover: artwork,
                tone: tone,
                totalFadeHeight: fullscreenHeroFadeHeight,
                panelSize: panelSize,
                scale: fullscreenCompositeScale
            ) else {
                return previous
            }
            var result: [ButtonIconID: ButtonIconTone] = [:]
            for id in ButtonIconID.allCases {
                let rect = ButtonIconRects.rect(for: id, panelSize: panelSize)
                let prior = previous[id] ?? .white
                guard let color = bitmap.dominantColor(rect: rect) else {
                    result[id] = prior
                    continue
                }
                result[id] = ButtonIconDecision.resolve(color: color, previous: prior)
            }
            return result
        }

        let color = ButtonIconBackdropColor.predictedFluidBackdropColor(artwork: artwork, reduceTransparency: reduceTransparency)
        var result: [ButtonIconID: ButtonIconTone] = [:]
        for id in ButtonIconID.allCases {
            result[id] = ButtonIconDecision.resolve(color: color, previous: previous[id] ?? .white)
        }
        return result
    }
}

// MARK: - Off-main-thread coordination (2026-09-24 review)

/// Runs `ButtonIconLegibility.resolveAll` off the main thread with last-request-wins
/// semantics: calling `refresh` again before a previous call's work has finished
/// supersedes it — that EARLIER call's `refresh` resolves to `nil` once its work
/// completes (however late), never overwriting the newer result. An `actor`'s
/// serialized-but-reentrant execution gives this for free: the `generation` bump and the
/// post-await comparison can never race each other, even though the awaited work itself
/// runs concurrently, off-actor (`Task.detached`).
///
/// `MiniPlayerView` owns one instance (as `@State`, so it survives across its own
/// re-renders) and calls `refresh` once per artwork change / `fullscreenAlbumCover`
/// toggle — never per frame. A `nil` result means "a newer refresh has already
/// superseded this one" — the caller must leave whatever tones are already on screen
/// untouched (never clear/flash to a default), which is exactly what NOT assigning does.
///
/// `compute` is injectable so the stale-result-drop behaviour is deterministically
/// testable (`ButtonIconLegibilityTests`) without depending on how fast the real
/// Core Image work happens to run on the test machine.
actor ButtonIconRefreshCoordinator {
    private var generation: Int = 0
    private let compute: (
        _ fullscreen: Bool,
        _ artwork: NSImage?,
        _ tone: ArtworkBackgroundToneMap,
        _ panelSize: CGSize,
        _ reduceTransparency: Bool,
        _ previous: [ButtonIconID: ButtonIconTone]
    ) async -> [ButtonIconID: ButtonIconTone]

    init(
        compute: @escaping (
            _ fullscreen: Bool,
            _ artwork: NSImage?,
            _ tone: ArtworkBackgroundToneMap,
            _ panelSize: CGSize,
            _ reduceTransparency: Bool,
            _ previous: [ButtonIconID: ButtonIconTone]
        ) async -> [ButtonIconID: ButtonIconTone] = { fullscreen, artwork, tone, panelSize, reduceTransparency, previous in
            await Task.detached(priority: .userInitiated) {
                ButtonIconLegibility.resolveAll(
                    fullscreen: fullscreen,
                    artwork: artwork,
                    tone: tone,
                    panelSize: panelSize,
                    reduceTransparency: reduceTransparency,
                    previous: previous
                )
            }.value
        }
    ) {
        self.compute = compute
    }

    /// Returns the resolved tones, or `nil` if a NEWER `refresh` call was made before
    /// this one's `compute` finished (in which case the caller must drop this result).
    func refresh(
        fullscreen: Bool,
        artwork: NSImage?,
        tone: ArtworkBackgroundToneMap,
        panelSize: CGSize,
        reduceTransparency: Bool,
        previous: [ButtonIconID: ButtonIconTone]
    ) async -> [ButtonIconID: ButtonIconTone]? {
        generation += 1
        let myGeneration = generation
        let result = await compute(fullscreen, artwork, tone, panelSize, reduceTransparency, previous)
        guard myGeneration == generation else { return nil }
        return result
    }
}
