// ──────────────────────────────────────────────
// SettingsWindowStructureTests — v3.2 settings window redesign
// (docs/design/2026-09-25-menu-settings/proposal.md §4, §5)
//
// Covers the acceptance list: tab sequence, window styleMask/size, the
// "Getting to know nanoPod" title/action policy, tab persistence + URL
// aliasing, Toggle/SettingsSwitchStyle parity, SettingsDemo/row 1:1
// correspondence, the demo stage being static stills (no animator anywhere,
// cross-fade off under Reduce Motion), Launch at Login going through a
// fakeable protocol, the AccentColor asset, and the "Music Mini Player" ->
// "nanoPod" text sweep.
// Hover-intent lives in SettingsHoverIntentTests; layout / localization in
// SettingsWindowLayoutTests.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
import ServiceManagement
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsWindowStructureTests: XCTestCase {

    override func tearDown() {
        LaunchAtLoginBridge.testingProvider = nil
        TourPersistence.reset()
        super.tearDown()
    }

    // MARK: - Source helper (same convention as ButtonFillTintTests)

    private func sourceText(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Scans occurrences of `marker` followed immediately by `.someIdentifier`
    /// and returns the set of identifiers found.
    private func identifiersAfter(_ marker: String, in source: String) -> Set<String> {
        var result = Set<String>()
        var searchRange = source.startIndex..<source.endIndex
        while let markerRange = source.range(of: marker, range: searchRange) {
            var idx = markerRange.upperBound
            var name = ""
            while idx < source.endIndex, source[idx].isLetter || source[idx].isNumber {
                name.append(source[idx])
                idx = source.index(after: idx)
            }
            if !name.isEmpty { result.insert(name) }
            searchRange = idx..<source.endIndex
        }
        return result
    }

    // MARK: - 1. Tab sequence

    func test_settingsTab_visibleCases_playerGeneralShortcutsAbout() {
        let visible = SettingsTab.visibleCases
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        XCTAssertEqual(visible, [.player, .general, .shortcuts, .about, .diagnostics])
        #else
        XCTAssertEqual(visible, [.player, .general, .shortcuts, .about])
        #endif
    }

    // MARK: - 2. Window styleMask / size / title

    func test_settingsWindow_isFixedSize_notResizableOrMiniaturizable() {
        let app = AppMain()
        app.createSettingsWindow()
        guard let window = app.settingsWindow else {
            return XCTFail("createSettingsWindow() must produce a window")
        }
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 480, height: 562))
        XCTAssertFalse(window.title.isEmpty)
        window.close()
    }

    // MARK: - 2a. "Getting to know nanoPod" title + action policy

    func test_tourButtonTitleKey_notStarted_isKeepGoing() {
        XCTAssertEqual(TourButtonPolicy.titleKey(status: .notStarted), "tour.settings.keepGoing")
    }

    func test_tourButtonTitleKey_inProgress_isKeepGoing() {
        XCTAssertEqual(TourButtonPolicy.titleKey(status: .inProgress), "tour.settings.keepGoing")
    }

    func test_tourButtonTitleKey_skipped_isKeepGoing() {
        XCTAssertEqual(TourButtonPolicy.titleKey(status: .skipped), "tour.settings.keepGoing")
    }

    func test_tourButtonTitleKey_completed_isAgain() {
        XCTAssertEqual(TourButtonPolicy.titleKey(status: .completed), "tour.settings.again")
    }

    func test_tourButtonTitles_areDifferentKeys_bothLocalized() {
        XCTAssertNotEqual(
            L10n.localized(TourButtonPolicy.titleKey(status: .notStarted)),
            L10n.localized(TourButtonPolicy.titleKey(status: .completed))
        )
    }

    func test_gettingToKnowAction_notCompleted_requestsResume_notFromStart() {
        var requestedFromStart: Bool?
        GettingToKnowNanoPodAction.perform(status: .inProgress) { requestedFromStart = $0 }
        XCTAssertEqual(requestedFromStart, false, "not-yet-finished must resume from where it left off")
    }

    func test_gettingToKnowAction_completed_requestsFromStart() {
        var requestedFromStart: Bool?
        GettingToKnowNanoPodAction.perform(status: .completed) { requestedFromStart = $0 }
        XCTAssertEqual(requestedFromStart, true, "a completed tour must restart from step 1")
    }

    // MARK: - 3. Tab persistence + URL aliasing

    func test_settingsWindowState_persistsSelectedTabAcrossInstances() throws {
        // Private suite: never touches the standard (real) defaults.
        let suite = "nanopod.test.settings-state.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = .shortcuts
        let restored = SettingsWindowState(defaults: defaults)
        XCTAssertEqual(restored.selectedTab, .shortcuts)
    }

    func test_openSettingsPage_appearanceAndLyricsAliases_landOnPlayer() {
        let app = AppMain()
        app.openSettingsPage(named: "appearance")
        XCTAssertEqual(app.settingsWindowState.selectedTab, .player)

        app.openSettingsPage(named: "lyrics")
        XCTAssertEqual(app.settingsWindowState.selectedTab, .player)

        app.openSettingsPage(named: "player")
        XCTAssertEqual(app.settingsWindowState.selectedTab, .player)

        app.settingsWindow?.close()
    }

    // MARK: - 4. Every Toggle uses the settings switch style

    func test_everyToggleInSettingsView_usesSettingsSwitchStyle() throws {
        let fullSource = try sourceText("Sources/MusicMiniPlayerAppKit/SettingsView.swift")
        // Scope to the proposal's own rows — the DEBUG-only Owner Diagnostics
        // panel (unrelated to this design, pre-existing) has its own toggle
        // that this acceptance criterion was never about.
        let cutoff = fullSource.range(of: "MARK: - Owner Diagnostics Debug Panel")?.lowerBound ?? fullSource.endIndex
        let source = String(fullSource[..<cutoff])
        let toggleCount = occurrenceCount(of: "Toggle(isOn:", in: source)
        let styleCount = occurrenceCount(of: ".toggleStyle(SettingsSwitchStyle())", in: source)
        XCTAssertGreaterThan(toggleCount, 0)
        XCTAssertEqual(toggleCount, styleCount, "every Toggle(isOn:) must be followed by .toggleStyle(SettingsSwitchStyle())")
        XCTAssertFalse(source.contains(".toggleStyle(.switch)"), "the system switch greys out in an inactive window; rows use SettingsSwitchStyle")
    }

    // MARK: - 5. SettingsDemo.allCases <-> row 1:1 correspondence

    func test_settingsDemoCases_matchRowDeclarationsExactly() throws {
        let source = try sourceText("Sources/MusicMiniPlayerAppKit/SettingsView.swift")

        // Rows declare their demo either directly (`SettingsRow(demo: .x`, also
        // when wrapped over several lines) or through the `toggleRow(.x, …)` helper.
        var declared = identifiersAfter("demo: .", in: source)
        declared.formUnion(identifiersAfter("toggleRow(.", in: source))

        // The 5 Shortcuts-tab rows go through `demo(for action:)` rather than a
        // literal `SettingsRow(demo: .case` — extract its switch's `return .case`.
        guard let funcStart = source.range(of: "private func demo(for action: GlobalShortcutAction) -> SettingsDemo {"),
              let funcEnd = source.range(of: "\n    }\n", range: funcStart.upperBound..<source.endIndex) else {
            return XCTFail("demo(for action:) not found in the expected shape")
        }
        let funcBody = String(source[funcStart.upperBound..<funcEnd.lowerBound])
        declared.formUnion(identifiersAfter("return .", in: funcBody))

        let allCases = Set(SettingsDemo.allCases.map(\.rawValue))
        XCTAssertEqual(declared, allCases, "every SettingsDemo case must map to exactly one row, and vice versa")
    }

    func test_everySettingsDemoCase_hasAStill() {
        let context = SettingsDemoContext(translationSampleText: "Let's go see the sea", shortcutDescriptions: [:])
        for demo in SettingsDemo.allCases {
            // Building the art must not crash/trap for any case, and every
            // demo belongs to exactly one page.
            _ = demo.art(context: context)
            XCTAssertTrue([SettingsTab.player, .general, .shortcuts].contains(demo.tab), demo.rawValue)
        }
        // Each page's default still is a row of that same page.
        for tab in [SettingsTab.player, .general, .shortcuts] {
            XCTAssertEqual(tab.defaultDemo?.tab, tab)
        }
        XCTAssertNil(SettingsTab.about.defaultDemo)
    }

    // MARK: - 6. The stage is static stills: no animator, cross-fade only

    /// This round ships clean stills; the animated prototypes come later.
    /// Nothing on the stage may animate on its own — the only motion is the
    /// 0.22s cross-fade between two stills, and it is off under Reduce Motion.
    func test_demoStage_hasNoAnimatorOrLoop_inAnySource() throws {
        for file in ["SettingsDemoStage.swift", "SettingsDemoArt.swift"] {
            let source = try sourceText("Sources/MusicMiniPlayerAppKit/\(file)")
            for banned in ["PhaseAnimator", "KeyframeAnimator", "TimelineView", "repeatForever", "symbolEffect", "Timer.", "Task.sleep"] {
                XCTAssertFalse(source.contains(banned), "\(file) must not contain \(banned)")
            }
        }
    }

    func test_demoStage_crossFade_isNilUnderReduceMotion() {
        XCTAssertNil(DemoStage.crossFade(reduceMotion: true))
        XCTAssertNotNil(DemoStage.crossFade(reduceMotion: false))
    }

    // MARK: - 8. Launch at Login via a fakeable protocol

    private final class FakeLaunchAtLoginProvider: LaunchAtLoginProviding {
        var status: SMAppService.Status
        private(set) var registerCallCount = 0
        private(set) var unregisterCallCount = 0

        init(status: SMAppService.Status) { self.status = status }
        func register() throws { registerCallCount += 1 }
        func unregister() throws { unregisterCallCount += 1 }
    }

    func test_launchAtLoginBridge_setEnabled_true_callsRegister() {
        let fake = FakeLaunchAtLoginProvider(status: .notRegistered)
        LaunchAtLoginBridge.testingProvider = fake
        LaunchAtLoginBridge.setEnabled(true)
        XCTAssertEqual(fake.registerCallCount, 1)
        XCTAssertEqual(fake.unregisterCallCount, 0)
    }

    func test_launchAtLoginBridge_setEnabled_false_callsUnregister() {
        let fake = FakeLaunchAtLoginProvider(status: .enabled)
        LaunchAtLoginBridge.testingProvider = fake
        LaunchAtLoginBridge.setEnabled(false)
        XCTAssertEqual(fake.unregisterCallCount, 1)
        XCTAssertEqual(fake.registerCallCount, 0)
    }

    func test_launchAtLoginBridge_status_reflectsAllThreeStates() {
        for status: SMAppService.Status in [.notRegistered, .enabled, .requiresApproval] {
            let fake = FakeLaunchAtLoginProvider(status: status)
            LaunchAtLoginBridge.testingProvider = fake
            XCTAssertEqual(LaunchAtLoginBridge.status, status)
        }
    }

    // MARK: - 9. AccentColor asset + Info.plist wiring

    func test_accentColorAsset_existsWithLightAndDarkValues() throws {
        let json = try sourceText("Sources/MusicMiniPlayerApp/Resources/AppAssets.xcassets/AccentColor.colorset/Contents.json")
        // #FA4058 = (250, 64, 88) light; #FB546C = (251, 84, 108) dark — proposal's "强调色" table.
        for eightBit in ["0xFA", "0x40", "0x58", "0xFB", "0x54", "0x6C"] {
            XCTAssertTrue(json.contains(eightBit), "expected 8-bit component \(eightBit) in AccentColor.colorset")
        }
        XCTAssertTrue(json.contains("\"appearance\""), "must declare a dark-appearance variant")
    }

    func test_infoPlist_declaresAccentColorName() throws {
        let plist = try sourceText("Sources/MusicMiniPlayerApp/Info.plist")
        XCTAssertTrue(plist.contains("NSAccentColorName"))
        XCTAssertTrue(plist.contains("<string>AccentColor</string>"))
    }

    // MARK: - 10. About page has no animation; "Music Mini Player" text is gone from AppKit

    func test_aboutPageView_hasNoAnimation() throws {
        let source = try sourceText("Sources/MusicMiniPlayerAppKit/AboutPageView.swift")
        XCTAssertFalse(source.contains("symbolEffect"))
        XCTAssertFalse(source.contains("PhaseAnimator"))
        XCTAssertFalse(source.contains("KeyframeAnimator"))
    }

    func test_appKitSources_noLongerMention_musicMiniPlayerDisplayName() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerAppKit")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("Music Mini Player"), "\(file.lastPathComponent) still mentions the old display name")
        }
    }
}
