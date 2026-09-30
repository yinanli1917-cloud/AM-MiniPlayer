/**
 * [INPUT]: TourRealPanelFixture (real panel + real tour windows), TourShotStudio (own-window capture).
 * [OUTPUT]: TourFix4ShotTests — opt-in (TOUR_FIX4_SHOTS=1) acceptance stills of the founder's 2026-09-29 third walk:
 *           the move step's two beats (no demo on the preface beat, the demo with trails on the nudge beat, mid-slide)
 *           and the finale's seal -> disc -> confetti sequence, light and dark.
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

    /// Polls (fast) until the demo's clock reads at least `elapsed`, then shoots at once.
    private func shootWhenGlyphReaches(_ elapsed: Double, name: String, studio: TourShotStudio, f: TourRealPanelFixture, timeout: Double = 8) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let e = f.controller.guidance.lastFrame.glyphElapsed, e >= elapsed { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        }
        let e = f.controller.guidance.lastFrame.glyphElapsed
        studio.shoot("\(name)-el\(String(format: "%.2f", e ?? -1))", fixture: f)
    }

    /// The move step from the lyrics page: the preface beat (no demo), then back on the cover (the demo grows in, slides, trails).
    private func moveStep(dark: Bool) throws {
        let studio = TourShotStudio(dark: dark)
        defer { studio.finish() }
        let f = TourRealPanelFixture(dark: dark, page: .lyrics)
        studio.settleBackdrop(f)
        defer { f.tearDown() }
        f.showControls(on: .lyrics)
        studio.settleBackdrop(f)
        f.controller.send(.resume(completed: all.subtracting([.moveTuck, .back])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(2.4)
        studio.shoot("1-move-preface-backToCover", fixture: f)

        f.music.currentPage = .album
        f.spin(0.10)
        studio.shoot("2-move-nudge-band-growing", fixture: f)
        f.spin(0.9)
        shootWhenGlyphReaches(0.55, name: "3-move-nudge-dotsIn", studio: studio, f: f)
        shootWhenGlyphReaches(1.02, name: "4-move-nudge-slideStart", studio: studio, f: f)
        shootWhenGlyphReaches(1.27, name: "5-move-nudge-midSlide-trails", studio: studio, f: f)
        shootWhenGlyphReaches(1.48, name: "6-move-nudge-slideEnd", studio: studio, f: f)
        f.spin(6.0)
        studio.shoot("7-move-nudge-atRest", fixture: f)
    }

    func test_moveStepFrames_lightAndDark() throws {
        try enabled()
        try moveStep(dark: false)
        try moveStep(dark: true)
    }

    /// The finale, played for real: tuck, peek, click. Frames from the moment the panel is back.
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
        XCTAssertTrue(f.wait(6) { f.controller.state.phase == .finale })
        let t0 = Date()
        var n = 0
        var log: [String] = []
        for at in [0.25, 0.55, 0.85, 1.05, 1.25, 1.45, 1.75, 2.1] {
            while Date().timeIntervalSince(t0) < at { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) }
            let t = Date().timeIntervalSince(t0)
            let fb = f.controller.debugFeedback
            log.append(String(format: "t=%.2f particles=%d halos=%d fxWindow=%@ fxRenders=%d", t, fb.fx.particles.count, fb.fx.halos.count,
                              fb.debugSparkOverlay.window == nil ? "parked" : "open", TourPerfProbe.count(.fxRender)))
            n += 1
            studio.shoot(String(format: "finale-%02d-t%.2f", n, t), fixture: f, includeFX: true)
        }
        print("[shots] finale " + (dark ? "dark" : "light") + " log:\n" + log.joined(separator: "\n"))
    }

    func test_finaleFrames_lightAndDark() throws {
        try enabled()
        try finale(dark: false)
        try finale(dark: true)
    }
}
