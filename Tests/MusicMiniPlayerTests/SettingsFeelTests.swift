import XCTest
@testable import MusicMiniPlayerCore

/// C4 设置页 settingsToggle feel channel 的纯逻辑覆盖：resolve 钳制、
/// apply/reset 往返、SettingsTogglePulsePolicy 决策表、token 钉死。
///
/// `settingsTab`/`SettingsTabTransition` (the TabView-era tab-switch crossfade)
/// were deleted 2026-09-27 with the menu/settings v3.2 redesign — the new
/// settings window uses a segmented Picker with no page transition, so there
/// is nothing left for that channel to arm (docs/design/2026-09-25-menu-
/// settings/proposal.md §4.4). `settingsToggle`'s default flipped from
/// `.custom` to `.system` in the same change: the redesign's demo-stage
/// playback already gives switch-toggle feedback, so the label pulse is no
/// longer the shipping default (it stays available for debug comparison).
final class SettingsFeelTests: XCTestCase {

    override func tearDown() {
        MicroInteractionFeel.reset()
        super.tearDown()
    }

    // MARK: - resolve() 钳制：未知/nil 一律回落默认，不能让 typo 改变生产表现

    func test_settingsToggleMode_resolve_clampsUnknownAndNilToDefault() {
        XCTAssertEqual(MicroInteractionFeel.SettingsToggleMode.resolve(from: nil), .system)
        XCTAssertEqual(MicroInteractionFeel.SettingsToggleMode.resolve(from: "garbage"), .system)
        XCTAssertEqual(MicroInteractionFeel.SettingsToggleMode.resolve(from: "CUSTOM"), .custom)
        XCTAssertEqual(MicroInteractionFeel.SettingsToggleMode.resolve(from: "system"), .system)
    }

    // MARK: - apply/reset 往返

    func test_apply_settingsToggle_roundTripsThroughUserDefaults() {
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "settingsToggle", value: "custom"))
        MicroInteractionFeel.testingSettingsToggle = nil
        XCTAssertEqual(
            MicroInteractionFeel.SettingsToggleMode.resolve(
                from: UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsToggleDefaultsKey)
            ),
            .custom
        )

        MicroInteractionFeel.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsToggleDefaultsKey))
    }

    func test_apply_reset_clearsSettingsToggleChannel() {
        _ = MicroInteractionFeel.apply(channel: "settingsToggle", value: "custom")
        MicroInteractionFeel.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.settingsToggleDefaultsKey))
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

    func test_tokens_settingsToggle_arePinned() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.settingsToggleBumpScale, 1.03, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.settingsToggleBumpResponse, 0.18, accuracy: 0.0001)
    }

    // MARK: - Testing overrides + isRunningTests default（同其余 channel 的既有约定）

    func test_settingsToggle_testingOverride_takesPrecedence() {
        MicroInteractionFeel.testingSettingsToggle = .custom
        XCTAssertEqual(MicroInteractionFeel.settingsToggle, .custom)
        MicroInteractionFeel.testingSettingsToggle = nil
        XCTAssertEqual(MicroInteractionFeel.settingsToggle, .system) // isRunningTests default (2026-09-27 flipped to .system)
    }
}
