import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// Offscreen render review of the REAL `TourCardView` (founder 2026-09-29:
/// wrong sizes, system-blue links, grey buttons, unreadable contrast). The
/// card is rendered at 2x with `ImageRenderer` (no window, no capture) onto
/// light and dark desktop-colored backdrops. Real Liquid Glass cannot be
/// drawn offscreen, so the render uses `TourCardMaterialArm.simulated` (the
/// storyboard's translucent fill over a blurred wallpaper) — it judges the
/// card's CONTENT (type, spacing, colors, contrast), not the glass itself.
/// PNGs land in `TOUR_RENDER_DIR` (default: the session scratchpad).
@MainActor
final class TourCardRenderTests: XCTestCase {
    private let outDir = ProcessInfo.processInfo.environment["TOUR_RENDER_DIR"]
        ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-render"

    private func feedback() -> TourCompletionFeedback { TourCompletionFeedback(autoTick: false) }

    private struct Rendered { let image: CGImage; let size: CGSize; let shape: TourBubbleShape }

    private func renderCard(_ model: TourCardModel, dark: Bool, gesture: TourGestureKind? = nil,
                            beakSide: TourCardSide = .right, fb: TourCompletionFeedback? = nil) -> Rendered {
        // Two passes: height first (beak offset depends on it).
        func view(_ offset: CGFloat) -> some View {
            TourCardView(model: model, beakSide: beakSide, beakOffset: offset, gestureKind: gesture,
                         arm: .simulated, feedback: fb ?? feedback(),
                         onPrimary: {}, onSecondary: {}, onStop: {}, onSkipStep: {}, onFallback: {})
                .environment(\.colorScheme, dark ? .dark : .light)
        }
        let probe = ImageRenderer(content: view(40))
        probe.scale = 2
        let h = CGFloat(probe.cgImage!.height) / 2
        let r = ImageRenderer(content: view(h * 0.55))
        r.scale = 2
        let cg = r.cgImage!
        let size = CGSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        return Rendered(image: cg, size: size, shape: TourBubbleShape(beakSide: beakSide, beakOffset: h * 0.55))
    }

    @discardableResult
    private func save(_ name: String, model: TourCardModel, wall: TourSceneComposer.Wallpaper, dark: Bool,
                      gesture: TourGestureKind? = nil, fb: TourCompletionFeedback? = nil) -> Rendered {
        let card = renderCard(model, dark: dark, gesture: gesture, fb: fb)
        let canvas = CGSize(width: card.size.width + 56, height: card.size.height + 44)
        let composed = TourSceneComposer.compose(card: card.image, cardSize: card.size, shape: card.shape, wallpaper: wall,
                                                 canvas: canvas, origin: CGPoint(x: 22, y: 22))
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        TourRender.writePNG(composed, to: "\(outDir)/\(name)-\(wall.name)-\(dark ? "darkcard" : "lightcard").png")
        return card
    }

    // MARK: - The scene PNGs (S0, G, S1 with a beat done, S7, closed ring, + neighbours)

    func test_renderScenePNGs_lightAndDark() {
        typealias F = TourSceneFixtures
        for (wall, dark) in [(TourSceneComposer.Wallpaper.light, false), (.dark, true)] {
            save("S0-welcome-en", model: F.welcome(.en), wall: wall, dark: dark)
            save("S0-welcome-zh", model: F.welcome(.zh), wall: wall, dark: dark)
            save("G-hi-music-en", model: F.gate(.en), wall: wall, dark: dark)
            save("G-hi-music-zh", model: F.gate(.zh), wall: wall, dark: dark)
            save("S1-reveal-beat1done-en", model: F.reveal(.en), wall: wall, dark: dark)
            save("S1-reveal-beat1done-zh", model: F.reveal(.zh), wall: wall, dark: dark)
            save("S3-lyrics-en", model: F.lyrics(.en), wall: wall, dark: dark)
            save("S5-move-en", model: F.move(.en), wall: wall, dark: dark, gesture: .nudgeToCorner())
            save("S7-finale-en", model: F.finale(.en), wall: wall, dark: dark)
            save("S7-finale-zh", model: F.finale(.zh), wall: wall, dark: dark)
        }
        // Cross cases: a light card on a dark desktop and the reverse.
        save("S0-welcome-en", model: TourSceneFixtures.welcome(.en), wall: .dark, dark: false)
        save("S0-welcome-en", model: TourSceneFixtures.welcome(.en), wall: .light, dark: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outDir)/S0-welcome-en-light-lightcard.png"))
    }

    /// The ring after the last step: full circle with the check (合圈后的环),
    /// rendered big enough to inspect, on both desktops.
    func test_renderClosedRing_bigOnBothDesktops() throws {
        for (wall, dark) in [(TourSceneComposer.Wallpaper.light, false), (.dark, true)] {
            let p = dark ? TourCardPalette.dark : TourCardPalette.light
            let ring = TourFeedbackRing(completed: 7, closed: true, stepLabel: "", palette: p, feedback: feedback())
                .scaleEffect(4).frame(width: 130, height: 130)
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: ring); r.scale = 2
            let cg = try XCTUnwrap(r.cgImage)
            let composed = TourSceneComposer.compose(card: cg, cardSize: CGSize(width: 130, height: 130),
                                                     shape: TourBubbleShape(beakSide: .left, beakOffset: 40, cornerRadius: 0, beakSize: 0),
                                                     wallpaper: wall, canvas: CGSize(width: 160, height: 160), origin: CGPoint(x: 15, y: 15))
            TourRender.writePNG(composed, to: "\(outDir)/ring-closed-\(wall.name).png")
        }
    }

    // MARK: - Measurable layout facts

    func test_cardWidth_isBodyPlusBeak_andRingSitsTopRight() throws {
        let card = renderCard(TourSceneFixtures.finale(.en), dark: false)
        XCTAssertEqual(card.size.width, TourCardView.windowWidth(beakSide: .right), accuracy: 0.6)
        let px = TourRender.pixels(from: card.image, scale: 2)
        // Closed ring: solid accent circle of outer diameter 28.
        var n = 0, sx = 0.0, sy = 0.0, minX = Int.max, maxX = 0, minY = Int.max
        for y in 0..<Int(70 * 2) { for x in Int(150 * 2)..<px.width where TourRender.isAccent(px.rgba(x: x, y: y)) {
            n += 1; sx += Double(x); sy += Double(y); minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y)
        } }
        XCTAssertGreaterThan(n, 100)
        let expected = TourCardView.ringCenter(inWindowFrame: CGRect(origin: .zero, size: card.size), beakSide: .right)
        // ringCenter is in y-up window space; the render is y-down.
        XCTAssertEqual(sx / Double(n) / 2, expected.x, accuracy: 1.2, "spark origin x must be the ring's drawn center")
        XCTAssertEqual(sy / Double(n) / 2, card.size.height - expected.y, accuracy: 1.2, "spark origin y must be the ring's drawn center")
        XCTAssertEqual(Double(maxX - minX + 1) / 2, 28, accuracy: 1.5, "outer diameter 28pt")
        XCTAssertEqual(Double(minY) / 2, TourCardMetrics.paddingTop, accuracy: 1.2, "ring top edge sits at the card's top padding")
    }

    func test_footerButtons_areTheTourStyle_notSystemBlueOrGrey() throws {
        let card = renderCard(TourSceneFixtures.welcome(.en), dark: false)
        let px = TourRender.pixels(from: card.image, scale: 2)
        var blue = 0
        for y in 0..<px.height { for x in 0..<px.width {
            let c = px.rgba(x: x, y: y)
            if c.a > 200, c.b > 200, c.r < 90, c.g > 90, c.g < 200 { blue += 1 }
        } }
        XCTAssertEqual(blue, 0, "no system-blue link pixels (links are secondary ink)")
        // The primary capsule is solid dark ink on light: its center is the button fill.
        let filled = (0..<px.height).contains { y in
            (Int(px.width * 6 / 10)..<px.width).contains { x in
                let c = px.rgba(x: x, y: y)
                return c.a > 240 && c.r < 40 && c.g < 40 && c.b < 45
            }
        }
        XCTAssertTrue(filled, "the primary button is a solid capsule")
    }

    // MARK: - Contrast (WCAG 4.5:1 for body text) on the simulated card fill

    func test_textContrast_meetsWCAG_onLightAndDarkDesktops() {
        func check(dark: Bool, wall: TourSceneComposer.Wallpaper, min: Double, enforce: Bool = true, _ label: String) {
            let p = dark ? TourCardPalette.dark : TourCardPalette.light
            let backdrop = TourContrast.rgb(Color(nsColor: TourSceneComposer.backdropColor(wall)))
            let fill = dark ? TourContrast.RGB(r: 34 / 255, g: 32 / 255, b: 40 / 255, a: 0.58) : TourContrast.RGB(r: 1, g: 1, b: 1, a: 0.66)
            let surface = TourContrast.over(fill, backdrop)
            let ink = TourContrast.ratio(text: TourContrast.rgb(p.ink), on: surface)
            let muted = TourContrast.ratio(text: TourContrast.rgb(p.muted), on: surface)
            let accent = TourContrast.ratio(text: TourContrast.rgb(p.accentInk), on: surface)
            print("[contrast] \(label): ink \(String(format: "%.2f", ink)), muted(body) \(String(format: "%.2f", muted)), ring number \(String(format: "%.2f", accent))")
            guard enforce else { return }
            XCTAssertGreaterThanOrEqual(ink, min, "\(label) ink")
            XCTAssertGreaterThanOrEqual(muted, min, "\(label) body text")
            XCTAssertGreaterThanOrEqual(accent, min, "\(label) ring number (accent ink tier)")
        }
        check(dark: false, wall: .light, min: 4.5, "light card / light desktop")
        check(dark: true, wall: .dark, min: 4.5, "dark card / dark desktop")
        check(dark: false, wall: .dark, min: 3.0, enforce: false, "light card / dark desktop (cross, informational)")
        check(dark: true, wall: .light, min: 3.0, enforce: false, "dark card / light desktop (cross, informational)")
    }
}
