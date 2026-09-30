/**
 * [INPUT]: TourRealPanelFixture (real panel + real tour windows), TourShotStudio (own-window capture).
 * [OUTPUT]: TourFix4ShotTests — opt-in (TOUR_FIX4_SHOTS=1) acceptance stills of the founder's 2026-09-29
 *           third walk: the move step's two beats (no glyph on the preface beat, glyph with trails on the
 *           nudge beat) and the finale's seal -> disc -> confetti sequence, light and dark.
 * [POS]: Tests. Real windows, real glass, WindowServer pixels of this process only.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourFix4ShotTests: XCTestCase {
    private let all = Set(TourStep.orderedSteps)

    private func enabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_FIX4_SHOTS"] == "1", "opt-in: puts windows on the screen for a minute")
    }

    /// The finale, played for real: tuck, peek, click. Frames every 90 ms from the click.
    private func finale(dark: Bool) throws {
        let studio = TourShotStudio(dark: dark)
        defer { studio.finish() }
        let f = TourRealPanelFixture(dark: dark, page: .album)
        studio.settleBackdrop(f)
        defer { f.tearDown() }
        f.controller.send(.resume(completed: all.subtracting([.back])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        XCTAssertTrue(f.liquidEdge.collapse(to: .right))
        XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .tucked })
        f.spin(1.2)
        f.liquidEdge.hoverEntered()
        XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .floating })
        f.spin(1.0)
        f.liquidEdge.expand()
        let t0 = Date()
        var n = 0
        var log: [String] = []
        while Date().timeIntervalSince(t0) < 3.2 {
            f.spin(0.09)
            let t = Date().timeIntervalSince(t0)
            let fx = f.controller.debugFeedback.debugSparkOverlay.window
            var ink = -1
            if let fx, fx.isVisible, let img = TourWindowCapture.image(of: fx) {
                let rep = NSBitmapImageRep(cgImage: img)
                ink = 0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { ink += 1 }
                } }
            }
            log.append(String(format: "t=%.2f inkPx=%d fxRenders=%d fx=%@ frame=%@ particles=%d phase=%@", t, ink, TourPerfProbe.count(.fxRender),
                              fx?.isVisible == true ? "shown" : (fx == nil ? "nil" : "hidden"),
                              fx.map { "\($0.frame)" } ?? "-", f.controller.debugFeedback.fx.particles.count,
                              "\(f.controller.state.phase)"))
            if t > 0.4 {
                n += 1
                studio.shoot(String(format: "finale-%02d-t%.2f", n, t), fixture: f, includeFX: true)
            }
        }
        print("[shots] finale log:\n" + log.joined(separator: "\n"))
    }

    func test_finaleFrames_lightAndDark() throws {
        try enabled()
        try finale(dark: false)
        try finale(dark: true)
    }
}
