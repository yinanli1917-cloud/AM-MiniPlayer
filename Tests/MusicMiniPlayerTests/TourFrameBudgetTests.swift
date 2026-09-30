/**
 * [INPUT]: TourRealPanelFixture (real panel, real tour windows), TourFrameMeter.
 * [OUTPUT]: TourFrameBudgetTests — frame times of the check -> handoff -> transition sequence and of a two-finger drag on
 *           the real windows, and the guards that came out of measuring them.
 * [POS]: Tests. Founder 2026-09-29 (third walk): "the step-complete checkmark is very laggy, the transitions are not
 *        smooth at all". Numbers first: max / p95 / count over 16.7 ms of the main thread's run-loop turns, the tour's own
 *        tick intervals and apply() times, and how often each window redraws. Findings, in order of size:
 *        1. `controller.send()` asked the system for the Automation permission (a 30-45 ms synchronous TCC query) on every
 *           event, so every completion stalled the main thread on the frame its check began (guarded below);
 *        2. a `Canvas` inside the card's glass redrew through a synchronous WindowServer round trip on every card update,
 *           stalling a two-finger drag by ~100 ms (the demo is plain shapes now; guarded below);
 *        3. a full-screen ring overlay, two display links, a hosting view built per measure.
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
    /// Milliseconds the main thread spent inside `controller.send(...)` for the two completions of `runSequence`.
    private var sendCosts: [Double] = []

    private var runs: Int { Int(ProcessInfo.processInfo.environment["TOUR_MEASURE_RUNS"] ?? "1") ?? 1 }

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
        var t = CACurrentMediaTime()
        f.controller.send(.panelSettled(corner: .bottomLeft))        // beat 1 checks
        sendCosts.append((CACurrentMediaTime() - t) * 1000)
        f.spin(1.6)
        t = CACurrentMediaTime()
        f.controller.send(.panelTucked)                              // ring grows, check draws, handoff, next card
        sendCosts.append((CACurrentMediaTime() - t) * 1000)
        f.spin(3.2)
        meter.stop()
        print(meter.report(title))
        print(String(format: "[frames]   controller.send() for the two completions: %.1f ms, %.1f ms", sendCosts[sendCosts.count - 2], sendCosts[sendCosts.count - 1]))
        return meter
    }

    func test_measure_checkHandoffTransition() throws {
        for i in 0..<runs {
            let meter = runSequence("check -> handoff -> transition (move step -> back step) run \(i + 1)/\(runs)")
            XCTAssertGreaterThan(meter.busy.count, 10)
            f.tearDown(); f = nil
        }
        for cost in sendCosts {
            XCTAssertLessThan(cost, 20, "a completion's synchronous work stays well inside a frame budget (it was 32-49 ms)")
        }
    }

    /// `send()` read the system's Automation permission (`AEDeterminePermissionToAutomateTarget`, a 30-45 ms synchronous
    /// query to the TCC daemon) on EVERY event — the very frame each check began. Only `.start` needs it.
    func test_aCompletion_doesNotAskTheSystemForAutomationPermission() throws {
        f = TourRealPanelFixture(page: .album)
        var queries = 0
        f.controller.automationStatusProvider = { queries += 1; return .notDetermined }
        f.controller.send(.resume(completed: allButMoveAndBack))
        f.wait { f.cardWindow != nil }
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.3)
        f.controller.send(.panelTucked)
        f.spin(0.3)
        XCTAssertEqual(queries, 0, "a completion (and a resume, and the handoff after it) must not pay for a system permission query")
        f.controller.send(.start)
        XCTAssertEqual(queries, 1, "the start of the tour is the one event that does need it")
    }

    /// A card resting on the move step has two things ticking: the panel-edge glow (the overlay's) and the demo's clock (the
    /// demo's). Neither may re-evaluate the card around them: it used to be rebuilt (title, body, beats, buttons, glass) on
    /// every one of those frames.
    func test_restingMoveStep_glowAndDemoFrames_doNotReEvaluateTheCard() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        f.wait { f.cardWindow != nil }
        f.spin(1.8)                                                  // appeared; the glow and the demo are playing
        XCTAssertNotNil(f.controller.guidance.lastFrame.glyphElapsed, "fixture sanity: the demo's clock is running")
        let meter = TourFrameMeter()
        meter.start()
        f.spin(1.0)
        meter.stop()
        #if DEBUG
        XCTAssertLessThan(TourPerfProbe.count(.cardBody), 6, "the card was re-evaluated \(TourPerfProbe.count(.cardBody)) times by a second of glow and demo frames")
        XCTAssertGreaterThan(TourPerfProbe.count(.overlayRender), 20, "fixture sanity: the glow really is drawing frames")
        #endif
    }

    /// The ring overlay used to be a 2560x1440 transparent window (a 59 MB backing store) re-rendered every frame. It covers
    /// what it draws now, and is not on screen at all when it draws nothing.
    func test_theRingOverlay_coversWhatItDraws_notTheScreen_andIsParkedWhenItDrawsNothing() throws {
        f = TourRealPanelFixture(page: .album)
        #if DEBUG
        TourPerfProbe.resetMarks()
        #endif
        f.controller.send(.resume(completed: allButMoveAndBack))
        f.wait { f.cardWindow != nil }
        f.spin(1.2)                                                  // the panel-edge glow is breathing
        let overlay = try XCTUnwrap(f.controller.debugOverlayWindow)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertTrue(overlay.ignoresMouseEvents, "and it stays click-through")
        let screen = try XCTUnwrap(NSScreen.main).frame
        XCTAssertLessThan(overlay.frame.width * overlay.frame.height / (screen.width * screen.height), 0.15, "\(overlay.frame) on \(screen)")
        XCTAssertTrue(overlay.frame.contains(f.panel.frame), "the glow around the panel is inside it")
        let resizes = f.controller.guidance.overlayResizeCount
        f.spin(1.0)
        XCTAssertEqual(f.controller.guidance.overlayResizeCount, resizes, "a breathing glow does not resize the window frame by frame")
        f.spin(2.5)                                                  // through a breath boundary, where the glow touches zero
        #if DEBUG
        let ins = TourPerfProbe.marks.filter { $0.name == "overlay orderFront" }.count
        let outs = TourPerfProbe.marks.filter { $0.name == "overlay orderOut" }.count
        XCTAssertEqual(ins, 1, "the window came on screen once, not once per breath")
        XCTAssertEqual(outs, 0, "and was not ordered out between breaths")
        #endif
        f.spin(6.0)                                                  // three breaths, then it is done
        XCTAssertFalse(overlay.isVisible, "nothing to draw: the window is not on screen")
    }

    /// A real-paced two-finger drag (120 events/s, the trackpad's rate) with and without the tour: what does each
    /// event cost the main thread, and how many times do the tour's windows redraw?
    private func gestureCost(withTour: Bool) -> (meter: TourFrameMeter, worstLag: Double) {
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
        let worstLag = (lag.max() ?? 0) * 1000
        print(String(format: "[frames]   event delivery lag behind the 120 Hz schedule: max %.1f ms", worstLag))
        return (meter, worstLag)
    }

    func test_measure_twoFingerDrag_withAndWithoutTour() throws {
        var lags: [Double] = []
        for _ in 0..<runs {
            _ = gestureCost(withTour: false)
            f.tearDown(); f = nil
            lags.append(gestureCost(withTour: true).worstLag)
            f.tearDown(); f = nil
        }
        for lag in lags {
            XCTAssertLessThan(lag, 70, "the drag is not held up by the tour's windows (a Canvas in the card's glass held it up ~100 ms)")
        }
    }
}
