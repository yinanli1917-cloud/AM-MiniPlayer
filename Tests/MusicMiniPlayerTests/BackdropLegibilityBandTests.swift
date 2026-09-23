import AppKit
import XCTest
@testable import MusicMiniPlayerCore

/// Backdrop legibility band (research/spec-2026-09-22-backdrop-legibility.md): the two
/// founder-reported symptoms — a bright fullscreen album cover making the bottom
/// controls/text unreadable, and a near-black cover making the lyrics/playlist backdrop
/// too harshly dark — reproduced in code via an analytic replica of the existing SwiftUI
/// compositing chain (contrast/brightness/blend-mode formulas from
/// `BackdropLegibilityBand.fluidBackdropToneLuminance` /
/// `.fullscreenBottomBandToneLuminance`), per the spec's documented fallback:
/// `ImageRenderer` cannot reliably capture a `GeometryReader` + large-radius `.blur()` +
/// blend-mode compositing chain headless, and this project already treats rendered-pixel
/// headless tests as a known flaky-test trap (memory: lyrics_disk_preflight_and_flaky_tests.md).
/// `NSImage.artworkVisualMetrics()` / `.controlAreaMaxLuminance()` ARE exercised for real
/// (they are plain CGContext pixel math, not SwiftUI rendering, so they are deterministic
/// headless) — only the blur/contrast/brightness/blend-mode compositing is analytic.
/// Pure-model only — no view hosting, same convention as `ArtworkContrastFeelTests`.
final class BackdropLegibilityBandTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSolidImage(size: Int = 64, white: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(srgbRed: white, green: white, blue: white, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    private func makeTwoToneImage(size: Int = 64) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: size / 2, width: size, height: size / 2).fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: size, height: size / 2).fill()
        image.unlockFocus()
        return image
    }

    private var whiteImage: NSImage { makeSolidImage(white: 1.0) }
    private var nearBlackImage: NSImage { makeSolidImage(white: 10.0 / 255.0) } // #0A0A0A
    private var midGrayImage: NSImage { makeSolidImage(white: 0.5) }
    private var twoToneImage: NSImage { makeTwoToneImage() }

    private func makeSolidColorImage(size: Int = 64, r: CGFloat, g: CGFloat, b: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    /// top/bottom halves (NSRect y=0 is the BOTTOM in AppKit's flipped-off coordinate
    /// space used by `lockFocus`, matching `controlAreaMaxLuminance`'s own bottom-fraction
    /// sampling — `bottomColor` really does land in the sampled control band).
    private func makeHorizontalSplitImage(size: Int = 64, topColor: NSColor, bottomColor: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        topColor.setFill()
        NSRect(x: 0, y: size / 2, width: size, height: size / 2).fill()
        bottomColor.setFill()
        NSRect(x: 0, y: 0, width: size, height: size / 2).fill()
        image.unlockFocus()
        return image
    }

    private func makeVerticalSplitImage(size: Int = 64, leftColor: NSColor, rightColor: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        leftColor.setFill()
        NSRect(x: 0, y: 0, width: size / 2, height: size).fill()
        rightColor.setFill()
        NSRect(x: size / 2, y: 0, width: size / 2, height: size).fill()
        image.unlockFocus()
        return image
    }

    /// `baseColor` fills the whole image, `bottomQuarterColor` overwrites the bottom 25%
    /// (y=0...size/4 in lockFocus's bottom-origin space) — the region `controlAreaMaxLuminance`
    /// / `controlAreaMaxColor` actually sample (`bottomFraction` default 0.25).
    private func makeBottomQuarterImage(size: Int = 64, baseColor: NSColor, bottomQuarterColor: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        baseColor.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        bottomQuarterColor.setFill()
        NSRect(x: 0, y: 0, width: size, height: size / 4).fill()
        image.unlockFocus()
        return image
    }

    private func makeCheckerboardImage(size: Int = 64, squares: Int = 8) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let squareSize = size / squares
        for row in 0..<squares {
            for col in 0..<squares {
                let isWhite = (row + col).isMultiple(of: 2)
                (isWhite ? NSColor.white : NSColor.black).setFill()
                NSRect(x: col * squareSize, y: row * squareSize, width: squareSize, height: squareSize).fill()
            }
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Point A: FluidGradientBackground (lyrics / playlist / non-fullscreen album)
    //
    // `applyContrastDarken: false` matches the shipping default arm — `.legacy`, per the
    // 2026-09-14 founder decision baked into `MicroInteractionFeel.ArtworkContrastMode
    // .resolve(from:)` — i.e. exactly what the founder's build actually renders. (Note:
    // `MicroInteractionFeel.artworkContrast` itself cannot be read here to derive this
    // boolean — `isRunningTests` forces it to `.tuned` inside XCTest — so the boolean is
    // passed explicitly instead.)

    func test_pointA_whiteArtwork_finalContrastMeetsCeiling() {
        let metrics = whiteImage.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let contrastResolution = ArtworkContrastPolicy.resolve(
            brightness: metrics.averageLuminance, params: .default, reduceTransparency: false
        )
        let preCorrection = BackdropLegibilityBand.fluidBackdropToneLuminance(
            artworkAverageLuminance: metrics.averageLuminance,
            tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
        )
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: preCorrection)
        let final = BackdropLegibilityBand.apply(preCorrection, correction)

        XCTAssertGreaterThanOrEqual(
            BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: final),
            MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast,
            "white artwork's fluid backdrop must stay >= 4.5:1 for white text/icons"
        )
    }

    func test_pointA_nearBlackArtwork_finalContrastMeetsFloor() {
        let metrics = nearBlackImage.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let contrastResolution = ArtworkContrastPolicy.resolve(
            brightness: metrics.averageLuminance, params: .default, reduceTransparency: false
        )
        let preCorrection = BackdropLegibilityBand.fluidBackdropToneLuminance(
            artworkAverageLuminance: metrics.averageLuminance,
            tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
        )
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: preCorrection)
        let final = BackdropLegibilityBand.apply(preCorrection, correction)

        XCTAssertLessThanOrEqual(
            BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: final),
            MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast,
            "near-black artwork's fluid backdrop must not exceed a harsh 12:1 against white text"
        )
    }

    func test_pointA_midGrayArtwork_correctionIsZero() {
        let metrics = midGrayImage.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let contrastResolution = ArtworkContrastPolicy.resolve(
            brightness: metrics.averageLuminance, params: .default, reduceTransparency: false
        )
        let preCorrection = BackdropLegibilityBand.fluidBackdropToneLuminance(
            artworkAverageLuminance: metrics.averageLuminance,
            tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
        )
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: preCorrection)

        XCTAssertEqual(correction.darkenOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(correction.liftAmount, 0, accuracy: 0.0001)
    }

    func test_pointA_twoToneArtwork_recordsMeasuredContrast() {
        let metrics = twoToneImage.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let contrastResolution = ArtworkContrastPolicy.resolve(
            brightness: metrics.averageLuminance, params: .default, reduceTransparency: false
        )
        let preCorrection = BackdropLegibilityBand.fluidBackdropToneLuminance(
            artworkAverageLuminance: metrics.averageLuminance,
            tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
        )
        let contrast = BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: preCorrection)

        // Half-white/half-black lands right at the floor boundary (~12:1) before any
        // correction — recorded in research/spec-2026-09-22-backdrop-legibility.md rather
        // than pinned to a tight bound here, since it is a genuine edge case.
        XCTAssertTrue(contrast.isFinite)
    }

    // MARK: - Point A: floor lift is FOLDED into the existing inner brightness step
    // (no new resident filter) — coordinator review fix #2.

    func test_pointA_nearBlackArtwork_foldedInnerBrightness_reachesExactFloor() {
        let metrics = nearBlackImage.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let contrastResolution = ArtworkContrastPolicy.resolve(
            brightness: metrics.averageLuminance, params: .default, reduceTransparency: false
        )
        let preCorrection = BackdropLegibilityBand.fluidBackdropToneLuminance(
            artworkAverageLuminance: metrics.averageLuminance,
            tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
        )
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: preCorrection)
        XCTAssertGreaterThan(correction.liftAmount, 0, "near-black artwork must need a lift")

        // Exactly what production now does: fold the lift into tone.textureBrightness at
        // the EXISTING `.brightness()` modifier, instead of a new modifier on top.
        let delta = BackdropLegibilityBand.innerBrightnessDelta(
            liftAmount: correction.liftAmount, tone: tone,
            contrastResolution: contrastResolution, applyContrastDarken: false
        )
        let foldedFinal = BackdropLegibilityBand.fluidBackdropToneLuminance(
            artworkAverageLuminance: metrics.averageLuminance,
            tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false,
            textureBrightnessOverride: tone.textureBrightness + delta
        )

        // Must match the abstract apply() result (same correction, different mechanism)...
        let expectedFinal = BackdropLegibilityBand.apply(preCorrection, correction)
        XCTAssertEqual(foldedFinal, expectedFinal, accuracy: 0.0005)
        // ...and must still land exactly on the 12:1 floor.
        XCTAssertEqual(
            BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: foldedFinal),
            MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast,
            accuracy: 0.01
        )
    }

    func test_innerBrightnessDelta_zeroWhenNoLiftNeeded() {
        let tone = ArtworkBackgroundToneMap.neutral
        let contrastResolution = ArtworkContrastPolicy.resolve(brightness: 0.5, params: .default, reduceTransparency: false)
        let delta = BackdropLegibilityBand.innerBrightnessDelta(
            liftAmount: 0, tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
        )
        XCTAssertEqual(delta, 0)
    }

    // MARK: - Point B: fullscreen album page bottom control band (TINTED model,
    // research/progressive-blur-2026-09-23.md — blends toward `pointBTint`, an
    // artwork-derived dark colour, never Color.black).

    private func tintedPointBFixture(_ image: NSImage) -> (preCorrection: BackdropLegibilityBand.RGBColor, tint: BackdropLegibilityBand.RGBColor, correction: BackdropLegibilityBand.TintedCorrection) {
        let metrics = image.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let coverColorRaw = image.controlAreaMaxColor()
        let coverColor = BackdropLegibilityBand.RGBColor(r: coverColorRaw.r, g: coverColorRaw.g, b: coverColorRaw.b)
        let averageColor = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)
        let preCorrection = BackdropLegibilityBand.fullscreenBottomBandToneColor(coverBottomRowColor: coverColor, artworkAverageColor: averageColor, tone: tone)
        let tint = BackdropLegibilityBand.pointBTint(from: averageColor)
        let correction = BackdropLegibilityBand.resolveTinted(preCorrection: preCorrection, tint: tint)
        return (preCorrection, tint, correction)
    }

    func test_pointB_whiteArtwork_finalContrastMeetsCeiling() {
        let (preCorrection, _, correction) = tintedPointBFixture(whiteImage)
        let final = BackdropLegibilityBand.applyTinted(preCorrection, correction)

        // `resolveTinted` solves via bisection (unlike Point A's exact closed-form solve
        // for a pure-black target), so the boundary is reached to within floating-point
        // noise (~1e-15), not bit-exactly — same reasoning as the brute-force sweep's
        // `boundaryTolerance` below.
        XCTAssertGreaterThanOrEqual(
            BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(final)),
            MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast - 1e-9,
            "white fullscreen cover's bottom control band must stay >= 4.5:1 for white shuffle/repeat icons"
        )
    }

    // MARK: - Point B: the scrim must deliver FULL blendOpacity where the real
    // foreground elements actually are — coordinator review fix #1, still true under the
    // tinted model. Positions per MiniPlayerView.albumOverlayContent's own layout formulas:
    //   - hover-mode title: centre at controlsHeight(80)+4+16 = 100pt above bottom,
    //     top edge ~107pt (half of a 12pt bold line's rendered height above centre).
    //   - shuffle/repeat row: bottom at controlsHeight(80)+4 = 84pt, top at +24pt = 108pt.
    // Both must fall inside the flat (full-opacity) zone.

    func test_pointB_scrimAtHoverTitleTop_isFullOpacity() {
        let (preCorrection, _, correction) = tintedPointBFixture(whiteImage)
        XCTAssertGreaterThan(correction.blendOpacity, 0, "white cover must need a tinted scrim")
        XCTAssertNotEqual(correction.tint, BackdropLegibilityBand.RGBColor(r: 0, g: 0, b: 0),
                           "white artwork's tint must not be pure black")

        let titleTopDistanceAboveBottom = 107.0
        let scrimOpacityAtTitle = BackdropLegibilityBand.bottomBandScrimOpacity(
            distanceAboveBottom: titleTopDistanceAboveBottom,
            darkenOpacity: correction.blendOpacity
        )
        XCTAssertEqual(scrimOpacityAtTitle, correction.blendOpacity, accuracy: 0.0001,
                        "the title's top must sit in the FULL-opacity flat zone, not a partial ramp value")

        let finalAtTitle = BackdropLegibilityBand.applyTinted(
            preCorrection, BackdropLegibilityBand.TintedCorrection(blendOpacity: scrimOpacityAtTitle, liftAmount: 0, tint: correction.tint)
        )
        // Bisection-precision epsilon — see the comment in
        // test_pointB_whiteArtwork_finalContrastMeetsCeiling.
        XCTAssertGreaterThanOrEqual(
            BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(finalAtTitle)),
            MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast - 1e-9,
            "contrast actually delivered at the title's own position must meet the ceiling, not just the modelled bottom-row value"
        )
    }

    func test_pointB_scrimAtShuffleRepeatRowTop_isFullOpacity() {
        let (preCorrection, _, correction) = tintedPointBFixture(whiteImage)

        // controlsHeight (80) + row bottom padding (4) + row height (24) = 108pt.
        let shuffleRowTopDistanceAboveBottom = 80.0 + 4.0 + 24.0
        let scrimOpacity = BackdropLegibilityBand.bottomBandScrimOpacity(
            distanceAboveBottom: shuffleRowTopDistanceAboveBottom,
            darkenOpacity: correction.blendOpacity
        )
        XCTAssertEqual(scrimOpacity, correction.blendOpacity, accuracy: 0.0001)

        let finalAtRow = BackdropLegibilityBand.applyTinted(
            preCorrection, BackdropLegibilityBand.TintedCorrection(blendOpacity: scrimOpacity, liftAmount: 0, tint: correction.tint)
        )
        // Bisection-precision epsilon — see the comment in
        // test_pointB_whiteArtwork_finalContrastMeetsCeiling.
        XCTAssertGreaterThanOrEqual(
            BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(finalAtRow)),
            MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast - 1e-9
        )
    }

    // MARK: - Point B tint: never Color.black, and proportional to the artwork.

    func test_pointBTint_neverPureBlack_forNonBlackArtwork() {
        let samples: [BackdropLegibilityBand.RGBColor] = [
            .init(r: 1, g: 1, b: 1),       // white cover (the founder's reported case)
            .init(r: 0.9, g: 0.2, b: 0.2), // saturated red cover
            .init(r: 0.5, g: 0.5, b: 0.5), // mid gray
            .init(r: 0.02, g: 0.02, b: 0.02), // near-black but not literal black
        ]
        for color in samples {
            let tint = BackdropLegibilityBand.pointBTint(from: color)
            XCTAssertNotEqual(tint, BackdropLegibilityBand.RGBColor(r: 0, g: 0, b: 0),
                               "tint for \(color) must not collapse to pure black")
            // Hue-preserving: the tint is a fixed positive scalar multiple of the input.
            let shadeFactor = MicroInteractionFeel.Tokens.backdropLegibilityBottomBandTintShadeFactor
            XCTAssertEqual(tint.r, color.r * shadeFactor, accuracy: 0.0001)
            XCTAssertEqual(tint.g, color.g * shadeFactor, accuracy: 0.0001)
            XCTAssertEqual(tint.b, color.b * shadeFactor, accuracy: 0.0001)
        }
    }

    func test_pointBTint_literalBlackArtworkStaysBlack() {
        // The only input for which the tint is (0,0,0) is a literally-black artwork —
        // "darkened toward the artwork's own colour" degenerately has nothing to derive
        // from, not a hardcoded Color.black default.
        let tint = BackdropLegibilityBand.pointBTint(from: .init(r: 0, g: 0, b: 0))
        XCTAssertEqual(tint, BackdropLegibilityBand.RGBColor(r: 0, g: 0, b: 0))
    }

    // MARK: - Tint gradient: C1-smooth (no discontinuity in value OR slope) at both zone
    // boundaries — this is what actually fixes the founder's "visible top edge" complaint;
    // the OLD linear ramp was already continuous in VALUE (see
    // `test_bottomBandScrimOpacity_fadesToClearAboveTheFlatZone` below) but had a slope
    // discontinuity the eye reads as an edge.

    func test_bottomBandScrimOpacity_isC1SmoothAcrossZoneBoundaries() {
        let darkenOpacity = 0.6
        let flatHeight = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFlatHeight)
        let fadeHeight = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFadeHeight)

        func opacity(_ d: Double) -> Double {
            BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom: d, darkenOpacity: darkenOpacity)
        }
        func derivative(at d: Double, step: Double = 0.001) -> Double {
            (opacity(d + step) - opacity(d - step)) / (2 * step)
        }

        // Value continuity at both boundaries.
        XCTAssertEqual(opacity(flatHeight - 0.01), opacity(flatHeight + 0.01), accuracy: 0.01)
        XCTAssertEqual(opacity(flatHeight + fadeHeight - 0.01), opacity(flatHeight + fadeHeight + 0.01), accuracy: 0.01)

        // Slope continuity. A LINEAR fade has slope 0 in the flat zone but
        // -darkenOpacity/fadeHeight (~ -0.0136 here) just inside the fade zone — a jump of
        // that whole magnitude, which the 0.003 tolerance below would catch. Smoothstep's
        // derivative is 0 at both ends of the fade zone by construction, so the measured
        // jump for the shipped curve is orders of magnitude smaller than that tolerance.
        let slopeBelowFlatBoundary = derivative(at: flatHeight - 0.05)
        let slopeAboveFlatBoundary = derivative(at: flatHeight + 0.05)
        XCTAssertEqual(slopeBelowFlatBoundary, slopeAboveFlatBoundary, accuracy: 0.003,
                        "no kink where the flat zone meets the fade zone")

        let slopeBelowFadeTop = derivative(at: flatHeight + fadeHeight - 0.05)
        let slopeAboveFadeTop = derivative(at: flatHeight + fadeHeight + 0.05)
        XCTAssertEqual(slopeBelowFadeTop, slopeAboveFadeTop, accuracy: 0.003,
                        "no kink where the fade zone meets clear")
    }

    func test_bottomBandScrimGradientStops_matchesPureFunctionShape() {
        let stops = BackdropLegibilityBand.bottomBandScrimGradientStops()
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.first?.opacityFraction ?? -1, 0, accuracy: 0.0001, "top of the band is clear")
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops.last?.opacityFraction ?? -1, 1, accuracy: 0.0001, "bottom edge is full opacity")

        // Monotonically non-decreasing top -> bottom (the curve never dips back down).
        for i in 1..<stops.count {
            XCTAssertGreaterThanOrEqual(stops[i].opacityFraction, stops[i - 1].opacityFraction - 0.0001)
        }
    }

    // MARK: - Point B pure-SwiftUI progressive blur recipe (round 2 — no Metal). See
    // `test_pointBPath_doesNotReferenceMetalShaderOrBundleModule` below for the guard that
    // production actually stays on this path.

    func test_heroBottomBandBlurLayers_radiiIncreaseMonotonically() {
        let layers = BackdropLegibilityBand.heroBottomBandBlurLayers()
        XCTAssertEqual(layers.count, MicroInteractionFeel.Tokens.backdropLegibilityBottomBandBlurLayerCount)
        for i in 1..<layers.count {
            XCTAssertGreaterThan(layers[i].radius, layers[i - 1].radius, "layer \(i) must blur MORE than layer \(i - 1)")
        }
        XCTAssertEqual(layers.last?.radius ?? -1, MicroInteractionFeel.Tokens.backdropLegibilityBottomBandBlurRadius, accuracy: 0.001,
                        "the strongest (last/frontmost) layer reaches the configured max radius")
    }

    func test_heroBottomBandBlurLayers_revealSpanShrinksAsRadiusGrows() {
        // Layer 1 (weakest) must reach across the WHOLE band; the strongest layer must be
        // confined to a narrow strip right at the bottom edge — this is what makes the
        // z-ordered composite (weakest drawn first/back, strongest last/front) read as
        // increasing blur toward the bottom rather than a uniform wash.
        let bandHeight = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFlatHeight)
            + Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFadeHeight)
        let layers = BackdropLegibilityBand.heroBottomBandBlurLayers()

        let weakestSpan = layers[0].flatHeight + layers[0].fadeHeight
        XCTAssertEqual(weakestSpan, bandHeight, accuracy: 0.01, "the weakest layer must span the entire band")

        for i in 1..<layers.count {
            let spanPrev = layers[i - 1].flatHeight + layers[i - 1].fadeHeight
            let span = layers[i].flatHeight + layers[i].fadeHeight
            XCTAssertLessThan(span, spanPrev, "layer \(i)'s reveal span must be smaller than layer \(i - 1)'s (stronger blur = narrower, closer to the bottom edge)")
        }
    }

    func test_heroBottomBandBlurLayers_emptyForNonPositiveInputs() {
        XCTAssertTrue(BackdropLegibilityBand.heroBottomBandBlurLayers(layerCount: 0).isEmpty)
        XCTAssertTrue(BackdropLegibilityBand.heroBottomBandBlurLayers(maxRadius: 0).isEmpty)
        XCTAssertTrue(BackdropLegibilityBand.heroBottomBandBlurLayers(bandHeight: 0).isEmpty)
    }

    // MARK: - Guard: the Point-B production path must not use the Metal shader / resource
    // bundle machinery. Coordinator review of commit 968a05d found `xcrun metal` fails with
    // "missing Metal Toolchain" on this machine, so `.metal` sources never compile to a
    // usable .metallib, and `build_app.sh` never copies `MusicMiniPlayerCore`'s resource
    // bundle into nanoPod.app — `ShaderLibrary.bundle(Bundle.module)` would fail at runtime
    // in the shipped app even though `swift build` looks clean. A pure-function test can't
    // catch a SwiftUI view calling the wrong API, so this reads MiniPlayerView.swift's own
    // source text (read-only, no I/O outside the repo) and asserts neither name appears.

    private func repoRootURL(from fileURL: URL) -> URL {
        var dir = fileURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            let parent = dir.deletingLastPathComponent()
            if parent == dir { return dir } // reached filesystem root without finding it
            dir = parent
        }
        return dir
    }

    func test_pointBPath_doesNotReferenceMetalShaderOrBundleModule() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let miniPlayerViewURL = root.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift")
        let source = try String(contentsOf: miniPlayerViewURL, encoding: .utf8)

        // Scoped to the Point-B region only (albumOverlayContent ... heroBottomBandBlurLayer,
        // bounded by these two stable `// MARK:` anchors) — NOT the whole file. The file's
        // `#if DEBUG` PreviewProvider legitimately uses `Bundle.module` to load sample
        // wallpaper/artwork images for Xcode previews; that is unrelated to Point B's runtime
        // path and would make a whole-file scan permanently fail for an unrelated reason.
        let startMarker = "// MARK: - Album Overlay Content"
        let endMarker = "// MARK: - Album Page Content"
        guard let startRange = source.range(of: startMarker), let endRange = source.range(of: endMarker) else {
            XCTFail("could not locate the Point-B region anchors — MiniPlayerView.swift's structure changed; update this test's markers")
            return
        }
        let pointBRegion = String(source[startRange.lowerBound..<endRange.lowerBound])

        XCTAssertFalse(pointBRegion.contains("ShaderLibrary"),
                        "MiniPlayerView's Point-B path must not call the Metal ShaderLibrary path — it has no compiled .metallib on this toolchain and no resource bundle in the shipped app")
        XCTAssertFalse(pointBRegion.contains("Bundle.module"),
                        "MiniPlayerView's Point-B path must not trigger new Bundle.module resource loading — build_app.sh does not copy MusicMiniPlayerCore's resource bundle into nanoPod.app")
        XCTAssertFalse(pointBRegion.contains("ConditionalProgressiveBlur"),
                        "Point B must not reference the Metal-shader-backed ProgressiveBlurView.swift modifier")
    }

    func test_bottomBandScrimOpacity_fadesToClearAboveTheFlatZone() {
        let flatHeight = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFlatHeight)
        let fadeHeight = Double(MicroInteractionFeel.Tokens.backdropLegibilityBottomBandFadeHeight)

        XCTAssertEqual(BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom: 0, darkenOpacity: 0.5), 0.5)
        XCTAssertEqual(BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom: flatHeight, darkenOpacity: 0.5), 0.5,
                        "the flat/fade boundary itself is still full opacity")
        XCTAssertEqual(BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom: flatHeight + fadeHeight / 2, darkenOpacity: 0.5), 0.25, accuracy: 0.001)
        XCTAssertEqual(BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom: flatHeight + fadeHeight, darkenOpacity: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom: flatHeight + fadeHeight + 50, darkenOpacity: 0.5), 0)
    }

    func test_bottomBandScrimOpacity_zeroDarkenIsAlwaysZero() {
        XCTAssertEqual(BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom: 0, darkenOpacity: 0), 0)
    }

    // MARK: - Band function contract (continuity + boundaries)

    func test_resolve_exactlyAtCeilingBoundary_correctionIsZero() {
        let ceiling = MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast
        let boundaryLuminance = BackdropLegibilityBand.linearToSRGB((1.0 + 0.05) / ceiling - 0.05)
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: boundaryLuminance)
        XCTAssertEqual(correction.darkenOpacity, 0, accuracy: 0.0005)
        XCTAssertEqual(correction.liftAmount, 0, accuracy: 0.0005)
    }

    func test_resolve_exactlyAtFloorBoundary_correctionIsZero() {
        let floor = MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast
        let boundaryLuminance = BackdropLegibilityBand.linearToSRGB((1.0 + 0.05) / floor - 0.05)
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: boundaryLuminance)
        XCTAssertEqual(correction.darkenOpacity, 0, accuracy: 0.0005)
        XCTAssertEqual(correction.liftAmount, 0, accuracy: 0.0005)
    }

    func test_resolve_continuousAcrossCeilingBoundary_noHardJump() {
        let ceiling = MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast
        let boundary = BackdropLegibilityBand.linearToSRGB((1.0 + 0.05) / ceiling - 0.05)

        let justBelow = BackdropLegibilityBand.resolve(backgroundLuminance: boundary - 0.01)
        let justAbove = BackdropLegibilityBand.resolve(backgroundLuminance: boundary + 0.01)

        XCTAssertEqual(justBelow.darkenOpacity, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(justAbove.darkenOpacity, 0)
        XCTAssertLessThan(justAbove.darkenOpacity, 0.05, "no hard jump — correction near the boundary must be small")
    }

    func test_resolve_continuousAcrossFloorBoundary_noHardJump() {
        let floor = MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast
        let boundary = BackdropLegibilityBand.linearToSRGB((1.0 + 0.05) / floor - 0.05)

        let justAbove = BackdropLegibilityBand.resolve(backgroundLuminance: boundary + 0.01)
        let justBelow = BackdropLegibilityBand.resolve(backgroundLuminance: boundary - 0.01)

        XCTAssertEqual(justAbove.liftAmount, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(justBelow.liftAmount, 0)
        XCTAssertLessThan(justBelow.liftAmount, 0.05, "no hard jump — correction near the boundary must be small")
    }

    func test_resolve_darkensPureWhiteToExactCeiling() {
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: 1.0)
        let final = BackdropLegibilityBand.apply(1.0, correction)
        XCTAssertEqual(
            BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: final),
            MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast,
            accuracy: 0.01
        )
    }

    func test_resolve_liftsPureBlackToExactFloor() {
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: 0.0)
        let final = BackdropLegibilityBand.apply(0.0, correction)
        XCTAssertEqual(
            BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: final),
            MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast,
            accuracy: 0.01
        )
    }

    // MARK: - Brute-force sweep (coordinator review, 2026-09-22 round 3)
    //
    // One combined table across three categories, all exercised through the REAL
    // `artworkVisualMetrics()` / `controlAreaMaxColor()` (or `controlAreaMaxLuminance()`
    // for the grayscale high-variance fixtures) + tone map + band path — not hand-fed
    // metrics. `applyContrastDarken: false` throughout (shipping `.legacy` default, see
    // the Point A section note above).

    private static let ceiling = MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast
    private static let floor = MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast
    private static let boundaryTolerance = 0.01
    private static let hoverTitleTopDistance = 107.0
    private static let shuffleRowTopDistance = 80.0 + 4.0 + 24.0 // controlsHeight + row padding + row height

    private struct PointAResult {
        let preColor: BackdropLegibilityBand.RGBColor
        let correction: BackdropLegibilityBand.Correction
        let finalContrast: Double
    }

    private func evaluatePointA(_ image: NSImage) -> (metrics: ArtworkVisualMetrics, result: PointAResult) {
        let metrics = image.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let contrastResolution = ArtworkContrastPolicy.resolve(
            brightness: metrics.averageLuminance, params: .default, reduceTransparency: false
        )
        let preColor = BackdropLegibilityBand.fluidBackdropToneColor(
            artworkAverageColor: BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue),
            tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
        )
        let correction = BackdropLegibilityBand.resolveChannelCorrect(preCorrection: preColor)
        let final = BackdropLegibilityBand.apply(preColor, correction)
        let contrast = BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(final))
        return (metrics, PointAResult(preColor: preColor, correction: correction, finalContrast: contrast))
    }

    /// Contrast actually delivered at the title/shuffle-row positions — production only
    /// ever renders the BLEND (tint) portion of the point-B correction (never a lift), so
    /// this mirrors that: the scrim opacity at `distance`, blended toward `tint` on top of
    /// the pre-correction colour, ignoring any lift `resolveTinted` may have also computed.
    private func pointBContrastAtDistance(_ distance: Double, preColor: BackdropLegibilityBand.RGBColor, tint: BackdropLegibilityBand.RGBColor, blendOpacity: Double) -> Double {
        let scrimOpacity = BackdropLegibilityBand.bottomBandScrimOpacity(distanceAboveBottom: distance, darkenOpacity: blendOpacity)
        let final = BackdropLegibilityBand.applyTinted(preColor, BackdropLegibilityBand.TintedCorrection(blendOpacity: scrimOpacity, liftAmount: 0, tint: tint))
        return BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(final))
    }

    func test_bruteForceSweep_grayscaleSaturatedHighVariance() {
        var rows: [String] = []
        rows.append("category            | fixture              | avgLum | pointA contrast | pointB@title | pointB@row | note")
        rows.append(String(repeating: "-", count: 100))

        // MARK: Part 1 — grayscale sweep, 0.00...1.00 step 0.02 (51 points).
        var gray = 0.0
        while gray <= 1.0 + 1e-9 {
            let clampedGray = min(gray, 1.0)
            let image = makeSolidImage(white: CGFloat(clampedGray))
            let (metrics, pointA) = evaluatePointA(image)

            XCTAssertGreaterThanOrEqual(pointA.finalContrast, Self.ceiling - Self.boundaryTolerance,
                                         "gray \(clampedGray) pointA below ceiling: \(pointA.finalContrast)")
            XCTAssertLessThanOrEqual(pointA.finalContrast, Self.floor + Self.boundaryTolerance,
                                      "gray \(clampedGray) pointA above floor: \(pointA.finalContrast)")

            let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
            let coverColorRaw = image.controlAreaMaxColor()
            let coverColor = BackdropLegibilityBand.RGBColor(r: coverColorRaw.r, g: coverColorRaw.g, b: coverColorRaw.b)
            let averageColor = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)
            let preColorB = BackdropLegibilityBand.fullscreenBottomBandToneColor(coverBottomRowColor: coverColor, artworkAverageColor: averageColor, tone: tone)
            let tintB = BackdropLegibilityBand.pointBTint(from: averageColor)
            let correctionB = BackdropLegibilityBand.resolveTinted(preCorrection: preColorB, tint: tintB)
            let titleContrast = pointBContrastAtDistance(Self.hoverTitleTopDistance, preColor: preColorB, tint: tintB, blendOpacity: correctionB.blendOpacity)
            let rowContrast = pointBContrastAtDistance(Self.shuffleRowTopDistance, preColor: preColorB, tint: tintB, blendOpacity: correctionB.blendOpacity)

            XCTAssertGreaterThanOrEqual(titleContrast, Self.ceiling - Self.boundaryTolerance, "gray \(clampedGray) pointB@title below ceiling: \(titleContrast)")
            XCTAssertGreaterThanOrEqual(rowContrast, Self.ceiling - Self.boundaryTolerance, "gray \(clampedGray) pointB@row below ceiling: \(rowContrast)")

            rows.append(String(format: "gray                | %.2f                 | %.4f | %14.3f | %12.3f | %10.3f |",
                                clampedGray, metrics.averageLuminance, pointA.finalContrast, titleContrast, rowContrast))
            gray += 0.02
        }

        // MARK: Part 2 — saturated solids. Reports divergence vs the OLD gray-luminance
        // approximation (scalar `resolve`/`fluidBackdropToneLuminance` fed the gamma-mixed
        // `averageLuminance` directly) alongside the NEW channel-correct result production
        // now uses.
        let saturatedSwatches: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("red", 1, 0, 0), ("green", 0, 1, 0), ("blue", 0, 0, 1),
            ("yellow", 1, 1, 0), ("cyan", 0, 1, 1), ("magenta", 1, 0, 1),
            ("dark_navy", 0.05, 0.05, 0.2), ("pale_pastel", 0.9, 0.85, 0.95),
        ]
        var flaggedDivergences: [String] = []
        for (name, r, g, b) in saturatedSwatches {
            let image = makeSolidColorImage(r: r, g: g, b: b)
            let (metrics, pointA) = evaluatePointA(image)

            // OLD gray-luminance approximation, for comparison only.
            let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
            let contrastResolution = ArtworkContrastPolicy.resolve(brightness: metrics.averageLuminance, params: .default, reduceTransparency: false)
            let grayPre = BackdropLegibilityBand.fluidBackdropToneLuminance(
                artworkAverageLuminance: metrics.averageLuminance, tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
            )
            let grayCorrection = BackdropLegibilityBand.resolve(backgroundLuminance: grayPre)
            let grayFinal = BackdropLegibilityBand.apply(grayPre, grayCorrection)
            let grayApproxContrast = BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: grayFinal)
            let divergence = pointA.finalContrast - grayApproxContrast
            if abs(divergence) > 0.3 {
                flaggedDivergences.append("\(name): channel-correct=\(String(format: "%.3f", pointA.finalContrast)) gray-approx=\(String(format: "%.3f", grayApproxContrast)) diff=\(String(format: "%.3f", divergence))")
            }

            XCTAssertGreaterThanOrEqual(pointA.finalContrast, Self.ceiling - Self.boundaryTolerance, "\(name) pointA below ceiling: \(pointA.finalContrast)")
            XCTAssertLessThanOrEqual(pointA.finalContrast, Self.floor + Self.boundaryTolerance, "\(name) pointA above floor: \(pointA.finalContrast)")

            let coverColorRaw = image.controlAreaMaxColor()
            let coverColor = BackdropLegibilityBand.RGBColor(r: coverColorRaw.r, g: coverColorRaw.g, b: coverColorRaw.b)
            let averageColor = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)
            let preColorB = BackdropLegibilityBand.fullscreenBottomBandToneColor(coverBottomRowColor: coverColor, artworkAverageColor: averageColor, tone: tone)
            let tintB = BackdropLegibilityBand.pointBTint(from: averageColor)
            let correctionB = BackdropLegibilityBand.resolveTinted(preCorrection: preColorB, tint: tintB)
            let titleContrast = pointBContrastAtDistance(Self.hoverTitleTopDistance, preColor: preColorB, tint: tintB, blendOpacity: correctionB.blendOpacity)
            let rowContrast = pointBContrastAtDistance(Self.shuffleRowTopDistance, preColor: preColorB, tint: tintB, blendOpacity: correctionB.blendOpacity)

            XCTAssertGreaterThanOrEqual(titleContrast, Self.ceiling - Self.boundaryTolerance, "\(name) pointB@title below ceiling: \(titleContrast)")
            XCTAssertGreaterThanOrEqual(rowContrast, Self.ceiling - Self.boundaryTolerance, "\(name) pointB@row below ceiling: \(rowContrast)")

            rows.append(String(format: "saturated           | %-20@ | %.4f | %14.3f | %12.3f | %10.3f | gray-approx=%.3f diff=%.3f",
                                name as NSString, metrics.averageLuminance, pointA.finalContrast, titleContrast, rowContrast, grayApproxContrast, divergence))
        }

        // MARK: Part 3 — high-variance artworks. Point B uses `controlAreaMaxLuminance`
        // (scalar) as instructed — these fixtures are pure black/white so the scalar and
        // channel-correct models agree exactly. Point A is diagnostic-only (no assert):
        // mean-based (averageLuminance) vs p90-highlight-based (highlightLuminance) as the
        // representative input luminance.
        let highVarianceFixtures: [(String, NSImage)] = [
            ("half_vertical", makeVerticalSplitImage(leftColor: .white, rightColor: .black)),
            ("half_horizontal", makeHorizontalSplitImage(topColor: .white, bottomColor: .black)),
            ("white_black_bottomQ", makeBottomQuarterImage(baseColor: .white, bottomQuarterColor: .black)),
            ("black_white_bottomQ", makeBottomQuarterImage(baseColor: .black, bottomQuarterColor: .white)),
            ("checkerboard", makeCheckerboardImage()),
        ]
        for (name, image) in highVarianceFixtures {
            let metrics = image.artworkVisualMetrics()
            let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
            let contrastResolution = ArtworkContrastPolicy.resolve(brightness: metrics.averageLuminance, params: .default, reduceTransparency: false)

            // Point A diagnostics (no assert): mean-based vs p90-highlight-based.
            let meanPre = BackdropLegibilityBand.fluidBackdropToneLuminance(
                artworkAverageLuminance: metrics.averageLuminance, tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
            )
            let meanFinal = BackdropLegibilityBand.apply(meanPre, BackdropLegibilityBand.resolve(backgroundLuminance: meanPre))
            let meanContrast = BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: meanFinal)

            let p90Pre = BackdropLegibilityBand.fluidBackdropToneLuminance(
                artworkAverageLuminance: metrics.highlightLuminance, tone: tone, contrastResolution: contrastResolution, applyContrastDarken: false
            )
            let p90Final = BackdropLegibilityBand.apply(p90Pre, BackdropLegibilityBand.resolve(backgroundLuminance: p90Pre))
            let p90Contrast = BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: p90Final)

            // Point B (tinted model): scalar `controlAreaMaxLuminance`, replicated across
            // R/G/B (these fixtures are pure black/white, where the scalar and
            // channel-correct models agree exactly, per the note above), tint from the
            // artwork's own average colour, asserted >= ceiling.
            let coverLuminance = Double(image.controlAreaMaxLuminance())
            let coverColorB = BackdropLegibilityBand.RGBColor(r: coverLuminance, g: coverLuminance, b: coverLuminance)
            let averageColorB = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)
            let preColorB = BackdropLegibilityBand.fullscreenBottomBandToneColor(coverBottomRowColor: coverColorB, artworkAverageColor: averageColorB, tone: tone)
            let tintB = BackdropLegibilityBand.pointBTint(from: averageColorB)
            let correctionB = BackdropLegibilityBand.resolveTinted(preCorrection: preColorB, tint: tintB)
            let titleContrast = pointBContrastAtDistance(Self.hoverTitleTopDistance, preColor: preColorB, tint: tintB, blendOpacity: correctionB.blendOpacity)
            let rowContrast = pointBContrastAtDistance(Self.shuffleRowTopDistance, preColor: preColorB, tint: tintB, blendOpacity: correctionB.blendOpacity)

            XCTAssertGreaterThanOrEqual(titleContrast, Self.ceiling - Self.boundaryTolerance, "\(name) pointB@title below ceiling: \(titleContrast)")
            XCTAssertGreaterThanOrEqual(rowContrast, Self.ceiling - Self.boundaryTolerance, "\(name) pointB@row below ceiling: \(rowContrast)")

            rows.append(String(format: "high-variance       | %-20@ | %.4f | mean=%.3f p90=%.3f (diag) | %12.3f | %10.3f |",
                                name as NSString, metrics.averageLuminance, meanContrast, p90Contrast, titleContrast, rowContrast))
        }

        let table = rows.joined(separator: "\n")
        print("\n=== BackdropLegibilityBand brute-force sweep ===\n\(table)\n")
        if !flaggedDivergences.isEmpty {
            print("Flagged gray-approximation divergences (> 0.3 contrast, all now fixed via channel-correct model):")
            for line in flaggedDivergences { print("  - \(line)") }
        }
    }
}
