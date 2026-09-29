// ──────────────────────────────────────────────
// SettingsWindowRenderTests — offscreen PNG render of the REAL settings window
// (docs/design/2026-09-25-menu-settings/mockup.html is the visual reference).
//
// Hosts the real SettingsWindowView in a 480-wide toolbar-tab window (height follows the tab) (same
// construction as AppMain.createSettingsWindow) far off screen, and captures
// its content view at exactly 2x: every tab x {light, dark} x {en, zh}, plus
// every demo scene at rest x {light, dark}. Output dir:
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

    static func writePNG(_ rep: NSBitmapImageRep, name: String, into dir: URL? = nil) throws {
        let dir = dir ?? outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }

    private static let renderContext = SettingsDemoContext(
        translationSampleText: "我们去看海吧",
        shortcutDescriptions: [.togglePanel: "\u{2325}\u{2318}P"]
    )

    /// The real settings window (native toolbar tabs, one hosted page per tab)
    /// with deterministic permission state. `hover`, when given, drives the
    /// selected tab's page so a hovered-row state can be staged without events.
    static func makeSettingsWindow(state: SettingsWindowState, dark: Bool, hover: SettingsHoverIntentModel? = nil) -> NSWindow {
        let window = SettingsTabViewController.makeWindow(state: state, autosaveName: nil) { tab in
            var view = SettingsWindowView(state: state, tab: tab, hover: tab == state.selectedTab ? hover : nil)
            view.automationStatusProvider = { .authorized }
            view.appleMusicStatusProvider = { .notDetermined }
            return SettingsTabViewController.hostPage(view.environmentObject(MusicController(preview: true)))
        }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        return window
    }

    private func makeSettingsWindow(tab: SettingsTab, dark: Bool) -> (NSWindow, SettingsWindowState) {
        let defaults = UserDefaults(suiteName: "nanopod.test.settings-render.\(UUID().uuidString)")!
        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = tab
        return (Self.makeSettingsWindow(state: state, dark: dark), state)
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
                    XCTAssertEqual(content.bounds.width, 480)
                    let rep = Self.capture(content)
                    XCTAssertEqual(rep.pixelsWide, 960)
                    XCTAssertEqual(CGFloat(rep.pixelsHigh), content.bounds.height * 2, accuracy: 2)
                    let prefix = ProcessInfo.processInfo.environment["NANOPOD_RENDER_PREFIX"] ?? ""
                    try Self.writePNG(rep, name: "\(prefix)window-\(tab.rawValue)-\(dark ? "dark" : "light")-\(langTag).png")
                    window.close()
                }
            }
        }
    }

    // MARK: every demo, at rest

    func test_render_everyDemoAtRest_lightDark() throws {
        L10n.languageOverride = "en"
        for dark in [false, true] {
            for demo in SettingsDemo.allCases {
                let model = DemoStageModel()
                model.show(demo)
                var context = Self.renderContext
                context.captions[demo] = demo.rawValue
                let stage = DemoStage(model: model, context: context)
                    .padding(EdgeInsets(top: 20, leading: 90, bottom: 20, trailing: 90))
                    .background(SettingsPalette.windowBackground)
                let hosting = NSHostingView(rootView: stage)
                hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 209)
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
                try Self.writePNG(rep, name: "\(prefix)rest-\(demo.rawValue)-\(dark ? "dark" : "light").png")
                window.close()
            }
        }
    }
}
