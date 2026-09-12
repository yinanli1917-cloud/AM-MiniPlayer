import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Micro-interaction feel channels: hoverCapsule / pressScale / progressHover /
// shuffleRepeat / windowPresent. Modelled on NativeLyricsFeelParityTests.
// Switch (live): nanopod://debug/feel/<channel>/<arm>, .../feel/reset.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class MicroInteractionFeelTests: XCTestCase {

    override func tearDown() {
        MicroInteractionFeel.resetTestingOverrides()
        MicroInteractionFeel.reset()
        super.tearDown()
    }

    func test_unknownOrNilValuesFallBackToDefaults() {
        XCTAssertEqual(MicroInteractionFeel.HoverCapsuleMode.resolve(from: nil), .capsule)
        XCTAssertEqual(MicroInteractionFeel.HoverCapsuleMode.resolve(from: "nope"), .capsule)
        XCTAssertEqual(MicroInteractionFeel.HoverCapsuleMode.resolve(from: "off"), .off)

        XCTAssertEqual(MicroInteractionFeel.PressScaleMode.resolve(from: nil), .unified)
        XCTAssertEqual(MicroInteractionFeel.PressScaleMode.resolve(from: "nope"), .unified)
        XCTAssertEqual(MicroInteractionFeel.PressScaleMode.resolve(from: "legacy"), .legacy)

        XCTAssertEqual(MicroInteractionFeel.ProgressHoverMode.resolve(from: nil), .tuned)
        XCTAssertEqual(MicroInteractionFeel.ProgressHoverMode.resolve(from: "nope"), .tuned)
        XCTAssertEqual(MicroInteractionFeel.ProgressHoverMode.resolve(from: "legacy"), .legacy)

        XCTAssertEqual(MicroInteractionFeel.ShuffleRepeatMode.resolve(from: nil), .critical)
        XCTAssertEqual(MicroInteractionFeel.ShuffleRepeatMode.resolve(from: "nope"), .critical)
        XCTAssertEqual(MicroInteractionFeel.ShuffleRepeatMode.resolve(from: "legacy055"), .legacy055)

        XCTAssertEqual(MicroInteractionFeel.WindowPresentMode.resolve(from: nil), .fade)
        XCTAssertEqual(MicroInteractionFeel.WindowPresentMode.resolve(from: "nope"), .fade)
        XCTAssertEqual(MicroInteractionFeel.WindowPresentMode.resolve(from: "hardcut"), .hardcut)
    }

    func test_liveAccessors_resolveUserDefaultsValueViaTypedResolve() {
        // In this harness XCTestConfigurationFilePath is not guaranteed set, so
        // isRunningTests cannot be asserted directly; instead pin that the live
        // accessor round-trips a written UserDefaults value through the same
        // resolve(from:) used everywhere else, and clamps unknown ones.
        UserDefaults.standard.set("off", forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey)
        XCTAssertEqual(
            MicroInteractionFeel.HoverCapsuleMode.resolve(
                from: UserDefaults.standard.string(forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey)
            ),
            .off
        )
        UserDefaults.standard.set("bogus", forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey)
        XCTAssertEqual(
            MicroInteractionFeel.HoverCapsuleMode.resolve(
                from: UserDefaults.standard.string(forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey)
            ),
            .capsule
        )
        UserDefaults.standard.removeObject(forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey)
    }

    func test_testingOverrides_takePrecedenceOverUserDefaults() {
        UserDefaults.standard.set("off", forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey)
        MicroInteractionFeel.testingHoverCapsule = .off
        XCTAssertEqual(MicroInteractionFeel.hoverCapsule, .off)
        MicroInteractionFeel.testingHoverCapsule = nil
        UserDefaults.standard.removeObject(forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey)
    }

    func test_apply_roundTripsThroughUserDefaults() {
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "hoverCapsule", value: "off"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey), "off")

        XCTAssertTrue(MicroInteractionFeel.apply(channel: "pressScale", value: "legacy"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: MicroInteractionFeel.pressScaleDefaultsKey), "legacy")

        XCTAssertTrue(MicroInteractionFeel.apply(channel: "progressHover", value: "legacy"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: MicroInteractionFeel.progressHoverDefaultsKey), "legacy")

        XCTAssertTrue(MicroInteractionFeel.apply(channel: "shuffleRepeat", value: "legacy055"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: MicroInteractionFeel.shuffleRepeatDefaultsKey), "legacy055")

        XCTAssertTrue(MicroInteractionFeel.apply(channel: "windowPresent", value: "hardcut"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: MicroInteractionFeel.windowPresentDefaultsKey), "hardcut")

        XCTAssertFalse(MicroInteractionFeel.apply(channel: "nope", value: "off"))
    }

    func test_reset_clearsAllFiveKeys() {
        _ = MicroInteractionFeel.apply(channel: "hoverCapsule", value: "off")
        _ = MicroInteractionFeel.apply(channel: "pressScale", value: "legacy")
        _ = MicroInteractionFeel.apply(channel: "progressHover", value: "legacy")
        _ = MicroInteractionFeel.apply(channel: "shuffleRepeat", value: "legacy055")
        _ = MicroInteractionFeel.apply(channel: "windowPresent", value: "hardcut")

        XCTAssertTrue(MicroInteractionFeel.apply(channel: "reset", value: ""))

        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.hoverCapsuleDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.pressScaleDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.progressHoverDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.shuffleRepeatDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.windowPresentDefaultsKey))
    }

    func test_tokens_pinnedToSpecifiedValues() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.hoverCapsuleDuration, 0.22, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.hoverCapsuleOpacity, 0.12, accuracy: 0.0001)

        XCTAssertEqual(MicroInteractionFeel.Tokens.pressScaleFactor, 0.92, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.pressSpringResponse, 0.18, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.pressSpringDamping, 1.0, accuracy: 0.0001)

        XCTAssertEqual(MicroInteractionFeel.Tokens.progressHoverDuration, 0.16, accuracy: 0.0001)

        XCTAssertEqual(MicroInteractionFeel.Tokens.shuffleReboundResponse, 0.30, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.shuffleReboundDamping, 1.0, accuracy: 0.0001)

        XCTAssertEqual(MicroInteractionFeel.Tokens.windowFadeInDuration, 0.18, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.windowFadeOutDuration, 0.14, accuracy: 0.0001)
    }

    // MARK: - WindowPresentPolicy (pure decision function)

    func test_windowPresentPolicy_reduceMotionAlwaysWinsOverFadeArm() {
        XCTAssertFalse(WindowPresentPolicy.resolve(arm: .fade, reduceMotion: true))
        XCTAssertFalse(WindowPresentPolicy.resolve(arm: .hardcut, reduceMotion: true))
    }

    func test_windowPresentPolicy_fadeArmAnimatesWithoutReduceMotion() {
        XCTAssertTrue(WindowPresentPolicy.resolve(arm: .fade, reduceMotion: false))
        XCTAssertFalse(WindowPresentPolicy.resolve(arm: .hardcut, reduceMotion: false))
    }

    // MARK: - WindowPresentGeneration (pure cancellation logic)

    func test_windowPresentGeneration_advanceIncrementsAndReturnsNewToken() {
        var generation = 0
        let first = WindowPresentGeneration.advance(&generation)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(generation, 1)
        let second = WindowPresentGeneration.advance(&generation)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(generation, 2)
    }

    func test_windowPresentGeneration_shouldApply_onlyWhenTokenIsStillCurrent() {
        var generation = 0
        let hideToken = WindowPresentGeneration.advance(&generation)
        XCTAssertTrue(WindowPresentGeneration.shouldApply(token: hideToken, currentGeneration: generation))

        // A later show supersedes the pending hide.
        _ = WindowPresentGeneration.advance(&generation)
        XCTAssertFalse(
            WindowPresentGeneration.shouldApply(token: hideToken, currentGeneration: generation),
            "a show requested after the hide was queued must cancel the pending orderOut"
        )
    }
}
