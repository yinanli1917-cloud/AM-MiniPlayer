/**
 * [INPUT]: MusicMiniPlayerAppKit's TourCardWindow/TourCardStore/TourCardMaterialArm, TourSceneFixtures, TourWindowCapture.
 * [OUTPUT]: TourCardGlassShotTests — opt-in (NANOPOD_TOUR_GLASS_SHOT_DIR=<dir>) composited stills of the REAL card window over
 *           two backdrops (warm sunset, flat purple) x light/dark x the old `glass` arm / the native default / native with a
 *           window shadow / a key-window reference (test-only; the app's card is never key);
 *           TourCardMaterialArmTests — the arm default and A/B keys.
 * [POS]: Tests. ImageRenderer cannot draw Liquid Glass, so the look is judged from WindowServer's own composite of this
 *        process's windows. Only our windows are captured: if another app's window sits above the backdrop the shot is skipped.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourCardGlassShotTests: XCTestCase {
    enum Backdrop: String, CaseIterable { case sunset, purple }

    /// `sunset`: peach at the top to dusky purple at the bottom (the reference's wallpaper).
    /// `purple`: the founder's flat purple desktop with fine deterministic grain.
    final class BackdropView: NSView {
        var kind = Backdrop.sunset
        override func draw(_ dirtyRect: NSRect) {
            switch kind {
            case .sunset:
                // y-up: `bounds.maxY` is the top.
                NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.15, blue: 0.27, alpha: 1),
                                    NSColor(srgbRed: 0.55, green: 0.38, blue: 0.52, alpha: 1),
                                    NSColor(srgbRed: 0.96, green: 0.72, blue: 0.58, alpha: 1),
                                    NSColor(srgbRed: 0.98, green: 0.80, blue: 0.55, alpha: 1)],
                           atLocations: [0, 0.38, 0.78, 1], colorSpace: .sRGB)?.draw(in: bounds, angle: 90)
            case .purple:
                NSColor(srgbRed: 0.58, green: 0.38, blue: 0.70, alpha: 1).setFill()
                bounds.fill()
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
                for _ in 0..<26000 {
                    let c = next()
                    (c > 0.5 ? NSColor.white : NSColor.black).withAlphaComponent(0.05 + 0.10 * next()).setFill()
                    NSRect(x: next() * bounds.width, y: next() * bounds.height, width: 1.2, height: 1.2).fill()
                }
            }
        }
    }

    func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func onlyOurWindowsAbove(_ backdrop: NSWindow) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        guard let backIndex = list.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == backdrop.windowNumber }) else { return false }
        let rect = TourWindowCapture.cgRect(backdrop.frame)
        for entry in list[..<backIndex] {
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int, owner != pid else { continue }
            guard (entry[kCGWindowLayer as String] as? Int ?? 0) < 20 else { continue }
            guard let b = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            if CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).intersects(rect) { return false }
        }
        return true
    }

    private enum Shot: String, CaseIterable {
        /// The previous `glass` arm: custom buttons, fixed palette, dark hairline.
        case oldGlass = "glass-old"
        /// The shipping default: native glass, system text and button styles, window not key.
        case native
        /// Investigation: native + the window's own shadow (the glass cannot draw one outside a window that is exactly its size).
        case nativeShadow = "native-shadow"
        // No key-window reference: making a window key activates the test process and takes the founder's keyboard focus
        // (2026-10-05). The 04c98e2f investigation shots are the record of that look.

        var arm: TourCardMaterialArm { self == .oldGlass ? .glass : .liquid }
    }

    func test_compositedStills_oldGlassVsNative() throws {
        guard let dir = ProcessInfo.processInfo.environment["NANOPOD_TOUR_GLASS_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("opt-in: puts two windows on the screen for a few seconds (NANOPOD_TOUR_GLASS_SHOT_DIR=<dir>)")
        }
        let visible = NSScreen.main!.visibleFrame
        let size = CGSize(width: 520, height: 420)
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.hasShadow = false
        backdrop.level = .tourOverlay
        backdrop.isOpaque = true
        backdrop.ignoresMouseEvents = true
        let view = BackdropView(frame: NSRect(origin: .zero, size: size))
        backdrop.contentView = view

        let fb = TourCompletionFeedback(autoTick: false)
        func makeStore() -> TourCardStore {
            let store = TourCardStore(model: TourSceneFixtures.welcome(.en), feedback: fb, arm: .glass)
            store.onPrimary = {}; store.onSecondary = {}; store.onStop = {}; store.onSkipStep = {}; store.onFallback = {}
            store.beakSide = .right
            return store
        }
        let store = makeStore()
        let card = TourCardWindow(store: store)
        defer {
            card.orderOut(nil); card.contentView = nil
            backdrop.orderOut(nil); backdrop.contentView = nil
        }

        var written = 0
        let cards: [(String, TourCardModel)] = [("", TourSceneFixtures.welcome(.en)), ("_finale", TourSceneFixtures.finale(.en))]
        for kind in Backdrop.allCases {
            view.kind = kind
            view.needsDisplay = true
            backdrop.orderFrontRegardless()
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for shot in Shot.allCases {
                    let (s, window): (TourCardStore, NSWindow) = (store, card)
                    window.appearance = appearance
                    for (suffix, model) in cards {
                        s.arm = shot.arm
                        window.hasShadow = shot == .nativeShadow || shot.arm.needsWindowShadow
                        s.model = model
                        s.contentKey += 1
                        spin(0.2)
                        let fit = window.contentView?.fittingSize ?? .zero
                        XCTAssertGreaterThan(fit.height, 100)
                        s.beakOffset = fit.height / 2
                        window.setFrame(NSRect(x: frame.midX - fit.width / 2, y: frame.midY - fit.height / 2, width: fit.width, height: fit.height), display: true)
                        window.orderFrontRegardless()
                        spin(0.6)
                        guard onlyOurWindowsAbove(backdrop) else { print("[glass-shots] SKIPPED \(kind) \(dark) \(shot): another app's window is above the backdrop"); continue }
                        let image = try XCTUnwrap(TourWindowCapture.composite(through: window, in: TourWindowCapture.cgRect(frame)))
                        TourWindowCapture.writePNG(image, to: "\(dir)/\(kind.rawValue)_\(dark ? "dark" : "light")_\(shot.rawValue)\(suffix).png")
                        written += 1
                    }
                    window.orderOut(nil)
                }
            }
        }
        print("[glass-shots] wrote \(written) PNGs to \(dir)")
    }
}

/// The arm choice and the finish numbers' shape — no windows, an injected defaults suite.
final class TourCardMaterialArmTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "TourCardMaterialArmTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func test_absentDefaultsKeyIsLiquid_andGlassStaysReachable() {
        let d = suite()
        XCTAssertEqual(TourCardMaterialArm.current(d), .liquid)
        d.set("glass", forKey: TourCardMaterialArm.defaultsKey)
        XCTAssertEqual(TourCardMaterialArm.current(d), .glass)
        d.set("vibrancy", forKey: TourCardMaterialArm.defaultsKey)
        XCTAssertEqual(TourCardMaterialArm.current(d), .vibrancy)
        d.set("nonsense", forKey: TourCardMaterialArm.defaultsKey)
        XCTAssertEqual(TourCardMaterialArm.current(d), .liquid)
        d.set("simulated", forKey: TourCardMaterialArm.defaultsKey)
        XCTAssertEqual(TourCardMaterialArm.current(d), .liquid, "simulated never comes from defaults")
    }

    func test_liquidDrawsItsOwnShadowAndUsesSystemControls_onlyLiquidDoes() {
        XCTAssertFalse(TourCardMaterialArm.liquid.needsWindowShadow)
        XCTAssertTrue(TourCardMaterialArm.liquid.usesSystemControls)
        for arm in [TourCardMaterialArm.glass, .clear, .vibrancy, .simulated] { XCTAssertFalse(arm.usesSystemControls) }
        XCTAssertTrue(TourCardMaterialArm.vibrancy.needsWindowShadow)
    }
}

/// The native arm's system buttons must work in the card's window: it is never key, and a system button in a window that
/// is not key has to fire on the FIRST click (no "click to focus" swallowing it) without the window becoming key.
@MainActor
final class TourCardSystemControlsClickTests: XCTestCase {
    /// A control's mouseDown runs a tracking loop that waits for the mouseUp in the application's queue, so the up event
    /// is queued BEFORE the down is delivered (delivering both through `sendEvent` would block in that loop forever).
    private func click(_ window: NSWindow, at p: CGPoint) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        window.sendEvent(event(.leftMouseUp))   // SwiftUI gestures take the up here; an AppKit button already consumed the queued one
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    /// Welcome card: the text action (bottom left) and the primary button (bottom right). Finale card: the filled
    /// secondary (bottom left). The custom arm is the harness control: if it fires, a silent native button is real.
    func test_footerButtons_fireOnTheFirstClick_inTheNonKeyCardWindow() throws {
        for arm in [TourCardMaterialArm.glass, .liquid] {
            let welcome = try fire(arm, TourSceneFixtures.welcome(.en))
            XCTAssertEqual(welcome.primary, 1, "\(arm): primary button must fire on the first click in a non-key window")
            XCTAssertEqual(welcome.secondary, 1, "\(arm): text action must fire on the first click in a non-key window")
            let finale = try fire(arm, TourSceneFixtures.finale(.en))
            XCTAssertEqual(finale.secondary, 1, "\(arm): filled secondary must fire on the first click in a non-key window")
        }
    }

    private func fire(_ arm: TourCardMaterialArm, _ model: TourCardModel) throws -> (primary: Int, secondary: Int) {
        let store = TourCardStore(model: model, feedback: TourCompletionFeedback(autoTick: false), arm: arm)
        var primary = 0, secondary = 0
        store.onPrimary = { primary += 1 }
        store.onSecondary = { secondary += 1 }
        store.beakSide = .right
        let card = TourCardWindow(store: store)
        defer { card.orderOut(nil); card.contentView = nil }
        let fit = card.contentFittingSize
        card.setFrame(NSRect(x: 200, y: 200, width: fit.width, height: fit.height), display: true)
        card.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(card.isKeyWindow)

        // The footer row sits above the note (window coordinates, y up). Sweep a small grid through each button's
        // area and stop at the first click that fires.
        func sweep(xs: [CGFloat], until fired: () -> Bool) {
            for y in stride(from: CGFloat(44), through: 84, by: 4) {
                for x in xs where !fired() { click(card, at: CGPoint(x: x, y: y)) }
            }
        }
        sweep(xs: [fit.width - 70, fit.width - 55, fit.width - 40]) { primary > 0 }
        sweep(xs: [22, 30, 38]) { secondary > 0 }
        XCTAssertFalse(card.isKeyWindow, "clicking the card must never make it key")
        return (primary, secondary)
    }
}
