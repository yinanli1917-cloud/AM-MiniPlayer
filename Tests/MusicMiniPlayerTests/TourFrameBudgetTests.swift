/**
 * [INPUT]: TourRealPanelFixture (real panel, real tour windows), TourFrameMeter.
 * [OUTPUT]: TourFrameBudgetTests — frame times of the check -> handoff -> transition sequence on the
 *           real windows (the move step's corner beat, then the tuck that hands off to the "back" card).
 * [POS]: Tests. Founder 2026-09-29: "the step-complete checkmark is very laggy, the transitions are not
 *        smooth at all". Numbers first: max / p95 / count over 16.7 ms of the main thread's run-loop turns,
 *        the tour's own tick intervals and apply() times, and how often each window redraws.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourFrameBudgetTests: XCTestCase {
    private var f: TourRealPanelFixture!
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    private let allButMoveAndBack: Set<TourStep> = Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])

    /// One measured run of: card resting (gesture glow running) -> corner beat check -> tuck (ring grows, check,
    /// handoff) -> the "back" card arrives.
    private func runSequence(_ title: String) -> TourFrameMeter {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        f.wait { f.cardWindow != nil }
        f.spin(2.0)                                                  // the appear spring is done; the glow runs on
        let meter = TourFrameMeter()
        meter.start()
        f.spin(1.0)                                                  // resting (glow ticking)
        f.controller.send(.panelSettled(corner: .bottomLeft))                // beat 1 checks
        f.spin(1.6)
        f.controller.send(.panelTucked)                              // ring grows, check draws, handoff, next card
        f.spin(3.2)
        meter.stop()
        print(meter.report(title))
        return meter
    }

    func test_measure_checkHandoffTransition() throws {
        let meter = runSequence("check -> handoff -> transition (move step -> back step)")
        // Recorded, not yet asserted: this is the "before" measurement. The budget test below asserts after the fix.
        XCTAssertGreaterThan(meter.busy.count, 10)
    }

    /// A real-paced two-finger drag (120 events/s, the trackpad's rate) with and without the tour: what does each
    /// event cost the main thread, and how many times do the tour's windows redraw?
    private func gestureCost(withTour: Bool) -> TourFrameMeter {
        f = TourRealPanelFixture(page: .album)
        if withTour {
            f.controller.send(.resume(completed: allButMoveAndBack))
            f.wait { f.cardWindow != nil }
            f.spin(2.0)
        }
        let meter = TourFrameMeter()
        meter.start()
        if let e = f.gestureEvent(dx: 0, dy: 0, phase: .began) { f.panel.sendEvent(e) }
        let t0 = CACurrentMediaTime()
        var lag: [Double] = []
        for i in 0..<90 {                                           // 0.75 s of fingers
            let due = t0 + Double(i) * (1.0 / 120.0)
            while CACurrentMediaTime() < due { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
            lag.append(CACurrentMediaTime() - due)
            if let e = f.gestureEvent(dx: -6, dy: 4, phase: .changed) { f.panel.sendEvent(e) }
        }
        if let e = f.gestureEvent(dx: 0, dy: 0, phase: .ended) { f.panel.sendEvent(e) }
        f.spin(1.0)
        meter.stop()
        print(meter.report(withTour ? "two-finger drag, move step running" : "two-finger drag, no tour"))
        let worstLag = lag.max() ?? 0
        print(String(format: "[frames]   event delivery lag behind the 120 Hz schedule: max %.1f ms", worstLag * 1000))
        return meter
    }

    func test_measure_twoFingerDrag_withAndWithoutTour() throws {
        _ = gestureCost(withTour: false)
        f.tearDown(); f = nil
        _ = gestureCost(withTour: true)
    }
}
