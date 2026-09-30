/**
 * [INPUT]: MusicMiniPlayerAppKit's TourGuidanceMotion; frame samples read from the running motion
 *          prototype (docs/design/2026-09-29-motion-prototype/prototype.html section C, driven with
 *          `__proto.resetC()` / `__proto.userDid('start')` / `__proto.advance(1/60)` and read from
 *          `__proto.CV` / `__proto.Q` / the halo and ghost-cursor elements).
 * [OUTPUT]: TourGuidanceMotionParityTests — the Swift motion against the prototype, frame by frame.
 * [POS]: Tests. The numbers below are the prototype's own, not derived: sampled at 60 Hz frame indices
 *        from the moment each animation starts. One channel-dependent detail is replicated on purpose:
 *        the prototype starts an animation from a CUE inside a step, so a spring there has already
 *        taken one step at the first sampled frame while a tween has not (springs k+1 steps, tweens k).
 */

import XCTest
import MusicMiniPlayerCore
@testable import MusicMiniPlayerAppKit

final class TourGuidanceMotionParityTests: XCTestCase {
    private let dt = 1.0 / 60
    private let stageHeight = 1000.0    // prototype stage coordinates are y-down; the app's are y-up

    private func steps(_ m: TourGuidanceMotion, _ n: Int) { for _ in 0..<n { m.step(dt) } }

    /// (k, cop, csc, capp) — `cardAppear`, from the first frame after the cue.
    private let cardAppear: [[Double]] = [
        [0, 0, 0.9428, 9.537], [1, 0.4637, 0.9484, 8.603], [2, 0.7496, 0.9553, 7.457], [3, 0.8764, 0.9624, 6.267],
        [4, 0.9379, 0.9692, 5.134], [6, 0.9878, 0.9806, 3.229], [8, 0.9998, 0.9887, 1.878], [12, 1, 0.997, 0.493],
        [16, 1, 0.9996, 0.067], [24, 1, 1.0001, -0.019], [36, 1, 1, -0.001], [48, 1, 1, 0],
    ]

    func test_cardAppear_matchesThePrototypeFrameForFrame() {
        var worst = 0.0
        for row in cardAppear {
            let k = Int(row[0])
            // opacity is a tween (k steps), scale and approach are springs (k+1 steps).
            let m1 = TourGuidanceMotion(); m1.presentCard(at: pose()); steps(m1, k)
            let m2 = TourGuidanceMotion(); m2.presentCard(at: pose()); steps(m2, k + 1)
            let f1 = m1.makeFrame(), f2 = m2.makeFrame()
            for (label, swift, proto) in [("cop", f1.cardOpacity, row[1]), ("csc", f2.cardScale, row[2]), ("capp", f2.cardApproach, row[3])] {
                worst = max(worst, abs(swift - proto))
                XCTAssertEqual(swift, proto, accuracy: 0.01, "card appear k=\(k) \(label)")
            }
        }
        print("[parity] card appear: max |swift - prototype| = \(worst)")
    }

    private func pose() -> TourCardPose {
        // The prototype's S0 card: x 58, top (y-down) 82, h 192, beak 96, 260 wide.
        TourCardPose(x: 58, top: stageHeight - 82, width: 260, height: 192, beakSide: .right, beakOffset: 96)
    }

    /// (k, hop, hsc, rs, ro, g) — the S1 ring in its hint mode, from the frame `haloShow` ran.
    private let ring: [[Double]] = [
        [0, 0, 0.8538, 1, 0, 0], [1, 0.2339, 0.8622, 1, 0, 0], [2, 0.4238, 0.8736, 1, 0, 0], [3, 0.5371, 0.8867, 1, 0, 0],
        [4, 0.6007, 0.9006, 1, 0, 0], [6, 0.6623, 0.9278, 1, 0, 0], [8, 0.6875, 0.9514, 1, 0, 0], [12, 0.7, 0.9838, 1, 0, 0],
        [16, 0.7, 0.9988, 1, 0, 0], [24, 0.7, 1.0032, 1, 0, 0], [30, 0.7, 1.0014, 1.0884, 0.3738, 0.025],
        [36, 0.7, 1.0002, 1.1693, 0.2582, 0.075], [42, 0.7, 1, 1.2293, 0.1724, 0.15], [48, 0.7, 1, 1.2685, 0.1164, 0.25],
        [54, 0.7, 1, 1.2939, 0.0801, 0.375], [60, 0.7, 1, 1.311, 0.0558, 0.5], [72, 0.7, 1, 1.3311, 0.027, 0.75],
        [84, 0.7, 1, 1.3415, 0.0121, 0.925], [96, 0.7, 1, 1.3469, 0.0044, 1], [120, 0.7, 1, 1.35, 0, 0.75],
        [144, 0.7, 1, 1, 0, 0.25], [168, 0.7, 1, 1, 0, 0], [180, 0.7, 1, 1.1693, 0.2582, 0.075],
        [192, 0.7, 1, 1.2685, 0.1164, 0.25], [216, 0.7, 1, 1.3311, 0.027, 0.75], [240, 0.7, 1, 1.3469, 0.0044, 1],
        [264, 0.7, 1, 1, 0, 0.75], [288, 0.7, 1, 1, 0, 0.25], [312, 0.7, 1, 1, 0.5, 0], [336, 0.7, 1, 1.2685, 0.1164, 0.25],
        [360, 0.7, 1, 1.3311, 0.027, 0.75], [384, 0.7, 1, 1.3469, 0.0044, 1], [408, 0.7, 1, 1, 0, 0.75],
        [432, 0.7, 1, 1, 0, 0.25], [456, 0.7, 1, 1, 0, 0], [480, 0.7, 1, 1, 0, 0], [504, 0.7, 1, 1, 0, 0],
        [552, 0.7, 1, 1, 0, 0], [600, 0.7, 1, 1, 0, 0],
    ]

    func test_ring_appearAndSoftPulse_matchThePrototypeFrameForFrame() {
        var worst = 0.0
        for row in ring {
            let k = Int(row[0])
            let tw = TourGuidanceMotion(); tw.showRing(TourRingGeometry(cx: 459, cy: stageHeight - 289, w: 40, h: 40, corner: 20), mode: .hint); steps(tw, k)
            let sp = TourGuidanceMotion(); sp.showRing(TourRingGeometry(cx: 459, cy: stageHeight - 289, w: 40, h: 40, corner: 20), mode: .hint); steps(sp, k + 1)
            let ft = tw.makeFrame(), fs = sp.makeFrame()
            // The pulse is clocked by B.now (k steps), like a tween.
            let e = ft.ripples.first.map { TourFeedbackEase.out.value($0) }
            let rs = e.map { 1 + 0.35 * $0 } ?? 1
            let ro = e.map { 0.5 * (1 - $0) } ?? 0
            var checks: [(String, Double, Double)] = [("hop", ft.ringOpacity, row[1]), ("hsc", fs.ringScale, row[2]), ("g", ft.breath, row[5])]
            // (Exactly on a ripple's first frame the prototype's float comparison flips between "not yet" and "0.5".)
            if ![24, 168, 312].contains(k) { checks.append(("ro", ro, row[4])) }
            if row[4] > 0.001 { checks.append(("rs", rs, row[3])) }
            for (label, swift, proto) in checks {
                worst = max(worst, abs(swift - proto))
                XCTAssertEqual(swift, proto, accuracy: 0.02, "ring k=\(k) \(label)")
            }
        }
        print("[parity] ring appear + pulse: max |swift - prototype| = \(worst)")
    }

    /// (k, cy - 82, ch, bOff) — S0 -> S1 card move, k counted from the first frame the top moved.
    private let cardMove: [[Double]] = [
        [0, 2.595, 192, 96.243], [1, 8.243, 192, 96.755], [2, 15.768, 192, 97.41], [3, 24.292, 192, 98.124],
        [4, 33.178, 192, 98.837], [6, 50.366, 192.533, 100.126], [8, 65.265, 195.045, 101.141], [12, 86.207, 200.662, 102.361],
        [16, 97.197, 204.058, 102.852], [20, 102.058, 205.498, 103], [24, 103.827, 205.956, 103.025],
        [30, 104.306, 206.046, 103.013], [36, 104.179, 206.019, 103.003], [48, 104.015, 206, 103], [60, 103.999, 206, 103],
    ]

    func test_cardMove_matchesThePrototypeFrameForFrame() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose())
        m.advance(by: 1.0)
        let from = m.makeFrame()
        var target = pose(); target.top = stageHeight - 186; target.height = 206; target.beakOffset = 103
        m.moveCard(to: target, delay: 0.04)
        // First frame the top has moved.
        var first = 0
        var frames: [TourGuidanceFrame] = []
        for i in 0..<120 { m.step(dt); frames.append(m.makeFrame()); if first == 0, abs(frames[i].cardTop - from.cardTop) > 1e-9 { first = i } }
        var worst = 0.0
        for row in cardMove {
            let f = frames[first + Int(row[0])]
            for (label, swift, proto) in [("cy", from.cardTop - f.cardTop, row[1]), ("ch", f.cardHeight, row[2]), ("bOff", f.cardBeakOffset, row[3])] {
                worst = max(worst, abs(swift - proto))
                XCTAssertEqual(swift, proto, accuracy: 0.25, "card move k=\(row[0]) \(label)")
            }
        }
        print("[parity] card move: max |swift - prototype| = \(worst) pt")
    }

    /// (offset from the first visible ghost frame, opacity, x, y) in the prototype's y-down stage coordinates.
    private let ghost: [[Double]] = [
        [4, 0.383, 318, 289], [16, 0.92, 318.4, 288.7], [28, 0.92, 341.1, 272.1], [40, 0.92, 395.7, 242.6],
        [52, 0.92, 453.7, 227.4], [64, 0.92, 482.2, 226], [76, 0.92, 484, 226], [112, 0.92, 484, 226],
        [124, 0.818, 484, 226], [136, 0.204, 484, 226], [148, 0, 484, 226],
    ]

    func test_ghostCursor_matchesThePrototypeFrameForFrame() {
        var settled = pose()
        settled.top = stageHeight - 186; settled.height = 206; settled.beakOffset = 103
        var worst = 0.0
        for row in ghost {
            let m = TourGuidanceMotion()
            m.presentCard(at: settled)
            m.advance(by: 1.0)
            m.startHover(target: CGPoint(x: 484, y: stageHeight - 226))
            // The prototype's ghost clock starts 0.6 s after the ring; its first visible frame is offset 0
            // = ring frame 37 (opacity is a tween: u = k / 60 - 0.6).
            steps(m, 37 + Int(row[0]))
            let f = m.makeFrame()
            let x = f.ghost.x, y = stageHeight - f.ghost.y
            worst = max(worst, abs(f.ghostOpacity - row[1]), abs(x - row[2]), abs(y - row[3]))
            XCTAssertEqual(f.ghostOpacity, row[1], accuracy: 0.03, "ghost +\(row[0]) opacity")
            XCTAssertEqual(x, row[2], accuracy: 0.6, "ghost +\(row[0]) x")
            XCTAssertEqual(y, row[3], accuracy: 0.6, "ghost +\(row[0]) y")
        }
        print("[parity] ghost cursor: max deviation = \(worst)")
    }
}
