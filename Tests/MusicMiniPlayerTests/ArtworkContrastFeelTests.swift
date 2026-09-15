import XCTest
@testable import MusicMiniPlayerCore

/// C5 (roadmap C5, "浅色封面对比度"): policy table + params round-trip for
/// `ArtworkContrastPolicy` / `MicroInteractionFeel.ArtworkContrastParams`.
/// Pure-model only — no view hosting, per CLAUDE.md 手感类验证 rule.
final class ArtworkContrastFeelTests: XCTestCase {

    override func tearDown() {
        MicroInteractionFeel.reset()
        super.tearDown()
    }

    // MARK: - Policy table

    func test_belowThreshold_darkenIsZero() {
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: 0.3, params: .default, reduceTransparency: false
        )
        XCTAssertEqual(resolution.darkenOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(resolution.saturation, MicroInteractionFeel.Tokens.artworkContrastSaturation)
        XCTAssertEqual(resolution.blurRadius, MicroInteractionFeel.Tokens.artworkContrastBlurRadius)
    }

    func test_atThreshold_darkenIsZero() {
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: MicroInteractionFeel.Tokens.artworkContrastBrightnessThreshold,
            params: .default, reduceTransparency: false
        )
        XCTAssertEqual(resolution.darkenOpacity, 0, accuracy: 0.0001)
    }

    func test_midRamp_darkenIsHalfway() {
        let params = MicroInteractionFeel.ArtworkContrastParams.default
        let midBrightness = params.brightnessThreshold + params.darkenRamp / 2
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: midBrightness, params: params, reduceTransparency: false
        )
        XCTAssertEqual(resolution.darkenOpacity, params.darken / 2, accuracy: 0.001)
    }

    func test_aboveRamp_darkenIsFullParamValue() {
        let params = MicroInteractionFeel.ArtworkContrastParams.default
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: params.brightnessThreshold + params.darkenRamp + 0.3,
            params: params, reduceTransparency: false
        )
        XCTAssertEqual(resolution.darkenOpacity, params.darken, accuracy: 0.0001)
    }

    func test_brightnessAboveOne_clampsToFullDarken() {
        let params = MicroInteractionFeel.ArtworkContrastParams.default
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: 5.0, params: params, reduceTransparency: false
        )
        XCTAssertEqual(resolution.darkenOpacity, params.darken, accuracy: 0.0001)
    }

    func test_brightnessBelowZero_clampsToZeroDarken() {
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: -1.0, params: .default, reduceTransparency: false
        )
        XCTAssertEqual(resolution.darkenOpacity, 0, accuracy: 0.0001)
    }

    func test_darkenParamAboveOne_clampsToOne() {
        var params = MicroInteractionFeel.ArtworkContrastParams.default
        params.darken = 3.0
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: 1.0, params: params, reduceTransparency: false
        )
        XCTAssertEqual(resolution.darkenOpacity, 1.0, accuracy: 0.0001)
    }

    func test_zeroRamp_doesNotCrash_stepsImmediately() {
        var params = MicroInteractionFeel.ArtworkContrastParams.default
        params.darkenRamp = 0
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: params.brightnessThreshold + 0.001, params: params, reduceTransparency: false
        )
        XCTAssertEqual(resolution.darkenOpacity, params.darken, accuracy: 0.01)
    }

    // MARK: - Reduce Transparency branch

    func test_reduceTransparency_forcesFixedScrimAndZeroBlur() {
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: 0.1, params: .default, reduceTransparency: true
        )
        XCTAssertEqual(resolution.darkenOpacity, MicroInteractionFeel.Tokens.artworkContrastReduceTransparencyDarken)
        XCTAssertEqual(resolution.blurRadius, 0)
        // Saturation is unaffected by Reduce Transparency — only translucency/blur is.
        XCTAssertEqual(resolution.saturation, MicroInteractionFeel.Tokens.artworkContrastSaturation)
    }

    func test_reduceTransparency_overridesEvenBrightArtwork() {
        let resolution = ArtworkContrastPolicy.resolve(
            brightness: 1.0, params: .default, reduceTransparency: true
        )
        XCTAssertEqual(resolution.darkenOpacity, MicroInteractionFeel.Tokens.artworkContrastReduceTransparencyDarken)
    }

    // MARK: - Token pins

    func test_defaultTokens_matchSpec() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.artworkContrastBlurRadius, 40)
        XCTAssertEqual(MicroInteractionFeel.Tokens.artworkContrastDarken, 0.28)
        XCTAssertEqual(MicroInteractionFeel.Tokens.artworkContrastBrightnessThreshold, 0.62)
        XCTAssertEqual(MicroInteractionFeel.Tokens.artworkContrastSaturation, 1.25)
        XCTAssertEqual(MicroInteractionFeel.Tokens.artworkContrastDarkenRamp, 0.15)
    }

    func test_defaultParams_matchTokens() {
        let params = MicroInteractionFeel.ArtworkContrastParams.default
        XCTAssertEqual(params.blurRadius, MicroInteractionFeel.Tokens.artworkContrastBlurRadius)
        XCTAssertEqual(params.darken, MicroInteractionFeel.Tokens.artworkContrastDarken)
        XCTAssertEqual(params.brightnessThreshold, MicroInteractionFeel.Tokens.artworkContrastBrightnessThreshold)
        XCTAssertEqual(params.saturation, MicroInteractionFeel.Tokens.artworkContrastSaturation)
        XCTAssertEqual(params.darkenRamp, MicroInteractionFeel.Tokens.artworkContrastDarkenRamp)
    }

    // MARK: - Channel resolve (arm switch)

    func test_channelResolve_nilFallsBackToTuned() {
        XCTAssertEqual(MicroInteractionFeel.ArtworkContrastMode.resolve(from: nil), .legacy)
    }

    func test_channelResolve_unknownFallsBackToTuned() {
        XCTAssertEqual(MicroInteractionFeel.ArtworkContrastMode.resolve(from: "garbage"), .legacy)
    }

    func test_channelResolve_legacyRecognized() {
        XCTAssertEqual(MicroInteractionFeel.ArtworkContrastMode.resolve(from: "legacy"), .legacy)
    }

    // MARK: - apply(channel:value:) — arm switch + per-param overrides

    private func storedParams() -> MicroInteractionFeel.ArtworkContrastParams {
        let dict = UserDefaults.standard.dictionary(forKey: MicroInteractionFeel.artworkContrastParamsDefaultsKey) as? [String: Double]
        return MicroInteractionFeel.ArtworkContrastParams.fromDictionary(dict)
    }

    func test_apply_artworkContrastArm_switchesAndPersists() {
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "artworkContrast", value: "legacy"))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: MicroInteractionFeel.artworkContrastDefaultsKey),
            MicroInteractionFeel.ArtworkContrastMode.legacy.rawValue
        )
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "artworkContrast", value: "tuned"))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: MicroInteractionFeel.artworkContrastDefaultsKey),
            MicroInteractionFeel.ArtworkContrastMode.tuned.rawValue
        )
    }

    func test_apply_paramOverride_roundTripsThroughUserDefaults() {
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "artworkContrast", value: "artworkContrastDarken=0.5"))
        XCTAssertEqual(storedParams().darken, 0.5, accuracy: 0.0001)
        // Other fields stay at default — a single-param override must not reset the rest.
        XCTAssertEqual(storedParams().blurRadius, MicroInteractionFeel.Tokens.artworkContrastBlurRadius)
    }

    func test_apply_paramOverride_badParamNameIgnored() {
        XCTAssertFalse(MicroInteractionFeel.apply(channel: "artworkContrast", value: "notARealParam=0.5"))
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: MicroInteractionFeel.artworkContrastParamsDefaultsKey))
    }

    func test_apply_paramOverride_nonNumericValueIgnored() {
        XCTAssertFalse(MicroInteractionFeel.apply(channel: "artworkContrast", value: "artworkContrastDarken=notANumber"))
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: MicroInteractionFeel.artworkContrastParamsDefaultsKey))
    }

    func test_apply_multipleParamOverrides_accumulate() {
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "artworkContrast", value: "artworkContrastDarken=0.4"))
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "artworkContrast", value: "artworkContrastSaturation=1.5"))
        let params = storedParams()
        XCTAssertEqual(params.darken, 0.4, accuracy: 0.0001)
        XCTAssertEqual(params.saturation, 1.5, accuracy: 0.0001)
    }

    func test_reset_clearsArmAndParams() {
        _ = MicroInteractionFeel.apply(channel: "artworkContrast", value: "legacy")
        _ = MicroInteractionFeel.apply(channel: "artworkContrast", value: "artworkContrastDarken=0.9")
        MicroInteractionFeel.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.artworkContrastDefaultsKey))
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: MicroInteractionFeel.artworkContrastParamsDefaultsKey))
    }
}
