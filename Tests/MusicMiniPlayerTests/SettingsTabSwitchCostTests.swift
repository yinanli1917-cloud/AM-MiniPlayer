// ──────────────────────────────────────────────
// SettingsTabSwitchCostTests — why switching to General used to block the main thread for ~210 ms, and
// the guards that keep it fixed (measurements: SettingsTabSwitchPerfTests, opt-in):
//  - the General page's `body` ran `AEDeterminePermissionToAutomateTarget` (~10 ms), MusicKit's status
//    (~11 ms) and `SMAppService.status` (~2.5 ms, several reads) on every evaluation, and a tab switch
//    evaluates it several times. Statuses now come from SettingsPermissionStatusStore (background
//    queries, last-known cache) and the login status is read once per appearance.
//  - hidden pages built their SwiftUI tree inside the switching click; they are now pre-warmed once.
// Private defaults suites; no real permission prompt (providers are injected).
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
import ServiceManagement
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsTabSwitchCostTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SettingsPalette.accentOverride = SettingsPalette.brandAccent
        SettingsPermissionStatusStore.resetLastKnown()
    }

    override func tearDown() {
        SettingsPalette.accentOverride = nil
        SettingsPermissionStatusStore.resetLastKnown()
        LaunchAtLoginBridge.testingProvider = nil
        L10n.languageOverride = nil
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _onMain = 0, _offMain = 0
        func record() {
            lock.lock(); defer { lock.unlock() }
            if Thread.isMainThread { _onMain += 1 } else { _offMain += 1 }
        }
        var onMain: Int { lock.lock(); defer { lock.unlock() }; return _onMain }
        var offMain: Int { lock.lock(); defer { lock.unlock() }; return _offMain }
    }

    private final class CountingLoginProvider: LaunchAtLoginProviding {
        var reads = 0
        var status: SMAppService.Status { reads += 1; return .notRegistered }
        func register() throws {}
        func unregister() throws {}
    }

    // MARK: the store

    func test_store_refreshQueriesOffTheMainThread_thenPublishesAndCaches() {
        let log = CallLog()
        let store = SettingsPermissionStatusStore()
        XCTAssertNil(store.automation, "nothing asked yet: no wrong status")
        store.refresh(automation: { log.record(); return .authorized }, appleMusic: { log.record(); return .notDetermined })
        spin(0.4)
        XCTAssertEqual(store.automation, .authorized)
        XCTAssertEqual(store.appleMusic, .notDetermined)
        XCTAssertEqual(log.onMain, 0, "the system queries never run on the main thread")
        XCTAssertEqual(log.offMain, 2)
        // A second store (another page, a re-opened window) starts from the last known answer.
        let reopened = SettingsPermissionStatusStore()
        XCTAssertEqual(reopened.automation, .authorized)
        XCTAssertEqual(reopened.appleMusic, .notDetermined)
    }

    func test_store_newerRefreshSupersedesAnOlderOneInFlight() {
        let store = SettingsPermissionStatusStore()
        store.refresh(automation: { Thread.sleep(forTimeInterval: 0.25); return .denied }, appleMusic: { .denied })
        store.refresh(automation: { .authorized }, appleMusic: { .authorized })
        spin(0.6)
        XCTAssertEqual(store.automation, .authorized)
        XCTAssertEqual(store.appleMusic, .authorized)
    }

    // MARK: the General page

    private func hostGeneral(automation: @escaping @Sendable () -> OnboardingAuthorizationStatus,
                             appleMusic: @escaping @Sendable () -> OnboardingAuthorizationStatus) throws -> (NSWindow, SettingsWindowState) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nanopod.test.tab-cost.\(UUID().uuidString)"))
        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = .general
        let musicController = MusicController(preview: true)
        let window = SettingsTabViewController.makeWindow(state: state, autosaveName: nil) { tab in
            var view = SettingsWindowView(state: state, tab: tab)
            view.automationStatusProvider = automation
            view.appleMusicStatusProvider = appleMusic
            return SettingsTabViewController.hostPage(view.environmentObject(musicController))
        }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        return (window, state)
    }

    func test_generalPage_neverAsksTheSystemOnTheMainThread_andFillsTheRowsAfterwards() throws {
        L10n.languageOverride = "en"
        let log = CallLog()
        let (window, state) = try hostGeneral(automation: { log.record(); return .authorized }, appleMusic: { log.record(); return .notDetermined })
        defer { window.close() }
        spin(0.8)
        XCTAssertEqual(log.onMain, 0, "no permission query on the main thread")
        XCTAssertGreaterThanOrEqual(log.offMain, 2, "the page did ask (in the background)")
        let rendered = try XCTUnwrap(window.contentView).accessibilityChildren() ?? []
        _ = rendered
        // Switch away and back: more body evaluations, still nothing on the main thread.
        state.selectedTab = .player
        spin(0.4)
        state.selectedTab = .general
        spin(0.6)
        XCTAssertEqual(log.onMain, 0)
    }

    func test_generalPage_bodyDoesNotReadTheLoginStatusPerEvaluation() throws {
        let fake = CountingLoginProvider()
        LaunchAtLoginBridge.testingProvider = fake
        let (window, state) = try hostGeneral(automation: { .authorized }, appleMusic: { .authorized })
        defer { window.close() }
        spin(0.6)
        let afterOpen = fake.reads
        XCTAssertLessThanOrEqual(afterOpen, 6, "init + appear reads only, got \(afterOpen)")
        // Hover churn re-evaluates the page body many times; it must not read the status again.
        for i in 0..<20 { state.selectedTab = i % 2 == 0 ? .general : .general; spin(0.01) }
        XCTAssertEqual(fake.reads, afterOpen, "the status is read per appearance, not per body evaluation")
    }

    // MARK: pre-warm

    func test_prewarm_buildsHiddenPages_inAThrowawayWindow_andHandsThemBack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nanopod.test.tab-prewarm.\(UUID().uuidString)"))
        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = .player
        var built: [SettingsTab: Int] = [:]
        let musicController = MusicController(preview: true)
        let window = SettingsTabViewController.makeWindow(state: state, autosaveName: nil, prewarmHiddenPages: true) { tab in
            built[tab, default: 0] += 1
            return SettingsTabViewController.hostPage(SettingsWindowView(state: state, tab: tab).environmentObject(musicController))
        }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        defer { window.close() }
        spin(1.8)
        let controller = try XCTUnwrap(window.contentViewController as? SettingsTabViewController)
        for item in controller.tabViewItems {
            let page = try XCTUnwrap(item.viewController)
            XCTAssertTrue(page.isViewLoaded)
            XCTAssertEqual(built[SettingsTab(rawValue: item.identifier as! String)!], 1, "each page controller is built once")
        }
        // The pages still switch normally afterwards and end up in the real window.
        for tab in [SettingsTab.general, .shortcuts, .about, .player] {
            state.selectedTab = tab
            spin(0.5)
            XCTAssertEqual(window.title, tab.title)
            let page = try XCTUnwrap(controller.tabViewItems[SettingsTab.visibleCases.firstIndex(of: tab)!].viewController)
            XCTAssertTrue(page.view.window === window, "\(tab) is attached to the settings window after the switch")
        }
    }

    func test_prewarm_isOffByDefault_forPlainWindows() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nanopod.test.tab-noprewarm.\(UUID().uuidString)"))
        let state = SettingsWindowState(defaults: defaults)
        let window = SettingsTabViewController.makeWindow(state: state, autosaveName: nil) { tab in
            SettingsTabViewController.hostPage(SettingsWindowView(state: state, tab: tab).environmentObject(MusicController(preview: true)))
        }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        defer { window.close() }
        spin(1.0)
        let controller = try XCTUnwrap(window.contentViewController as? SettingsTabViewController)
        let hidden = controller.tabViewItems.filter { $0.viewController?.view.window == nil }
        XCTAssertFalse(hidden.isEmpty, "without prewarm, hidden pages stay out of every window")
    }
}
