// ──────────────────────────────────────────────
// SettingsWindowStructureTests — v3.2 settings window redesign
// (docs/design/2026-09-25-menu-settings/proposal.md §4, §5)
//
// Covers the acceptance list verbatim: tab sequence, window styleMask/size,
// the "Getting to know nanoPod" title/action policy, tab persistence + URL
// aliasing, Toggle/.switch parity, SettingsDemo/row 1:1 correspondence,
// Reduce Motion suppressing PhaseAnimator/KeyframeAnimator/TimelineView, the
// row hover-intent dwell gate (fake clock, no real sleeping), Launch at
// Login going through a fakeable protocol, the AccentColor asset, and the
// "Music Mini Player" -> "nanoPod" text sweep.
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

    func test_settingsWindowState_persistsSelectedTabAcrossInstances() {
        let key = SettingsWindowState.selectedTabDefaultsKey
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let state = SettingsWindowState()
        state.selectedTab = .shortcuts
        let restored = SettingsWindowState()
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

    // MARK: - 4. Every Toggle explicitly `.toggleStyle(.switch)`

    func test_everyToggleInSettingsView_hasExplicitSwitchStyle() throws {
        let fullSource = try sourceText("Sources/MusicMiniPlayerAppKit/SettingsView.swift")
        // Scope to the proposal's own rows — the DEBUG-only Owner Diagnostics
        // panel (unrelated to this design, pre-existing) has its own toggle
        // that this acceptance criterion was never about.
        let cutoff = fullSource.range(of: "MARK: - Owner Diagnostics Debug Panel")?.lowerBound ?? fullSource.endIndex
        let source = String(fullSource[..<cutoff])
        let toggleCount = occurrenceCount(of: "Toggle(isOn:", in: source)
        let switchStyleCount = occurrenceCount(of: ".toggleStyle(.switch)", in: source)
        XCTAssertGreaterThan(toggleCount, 0)
        XCTAssertEqual(toggleCount, switchStyleCount, "every Toggle(isOn:) must be followed by .toggleStyle(.switch)")
    }

    // MARK: - 5. SettingsDemo.allCases <-> row 1:1 correspondence

    func test_settingsDemoCases_matchRowDeclarationsExactly() throws {
        let source = try sourceText("Sources/MusicMiniPlayerAppKit/SettingsView.swift")

        var declared = identifiersAfter("SettingsRow(demo: .", in: source)

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

    func test_everySettingsDemoCase_hasARestingFrame() {
        let context = SettingsDemoContext(
            fullscreenCoverOn: true,
            edgeShowSongOn: true,
            showTranslationOn: true,
            translationSampleText: "Let's go see the sea",
            launchAtLoginOn: false,
            showInDockOn: true,
            automationStatus: .authorized,
            appleMusicStatus: .authorized,
            shortcutDescriptions: [:]
        )
        for demo in SettingsDemo.allCases {
            // Constructing the view must not crash/trap for any case.
            _ = demo.restingFrame(state: context)
        }
    }

    // MARK: - 6. Reduce Motion suppresses PhaseAnimator/KeyframeAnimator/TimelineView

    private var dummyContext: SettingsDemoContext {
        SettingsDemoContext(
            fullscreenCoverOn: false,
            edgeShowSongOn: false,
            showTranslationOn: false,
            translationSampleText: "",
            launchAtLoginOn: false,
            showInDockOn: false,
            automationStatus: .notDetermined,
            appleMusicStatus: .notDetermined,
            shortcutDescriptions: [:]
        )
    }

    /// `_ConditionalContent<True, False>`'s STATIC type always spells out both
    /// branches — `String(reflecting: type(of: body))` says "PhaseAnimator"
    /// regardless of `reduceMotion`, since Swift's ViewBuilder bakes both
    /// possible branch types into one compile-time type (verified: this is
    /// what a first attempt at this test found). A `Mirror` walk of the live
    /// `body` VALUE was tried next, but SwiftUI's internal view-tree types
    /// (accessibility-modifier storage in particular) aren't reliably
    /// Mirror-reflectable — a real risk of false failures/passes for reasons
    /// having nothing to do with `reduceMotion`. The reliable, maintainable
    /// check for "this branch never constructs a PhaseAnimator" is structural:
    /// the `if reduceMotion { … } else { … }` branch in `DemoStage.body`'s
    /// source must not mention the banned animator types in its own lexical
    /// scope — same source-scan convention as `ButtonFillTintTests`.
    func test_demoStage_reduceMotionBranch_sourceNeverMentionsAnimatorTypes() throws {
        let source = try sourceText("Sources/MusicMiniPlayerAppKit/SettingsDemoStage.swift")
        guard let branchStart = source.range(of: "if reduceMotion {"),
              let branchEnd = source.range(of: "} else {", range: branchStart.upperBound..<source.endIndex) else {
            return XCTFail("DemoStage.body's `if reduceMotion { … } else {` shape not found")
        }
        let reduceMotionBranch = String(source[branchStart.upperBound..<branchEnd.lowerBound])
        XCTAssertFalse(reduceMotionBranch.contains("PhaseAnimator"), reduceMotionBranch)
        XCTAssertFalse(reduceMotionBranch.contains("KeyframeAnimator"), reduceMotionBranch)
        XCTAssertFalse(reduceMotionBranch.contains("TimelineView"), reduceMotionBranch)
    }

    /// Positive control: the `else` (motion-allowed) branch DOES use
    /// PhaseAnimator — proves the source-scan above targets the right text
    /// (not just failing to find PhaseAnimator for unrelated reasons).
    func test_demoStage_motionAllowedBranch_sourceDoesUsePhaseAnimator() throws {
        let source = try sourceText("Sources/MusicMiniPlayerAppKit/SettingsDemoStage.swift")
        guard let branchStart = source.range(of: "} else {"),
              let branchEnd = source.range(of: "} else if let demo = SettingsDemo.allCases.first {", range: branchStart.upperBound..<source.endIndex) else {
            return XCTFail("DemoStage.body's else branch not found in the expected shape")
        }
        let motionBranch = String(source[branchStart.upperBound..<branchEnd.lowerBound])
        XCTAssertTrue(motionBranch.contains("PhaseAnimator"), motionBranch)
    }

    // MARK: - 7. Row hover-intent dwell gate (fake clock — no real sleeping)

    func test_hoverIntent_fastPassThrough_neverCommits() {
        let host = SettingsRowHoverIntentHost()
        var committed: [Bool] = []
        host.onCommitChanged = { committed.append($0) }

        var now: TimeInterval = 0
        host.nowProvider = { now }
        host.scheduleProvider = { _, _ in
            // Never fires — simulates leaving before the dwell timer's real-world deadline.
        }

        host.hoverChanged(true)
        now += 0.05 // 50ms — well under the 150ms dwell
        host.hoverChanged(false)

        XCTAssertTrue(committed.isEmpty, "a fast pass must never switch the demo")
    }

    func test_hoverIntent_fullDwell_commits() {
        let host = SettingsRowHoverIntentHost()
        var committed: [Bool] = []
        host.onCommitChanged = { committed.append($0) }

        var now: TimeInterval = 0
        host.nowProvider = { now }
        host.scheduleProvider = { delay, fire in
            now += delay // fake clock: jump straight to the armed deadline
            fire()
        }

        host.hoverChanged(true)
        XCTAssertEqual(committed, [true])
    }

    func test_hoverIntentConfig_matchesProgressBarNumbers() {
        // proposal §4.4 explicitly reuses the progress bar's numbers.
        XCTAssertEqual(ProgressHoverIntentEngine.Config.default.dwellDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(ProgressHoverIntentEngine.Config.default.movementTolerance, 4.0, accuracy: 0.0001)
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
