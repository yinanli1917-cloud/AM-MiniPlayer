/**
 * [INPUT]: TourCornerGuide (pure), TourGestureMotion, TourRealPanelFixture (real panel + tour windows).
 * [OUTPUT]: TourCornerGuideTests — the trackpad demo in the card and the emphasised snap-target mark on screen agree
 *           (corner beat toward the nearest unvisited corner, diagonal beat toward the opposite one):
 *           the demo's direction is the normalized panel -> target vector for all four start corners and both corner beats,
 *           it points at the nearest edge on the edge beat, it flips with natural scrolling off, and the emphasised mark is
 *           the demo's target.
 * [POS]: Tests. Pure value tests first, then the real panel/controller.
 */

import XCTest
import AppKit
import MusicMiniPlayerCore
@testable import MusicMiniPlayerAppKit

final class TourCornerGuideValueTests: XCTestCase {
    private typealias M = TourGestureMotion
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 860)
    private var frames: [ScreenCorner: CGRect] { TourCornerMatch.landingFrames(frameSize: CGSize(width: 250, height: 284), visibleFrame: visible, margin: 16) }
    private func center(_ c: ScreenCorner) -> CGPoint { CGPoint(x: frames[c]!.midX, y: frames[c]!.midY) }

    private func unit(_ v: (dx: CGFloat, dy: CGFloat)) -> (CGFloat, CGFloat) {
        let l = hypot(v.dx, v.dy); return (v.dx / l, v.dy / l)
    }

    func test_theTargetIsTheNearestCornerNotVisitedYet_forEveryStart() {
        for start in ScreenCorner.allCases {
            let first = TourCornerGuide.target(from: start, visited: [start], frames: frames)
            let f = try! XCTUnwrap(first)
            XCTAssertNotEqual(f, start)
            for other in ScreenCorner.allCases where other != start && other != f {
                let df = hypot(center(start).x - center(f).x, center(start).y - center(f).y)
                let dOther = hypot(center(start).x - center(other).x, center(start).y - center(other).y)
                XCTAssertLessThanOrEqual(df, dOther + 0.001, "\(start): \(f) is nearer than \(other)")
            }
            // The second suggestion: nearest to where the panel IS NOW (the first landing), not yet visited.
            let second = try! XCTUnwrap(TourCornerGuide.target(from: f, visited: [start, f], frames: frames))
            XCTAssertFalse([start, f].contains(second), "\(start) -> \(f) -> \(second)")
            for other in ScreenCorner.allCases where ![start, f, second].contains(other) {
                XCTAssertLessThanOrEqual(hypot(center(f).x - center(second).x, center(f).y - center(second).y),
                                         hypot(center(f).x - center(other).x, center(f).y - center(other).y) + 0.001)
            }
        }
    }

    func test_theDemoPointsAlongPanelToTarget_forEveryStartAndBothCornerBeats() {
        for start in ScreenCorner.allCases {
            var visited: Set<ScreenCorner> = [start]
            var current = start
            for beat in 1...2 {
                let target = try! XCTUnwrap(TourCornerGuide.target(from: current, visited: visited, frames: frames))
                let panelHeading = try! XCTUnwrap(TourCornerGuide.heading(from: center(current), to: center(target)))
                let finger = TourCornerGuide.fingerHeading(panelHeading: panelHeading, naturalScrolling: true)
                let kind = TourGestureKind.nudgeToCorner(TourGestureHeading(finger))
                let d = unit(M.displacement(kind))
                // Natural scrolling: the dots move the way the panel will (view space is y down, screen is y up).
                XCTAssertEqual(d.0, panelHeading.dx, accuracy: 0.001, "\(start) beat \(beat) x")
                XCTAssertEqual(d.1, -panelHeading.dy, accuracy: 0.001, "\(start) beat \(beat) y")
                // The trail lies behind the dots: along the same axis, shifted the other way.
                let trail = M.trail(kind: kind, elapsed: 1.275, reduceMotion: false)
                XCTAssertLessThan(trail.shift, 0)
                XCTAssertEqual(cos(trail.angleDegrees * .pi / 180), d.0, accuracy: 0.001)
                XCTAssertEqual(sin(trail.angleDegrees * .pi / 180), d.1, accuracy: 0.001)
                visited.insert(target); current = target
            }
        }
    }

    /// Any ordered pair, adjacent or diagonal: the demo is a free 2D vector along panel -> target.
    func test_theDemoIsAFree2DVector_allTwelveStartTargetPairs() {
        var diagonals = 0
        for start in ScreenCorner.allCases {
            for target in ScreenCorner.allCases where target != start {
                let ph = try! XCTUnwrap(TourCornerGuide.heading(from: center(start), to: center(target)))
                let kind = TourGestureKind.nudgeToCorner(TourGestureHeading(TourCornerGuide.fingerHeading(panelHeading: ph, naturalScrolling: true)))
                let d = unit(M.displacement(kind))
                XCTAssertEqual(d.0, ph.dx, accuracy: 0.001, "\(start)->\(target)")
                XCTAssertEqual(d.1, -ph.dy, accuracy: 0.001, "\(start)->\(target)")
                if abs(ph.dx) > 0.2 && abs(ph.dy) > 0.2 { diagonals += 1 }
            }
        }
        XCTAssertEqual(diagonals, 4, "the four diagonal pairs slide diagonally")
    }

    func test_theDemoPathStaysInsideThePad() {
        for start in ScreenCorner.allCases {
            for target in ScreenCorner.allCases where target != start {
                let ph = TourCornerGuide.heading(from: center(start), to: center(target))!
                let kind = TourGestureKind.nudgeToCorner(TourGestureHeading(TourCornerGuide.fingerHeading(panelHeading: ph, naturalScrolling: true)))
                let c = M.dotCenters(kind), d = M.displacement(kind)
                for p in [c.a, c.b, CGPoint(x: c.a.x + d.dx / M.scale, y: c.a.y + d.dy / M.scale), CGPoint(x: c.b.x + d.dx / M.scale, y: c.b.y + d.dy / M.scale)] {
                    XCTAssertTrue(CGRect(origin: .zero, size: M.padSize).insetBy(dx: 5, dy: 5).contains(p), "\(start)->\(target) \(p)")
                }
            }
        }
    }

    func test_theDirectionFlipsWhenNaturalScrollingIsOff() {
        let h = CGVector(dx: 0.6, dy: -0.8)       // the panel travels right and down (screen y up)
        let natural = TourCornerGuide.fingerHeading(panelHeading: h, naturalScrolling: true)
        let inverted = TourCornerGuide.fingerHeading(panelHeading: h, naturalScrolling: false)
        XCTAssertEqual(natural.dx, 0.6, accuracy: 1e-9); XCTAssertEqual(natural.dy, 0.8, accuracy: 1e-9)
        XCTAssertEqual(inverted.dx, -natural.dx, accuracy: 1e-9); XCTAssertEqual(inverted.dy, -natural.dy, accuracy: 1e-9)
        XCTAssertTrue(TourCornerGuide.fingerRightward(panelRightward: true, naturalScrolling: true))
        XCTAssertFalse(TourCornerGuide.fingerRightward(panelRightward: true, naturalScrolling: false))
    }

    func test_theEdgeBeatPointsAtTheNearestEdge() {
        XCTAssertTrue(TourCornerGuide.nearestEdgeIsRight(panelMidX: 1000, visibleMidX: 720))
        XCTAssertFalse(TourCornerGuide.nearestEdgeIsRight(panelMidX: 300, visibleMidX: 720))
        for right in [true, false] {
            let kind = TourGestureKind.swipeToEdge(rightward: TourCornerGuide.fingerRightward(panelRightward: right, naturalScrolling: true))
            XCTAssertEqual(M.displacement(kind).dx > 0, right)
        }
    }

    func test_thePrototypeDiagonalIsUnchanged() {
        XCTAssertEqual(M.dotCenters(.nudgeToCorner()).a.x, 25.5)
        XCTAssertEqual(M.displacement(.nudgeToCorner()).dx, 30 * M.scale, accuracy: 1e-9)
        XCTAssertEqual(M.trail(kind: .nudgeToCorner(), elapsed: 1.275, reduceMotion: false).angleDegrees, 31)
    }
}

@MainActor
final class TourCornerGuideRealPanelTests: XCTestCase {
    private var f: TourRealPanelFixture!
    private let allButMoveAndBack = Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    private func fingerDirection() throws -> (Double, Double) {
        guard case .nudgeToCorner(let h)? = f.controller.debugCardStore?.gestureKind else { XCTFail("no nudge demo"); throw CancellationError() }
        return (h.dx, h.dy)
    }

    func test_theDemoAndTheEmphasisedMarkAgree_fromEveryStartCorner_andFlipWithScrollDirection() throws {
        for start in ScreenCorner.allCases {
            f = TourRealPanelFixture(corner: start, page: .album)
            f.controller.send(.resume(completed: allButMoveAndBack))
            XCTAssertTrue(f.wait { f.cardWindow != nil }, "\(start)")
            f.spin(1.2)
            let marks = f.controller.debugSnapMarks
            let target = try XCTUnwrap(marks.target, "\(start): one mark is emphasised")
            XCTAssertNotEqual(ScreenCorner.allCases[target], start)
            let rect = marks.rects[target]
            let panel = f.panel.frame
            let v = CGVector(dx: rect.midX - panel.midX, dy: rect.midY - panel.midY)
            let l = hypot(v.dx, v.dy)
            let (dx, dy) = try fingerDirection()
            XCTAssertEqual(dx, v.dx / l, accuracy: 0.002, "\(start): the dots go where the panel will (x)")
            XCTAssertEqual(dy, -v.dy / l, accuracy: 0.002, "\(start): (y, view space is y down)")
            // Natural scrolling off: the same target, the fingers go the other way.
            f.controller.naturalScrollingProvider = { false }
            f.controller.debugRefreshCard()
            f.spin(0.4)
            let (ix, iy) = try fingerDirection()
            XCTAssertEqual(ix, -dx, accuracy: 0.002); XCTAssertEqual(iy, -dy, accuracy: 0.002)
            XCTAssertEqual(f.controller.debugSnapMarks.target, target, "the mark does not depend on the scroll setting")
            f.tearDown(); f = nil
        }
    }

    /// The user heads somewhere other than the suggestion (any of the other three corners, adjacent or diagonal): it ticks,
    /// nobody is scolded, and the guidance moves on to the DIAGONAL beat: the demo and the emphasised mark now point at the
    /// corner opposite the one the panel landed in.
    func test_landingAnywhere_ticks_andTheGuidanceMovesOnToTheOppositeCorner_allTwelvePairs() throws {
        for start in ScreenCorner.allCases {
            for landing in ScreenCorner.allCases where landing != start {
                f = TourRealPanelFixture(corner: start, page: .album)
                f.controller.send(.resume(completed: allButMoveAndBack))
                XCTAssertTrue(f.wait { f.cardWindow != nil }, "\(start)")
                f.spin(0.6)
                let suggested = try XCTUnwrap(f.controller.debugSnapMarks.target)
                let frame = try XCTUnwrap(f.panel.cornerLandingFrames()[landing])
                f.panel.setFrameOrigin(frame.origin)
                f.controller.send(.panelSettled(corner: landing))
                f.spin(0.5)
                XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, false, false]), "\(start) -> \(landing) (suggested \(ScreenCorner.allCases[suggested]))")
                let marks = f.controller.debugSnapMarks
                let target = try XCTUnwrap(marks.target, "\(start) -> \(landing): the diagonal's target is emphasised")
                XCTAssertEqual(ScreenCorner.allCases[target], landing.opposite, "\(start) -> \(landing)")
                // The demo points the same way the ghost's path does: panel centre -> the opposite corner's landing frame.
                let rect = marks.rects[target], panel = f.panel.frame
                let v = CGVector(dx: rect.midX - panel.midX, dy: rect.midY - panel.midY)
                let l = hypot(v.dx, v.dy)
                let (dx, dy) = try fingerDirection()
                XCTAssertEqual(dx, v.dx / l, accuracy: 0.002, "\(start) -> \(landing)")
                XCTAssertEqual(dy, -v.dy / l, accuracy: 0.002, "\(start) -> \(landing)")
                f.tearDown(); f = nil
            }
        }
    }

    func test_theEdgeBeat_pointsAtTheNearestEdge_andFlipsWithScrollDirection() throws {
        for (corner, right) in [(ScreenCorner.topLeft, false), (.bottomRight, true)] {
            f = TourRealPanelFixture(corner: corner, page: .album)
            f.controller.send(.resume(completed: allButMoveAndBack))
            XCTAssertTrue(f.wait { f.cardWindow != nil })
            f.spin(0.8)
            let other: ScreenCorner = right ? .bottomLeft : .topRight
            f.controller.send(.panelSettled(corner: other))
            f.spin(0.4)
            // Park the panel in the corner the question is about: the second corner ticks the diagonal beat, the edge is next.
            let landing = try XCTUnwrap(f.panel.cornerLandingFrames()[corner])
            f.panel.setFrameOrigin(landing.origin)
            f.controller.send(.panelSettled(corner: corner))
            f.controller.debugRefreshCard()
            f.spin(0.8)
            guard case .swipeToEdge(let rightward)? = f.controller.debugCardStore?.gestureKind else { return XCTFail("edge demo expected, got \(String(describing: f.controller.debugCardStore?.gestureKind))") }
            XCTAssertEqual(rightward, right, "\(corner)")
            f.controller.naturalScrollingProvider = { false }
            f.controller.debugRefreshCard()
            f.spin(0.8)
            guard case .swipeToEdge(let inverted)? = f.controller.debugCardStore?.gestureKind else { return XCTFail() }
            XCTAssertEqual(inverted, !right, "\(corner): inverted scrolling flips the fingers")
            f.tearDown(); f = nil
        }
    }
}
