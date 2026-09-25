import AppKit
import XCTest
@testable import MusicMiniPlayerCore

/// Founder 2026-09-24, narrowed same day after trying the whole-button-set version:
/// ONLY the shuffle/repeat circle buttons adapt. "灰色一点就行，保持对比度就好" — when the
/// pixels directly under shuffle/repeat are too bright, the icon becomes a neutral gray
/// solved to land EXACTLY on the WCAG 3:1 non-text contrast floor, never pure black. The
/// two top buttons and the bottom play area (SharedBottomControls) went back to their
/// pre-2026-09-24 rules and no longer read this mechanism at all (verified below via
/// source/structure checks, since there is no SwiftUI-rendering-identity tool here).
///
/// Pure-model only, no view hosting (same convention as `BackdropLegibilityBandTests`):
/// `ButtonIconDecision`/`ButtonIconGraySolve`/`ButtonIconCompositeSampler` are plain
/// CGContext + Core Image pixel math + WCAG arithmetic, deterministic headless.
final class ButtonIconLegibilityTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSolidImage(size: Int = 200, white: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(srgbRed: white, green: white, blue: white, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    private let panelSize = CGSize(width: PanelWindowMetrics.defaultSize.width, height: PanelWindowMetrics.defaultSize.height)

    /// Builds a neutral-gray `RGBColor` whose WCAG contrast against white is exactly
    /// `contrast` (solved via the same sRGB linearization `BackdropLegibilityBand` uses),
    /// so the decision boundary tests are exact, not approximate.
    private func grayColor(contrast: Double) -> BackdropLegibilityBand.RGBColor {
        let relativeLuminance = 1.05 / contrast - 0.05
        let gamma = BackdropLegibilityBand.linearToSRGB(relativeLuminance)
        return BackdropLegibilityBand.RGBColor(r: gamma, g: gamma, b: gamma)
    }

    /// The contrast a `ButtonIconTone` actually delivers against `color` — white is
    /// trivially 1.0 (own colour), a solved gray is recomputed from its own lightness so
    /// the assertion checks the REAL resulting contrast, not just that a case was chosen.
    private func actualContrast(of tone: ButtonIconTone, against color: BackdropLegibilityBand.RGBColor) -> Double {
        switch tone {
        case .white:
            return BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(color))
        case .gray(let lightness):
            let grayLuminance = BackdropLegibilityBand.relativeLuminance(BackdropLegibilityBand.RGBColor(r: lightness, g: lightness, b: lightness))
            let bgLuminance = BackdropLegibilityBand.relativeLuminance(color)
            let lighter = max(grayLuminance, bgLuminance)
            let darker = min(grayLuminance, bgLuminance)
            return (lighter + 0.05) / (darker + 0.05)
        }
    }

    // MARK: - ButtonIconGraySolve (pure math — the exact-3:1 solve)

    func test_graySolve_pureWhiteBackground_landsExactlyOnTargetContrast() {
        let white = BackdropLegibilityBand.RGBColor(r: 1, g: 1, b: 1)
        let lightness = ButtonIconGraySolve.lightness(background: white)
        let gray = BackdropLegibilityBand.RGBColor(r: lightness, g: lightness, b: lightness)
        let contrast = BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(gray))
        // whiteContrastRatio(relativeLuminance:) is exactly "(1+0.05)/(L+0.05)" — the same
        // formula the solve targets against a white foreground reference, so this IS the
        // background/gray contrast for a white background.
        XCTAssertEqual(contrast, ButtonIconGraySolve.targetContrast, accuracy: 0.02)
    }

    func test_graySolve_neverReturnsPureBlack() {
        let white = BackdropLegibilityBand.RGBColor(r: 1, g: 1, b: 1)
        let lightness = ButtonIconGraySolve.lightness(background: white)
        XCTAssertGreaterThan(lightness, 0, "pure white background must still solve to a non-zero gray, never pure black")
    }

    func test_graySolve_neverDarkerThanTheSolvedBoundary() {
        // The solve is defined as the LIGHTEST gray that still reaches the target contrast
        // — any lighter gray must fail, confirming the solved value sits exactly at the
        // boundary rather than with extra (unrequested) margin.
        let background = grayColor(contrast: 4.0) // some background bright enough to flip
        let lightness = ButtonIconGraySolve.lightness(background: background)
        let bit = BackdropLegibilityBand.linearToSRGB(min(BackdropLegibilityBand.srgbToLinear(lightness) + 0.02, 1))
        let solvedContrast = actualContrast(of: .gray(lightness), against: background)
        let lighterContrast = actualContrast(of: .gray(bit), against: background)
        XCTAssertGreaterThanOrEqual(solvedContrast, ButtonIconGraySolve.targetContrast - 0.02)
        XCTAssertLessThan(lighterContrast, solvedContrast, "a lighter gray than the solved value must give LESS contrast — the solve sits at the boundary")
    }

    // MARK: - ButtonIconDecision (threshold + hysteresis + gray solve)

    func test_decision_wellBelowGrayThreshold_flipsWhiteToGray_atExactly3to1() {
        let color = grayColor(contrast: 2.5)
        let result = ButtonIconDecision.resolve(color: color, previous: .white)
        guard case .gray(let lightness) = result else {
            return XCTFail("expected .gray, got \(result)")
        }
        XCTAssertGreaterThan(lightness, 0, "never pure black")
        XCTAssertEqual(actualContrast(of: result, against: color), ButtonIconGraySolve.targetContrast, accuracy: 0.02)
    }

    func test_decision_wellAboveWhiteThreshold_staysOrReturnsWhite() {
        let color = grayColor(contrast: 5.0)
        XCTAssertEqual(ButtonIconDecision.resolve(color: color, previous: .white), .white)
        XCTAssertEqual(ButtonIconDecision.resolve(color: color, previous: .gray(0.3)), .white)
    }

    func test_decision_hysteresis_midBandDoesNotFlipEitherDirection() {
        // 3.2 sits strictly between the 3.0 gray threshold and the 3.5 white threshold.
        let color = grayColor(contrast: 3.2)
        XCTAssertEqual(ButtonIconDecision.resolve(color: color, previous: .white), .white, "white must not flip until contrast < 3.0")
        let stillGray = ButtonIconDecision.resolve(color: color, previous: .gray(0.3))
        guard case .gray = stillGray else {
            return XCTFail("gray must not flip back to white until contrast >= 3.5, got \(stillGray)")
        }
    }

    func test_decision_boundaryValues_areExact() {
        // A small margin either side of each threshold — `grayColor` round-trips through
        // sRGB<->linear twice (once building the fixture, once inside `resolve`), so
        // asserting the literal threshold value itself is not float-exact; the DIRECTION
        // of the flip at 0.01 either side of each threshold is what the contract promises.
        XCTAssertEqual(ButtonIconDecision.resolve(color: grayColor(contrast: 3.01), previous: .white), .white, "just above 3.0 must not flip")
        guard case .gray = ButtonIconDecision.resolve(color: grayColor(contrast: 2.99), previous: .white) else {
            return XCTFail("just below 3.0 must flip to gray")
        }
        XCTAssertEqual(ButtonIconDecision.resolve(color: grayColor(contrast: 3.51), previous: .gray(0.3)), .white, "just above 3.5 must switch back")
        guard case .gray = ButtonIconDecision.resolve(color: grayColor(contrast: 3.49), previous: .gray(0.3)) else {
            return XCTFail("just below 3.5 must stay gray")
        }
    }

    /// The `.gray` lightness tracks the CURRENT background continuously while flipped —
    /// not frozen at whatever value it first flipped to — so a brighter background (still
    /// within the flipped regime) recomputes to a DIFFERENT lightness, letting the 0.25s
    /// cross-fade in `MiniPlayerView` read as smooth motion, never a snap-then-freeze.
    func test_decision_grayLightness_recomputesContinuously_asBackgroundShiftsWhileFlipped() {
        let dimmerFlip = grayColor(contrast: 2.9)
        let brighterFlip = grayColor(contrast: 1.5)
        guard case .gray(let l1) = ButtonIconDecision.resolve(color: dimmerFlip, previous: .white) else {
            return XCTFail("expected gray")
        }
        guard case .gray(let l2) = ButtonIconDecision.resolve(color: brighterFlip, previous: .gray(l1)) else {
            return XCTFail("expected gray")
        }
        XCTAssertNotEqual(l1, l2, accuracy: 0.001, "lightness must keep tracking the background, not freeze at the first flip's value")
    }

    // MARK: - ButtonIconRects — only shuffle/repeat are inventoried now

    func test_buttonIconID_onlyShuffleAndRepeat() {
        XCTAssertEqual(Set(ButtonIconID.allCases), [.shuffle, .repeatButton])
    }

    func test_rects_allInventoriedButtons_fitInsidePanel() {
        for id in ButtonIconID.allCases {
            let rect = ButtonIconRects.rect(for: id, panelSize: panelSize)
            XCTAssertGreaterThanOrEqual(rect.x, 0, "\(id) x")
            XCTAssertGreaterThanOrEqual(rect.distanceFromBottom, 0, "\(id) distanceFromBottom")
            XCTAssertLessThanOrEqual(rect.x + rect.width, panelSize.width + 0.001, "\(id) right edge")
            XCTAssertLessThanOrEqual(rect.distanceFromBottom + rect.height, panelSize.height + 0.001, "\(id) top edge")
        }
    }

    // MARK: - resolveAll: no artwork

    func test_resolveAll_noArtwork_allWhite() {
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: nil, tone: .neutral, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertEqual(result[id], .white, "\(id)")
        }
    }

    // MARK: - resolveAll: fullscreen, non-bright cover stays exactly today's white

    func test_resolveAll_fullscreen_typicalCover_everyButtonStaysWhite() {
        // A mid-gray cover is representative of an ordinary (non-overexposed) piece of
        // album art — shuffle/repeat should never have needed to go gray.
        let cover = makeSolidImage(white: 0.45)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertEqual(result[id], .white, "\(id) must stay today's white on an ordinary cover")
        }
    }

    func test_resolveAll_fullscreen_darkCover_staysWhite_byteIdenticalToToday() {
        let cover = makeSolidImage(white: 10.0 / 255.0)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertEqual(result[id], .white, "\(id)")
        }
    }

    // MARK: - resolveAll: fullscreen, overexposed cover flips shuffle/repeat to gray

    func test_resolveAll_fullscreen_pureWhiteCover_bothButtonsFlipToGray_neverBlack() {
        let cover = makeSolidImage(white: 1.0)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            guard let tone = result[id], case .gray(let lightness) = tone else {
                return XCTFail("\(id) must flip to gray on a pure-white cover, got \(String(describing: result[id]))")
            }
            XCTAssertGreaterThan(lightness, 0, "\(id) must never go pure black")
        }
    }

    /// Reports the actual gray solved for white / 0.8 / 0.6 gamma-luminance solid covers
    /// (each cover's own tone-mapped composite, matching every other resolveAll test's
    /// convention) — printed so the founder can see the exact numbers. On THIS pipeline
    /// (post hero-fade + Layer-1 tone-map compositing, not a raw untouched pixel), 0.6
    /// already sits past the flip boundary here too — the gray solve activates whenever
    /// the composited pixel under the button drops below 3:1, never a hardcoded gamma
    /// cutoff — so all three report a solved gray, none pure black.
    func test_resolveAll_fullscreen_reportedBackgroundLuminances() {
        for gamma: CGFloat in [0.6, 0.8, 1.0] {
            let cover = makeSolidImage(white: gamma)
            let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
            let result = ButtonIconLegibility.resolveAll(
                fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
                reduceTransparency: false, previous: [:]
            )
            let shuffleTone = result[.shuffle]
            switch shuffleTone {
            case .white:
                print("[ButtonIconLegibility gray-solve] background gamma \(gamma) -> white (unflipped)")
            case .gray(let lightness):
                XCTAssertGreaterThan(lightness, 0, "background gamma \(gamma) must never solve to pure black")
                print("[ButtonIconLegibility gray-solve] background gamma \(gamma) -> gray lightness \(lightness)")
            case .none:
                XCTFail("missing result for background gamma \(gamma)")
            }
        }
    }

    /// A background dim enough that white still comfortably passes 3:1 must stay
    /// byte-identical white — the gray solve is a targeted fix for OVEREXPOSED pixels,
    /// not a general dimming of shuffle/repeat.
    func test_resolveAll_fullscreen_dimCover_staysWhite() {
        let cover = makeSolidImage(white: 0.3)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertEqual(result[id], .white, "\(id) must stay white on a merely-dim (not overexposed) cover")
        }
    }

    // MARK: - resolveAll: non-fullscreen — both buttons sit over the fluid backdrop,
    // whose own legibility band already guarantees >= 4.5:1, so it never flips.

    func test_resolveAll_nonFullscreen_brightCover_stillAllWhite() {
        let cover = makeSolidImage(white: 1.0)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: false, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertEqual(result[id], .white, "\(id) — non-fullscreen buttons sit over the fluid backdrop, not the raw cover")
        }
    }

    func test_resolveAll_nonFullscreen_typicalCover_everyButtonStaysWhite() {
        let cover = makeSolidImage(white: 0.5)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: false, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertEqual(result[id], .white, "\(id)")
        }
    }

    // MARK: - Hysteresis carries across a resolveAll call (no per-call reset)

    func test_resolveAll_previousGray_needsHigherContrastToReturnWhite() {
        // A cover bright enough to fail 3.0 but not reach 3.5 must stay gray once it IS
        // gray, and a `previous: [:]` (i.e. starting white) call on the same cover must
        // report gray — exercising the dictionary plumbing, not just the pure function.
        let cover = makeSolidImage(white: 1.0)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let previous: [ButtonIconID: ButtonIconTone] = Dictionary(uniqueKeysWithValues: ButtonIconID.allCases.map { ($0, .gray(0.3)) })
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: previous
        )
        for id in ButtonIconID.allCases {
            guard case .gray = result[id] else {
                return XCTFail("\(id) stays gray — still overexposed, got \(String(describing: result[id]))")
            }
        }
    }

    // MARK: - Composite sampler smoke test

    func test_compositeSampler_render_producesExpectedDimensions() {
        let cover = makeSolidImage(white: 0.5)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let bitmap = ButtonIconCompositeSampler.render(
            cover: cover, tone: tone, totalFadeHeight: 100, panelSize: panelSize, scale: 2
        )
        XCTAssertNotNil(bitmap)
        XCTAssertEqual(bitmap?.width, Int((panelSize.width * 2).rounded()))
        XCTAssertEqual(bitmap?.height, Int((panelSize.height * 2).rounded()))
    }

    // MARK: - Cost (2026-09-24 review: must not hitch the main thread on a song change)

    /// A noisy (not flat-color) fixture — a flat fill lets Core Image/CG take fast paths a
    /// real photo never would, understating cost. Deterministic PRNG so the test is
    /// reproducible.
    private func makeNoisyImage(size: Int) -> NSImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var state: UInt64 = 0x2545F4914F6CDD1D
        func nextByte() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 33) & 0xFF)
        }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = nextByte()
            pixels[i + 1] = nextByte()
            pixels[i + 2] = nextByte()
            pixels[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    /// `warm`: the CIContext (GPU/Metal pipeline compile) pays a real one-time cost on its
    /// FIRST use in the process — irrelevant to steady-state cost, since `ciContext` is a
    /// shared `static let` and production only pays it once per app launch, off the main
    /// thread. `warm: true` discards a throwaway first render so the timed run measures
    /// the number that actually recurs on every subsequent song change.
    private func measureRenderMs(coverSize: Int, scale: CGFloat, warm: Bool) -> Double {
        let cover = makeNoisyImage(size: coverSize)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        if warm {
            _ = ButtonIconCompositeSampler.render(cover: cover, tone: tone, totalFadeHeight: 100, panelSize: panelSize, scale: scale)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let bitmap = ButtonIconCompositeSampler.render(
            cover: cover, tone: tone, totalFadeHeight: 100, panelSize: panelSize, scale: scale
        )
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertNotNil(bitmap)
        return elapsedMs
    }

    /// Reports actual cost at both the OLD (scale 2 == panel-size x2) and NEW (scale 1 ==
    /// panel-size x1, what `ButtonIconLegibility.resolveAll` now actually renders at)
    /// working resolution, for 600x600 and 1200x1200 source artwork — the composite's own
    /// output buffer is panel-sized regardless of the SOURCE image's resolution, so cost
    /// is dominated by panelSize*scale, not by cover size; this asserts that relationship
    /// rather than a specific device-dependent millisecond number (which would be flaky
    /// across CI/dev hardware) — the moved-off-main-thread change is what actually keeps
    /// song changes from hitching, this is a supporting sanity/regression guard, not the
    /// mechanism that prevents the hitch. Sampling only two rects now (vs. nine before the
    /// 2026-09-24 narrowing) does not change this cost — the expensive part is the
    /// composite RENDER, not the per-rect p90 scan.
    func test_cost_600And1200SourceArtwork_costIsDrivenByOutputSizeNotSourceSize() {
        // Cold: first-ever CIContext use in the process (Metal pipeline compile) — a
        // one-time cost paid once per app launch, off the main thread, not per song.
        let ms600Scale2Cold = measureRenderMs(coverSize: 600, scale: 2, warm: false)
        // Warm: every subsequent render — the number that actually recurs per song change.
        let ms600Scale2 = measureRenderMs(coverSize: 600, scale: 2, warm: true)
        let ms1200Scale2 = measureRenderMs(coverSize: 1200, scale: 2, warm: true)
        let ms600Scale1 = measureRenderMs(coverSize: 600, scale: 1, warm: true)
        let ms1200Scale1 = measureRenderMs(coverSize: 1200, scale: 1, warm: true)
        print("[ButtonIconLegibility cost] COLD (first CIContext use) 600x600 cover, panel x2: \(String(format: "%.2f", ms600Scale2Cold)) ms")
        print("[ButtonIconLegibility cost] warm 600x600 cover, panel x2 (\(Int(panelSize.width * 2))x\(Int(panelSize.height * 2))): \(String(format: "%.2f", ms600Scale2)) ms")
        print("[ButtonIconLegibility cost] warm 1200x1200 cover, panel x2 (\(Int(panelSize.width * 2))x\(Int(panelSize.height * 2))): \(String(format: "%.2f", ms1200Scale2)) ms")
        print("[ButtonIconLegibility cost] warm 600x600 cover, panel x1 (\(Int(panelSize.width))x\(Int(panelSize.height))): \(String(format: "%.2f", ms600Scale1)) ms")
        print("[ButtonIconLegibility cost] warm 1200x1200 cover, panel x1 (\(Int(panelSize.width))x\(Int(panelSize.height))): \(String(format: "%.2f", ms1200Scale1)) ms")
        // Generous upper bound — this is a hitch-prevention sanity guard (the composite now
        // runs off the main thread regardless), not a tight perf assertion that would be
        // flaky across CI/dev hardware.
        XCTAssertLessThan(ms1200Scale1, 500, "panel x1 working resolution must stay cheap even for a large source cover")
    }

    // MARK: - ButtonIconRefreshCoordinator: stale-result drop (2026-09-24 review)

    /// Two artwork changes in a row: the FIRST call's underlying work is artificially
    /// SLOW and the SECOND's is fast, so the first's `compute` finishes strictly after
    /// the second's — the worst case for a naive "last one to finish wins" bug. Only the
    /// latest (second) result may ever be observed; the first's `refresh` call must
    /// resolve to `nil` (its own signal to the caller: "drop me, do not apply").
    func test_refreshCoordinator_twoRefreshesInARow_onlyLatestApplies() async {
        let coordinator = ButtonIconRefreshCoordinator { fullscreen, _, _, _, _, _ in
            // Encode which call this is (fullscreen bool doubles as a tag) into the
            // delay AND the result, so the test can tell them apart unambiguously.
            if fullscreen {
                try? await Task.sleep(nanoseconds: 60_000_000) // "first" call: slow
                return [.shuffle: .gray(0.3)]
            } else {
                return [.shuffle: .white] // "second" call: fast
            }
        }

        async let firstResult = coordinator.refresh(
            fullscreen: true, artwork: nil, tone: .neutral, panelSize: .zero,
            reduceTransparency: false, previous: [:]
        )
        // Give the first call time to pass its `generation += 1` before starting the
        // second (both are near-instant synchronously; the sleep above is what actually
        // keeps `first` in flight past `second`'s start).
        try? await Task.sleep(nanoseconds: 5_000_000)
        let secondResult = await coordinator.refresh(
            fullscreen: false, artwork: nil, tone: .neutral, panelSize: .zero,
            reduceTransparency: false, previous: [:]
        )

        let firstOutcome = await firstResult
        XCTAssertEqual(secondResult?[.shuffle], .white, "the second (latest) refresh must apply")
        XCTAssertNil(firstOutcome, "the first (superseded) refresh must be dropped, even though its own work finished later")
    }

    /// The ordinary case — no overlap — must still resolve normally (the coordinator does
    /// not accidentally drop a refresh that had no competition).
    func test_refreshCoordinator_singleRefresh_resolves() async {
        let coordinator = ButtonIconRefreshCoordinator { _, _, _, _, _, _ in
            [.repeatButton: .gray(0.3)]
        }
        let result = await coordinator.refresh(
            fullscreen: true, artwork: nil, tone: .neutral, panelSize: .zero,
            reduceTransparency: false, previous: [:]
        )
        XCTAssertEqual(result?[.repeatButton], .gray(0.3))
    }

    // MARK: - Source/structure checks: the top buttons and bottom play area went back to
    // their exact pre-2026-09-24 rules (no SwiftUI-rendering-identity tool exists here, so
    // this is the code-level equivalent — the founder's own 2026-08-21 rule: unit tests,
    // not screenshots, for anything this project cannot deterministically replay).

    private func sourceText(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_sharedControls_bottomPlayArea_hasNoIconToneOverride_byteIdenticalToPreFeature() throws {
        let source = try sourceText("Sources/MusicMiniPlayerCore/UI/Components/SharedControls.swift")
        XCTAssertFalse(source.contains("iconTones"), "SharedBottomControls must not read a per-icon tone override")
        XCTAssertFalse(source.contains("SharedBottomControlsIconTones"), "the override struct must be gone, not just unused")
        XCTAssertFalse(source.contains("ButtonIconTone"), "SharedControls.swift must not reference this mechanism at all")
        // The five icon call sites must use the plain, unconditional `controlInk` — not
        // `iconTones?.x ?? controlInk`.
        let plainInkColorSites = source.components(separatedBy: "inkColor: controlInk,").count - 1
        XCTAssertEqual(plainInkColorSites, 5, "lyricsNav/backward/play/forward/playlistNav must all pass plain controlInk")
        XCTAssertFalse(source.contains("?? controlInk"), "no site may fall back to controlInk from an optional override")
    }

    func test_hoverableButtons_topButtons_useOriginalLuminanceRule_byteIdenticalToPreFeature() throws {
        let source = try sourceText("Sources/MusicMiniPlayerCore/UI/HoverableButtons.swift")
        XCTAssertFalse(source.contains("toneOverride"), "GlassButtonBackground must not carry a tone override any more")
        XCTAssertFalse(source.contains("ButtonIconTone"), "HoverableButtons.swift must not reference this mechanism at all")
        XCTAssertFalse(source.contains("iconTone"), "MusicButtonView/ExpandButtonView/HoverableActionButton must not carry an iconTone param")
        XCTAssertTrue(
            source.contains("let adaptiveColor: Color = luminance > 0.55 ? .black : .white"),
            "the two top buttons must use the exact original region-average rule"
        )
    }

    func test_audioOutputSwitcherView_hasNoIconToneOverride_byteIdenticalToPreFeature() throws {
        let source = try sourceText("Sources/MusicMiniPlayerCore/UI/AudioOutputSwitcherView.swift")
        XCTAssertFalse(source.contains("iconTone"), "AudioOutputSwitcherView must not carry an iconTone param")
        XCTAssertFalse(source.contains("ButtonIconTone"))
    }

    func test_miniPlayerView_topButtonsAndBottomControls_passNoIconTone() throws {
        let source = try sourceText("Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift")
        XCTAssertFalse(source.contains("iconTone: buttonIconTones"), "the top two buttons must not read buttonIconTones any more")
        XCTAssertFalse(source.contains("iconTones: SharedBottomControlsIconTones"), "SharedBottomControls must not be passed a tone override any more")
        // Only the shuffle/repeat cluster may still call `iconColor(for:)`.
        XCTAssertTrue(source.contains("iconColor(for: .shuffle)"))
        XCTAssertTrue(source.contains("iconColor(for: .repeatButton)"))
    }
}
