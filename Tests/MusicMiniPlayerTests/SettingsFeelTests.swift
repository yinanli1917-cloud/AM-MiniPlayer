import XCTest
@testable import MusicMiniPlayerCore

/// C4 设置页两条 feel channel（settingsTab / settingsToggle）的纯逻辑覆盖：
/// resolve 钳制、apply/reset 往返、SettingsTabTransition 决策表、
/// SettingsTogglePulsePolicy 决策表、token 钉死。
final class SettingsFeelTests: XCTestCase {

    override func tearDown() {
        MicroInteractionFeel.reset()
        super.tearDown()
    }

    // MARK: - resolve() 钳制：未知/nil 一律回落默认，不能让 typo 改变生产表现

    func test_settingsTabMode_resolve_clampsUnknownAndNilToDefault() {
        XCTAssertEqual(MicroInteractionFeel.SettingsTabMode.resolve(from: nil), .system)
        XCTAssertEqual(MicroInteractionFeel.SettingsTabMode.resolve(from: "garbage"), .system)
        XCTAssertEqual(MicroInteractionFeel.SettingsTabMode.resolve(from: "SYSTEM"), .system)
        XCTAssertEqual(MicroInteractionFeel.SettingsTabMode.resolve(from: "custom"), .custom)
    }

    func test_settingsToggleMode_resolve_clampsUnknownAndNilToDefault() {
        XCTAssertEqual(MicroInteractionFeel.SettingsToggleMode.resolve(from: nil), .custom)
        XCTAssertEqual(MicroInteractionFeel.SettingsToggleMode.resolve(from: "garbage"), .custom)
        XCTAssertEqual(MicroInteractionFeel.SettingsToggleMode.resolve(from: "SYSTEM"), .system)
        XCTAssertEqual(MicroInteractionFeel.SettingsToggleMode.resolve(from: "custom"), .custom)
    }

    // MARK: - apply/reset 往返

    func test_apply_settingsTab_roundTripsThroughUserDefaults() {
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "settingsTab", value: "system"))
        MicroInteractionFeel.testingSettingsTab = nil
        XCTAssertEqual(
            MicroInteractionFeel.SettingsTabMode.resolve(
                from: UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsTabDefaultsKey)
            ),
            .system
        )

        MicroInteractionFeel.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsTabDefaultsKey))
    }

    func test_apply_settingsToggle_roundTripsThroughUserDefaults() {
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "settingsToggle", value: "system"))
        MicroInteractionFeel.testingSettingsToggle = nil
        XCTAssertEqual(
            MicroInteractionFeel.SettingsToggleMode.resolve(
                from: UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsToggleDefaultsKey)
            ),
            .system
        )

        MicroInteractionFeel.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsToggleDefaultsKey))
    }

    func test_apply_reset_clearsBothNewChannels() {
        _ = MicroInteractionFeel.apply(channel: "settingsTab", value: "system")
        _ = MicroInteractionFeel.apply(channel: "settingsToggle", value: "system")
        MicroInteractionFeel.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsTabDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsToggleDefaultsKey))
    }

    // MARK: - SettingsTabTransition 决策表

    func test_transition_systemArm_alwaysReturnsIdentityAndNilAnimation() {
        let resolved = SettingsTabTransition.resolve(arm: .system, from: 0, to: 2, reduceMotion: false)
        XCTAssertEqual(resolved.kind, .none)
        XCTAssertNil(resolved.animation)
    }

    func test_transition_systemArm_ignoresReduceMotion() {
        let resolved = SettingsTabTransition.resolve(arm: .system, from: 0, to: 1, reduceMotion: true)
        XCTAssertEqual(resolved.kind, .none)
        XCTAssertNil(resolved.animation)
    }

    func test_transition_customArm_forwardSlidesFromTrailing() {
        let resolved = SettingsTabTransition.resolve(arm: .custom, from: 0, to: 2, reduceMotion: false)
        XCTAssertEqual(resolved.kind, .slideForward)
        XCTAssertNotNil(resolved.animation)
    }

    func test_transition_customArm_backwardSlidesFromLeading() {
        let resolved = SettingsTabTransition.resolve(arm: .custom, from: 3, to: 1, reduceMotion: false)
        XCTAssertEqual(resolved.kind, .slideBackward)
        XCTAssertNotNil(resolved.animation)
    }

    func test_transition_customArm_sameIndexIsOpacityOnly() {
        let resolved = SettingsTabTransition.resolve(arm: .custom, from: 1, to: 1, reduceMotion: false)
        XCTAssertEqual(resolved.kind, .opacity)
    }

    func test_transition_reduceMotion_alwaysWinsOverCustomArm() {
        let forward = SettingsTabTransition.resolve(arm: .custom, from: 0, to: 3, reduceMotion: true)
        XCTAssertEqual(forward.kind, .opacity)

        let backward = SettingsTabTransition.resolve(arm: .custom, from: 3, to: 0, reduceMotion: true)
        XCTAssertEqual(backward.kind, .opacity)
    }

    // MARK: - SettingsTogglePulsePolicy 决策表

    func test_pulsePolicy_customArmWithoutReduceMotion_pulses() {
        XCTAssertTrue(SettingsTogglePulsePolicy.shouldPulse(arm: .custom, reduceMotion: false))
    }

    func test_pulsePolicy_systemArm_neverPulses() {
        XCTAssertFalse(SettingsTogglePulsePolicy.shouldPulse(arm: .system, reduceMotion: false))
        XCTAssertFalse(SettingsTogglePulsePolicy.shouldPulse(arm: .system, reduceMotion: true))
    }

    func test_pulsePolicy_reduceMotion_suppressesCustomArm() {
        XCTAssertFalse(SettingsTogglePulsePolicy.shouldPulse(arm: .custom, reduceMotion: true))
    }

    // MARK: - Token 钉死（call sites 不许在现场重述这些值）

    func test_tokens_settingsTab_arePinned() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.settingsTabDuration, 0.22, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.settingsTabReducedMotionDuration, 0.12, accuracy: 0.0001)
    }

    func test_tokens_settingsToggle_arePinned() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.settingsToggleBumpScale, 1.03, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.settingsToggleBumpResponse, 0.18, accuracy: 0.0001)
    }

    // MARK: - Testing overrides + isRunningTests default（同其余 channel 的既有约定）

    func test_settingsTab_testingOverride_takesPrecedence() {
        MicroInteractionFeel.testingSettingsTab = .system
        XCTAssertEqual(MicroInteractionFeel.settingsTab, .system)
        MicroInteractionFeel.testingSettingsTab = nil
        XCTAssertEqual(MicroInteractionFeel.settingsTab, .system) // isRunningTests default（09-14 撤回 custom 后）
    }

    func test_settingsToggle_testingOverride_takesPrecedence() {
        MicroInteractionFeel.testingSettingsToggle = .system
        XCTAssertEqual(MicroInteractionFeel.settingsToggle, .system)
        MicroInteractionFeel.testingSettingsToggle = nil
        XCTAssertEqual(MicroInteractionFeel.settingsToggle, .custom) // isRunningTests default
    }
}
