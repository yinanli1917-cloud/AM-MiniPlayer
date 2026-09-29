// ──────────────────────────────────────────────
// SettingsToolbarTabsTests — the settings window's page switcher is the native
// macOS 26 toolbar-tab strip (NSTabViewController, tabStyle .toolbar: SF Symbol
// over label, accent-tinted selection, window title = page name), not the
// hand-drawn segmented control (founder decision 2026-09-29).
//
//  - the window's content controller is a toolbar-style tab controller with one
//    item per SettingsTab, each with an icon and the tab's title;
//  - selecting a tab (by state or by the toolbar) changes the window title;
//  - with the segmented control gone, every page still fits its viewport
//    (SettingsWindowLayoutTests).
// Real windows through AppMain.createSettingsWindow, hosted offscreen; the tab
// state uses a private defaults suite, never the real one.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsToolbarTabsTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        L10n.languageOverride = nil
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// A real settings window built by the app's own code path, parked far off
    /// screen, with tab state in a throwaway suite.
    private func makeWindow(selected: SettingsTab = .general) throws -> (app: AppMain, window: NSWindow) {
        let suite = "nanopod.test.settings-toolbar.\(UUID().uuidString)"
        suites.append(suite)
        let app = AppMain()
        app.settingsWindowState = SettingsWindowState(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        app.settingsWindowState.selectedTab = selected
        app.createSettingsWindow()
        let window = try XCTUnwrap(app.settingsWindow)
        window.setFrameAutosaveName("") // never persist the parked frame into real defaults
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        spin(0.4)
        return (app, window)
    }

    func test_window_hasOneNativeToolbarTabPerPage_eachWithAnIcon() throws {
        L10n.languageOverride = "en"
        let (_, window) = try makeWindow()
        defer { window.close() }
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController,
                                 "the settings window's content must be an NSTabViewController")
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.count, SettingsTab.visibleCases.count)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), SettingsTab.visibleCases.map(\.title))
        for item in tabs.tabViewItems {
            XCTAssertNotNil(item.image, "\(item.label) needs an SF Symbol")
        }
        XCTAssertEqual(Array(SettingsTab.visibleCases.map(\.title).prefix(4)), ["Player", "General", "Shortcuts", "About"])
    }

    /// The persisted / requested tab is what the window opens on (the tab view
    /// resets to its first item while loading — this bit the first build).
    func test_window_opensOnThePersistedTab() throws {
        L10n.languageOverride = "en"
        for tab in SettingsTab.visibleCases {
            let (_, window) = try makeWindow(selected: tab)
            defer { window.close() }
            let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
            XCTAssertEqual(tabs.tabViewItems[tabs.selectedTabViewItemIndex].label, tab.title)
            XCTAssertEqual(window.title, tab.title)
        }
    }

    func test_windowTitle_followsTheSelectedTab() throws {
        L10n.languageOverride = "en"
        let (app, window) = try makeWindow()
        defer { window.close() }
        for tab in SettingsTab.visibleCases {
            app.settingsWindowState.selectedTab = tab
            spin(0.3)
            XCTAssertEqual(window.title, tab.title, "state → window title for \(tab)")
        }
        // The toolbar path: the user clicking a tab item.
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        for (index, tab) in SettingsTab.visibleCases.enumerated().reversed() {
            tabs.selectedTabViewItemIndex = index
            spin(0.3)
            XCTAssertEqual(window.title, tab.title, "toolbar → window title for \(tab)")
            XCTAssertEqual(app.settingsWindowState.selectedTab, tab, "toolbar → persisted state for \(tab)")
        }
    }

    /// Native Settings behaviour: switching tabs resizes the window to the new
    /// page, keeping the top edge where it was.
    func test_switchingTabs_resizesTheWindow_topEdgePinned() throws {
        let (app, window) = try makeWindow(selected: .general)
        defer { window.close() }
        let top = window.frame.maxY
        let generalHeight = try XCTUnwrap(window.contentView).bounds.height
        app.settingsWindowState.selectedTab = .player
        spin(1.0)
        let playerHeight = try XCTUnwrap(window.contentView).bounds.height
        XCTAssertNotEqual(playerHeight, generalHeight, accuracy: 20)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "top edge must stay pinned")
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.width, SettingsMetrics.windowWidth)
        app.settingsWindowState.selectedTab = .general
        spin(1.0)
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.height, generalHeight, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
    }

    func test_segmentedControl_isGone() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["SettingsView.swift", "SettingsControls.swift", "SettingsPalette.swift"] {
            let text = try String(contentsOf: repo.appendingPathComponent("Sources/MusicMiniPlayerAppKit/\(file)"), encoding: .utf8)
            XCTAssertFalse(text.contains("SettingsSegmentedControl"), file)
            XCTAssertFalse(text.contains("segmentedHeight"), file)
        }
    }
}
