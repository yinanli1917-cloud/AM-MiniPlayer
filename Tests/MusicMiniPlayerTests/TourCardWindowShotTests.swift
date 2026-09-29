/**
 * [INPUT]: MusicMiniPlayerAppKit's TourCardWindow/TourCardStore, TourSceneFixtures, TourWindowCapture.
 * [OUTPUT]: TourCardWindowShotTests (opt-in with TOUR_WINDOW_SHOTS=1).
 * [POS]: Tests. Real-window acceptance stills of the tour card over light/dark backdrops.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// Real-window acceptance shots of the tour card (founder 2026-09-29): the
/// REAL `TourCardWindow` (real Liquid Glass, real clipping, real transparency)
/// ordered onto the screen over a gradient backdrop window, captured as ONE
/// composite still of just those two windows. Opt-in: it puts two windows on
/// the user's screen for a few seconds, so it only runs with
/// `TOUR_WINDOW_SHOTS=1`. PNGs land in `TOUR_WINDOW_SHOTS_DIR`.
@MainActor
final class TourCardWindowShotTests: XCTestCase {
    private let outDir = ProcessInfo.processInfo.environment["TOUR_WINDOW_SHOTS_DIR"]
        ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-window-shots"

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// A wallpaper stand-in: diagonal gradient, soft blobs and a stripe of
    /// small text-like marks (glass needs texture behind it to read as glass),
    /// plus a fake 250x284 panel.
    private final class BackdropView: NSView {
        var dark = false
        var panelRect = NSRect.zero
        override func draw(_ dirtyRect: NSRect) {
            let a = dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.20, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.80, blue: 0.62, alpha: 1)
            let b = dark ? NSColor(srgbRed: 0.34, green: 0.14, blue: 0.40, alpha: 1) : NSColor(srgbRed: 0.55, green: 0.72, blue: 0.95, alpha: 1)
            NSGradient(starting: a, ending: b)?.draw(in: bounds, angle: 35)
            let blobs: [(NSRect, NSColor)] = [
                (NSRect(x: 40, y: 250, width: 240, height: 160), dark ? .systemPink.withAlphaComponent(0.45) : .white.withAlphaComponent(0.7)),
                (NSRect(x: bounds.maxX - 300, y: 30, width: 260, height: 190), dark ? .systemTeal.withAlphaComponent(0.4) : .systemPink.withAlphaComponent(0.45)),
            ]
            for (r, c) in blobs { c.setFill(); NSBezierPath(ovalIn: r).fill() }
            (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.35).setFill()
            for row in 0..<7 {
                for col in 0..<10 {
                    NSBezierPath(roundedRect: NSRect(x: 30 + CGFloat(col) * 22 + CGFloat(row % 3) * 4, y: 40 + CGFloat(row) * 20, width: 14, height: 6), xRadius: 2, yRadius: 2).fill()
                }
            }
            // Fake panel (album-cover look) the card points at.
            let path = NSBezierPath(roundedRect: panelRect, xRadius: 16, yRadius: 16)
            NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.85, blue: 0.45, alpha: 1), ending: NSColor(srgbRed: 0.38, green: 0.34, blue: 0.16, alpha: 1))?
                .draw(in: path, angle: 90)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: panelRect.minX + 16, y: panelRect.minY + 22, width: 70, height: 9), xRadius: 4, yRadius: 4).fill()
        }
    }

    private func makeBackdrop(dark: Bool) -> (NSWindow, BackdropView) {
        let visible = NSScreen.main!.visibleFrame
        let size = CGSize(width: 900, height: 460)
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        // Same level as the card (ordered first, so the card sits above it): at .normal
        // other apps' windows stay in front of it and would show through the capture.
        window.level = .floating
        window.isOpaque = true
        let view = BackdropView(frame: NSRect(origin: .zero, size: size))
        view.dark = dark
        window.contentView = view
        return (window, view)
    }

    private struct Shot { let name: String; let model: TourCardModel; let gesture: TourGestureKind?; let cardOnLeft: Bool; let anchorIsPlay: Bool }

    private func shots() -> [Shot] {
        typealias F = TourSceneFixtures
        return [
            Shot(name: "S0-welcome", model: F.welcome(.en), gesture: nil, cardOnLeft: true, anchorIsPlay: false),
            Shot(name: "G-connect", model: F.gate(.en), gesture: nil, cardOnLeft: true, anchorIsPlay: false),
            Shot(name: "S1-reveal-beat1done-left", model: F.reveal(.en), gesture: nil, cardOnLeft: true, anchorIsPlay: true),
            Shot(name: "S1-reveal-beat1done-right", model: F.reveal(.en), gesture: nil, cardOnLeft: false, anchorIsPlay: true),
            Shot(name: "S5-move", model: F.move(.en), gesture: .nudgeToCorner, cardOnLeft: true, anchorIsPlay: false),
            Shot(name: "S7-finale", model: F.finale(.en), gesture: nil, cardOnLeft: true, anchorIsPlay: false),
            Shot(name: "S1-reveal-zh", model: F.reveal(.zh), gesture: nil, cardOnLeft: true, anchorIsPlay: true),
        ]
    }

    func test_captureRealCardWindows_lightAndDark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_WINDOW_SHOTS"] == "1", "opt-in: puts windows on screen")
        let gap: CGFloat = 16
        for dark in [false, true] {
            let (backdrop, view) = makeBackdrop(dark: dark)
            let panelSize = CGSize(width: 250, height: 284)
            view.panelRect = NSRect(x: (backdrop.frame.width - panelSize.width) / 2, y: 90, width: panelSize.width, height: panelSize.height)
            view.needsDisplay = true
            backdrop.orderFrontRegardless()

            let fb = TourCompletionFeedback(autoTick: false)
            let store = TourCardStore(model: TourSceneFixtures.welcome(.en), feedback: fb, arm: .glass)
            store.onPrimary = {}; store.onSecondary = {}; store.onStop = {}; store.onSkipStep = {}; store.onFallback = {}
            let card = TourCardWindow(store: store)
            card.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            defer { card.orderOut(nil); card.contentView = nil; backdrop.orderOut(nil) }

            for shot in shots() {
                let beakSide: TourCardSide = shot.cardOnLeft ? .right : .left
                store.beakSide = beakSide
                store.model = shot.model
                store.gestureKind = shot.gesture
                store.contentKey += 1
                store.beakOffset = 60
                spin(0.15)
                let size = card.contentFittingSize
                XCTAssertGreaterThan(size.height, 100)

                // Panel in screen space.
                let panelScreen = view.panelRect.offsetBy(dx: backdrop.frame.minX, dy: backdrop.frame.minY)
                let anchorY = shot.anchorIsPlay ? panelScreen.minY + 31 : panelScreen.midY
                let x = shot.cardOnLeft ? panelScreen.minX - gap - size.width : panelScreen.maxX + gap
                let y = anchorY - size.height / 2
                store.beakOffset = size.height / 2
                card.place(NSRect(x: x, y: y, width: size.width, height: size.height), animated: false)
                card.orderFrontRegardless()
                spin(0.45)

                let rect = TourWindowCapture.cgRect(backdrop.frame)
                let image = try XCTUnwrap(TourWindowCapture.composite(through: card, in: rect))
                TourWindowCapture.writePNG(image, to: "\(outDir)/\(shot.name)-\(dark ? "dark" : "light").png")
                // A tight crop of just the card, for reading the type.
                if let crop = TourWindowCapture.image(of: card) {
                    TourWindowCapture.writePNG(crop, to: "\(outDir)/\(shot.name)-\(dark ? "dark" : "light")-cardonly.png")
                }
            }
        }
    }
}
