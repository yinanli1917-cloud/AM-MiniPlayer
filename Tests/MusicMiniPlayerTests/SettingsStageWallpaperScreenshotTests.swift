// ──────────────────────────────────────────────
// SettingsStageWallpaperScreenshotTests — every StageWallpaper candidate in the REAL settings
// window (title bar, toolbar tabs, page): Player tab with a scene mid-animation + General tab,
// light and dark, one `screencapture -l <windowID>` each. The window is ordered front at
// .floating level WITHOUT activating the app and closed right after each shot.
//
// Opt-in: set NANOPOD_STAGE_GRADIENT_SHOTS_DIR to an output directory, otherwise skipped (the
// shots are design evidence, not a regression gate). Files: <candidate>-<player|general>-<light|dark>.png.
// Tab state uses a private defaults suite; nothing here touches real caches or defaults.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsStageWallpaperScreenshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SettingsPalette.accentOverride = SettingsPalette.brandAccent
    }

    override func tearDown() {
        StageWallpaper.override = nil
        StageArt.override = nil
        SettingsPalette.accentOverride = nil
        L10n.languageOverride = nil
        super.tearDown()
    }

    func outputDirForArt() throws -> URL { try outputDir() }
    func makeStateForArt(_ tab: SettingsTab) throws -> SettingsWindowState { try makeState(tab) }
    func presentForArt(_ window: NSWindow) { present(window) }
    func shootForArt(_ window: NSWindow, to url: URL) throws { try shoot(window, to: url) }

    private func outputDir() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["NANOPOD_STAGE_GRADIENT_SHOTS_DIR"] else {
            throw XCTSkip("set NANOPOD_STAGE_GRADIENT_SHOTS_DIR to capture the wallpaper candidates")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func present(_ window: NSWindow) {
        if let screen = NSScreen.main {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 24, y: screen.visibleFrame.minY + 24))
        }
        window.level = .floating
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
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nanopod.test.stage-wallpaper-shots.\(UUID().uuidString)"))
        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = tab
        return state
    }

    /// `NANOPOD_STAGE_GRADIENT_ONLY` (comma list of candidate names) narrows a re-run.
    private var candidates: [StageWallpaper] {
        guard let only = ProcessInfo.processInfo.environment["NANOPOD_STAGE_GRADIENT_ONLY"] else { return StageWallpaper.candidates }
        let names = Set(only.split(separator: ",").map(String.init))
        return StageWallpaper.candidates.filter { names.contains($0.name) }
    }

    func test_shoot_everyCandidate_playerAndGeneral_lightAndDark() throws {
        let dir = try outputDir()
        L10n.languageOverride = "en"
        for candidate in candidates {
            StageWallpaper.override = candidate
            for dark in [false, true] {
                // Player tab, peek scene with the song card slid out (≈ 4.5s into the loop).
                do {
                    let hover = SettingsHoverIntentModel()
                    let window = SettingsWindowRenderTests.makeSettingsWindow(state: try makeState(.player), dark: dark, hover: hover)
                    present(window)
                    spin(0.8)
                    hover.pointerEntered(.edgeShowSongOnTrackChange, at: CGPoint(x: 100, y: 20))
                    spin(4.6)
                    try shoot(window, to: dir.appendingPathComponent("\(candidate.name)-player-\(dark ? "dark" : "light").png"))
                    window.close()
                }
                // General tab: the "Getting to know nanoPod" still (wallpaper + panel + glass card, no login dimming).
                do {
                    let hover = SettingsHoverIntentModel()
                    let window = SettingsWindowRenderTests.makeSettingsWindow(state: try makeState(.general), dark: dark, hover: hover)
                    present(window)
                    spin(0.8)
                    hover.pointerEntered(.gettingToKnowNanoPod, at: CGPoint(x: 100, y: 20))
                    spin(1.4)
                    try shoot(window, to: dir.appendingPathComponent("\(candidate.name)-general-\(dark ? "dark" : "light").png"))
                    window.close()
                }
            }
        }
    }
}

extension SettingsStageWallpaperScreenshotTests {

    /// Art candidates (teal / olive sea) on the shipped wallpaper: Player tab mid peek card, Show Translation
    /// (lyrics page), Fullscreen Cover mid-fill, General tab. Files: art-<sea>-<scene>-<light|dark>.png.
    /// `NANOPOD_STAGE_ART_ONLY` (comma list of sea names) narrows a re-run.
    func test_shoot_artCandidates_scenes_lightAndDark() throws {
        let dir = try outputDirForArt()
        L10n.languageOverride = "en"
        let only = ProcessInfo.processInfo.environment["NANOPOD_STAGE_ART_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let scenes: [(name: String, tab: SettingsTab, demo: SettingsDemo, wait: Double)] = [
            ("peek", .player, .edgeShowSongOnTrackChange, 4.6),
            ("translation", .player, .showTranslation, 3.0),
            ("cover", .player, .fullscreenCover, 2.9),
            ("general", .general, .gettingToKnowNanoPod, 1.4),
        ]
        for art in StageArt.candidates where only?.contains(art.name) ?? true {
            StageArt.override = art
            for dark in [false, true] {
                for scene in scenes {
                    let hover = SettingsHoverIntentModel()
                    let window = SettingsWindowRenderTests.makeSettingsWindow(state: try makeStateForArt(scene.tab), dark: dark, hover: hover)
                    presentForArt(window)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                    hover.pointerEntered(scene.demo, at: CGPoint(x: 100, y: 20))
                    RunLoop.main.run(until: Date().addingTimeInterval(scene.wait))
                    try shootForArt(window, to: dir.appendingPathComponent("art-\(art.name)-\(scene.name)-\(dark ? "dark" : "light").png"))
                    window.close()
                }
            }
        }
    }
}

extension SettingsStageWallpaperScreenshotTests {

    /// General tab, real window, light and dark, with nanoPod's REAL icon (the repo's AppIcon.icns stands in for the
    /// app bundle's icon): Launch at Login mid-story (panel arriving, ~1.9s into the loop), its lit rest, and
    /// Show in Dock (icon seated). Files: gen-login-<light|dark>.png, gen-login-held-<...>.png, gen-dock-<...>.png.
    func test_shoot_generalScenes_withTheRealIcon() throws {
        let dir = try outputDirForArt()
        L10n.languageOverride = "en"
        let icon = try XCTUnwrap(SettingsDemoAppIconTests.repoIcon)
        let saved = DemoAppIcon.source
        DemoAppIcon.source = { icon }
        DemoAppIcon.resetCache()
        defer { DemoAppIcon.source = saved; DemoAppIcon.resetCache() }
        let scenes: [(name: String, demo: SettingsDemo, wait: Double)] = [
            ("login", .launchAtLogin, 1.35),
            ("login-held", .launchAtLogin, 3.2),
            ("dock", .showInDock, 2.9),
        ]
        for dark in [false, true] {
            for scene in scenes {
                let hover = SettingsHoverIntentModel()
                let window = SettingsWindowRenderTests.makeSettingsWindow(state: try makeStateForArt(.general), dark: dark, hover: hover)
                presentForArt(window)
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                hover.pointerEntered(scene.demo, at: CGPoint(x: 100, y: 20))
                RunLoop.main.run(until: Date().addingTimeInterval(scene.wait))
                try shootForArt(window, to: dir.appendingPathComponent("gen-\(scene.name)-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }
}
