// ──────────────────────────────────────────────
// SettingsWindowLayoutTests — the first settings build clipped the bottom row
// and mixed Chinese into the English UI (founder report, 2026-09-29).
//
//  - each tab's window height is its own content plus the 20pt bottom padding
//    (native Settings behaviour: the window follows the tab, width fixed at 480),
//    so nothing is clipped and no page leaves a large empty area;
//  - no hard-coded Chinese reaches the English UI, and every settings string
//    has both languages.
// Real SettingsWindowView through AppMain.createSettingsWindow, hosted
// offscreen, one window per page.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsWindowLayoutTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func allSubviews(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    private func hostedWindow(_ tab: SettingsTab) throws -> NSWindow {
        let suite = "nanopod.test.settings-layout.\(UUID().uuidString)"
        suites.append(suite)
        let app = AppMain()
        app.settingsWindowState = SettingsWindowState(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        app.settingsWindowState.selectedTab = tab
        app.createSettingsWindow()
        let window = try XCTUnwrap(app.settingsWindow)
        window.setFrameAutosaveName("") // never persist the parked frame into real defaults
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        spin(0.5)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private var fixedPages: [SettingsTab] {
        SettingsTab.visibleCases.filter {
            #if DEBUG || LOCAL_DEVELOPER_BUILD
            return $0 != .diagnostics // owner-only debug panel, fits however it fits
            #else
            return true
            #endif
        }
    }

    /// Points of untouched window background between the lowest drawn pixel and
    /// the bottom edge of the content view.
    private func bottomGap(of window: NSWindow) throws -> CGFloat {
        let content = try XCTUnwrap(window.contentView)
        let rep = SettingsWindowRenderTests.capture(content)
        let data = try XCTUnwrap(rep.bitmapData)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<3).map { Int(data[y * rep.bytesPerRow + x * 4 + $0]) } }
        let background = pixel(2, rep.pixelsHigh - 2)
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let p = pixel(x, y)
                if zip(p, background).contains(where: { abs($0 - $1) > 3 }) {
                    return CGFloat(rep.pixelsHigh - 1 - y) / scale
                }
            }
        }
        return content.bounds.height
    }

    // MARK: window height follows the tab

    /// General is one card of six rows (4 x 44 + 2 x 53 = 282): its window is exactly
    /// top padding + stage + gap + rows + the bottom padding.
    func test_generalWindowHeight_isContentPlusBottomPadding() throws {
        let m = SettingsMetrics.self
        XCTAssertEqual(4 * m.rowHeight + 2 * m.rowHeightWithDetail, 282)
        let window = try hostedWindow(.general)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.bounds.size.width, m.windowWidth)
        XCTAssertEqual(content.bounds.size.height,
                       m.topPadding + m.stageHeight + m.stageToPage + 282 + m.pageBottomInset, accuracy: 1)
    }

    func test_everyTab_windowHeightIsItsOwnContent_withTheSameBottomPadding() throws {
        var heights: [SettingsTab: CGFloat] = [:]
        for tab in fixedPages {
            let window = try hostedWindow(tab)
            defer { window.close() }
            let content = try XCTUnwrap(window.contentView)
            XCTAssertEqual(content.bounds.width, SettingsMetrics.windowWidth, "\(tab): width is fixed")
            heights[tab] = content.bounds.height
            // The window is exactly the page's natural height: nothing clipped, no slack.
            let controller = try XCTUnwrap(window.contentViewController as? NSTabViewController)
            let index = try XCTUnwrap(SettingsTab.visibleCases.firstIndex(of: tab))
            let page = try XCTUnwrap(controller.tabViewItems[index].viewController)
            XCTAssertEqual(content.bounds.height, page.view.fittingSize.height, accuracy: 1, "\(tab)")
            // Bottom padding: the last element sits 20pt above the edge (text footers add
            // their own line-box slack on top of it).
            let gap = try bottomGap(of: window)
            XCTAssertGreaterThanOrEqual(gap, SettingsMetrics.pageBottomInset - 1, "\(tab) bottom gap \(gap)")
            XCTAssertLessThanOrEqual(gap, SettingsMetrics.pageBottomInset + 16, "\(tab) bottom gap \(gap) — empty area under the content")
        }
        XCTAssertGreaterThan(Set(heights.values.map { Int($0.rounded()) }).count, 2, "tabs must not share one fixed height: \(heights)")
    }

    func test_generalPageGap_isExactlyTheBottomPadding() throws {
        let window = try hostedWindow(.general) // last element is a card: no text slack
        defer { window.close() }
        XCTAssertEqual(try bottomGap(of: window), SettingsMetrics.pageBottomInset, accuracy: 1)
    }

    func test_metrics_width_stage_and_padding() {
        let m = SettingsMetrics.self
        XCTAssertEqual(m.windowWidth, 480)
        XCTAssertEqual(m.contentWidth + 2 * m.outerPadding, m.windowWidth)
        XCTAssertEqual(m.pageBottomInset, 20)
        // The stage: a centred 16:9 rounded rectangle, one corner radius with the cards below.
        XCTAssertEqual(CGSize(width: m.stageWidth, height: m.stageHeight), CGSize(width: 300, height: 169))
        XCTAssertEqual(m.stageWidth / m.stageHeight, 16.0 / 9.0, accuracy: 0.01)
        XCTAssertEqual(m.stageCorner, m.cardCorner)
    }

    // MARK: language

    /// The first build showed "已授权" (from MusicController.musicKitAuthStatus,
    /// which hard-codes Chinese) next to English labels. Settings must take
    /// every visible string from L10n.
    func test_settingsView_neverShowsCoreHardCodedStatusStrings() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Sources/MusicMiniPlayerAppKit/SettingsView.swift"), encoding: .utf8)
        let cutoff = source.range(of: "MARK: - Owner Diagnostics Debug Panel")?.lowerBound ?? source.endIndex
        XCTAssertFalse(String(source[..<cutoff]).contains("musicKitAuthStatus"))
    }

    func test_englishUI_hasNoChineseInAnySettingsString() {
        L10n.languageOverride = "en"
        defer { L10n.languageOverride = nil }
        let keys = settingsStringKeys
        XCTAssertGreaterThan(keys.count, 25)
        for key in keys {
            let text = L10n.localized(key)
            XCTAssertNotEqual(text, key, "missing English string for \(key)")
            XCTAssertFalse(text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(key) → \(text) has Chinese in the English UI")
        }
        for tab in SettingsTab.visibleCases {
            XCTAssertFalse(tab.title.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(tab)")
        }
    }

    func test_chineseUI_hasAChineseStringForEverySettingsKey() {
        L10n.languageOverride = "zh"
        defer { L10n.languageOverride = nil }
        for key in settingsStringKeys {
            let text = L10n.localized(key)
            XCTAssertNotEqual(text, key, "missing Chinese string for \(key)")
        }
    }

    // MARK: helpers

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Keys the settings window displays (rows, sections, statuses, About).
    private var settingsStringKeys: [String] {
        ["player", "general", "shortcuts", "about",
         "fullscreenCover", "fullscreenCoverDesc", "edgeShowSongOnTrackChange", "edgeShowSongOnTrackChangeDesc",
         "showTranslation", "showTranslationDesc", "translateTo", "followSystem",
         "launchAtLogin", "launchAtLoginApprovalNeeded", "launchAtLoginOpenItems", "showInDock",
         "tour.settings.title", "tour.settings.keepGoing", "tour.settings.again",
         "sectionEdge", "sectionLyrics", "sectionPermissions", "sectionData",
         "automation", "appleMusic", "automationDesc", "automationGrant", "automationOpenSettings",
         "onboarding.auth.authorized", "authDenied", "authNotDetermined",
         "playbackHistory", "clearPlaybackHistoryDesc", "clearButton", "clearPlaybackHistory",
         "clearHistoryConfirmTitle", "clearHistoryConfirmMessage", "cancel",
         "shortcutsFooter", "stateOn", "stateOff", "playerFooter", "version", "aboutTagline", "acknowledgements", "reportIssue"]
    }
}
