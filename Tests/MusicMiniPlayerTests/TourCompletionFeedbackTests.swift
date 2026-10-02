import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// The step-completion feedback (spec docs/design/2026-09-29-motion-prototype/
/// spec.md §B), driven by a fake clock:
///  - the state machine walks its states on time (§B.2/§B.3),
///  - a burst of completions never moves the ring backwards (§B.4),
///  - decoration of an interrupted sequence is dropped, state still lands,
///  - Reduce Motion: no particles, no scale, no width change (§B.7),
///  - haptics land on their frames (§B.8),
///  - the rendered pixels (ImageRenderer, offscreen) follow the frame.
/// The pure choreographer is stepped at 1/60 like the prototype's
/// `__proto.advance()`; that its values equal the prototype's to the last bit
/// was verified separately (frame-by-frame comparison sheets).
@MainActor
final class TourCompletionFeedbackTests: XCTestCase {
    private var now: TimeInterval = 100
    private let palette = TourCardPalette.light
    private let center = CGPoint(x: 20, y: 20) // ring center inside a 40x40 host
    private let frameStep = 1.0 / 60.0

    private final class HapticBox { var log: [(at: Double, kind: TourHaptic)] = [] }

    // MARK: - Fixtures

    private func makeCho(reduceMotion: Bool = false, seed: UInt32 = 1, haptics: HapticBox? = nil, geometry: Bool = true) -> TourFeedbackChoreographer {
        var clockRef: (() -> Double)?
        let cho = TourFeedbackChoreographer(reduceMotion: reduceMotion, random: TourSeededRandom(seed: seed), haptic: { kind in
            haptics?.log.append((clockRef?() ?? 0, kind))
        })
        clockRef = { [unowned cho] in cho.now }
        if geometry {
            cho.geometry = TourFXGeometry(ringCenter: CGPoint(x: 100, y: 100), cardTop: 40, cardCenterX: 100, zoom: 1)
        }
        return cho
    }

    private func makeFeedback(reduceMotion: Bool = false, haptics: HapticBox? = nil) -> TourCompletionFeedback {
        // (These tests are of B.2 / B.3 as specified: the small ring on the card. The celebration moment, which draws the big
        // ring instead, has its own tests — TourFeedbackCelebrationTests, TourCelebrationRealWindowTests.)
        TourCompletionFeedback(clock: { [unowned self] in self.now }, reduceMotion: { reduceMotion }, autoTick: false,
                               celebrationEnabled: false,
                               haptic: { kind in haptics?.log.append((self.now, kind)) }, random: TourSeededRandom(seed: 3))
    }

    private func step(_ cho: TourFeedbackChoreographer, seconds: Double, each: (() -> Void)? = nil) {
        var t = 0.0
        while t < seconds - 1e-9 { cho.step(frameStep); t += frameStep; each?() }
    }

    private func ev(from: Int, to: Int, beats: [Int] = [], closes: Bool = false, confetti: Bool = false,
                    sparks: Bool = true, handsOff: Bool = true) -> TourFeedbackEvent {
        TourFeedbackEvent(ringFrom: from, ringTo: to, beatIndices: beats, closesRing: closes, confetti: confetti,
                          sparks: sparks && !closes, handsOff: handsOff)
    }

    // MARK: - State machine timing (§B.2, §B.3)

    func test_ordinaryStep_walksAnticipateDrawGrowSparksSettleHandoffIdle_onTime() {
        let cho = makeCho()
        XCTAssertTrue(cho.begin(ev(from: 1, to: 2), wallNow: 0))
        step(cho, seconds: 1.4)
        let log = cho.phaseLog.map { ($0.phase, $0.ms) }
        XCTAssertEqual(log.map(\.0), [.anticipate, .draw, .grow, .sparks, .settle, .handoff, .idle])
        // cues fire on the first 1/60 frame at or after their time (17ms grid)
        let expected: [Double] = [0, 60, 60, 380, 660, 760, 1100]
        for (entry, want) in zip(log, expected) {
            XCTAssertEqual(Double(entry.1), want, accuracy: 20, "\(entry.0) at \(entry.1)ms, spec \(want)ms")
        }
    }

    func test_twoPendingBeats_shiftEverythingBySeventyMilliseconds() {
        let cho = makeCho()
        cho.begin(ev(from: 0, to: 1, beats: [0, 1]), wallNow: 0)
        step(cho, seconds: 1.5)
        let byPhase = Dictionary(cho.phaseLog.map { ($0.phase, $0.ms) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(Double(byPhase[.anticipate] ?? -1), 70, accuracy: 20, "T0 = 70ms x (n-1)")
        XCTAssertEqual(Double(byPhase[.sparks] ?? -1), 450, accuracy: 20)
    }

    func test_lastStep_sealsThenConfetti_thenHandsOffToTheFinale() {
        let cho = makeCho()
        cho.begin(ev(from: 6, to: 7, closes: true, confetti: true), wallNow: 0)
        step(cho, seconds: 1.8)
        let log = cho.phaseLog.map { ($0.phase, $0.ms) }
        XCTAssertEqual(log.map(\.0), [.anticipate, .draw, .grow, .seal, .confetti, .settle, .handoff, .idle])
        let expected: [Double] = [0, 60, 60, 600, 680, 1050, 1050, 1500]
        for (entry, want) in zip(log, expected) {
            XCTAssertEqual(Double(entry.1), want, accuracy: 20, "\(entry.0) at \(entry.1)ms, spec \(want)ms")
        }
        XCTAssertTrue(cho.finished)
        let frame = cho.makeFrame()
        XCTAssertEqual(frame.disc, 1, accuracy: 0.05, "the ring ends as a solid disc")
        XCTAssertEqual(frame.ringProgress ?? 0, 7, accuracy: 0.001)
    }

    func test_closingSequence_isNotInterruptible_andFinishedIgnoresEverything() {
        let cho = makeCho()
        cho.begin(ev(from: 6, to: 7, closes: true, confetti: true), wallNow: 0)
        step(cho, seconds: 0.3)
        XCTAssertFalse(cho.begin(ev(from: 6, to: 7), wallNow: 0.3), "§B.4-4: the seal cannot be interrupted")
        step(cho, seconds: 2.5)
        XCTAssertFalse(cho.begin(ev(from: 0, to: 1), wallNow: 3), "after the seal nothing replays")
    }

    func test_lastStep_ceremony_particlesAndBounce() {
        let cho = makeCho()
        cho.begin(ev(from: 6, to: 7, closes: true, confetti: true), wallNow: 0)
        var maxParticles = 0, minBounce = 0.0
        step(cho, seconds: 2.7) {
            maxParticles = max(maxParticles, cho.makeFXSnapshot().particles.count)
            minBounce = min(minBounce, cho.makeFrame().cardOffsetY)
        }
        XCTAssertEqual(maxParticles, 72, "72 confetti")
        XCTAssertLessThan(minBounce, -3, "the card jumps up ~4pt (§B.3)")
        XCTAssertTrue(cho.makeFXSnapshot().isEmpty, "everything has died by 2.5s")
    }

    // MARK: - Interruption (§B.4)

    func test_tripleCompletion_ringNeverGoesBack_andEndsAtThree() {
        let cho = makeCho()
        var samples: [Double] = []
        func run(_ s: Double) { step(cho, seconds: s) { samples.append(cho.makeFrame().ringProgress ?? samples.last ?? 0) } }
        cho.begin(ev(from: 0, to: 1), wallNow: 0); run(0.16)
        cho.begin(ev(from: 1, to: 2), wallNow: 0.16); run(0.16)
        cho.begin(ev(from: 2, to: 3), wallNow: 0.32); run(1.6)
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a - 1e-9, "the ring must never move backwards (\(a) -> \(b))")
            XCTAssertLessThan(b - a, 0.13, "and never jump: speed stays continuous across the retarget")
        }
        XCTAssertEqual(samples.last ?? 0, 3, accuracy: 1e-3)
    }

    func test_interrupt_dropsDecoration_butStateStillLands() {
        let cho = makeCho()
        cho.onSwapDue = { }                                        // a controller owns the card swap
        cho.begin(ev(from: 0, to: 1, beats: [0, 1]), wallNow: 0)
        step(cho, seconds: 0.16)                                   // before the sparks at 380ms
        cho.begin(ev(from: 1, to: 2), wallNow: 0.16)               // interrupt: combo 1
        var bursts = 0, previous = 0, peak = 0
        step(cho, seconds: 0.12) {
            XCTAssertNotNil(cho.makeFrame().beats[0], "first event's dots are still animating")
        }
        let beat1 = cho.makeFrame().beats[1]
        XCTAssertGreaterThan(beat1?.fill ?? 0, 0.9, "the pending dot cue was fast-forwarded, not lost")
        step(cho, seconds: 1.2) {
            let n = cho.makeFXSnapshot().particles.count
            if n > previous { bursts += 1 }
            previous = n; peak = max(peak, n)
        }
        XCTAssertEqual(bursts, 1, "only the last completion sparks: the interrupted one dropped its decoration")
        XCTAssertEqual(peak, 16 + 4, "combo 1: 16 + 4 sparks")
    }

    // MARK: - Reduce Motion (§B.7)

    func test_reduceMotion_noParticles_noScale_noWidthChange_noComet_linearRing() {
        let cho = makeCho(reduceMotion: true)
        cho.begin(ev(from: 6, to: 7, beats: [0, 1], closes: true, confetti: true), wallNow: 0)
        var mid = 0.0
        step(cho, seconds: 1.6) {
            let f = cho.makeFrame()
            XCTAssertEqual(f.ringScale, 1)
            XCTAssertEqual(f.ringLineWidth, 5.5)
            XCTAssertEqual(f.ringVelocity, 0, "no comet: a linear fill has no spring velocity")
            XCTAssertEqual(f.cardOffsetY, 0, "no card jump")
            XCTAssertEqual(f.numberScale, 1)
            for b in f.beats.values { XCTAssertEqual(b.scale, 1, "dots do not pop") }
            XCTAssertTrue(cho.makeFXSnapshot().isEmpty, "no sparks, halos or confetti")
            if abs(cho.now - 0.22) < 0.009 { mid = f.ringProgress ?? 0 }      // 0.07 + 0.15 of the 0.3s linear fill
        }
        XCTAssertEqual(mid, 6.5, accuracy: 0.12, "the fill is linear over 0.3s")
    }

    func test_reduceMotion_dotsSnapSolid_withoutTrimOrScale() {
        let cho = makeCho(reduceMotion: true)
        cho.begin(TourFeedbackEvent(ringFrom: 1, ringTo: 1, beatIndices: [0]), wallNow: 0)
        cho.step(frameStep)
        let dot = cho.makeFrame().beats[0]
        XCTAssertEqual(dot?.fill, 1)
        XCTAssertEqual(dot?.draw, 1)
        XCTAssertEqual(dot?.scale, 1)
    }

    // MARK: - Haptics (§B.8)

    func test_haptics_ordinaryStep_oneLevelChange_onTheCheckLanding() {
        let box = HapticBox()
        let cho = makeCho(haptics: box)
        cho.begin(ev(from: 1, to: 2), wallNow: 0)
        step(cho, seconds: 1.4)
        XCTAssertEqual(box.log.map(\.kind), [.levelChange])
        XCTAssertEqual(box.log[0].at, 0.06, accuracy: 0.02, "+60ms")
    }

    func test_haptics_lastStep_levelChangeThenAlignmentOnTheSeal() {
        let box = HapticBox()
        let cho = makeCho(haptics: box)
        cho.begin(ev(from: 6, to: 7, closes: true, confetti: true), wallNow: 0)
        step(cho, seconds: 2.0)
        XCTAssertEqual(box.log.map(\.kind), [.levelChange, .alignment])
        XCTAssertEqual(box.log[0].at, 0.06, accuracy: 0.02)
        XCTAssertEqual(box.log[1].at, 0.60, accuracy: 0.02, "+600ms")
    }

    func test_haptics_beatOnly_oneLevelChange_reduceMotionKeepsIt() {
        for rm in [false, true] {
            let box = HapticBox()
            let cho = makeCho(reduceMotion: rm, haptics: box)
            cho.begin(TourFeedbackEvent(ringFrom: 2, ringTo: 2, beatIndices: [0]), wallNow: 0)
            step(cho, seconds: 0.5)
            XCTAssertEqual(box.log.map(\.kind), [.levelChange], "reduceMotion=\(rm)")
        }
    }

    func test_haptics_reduceMotionStep_fireAtOnce_andSealUsesAlignment() {
        let box = HapticBox()
        let cho = makeCho(reduceMotion: true, haptics: box)
        cho.begin(ev(from: 1, to: 2), wallNow: 0)
        step(cho, seconds: 1)
        XCTAssertEqual(box.log.map(\.kind), [.levelChange])
        XCTAssertLessThan(box.log[0].at, 0.03)
    }

    // MARK: - Card handoff handshake

    func test_handoff_fadesTheOldCardOut_asksForTheSwap_andFadesTheNewOneIn() {
        let cho = makeCho()
        var calls = 0
        var opacityAtCall: [Double] = []
        var callTime = 0.0
        cho.onSwapDue = {
            calls += 1
            callTime = cho.now
            opacityAtCall = cho.makeFrame().contentOpacity
            XCTAssertTrue(cho.expectsSwap)
        }
        cho.begin(ev(from: 1, to: 2), wallNow: 0)
        step(cho, seconds: 0.95)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(callTime, 0.9, accuracy: 0.02, "760ms + 140ms fade-out")
        XCTAssertEqual(opacityAtCall.count, 3)
        XCTAssertTrue(opacityAtCall.allSatisfy { $0 < 0.1 }, "the old content is (all but) out when the swap is asked for: \(opacityAtCall)")
        cho.cardDidSwap()
        XCTAssertFalse(cho.expectsSwap)
        XCTAssertEqual(cho.makeFrame().numberOpacity, 0, accuracy: 0.01, "the new number rolls in from nothing")
        step(cho, seconds: 0.03)
        let early = cho.makeFrame().contentOpacity
        XCTAssertGreaterThan(early[0], 0)
        XCTAssertLessThan(early[2], early[0], "the three blocks stagger in, 40ms apart")
        step(cho, seconds: 0.4)
        XCTAssertEqual(cho.makeFrame().isActive, false, "sequence over, the views are back on the static card")
    }

    func test_handoff_noSwapWithinHalfASecond_bringsTheContentBack() {
        let cho = makeCho()
        cho.onSwapDue = { }                       // the controller never answers
        cho.begin(ev(from: 1, to: 2), wallNow: 0)
        step(cho, seconds: 1.0)
        XCTAssertTrue(cho.expectsSwap)
        step(cho, seconds: 0.9)
        XCTAssertFalse(cho.expectsSwap)
        XCTAssertFalse(cho.isActive, "and the sequence ends by itself")
    }

    func test_swapArrivingBeforeTheFadeOut_isAccepted() {
        let cho = makeCho()
        cho.onSwapDue = { }
        cho.begin(ev(from: 1, to: 2), wallNow: 0)
        step(cho, seconds: 0.5)
        XCTAssertTrue(cho.expectsSwap, "swap is promised for later")
        cho.cardDidSwap()                          // the controller's own timer came first
        XCTAssertFalse(cho.expectsSwap)
        step(cho, seconds: 1.4)
        XCTAssertFalse(cho.isActive)
    }

    // MARK: - Determinism + geometry

    func test_sameSeedSameSteps_sameFramesAndParticles() {
        func run() -> [TourFeedbackFrame] {
            let cho = makeCho(seed: 42)
            cho.begin(ev(from: 2, to: 3, beats: [0, 1]), wallNow: 0)
            var out: [TourFeedbackFrame] = []
            step(cho, seconds: 1.2) { out.append(cho.makeFrame()); if out.count % 10 == 0 { XCTAssertEqual(cho.makeFXSnapshot(), cho.makeFXSnapshot()) } }
            return out
        }
        XCTAssertEqual(run(), run())
    }

    func test_sparksLeaveTheArcHead_ofTheTargetProgress() {
        let cho = makeCho(seed: 9)
        cho.begin(ev(from: 1, to: 2), wallNow: 0)
        step(cho, seconds: 0.4)                                  // just after the 380ms cue
        let parts = cho.makeFXSnapshot().particles
        XCTAssertEqual(parts.count, 16)
        let cx = parts.map(\.x).reduce(0, +) / Double(parts.count)
        let cy = parts.map(\.y).reduce(0, +) / Double(parts.count)
        let dx = cx - 100, dy = cy - 100
        let angle = atan2(dy, dx) * 180 / .pi
        let want = -90 + 360.0 * 2 / 7                            // 2/7 of a turn clockwise from 12 o'clock
        XCTAssertEqual(angle, want, accuracy: 12)
        XCTAssertEqual((dx * dx + dy * dy).squareRoot(), 11.25, accuracy: 6, "on the ring's centerline, plus a frame of drift")
    }

    func test_sparkColours_arePinkSoftPinkAndGold_neverWhite() {
        let cho = makeCho(seed: 5)
        cho.begin(ev(from: 1, to: 2), wallNow: 0)
        step(cho, seconds: 0.4)
        let colors = Set(cho.makeFXSnapshot().particles.map(\.color))
        XCTAssertTrue(colors.isSubset(of: [.accent, .soft, .gold]))
        XCTAssertFalse(colors.contains(.white))
    }

    // MARK: - Pixels (offscreen ImageRenderer)

    private func ringView(_ fb: TourCompletionFeedback, completed: Int = 2, closed: Bool = false, label: String = "3") -> some View {
        TourFeedbackRing(completed: completed, closed: closed, stepLabel: label, palette: palette, feedback: fb)
            .padding(6)
            .frame(width: 40, height: 40)
    }

    private func render<V: View>(_ v: V, size: CGSize) -> TourPixels { TourRender.pixels(v, size: size)! }

    /// Fraction of the ring's centerline (r = 11.25pt) drawn in solid accent.
    private func arcFraction(_ px: TourPixels) -> Double {
        let samples = 180
        var hit = 0
        for k in 0..<samples {
            let theta = (Double(k) + 0.5) / Double(samples) * 2 * .pi
            let p = CGPoint(x: center.x + 11.25 * sin(theta), y: center.y - 11.25 * cos(theta))
            if TourRender.isAccent(px.rgba(atPoint: p)) { hit += 1 }
        }
        return Double(hit) / Double(samples)
    }

    private func lineThickness(_ px: TourPixels) -> Double {
        var run = 0, best = 0
        let x = Int((center.x + 3) * px.scale)
        for y in 0..<px.height {
            if TourRender.isAccent(px.rgba(x: x, y: y)) { run += 1; best = max(best, run) } else { run = 0 }
        }
        return Double(best) / Double(px.scale)
    }

    func test_ringArc_drawsTheGrowthOfOneStep() {
        let fb = makeFeedback()
        fb.begin(ev(from: 2, to: 3, handsOff: false))
        let size = CGSize(width: 40, height: 40)
        func arc(at dt: Double) -> Double { fb.advance(to: 100 + dt); return arcFraction(render(ringView(fb), size: size)) }
        let cap = 2 * 2.75 / (2 * Double.pi * 11.25)
        let start = arc(at: 0)
        let end = arc(at: 0.8)
        XCTAssertEqual(start, 2.0 / 7 + cap, accuracy: 0.05, "before it moves the ring shows 2/7")
        XCTAssertEqual(end, 3.0 / 7 + cap, accuracy: 0.05, "and 3/7 once settled")
        fb.advance(to: 100.25)
        XCTAssertGreaterThan(Double(fb.frame.ringProgress ?? 0), 2.2, "mid-flight the arc is between the two")
        XCTAssertLessThan(Double(fb.frame.ringProgress ?? 9), 3.0)
    }

    func test_ringLineWidth_swellsThenReturnsToBase_inRenderedPixels() {
        let fb = makeFeedback()
        fb.begin(ev(from: 2, to: 3, handsOff: false))
        let size = CGSize(width: 40, height: 40)
        func thickness(at dt: Double) -> Double { fb.advance(to: 100 + dt); return lineThickness(render(ringView(fb), size: size)) }
        let base = thickness(at: 0)
        let peak = thickness(at: 0.22)
        let settled = thickness(at: 0.9)
        XCTAssertEqual(base, 5.5, accuracy: 0.6)
        XCTAssertGreaterThan(peak, base + 0.5, "the line swells 5.5 -> 6.5 while it grows")
        XCTAssertEqual(settled, 5.5, accuracy: 0.6)
    }

    func test_ringCenter_numberBecomesTheCheck_inRenderedPixels() {
        let fb = makeFeedback()
        fb.begin(ev(from: 2, to: 3, handsOff: false))
        let size = CGSize(width: 40, height: 40)
        func accentInCenter(at dt: Double) -> Int {
            fb.advance(to: 100 + dt)
            let px = render(ringView(fb), size: size)
            var n = 0
            for dy in -8...8 { for dx in -8...8 where TourRender.isAccent(px.rgba(atPoint: CGPoint(x: center.x + Double(dx) * 0.5, y: center.y + Double(dy) * 0.5))) { n += 1 } }
            return n
        }
        XCTAssertEqual(accentInCenter(at: 0), 0, "the step number is ink, not accent")
        XCTAssertGreaterThan(accentInCenter(at: 0.72), 12, "by 0.7s the accent check mark sits in the ring")
    }

    func test_beatDot_hollowToSolid_withPop() {
        let fb = makeFeedback()
        fb.begin(TourFeedbackEvent(ringFrom: 1, ringTo: 1, beatIndices: [1]))
        func dot() -> TourPixels {
            render(TourFeedbackBeatDot(index: 1, checked: true, palette: palette, feedback: fb).padding(4), size: CGSize(width: 22, height: 22))
        }
        let c = CGPoint(x: 11, y: 11)
        fb.advance(to: 100)
        XCTAssertFalse(TourRender.isAccent(dot().rgba(atPoint: c)), "hollow at the start")
        fb.advance(to: 100.15)
        XCTAssertGreaterThan(fb.frame.beats[1]?.scale ?? 1, 1.15, "presses down, then pops to ~1.22")
        fb.advance(to: 100.6)
        XCTAssertTrue(TourRender.isAccent(dot().rgba(atPoint: CGPoint(x: 5.6, y: 11))), "solid accent afterwards")
        XCTAssertEqual(fb.frame.beats[1]?.scale ?? 0, 1, accuracy: 0.02)
    }

    func test_beatDot_pressesDownBeforeItPops() {
        let cho = makeCho()
        cho.begin(TourFeedbackEvent(ringFrom: 1, ringTo: 1, beatIndices: [0]), wallNow: 0)
        var low = 2.0
        step(cho, seconds: 0.07) { low = min(low, cho.makeFrame().beats[0]?.scale ?? 2) }
        XCTAssertLessThan(low, 0.9, "anticipation: scale 1 -> 0.88 in 60ms")
    }

    func test_beatOnly_leavesTheRingAlone() {
        let fb = makeFeedback()
        fb.begin(TourFeedbackEvent(ringFrom: 1, ringTo: 1, beatIndices: [0]))
        fb.advance(to: 100.1)
        XCTAssertNil(fb.frame.ringProgress, "a beat completes no step: the ring keeps its static arc")
        XCTAssertEqual(fb.frame.numberOpacity, 1)
        XCTAssertNotNil(fb.frame.beats[0])
    }

    // MARK: - FX window (coordinates fixed 2026-09-29: window-local, y down)

    func test_fxWindow_isClickThrough_centredOnTheRing_andSparksStayInside() throws {
        let fb = makeFeedback()
        let ring = CGPoint(x: 700, y: 500)
        var e = ev(from: 1, to: 2)
        e.ringCenterOnScreen = ring
        e.cardFrameOnScreen = CGRect(x: 450, y: 340, width: 236, height: 200)
        fb.begin(e)
        let overlay = fb.debugSparkOverlay
        let window = try XCTUnwrap(overlay.window, "sparks need their own click-through window")
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertTrue(window.frame.contains(ring))
        let local = try XCTUnwrap(overlay.originInWindow)
        XCTAssertEqual(local.x, ring.x - window.frame.minX, accuracy: 0.5, "particles start at the window-local ring, not at screen coordinates")
        XCTAssertEqual(local.y, window.frame.maxY - ring.y, accuracy: 0.5, "y is flipped into the y-down local space")

        var painted = 0, sx = 0.0, sy = 0.0
        for t in stride(from: 0.0, through: 1.0, by: 1.0 / 30) {
            fb.advance(to: 100 + t)
            for p in fb.fx.particles {
                XCTAssertTrue(CGRect(origin: .zero, size: window.frame.size).contains(CGPoint(x: p.x, y: p.y)), "spark left its window: \(p.x),\(p.y)")
            }
            if abs(t - 0.6) < 0.02 {
                let px = try XCTUnwrap(TourRender.pixels(TourFXCanvas(snapshot: fb.fx, palette: palette).frame(width: window.frame.width, height: window.frame.height),
                                                          size: window.frame.size))
                for y in 0..<px.height { for x in 0..<px.width where px.rgba(x: x, y: y).a > 40 { painted += 1; sx += Double(x); sy += Double(y) } }
                XCTAssertEqual(sx / Double(max(painted, 1)) / px.scale, Double(local.x), accuracy: 16)
                XCTAssertEqual(sy / Double(max(painted, 1)) / px.scale, Double(local.y), accuracy: 16)
            }
        }
        XCTAssertGreaterThan(painted, 40, "sparks and the shock ring must paint pixels")
        fb.cancel()
        XCTAssertNil(overlay.window, "cancel closes the FX window")
    }

    func test_fxWindow_confetti_launchesFromTheCardTop_andNeverLeavesTheWindow() throws {
        let fb = makeFeedback()
        let card = CGRect(x: 450, y: 340, width: 236, height: 200)
        var e = ev(from: 6, to: 7, closes: true, confetti: true)
        e.ringCenterOnScreen = CGPoint(x: 646, y: 500)
        e.cardFrameOnScreen = card
        fb.begin(e)
        let window = try XCTUnwrap(fb.debugSparkOverlay.window)
        XCTAssertTrue(window.frame.contains(CGPoint(x: card.midX, y: card.maxY + 150)), "room above the card")
        XCTAssertTrue(window.frame.contains(CGPoint(x: card.midX, y: card.minY - 420)), "and below, where the confetti falls")
        var sawConfetti = false
        for t in stride(from: 0.0, through: 2.7, by: 1.0 / 30) {
            fb.advance(to: 100 + t)
            for p in fb.fx.particles where p.kind == .confetti {
                sawConfetti = true
                XCTAssertTrue(CGRect(origin: .zero, size: window.frame.size).contains(CGPoint(x: p.x, y: p.y)), "confetti left its window at \(t)s: \(p.x),\(p.y)")
                if p.age < 0.03 {
                    XCTAssertEqual(p.y, Double(window.frame.maxY - card.maxY) + 8, accuracy: 12, "launches at the card top edge")
                    XCTAssertEqual(p.x, Double(card.midX - window.frame.minX), accuracy: 72, "within ~60pt of the card centre (the ring pop scales the spread)")
                }
            }
        }
        XCTAssertTrue(sawConfetti)
    }

    func test_reduceMotion_opensNoFXWindow() {
        let fb = makeFeedback(reduceMotion: true)
        var e = ev(from: 1, to: 2)
        e.ringCenterOnScreen = CGPoint(x: 500, y: 500)
        fb.begin(e)
        XCTAssertNil(fb.debugSparkOverlay.window)
        fb.advance(to: 100.5)
        XCTAssertTrue(fb.fx.isEmpty)
    }

    // MARK: - Lifecycle + haptics through the entry point

    func test_entryPoint_firesTheHapticOnce_onTheFrameItLands() {
        let box = HapticBox()
        let fb = makeFeedback(haptics: box)
        fb.begin(ev(from: 1, to: 2))
        fb.advance(to: 100.03)
        XCTAssertTrue(box.log.isEmpty, "not before the check lands")
        fb.advance(to: 100.12)
        XCTAssertEqual(box.log.map(\.kind), [.levelChange])
        fb.advance(to: 101.5)
        XCTAssertEqual(box.log.count, 1)
    }

    func test_sequenceEnds_andHandsBackToTheStaticCard() {
        let fb = makeFeedback()
        fb.begin(ev(from: 1, to: 2, handsOff: false))
        fb.advance(to: 100.5)
        XCTAssertTrue(fb.isActive)
        for t in stride(from: 101.0, through: 103.0, by: 0.5) { fb.advance(to: t) }   // (one tick never covers more than 0.5s)
        XCTAssertFalse(fb.isActive)
        XCTAssertEqual(fb.frame, .rest)
        XCTAssertTrue(fb.fx.isEmpty)
    }

    func test_outOfOrderCompletion_noSwapFollows_checkGoesBackToTheNumber() {
        let cho = makeCho()
        cho.begin(ev(from: 1, to: 2, handsOff: false), wallNow: 0)
        step(cho, seconds: 0.7)
        XCTAssertGreaterThan(cho.makeFrame().checkDraw, 0.9, "check shown while the ring settles")
        step(cho, seconds: 0.8)
        XCTAssertFalse(cho.isActive)
        XCTAssertEqual(cho.makeFrame(), .rest, "no stale check, the card's own number shows again")
    }
}
