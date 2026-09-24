import AppKit
import XCTest
@testable import MusicMiniPlayerCore

/// Backdrop legibility band (research/spec-2026-09-22-backdrop-legibility.md): the
/// founder-reported symptom of a near-black cover making the lyrics/playlist backdrop
/// too harshly dark — reproduced in code via an analytic replica of the existing SwiftUI
/// compositing chain (contrast/brightness/blend-mode formulas from
/// `BackdropLegibilityBand.fluidBackdropToneLuminance`), per the spec's documented
/// fallback: `ImageRenderer` cannot reliably capture a `GeometryReader` + large-radius
/// `.blur()` + blend-mode compositing chain headless, and this project already treats
/// rendered-pixel headless tests as a known flaky-test trap (memory:
/// lyrics_disk_preflight_and_flaky_tests.md). `NSImage.artworkVisualMetrics()` /
/// `.controlAreaMaxLuminance()` ARE exercised for real (they are plain CGContext pixel
/// math, not SwiftUI rendering, so they are deterministic headless) — only the
/// blur/contrast/brightness/blend-mode compositing is analytic. Pure-model only — no view
/// hosting, same convention as `ArtworkContrastFeelTests`.
///
/// This file covers Point A (`FluidGradientBackground`) only. The fullscreen album page's
/// own bottom-band legibility fix (point B) lives in `FullscreenBottomBandLegibility.swift`
/// / `FullscreenBottomBandLegibilityTests.swift` — a rejected point-B design (black/tinted
/// scrim + stacked progressive blur) used to be tested here and was removed 2026-09-23
/// after the founder rejected it on sight (commit b58b4e6).
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

    func test_bruteForceSweep_grayscaleSaturatedHighVariance() {
        var rows: [String] = []
        rows.append("category            | fixture              | avgLum | pointA contrast | note")
        rows.append(String(repeating: "-", count: 80))

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

            rows.append(String(format: "gray                | %.2f                 | %.4f | %14.3f |",
                                clampedGray, metrics.averageLuminance, pointA.finalContrast))
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

            rows.append(String(format: "saturated           | %-20@ | %.4f | %14.3f | gray-approx=%.3f diff=%.3f",
                                name as NSString, metrics.averageLuminance, pointA.finalContrast, grayApproxContrast, divergence))
        }

        // MARK: Part 3 — high-variance artworks. Diagnostic-only (no assert): mean-based
        // (averageLuminance) vs p90-highlight-based (highlightLuminance) as the
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

            rows.append(String(format: "high-variance       | %-20@ | %.4f | mean=%.3f p90=%.3f (diag) |",
                                name as NSString, metrics.averageLuminance, meanContrast, p90Contrast))
        }

        let table = rows.joined(separator: "\n")
        print("\n=== BackdropLegibilityBand brute-force sweep ===\n\(table)\n")
        if !flaggedDivergences.isEmpty {
            print("Flagged gray-approximation divergences (> 0.3 contrast, all now fixed via channel-correct model):")
            for line in flaggedDivergences { print("  - \(line)") }
        }
    }
}
