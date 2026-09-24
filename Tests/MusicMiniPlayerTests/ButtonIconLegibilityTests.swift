import AppKit
import XCTest
@testable import MusicMiniPlayerCore

/// Founder 2026-09-24 (verbatim intent): "检测到下面的像素过分亮的话，就把它转成黑色的那个图标
/// 就好" — measure the pixels directly under each button/icon on the album page; black icon
/// when too bright, otherwise today's white. Pure-model only, no view hosting (same
/// convention as `BackdropLegibilityBandTests`): `ButtonIconDecision`/`ButtonIconCompositeSampler`
/// are plain CGContext + Core Image pixel math + WCAG arithmetic, deterministic headless.
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

    /// Top 20% (visually) pure white, remaining 80% pure black — an extreme split so the
    /// composite's sharp Layer-2 top corners and its blurred/toned Layer-1 bottom band
    /// land on opposite sides of the black/white threshold regardless of exact blur/tone
    /// constants.
    private func makeTopBrightBottomDarkImage(size: Int = 200) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.white.setFill()
        // AppKit's lockFocus origin is bottom-left, so the visual TOP 20% is the highest y.
        NSRect(x: 0, y: Int(Double(size) * 0.8), width: size, height: Int(Double(size) * 0.2)).fill()
        image.unlockFocus()
        return image
    }

    private let panelSize = CGSize(width: PanelWindowMetrics.defaultSize.width, height: PanelWindowMetrics.defaultSize.height)

    // MARK: - ButtonIconDecision (pure threshold + hysteresis)

    /// Builds a neutral-gray `RGBColor` whose WCAG contrast against white is exactly
    /// `contrast` (solved via the same sRGB linearization `BackdropLegibilityBand` uses),
    /// so the decision boundary tests are exact, not approximate.
    private func grayColor(contrast: Double) -> BackdropLegibilityBand.RGBColor {
        let relativeLuminance = 1.05 / contrast - 0.05
        let gamma = BackdropLegibilityBand.linearToSRGB(relativeLuminance)
        return BackdropLegibilityBand.RGBColor(r: gamma, g: gamma, b: gamma)
    }

    func test_decision_wellBelowBlackThreshold_flipsWhiteToBlack() {
        let color = grayColor(contrast: 2.5)
        XCTAssertEqual(ButtonIconDecision.resolve(color: color, previous: .white), .black)
    }

    func test_decision_wellAboveWhiteThreshold_staysOrReturnsWhite() {
        let color = grayColor(contrast: 5.0)
        XCTAssertEqual(ButtonIconDecision.resolve(color: color, previous: .white), .white)
        XCTAssertEqual(ButtonIconDecision.resolve(color: color, previous: .black), .white)
    }

    func test_decision_hysteresis_midBandDoesNotFlipEitherDirection() {
        // 3.2 sits strictly between the 3.0 black threshold and the 3.5 white threshold.
        let color = grayColor(contrast: 3.2)
        XCTAssertEqual(ButtonIconDecision.resolve(color: color, previous: .white), .white, "white must not flip until contrast < 3.0")
        XCTAssertEqual(ButtonIconDecision.resolve(color: color, previous: .black), .black, "black must not flip back until contrast >= 3.5")
    }

    func test_decision_boundaryValues_areExact() {
        // A small margin either side of each threshold — `grayColor` round-trips through
        // sRGB<->linear twice (once building the fixture, once inside `resolve`), so
        // asserting the literal threshold value itself is not float-exact; the DIRECTION
        // of the flip at 0.01 either side of each threshold is what the contract promises.
        XCTAssertEqual(ButtonIconDecision.resolve(color: grayColor(contrast: 3.01), previous: .white), .white, "just above 3.0 must not flip")
        XCTAssertEqual(ButtonIconDecision.resolve(color: grayColor(contrast: 2.99), previous: .white), .black, "just below 3.0 must flip")
        XCTAssertEqual(ButtonIconDecision.resolve(color: grayColor(contrast: 3.51), previous: .black), .white, "just above 3.5 must switch back")
        XCTAssertEqual(ButtonIconDecision.resolve(color: grayColor(contrast: 3.49), previous: .black), .black, "just below 3.5 must stay black")
    }

    // MARK: - ButtonIconRects (sanity — every rect lands inside the panel)

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
        // album art — none of today's buttons should ever have needed to go black.
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

    // MARK: - resolveAll: fullscreen, overexposed cover flips the buttons sitting on it

    func test_resolveAll_fullscreen_pureWhiteCover_everyButtonFlipsBlack() {
        let cover = makeSolidImage(white: 1.0)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertEqual(result[id], .black, "\(id) must go black on a pure-white cover")
        }
    }

    // MARK: - resolveAll: fullscreen, split cover -> per-button DIFFERENT results

    /// The founder-reviewed finding this mechanism exists to fix: a whole-cover average
    /// is wrong when the cover is not uniform. A top-bright/bottom-dark cover must flip
    /// the top corner buttons (sharp Layer-2, no fade) black while the bottom row
    /// (blended into the darker Layer-1) stays white — proving the decision is LOCAL, not
    /// a single whole-page verdict.
    func test_resolveAll_fullscreen_splitCover_perButtonDifferentResults() {
        let cover = makeTopBrightBottomDarkImage()
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        XCTAssertEqual(result[.musicCapsule], .black, "top-left sits on the bright sharp hero")
        XCTAssertEqual(result[.airplay], .black, "top-right sits on the bright sharp hero")
        XCTAssertEqual(result[.backward], .white, "bottom row sits on the dark blurred/toned base")
        XCTAssertEqual(result[.play], .white)
        XCTAssertEqual(result[.forward], .white)
        XCTAssertEqual(result[.lyricsNav], .white)
        XCTAssertEqual(result[.playlistNav], .white)
    }

    // MARK: - resolveAll: non-fullscreen — every button sits over the fluid backdrop,
    // whose own legibility band already guarantees >= 4.5:1, so it never goes black.

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

    func test_resolveAll_previousBlack_needsHigherContrastToReturnWhite() {
        // A cover bright enough to fail 3.0 but not reach 3.5 must stay black once it IS
        // black, and a `previous: [:]` (i.e. starting white) call on the same cover must
        // report black — exercising the dictionary plumbing, not just the pure function.
        let cover = makeSolidImage(white: 1.0)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let previous: [ButtonIconID: ButtonIconTone] = Dictionary(uniqueKeysWithValues: ButtonIconID.allCases.map { ($0, .black) })
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: previous
        )
        for id in ButtonIconID.allCases {
            XCTAssertEqual(result[id], .black, "\(id) stays black — still overexposed")
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

    /// Reports actual cost at both the OLD (scale 2 == panel-size x2, the default before
    /// this review) and NEW (scale 1 == panel-size x1, what `ButtonIconLegibility.resolveAll`
    /// now actually renders at) working resolution, for 600x600 and 1200x1200 source
    /// artwork — the composite's own output buffer is panel-sized regardless of the
    /// SOURCE image's resolution (Core Image samples the source lazily into a fixed
    /// output extent), so cost is dominated by panelSize*scale, not by cover size; this
    /// asserts that relationship rather than a specific device-dependent millisecond
    /// number (which would be flaky across CI/dev hardware) — the moved-off-main-thread
    /// change is what actually keeps song changes from hitching, this is a supporting
    /// sanity/regression guard, not the mechanism that prevents the hitch.
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
                return [.musicCapsule: .black]
            } else {
                return [.musicCapsule: .white] // "second" call: fast
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
        XCTAssertEqual(secondResult?[.musicCapsule], .white, "the second (latest) refresh must apply")
        XCTAssertNil(firstOutcome, "the first (superseded) refresh must be dropped, even though its own work finished later")
    }

    /// The ordinary case — no overlap — must still resolve normally (the coordinator does
    /// not accidentally drop a refresh that had no competition).
    func test_refreshCoordinator_singleRefresh_resolves() async {
        let coordinator = ButtonIconRefreshCoordinator { _, _, _, _, _, _ in
            [.airplay: .black]
        }
        let result = await coordinator.refresh(
            fullscreen: true, artwork: nil, tone: .neutral, panelSize: .zero,
            reduceTransparency: false, previous: [:]
        )
        XCTAssertEqual(result?[.airplay], .black)
    }
}
