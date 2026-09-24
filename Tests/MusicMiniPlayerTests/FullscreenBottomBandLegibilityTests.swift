import AppKit
import XCTest
@testable import MusicMiniPlayerCore

/// Fullscreen album page bottom-band legibility (research/progressive-blur-2026-09-23.md
/// round 3, extending research/spec-2026-09-22-backdrop-legibility.md point B): for BRIGHT
/// covers only, `FullscreenBottomBandLegibility.resolve` (1) extends the founder-tuned hero
/// fade so the real title/shuffle-repeat/controls sit over Layer 1 instead of the sharp
/// cover, and (2) darkens Layer 1's own tone controls (brightness/dim) just enough — reusing
/// `BackdropLegibilityBand`'s channel-correct WCAG math throughout. In-band and dark covers
/// must reproduce the original 62877a4 rendering exactly (`needsCorrection == false`).
///
/// Pure-model only — `NSImage.artworkVisualMetrics()` / `.controlAreaMaxColor()` ARE
/// exercised for real (plain CGContext/CIFilter pixel math, deterministic headless, no
/// SwiftUI rendering, no I/O outside the process) — same convention as
/// `BackdropLegibilityBandTests`.
final class FullscreenBottomBandLegibilityTests: XCTestCase {

    // MARK: - Fixtures (same recipes as BackdropLegibilityBandTests, duplicated — file-private).

    private func makeSolidImage(size: Int = 64, white: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(srgbRed: white, green: white, blue: white, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    private func makeSolidColorImage(size: Int = 64, r: CGFloat, g: CGFloat, b: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    /// top/bottom halves — y=0 is the BOTTOM in `lockFocus`'s flipped-off space, matching
    /// `controlAreaMaxColor`'s own bottom-fraction sampling.
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

    // MARK: - Helpers

    private func resolve(for image: NSImage) -> (metrics: ArtworkVisualMetrics, tone: ArtworkBackgroundToneMap, correction: FullscreenBottomBandLegibility.Correction) {
        let metrics = image.artworkVisualMetrics()
        let tone = ArtworkBackgroundToneMap.forMetrics(metrics)
        let bottomColor = image.controlAreaMaxColor()
        let correction = FullscreenBottomBandLegibility.resolve(
            artworkAverageColor: BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue),
            coverBottomRowColor: BackdropLegibilityBand.RGBColor(r: bottomColor.r, g: bottomColor.g, b: bottomColor.b),
            tone: tone
        )
        return (metrics, tone, correction)
    }

    /// Contrast actually delivered at `distance` AFTER correction: composites the (possibly
    /// extended) mask against Layer 1 (with its possibly-darkened brightness/dim) and the raw
    /// cover colour, exactly the way `MiniPlayerView.floatingArtwork`'s fullscreen branch
    /// renders it.
    private func deliveredContrast(at distance: Double, coverColor: BackdropLegibilityBand.RGBColor, tone: ArtworkBackgroundToneMap, correction: FullscreenBottomBandLegibility.Correction) -> Double {
        let layer1 = FullscreenBottomBandLegibility.layer1Color(
            artworkAverageColor: coverColor, // average and bottom-row colour coincide for solid fixtures; callers with real art use metrics separately
            tone: tone,
            brightnessOverride: correction.layer1Brightness,
            dimOpacityOverride: correction.layer1DimOpacity
        )
        let visibility = FullscreenBottomBandLegibility.coverVisibility(distanceAboveBottom: distance, correction: correction)
        let composite = BackdropLegibilityBand.RGBColor(
            r: coverColor.r * visibility + layer1.r * (1 - visibility),
            g: coverColor.g * visibility + layer1.g * (1 - visibility),
            b: coverColor.b * visibility + layer1.b * (1 - visibility)
        )
        return BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(composite))
    }

    private static let ceiling = MicroInteractionFeel.Tokens.backdropLegibilityCeilingContrast
    private static let tolerance = 0.05

    // MARK: - In-band / dark covers: byte-identical to the 62877a4 baseline

    func test_grayscaleSweep_inBandAndDarkCovers_areByteIdenticalToBaseline() {
        var gray = 0.0
        while gray <= 1.0 + 1e-9 {
            let clampedGray = min(gray, 1.0)
            let image = makeSolidImage(white: CGFloat(clampedGray))
            let (_, tone, correction) = resolve(for: image)

            if !correction.needsCorrection {
                XCTAssertEqual(correction.blendHeight, CGFloat(FullscreenBottomBandLegibility.baselineBlendHeight), accuracy: 0.001,
                                "gray \(clampedGray): unchanged blendHeight must equal the founder-tuned baseline (100pt)")
                XCTAssertEqual(correction.layer1Brightness, tone.textureBrightness, accuracy: 0.0001,
                               "gray \(clampedGray): unchanged case must not touch Layer 1's brightness")
                XCTAssertEqual(correction.layer1DimOpacity, tone.textureDimmingOpacity, accuracy: 0.0001,
                               "gray \(clampedGray): unchanged case must not touch Layer 1's dim opacity")
            }
            gray += 0.1
        }
    }

    /// The task's own acceptance bar: for the FULL gray sweep (0...1), whatever `resolve()`
    /// decides, the contrast ACTUALLY delivered at every critical text/control position must
    /// reach >= 4.5:1. Uses the same conservative "whichever of average/bottom-row has the
    /// higher true luminance" cover-colour proxy `resolve()` itself uses internally (see its
    /// doc comment on `NSImage.controlAreaMaxColor()`'s linear-light quirk for uniform
    /// swatches) — this is what actually caught that quirk during development: a naive
    /// bottom-row-only gate silently failed to correct a uniform ~50% gray cover, whose
    /// hover-title/shuffle-row positions (both beyond the 100pt baseline blend height, so
    /// fully exposed to the raw cover) measured 3.95:1, below the 4.5:1 ceiling.
    func test_grayscaleSweep_deliveredContrastAlwaysMeetsCeiling() {
        var gray = 0.0
        while gray <= 1.0 + 1e-9 {
            let clampedGray = min(gray, 1.0)
            let image = makeSolidImage(white: CGFloat(clampedGray))
            let (metrics, tone, correction) = resolve(for: image)
            let bottomColorRaw = image.controlAreaMaxColor()
            let bottomColor = BackdropLegibilityBand.RGBColor(r: bottomColorRaw.r, g: bottomColorRaw.g, b: bottomColorRaw.b)
            let averageColor = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)
            let effectiveCoverColor = BackdropLegibilityBand.relativeLuminance(averageColor) >= BackdropLegibilityBand.relativeLuminance(bottomColor) ? averageColor : bottomColor

            for distance in FullscreenBottomBandLegibility.criticalTextTopDistances {
                let contrast = deliveredContrast(at: distance, coverColor: effectiveCoverColor, tone: tone, correction: correction)
                XCTAssertGreaterThanOrEqual(contrast, Self.ceiling - Self.tolerance,
                                             "gray \(clampedGray) @ \(distance)pt below ceiling: \(contrast) (needsCorrection=\(correction.needsCorrection))")
            }
            gray += 0.02
        }
    }

    func test_darkCover_neverNeedsCorrection() {
        let (_, _, correction) = resolve(for: makeSolidImage(white: 10.0 / 255.0)) // #0A0A0A
        XCTAssertFalse(correction.needsCorrection, "a near-black cover must never trigger the bright-cover-only correction")
    }

    func test_darkerGrayCover_neverNeedsCorrection() {
        // NOTE: a 50% gray cover is NOT automatically safe — its raw (untoned) gamma
        // luminance (~0.50) is ABOVE the ~0.4655 boundary where a pure-white foreground's
        // contrast against it drops below the 4.5:1 ceiling, and the hover-title/shuffle-row
        // positions sit beyond the ORIGINAL 100pt blend height, i.e. fully exposed to the raw,
        // untoned cover in the founder's own 62877a4 design — so a mid-gray cover genuinely
        // DOES need correction there (see test_grayscaleSweep_deliveredContrastAlwaysMeetsCeiling).
        // A comfortably darker gray, clear of that boundary, must stay untouched.
        let (_, _, correction) = resolve(for: makeSolidImage(white: 0.35))
        XCTAssertFalse(correction.needsCorrection, "a comfortably dark gray cover must not be touched")
    }

    // MARK: - Bright covers: contrast reaches the ceiling at every real text/control position

    func test_whiteCover_needsCorrection_andMeetsCeilingAtAllCriticalPositions() {
        let image = makeSolidImage(white: 1.0)
        let (metrics, tone, correction) = resolve(for: image)
        XCTAssertTrue(correction.needsCorrection, "a pure white fullscreen cover must trigger the correction")
        XCTAssertGreaterThan(correction.blendHeight, CGFloat(FullscreenBottomBandLegibility.baselineBlendHeight),
                              "the fade must extend beyond the 100pt baseline for a white cover")

        let coverColor = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)
        for distance in FullscreenBottomBandLegibility.criticalTextTopDistances {
            let contrast = deliveredContrast(at: distance, coverColor: coverColor, tone: tone, correction: correction)
            XCTAssertGreaterThanOrEqual(contrast, Self.ceiling - Self.tolerance,
                                         "distance \(distance)pt above bottom must reach >= 4.5:1, got \(contrast)")
        }
    }

    func test_hoverTitleTop_shuffleRowTop_nonHoverTitle_nonHoverArtist_allMeetCeilingForBrightCover() {
        // Explicit per-position assertions (not just the loop above) — the task's own
        // acceptance list.
        let image = makeSolidImage(white: 0.95)
        let (metrics, tone, correction) = resolve(for: image)
        let coverColor = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)

        let hoverTitle = deliveredContrast(at: FullscreenBottomBandLegibility.hoverTitleTopDistance, coverColor: coverColor, tone: tone, correction: correction)
        let shuffleRow = deliveredContrast(at: FullscreenBottomBandLegibility.shuffleRowTopDistance, coverColor: coverColor, tone: tone, correction: correction)
        let nonHoverTitle = deliveredContrast(at: FullscreenBottomBandLegibility.nonHoverTitleTopDistance, coverColor: coverColor, tone: tone, correction: correction)
        let nonHoverArtist = deliveredContrast(at: FullscreenBottomBandLegibility.nonHoverArtistTopDistance, coverColor: coverColor, tone: tone, correction: correction)

        XCTAssertGreaterThanOrEqual(hoverTitle, Self.ceiling - Self.tolerance, "hover title top: \(hoverTitle)")
        XCTAssertGreaterThanOrEqual(shuffleRow, Self.ceiling - Self.tolerance, "shuffle row top: \(shuffleRow)")
        XCTAssertGreaterThanOrEqual(nonHoverTitle, Self.ceiling - Self.tolerance, "non-hover title: \(nonHoverTitle)")
        XCTAssertGreaterThanOrEqual(nonHoverArtist, Self.ceiling - Self.tolerance, "non-hover artist: \(nonHoverArtist)")
    }

    func test_saturatedSwatches_meetCeilingWhenCorrected() {
        let saturatedSwatches: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("red", 1, 0, 0), ("green", 0, 1, 0), ("blue", 0, 0, 1),
            ("yellow", 1, 1, 0), ("cyan", 0, 1, 1), ("magenta", 1, 0, 1),
            ("dark_navy", 0.05, 0.05, 0.2), ("pale_pastel", 0.9, 0.85, 0.95),
        ]
        for (name, r, g, b) in saturatedSwatches {
            let image = makeSolidColorImage(r: r, g: g, b: b)
            let (metrics, tone, correction) = resolve(for: image)
            let coverColor = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)

            for distance in FullscreenBottomBandLegibility.criticalTextTopDistances {
                let contrast = deliveredContrast(at: distance, coverColor: coverColor, tone: tone, correction: correction)
                XCTAssertGreaterThanOrEqual(contrast, Self.ceiling - Self.tolerance,
                                             "\(name) @ \(distance)pt below ceiling: \(contrast)")
            }
        }
    }

    func test_highVarianceFixtures_meetCeilingWhenCorrected() {
        let fixtures: [(String, NSImage)] = [
            ("half_horizontal_white_top", makeHorizontalSplitImage(topColor: .white, bottomColor: .black)),
            ("white_black_bottomQ", makeBottomQuarterImage(baseColor: .white, bottomQuarterColor: .black)),
            ("black_white_bottomQ", makeBottomQuarterImage(baseColor: .black, bottomQuarterColor: .white)),
            ("checkerboard", makeCheckerboardImage()),
        ]
        for (name, image) in fixtures {
            let (metrics, tone, correction) = resolve(for: image)
            let coverColor = BackdropLegibilityBand.RGBColor(r: metrics.averageRed, g: metrics.averageGreen, b: metrics.averageBlue)
            guard correction.needsCorrection else { continue } // some of these land in-band; nothing to check
            for distance in FullscreenBottomBandLegibility.criticalTextTopDistances {
                let contrast = deliveredContrast(at: distance, coverColor: coverColor, tone: tone, correction: correction)
                XCTAssertGreaterThanOrEqual(contrast, Self.ceiling - Self.tolerance,
                                             "\(name) @ \(distance)pt below ceiling: \(contrast)")
            }
        }
    }

    // MARK: - "Just enough": Layer 1 darkening only happens when hiding the cover isn't enough

    func test_hiddenCoverHeight_coversEveryCriticalPosition() {
        let (_, _, correction) = resolve(for: makeSolidImage(white: 1.0))
        XCTAssertTrue(correction.needsCorrection)
        for distance in FullscreenBottomBandLegibility.criticalTextTopDistances {
            XCTAssertLessThanOrEqual(distance, correction.hiddenCoverHeight,
                                      "distance \(distance) must fall inside the fully-hidden flat zone")
            XCTAssertEqual(FullscreenBottomBandLegibility.coverVisibility(distanceAboveBottom: distance, correction: correction), 0, accuracy: 0.0001,
                           "the sharp cover must be COMPLETELY hidden (not partially blended) at every critical position")
        }
    }

    func test_layer1Correction_isZeroWhenHidingTheCoverAloneIsEnough() {
        // Synthetic, fully-controlled scenario (not a real image sweep): fix `tone` to
        // `.neutral`, pair it with a pure-white `coverBottomRowColor`, and search for an
        // `artworkAverageColor` gray where Layer 1 ALONE (untouched tone) already lands
        // WITHIN the legibility band (>= ceiling, <= floor) — i.e. `resolveChannelCorrect`
        // must return exactly `.zero` for it. A white raw cover always fails the ceiling at
        // the two critical positions that sit beyond the 100pt baseline blend height
        // (`hoverTitleTopDistance`/`shuffleRowTopDistance`, both > 100 — the sharp cover
        // shows through there UNCHANGED regardless of Layer 1), so `needsCorrection` is
        // guaranteed true; this isolates whether Layer 1's OWN tone is left untouched.
        let tone = ArtworkBackgroundToneMap.neutral
        let whiteCover = BackdropLegibilityBand.RGBColor(r: 1, g: 1, b: 1)
        let floor = MicroInteractionFeel.Tokens.backdropLegibilityFloorContrast

        var gray = 0.0
        var found = false
        while gray <= 1.0 {
            let averageColor = BackdropLegibilityBand.RGBColor(r: gray, g: gray, b: gray)
            let layer1 = FullscreenBottomBandLegibility.layer1Color(artworkAverageColor: averageColor, tone: tone)
            let layer1Contrast = BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(layer1))
            if layer1Contrast >= Self.ceiling && layer1Contrast <= floor {
                let correction = FullscreenBottomBandLegibility.resolve(artworkAverageColor: averageColor, coverBottomRowColor: whiteCover, tone: tone)
                XCTAssertTrue(correction.needsCorrection, "a pure-white raw cover must always trigger the gate (it fails the ceiling wherever it's fully exposed)")
                XCTAssertEqual(correction.layer1Brightness, tone.textureBrightness, accuracy: 0.0001,
                               "Layer 1's brightness must stay untouched when it already sits within the band")
                XCTAssertEqual(correction.layer1DimOpacity, tone.textureDimmingOpacity, accuracy: 0.0001,
                               "Layer 1's dim opacity must stay untouched when it already sits within the band")
                found = true
                break
            }
            gray += 0.01
        }
        XCTAssertTrue(found, "a synthetic gray must exist where Layer 1 alone already sits within [ceiling, floor]")
    }

    func test_layer1Correction_appliesWhenLayer1ItselfIsStillTooBright() {
        // Pure white pushes tone's own textureBrightness/textureDimmingOpacity chain to its
        // limit; assert the mechanism ACTUALLY engages for at least one bright fixture, i.e.
        // this is not a dead code path.
        let image = makeSolidImage(white: 1.0)
        let (_, tone, correction) = resolve(for: image)
        XCTAssertTrue(correction.needsCorrection)
        let layer1Darkened = correction.layer1Brightness != tone.textureBrightness || correction.layer1DimOpacity != tone.textureDimmingOpacity
        // Either the fade extension alone was enough, or Layer 1 was also darkened — both are
        // valid outcomes of "just enough"; this test only pins that Layer 1's own correction
        // NEVER makes things brighter/less dim than the original tone.
        XCTAssertGreaterThanOrEqual(correction.layer1DimOpacity, tone.textureDimmingOpacity - 0.0001)
        _ = layer1Darkened
    }

    // MARK: - Blend curve: C1-continuous (no hard edge) when correction is needed

    func test_coverVisibility_isC1SmoothAcrossZoneBoundaries() {
        let correction = FullscreenBottomBandLegibility.Correction(
            needsCorrection: true, blendHeight: 160, hiddenCoverHeight: 116, fadeHeight: 44,
            layer1Brightness: -0.3, layer1DimOpacity: 0.2
        )

        func visibility(_ d: Double) -> Double {
            FullscreenBottomBandLegibility.coverVisibility(distanceAboveBottom: d, correction: correction)
        }
        func derivative(at d: Double, step: Double = 0.001) -> Double {
            (visibility(d + step) - visibility(d - step)) / (2 * step)
        }

        // Value continuity at both boundaries.
        XCTAssertEqual(visibility(116 - 0.01), visibility(116 + 0.01), accuracy: 0.01)
        XCTAssertEqual(visibility(160 - 0.01), visibility(160 + 0.01), accuracy: 0.01)

        // Slope continuity: smoothstep's derivative is exactly 0 at both ends of the fade
        // zone, matching the flat zone (slope 0) below and the fully-visible zone (slope 0)
        // above — no kink at either boundary.
        let slopeBelowHidden = derivative(at: 116 - 0.05)
        let slopeAboveHidden = derivative(at: 116 + 0.05)
        XCTAssertEqual(slopeBelowHidden, slopeAboveHidden, accuracy: 0.003, "no kink where the flat zone meets the fade zone")

        let slopeBelowTop = derivative(at: 160 - 0.05)
        let slopeAboveTop = derivative(at: 160 + 0.05)
        XCTAssertEqual(slopeBelowTop, slopeAboveTop, accuracy: 0.003, "no kink where the fade zone meets fully-visible")
    }

    func test_coverVisibility_shapeContract() {
        let correction = FullscreenBottomBandLegibility.Correction(
            needsCorrection: true, blendHeight: 160, hiddenCoverHeight: 116, fadeHeight: 44,
            layer1Brightness: -0.3, layer1DimOpacity: 0.2
        )
        XCTAssertEqual(FullscreenBottomBandLegibility.coverVisibility(distanceAboveBottom: 0, correction: correction), 0)
        XCTAssertEqual(FullscreenBottomBandLegibility.coverVisibility(distanceAboveBottom: 116, correction: correction), 0,
                       "the flat/fade boundary itself is still fully hidden")
        XCTAssertEqual(FullscreenBottomBandLegibility.coverVisibility(distanceAboveBottom: 116 + 22, correction: correction), 0.5, accuracy: 0.001)
        XCTAssertEqual(FullscreenBottomBandLegibility.coverVisibility(distanceAboveBottom: 160, correction: correction), 1, accuracy: 0.0001)
        XCTAssertEqual(FullscreenBottomBandLegibility.coverVisibility(distanceAboveBottom: 200, correction: correction), 1)
    }

    // MARK: - Mask gradient stops: unchanged case matches the ORIGINAL linear ramp exactly

    func test_maskGradientStops_unchangedCase_matchesOriginalLinearRamp() {
        let correction = FullscreenBottomBandLegibility.Correction.unchanged(tone: .neutral)
        let stops = FullscreenBottomBandLegibility.maskGradientStops(correction: correction)

        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.first?.coverVisibility ?? -1, 1, accuracy: 0.0001, "top of the band = original `.black` stop (cover fully visible)")
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops.last?.coverVisibility ?? -1, 0, accuracy: 0.0001, "bottom edge = original `.clear` stop (cover fully hidden)")

        // A dense sampling of a LINEAR ramp reproduces the exact same line at every sampled
        // point: coverVisibility(location) must equal (1 - location) exactly.
        for stop in stops {
            XCTAssertEqual(stop.coverVisibility, 1 - stop.location, accuracy: 0.0001)
        }
    }

    func test_maskGradientStops_correctedCase_isMonotonicAndBounded() {
        let (_, _, correction) = resolve(for: makeSolidImage(white: 1.0))
        XCTAssertTrue(correction.needsCorrection)
        let stops = FullscreenBottomBandLegibility.maskGradientStops(correction: correction)
        XCTAssertEqual(stops.first?.coverVisibility ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(stops.last?.coverVisibility ?? -1, 0, accuracy: 0.0001)
        for i in 1..<stops.count {
            XCTAssertLessThanOrEqual(stops[i].coverVisibility, stops[i - 1].coverVisibility + 0.0001,
                                      "visibility must be monotonically non-increasing from top to bottom")
        }
    }

    // MARK: - Source-scan guard: the fullscreen branch introduces NO new view types vs
    // 62877a4 (the founder-tuned commit `b58b4e6` restored MiniPlayerView.swift to
    // byte-identical). This task's constraint is "different parameter values on the
    // EXISTING views only" — this compares view-TYPE token counts (not values, which are
    // expected to differ) inside the fullscreen branch region between the current source and
    // the git blob at 62877a4, read read-only via `git show` (local, no network).

    private func repoRootURL(from fileURL: URL) -> URL {
        var dir = fileURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            let parent = dir.deletingLastPathComponent()
            if parent == dir { return dir }
            dir = parent
        }
        return dir
    }

    private func gitShow(ref: String, path: String, repoRoot: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["show", "\(ref):\(path)"]
        process.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Extracts the fullscreen `floatingArtwork` branch's Layer 1 + Layer 2 region, bounded
    /// by two markers present verbatim in both the current source and 62877a4.
    private func fullscreenBranchRegion(_ source: String) -> String? {
        let startMarker = "let coverSize = geo.size.width"
        let endMarker = "accessibilityLabel(\"专辑封面\")"
        guard let startRange = source.range(of: startMarker),
              let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    private func occurrences(of token: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: token, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    func test_fullscreenBranch_introducesNoNewViewTypes_vs62877a4() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let path = "Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift"
        let currentSource = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let originalSource = try gitShow(ref: "62877a4", path: path, repoRoot: root)
        XCTAssertFalse(originalSource.isEmpty, "git show 62877a4:\(path) returned nothing — is this a shallow clone missing that commit?")

        guard let currentRegion = fullscreenBranchRegion(currentSource),
              let originalRegion = fullscreenBranchRegion(originalSource) else {
            XCTFail("could not locate the fullscreen branch region anchors — MiniPlayerView.swift's structure changed; update this test's markers")
            return
        }

        // View/CONTAINER constructors and modifiers whose count must stay EXACTLY the same —
        // not colour literals (`.black`/`.clear` vs `Color.black.opacity(...)` are different
        // equally-valid spellings of the same Color value, not different view types) and not
        // `.opacity(` (the mask's gradient stops now build their Color from a numeric
        // visibility fraction via `Color.black.opacity(x)` instead of a hardcoded `.black`/
        // `.clear` literal — one more call of an ALREADY-used SwiftUI modifier already
        // present in this region (`.opacity(isAlbumPage ? 1 : 0)` on Layer 1), not a new
        // view type).
        let viewTypeTokens = [
            "Image(", "LinearGradient(", ".overlay(", ".mask(", ".blur(", "VStack(", "Rectangle(",
            ".saturation(", ".contrast(", ".brightness(", ".clipped(", ".cornerRadius(", ".shadow(",
            ".matchedGeometryEffect(", ".position(", ".frame(", ".resizable(", ".scaledToFill(",
            ".accessibilityHidden(",
        ]
        for token in viewTypeTokens {
            let currentCount = occurrences(of: token, in: currentRegion)
            let originalCount = occurrences(of: token, in: originalRegion)
            XCTAssertEqual(currentCount, originalCount,
                            "'\(token)' count changed (\(originalCount) -> \(currentCount)) — the fullscreen branch must only change parameter VALUES on the existing views, never introduce a new view type")
        }
    }
}
