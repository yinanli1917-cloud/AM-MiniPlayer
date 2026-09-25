import AppKit
import CoreImage
import SwiftUI

/**
 * [INPUT]: Depends on `ArtworkVisualMetrics`/`ArtworkBackgroundToneMap` (FluidGradientBackground.swift),
 *          `BackdropLegibilityBand` (RGBColor / relativeLuminance / whiteContrastRatio /
 *          fluidBackdropToneColor / resolveChannelCorrect / apply / srgbToLinear /
 *          linearToSRGB) for WCAG-correct contrast, `ArtworkContrastPolicy` +
 *          `MicroInteractionFeel` for the exact same C5 arm the live `FluidGradientBackground`
 *          reads, and raw artwork pixels via CoreGraphics / Core Image for the fullscreen
 *          hero composite (ported from research/spikes/legibility-gallery/.../CompositeSampler.swift).
 * [OUTPUT]: Exports `ButtonIconID` (the shuffle/repeat circle buttons this mechanism drives —
 *           founder 2026-09-24 narrowed scope to ONLY these two), `ButtonIconRect` +
 *           `ButtonIconRects` (their real footprint in panel points, mirroring
 *           MiniPlayerView.swift's `shuffleRepeatCluster` layout literals), `ButtonIconTone`
 *           (white, or a solved neutral gray), `ButtonIconDecision` (the WCAG threshold +
 *           hysteresis rule + gray solve), and `ButtonIconLegibility.resolveAll` — the ONE
 *           mechanism the shuffle/repeat cluster asks for its icon colour.
 * [POS]: UI/ 的 shuffle/repeat 按钮图标可读性判定 — founder 2026-09-24 (verbatim intent,
 *        narrowed same day after trying the whole-button-set version): 只有 shuffle/repeat
 *        圆形按钮需要自适应；像素太亮时图标不是纯黑，而是恰好过 3:1 WCAG 对比度门槛的中性灰
 *        （"灰色一点就行，保持对比度就好"），越暗的背景需要的灰越深但永远不到纯黑；平滑渐变
 *        过渡，滞后区保留。播放区（SharedBottomControls）与顶部两个按钮（Music/AirPlay）都
 *        不再经过这个机制，见 SharedControls.swift / HoverableButtons.swift / AudioOutputSwitcherView.swift
 *        的原始（feature 之前）规则。
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
    /// `ButtonIconGraySolve.lightness` to land EXACTLY on the 3:1 WCAG non-text contrast
    /// floor against the background it was resolved for — never darker than that solve,
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
/// plus p90-luminance sampling restricted to one button's own rect. Ported from
/// `research/spikes/legibility-gallery/.../CompositeSampler.swift` (Core Image
/// `CIGaussianBlur`, matching `NSImage+AverageColor.swift`'s established CIFilter-chain
/// pattern — SwiftUI `ImageRenderer` is this project's known flaky-test trap for
/// large-radius blur, see `lyrics_disk_preflight_and_flaky_tests.md`).
struct ButtonIconCompositeBitmap {
    let pixels: [UInt8] // RGBA8 premultiplied-last, row 0 = TOP of the image.
    let width: Int
    let height: Int
    let scale: CGFloat

    /// The p90-luminance pixel's own RGB inside `rect` — a near-worst-case sample, not an
    /// average (founder: "the exact few pixels directly under the button"), matching
    /// `CompositeBitmap.stats(rect:)`'s established convention in the gallery. `rect` uses
    /// `(x, distanceFromBottom)`.
    func p90Color(rect: ButtonIconRect) -> BackdropLegibilityBand.RGBColor? {
        let colLeft = max(0, Int((rect.x * scale).rounded(.down)))
        let colRight = min(width, Int(((rect.x + rect.width) * scale).rounded(.up)))
        let rowTop = max(0, Int((CGFloat(height) - (rect.distanceFromBottom + rect.height) * scale).rounded(.down)))
        let rowBottom = min(height, Int((CGFloat(height) - rect.distanceFromBottom * scale).rounded(.up)))
        guard colRight > colLeft, rowBottom > rowTop else { return nil }

        var samples: [(pixel: ButtonIconRGBPixel, luminance: Double)] = []
        samples.reserveCapacity((colRight - colLeft) * (rowBottom - rowTop))
        for row in rowTop..<rowBottom {
            for col in colLeft..<colRight {
                let offset = (row * width + col) * 4
                guard offset + 2 < pixels.count else { continue }
                let r = Double(pixels[offset]) / 255.0
                let g = Double(pixels[offset + 1]) / 255.0
                let b = Double(pixels[offset + 2]) / 255.0
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                samples.append((ButtonIconRGBPixel(r: r, g: g, b: b), luminance))
            }
        }
        guard !samples.isEmpty else { return nil }

        let sortedIndices = samples.indices.sorted { samples[$0].luminance < samples[$1].luminance }
        let p90Index = sortedIndices[Int((Double(sortedIndices.count - 1) * 0.9).rounded())]
        let winner = samples[p90Index].pixel
        return BackdropLegibilityBand.RGBColor(r: winner.r, g: winner.g, b: winner.b)
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
/// codebase already trusts to guarantee white-foreground legibility there (band ceiling
/// 4.5:1 — see the doc comment on `resolveAll` for why this means non-fullscreen icons
/// stay white by construction, not by a hardcoded exception).
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

// MARK: - Gray solve (founder 2026-09-24, "灰色一点就行，保持对比度就好")

/// Solves for a neutral gray icon colour that lands EXACTLY on the WCAG non-text 3:1
/// contrast floor against a given background — never a hardcoded pure black.
enum ButtonIconGraySolve {
    /// The WCAG non-text minimum this mechanism targets. The gray is solved to land
    /// EXACTLY here, so it is always "the lightest gray that still passes" — any lighter
    /// gray would fail 3:1 against this exact background.
    static let targetContrast: Double = 3.0

    /// A floor on the SOLVED gray's linear luminance so the result is never literally 0
    /// (pure black), matching the founder's "灰色一点就行" (some gray is enough, never
    /// black). Chosen well below any linear luminance this solve actually produces for a
    /// background bright enough to trigger it in the first place (see doc comment on
    /// `lightness`), so it only ever acts as a defensive floor, not a lived-in clamp.
    static let minimumLinearLuminance: Double = 0.02

    /// The lightest neutral gray (sRGB gamma, 0...1 — feed directly into
    /// `Color(white:)`/`ButtonIconTone.gray`) whose WCAG contrast against `background` is
    /// exactly `targetContrast`. Solves `(backgroundLuminance + 0.05) / (gray + 0.05) ==
    /// targetContrast` for the gray's own (linear) relative luminance, then converts back
    /// to sRGB gamma space — the same `srgbToLinear`/`linearToSRGB` round-trip
    /// `BackdropLegibilityBand`'s other channel-correct solves already use.
    static func lightness(background: BackdropLegibilityBand.RGBColor) -> Double {
        let backgroundLuminance = BackdropLegibilityBand.relativeLuminance(background)
        let solvedLinear = (backgroundLuminance + 0.05) / targetContrast - 0.05
        let clamped = min(max(solvedLinear, minimumLinearLuminance), 1)
        return BackdropLegibilityBand.linearToSRGB(clamped)
    }
}

// MARK: - Decision (WCAG threshold + hysteresis + gray solve)

/// The white/gray call for one button, given the colour under it and its PREVIOUS tone.
/// Hysteresis: switching white->gray needs contrast to drop below 3:1 (WCAG's non-text
/// minimum — a button icon is graphical UI, not body text); switching back gray->white
/// needs contrast to climb back up to >= 3.5:1, so a cover that sits right at the boundary
/// does not flicker every recompute. While staying gray, the exact lightness keeps
/// tracking the current background (continuous, not frozen at the moment it first flipped)
/// so a 0.25s cross-fade (`MiniPlayerView`) reads as smooth motion, never a snap.
enum ButtonIconDecision {
    /// Below this contrast, white no longer passes the WCAG 3:1 non-text minimum.
    static let grayThreshold: Double = 3.0
    /// Contrast must climb back up to this before returning to white.
    static let whiteThreshold: Double = 3.5

    static func resolve(color: BackdropLegibilityBand.RGBColor, previous: ButtonIconTone) -> ButtonIconTone {
        let contrast = BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(color))
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

    /// Working resolution for the fullscreen composite: panel size x1 (not x2 — a p90
    /// stat over a ~24pt button rect does not need retina-resolution sampling, and the
    /// render cost — CIGaussianBlur + a CGContext raster over the OUTPUT extent — scales
    /// with this, not with the source cover's own resolution, see
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
    /// guarantees white-foreground contrast >= 4.5:1 — strictly above this mechanism's
    /// 3:1 threshold. So non-fullscreen buttons are, by that existing invariant, always
    /// resolved white; this function still runs the real prediction (not a hardcoded
    /// `.white`) so it stays correct if that band's constants ever change.
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
                guard let color = bitmap.p90Color(rect: rect) else {
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
