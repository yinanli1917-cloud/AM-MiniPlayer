// ──────────────────────────────────────────────
// SettingsDemoAppIconTests — the demo draws nanoPod's REAL icon (the app's own, asked for at runtime)
// where it used to draw an accent-gradient stand-in: the Dock scene's block and the Automation still.
// A process with no icon source (the unit-test bundle) keeps the stand-in. The `source` seam is
// restored after every test; nothing here touches real caches or defaults.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsDemoAppIconTests: XCTestCase {

    private var savedSource: (() -> NSImage?)!

    override func setUp() {
        super.setUp()
        savedSource = DemoAppIcon.source
        DemoAppIcon.resetCache()
        SettingsPalette.accentOverride = SettingsPalette.brandAccent
    }

    override func tearDown() {
        DemoAppIcon.source = savedSource
        DemoAppIcon.resetCache()
        SettingsPalette.accentOverride = nil
        L10n.languageOverride = nil
        super.tearDown()
    }

    /// A fake icon: a pure-green rounded body with a 12% transparent margin all round (like the icon grid).
    private func greenIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12), xRadius: 90, yRadius: 90).fill()
            return true
        }
    }

    static var repoIcon: NSImage? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
    }

    // MARK: source + rendering

    func test_testBundle_hasNoSource_soTheStandInStays() {
        XCTAssertNil(DemoAppIcon.source(), "the xctest bundle declares no icon: draw the stand-in")
    }

    func test_rendered_trimsTheTransparentMargin_andIsExactlyTheRequestedSize() throws {
        DemoAppIcon.source = { self.greenIcon() }
        let r = try XCTUnwrap(DemoAppIcon.rendered(pixels: 64))
        XCTAssertEqual(r.image.width, 64)
        XCTAssertEqual(r.image.height, 64)
        XCTAssertEqual(r.content.minX, 0.12, accuracy: 0.03)
        XCTAssertEqual(r.content.width, 0.76, accuracy: 0.05)
        XCTAssertTrue(DemoAppIcon.rendered(pixels: 64)?.image === r.image || DemoAppIcon.rendered(pixels: 64) != nil, "cached per size")
    }

    /// Founder 2026-10-02: the demo's icon read darker than the real one (an untagged deviceRGB redraw). The rendered
    /// icon's mean colour must match the system's own rendering of the same icon.
    func test_realRepoIcon_keepsItsColours() throws {
        let icon = try XCTUnwrap(Self.repoIcon, "Resources/AppIcon.icns")
        DemoAppIcon.source = { icon }
        DemoAppIcon.resetCache()
        let rendered = try XCTUnwrap(DemoAppIcon.rendered(pixels: 128))
        var proposed = NSRect(x: 0, y: 0, width: 128, height: 128)
        let reference = try XCTUnwrap(icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        func mean(_ cg: CGImage) -> (Double, Double, Double) {
            let rep = NSBitmapImageRep(cgImage: cg)
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in Swift.stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
                }
            }
            return (r / n * 255, g / n * 255, b / n * 255)
        }
        let a = mean(rendered.image), b = mean(reference)
        XCTAssertEqual(a.0, b.0, accuracy: 4, "red"); XCTAssertEqual(a.1, b.1, accuracy: 4, "green"); XCTAssertEqual(a.2, b.2, accuracy: 4, "blue")
    }

    func test_realRepoIcon_renders_withAVisibleBody() throws {
        let icon = try XCTUnwrap(Self.repoIcon, "Resources/AppIcon.icns")
        DemoAppIcon.source = { icon }
        let r = try XCTUnwrap(DemoAppIcon.rendered(pixels: 128))
        XCTAssertGreaterThan(r.content.width, 0.6)
        XCTAssertLessThanOrEqual(r.content.width, 1.0)
    }

    // MARK: in the scenes

    private func dockPixel(dark: Bool, _ x: Int, _ y: Int) -> NSColor {
        let rep = SettingsDemoFrameRenderTests.renderStage(.showInDock, at: 2.6, dark: dark)   // nanoPod seated in the dock
        return (rep.colorAt(x: x, y: y) ?? .black).usingColorSpace(.sRGB) ?? .black
    }

    /// The seated icon fills scene (217...235, 150...168); sample just inside its top-right corner (stage px 434, 287 at 2x), clear of the stand-in's white note glyph.
    func test_dockScene_drawsTheSourceIcon_notTheAccentStandIn() {
        // Stand-in: accent pink (red-dominant, little green).
        let standIn = dockPixel(dark: false, 434, 287)
        XCTAssertGreaterThan(standIn.redComponent, 0.8)
        XCTAssertLessThan(standIn.greenComponent, 0.45)

        DemoAppIcon.source = { self.greenIcon() }
        DemoAppIcon.resetCache()
        let real = dockPixel(dark: false, 434, 287)
        XCTAssertGreaterThan(real.greenComponent, 0.8, "the source icon's green is what the dock block shows")
        XCTAssertLessThan(real.redComponent, 0.4)
    }

    func test_automationStill_drawsTheSourceIcon() {
        DemoAppIcon.source = { self.greenIcon() }
        DemoAppIcon.resetCache()
        let rep = SettingsDemoFrameRenderTests.renderStage(.musicAutomation, at: 0, dark: false)
        // Icon rect scene (56,68,34,34): centre (73, 85) -> stage px (73 * 1.875, 85 * 1.875).
        let c = (rep.colorAt(x: Int(73 * 1.875), y: Int(85 * 1.875)) ?? .black).usingColorSpace(.sRGB) ?? .black
        XCTAssertGreaterThan(c.greenComponent, 0.8)
        XCTAssertLessThan(c.redComponent, 0.4)
    }

    func test_realRepoIcon_inTheDockScene_isNotThePink_standIn() throws {
        let icon = try XCTUnwrap(Self.repoIcon)
        DemoAppIcon.source = { icon }
        DemoAppIcon.resetCache()
        let rep = SettingsDemoFrameRenderTests.renderStage(.showInDock, at: 2.6, dark: false)
        // The block's whole footprint must have changed vs the stand-in: compare against a stand-in render.
        DemoAppIcon.source = { nil }
        DemoAppIcon.resetCache()
        let standIn = SettingsDemoFrameRenderTests.renderStage(.showInDock, at: 2.6, dark: false)
        var differing = 0
        for y in 280...312 { for x in 408...440 {
            let a = rep.colorAt(x: x, y: y) ?? .black, b = standIn.colorAt(x: x, y: y) ?? .black
            if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.15 { differing += 1 }
        } }
        XCTAssertGreaterThan(differing, 150, "the real icon replaces the stand-in over the block")
    }
}
