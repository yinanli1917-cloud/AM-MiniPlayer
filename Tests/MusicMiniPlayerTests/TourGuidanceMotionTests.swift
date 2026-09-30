/**
 * [INPUT]: MusicMiniPlayerAppKit's TourGuidanceMotion (pure; a fake clock, no windows).
 * [OUTPUT]: TourGuidanceMotionTests — the section C motion, frame by frame.
 * [POS]: Tests. Each block cites the prototype spec (docs/design/2026-09-29-motion-prototype/
 *        spec.md §C) it pins: card appear / disappear (C.2), the step move with a
 *        velocity-preserving retarget, beak re-aim and height spring (C.3), the ring's
 *        appear / pulse / rest / jump / press-now (C.4.1, founder 2026-09-29 "soft pulse"),
 *        the ghost cursor and glow (C.4.2), Reduce Motion (C.7) and zero idle cost (C.8).
 */

import XCTest
import MusicMiniPlayerCore
@testable import MusicMiniPlayerAppKit

final class TourGuidanceMotionTests: XCTestCase {
    typealias T = TourGuidanceTokens
    private let dt = 1.0 / 60

    private func pose(x: Double = 100, top: Double = 600, h: Double = 200, side: TourCardSide = .right, beak: Double = 60) -> TourCardPose {
        TourCardPose(x: x, top: top, width: 272, height: h, beakSide: side, beakOffset: beak)
    }

    private func geo(_ cx: Double, _ cy: Double, _ size: Double = 40) -> TourRingGeometry {
        TourRingGeometry(cx: cx, cy: cy, w: size, h: size, corner: size / 2)
    }

    /// Steps `seconds` in display-link frames and returns the frame at every step.
    private func run(_ m: TourGuidanceMotion, _ seconds: Double) -> [TourGuidanceFrame] {
        var out: [TourGuidanceFrame] = []
        let n = Int((seconds / dt).rounded())
        for _ in 0..<n { m.step(dt); out.append(m.makeFrame()) }
        return out
    }

    // MARK: - C.2 appear / disappear

    func test_cardAppear_growsFromTheBeakTip() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose())
        let f0 = m.makeFrame()
        XCTAssertTrue(f0.cardVisible)
        XCTAssertEqual(f0.cardOpacity, 0, accuracy: 1e-9)
        XCTAssertEqual(f0.cardScale, T.appearScale, accuracy: 1e-9, "scale .94")
        XCTAssertEqual(f0.cardApproach, 10, accuracy: 1e-9, "10pt toward the anchor")
        XCTAssertEqual(f0.contentOpacity, [0, 0, 0])

        let frames = run(m, 1.0)
        let t = { (s: Double) in frames[Int((s / self.dt).rounded()) - 1] }
        XCTAssertGreaterThan(t(0.05).cardOpacity, 0.05)
        XCTAssertLessThan(t(0.05).cardOpacity, 0.99)
        XCTAssertEqual(t(0.14).cardOpacity, 1, accuracy: 0.01, "opacity 0 -> 1 in 0.14 s")
        XCTAssertEqual(t(1.0).cardScale, 1, accuracy: 0.002)
        XCTAssertEqual(t(1.0).cardApproach, 0, accuracy: 0.05)
        // Blocks stagger 40 ms apart after 60 ms.
        XCTAssertEqual(t(0.05).contentOpacity[0], 0, accuracy: 1e-6, "nothing before 60 ms")
        XCTAssertGreaterThan(t(0.18).contentOpacity[0], 0.3)
        XCTAssertLessThan(t(0.13).contentOpacity[2], t(0.13).contentOpacity[0], "block 2 trails block 0")
        XCTAssertEqual(t(0.40).contentOpacity, [1, 1, 1].map { $0 }, accuracy: 0.01)
    }

    func test_cardDisappear_isTheQuick_easeIn_shrinkTowardTheAnchor() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose())
        _ = run(m, 1.0)
        m.dismissCard()
        XCTAssertFalse(m.cardVisible)
        let frames = run(m, 0.2)
        let end = frames[Int((0.16 / dt).rounded()) - 1]
        XCTAssertEqual(end.cardOpacity, 0, accuracy: 0.01, "gone in 0.16 s")
        XCTAssertEqual(end.cardScale, T.disappearScale, accuracy: 0.005)
        XCTAssertEqual(end.cardApproach, 6, accuracy: 0.1)
        XCTAssertFalse(frames.last!.cardVisible)
    }

    // MARK: - C.3 the move

    func test_cardMove_retargetKeepsVelocity() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose(x: 100, top: 600))
        _ = run(m, 1.0)
        m.moveCard(to: pose(x: 400, top: 500), delay: 0)
        var xs = run(m, 0.15).map(\.cardX)
        // Retarget mid-flight (a second completion arrives).
        m.moveCard(to: pose(x: 250, top: 300), delay: 0)
        xs += run(m, 0.6).map(\.cardX)
        let v = zip(xs.dropFirst(), xs).map { ($0 - $1) / dt }
        let k = Int((0.15 / dt).rounded())
        XCTAssertGreaterThan(abs(v[k - 2]), 100, "the card really was moving at the retarget")
        // A spring retarget changes the FORCE at once (that is physics), never the speed:
        // the first frame after it is still moving at about the speed it had.
        XCTAssertGreaterThan(v[k], v[k - 1] * 0.3, "velocity is kept across the retarget (a restart would read 0)")
        XCTAssertLessThan(abs(v[k] - v[k - 1]), abs(v[k - 1]) * 0.8)
        let jumps = zip(xs.dropFirst(), xs).map { abs($0 - $1) }
        XCTAssertLessThan(jumps.max()!, 40, "no teleport")
    }

    func test_cardMove_reachesItsTarget_heightSpringsAHundredMillisecondsLater() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose(x: 100, top: 600, h: 200))
        _ = run(m, 1.0)
        m.moveCard(to: pose(x: 300, top: 500, h: 280), delay: 0.04)
        let frames = run(m, 2.0)
        let t = { (s: Double) in frames[Int((s / self.dt).rounded()) - 1] }
        XCTAssertEqual(t(0.03).cardX, 100, accuracy: 0.01, "the move starts 40 ms in")
        XCTAssertEqual(t(0.10).cardHeight, 200, accuracy: 0.01, "the height waits 100 ms more (delay + 0.1)")
        XCTAssertGreaterThan(t(0.40).cardHeight, 210)
        XCTAssertEqual(frames.last!.cardX, 300, accuracy: 0.01)
        XCTAssertEqual(frames.last!.cardTop, 500, accuracy: 0.01)
        XCTAssertEqual(frames.last!.cardHeight, 280, accuracy: 0.01)
    }

    func test_beakReaim_acrossThePanel_shrinksToNothingThenGrowsOnTheOtherSide() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose(side: .right))
        _ = run(m, 1.0)
        m.moveCard(to: pose(x: 500, side: .left), delay: 0)
        let frames = run(m, 0.6)
        let scales = frames.map(\.beakScale)
        guard let idx = frames.firstIndex(where: { $0.cardBeakSide == .left }) else { return XCTFail("the beak never changed side") }
        XCTAssertEqual(scales[idx], 0, accuracy: 0.02, "the side changes while the beak is invisible")
        XCTAssertEqual(frames[idx - 1].cardBeakSide, .right)
        XCTAssertEqual(scales.last!, 1, accuracy: 0.001)
        XCTAssertLessThan(scales.min()!, 0.02)
        XCTAssertEqual(Double(idx) * dt, T.beakSwapAt, accuracy: 0.05, "swap at ~120 ms")
    }

    func test_beakOffset_springsToTheNewAnchorHeight() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose(beak: 40))
        _ = run(m, 1.0)
        m.moveCard(to: pose(beak: 120), delay: 0)
        let last = run(m, 1.5).last!
        XCTAssertEqual(last.cardBeakOffset, 120, accuracy: 0.01)
    }

    func test_quietSwap_contentFadesOutInFourteenHundredthsThenStaggersBackIn() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose())
        _ = run(m, 1.0)
        m.fadeContentOut()
        let out = run(m, 0.2)
        XCTAssertEqual(out[Int((0.16 / dt).rounded()) - 1].contentOpacity, [0, 0, 0].map { $0 }, accuracy: 0.01, "faded out by ~0.14 s")
        m.staggerContentIn()
        let back = run(m, 0.5)
        XCTAssertEqual(back.last!.contentOpacity, [1, 1, 1].map { $0 }, accuracy: 0.001)
        XCTAssertLessThan(back[3].contentOpacity[2], back[3].contentOpacity[0], "40 ms apart")
    }

    // MARK: - C.4.1 the ring

    func test_ring_easesInFromEightyFivePercent_thenRestsSolid() {
        let m = TourGuidanceMotion()
        m.showRing(geo(300, 300), mode: .pressNow)
        let f0 = m.makeFrame()
        XCTAssertEqual(f0.ringScale, T.ringAppearScale, accuracy: 1e-9)
        XCTAssertEqual(f0.ringOpacity, 0, accuracy: 1e-9)
        XCTAssertFalse(f0.ringDashed)
        let frames = run(m, 12)
        XCTAssertEqual(frames[Int(0.25 / dt)].ringOpacity, 1, accuracy: 0.02, "opacity fades in over 0.2 s")
        XCTAssertEqual(frames[Int(1.0 / dt)].ringScale, 1, accuracy: 0.01)
        XCTAssertEqual(frames.last!.ringOpacity, 1, accuracy: 1e-6, "at rest: clearly visible, fully opaque")
        XCTAssertEqual(frames.last!.ringScale, 1, accuracy: 1e-6)
    }

    func test_ring_hintIsDashedAndSeventyPercent() {
        let m = TourGuidanceMotion()
        m.showRing(geo(300, 300), mode: .hint)
        let last = run(m, 12).last!
        XCTAssertTrue(last.ringDashed)
        XCTAssertEqual(last.ringOpacity, 0.7, accuracy: 1e-6, "rests at 0.7, not invisible")
    }

    func test_ring_pulsesThreeTimesThenRests() {
        let m = TourGuidanceMotion()
        m.showRing(geo(300, 300), mode: .pressNow)
        let frames = run(m, 13)
        var births = 0
        var previous = 0
        var peakBreath = 0.0
        for f in frames {
            if f.ripples.count > previous { births += f.ripples.count - previous }
            previous = f.ripples.count
            peakBreath = max(peakBreath, f.breath)
        }
        XCTAssertEqual(births, 3, "three sonar pulses, then it rests")
        XCTAssertGreaterThan(peakBreath, 0.95)
        // The pulses start soon after the ring has landed, not seconds later.
        let first = frames.firstIndex { !$0.ripples.isEmpty }!
        XCTAssertEqual(Double(first) * dt, T.breathDelay, accuracy: 0.1)
        // Rest state: no breath, no ripples, ring still fully there.
        let end = frames.last!
        XCTAssertEqual(end.breath, 0)
        XCTAssertTrue(end.ripples.isEmpty)
        XCTAssertEqual(end.ringOpacity, 1, accuracy: 1e-6)
    }

    func test_ripple_isTheFounderCue_expandsToOnePointThreeFive_fadesFromHalf_overOnePointSixSeconds() {
        XCTAssertEqual(T.rippleDuration, 1.6)
        XCTAssertEqual(T.rippleScale, 0.35, accuracy: 1e-9)
        XCTAssertEqual(T.rippleAlpha, 0.5, accuracy: 1e-9)
        // ease-out: most of the growth happens early.
        let early = TourFeedbackEase.out.value(0.25)
        XCTAssertGreaterThan(early, 0.4)
        XCTAssertEqual(TourFeedbackEase.out.value(1), 1)
    }

    func test_ring_jumpsToTheNextControlOnASpring_thenPulsesAgain() {
        let m = TourGuidanceMotion()
        m.showRing(geo(300, 300), mode: .pressNow)
        _ = run(m, 12)                                   // rested
        m.showRing(TourRingGeometry(cx: 500, cy: 400, w: 82, h: 42, corner: 21), mode: .pressNow)
        let frames = run(m, 3.0)
        let xs = frames.map { $0.ring.cx }
        XCTAssertGreaterThan(xs[3], 300, "moving")
        XCTAssertLessThan(xs[3], 500, "not there yet: a spring, not a teleport")
        XCTAssertEqual(xs.last!, 500, accuracy: 0.01)
        XCTAssertEqual(frames.last!.ring.w, 82, accuracy: 0.01, "the shape changes with the jump (circle -> capsule)")
        XCTAssertEqual(frames.last!.ring.h, 42, accuracy: 0.01)
        XCTAssertTrue(frames.contains { !$0.ripples.isEmpty }, "and it pulses again after landing")
    }

    func test_ring_retargetFollowsWithoutRestartingThePulse() {
        let m = TourGuidanceMotion()
        m.showRing(geo(300, 300), mode: .pressNow)
        _ = run(m, 12)
        m.retargetRing(geo(320, 300))
        let frames = run(m, 1.0)
        XCTAssertTrue(frames.allSatisfy { $0.ripples.isEmpty }, "the panel moved: follow, do not re-announce")
        XCTAssertEqual(frames.last!.ring.cx, 320, accuracy: 0.01)
    }

    func test_ring_enteringPressNow_givesOnePulse() {
        let m = TourGuidanceMotion()
        m.showRing(geo(300, 300), mode: .hint)
        _ = run(m, 12)
        m.setRingMode(.pressNow)
        let frames = run(m, 1.0)
        XCTAssertGreaterThan(frames.map(\.ringPulse).max()!, 1.10, "1 -> 1.14")
        XCTAssertEqual(frames.last!.ringPulse, 1, accuracy: 0.001)
        XCTAssertFalse(frames.last!.ringDashed)
        XCTAssertEqual(frames.last!.ringOpacity, 1, accuracy: 0.01)
    }

    func test_ring_hides_inFourteenHundredths() {
        let m = TourGuidanceMotion()
        m.showRing(geo(300, 300), mode: .pressNow)
        _ = run(m, 1)
        m.hideRing()
        let frames = run(m, 0.2)
        XCTAssertEqual(frames[Int((0.16 / dt).rounded()) - 1].ringOpacity, 0, accuracy: 0.01, "gone by ~0.14 s")
        XCTAssertFalse(frames.last!.ringVisible)
    }

    // MARK: - C.4.2 ghost cursor + glow

    func test_ghostCursor_floatsFromTheBeakTip_twice_andStopsTheSameFrameAsTheHint() {
        let m = TourGuidanceMotion()
        let p = pose(x: 100, top: 600, side: .right, beak: 60)
        m.presentCard(at: p)
        m.showRing(geo(500, 300), mode: .hint)
        let target = CGPoint(x: 480, y: 250)
        m.startHover(target: target)
        let frames = run(m, 8)
        let visible = frames.enumerated().filter { $0.element.ghostVisible }
        XCTAssertFalse(visible.isEmpty)
        XCTAssertEqual(Double(visible.first!.offset) * dt, T.ghostDelay, accuracy: 0.05, "starts 0.6 s after the ring")
        XCTAssertGreaterThan(Double(visible.last!.offset) * dt, 7.0)
        XCTAssertLessThan(Double(visible.last!.offset) * dt, 7.5, "two 3.4 s cycles after the 0.6 s wait, then gone")
        // At the start of its move it sits on the beak tip; at the end on the target.
        let tip = p.beakTip
        let early = frames[Int((T.ghostDelay + 0.26) / dt)]
        XCTAssertEqual(early.ghost.x, tip.x, accuracy: 6)
        XCTAssertEqual(early.ghost.y, tip.y, accuracy: 6)
        let parked = frames[Int((T.ghostDelay + 1.3) / dt)]
        XCTAssertEqual(parked.ghost.x, target.x, accuracy: 1)
        XCTAssertEqual(parked.ghost.y, target.y, accuracy: 1)
        XCTAssertNotNil(parked.ghostRipple, "the ripple says: this is where it stops")
        // Two peaks of the glow.
        XCTAssertGreaterThan(frames.map(\.panelGlow).max()!, 0.95)

        let m2 = TourGuidanceMotion()
        m2.presentCard(at: p); m2.startHover(target: target)
        _ = run(m2, 2)
        XCTAssertTrue(m2.makeFrame().ghostVisible || m2.makeFrame().panelGlow > 0)
        m2.stopHint()
        let f = m2.makeFrame()
        XCTAssertFalse(f.ghostVisible, "mouse on the panel: the ghost is gone in the same frame")
        XCTAssertEqual(f.panelGlow, 0)
        XCTAssertFalse(m2.hintRunning)
    }

    func test_gestureGlow_breathesThreeTimesAndStops() {
        let m = TourGuidanceMotion()
        m.startGestureGlow()
        let frames = run(m, 9)
        var peaks = 0
        for i in 1..<(frames.count - 1) where frames[i].panelGlow > 0.99 && frames[i].panelGlow >= frames[i - 1].panelGlow && frames[i].panelGlow > frames[i + 1].panelGlow { peaks += 1 }
        XCTAssertEqual(peaks, 3)
        XCTAssertEqual(frames.last!.panelGlow, 0)
        XCTAssertFalse(frames.last!.ghostVisible, "no ghost for the gesture step")
    }

    // MARK: - C.7 Reduce Motion

    func test_reduceMotion_noScale_noPulse_noGhost() {
        let m = TourGuidanceMotion(reduceMotion: true)
        m.presentCard(at: pose())
        m.showRing(geo(300, 300), mode: .pressNow)
        m.startHover(target: CGPoint(x: 1, y: 1))
        let frames = run(m, 3)
        XCTAssertTrue(frames.allSatisfy { $0.cardScale == 1 && $0.cardApproach == 0 && $0.ringScale == 1 && $0.ringPulse == 1 })
        XCTAssertTrue(frames.allSatisfy { $0.ripples.isEmpty && $0.breath == 0 && !$0.ghostVisible && $0.panelGlow == 0 })
        XCTAssertEqual(frames.last!.ringOpacity, 1, accuracy: 1e-6, "a static, clearly visible ring")
        XCTAssertEqual(frames.last!.cardOpacity, 1, accuracy: 1e-6)
        let mid = Int((0.08 / dt).rounded()) - 1
        XCTAssertEqual(frames[mid].cardOpacity, 0.5, accuracy: 0.1, "a plain 0.16 s linear fade")
    }

    func test_reduceMotion_moveIsFadeOut_jump_fadeIn() {
        let m = TourGuidanceMotion(reduceMotion: true)
        m.presentCard(at: pose(x: 100))
        _ = run(m, 1)
        m.moveCard(to: pose(x: 400, side: .left), delay: 0)
        let frames = run(m, 0.6)
        XCTAssertEqual(frames.first!.cardX, 100, "no travel")
        let jumped = frames.firstIndex { $0.cardX == 400 }!
        XCTAssertLessThan(frames[jumped].cardOpacity, 0.05, "the jump happens while invisible")
        XCTAssertEqual(frames[jumped].beakScale, 1, "and the beak just swaps sides")
        XCTAssertEqual(frames.last!.cardOpacity, 1, accuracy: 0.01)
    }

    // MARK: - C.8 zero idle cost

    func test_everythingRests_thenNothingIsAnimating() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose())
        m.showRing(geo(300, 300), mode: .pressNow)
        m.startHover(target: CGPoint(x: 1, y: 1))
        XCTAssertTrue(m.isAnimating)
        _ = run(m, 14)
        XCTAssertFalse(m.isAnimating, "no ticker needed once every value and every pulse is done")
    }

    func test_pulsesAreBounded_evenOverAVeryLongSession() {
        let m = TourGuidanceMotion()
        m.showRing(geo(300, 300), mode: .pressNow)
        let frames = run(m, 60)
        XCTAssertEqual(frames.filter { !$0.ripples.isEmpty }.count > 0, true)
        XCTAssertTrue(frames.suffix(Int(40 / dt)).allSatisfy { $0.ripples.isEmpty && $0.breath == 0 })
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, message, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, message, file: file, line: line) }
}
