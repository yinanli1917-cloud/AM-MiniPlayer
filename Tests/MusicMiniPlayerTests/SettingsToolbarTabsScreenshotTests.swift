// ──────────────────────────────────────────────
// SettingsToolbarTabsScreenshotTests — captures the REAL settings window (title
// bar, native toolbar tabs, page) with one `screencapture -l <windowID>` per
// shot: every tab x {light, dark}, plus one hovered-row state. The window is
// ordered front WITHOUT activating the app and closed right after each shot.
//
// Opt-in: set NANOPOD_SETTINGS_TAB_SHOTS_DIR to an output directory, otherwise
// every test here is skipped (the shots are evidence for a founder review, not
// a regression gate). Tab state uses a private defaults suite.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsToolbarTabsScreenshotTests: XCTestCase {

    private func outputDir() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["NANOPOD_SETTINGS_TAB_SHOTS_DIR"] else {
            throw XCTSkip("set NANOPOD_SETTINGS_TAB_SHOTS_DIR to capture settings window screenshots")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override func tearDown() {
        L10n.languageOverride = nil
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Parks the window on the main display's lower-right corner (visible to the
    /// compositor, out of the way), orders it front without activating the app.
    private func present(_ window: NSWindow) {
        if let screen = NSScreen.main {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 24, y: screen.visibleFrame.minY + 24))
        }
        window.orderFront(nil)
        window.makeKey()
    }

    private func shoot(_ window: NSWindow, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "screencapture failed for \(url.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
    }

    private func makeState(_ tab: SettingsTab) throws -> SettingsWindowState {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nanopod.test.settings-shots.\(UUID().uuidString)"))
        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = tab
        return state
    }

    func test_shoot_everyTab_lightAndDark() throws {
        let dir = try outputDir()
        L10n.languageOverride = "en"
        for dark in [false, true] {
            for tab in SettingsTab.visibleCases {
                let window = SettingsWindowRenderTests.makeSettingsWindow(state: try makeState(tab), dark: dark)
                present(window)
                spin(1.0)
                XCTAssertEqual(window.title, tab.title)
                try shoot(window, to: dir.appendingPathComponent("tab-\(tab.rawValue)-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }

    func test_shoot_hoveredRow() throws {
        let dir = try outputDir()
        L10n.languageOverride = "en"
        for dark in [false, true] {
            let hover = SettingsHoverIntentModel()
            let window = SettingsWindowRenderTests.makeSettingsWindow(state: try makeState(.general), dark: dark, hover: hover)
            present(window)
            spin(0.8)
            // Pointer rests on "Show in Dock": the row lights up, then the stage swaps to its scene.
            hover.pointerEntered(.showInDock, at: CGPoint(x: 100, y: 20))
            spin(1.2)
            try shoot(window, to: dir.appendingPathComponent("hover-general-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }
}
