// ──────────────────────────────────────────────
// SettingsDemoFrameRenderTests — offscreen 2x PNGs of the REAL demo stage, frozen at exact
// scene times, for frame-by-frame comparison with the motion prototype
// (docs/design/2026-09-29-motion-prototype/prototype.html, `__proto.shot(row, t, sw)`).
//
// The stage view is the production DemoStage; DemoStageModel.debugFreeze parks a scene on
// scene time t without a fade or a clock. Output dir: $NANOPOD_DEMO_COMPARE_DIR, else a
// throwaway temp dir. Frames sit on the prototype page background (#f5f5f7 / #161618) so a
// side-by-side with the prototype screenshot differs only where the stage does.
// Nothing here touches real caches or defaults.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsDemoFrameRenderTests: XCTestCase {

    /// Prototype row id, the demo it stands for, and the scene times worth comparing
    /// (rest · mid-motion · end of motion · hold · back to rest).
    static let matrix: [(id: String, demo: SettingsDemo, times: [Double])] = [
        ("cover", .fullscreenCover, [0.3, 1.0, 1.35, 1.8, 3.0, 3.95, 4.35, 4.8, 5.5]),
        ("peek", .edgeShowSongOnTrackChange, [0.3, 1.1, 1.7, 2.75, 3.6, 4.5, 6.0, 7.15, 8.0]),
        ("trans", .showTranslation, [0.3, 1.25, 1.5, 2.6, 4.35, 5.5]),
        ("transTo", .translateTo, [0.3, 1.2, 1.85, 2.5, 5.2, 6.7]),
        ("showhide", .showHidePlayerShortcut, [0.3, 1.07, 1.16, 1.6, 3.57, 3.8, 5.0]),
        ("hideEdge", .hideToEdgeShortcut, [0.3, 1.07, 1.5, 2.2, 4.5, 5.0]),
        // General-page scenes from spec A.9 (no prototype counterpart: written for the eye, not compared).
        ("login", .launchAtLogin, [0.3, 0.9, 1.25, 2.6, 3.6]),
        ("dock", .showInDock, [0.3, 1.25, 2.6, 3.85]),
    ]

    override func setUp() {
        super.setUp()
        SettingsPalette.accentOverride = SettingsPalette.brandAccent
    }

    override func tearDown() {
        SettingsPalette.accentOverride = nil
        L10n.languageOverride = nil
        super.tearDown()
    }

    static var outputDir: URL {
        if let path = ProcessInfo.processInfo.environment["NANOPOD_DEMO_COMPARE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nanopod-demo-compare", isDirectory: true)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    static func context(_ demo: SettingsDemo, isOn: Bool) -> SettingsDemoContext {
        var c = SettingsDemoContext(
            translationSampleText: "我们去看海吧",
            shortcutDescriptions: [.togglePanel: "\u{2325}\u{2318}P", .hideToEdge: "\u{2325}\u{2318}E"])
        L10n.languageOverride = "zh"
        c.captions[demo] = captionName(demo)
        c.chips[demo] = chip(demo, isOn: isOn)
        c.switchStates[demo] = isOn
        return c
    }

    private static func captionName(_ demo: SettingsDemo) -> String {
        switch demo {
        case .fullscreenCover: return "全屏封面"
        case .edgeShowSongOnTrackChange: return "贴边收起 · 换歌探出"
        case .showTranslation: return "显示翻译"
        case .translateTo: return "翻译为"
        case .showHidePlayerShortcut: return "显示 / 隐藏面板"
        case .hideToEdgeShortcut: return "贴边隐藏"
        default: return demo.rawValue
        }
    }

    private static func chip(_ demo: SettingsDemo, isOn: Bool) -> String? {
        switch demo {
        case .fullscreenCover, .edgeShowSongOnTrackChange, .showTranslation: return isOn ? "开" : "关"
        case .translateTo: return "跟随系统"
        case .showHidePlayerShortcut: return "\u{2325}\u{2318}P"
        case .hideToEdgeShortcut: return "\u{2325}\u{2318}E"
        default: return nil
        }
    }

    /// Render the production stage frozen on scene time `t` (2x, stage-sized).
    static func renderStage(_ demo: SettingsDemo, at t: Double, isOn: Bool = true, dark: Bool) -> NSBitmapImageRep {
        let model = DemoStageModel()
        model.debugFreeze(demo, at: t)
        let bg = dark ? Color(.sRGB, red: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255, opacity: 1)
                      : Color(.sRGB, red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, opacity: 1)
        let view = DemoStage(model: model, context: context(demo, isOn: isOn)).background(bg)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 169)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        let rep = SettingsWindowRenderTests.capture(hosting)
        window.close()
        return rep
    }

    func test_render_compareFrames_lightDark() throws {
        for dark in [false, true] {
            for entry in Self.matrix {
                for t in entry.times {
                    let rep = Self.renderStage(entry.demo, at: t, dark: dark)
                    XCTAssertEqual(rep.pixelsWide, 600)
                    XCTAssertEqual(rep.pixelsHigh, 338)
                    let name = String(format: "swift-%@-%05.2f-%@.png", entry.id, t, dark ? "dark" : "light")
                    try SettingsWindowRenderTests.writePNG(rep, name: name, into: Self.outputDir)
                }
            }
        }
    }
}
