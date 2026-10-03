/**
 * [INPUT]: TourRealPanelFixture (real panel + real tour windows), TourShotStudio (own-window capture over an opaque backdrop).
 * [OUTPUT]: TourPanelGhostShotTests — opt-in (TOUR_GHOST_SHOTS=1) stills of the move step's on-screen ghost, mid-glide: the first
 *           corner beat, the diagonal beat, and the edge beat (the ghost shrinking into the sliver), light and dark.
 * [POS]: Tests. Real windows, real glass, WindowServer pixels of this process only.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourPanelGhostShotTests: XCTestCase {
    private func spinToGlyph(_ f: TourRealPanelFixture, _ seconds: Double) {
        let end = Date().addingTimeInterval(10)
        while Date() < end, (f.controller.guidance.lastFrame.glyphElapsed ?? 0) < seconds { RunLoop.main.run(until: Date().addingTimeInterval(0.003)) }
    }

    private func run(dark: Bool) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_GHOST_SHOTS"] == "1", "opt-in: puts a full-screen backdrop on the screen for a few seconds")
        let studio = TourShotStudio(dark: dark, fullScreen: true)
        studio.outDir = ProcessInfo.processInfo.environment["TOUR_GHOST_SHOTS_DIR"]
            ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-ghost-shots"
        defer { studio.finish() }
        let f = TourRealPanelFixture(dark: dark, page: .album)
        studio.settleBackdrop(f)
        defer { f.tearDown() }
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        let screen = studio.backdrop.frame

        // Beat 1: the ghost mid-glide from the panel (top right) toward the emphasised corner.
        spinToGlyph(f, 0.95)
        XCTAssertTrue(f.controller.debugGhost.isDrawn)
        studio.shoot("1-corner-beat-ghost-midGlide", fixture: f, extraRect: screen)

        // The panel lands in the bottom left; the diagonal beat replays toward the opposite corner.
        let landing = try XCTUnwrap(f.panel.cornerLandingFrames()[.bottomLeft])
        f.panel.setFrameOrigin(landing.origin)
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.35)
        XCTAssertLessThan(f.controller.guidance.lastFrame.glyphElapsed ?? 0, 0.9, "the demo replayed from the top for the new beat")
        spinToGlyph(f, 0.95)
        XCTAssertTrue(f.controller.debugGhost.isDrawn)
        studio.shoot("2-diagonal-beat-ghost-midGlide", fixture: f, extraRect: screen)

        // Landing in the opposite corner: the edge beat, the ghost slides into the nearest edge and shrinks to the sliver.
        let top = try XCTUnwrap(f.panel.cornerLandingFrames()[.topRight])
        f.panel.setFrameOrigin(top.origin)
        f.controller.send(.panelSettled(corner: .topRight))
        f.spin(0.35)
        XCTAssertLessThan(f.controller.guidance.lastFrame.glyphElapsed ?? 0, 0.9)
        spinToGlyph(f, 1.02)
        XCTAssertTrue(f.controller.debugGhost.isDrawn)
        studio.shoot("3-edge-beat-ghost-shrinking", fixture: f, extraRect: screen)
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, true, false]))
    }

    func test_ghostMidGlide_light() throws { try run(dark: false) }
    func test_ghostMidGlide_dark() throws { try run(dark: true) }
}
