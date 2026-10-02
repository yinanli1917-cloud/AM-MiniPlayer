/**
 * [INPUT]: TourRealPanelFixture (real panel, real tour windows), TourWindowCapture (WindowServer pixels of the card window),
 *          TourFrameMeter.
 * [OUTPUT]: TourCelebrationRealWindowTests — the celebration moment (spec §B.10) in the shipping window stack: the card becomes
 *           the canvas (ring at its centre, content blurred), the next content swaps in under the blur, a click on the card ends
 *           it early, skips / lone beats stay quiet, Reduce Motion is quiet, and what it costs per frame.
 * [POS]: Tests. Real SwiftUI in a real NSWindow; pixels come from WindowServer (cacheDisplay cannot draw the card's material).
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourCelebrationRealWindowTests: XCTestCase {
    private var f: TourRealPanelFixture!
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    /// The reveal step ("hover the panel, press play") is showing.
    private func makeFixture(feedback: TourCompletionFeedback? = nil) {
        f = TourRealPanelFixture(page: .album, feedback: feedback)
        f.controller.send(.resume(completed: [.connect]))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.6)                                                  // appeared
    }

    /// Completes the reveal step (two beats); the next card (corners) takes over at the handoff.
    private func completeStep() {
        f.controller.send(.signal(.controlsRevealed))
        f.controller.send(.signal(.isPlaying))
    }

    private var feedback: TourCompletionFeedback { f.controller.debugFeedback }
    private var card: TourCardWindow { f.cardWindow! }

    /// Solid accent-pink pixels in a rect of the card window's own pixels (window-local points, top-left origin).
    private func accentCount(in rect: CGRect) -> Int {
        guard let image = TourWindowCapture.image(of: card) else { return -1 }
        let scale = CGFloat(image.width) / card.frame.width
        let px = TourRender.pixels(from: image, scale: scale)
        var n = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let c = px.rgba(x: x, y: y)
                if c.a > 200, c.r > 215, Int(c.r) - Int(c.g) > 110, Int(c.r) - Int(c.b) > 80 { n += 1 }
            }
        }
        return n
    }

    // MARK: - The moment

    func test_stepCompletion_theCardBecomesTheCanvas_nextContentSwapsInUnderTheBlur_thenItAllLetsGo() throws {
        makeFixture()
        let size = card.frame.size
        let bodyW = TourCardMetrics.bodyWidth
        let cornerRing = CGRect(x: bodyW - 14 - 28 - 4, y: 14 - 2, width: 36, height: 36)           // the card's own ring slot
        let centre = CGRect(x: bodyW / 2 - 45, y: size.height / 2 - 45, width: 90, height: 90)
        let before = accentCount(in: cornerRing)
        XCTAssertGreaterThan(before, 20, "fixture sanity: the card's ring is drawn in its corner")

        let t0 = CACurrentMediaTime()
        completeStep()
        var celebratedAt: Double?, swappedAt: Double?, doneAt: Double?
        var peakBlur = 0.0, peakLift = 0.0
        var centreWhileLifted = 0, cornerWhileLifted = Int.max
        let end = t0 + 2.6
        while CACurrentMediaTime() < end {
            f.spin(0.02)
            let now = CACurrentMediaTime() - t0
            let fr = feedback.frame
            if fr.isCelebrating, celebratedAt == nil { celebratedAt = now }
            peakBlur = max(peakBlur, fr.blur); peakLift = max(peakLift, fr.lift)
            if swappedAt == nil, f.controller.debugCardStore?.model.kind == .step(.corners) { swappedAt = now }
            if fr.lift > 0.98, now > 0.3, now < 0.7, centreWhileLifted == 0 {
                centreWhileLifted = accentCount(in: centre); cornerWhileLifted = accentCount(in: cornerRing)
            }
            if celebratedAt != nil, doneAt == nil, !fr.isCelebrating, !feedback.isActive { doneAt = now }
        }
        XCTAssertNotNil(celebratedAt)
        XCTAssertLessThan(celebratedAt ?? 9, 0.15, "the moment starts with the completion")
        XCTAssertEqual(peakBlur, 1, accuracy: 0.001)
        XCTAssertEqual(peakLift, 1, accuracy: 0.1)
        XCTAssertGreaterThan(centreWhileLifted, 150, "the big ring (and its sparks) are at the card's centre: \(centreWhileLifted) accent pixels")
        XCTAssertLessThan(cornerWhileLifted, before / 2, "and the corner slot is empty: \(cornerWhileLifted) vs \(before)")
        let swap = try XCTUnwrap(swappedAt)
        XCTAssertGreaterThan(swap, 0.85, "the next step's card comes in at H + 140 ms = 0.9 s, not under the first half of the moment: \(swap)")
        XCTAssertLessThan(swap, 1.25)
        XCTAssertNotNil(doneAt, "the blur lets go and the ring is home")
        XCTAssertLessThan(doneAt ?? 9, 1.5, "about 1.1 s of motion, done by ~1.2 s")
        f.spin(0.3)
        XCTAssertGreaterThan(accentCount(in: cornerRing), 20, "the card's own ring is back in its corner afterwards")
    }

    /// A click ON THE CARD (the SwiftUI click layer, reached through the real window's event path) ends the moment early.
    func test_aClickOnTheCard_endsTheMomentEarly() throws {
        makeFixture()
        let t0 = CACurrentMediaTime()
        completeStep()
        f.spin(0.25)
        XCTAssertTrue(feedback.frame.isCelebrating)
        let p = NSPoint(x: card.frame.minX + TourCardMetrics.bodyWidth / 2, y: card.frame.midY)
        let local = card.convertPoint(fromScreen: p)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: card.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: card.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        let clickedAt = CACurrentMediaTime() - t0
        card.sendEvent(down); card.sendEvent(up)
        var swappedAt: Double?
        while CACurrentMediaTime() - t0 < 2.4 {
            f.spin(0.02)
            if swappedAt == nil, f.controller.debugCardStore?.model.kind == .step(.corners) { swappedAt = CACurrentMediaTime() - t0 }
        }
        let swap = try XCTUnwrap(swappedAt)
        XCTAssertLessThan(swap, clickedAt + 0.45, "the handoff started at the click (the swap comes 140 ms after it), not at 0.76 s: swap \(swap), click \(clickedAt)")
        XCTAssertFalse(feedback.frame.isCelebrating, "and it all ends cleanly")
    }

    func test_aClick_whenNothingIsCelebrating_doesNothingToTheCard() throws {
        makeFixture()
        XCTAssertFalse(feedback.frame.isCelebrating)
        let local = card.convertPoint(fromScreen: NSPoint(x: card.frame.minX + 40, y: card.frame.midY))
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: card.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        card.sendEvent(down)
        f.spin(0.2)
        XCTAssertFalse(feedback.isActive)
        XCTAssertEqual(f.controller.debugCardStore?.model.kind, .step(.reveal))
    }

    /// A completion with no card handoff (the tuck: the next card is already up) still lets the ring and the blur go on their own.
    func test_aCompletionWithNoHandoff_stillLetsEverythingGo() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.6)
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.4)
        f.controller.send(.panelTucked)
        var celebrated = false
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 2.4 { f.spin(0.03); celebrated = celebrated || feedback.frame.isCelebrating }
        XCTAssertTrue(celebrated)
        XCTAssertFalse(feedback.frame.isCelebrating, "ring home and blur gone: \(feedback.frame.blur) \(feedback.frame.lift)")
        XCTAssertFalse(feedback.isActive)
    }

    // MARK: - Quiet cases

    func test_aLoneBeat_andASkip_stayQuiet() throws {
        makeFixture()
        f.controller.send(.signal(.controlsRevealed))                // a beat only
        var celebrated = false
        for _ in 0..<40 { f.spin(0.03); celebrated = celebrated || feedback.frame.isCelebrating }
        XCTAssertFalse(celebrated, "a beat alone is not a step")
        f.controller.send(.skipStep)                                  // "skip this one"
        for _ in 0..<80 { f.spin(0.03); celebrated = celebrated || feedback.frame.isCelebrating }
        XCTAssertFalse(celebrated, "skipping a step stays quiet")
        XCTAssertFalse(feedback.isActive)
    }

    func test_reduceMotion_cardDimsWithAStaticCheck_noSparks() throws {
        let rm = TourCompletionFeedback(reduceMotion: { true })
        makeFixture(feedback: rm)
        completeStep()
        var quiet = false, sparkWindow = false, peak = 0.0
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 1.4 {
            f.spin(0.02)
            let fr = feedback.frame
            quiet = quiet || (fr.isCelebrating && fr.celebrationQuiet)
            peak = max(peak, fr.blur)
            sparkWindow = sparkWindow || feedback.debugSparkOverlay.window != nil
        }
        XCTAssertTrue(quiet, "the content dims; it does not blur or scale")
        XCTAssertEqual(peak, 1, accuracy: 0.001)
        XCTAssertFalse(sparkWindow, "no sparks under Reduce Motion")
    }

    func test_reduceTransparency_dimsInsteadOfBlurring() throws {
        let rt = TourCompletionFeedback(reduceTransparency: { true })
        makeFixture(feedback: rt)
        completeStep()
        f.spin(0.4)
        XCTAssertTrue(feedback.frame.isCelebrating)
        XCTAssertTrue(feedback.frame.celebrationQuiet)
        XCTAssertGreaterThan(feedback.frame.lift, 0.9, "the ring still flies to the centre")
    }

    // MARK: - The sparks

    func test_sparkWindow_isCentredOnTheCard_whileCelebrating() throws {
        makeFixture()
        completeStep()
        var found: NSRect?
        var body: NSRect?
        let t0 = CACurrentMediaTime()
        // (Read late in the moment, before the handoff moves the card: by then the card has settled where the sparks were aimed.)
        while CACurrentMediaTime() - t0 < 1.2, found == nil {
            f.spin(0.02)
            if let w = feedback.debugSparkOverlay.window, feedback.frame.lift > 0.95, CACurrentMediaTime() - t0 > 0.55 {
                found = w.frame; body = TourCardView.bodyFrame(inWindowFrame: card.frame, beakSide: f.controller.debugCardStore?.beakSide ?? .right)
            }
        }
        let w = try XCTUnwrap(found, "the spark window opens while the ring is at the centre")
        let b = try XCTUnwrap(body)
        XCTAssertEqual(w.midX, b.midX, accuracy: 6, "centred on the card's body, where the big ring is")
        XCTAssertEqual(w.midY, b.midY, accuracy: 6)
        XCTAssertEqual(w.width, TourSparkOverlay.celebrationSparkRadius * 2, accuracy: 1)
    }

    // MARK: - Cost

    /// Frame times of the main thread over one completion with the moment, against the same completion without it: the turns of
    /// the 1.3 s from the completion (the moment itself), printed for the report. The guards are loose (the budget is 16.7 ms a
    /// frame; a loaded machine puts a stray turn over it).
    func test_measure_frameTimes_celebratedVersusPlain() throws {
        var moment: [String: TourFrameStats] = [:]
        for run in 0..<2 {
            for (name, on) in [("plain", false), ("celebrated", true)] {
                makeFixture(feedback: TourCompletionFeedback(celebrationEnabled: on))
                let meter = TourFrameMeter()
                let t0 = CACurrentMediaTime()
                meter.start()
                f.spin(0.5)
                let tComplete = CACurrentMediaTime() - t0
                completeStep()
                f.spin(2.2)
                meter.stop()
                let turns = meter.busyAt.filter { $0.t >= tComplete && $0.t < tComplete + 1.3 && $0.busy >= 0.0005 }.map(\.busy)
                let stats = TourFrameStats(turns)
                print("[frames] \(name) run \(run + 1): the moment's 1.3 s: \(stats)")
                if run == 1 { moment[name] = stats }
                f.tearDown(); f = nil
            }
        }
        let c = try XCTUnwrap(moment["celebrated"])
        XCTAssertLessThan(c.maxMs, 40, "no turn of the moment stalls the main thread (\(c))")
        XCTAssertLessThan(c.p95Ms, 16.7, "95 % of the moment's turns fit a 60 Hz frame (\(c))")
    }
}
