/**
 * [INPUT]: TourRealPanelFixture (real panel + real tour windows), TourShotStudio (own-window capture over an opaque backdrop),
 *          TourCompletionFeedback driven by a manual clock (`autoTick: false`).
 * [OUTPUT]: TourCelebrateShotTests — opt-in (TOUR_CELEBRATE_SHOTS=1) stills of the celebration moment (spec §B.10): a step
 *           (blur ramping in, ring at the card's centre filling, the check and the sparks, the unblur revealing the next step)
 *           and the finale (seal, disc, confetti), light and dark.
 * [POS]: Tests. Real windows, real glass, WindowServer pixels of this process only; the clock of the feedback is advanced by
 *        hand so every still is at an exact moment of the sequence, not "about when the capture happened to run".
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourCelebrateShotTests: XCTestCase {
    static let outDir = ProcessInfo.processInfo.environment["TOUR_CELEBRATE_SHOTS_DIR"]
        ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-celebrate-shots"

    private func enabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_CELEBRATE_SHOTS"] == "1", "opt-in: puts windows on the screen for a minute")
    }

    /// One run: `moments` are seconds since the completion began; each still is taken the instant the sequence clock reaches it.
    private func shoot(dark: Bool, final: Bool, moments: [Double], name: String) throws {
        let studio = TourShotStudio(dark: dark)
        studio.outDir = Self.outDir
        defer { studio.finish() }
        let f = TourRealPanelFixture(dark: dark, page: .album)
        studio.settleBackdrop(f)
        defer { f.tearDown() }
        let all = Set(TourStep.orderedSteps)
        // Step: the reveal step (hover + play) -> the next card. Finale: the back step's expand -> the finale card.
        f.controller.send(.resume(completed: final ? all.subtracting([.back]) : [.connect]))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(2.0)
        studio.settleBackdrop(f)
        studio.shoot("\(name)-0-before", fixture: f)

        if final {
            XCTAssertTrue(f.liquidEdge.collapse(to: .right))
            XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .tucked })
            f.spin(1.0)
            f.liquidEdge.hoverEntered()
            XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .floating })
            f.spin(0.8)
            f.liquidEdge.expand()
            XCTAssertTrue(f.wait(6) { f.controller.state.phase == .finale })
        } else {
            f.controller.send(.signal(.controlsRevealed))
            f.controller.send(.signal(.isPlaying))
        }
        let cho = f.controller.debugFeedback.choreographer
        let began = cho.now
        for (i, t) in moments.enumerated() {
            let deadline = Date().addingTimeInterval(4)
            while cho.now - began < t, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.003)) }
            let seen = cho.now - began
            studio.shoot(String(format: "\(name)-%d-t%04d", i + 1, Int(t * 1000)), fixture: f, includeFX: true)
            print(String(format: "[celebrate] \(name) still %d wanted t=%.2f at t=%.3f blur=%.2f lift=%.2f", i + 1, t, seen,
                          f.controller.debugFeedback.frame.blur, f.controller.debugFeedback.frame.lift))
        }
    }

    func test_step_light() throws { try enabled(); try shoot(dark: false, final: false, moments: [0.10, 0.30, 0.62, 0.98, 1.20], name: "step") }
    func test_step_dark() throws { try enabled(); try shoot(dark: true, final: false, moments: [0.10, 0.30, 0.62, 0.98, 1.20], name: "step") }
    func test_finale_light() throws { try enabled(); try shoot(dark: false, final: true, moments: [0.14, 0.50, 0.90, 1.30, 1.80], name: "finale") }
    func test_finale_dark() throws { try enabled(); try shoot(dark: true, final: true, moments: [0.14, 0.50, 0.90, 1.30, 1.80], name: "finale") }
}
