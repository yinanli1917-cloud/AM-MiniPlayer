import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ButtonFillTint (2026-09-26): the `.tinted` arm's pure "sampled backdrop
// colour -> button fill colour" function, its async sampling pipeline, and a
// source-level guard that the album cover's own backdrop stack (the founder's
// 2026-09-23 "no new overlay behind the artwork" rule) is untouched — this
// mechanism only ever changes the shuffle/repeat circles' OWN chrome.
// Numbers cited in comments are the pixel measurements in
// research/album-buttons-2026-09-26.md, not guesses.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class ButtonFillTintTests: XCTestCase {
    private let white = BackdropLegibilityBand.RGBColor(r: 1, g: 1, b: 1)

    private func apcaMagnitude(_ color: BackdropLegibilityBand.RGBColor) -> Double {
        abs(APCAContrast.lc(text: white, background: color))
    }

    // MARK: - Shared floor (intentional reuse, not a second arbitrary number)

    func test_apcaFloor_reusesButtonIconDecisionGrayThreshold() {
        XCTAssertEqual(ButtonFillTint.apcaFloor, ButtonIconDecision.grayThreshold)
    }

    func test_glassLift_pinnedToResearchMeasurement() {
        // research/album-buttons-2026-09-26.md: Apple star button +25/255 (0.098),
        // "..." button +22/255 (0.086); shipped value is their midpoint.
        XCTAssertEqual(ButtonFillTint.glassLift, 0.09, accuracy: 0.0001)
    }

    // MARK: - Already-dark backgrounds: lift only, never darkened further

    func test_pureBlackBackground_liftOnly_noDarkening() {
        let sampled = BackdropLegibilityBand.RGBColor(r: 0, g: 0, b: 0)
        let resolved = ButtonFillTint.resolve(sampled: sampled)
        // Contrast against black + a 0.09 lift is still far above the floor, so the
        // darken branch must not fire — the result is EXACTLY the lifted colour.
        XCTAssertEqual(resolved.r, ButtonFillTint.glassLift, accuracy: 0.0001)
        XCTAssertEqual(resolved.g, ButtonFillTint.glassLift, accuracy: 0.0001)
        XCTAssertEqual(resolved.b, ButtonFillTint.glassLift, accuracy: 0.0001)
    }

    func test_darkCover_liftOnly_staysAboveFloorByAWideMargin() {
        // A typical dark album cover corner, well away from any threshold.
        let sampled = BackdropLegibilityBand.RGBColor(r: 0.10, g: 0.08, b: 0.12)
        let resolved = ButtonFillTint.resolve(sampled: sampled)
        XCTAssertEqual(resolved.r, sampled.r + ButtonFillTint.glassLift, accuracy: 0.0001)
        XCTAssertGreaterThan(apcaMagnitude(resolved), ButtonFillTint.apcaFloor)
    }

    // MARK: - Bright backgrounds: darkened to exactly the floor, never below, never black

    func test_pureWhiteBackground_getsDarkened_notLeftAtLift() {
        let sampled = BackdropLegibilityBand.RGBColor(r: 1, g: 1, b: 1)
        let resolved = ButtonFillTint.resolve(sampled: sampled)
        // Lifted stays (1,1,1) (RGBColor clamps), whose contrast against white is 0 —
        // the darken branch MUST fire.
        XCTAssertLessThan(resolved.r, 1.0, "a pure-white sample must be darkened, not left at the lift")
        XCTAssertGreaterThan(resolved.r, 0.0, "never literal black")
        XCTAssertEqual(apcaMagnitude(resolved), ButtonFillTint.apcaFloor, accuracy: 1.0)
    }

    func test_ourMeasuredBuggyBackground_shuffleButton_getsCorrectedToTheFloor() {
        // research/album-buttons-2026-09-26.md: our own shuffle button's measured
        // local background, RGB(219,211,207)/255 — the actual reported bug (fill
        // ends up at lum ~228/255 with only the naive lift, 27/255 short of white,
        // not enough for a legible white icon).
        let sampled = BackdropLegibilityBand.RGBColor(r: 219.0 / 255, g: 211.0 / 255, b: 207.0 / 255)
        let naiveLift = BackdropLegibilityBand.RGBColor(
            r: sampled.r + ButtonFillTint.glassLift, g: sampled.g + ButtonFillTint.glassLift, b: sampled.b + ButtonFillTint.glassLift
        )
        XCTAssertLessThan(apcaMagnitude(naiveLift), ButtonFillTint.apcaFloor, "sanity check: this IS the reported bug case — naive lift alone is not legible")

        let resolved = ButtonFillTint.resolve(sampled: sampled)
        XCTAssertGreaterThanOrEqual(apcaMagnitude(resolved), ButtonFillTint.apcaFloor - 0.5, "the mechanism must correct the case that shipped the bug")
    }

    func test_ourMeasuredBuggyBackground_repeatButton_getsCorrectedToTheFloor() {
        // research/album-buttons-2026-09-26.md: repeat button's measured fill area,
        // RGB(205,198,195)/255.
        let sampled = BackdropLegibilityBand.RGBColor(r: 205.0 / 255, g: 198.0 / 255, b: 195.0 / 255)
        let resolved = ButtonFillTint.resolve(sampled: sampled)
        XCTAssertGreaterThanOrEqual(apcaMagnitude(resolved), ButtonFillTint.apcaFloor - 0.5)
    }

    func test_neverProducesLiteralBlack_evenForPathologicalInput() {
        let resolved = ButtonFillTint.resolve(sampled: BackdropLegibilityBand.RGBColor(r: 1, g: 1, b: 1))
        XCTAssertGreaterThan(resolved.r + resolved.g + resolved.b, 0, "must never collapse to literal (0,0,0)")
    }

    // MARK: - Hue-preserving (tinted, not collapsed to gray)

    func test_darkening_preservesHue_doesNotCollapseToGray() {
        // A warm off-white, needs darkening (APCA under-45 with only the lift).
        let sampled = BackdropLegibilityBand.RGBColor(r: 0.95, g: 0.85, b: 0.75)
        let lifted = BackdropLegibilityBand.RGBColor(
            r: sampled.r + ButtonFillTint.glassLift, g: sampled.g + ButtonFillTint.glassLift, b: sampled.b + ButtonFillTint.glassLift
        )
        let resolved = ButtonFillTint.resolve(sampled: sampled)
        XCTAssertLessThan(apcaMagnitude(lifted), ButtonFillTint.apcaFloor, "sanity check: this case needs darkening")
        // Uniform multiply-toward-black preserves channel RATIOS exactly (cross-
        // multiplication avoids a division-by-zero concern): r/g and g/b unchanged.
        XCTAssertEqual(resolved.r * lifted.g, resolved.g * lifted.r, accuracy: 0.0005, "r:g ratio must be preserved (hue-preserving darken)")
        XCTAssertEqual(resolved.g * lifted.b, resolved.b * lifted.g, accuracy: 0.0005, "g:b ratio must be preserved (hue-preserving darken)")
        // And it must actually still read as warm (r > g > b), not neutral gray.
        XCTAssertGreaterThan(resolved.r, resolved.g)
        XCTAssertGreaterThan(resolved.g, resolved.b)
    }

    // MARK: - Coverage: bright highlight / dark / highly saturated covers (task requirement)

    func test_contrastGuarantee_brightHighlightCover() {
        // Blown-out white highlight, the exact class of input the founder reported
        // ("亮封面" — bright cover).
        let sampled = BackdropLegibilityBand.RGBColor(r: 0.97, g: 0.96, b: 0.94)
        let resolved = ButtonFillTint.resolve(sampled: sampled)
        XCTAssertGreaterThanOrEqual(apcaMagnitude(resolved), ButtonFillTint.apcaFloor - 0.5)
    }

    func test_contrastGuarantee_darkCover() {
        let sampled = BackdropLegibilityBand.RGBColor(r: 0.05, g: 0.05, b: 0.06)
        let resolved = ButtonFillTint.resolve(sampled: sampled)
        XCTAssertGreaterThanOrEqual(apcaMagnitude(resolved), ButtonFillTint.apcaFloor - 0.5)
    }

    func test_contrastGuarantee_highlySaturatedCover() {
        // Saturated, high-luminance yellow — the class of input WCAG's naive
        // channel-average under-rates (see BackdropLegibilityBand's own doc comment
        // on saturated colours) and that ButtonIconLegibility.swift's 2026-09-25 note
        // moved this feature to APCA specifically to handle correctly.
        let saturatedYellow = BackdropLegibilityBand.RGBColor(r: 0.95, g: 0.85, b: 0.08)
        let resolved = ButtonFillTint.resolve(sampled: saturatedYellow)
        XCTAssertGreaterThanOrEqual(apcaMagnitude(resolved), ButtonFillTint.apcaFloor - 0.5)

        // A saturated teal (the founder's real-world "Damn" cover class, per
        // ButtonIconLegibility.swift's 2026-09-25 doc comment).
        let saturatedTeal = BackdropLegibilityBand.RGBColor(r: 0.05, g: 0.55, b: 0.52)
        let resolvedTeal = ButtonFillTint.resolve(sampled: saturatedTeal)
        XCTAssertGreaterThanOrEqual(apcaMagnitude(resolvedTeal), ButtonFillTint.apcaFloor - 0.5)
    }

    func test_contrastGuarantee_sweepOfGraysNeverDropsBelowFloor() {
        // Property-style sweep: for any gray input, the resolved fill's contrast
        // against white must clear the floor — the invariant this whole mechanism
        // exists to guarantee.
        for i in stride(from: 0, through: 100, by: 5) {
            let lightness = Double(i) / 100
            let sampled = BackdropLegibilityBand.RGBColor(r: lightness, g: lightness, b: lightness)
            let resolved = ButtonFillTint.resolve(sampled: sampled)
            XCTAssertGreaterThanOrEqual(
                apcaMagnitude(resolved), ButtonFillTint.apcaFloor - 0.5,
                "lightness \(lightness) must resolve to a fill that keeps white legible"
            )
        }
    }

    // MARK: - ButtonFillLegibility.resolveAll (mirrors ButtonIconLegibility.resolveAll)

    func test_resolveAll_noArtwork_returnsSameNeutralFillForBothButtons() {
        let result = ButtonFillLegibility.resolveAll(
            fullscreen: false, artwork: nil, tone: .neutral, panelSize: .zero,
            reduceTransparency: false, previous: [:]
        )
        XCTAssertEqual(result[.shuffle], result[.repeatButton])
        XCTAssertNotNil(result[.shuffle])
    }

    func test_resolveAll_nonFullscreen_bothButtonsShareTheSamePredictedBackdropColour() {
        // Non-fullscreen: both buttons sit over the same fluid-backdrop prediction
        // (mirrors ButtonIconLegibility's own non-fullscreen branch), so their
        // resolved fills must be identical for the same artwork.
        let result = ButtonFillLegibility.resolveAll(
            fullscreen: false, artwork: nil, tone: .neutral, panelSize: CGSize(width: 250, height: 284),
            reduceTransparency: false, previous: [:]
        )
        XCTAssertEqual(result.count, ButtonIconID.allCases.count)
        XCTAssertEqual(result[.shuffle], result[.repeatButton])
    }

    // MARK: - ButtonFillRefreshCoordinator (mirrors ButtonIconRefreshCoordinator)

    func test_refreshCoordinator_singleRefresh_resolves() async {
        let coordinator = ButtonFillRefreshCoordinator { _, _, _, _, _, _ in
            [.shuffle: BackdropLegibilityBand.RGBColor(r: 0.2, g: 0.2, b: 0.2)]
        }
        let result = await coordinator.refresh(
            fullscreen: true, artwork: nil, tone: .neutral, panelSize: .zero,
            reduceTransparency: false, previous: [:]
        )
        XCTAssertEqual(result?[.shuffle], BackdropLegibilityBand.RGBColor(r: 0.2, g: 0.2, b: 0.2))
    }

    func test_refreshCoordinator_twoRefreshesInARow_onlyLatestApplies() async {
        let coordinator = ButtonFillRefreshCoordinator { fullscreen, _, _, _, _, _ in
            if fullscreen {
                try? await Task.sleep(nanoseconds: 60_000_000) // "first" call: slow
                return [.shuffle: BackdropLegibilityBand.RGBColor(r: 0.1, g: 0.1, b: 0.1)]
            } else {
                return [.shuffle: BackdropLegibilityBand.RGBColor(r: 0.9, g: 0.9, b: 0.9)] // "second" call: fast
            }
        }

        async let firstResult = coordinator.refresh(
            fullscreen: true, artwork: nil, tone: .neutral, panelSize: .zero,
            reduceTransparency: false, previous: [:]
        )
        try? await Task.sleep(nanoseconds: 5_000_000)
        let secondResult = await coordinator.refresh(
            fullscreen: false, artwork: nil, tone: .neutral, panelSize: .zero,
            reduceTransparency: false, previous: [:]
        )

        let firstOutcome = await firstResult
        XCTAssertEqual(secondResult?[.shuffle], BackdropLegibilityBand.RGBColor(r: 0.9, g: 0.9, b: 0.9), "the second (latest) refresh must apply")
        XCTAssertNil(firstOutcome, "the first (superseded) refresh must be dropped, even though its own work finished later")
    }

    // MARK: - Source/structure checks: no new layer behind the album cover itself
    // (founder 2026-09-23 hard rule — this feature may only change the shuffle/
    // repeat circles' OWN chrome, never anything behind the artwork). No SwiftUI-
    // rendering-identity tool exists here, so — same as ButtonIconLegibilityTests's
    // own precedent (test_hoverableButtons_topButtons_.../test_miniPlayerView_...)
    // — this is the code-level equivalent: read the real source and assert the new
    // types are confined to the button subtree.

    private func sourceText(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_albumCoverBackdropFiles_haveNoNewLayerFromThisFeature() throws {
        // The three files that make up the album cover's own backdrop stack
        // (Directory Structure, CLAUDE.md "Background/"). None of them may
        // reference this feature's types.
        for path in [
            "Sources/MusicMiniPlayerCore/UI/Background/FluidGradientBackground.swift",
            "Sources/MusicMiniPlayerCore/UI/Background/PanelBackdrop.swift",
            "Sources/MusicMiniPlayerCore/UI/Background/LiquidBackgroundView.swift",
        ] {
            let source = try sourceText(path)
            XCTAssertFalse(source.contains("ButtonFillTint"), "\(path) must not reference ButtonFillTint")
            XCTAssertFalse(source.contains("ShuffleRepeatCircleChrome"), "\(path) must not reference ShuffleRepeatCircleChrome")
            XCTAssertFalse(source.contains("ButtonFillLegibility"), "\(path) must not reference ButtonFillLegibility")
        }
    }

    func test_floatingArtworkComposite_hasNoReferenceToTheNewFillMechanism() throws {
        // `floatingArtwork` is the function that actually draws the album cover
        // (Layer 1 blurred base + Layer 2 sharp hero, `blendHeight` fade) — the
        // founder's 2026-09-23 "two tuned layers, byte-identical" rule targets
        // exactly this function. Extracted by its own MARK comments (stable
        // anchors — survives line-number drift elsewhere in the file).
        let source = try sourceText("Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift")
        guard let start = source.range(of: "// MARK: - Floating Artwork"),
              let end = source.range(of: "// MARK: - 渐进模糊层", range: start.upperBound..<source.endIndex) else {
            XCTFail("could not locate floatingArtwork's MARK boundaries — anchors may have moved")
            return
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertFalse(body.contains("ButtonFillTint"))
        XCTAssertFalse(body.contains("ShuffleRepeatCircleChrome"))
        XCTAssertFalse(body.contains("fillColor(for:"))
        XCTAssertFalse(body.contains("buttonFillColors"))
        // The founder-tuned anchors must still be exactly there, untouched.
        XCTAssertTrue(body.contains("let blendHeight: CGFloat = 100"))
        XCTAssertTrue(body.contains("Layer 1: blurred full-window backing image."))
        XCTAssertTrue(body.contains("Layer 2: clear hero cover participating in matchedGeometryEffect."))
    }

    func test_shuffleRepeatCluster_isTheOnlyCallSiteOfTheNewFillMechanism() throws {
        let source = try sourceText("Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift")
        // fillColor(for:) is defined once and called exactly twice (shuffle, repeat).
        let definitionSites = source.components(separatedBy: "private func fillColor(for id: ButtonIconID)").count - 1
        XCTAssertEqual(definitionSites, 1)
        let callSites = source.components(separatedBy: "fillColor(for: .").count - 1
        XCTAssertEqual(callSites, 2, "fillColor(for:) must only be called for .shuffle and .repeatButton")
    }
}
