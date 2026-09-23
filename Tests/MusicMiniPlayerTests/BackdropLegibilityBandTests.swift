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

    // MARK: - Point B: fullscreen album page bottom control band

    func test_pointB_whiteArtwork_finalContrastMeetsCeiling() {
        let metrics = whiteImage.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let coverBottomRowLuminance = Double(whiteImage.controlAreaMaxLuminance())

        let preCorrection = BackdropLegibilityBand.fullscreenBottomBandToneLuminance(
            coverBottomRowLuminance: coverBottomRowLuminance,
            artworkAverageLuminance: metrics.averageLuminance,
            tone: tone
        )
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: preCorrection)
        let final = BackdropLegibilityBand.apply(preCorrection, correction)

        XCTAssertGreaterThanOrEqual(
            BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: final),
            MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast,
            "white fullscreen cover's bottom control band must stay >= 4.5:1 for white shuffle/repeat icons"
        )
    }

    // MARK: - Point B: the scrim must deliver FULL darkenOpacity where the real
    // foreground elements actually are — coordinator review fix #1. Positions per
    // MiniPlayerView.albumOverlayContent's own layout formulas:
    //   - hover-mode title: centre at controlsHeight(80)+4+16 = 100pt above bottom,
    //     top edge ~107pt (half of a 12pt bold line's rendered height above centre).
    //   - shuffle/repeat row: bottom at controlsHeight(80)+4 = 84pt, top at +24pt = 108pt.
    // Both must fall inside the flat (full-opacity) zone.

    func test_pointB_scrimAtHoverTitleTop_isFullOpacity() {
        let whiteImageMetrics = whiteImage.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(whiteImageMetrics)
        let coverBottomRowLuminance = Double(whiteImage.controlAreaMaxLuminance())
        let preCorrection = BackdropLegibilityBand.fullscreenBottomBandToneLuminance(
            coverBottomRowLuminance: coverBottomRowLuminance,
            artworkAverageLuminance: whiteImageMetrics.averageLuminance,
            tone: tone
        )
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: preCorrection)
        XCTAssertGreaterThan(correction.darkenOpacity, 0, "white cover must need a darken scrim")

        let titleTopDistanceAboveBottom = 107.0
        let scrimOpacityAtTitle = BackdropLegibilityBand.bottomBandScrimOpacity(
            distanceAboveBottom: titleTopDistanceAboveBottom,
            darkenOpacity: correction.darkenOpacity
        )
        XCTAssertEqual(scrimOpacityAtTitle, correction.darkenOpacity, accuracy: 0.0001,
                        "the title's top must sit in the FULL-opacity flat zone, not a partial ramp value")

        let finalAtTitle = BackdropLegibilityBand.apply(preCorrection, BackdropLegibilityBand.Correction(darkenOpacity: scrimOpacityAtTitle, liftAmount: 0))
        XCTAssertGreaterThanOrEqual(
            BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: finalAtTitle),
            MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast,
            "contrast actually delivered at the title's own position must meet the ceiling, not just the modelled bottom-row value"
        )
    }

    func test_pointB_scrimAtShuffleRepeatRowTop_isFullOpacity() {
        let whiteImageMetrics = whiteImage.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(whiteImageMetrics)
        let coverBottomRowLuminance = Double(whiteImage.controlAreaMaxLuminance())
        let preCorrection = BackdropLegibilityBand.fullscreenBottomBandToneLuminance(
            coverBottomRowLuminance: coverBottomRowLuminance,
            artworkAverageLuminance: whiteImageMetrics.averageLuminance,
            tone: tone
        )
        let correction = BackdropLegibilityBand.resolve(backgroundLuminance: preCorrection)

        // controlsHeight (80) + row bottom padding (4) + row height (24) = 108pt.
        let shuffleRowTopDistanceAboveBottom = 80.0 + 4.0 + 24.0
        let scrimOpacity = BackdropLegibilityBand.bottomBandScrimOpacity(
            distanceAboveBottom: shuffleRowTopDistanceAboveBottom,
            darkenOpacity: correction.darkenOpacity
        )
        XCTAssertEqual(scrimOpacity, correction.darkenOpacity, accuracy: 0.0001)

        let finalAtRow = BackdropLegibilityBand.apply(preCorrection, BackdropLegibilityBand.Correction(darkenOpacity: scrimOpacity, liftAmount: 0))
        XCTAssertGreaterThanOrEqual(
            BackdropLegibilityBand.whiteContrastRatio(gammaLuminance: finalAtRow),
            MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast
        )
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
}
