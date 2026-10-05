/**
 * [INPUT]: MusicMiniPlayerAppKit's TourCardWindow/TourCardStore/TourCardMaterialArm, TourSceneFixtures, TourWindowCapture.
 * [OUTPUT]: TourCardGlassShotTests — opt-in (NANOPOD_TOUR_GLASS_SHOT_DIR=<dir>) composited stills of the REAL card window over
 *           two backdrops (warm sunset, flat purple) x light/dark x arm glass (the old look) / liquid (the new one);
 *           TourCardMaterialArmTests — the arm default, A/B keys and the finish numbers' shape.
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
    private final class BackdropView: NSView {
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

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func onlyOurWindowsAbove(_ backdrop: NSWindow) -> Bool {
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

    func test_compositedStills_oldGlassVsLiquid() throws {
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
        let store = TourCardStore(model: TourSceneFixtures.welcome(.en), feedback: fb, arm: .glass)
        store.onPrimary = {}; store.onSecondary = {}; store.onStop = {}; store.onSkipStep = {}; store.onFallback = {}
        store.beakSide = .right
        let card = TourCardWindow(store: store)
        defer { card.orderOut(nil); card.contentView = nil; backdrop.orderOut(nil); backdrop.contentView = nil }

        var written = 0
        let cards: [(String, TourCardModel)] = [("", TourSceneFixtures.welcome(.en)), ("_finale", TourSceneFixtures.finale(.en))]
        for kind in Backdrop.allCases {
            view.kind = kind
            view.needsDisplay = true
            backdrop.orderFrontRegardless()
            for dark in [false, true] {
                card.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for arm in [TourCardMaterialArm.glass, .liquid] {
                    for (suffix, model) in cards {
                        store.arm = arm
                        card.hasShadow = arm.needsWindowShadow
                        store.model = model
                        store.contentKey += 1
                        spin(0.2)
                        let fit = card.contentFittingSize
                        XCTAssertGreaterThan(fit.height, 100)
                        store.beakOffset = fit.height / 2
                        card.place(NSRect(x: frame.midX - fit.width / 2, y: frame.midY - fit.height / 2, width: fit.width, height: fit.height), animated: false)
                        card.orderFrontRegardless()
                        spin(0.6)
                        guard onlyOurWindowsAbove(backdrop) else { print("[glass-shots] SKIPPED \(kind) \(dark) \(arm): another app's window is above the backdrop"); continue }
                        let image = try XCTUnwrap(TourWindowCapture.composite(through: card, in: TourWindowCapture.cgRect(frame)))
                        TourWindowCapture.writePNG(image, to: "\(dir)/\(kind.rawValue)_\(dark ? "dark" : "light")_\(arm.rawValue)\(suffix).png")
                        written += 1
                    }
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

    func test_liquidDrawsItsOwnShadowAndUsesGlassButtons_onlyLiquidDoes() {
        XCTAssertFalse(TourCardMaterialArm.liquid.needsWindowShadow)
        XCTAssertTrue(TourCardMaterialArm.liquid.usesGlassButtons)
        for arm in [TourCardMaterialArm.glass, .clear, .vibrancy, .simulated] { XCTAssertFalse(arm.usesGlassButtons) }
        XCTAssertTrue(TourCardMaterialArm.vibrancy.needsWindowShadow)
    }

    func test_finish_rimIsBrightestAtTheTopAndFadesDown_sheenFadesOutByFortyPercent() {
        for dark in [false, true] {
            let f = TourGlassFinish.resolve(dark: dark)
            XCTAssertGreaterThan(f.rimTop, f.rimUpper)
            XCTAssertGreaterThan(f.rimUpper, f.rimLower)
            XCTAssertGreaterThanOrEqual(f.rimLower, f.rimBottom)
            XCTAssertGreaterThan(f.rimBottom, 0, "the rim never vanishes")
            XCTAssertGreaterThan(f.sheenOpacity, 0)
            XCTAssertLessThanOrEqual(f.sheenReach, 0.40)
        }
        XCTAssertGreaterThan(TourGlassFinish.light.rimTop, TourGlassFinish.dark.rimTop)
    }
}
