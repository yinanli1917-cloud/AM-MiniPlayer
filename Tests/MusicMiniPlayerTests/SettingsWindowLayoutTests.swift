// ──────────────────────────────────────────────
// SettingsWindowLayoutTests — the first settings build clipped the bottom row
// and mixed Chinese into the English UI (founder report, 2026-09-29).
//
//  - every page's content fits its viewport (nothing clipped at rest), and a
//    page that ever grows must scroll rather than be cut;
//  - the page viewport ends inside the window (no row hangs below the frame);
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

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func allSubviews(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    private func hostedPage(_ tab: SettingsTab) throws -> (window: NSWindow, scroll: NSScrollView?) {
        let app = AppMain()
        app.createSettingsWindow()
        let window = try XCTUnwrap(app.settingsWindow)
        app.settingsWindowState.selectedTab = tab
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        spin(0.5)
        window.contentView?.layoutSubtreeIfNeeded()
        let scrolls = allSubviews(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSScrollView }
        // The page scroller is the tallest one (the popup / recorder never host one).
        return (window, scrolls.max(by: { $0.frame.height < $1.frame.height }))
    }

    // MARK: fit / scroll

    func test_everyPage_contentFitsViewport_orScrolls() throws {
        for tab in SettingsTab.visibleCases {
            #if DEBUG || LOCAL_DEVELOPER_BUILD
            if tab == .diagnostics { continue } // owner-only debug panel, own scroll view
            #endif
            let (window, scroll) = try hostedPage(tab)
            defer { window.close() }
            let contentBounds = try XCTUnwrap(window.contentView).bounds
            XCTAssertEqual(contentBounds.size, NSSize(width: 480, height: 562), "\(tab)")
            let scrollView = try XCTUnwrap(scroll, "\(tab): the page must live in a scroll view")
            let doc = try XCTUnwrap(scrollView.documentView)
            let viewport = scrollView.contentView.bounds.height
            let contentHeight = doc.frame.height - SettingsMetrics.pageBottomInset

            // The viewport ends inside the window: nothing hangs below the frame.
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(frameInWindow.minY, -0.5, "\(tab): page viewport must not extend below the window")
            XCTAssertEqual(viewport, SettingsMetrics.pageViewportHeight, accuracy: 1, "\(tab)")

            // Either everything shows at rest, or the page really scrolls.
            let fits = contentHeight <= viewport + 0.5
            let scrolls = doc.frame.height > viewport + 0.5 && scrollView.hasVerticalScroller
            XCTAssertTrue(fits || scrolls, "\(tab): content \(contentHeight) vs viewport \(viewport) — would be clipped without scrolling")
            // And this design ships pages that fit at rest.
            XCTAssertTrue(fits, "\(tab): content \(contentHeight) exceeds viewport \(viewport)")
        }
    }

    func test_metrics_addUpToTheWindow() {
        let m = SettingsMetrics.self
        XCTAssertEqual(
            m.outerPadding + m.stageHeight + m.stageToSegmented + m.segmentedHeight + m.segmentedToContent + m.pageViewportHeight,
            m.windowSize.height, accuracy: 0.001)
        XCTAssertEqual(m.windowSize, CGSize(width: 480, height: 562))
        XCTAssertEqual(m.contentWidth + 2 * m.outerPadding, m.windowSize.width)
        XCTAssertEqual(m.segmentedHeight, 24)
        XCTAssertEqual(m.stageHeight, 120)
        XCTAssertEqual(m.tileWidth * 2 + m.stageTileGap, m.contentWidth)
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
         "automation", "appleMusic", "automationFooter", "automationGrant", "automationOpenSettings",
         "onboarding.auth.authorized", "authDenied", "authNotDetermined",
         "playbackHistory", "clearPlaybackHistoryDesc", "clearButton", "clearPlaybackHistory",
         "clearHistoryConfirmTitle", "clearHistoryConfirmMessage", "cancel",
         "shortcutsFooter", "version", "aboutTagline", "acknowledgements", "reportIssue"]
    }
}
