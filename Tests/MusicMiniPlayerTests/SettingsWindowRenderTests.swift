// ──────────────────────────────────────────────
// SettingsWindowRenderTests — offscreen PNG render of the REAL settings window
// (docs/design/2026-09-25-menu-settings/mockup.html is the visual reference).
//
// Hosts the real SettingsWindowView in a fixed 480x562 titled window (same
// construction as AppMain.createSettingsWindow) far off screen, and captures
// its content view at exactly 2x: every tab x {light, dark} x {en, zh}, plus
// every demo-stage still x {light, dark}. Output dir:
// $NANOPOD_SETTINGS_RENDER_DIR, else a throwaway temp dir. Deterministic:
// permissions / shortcuts / settings values are injected, the brand accent is
// installed through SettingsPalette.accentOverride (a bare test process has no
// NSAccentColorName Info.plist), and the tab-selection defaults use a private
// suite — nothing here touches the real nanoPod caches or defaults.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsWindowRenderTests: XCTestCase {

    static var outputDir: URL {
        if let path = ProcessInfo.processInfo.environment["NANOPOD_SETTINGS_RENDER_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nanopod-settings-render", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        SettingsPalette.accentOverride = SettingsPalette.brandAccent
    }

    override func tearDown() {
        SettingsPalette.accentOverride = nil
        L10n.languageOverride = nil
        super.tearDown()
    }

    // MARK: harness

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Capture `view` at exactly 2x regardless of the host display.
    static func capture(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    static func writePNG(_ rep: NSBitmapImageRep, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: outputDir.appendingPathComponent(name))
    }

    private static let renderContext = SettingsDemoContext(
        translationSampleText: "我们去看海吧",
        shortcutDescriptions: [.togglePanel: "\u{2325}\u{2318}P"]
    )

    private func makeSettingsWindow(tab: SettingsTab, dark: Bool) -> (NSWindow, SettingsWindowState) {
        let defaults = UserDefaults(suiteName: "nanopod.test.settings-render.\(UUID().uuidString)")!
        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = tab
        var view = SettingsWindowView(state: state)
        view.automationStatusProvider = { .authorized }
        view.appleMusicStatusProvider = { .notDetermined }
        let host = NSHostingController(rootView: view.environmentObject(MusicController(preview: true)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 562))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return (window, state)
    }

    // MARK: whole window

    func test_render_everyTab_lightDark_englishAndChinese() throws {
        for (lang, langTag) in [("en", "en"), ("zh", "zh")] {
            L10n.languageOverride = lang
            for dark in [false, true] {
                for tab in SettingsTab.visibleCases {
                    let (window, _) = makeSettingsWindow(tab: tab, dark: dark)
                    spin(0.5)
                    let content = try XCTUnwrap(window.contentView)
                    XCTAssertEqual(content.bounds.size, NSSize(width: 480, height: 562))
                    let rep = Self.capture(content)
                    XCTAssertEqual(rep.pixelsWide, 960)
                    XCTAssertEqual(rep.pixelsHigh, 1124)
                    let prefix = ProcessInfo.processInfo.environment["NANOPOD_RENDER_PREFIX"] ?? ""
                    try Self.writePNG(rep, name: "\(prefix)window-\(tab.rawValue)-\(dark ? "dark" : "light")-\(langTag).png")
                    window.close()
                }
            }
        }
    }

    // MARK: every demo still

    func test_render_everyDemoStill_lightDark() throws {
        L10n.languageOverride = "en"
        for dark in [false, true] {
            for demo in SettingsDemo.allCases {
                let stage = DemoStage(demo: demo, context: Self.renderContext, reduceMotion: true, caption: demo.rawValue)
                    .padding(20)
                    .background(SettingsPalette.windowBackground)
                let hosting = NSHostingView(rootView: stage)
                hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 160)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                window.isReleasedWhenClosed = false
                window.orderFront(nil)
                spin(0.15)
                let rep = Self.capture(hosting)
                XCTAssertEqual(rep.pixelsWide, 960)
                let prefix = ProcessInfo.processInfo.environment["NANOPOD_RENDER_PREFIX"] ?? ""
                try Self.writePNG(rep, name: "\(prefix)still-\(demo.rawValue)-\(dark ? "dark" : "light").png")
                window.close()
            }
        }
    }

    // MARK: cross-fade midpoint

    /// What the stage looks like halfway through a row-to-row swap: the outgoing
    /// and incoming pairs are both on screen at complementary opacity (the
    /// `.transition(.opacity)` pair at t = 0.5). Composited by hand: a still
    /// capture cannot freeze SwiftUI's animation clock.
    func test_render_crossFadeMidpoint_lightDark() throws {
        L10n.languageOverride = "en"
        let pairs: [(SettingsDemo, SettingsDemo)] = [(.fullscreenCover, .edgeShowSongOnTrackChange), (.launchAtLogin, .showInDock)]
        for dark in [false, true] {
            for (from, to) in pairs {
                let stage = ZStack {
                    DemoTilePair(demo: from, context: Self.renderContext, caption: from.rawValue).opacity(0.5)
                    DemoTilePair(demo: to, context: Self.renderContext, caption: to.rawValue).opacity(0.5)
                }
                .frame(width: 440, height: 120)
                .padding(20)
                .background(SettingsPalette.windowBackground)
                let hosting = NSHostingView(rootView: stage)
                hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 160)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                window.isReleasedWhenClosed = false
                window.orderFront(nil)
                spin(0.15)
                let prefix = ProcessInfo.processInfo.environment["NANOPOD_RENDER_PREFIX"] ?? ""
                try Self.writePNG(Self.capture(hosting), name: "\(prefix)crossfade-mid-\(from.rawValue)-to-\(to.rawValue)-\(dark ? "dark" : "light").png")
                window.close()
            }
        }
    }
}
