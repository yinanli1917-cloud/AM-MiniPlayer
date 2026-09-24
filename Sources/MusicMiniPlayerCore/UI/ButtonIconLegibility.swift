import AppKit
import CoreImage
import SwiftUI

/**
 * [INPUT]: Depends on `ArtworkVisualMetrics`/`ArtworkBackgroundToneMap` (FluidGradientBackground.swift),
 *          `BackdropLegibilityBand` (RGBColor / relativeLuminance / whiteContrastRatio /
 *          fluidBackdropToneColor / resolveChannelCorrect / apply) for WCAG-correct contrast,
 *          `ArtworkContrastPolicy` + `MicroInteractionFeel` for the exact same C5 arm the
 *          live `FluidGradientBackground` reads, and raw artwork pixels via CoreGraphics /
 *          Core Image for the fullscreen hero composite (ported from
 *          research/spikes/legibility-gallery/.../CompositeSampler.swift, the founder-reviewed
 *          per-pixel renderer — round 1's whole-cover/band AVERAGE was rejected on sight
 *          2026-09-24: "what matters is the exact few pixels directly under each button").
 * [OUTPUT]: Exports `ButtonIconID` (every button/icon drawn over artwork on the album page),
 *           `ButtonIconRect` + `ButtonIconRects` (each button's real footprint in panel
 *           points, mirroring MiniPlayerView.swift/SharedControls.swift's own layout
 *           literals), `ButtonIconTone` (black/white), `ButtonIconDecision` (the WCAG
 *           threshold + hysteresis rule), and `ButtonIconLegibility.resolveAll` — the ONE
 *           mechanism every inventoried button asks for its icon colour.
 * [POS]: UI/ 的按钮图标可读性判定 — founder 2026-09-24 (verbatim intent): 检测按钮下面的像素
 *        过亮就把图标转黑，否则保持白色；只改图标颜色，不改玻璃材质/形状，不加光晕/阴影。
 *        Pure functions only (no SwiftUI view code) so they are unit-testable without
 *        hosting a window — MiniPlayerView.swift calls `resolveAll` once per artwork change
 *        (never per frame) and threads the per-button `ButtonIconTone` into
 *        HoverableActionButton / the shuffle-repeat cluster / SharedBottomControls.
 */

// MARK: - Button inventory

/// Every button/icon this mechanism drives, on the album page, fullscreen and
/// non-fullscreen, hover and non-hover (only hover renders them, but the rect/decision
/// math does not care). Selected-state tint colours (shuffle/repeat when ON) are NOT
/// part of this enum — those stay the existing theme-red, untouched.
enum ButtonIconID: CaseIterable, Hashable {
    case musicCapsule
    case airplay
    case shuffle
    case repeatButton
    case lyricsNav
    case playlistNav
    case backward
    case play
    case forward
}

enum ButtonIconTone: Equatable {
    case white
    case black
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

/// Real production rects, derived from the exact literals `MiniPlayerView.swift` /
/// `SharedControls.swift` already use — not re-measured guesses. Every button's rect is
/// IDENTICAL in fullscreen and non-fullscreen mode (padding(12) corners for the top
/// buttons; the bottom shuffle/repeat row + SharedBottomControls are laid out the same
/// way regardless of `fullscreenAlbumCover` — only the composite BEHIND them differs,
/// see `ButtonIconLegibility`).
enum ButtonIconRects {
    /// `SharedBottomControls.body`: `PlaybackProgressSection().frame(height: 32)` +
    /// `VStack(spacing: 4)` + the icon-row `HStack` (max child height 30, the
    /// `playbackCluster`'s `.frame(width: 30, height: 30)` buttons) + that VStack's own
    /// `.padding(.bottom, 16)`. No translation button on the album page (MiniPlayerView
    /// never passes one), so this IS `SharedBottomControls`'s full rendered height.
    private static let sharedBottomControlsHeight: CGFloat = 32 + 4 + 30 + 16

    /// `MiniPlayerView.albumOverlayContent`'s shuffle/repeat row: `.padding(.bottom, 4)`
    /// sits directly above `SharedBottomControls`.
    private static let shuffleRepeatRowBottomDistance: CGFloat = sharedBottomControlsHeight + 4

    /// The icon row's own vertical centre: `.padding(.bottom, 16)` + half the row's max
    /// height (30, `SharedControls.swift`'s `playbackCluster`). `leftNavigationButton` /
    /// `playlistNavigationButton` (26 tall) share the same HStack, default `.center`
    /// alignment, so their centres land on this same line.
    private static let iconRowCenterDistance: CGFloat = 16 + 15

    /// `MiniPlayerView.mainBody`'s `.overlay(alignment: .topLeading) { ... .padding(12) }`
    /// wrapping `MusicButtonView` — a `HoverableActionButton` capsule:
    /// `.padding(.horizontal, 10).padding(.vertical, 6)` around
    /// `HStack(spacing: 4) { Image(systemName: "arrow.up.left").font(size:10,weight:.semibold); Text("Music").font(size:11,weight:.medium) }`.
    static func musicCapsule(panelSize: CGSize) -> ButtonIconRect {
        let iconFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let iconSize = ("↖" as NSString).size(withAttributes: [.font: iconFont]) // arrow.up.left stand-in width
        let labelSize = ("Music" as NSString).size(withAttributes: [.font: labelFont])
        let width = iconSize.width + 4 + labelSize.width + 20 // HStack spacing 4 + h-padding 10+10
        let height = max(iconSize.height, labelSize.height) + 12 // v-padding 6+6
        return ButtonIconRect(x: 12, distanceFromBottom: panelSize.height - 12 - height, width: width, height: height)
    }

    /// `MiniPlayerView.mainBody`'s `.overlay(alignment: .topTrailing) { ... .padding(12) }`
    /// — either `AudioOutputSwitcherView` (`triggerSize == 32`, the default arm on the
    /// floating panel) or `ExpandButtonView` (a `HoverableActionButton` capsule around a
    /// single 12pt icon, comparable footprint). A single representative 32x32 box —
    /// same "representative, not pixel-identical" precedent the legibility-gallery's own
    /// `ElementLayout` uses for elements this module cannot reach a private layout for.
    static func airplay(panelSize: CGSize) -> ButtonIconRect {
        ButtonIconRect(x: panelSize.width - 12 - 32, distanceFromBottom: panelSize.height - 12 - 32, width: 32, height: 32)
    }

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

    /// `SharedControls.swift`'s `leftNavigationButton`: `.frame(width: 26, height: 26)`,
    /// `.padding(.horizontal, 12)` on the enclosing HStack pins it to the left inset.
    static func lyricsNav(panelSize: CGSize) -> ButtonIconRect {
        ButtonIconRect(x: 12, distanceFromBottom: iconRowCenterDistance - 13, width: 26, height: 26)
    }

    /// `SharedControls.swift`'s `playlistNavigationButton`: same 26x26 frame, right inset.
    static func playlistNav(panelSize: CGSize) -> ButtonIconRect {
        ButtonIconRect(x: panelSize.width - 12 - 26, distanceFromBottom: iconRowCenterDistance - 13, width: 26, height: 26)
    }

    /// `SharedControls.swift`'s `playbackCluster`: `HStack(spacing: 10)` of three
    /// `.frame(width: 30, height: 30)` buttons, centred in the icon row (the two 26pt nav
    /// buttons are equal-width, so the two `Spacer()`s either side centre the cluster at
    /// the row's own midpoint, `panelSize.width / 2`).
    static func backward(panelSize: CGSize) -> ButtonIconRect {
        ButtonIconRect(x: panelSize.width / 2 - 55, distanceFromBottom: iconRowCenterDistance - 15, width: 30, height: 30)
    }

    static func play(panelSize: CGSize) -> ButtonIconRect {
        ButtonIconRect(x: panelSize.width / 2 - 15, distanceFromBottom: iconRowCenterDistance - 15, width: 30, height: 30)
    }

    static func forward(panelSize: CGSize) -> ButtonIconRect {
        ButtonIconRect(x: panelSize.width / 2 + 25, distanceFromBottom: iconRowCenterDistance - 15, width: 30, height: 30)
    }

    static func rect(for id: ButtonIconID, panelSize: CGSize) -> ButtonIconRect {
        switch id {
        case .musicCapsule: return musicCapsule(panelSize: panelSize)
        case .airplay: return airplay(panelSize: panelSize)
        case .shuffle: return shuffle(panelSize: panelSize)
        case .repeatButton: return repeatButton(panelSize: panelSize)
        case .lyricsNav: return lyricsNav(panelSize: panelSize)
        case .playlistNav: return playlistNav(panelSize: panelSize)
        case .backward: return backward(panelSize: panelSize)
        case .play: return play(panelSize: panelSize)
        case .forward: return forward(panelSize: panelSize)
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

/// When `fullscreenAlbumCover` is off, every inventoried button is only ever visible
/// during hover — at which point `MiniPlayerView.floatingArtwork`'s non-fullscreen
/// artwork has already shrunk to 0.48x width, centred ABOVE the `controlsHeight`-tall
/// bottom band (`availableHeight = geo.height - controlsHeight`, `artCenterY =
/// availableHeight / 2`). None of the inventoried rects (top corners, shuffle/repeat,
/// SharedBottomControls) fall inside that shrunk cover's box at any panel size (the
/// layout is fraction-of-geometry throughout, so the relationship is scale-invariant) —
/// every one of them sits over `PanelBackdrop`'s fluid arm, i.e. `FluidGradientBackground`.
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

// MARK: - Decision (WCAG threshold + hysteresis)

/// The pure black/white call for one button, given the colour under it and its PREVIOUS
/// tone. Hysteresis: switching white->black needs contrast to drop below 3:1 (WCAG's
/// non-text minimum — a button icon is graphical UI, not body text); switching back
/// black->white needs contrast to climb back up to >= 3.5:1, so a cover that sits right
/// at the boundary does not flicker every recompute.
enum ButtonIconDecision {
    static let blackThreshold: Double = 3.0
    static let whiteThreshold: Double = 3.5

    static func resolve(color: BackdropLegibilityBand.RGBColor, previous: ButtonIconTone) -> ButtonIconTone {
        let contrast = BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(color))
        switch previous {
        case .white:
            return contrast < blackThreshold ? .black : .white
        case .black:
            return contrast >= whiteThreshold ? .white : .black
        }
    }
}

// MARK: - Top-level entry point

enum ButtonIconLegibility {
    /// `MiniPlayerView.floatingArtwork`'s fullscreen `blendHeight` literal.
    static let fullscreenHeroFadeHeight: CGFloat = 100

    /// Working resolution for the fullscreen composite: panel size x1 (not x2 — a p90
    /// stat over a ~30pt button rect does not need retina-resolution sampling, and the
    /// render cost — CIGaussianBlur + a CGContext raster over the OUTPUT extent — scales
    /// with this, not with the source cover's own resolution, see
    /// `ButtonIconCompositeSampler.render`'s doc comment and
    /// `ButtonIconLegibilityTests.test_cost_600And1200SourceArtwork_...`. 2026-09-24
    /// review: was x2; measured cost at x1 on a noisy 1200x1200 source is well under the
    /// test's 500ms guard (typically single-digit ms on Apple Silicon) — see the test for
    /// the actually-measured numbers, reported once per change in the PR/commit.
    static let fullscreenCompositeScale: CGFloat = 1

    /// Resolves every inventoried button's icon tone, once (call this on artwork change
    /// or `fullscreenAlbumCover` toggle — never per frame). `previous` supplies the
    /// hysteresis state; a missing id defaults to `.white` (today's colour, so a track
    /// with no prior computation never starts black).
    ///
    /// Fullscreen: real per-pixel hero+fade+Layer1 composite, sampled locally per button
    /// (round 1's rejected whole-cover average is NOT used here).
    ///
    /// Non-fullscreen: every button sits over the fluid backdrop (see
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
