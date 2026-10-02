/**
 * [INPUT]: TourFeedbackChoreographer (fake clock, stepped at 1/60 like the prototype's `__proto.advance`),
 *          TourCompletionFeedback, TourCelebrationRingPose.
 * [OUTPUT]: TourFeedbackCelebrationTests — the celebration moment (spec §B.10, founder 2026-10-01): the card is the canvas.
 * [POS]: Tests. What is pinned: B.2 / B.3 are untouched (same phases at the same times, same haptics, same handoff H);
 *        blur 0 -> 1 in 0.18 s while the ring lifts to the card centre; the ring flies home at H and the blur lets go AFTER
 *        the next content swapped in; a click ends the moment early; a burst never lets go in between; Reduce Transparency /
 *        Reduce Motion are quiet; beats, skips and a disabled moment stay quiet.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourFeedbackCelebrationTests: XCTestCase {
    private let dt = 1.0 / 60.0

    private final class HapticBox { var log: [(ms: Int, kind: TourHaptic)] = [] }

    private func makeCho(celebrate: Bool = true, reduceMotion: Bool = false, quietTransparency: Bool = false, haptics: HapticBox? = nil) -> TourFeedbackChoreographer {
        let cho = TourFeedbackChoreographer(reduceMotion: reduceMotion, random: TourSeededRandom(seed: 1), haptic: { _ in })
        cho.celebrationEnabled = celebrate
        cho.reduceTransparency = quietTransparency
        cho.geometry = TourFXGeometry(ringCenter: CGPoint(x: 130, y: 100), cardTop: 20, cardCenterX: 130,
                                      zoom: celebrate ? TourCelebrationTokens.ringZoom : 1, confettiZoom: celebrate ? 1 : nil)
        if let haptics { cho.haptic = { [unowned cho] kind in haptics.log.append((Int((cho.now * 1000).rounded()), kind)) } }
        return cho
    }

    private func ev(from: Int, to: Int, closes: Bool = false, confetti: Bool = false, handsOff: Bool = true, beats: [Int] = []) -> TourFeedbackEvent {
        TourFeedbackEvent(ringFrom: from, ringTo: to, beatIndices: beats, closesRing: closes, confetti: confetti,
                          sparks: !closes, handsOff: handsOff)
    }

    /// (t seconds, frame) for every 1/60 step up to `seconds`.
    private func record(_ cho: TourFeedbackChoreographer, seconds: Double, from start: Double = 0, each: ((Double) -> Void)? = nil) -> [(t: Double, f: TourFeedbackFrame)] {
        var out: [(Double, TourFeedbackFrame)] = []
        var t = start
        while t < start + seconds - 1e-9 {
            cho.step(dt); t += dt
            each?(t)
            out.append((t, cho.makeFrame()))
        }
        return out
    }

    private func at(_ log: [(t: Double, f: TourFeedbackFrame)], _ t: Double) -> TourFeedbackFrame {
        log.min { abs($0.t - t) < abs($1.t - t) }!.f
    }

    // MARK: - B.2 / B.3 are untouched

    func test_theCelebration_doesNotMoveAnyB2Cue_orHaptic() {
        for (name, event) in [("step", ev(from: 2, to: 3)), ("final", ev(from: 6, to: 7, closes: true, confetti: true))] {
            let plain = HapticBox(), cele = HapticBox()
            let a = makeCho(celebrate: false, haptics: plain), b = makeCho(celebrate: true, haptics: cele)
            a.begin(event, wallNow: 0); b.begin(event, wallNow: 0)
            _ = record(a, seconds: 2.2); _ = record(b, seconds: 2.2)
            XCTAssertEqual(a.phaseLog.map(\.phase), b.phaseLog.map(\.phase), "\(name): same states in the same order")
            XCTAssertEqual(a.phaseLog.map(\.ms), b.phaseLog.map(\.ms), "\(name): at the same times (H stays 760 / 1050 ms)")
            XCTAssertEqual(plain.log.map(\.ms), cele.log.map(\.ms), "\(name): haptics on the same frames")
            XCTAssertEqual(plain.log.map(\.kind), cele.log.map(\.kind))
        }
    }

    // MARK: - The moment

    func test_step_blurRampsInOverPointOneEightSeconds_ringLiftsToTheCentre_andHoldsUntilH() {
        let cho = makeCho()
        cho.begin(ev(from: 2, to: 3), wallNow: 0)
        let log = record(cho, seconds: 1.6)
        XCTAssertGreaterThan(at(log, 1.0 / 60).blur, 0.05, "starts at once (an `out` curve: fast first frame)")
        XCTAssertLessThan(at(log, 1.0 / 60).blur, 0.7)
        XCTAssertEqual(at(log, 0.18).blur, 1, accuracy: 0.02, "blur 0 -> 1 in 0.18 s")
        XCTAssertGreaterThan(at(log, 0.09).blur, 0.3); XCTAssertLessThan(at(log, 0.09).blur, 0.95)
        let liftMax = log.filter { $0.t > 0.25 && $0.t < 0.7 }.map(\.f.lift).max() ?? 0
        XCTAssertEqual(liftMax, 1, accuracy: 0.08, "the ring is at the card's centre (a spring: a hair of overshoot)")
        for (t, f) in log where t > 0.2 && t < 0.74 {
            XCTAssertEqual(f.blur, 1, accuracy: 0.001, "held until the handoff: t=\(t)")
            XCTAssertGreaterThan(f.lift, 0.9, "ring stays at the centre until H: t=\(t)")
        }
        XCTAssertTrue(log.allSatisfy { $0.f.blur <= 1.0001 })
    }

    func test_ringFliesHomeAtTheHandoff_andTheBlurLetsGoOnlyAfterTheSwap() {
        let cho = makeCho()
        cho.begin(ev(from: 2, to: 3), wallNow: 0)
        var swapAt: Double?
        let log = record(cho, seconds: 1.8) { t in if swapAt == nil, cho.swapGeneration > 0 { swapAt = t } }
        let swap = try! XCTUnwrap(swapAt)
        XCTAssertEqual(swap, 0.76 + 0.14, accuracy: 0.04, "the content swaps 140 ms after H")
        // ring: flies from H; blur: untouched until the swap
        XCTAssertLessThan(at(log, 0.76 + 0.17).lift, 0.8, "the ring is on its way home during the old content's fade-out")
        for (t, f) in log where t > 0.2 && t < swap - 0.03 {
            XCTAssertEqual(f.blur, 1, accuracy: 0.001, "blur holds through the fade-out and the swap: t=\(t)")
        }
        XCTAssertLessThan(at(log, swap + 0.26 + 0.05).blur, 0.01, "and is gone 0.26 s after the swap")
        XCTAssertGreaterThan(at(log, swap + 0.06).blur, 0.7, "the unblur reveals the new content, it does not start before it")
        XCTAssertLessThan(at(log, 0.76 + 0.34 + 0.05).lift, 0.01, "the ring is home 0.34 s after H")
        // monotone release
        let after = log.filter { $0.t > swap }.map(\.f.blur)
        XCTAssertEqual(after, after.sorted(by: >), "the blur only decreases once released")
        XCTAssertFalse(at(log, 1.7).isCelebrating)
        XCTAssertFalse(cho.busy)
    }

    func test_finalStep_sameMoment_thenDiscAndConfetti_handoffAtB3Time() {
        let cho = makeCho()
        cho.begin(ev(from: 6, to: 7, closes: true, confetti: true), wallNow: 0)
        let log = record(cho, seconds: 2.4)
        XCTAssertEqual(at(log, 0.2).blur, 1, accuracy: 0.001)
        XCTAssertGreaterThan(at(log, 0.9).lift, 0.9, "the ring is still big while it seals and fills")
        XCTAssertGreaterThan(at(log, 0.9).disc, 0.5, "disc fill (B.3) happens on the big ring")
        let handoff = Double(cho.phaseLog.first { $0.phase == .handoff }?.ms ?? -1)
        XCTAssertEqual(handoff, 1050, accuracy: 20, "H = 1050 ms (B.3), unchanged")
        XCTAssertTrue(cho.phaseLog.contains { $0.phase == .confetti })
        // the same order as a step: ring home from H, blur released after the swap (H + 140 ms) over 0.26 s
        XCTAssertEqual(at(log, 1.05 + 0.10).blur, 1, accuracy: 0.001, "blur holds through the old content's fade-out")
        XCTAssertGreaterThan(at(log, 1.05 + 0.14 + 0.08).blur, 0.5, "and starts to go only after the swap")
        XCTAssertLessThan(at(log, 1.05 + 0.14 + 0.26 + 0.05).blur, 0.01)
        XCTAssertFalse(at(log, 2.3).isCelebrating)
    }

    func test_sparksFlyFromTheBigRing_confettiKeepsItsOwnScale() {
        let cho = makeCho()
        cho.begin(ev(from: 2, to: 3), wallNow: 0)
        _ = record(cho, seconds: 0.5)
        let sparks = cho.makeFXSnapshot().particles.filter { $0.kind == .spark }
        XCTAssertGreaterThan(sparks.count, 10)
        // A spark starts on the big ring's arc: radius 11.25 x 2.86 = 32 pt from the ring centre (130, 100) (before it flies)
        let nearRing = sparks.filter { hypot($0.x - 130, $0.y - 100) < 60 }
        XCTAssertGreaterThan(nearRing.count, sparks.count / 2)
        let confettiCho = makeCho()
        confettiCho.begin(ev(from: 6, to: 7, closes: true, confetti: true), wallNow: 0)
        _ = record(confettiCho, seconds: 0.8)
        let confetti = confettiCho.makeFXSnapshot().particles.filter { $0.kind == .confetti }
        XCTAssertGreaterThan(confetti.count, 30)
        XCTAssertLessThan(confetti.map(\.w).max() ?? 99, 10, "confetti pieces stay card-sized (5-7pt x 0.8), not 2.86x")
    }

    // MARK: - Click ends it early

    func test_aClickEndsTheMomentEarly_handoffNow_decorationDropped() {
        let cho = makeCho()
        cho.begin(ev(from: 2, to: 3), wallNow: 0)
        var log = record(cho, seconds: 0.3)
        cho.endCelebrationEarly()
        log += record(cho, seconds: 1.4)
        let handoff = Double(cho.phaseLog.first { $0.phase == .handoff }?.ms ?? -1)
        XCTAssertEqual(handoff, 300 + 20, accuracy: 40, "the handoff starts at the click (was 760 ms)")
        XCTAssertFalse(cho.phaseLog.contains { $0.phase == .sparks }, "the sparks cue had not happened: dropped")
        XCTAssertEqual(cho.makeFXSnapshot().particles.count, 0)
        XCTAssertFalse(log.last!.f.isCelebrating, "the moment still ends cleanly (ring home, blur gone)")
        XCTAssertFalse(cho.busy)
    }

    func test_aClickBeforeAnyMoment_orAfterIt_doesNothing() {
        let cho = makeCho()
        cho.endCelebrationEarly()                         // nothing running
        cho.begin(ev(from: 2, to: 3), wallNow: 0)
        _ = record(cho, seconds: 1.6)
        cho.endCelebrationEarly()                         // already over
        XCTAssertFalse(cho.busy)
        XCTAssertEqual(cho.phaseLog.filter { $0.phase == .handoff }.count, 1)
    }

    // MARK: - A burst of completions

    func test_aBurst_neverLetsGoInBetween_andLetsGoOnceAtTheEnd() {
        let cho = makeCho()
        cho.begin(ev(from: 1, to: 2), wallNow: 0)
        var all = record(cho, seconds: 0.30)
        cho.begin(ev(from: 2, to: 3), wallNow: 0.3)       // a second completion, 0.3 s later
        all += record(cho, seconds: 0.30, from: 0.3)
        cho.begin(ev(from: 3, to: 4), wallNow: 0.6)
        all += record(cho, seconds: 2.0, from: 0.6)
        let busyPart = all.filter { $0.t > 0.2 && $0.t < 0.6 + 0.7 }.map(\.f)       // until the third sequence's H
        XCTAssertTrue(busyPart.allSatisfy { $0.blur > 0.999 }, "blur never dips between completions: min \(busyPart.map(\.blur).min() ?? -1)")
        XCTAssertTrue(busyPart.allSatisfy { $0.lift > 0.9 }, "the ring stays big: min \(busyPart.map(\.lift).min() ?? -1)")
        XCTAssertFalse(all.last!.f.isCelebrating, "and everything lets go at the end")
        let ring = all.compactMap(\.f.ringProgress)
        XCTAssertEqual(ring, ring.sorted(), "the ring never goes backwards")
        XCTAssertEqual(ring.last ?? 0, 4, accuracy: 0.01, "to the final count")
    }

    // MARK: - Quiet variants and the cases that do not celebrate

    func test_reduceMotion_dimsInsteadOfBlurring_staticCheck_noParticles_sameH() {
        let cho = makeCho(reduceMotion: true)
        cho.geometry = nil
        cho.begin(ev(from: 2, to: 3), wallNow: 0)
        let log = record(cho, seconds: 1.4)
        XCTAssertTrue(at(log, 0.2).celebrationQuiet, "the view neither blurs nor scales")
        XCTAssertEqual(at(log, 0.12).blur, 1, accuracy: 0.03, "0.12 s linear crossfade")
        XCTAssertEqual(at(log, 0.02).checkDraw, 1, accuracy: 0.001, "the check is simply there, not drawn")
        XCTAssertEqual(cho.makeFXSnapshot().particles.count, 0)
        XCTAssertEqual(Double(cho.phaseLog.first { $0.phase == .handoff }?.ms ?? -1), 500, accuracy: 20, "H stays at B.7's 500 ms")
        XCTAssertFalse(log.last!.f.isCelebrating)
    }

    func test_reduceTransparency_isQuiet_butKeepsTheMotion() {
        let cho = makeCho(quietTransparency: true)
        cho.begin(ev(from: 2, to: 3), wallNow: 0)
        let log = record(cho, seconds: 1.6)
        XCTAssertTrue(at(log, 0.3).celebrationQuiet)
        XCTAssertGreaterThan(at(log, 0.4).lift, 0.9, "the ring still flies to the centre")
        XCTAssertGreaterThan(cho.phaseLog.filter { $0.phase == .sparks }.count, 0, "and the sparks still fly")
    }

    func test_aBeatAlone_aDisabledMoment_andAStepWithNoHandoff() {
        // beat only: no ring growth, nothing
        let beat = makeCho()
        beat.begin(ev(from: 2, to: 2, beats: [0]), wallNow: 0)
        XCTAssertTrue(record(beat, seconds: 0.6).allSatisfy { !$0.f.isCelebrating })
        // disabled
        let off = makeCho(celebrate: false)
        off.begin(ev(from: 2, to: 3), wallNow: 0)
        XCTAssertTrue(record(off, seconds: 1.4).allSatisfy { !$0.f.isCelebrating })
        // a step finished out of order (no card swap follows): ring and blur let go on their own
        let lone = makeCho()
        lone.begin(ev(from: 2, to: 3, handsOff: false), wallNow: 0)
        let log = record(lone, seconds: 1.6)
        XCTAssertGreaterThan(at(log, 0.6).blur, 0.99)
        XCTAssertFalse(at(log, 1.5).isCelebrating, "released at 0.86 s")
        XCTAssertFalse(lone.busy)
    }

    // MARK: - Where the ring sits

    func test_ringPose_slotAtZero_centreAtOne() {
        let body = CGSize(width: 260, height: 180)
        let home = TourCelebrationRingPose.at(lift: 0, bodySize: body)
        XCTAssertEqual(home.center.x, 260 - 14 - 14, accuracy: 0.001)
        XCTAssertEqual(home.center.y, 14 + 14, accuracy: 0.001)
        XCTAssertEqual(home.scale, 1, accuracy: 1e-9)
        let big = TourCelebrationRingPose.at(lift: 1, bodySize: body)
        XCTAssertEqual(big.center.x, 130, accuracy: 0.001)
        XCTAssertEqual(big.center.y, 90, accuracy: 0.001)
        XCTAssertEqual(big.scale * 28, 80, accuracy: 0.001, "80 pt across")
        let half = TourCelebrationRingPose.at(lift: 0.5, bodySize: body)
        XCTAssertEqual(half.center.x, (232 + 130) / 2, accuracy: 0.001)
    }

    func test_theCardsOwnRingSlot_isWhereThePoseSaysItIs() {
        // TourCardView.ringCenter (what the sparks used) and the pose's slot are the same point.
        let frame = CGRect(x: 100, y: 200, width: TourCardMetrics.bodyWidth + TourCardMetrics.beakSize, height: 180)
        let c = TourCardView.ringCenter(inWindowFrame: frame, beakSide: .right)
        let slot = TourCelebrationRingPose.at(lift: 0, bodySize: CGSize(width: TourCardMetrics.bodyWidth, height: 180)).center
        XCTAssertEqual(frame.maxX - TourCardMetrics.beakSize - c.x, TourCardMetrics.bodyWidth - slot.x, accuracy: 0.001)
        XCTAssertEqual(frame.maxY - c.y, slot.y, accuracy: 0.001)
    }
}

private extension TourFeedbackChoreographer {
    /// The ring's current value in steps (test peek through the frame).
    var ringValueForTest: Double { makeFrame().ringProgress ?? 0 }
}
