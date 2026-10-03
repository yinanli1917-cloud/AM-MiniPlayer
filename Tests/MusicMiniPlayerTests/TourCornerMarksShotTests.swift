/**
 * [INPUT]: TourRealPanelFixture (real panel + real tour windows), TourShotStudio (own-window capture, full-screen backdrop).
 * [OUTPUT]: TourCornerMarksShotTests — opt-in (TOUR_CORNERS4_SHOTS=1) stills of the move step's corner beats with the four
 *           snap-target marks: before any landing, the instant after the first landing (that mark pulsing and ticked),
 *           and at rest on the second corner beat, light and dark.
 * [POS]: Tests. Real windows, real glass, WindowServer pixels of this process only.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourCornerMarksShotTests: XCTestCase {
    private func run(dark: Bool) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_CORNERS4_SHOTS"] == "1", "opt-in: puts a full-screen backdrop on the screen for a few seconds")
        let studio = TourShotStudio(dark: dark, fullScreen: true)
        studio.outDir = ProcessInfo.processInfo.environment["TOUR_CORNERS4_SHOTS_DIR"]
            ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-corners4-shots"
        defer { studio.finish() }
        let f = TourRealPanelFixture(dark: dark, page: .album)
        studio.settleBackdrop(f)
        defer { f.tearDown() }
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        let screen = studio.backdrop.frame
        // The swell is soft and the marks are low in contrast: shoot once they are fully in, at rest.
        f.spin(4.2)
        studio.shoot("1-corner-beat-fourMarks", fixture: f, extraRect: screen)

        // The panel lands in the bottom left: that mark pulses and ticks; the beat checks.
        let landing = try XCTUnwrap(f.panel.cornerLandingFrames()[.bottomLeft])
        f.panel.setFrameOrigin(landing.origin)
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.14)
        studio.shoot("2-first-landing-pulse", fixture: f, extraRect: screen)
        f.spin(2.4)
        studio.shoot("3-first-landing-rest-anotherCornerBeat", fixture: f, extraRect: screen)
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, false, false]))
    }

    /// One still per start corner (light): the demo's dots mid-slide with their trails, and the emphasised mark, agreeing.
    func test_directionStills_perStartCorner_light() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_CORNERS4_SHOTS"] == "1", "opt-in")
        let studio = TourShotStudio(dark: false, fullScreen: true)
        studio.outDir = ProcessInfo.processInfo.environment["TOUR_CORNERS4_SHOTS_DIR"]
            ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-corners4-shots"
        defer { studio.finish() }
        for start in ScreenCorner.allCases {
            let f = TourRealPanelFixture(corner: start, dark: false, page: .album)
            studio.settleBackdrop(f)
            f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])))
            XCTAssertTrue(f.wait { f.cardWindow != nil })
            f.spin(3.0)
            let end = Date().addingTimeInterval(8)
            while Date() < end, (f.controller.guidance.lastFrame.glyphElapsed ?? 0) < 1.30 { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) }
            studio.shoot("4-direction-start-\(start)", fixture: f, extraRect: studio.backdrop.frame)
            f.tearDown()
        }
    }

    func test_cornerBeatsWithFourMarks_light() throws { try run(dark: false) }
    func test_cornerBeatsWithFourMarks_dark() throws { try run(dark: true) }
}
