/**
 * [INPUT]: TourCornerGuide / TourMoveSuggestion (pure), TourPanelGhostMotion, TourGestureMotion, TourGuidanceMotion (fake clock),
 *          TourRealPanelFixture (real panel + real tour windows), L10n.
 * [OUTPUT]: TourPanelGhostTests — the on-screen demonstration of the move step (2026-10-03): the ghost starts at the panel's frame
 *           and ends exactly on the target landing frame for all four start corners and both corner beats (diagonal included),
 *           slides into the sliver at the edge; it rides the glyph's clock (same direction, same start time, flipped fingers only
 *           when scrolling is inverted); it plays twice, then rests; it stops the moment a two-finger gesture begins; Reduce Motion
 *           draws a static dotted path instead; the ghost window stays panel-sized; the steps run corner -> diagonal -> edge
 *           with per-beat copy (zh and en, no 「甩」).
 * [POS]: Tests. Pure value tests first, then the real panel and windows.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Pure
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TourPanelGhostValueTests: XCTestCase {
    private typealias G = TourPanelGhostMotion
    private typealias M = TourGestureMotion
    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 860)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 250, height: 284)
    private var frames: [ScreenCorner: CGRect] { TourCornerMatch.landingFrames(frameSize: size, visibleFrame: visible, margin: 16) }

    private func suggestion(_ beat: TourMoveBeat, from start: ScreenCorner, visited: Set<ScreenCorner> = []) throws -> TourMoveSuggestion {
        try XCTUnwrap(TourCornerGuide.suggestion(beat: beat, panelFrame: frames[start]!, current: start, visited: visited.union([start]),
                                                 frames: frames, screenFrame: screen, visibleMidX: visible.midX), "\(beat) from \(start)")
    }

    /// The elapsed time (glyph clock) of a frame in cycle 1 where the ghost has just landed.
    private var landed: TimeInterval { G.landedAt + 0.02 }

    func test_theGhostStartsAtThePanelFrame_andLandsExactlyOnTheTargetFrame_allFourStarts_bothCornerBeats() throws {
        for start in ScreenCorner.allCases {
            for beat in [TourMoveBeat.corner, .diagonal] {
                let move = try suggestion(beat, from: start)
                let target = try XCTUnwrap(move.targetCorner)
                XCTAssertNotEqual(target, start)
                if beat == .diagonal { XCTAssertEqual(target, start.opposite, "\(start): the diagonal beat goes to the opposite corner") }
                XCTAssertEqual(move.to, frames[target], "\(start) \(beat): the path ends on the real landing frame")
                XCTAssertEqual(move.from, frames[start])
                // Before the glide it sits on the panel; after it, exactly on the landing frame.
                for t in [G.fadeInDuration, G.glideStart - 0.01] {
                    XCTAssertEqual(G.visual(path: move, elapsed: t, reduceMotion: false).rect, move.from, "\(start) \(beat) t=\(t)")
                }
                let end = G.visual(path: move, elapsed: landed, reduceMotion: false)
                XCTAssertEqual(end.rect, move.to, "\(start) \(beat)")
                XCTAssertEqual(end.rect.size, size, "the corner beats keep the panel's size all the way")
                XCTAssertEqual(end.opacity, 1, accuracy: 1e-9, "it holds before it fades")
                // Mid-glide it is strictly between, on the straight line.
                let mid = G.visual(path: move, elapsed: G.glideStart + 0.25, reduceMotion: false).rect
                XCTAssertNotEqual(mid, move.from); XCTAssertNotEqual(mid, move.to)
            }
        }
    }

    func test_theEdgeBeat_slidesIntoTheNearestEdge_andShrinksToTheSliver() throws {
        for (start, right) in [(ScreenCorner.topLeft, false), (.bottomRight, true), (.topRight, true), (.bottomLeft, false)] {
            let move = try suggestion(.edge, from: start)
            XCTAssertEqual(move.edgeIsRight, right)
            XCTAssertNil(move.targetCorner)
            XCTAssertEqual(move.to.size, LiquidEdgeTokens.sliverSize)
            XCTAssertEqual(right ? move.to.maxX : move.to.minX, right ? screen.maxX : screen.minX, "the sliver is joined to the bezel")
            XCTAssertEqual(move.to.midY, move.from.midY, accuracy: 1e-9, "it slides straight in")
            XCTAssertEqual(G.visual(path: move, elapsed: landed, reduceMotion: false).rect, move.to, "\(start)")
            var shrinking = false, t = G.glideStart
            while t < G.landedAt {
                let w = G.visual(path: move, elapsed: t, reduceMotion: false).rect.width
                if w < move.from.width - 1, w > move.to.width + 1 { shrinking = true }
                t += 0.005
            }
            XCTAssertTrue(shrinking, "\(start): it passes through sizes between the panel's and the sliver's")
            XCTAssertEqual(G.visual(path: move, elapsed: landed, reduceMotion: false).cornerRadius, LiquidEdgeTokens.sliverSize.width / 2, accuracy: 1e-9)
        }
    }

    func test_theGhostFadesInHoldsLandsHoldsFadesOut_andPlaysTwiceThenRests() throws {
        let move = try suggestion(.corner, from: .topRight)
        func v(_ t: TimeInterval) -> TourPanelGhostVisual { G.visual(path: move, elapsed: t, reduceMotion: false) }
        XCTAssertEqual(v(0).opacity, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(v(G.fadeInDuration / 2).opacity, 0.3); XCTAssertLessThan(v(G.fadeInDuration / 2).opacity, 0.7)
        XCTAssertEqual(v(G.glideStart).opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(G.hold, 0.4, accuracy: 1e-9, "it holds about 0.4 s on the target")
        XCTAssertEqual(v(G.landedAt + G.hold - 0.01).opacity, 1, accuracy: 1e-9)
        XCTAssertLessThan(v(G.fadeOutStart + 0.15).opacity, 1); XCTAssertGreaterThan(v(G.fadeOutStart + 0.15).opacity, 0)
        XCTAssertEqual(v(G.fadeOutStart + G.fadeOutDuration + 0.01).opacity, 0, accuracy: 1e-9)
        XCTAssertLessThan(G.fadeOutStart + G.fadeOutDuration, M.cycleDuration, "it is gone before the next cycle begins")
        // The second cycle plays the same thing; the third does not exist.
        XCTAssertEqual(v(M.cycleDuration + landed).rect, move.to)
        XCTAssertEqual(v(M.cycleDuration + landed).opacity, 1, accuracy: 1e-9)
        XCTAssertFalse(v(Double(M.cycles) * M.cycleDuration + 0.1).isDrawn)
        XCTAssertFalse(G.visual(path: move, elapsed: nil, reduceMotion: false).isDrawn, "no glyph clock = no ghost")
        XCTAssertEqual(G.fillOpacity, 0.22, accuracy: 1e-9)
    }

    func test_theGhostRidesTheGlyph_sameDirection_sameStartTime_andOnlyTheFingersFlipWithInvertedScrolling() throws {
        for start in ScreenCorner.allCases {
            for beat in [TourMoveBeat.corner, .diagonal, .edge] {
                let move = try suggestion(beat, from: start)
                for natural in [true, false] {
                    // The ghost travels the PANEL's way (screen, y up); the glyph's fingers travel the panel's way when scrolling is
                    // natural and the opposite way when it is inverted (view space, y down).
                    let ghostMove = CGVector(dx: move.to.midX - move.from.midX, dy: move.to.midY - move.from.midY)
                    let ghostLen = hypot(ghostMove.dx, ghostMove.dy)
                    let kind: TourGestureKind = beat == .edge
                        ? .swipeToEdge(rightward: move.fingerRightward(naturalScrolling: natural))
                        : .nudgeToCorner(TourGestureHeading(move.fingerHeading(naturalScrolling: natural)))
                    let d = M.displacement(kind)
                    let dl = hypot(d.dx, d.dy)
                    let sign: CGFloat = natural ? 1 : -1
                    XCTAssertEqual(d.dx / dl, sign * ghostMove.dx / ghostLen, accuracy: 0.002, "\(start) \(beat) natural=\(natural) x")
                    XCTAssertEqual(d.dy / dl, -sign * ghostMove.dy / ghostLen, accuracy: 0.002, "\(start) \(beat) natural=\(natural) y")
                    // Same start time: the first elapsed at which the glyph's dots move is the first at which the ghost leaves the panel.
                    var glyphStart: TimeInterval?, ghostStart: TimeInterval?
                    var t = 0.0
                    while t < M.cycleDuration, glyphStart == nil || ghostStart == nil {
                        if glyphStart == nil, M.frame(kind: kind, elapsed: t, reduceMotion: false).dx != 0 || M.frame(kind: kind, elapsed: t, reduceMotion: false).dy != 0 { glyphStart = t }
                        if ghostStart == nil, G.visual(path: move, elapsed: t, reduceMotion: false).rect != move.from { ghostStart = t }
                        t += 0.002
                    }
                    let gs = try XCTUnwrap(glyphStart, "\(start) \(beat)"), hs = try XCTUnwrap(ghostStart, "\(start) \(beat)")
                    XCTAssertEqual(gs, hs, accuracy: 0.02, "\(start) \(beat) natural=\(natural): the slide and the glide start together")
                    XCTAssertEqual(gs, G.glideStart, accuracy: 0.02)
                }
            }
        }
    }

    func test_reduceMotion_showsAStaticDottedPath_notAGlide() throws {
        for start in ScreenCorner.allCases {
            for beat in TourMoveBeat.allCases {
                let move = try suggestion(beat, from: start)
                for t in [nil, 0, 1.0, 1.5, 5.0] as [TimeInterval?] {
                    let v = G.visual(path: move, elapsed: t, reduceMotion: true)
                    XCTAssertEqual(v.staticPath, TourGhostStaticPath(from: move.from, to: move.to), "\(start) \(beat) t=\(String(describing: t)): the same picture at every instant")
                    XCTAssertTrue(v.rect.isEmpty, "no ghost body to glide")
                    XCTAssertTrue(v.isDrawn)
                }
                let seg = try XCTUnwrap(TourGhostGeometry.pathSegment(from: move.from, to: move.to), "\(start) \(beat)")
                XCTAssertFalse(move.from.insetBy(dx: 1, dy: 1).contains(seg.a), "the line leaves the panel's border")
                XCTAssertFalse(move.to.insetBy(dx: 1, dy: 1).contains(seg.b), "and stops at the landing frame's border")
                // It runs along panel centre -> target centre.
                let cross = (seg.b.x - seg.a.x) * (move.to.midY - move.from.midY) - (seg.b.y - seg.a.y) * (move.to.midX - move.from.midX)
                XCTAssertEqual(cross, 0, accuracy: 1)
            }
        }
    }

    func test_theGhostWindowStaysPanelSized_themovingKind_andOnlyTheStaticLineIsPathSized() throws {
        let move = try suggestion(.diagonal, from: .topRight)
        let panelArea = size.width * size.height
        for t in stride(from: 0.0, to: 2 * M.cycleDuration, by: 0.05) {
            let v = G.visual(path: move, elapsed: t, reduceMotion: false)
            guard v.isDrawn else { continue }
            let w = TourPanelGhostRegion.windowFrame(for: v)
            XCTAssertLessThan(w.width * w.height, 1.2 * panelArea, "t=\(t): a panel-sized window that moves, never one spanning the path")
            XCTAssertTrue(w.contains(v.rect))
        }
        let edge = try suggestion(.edge, from: .topRight)
        for t in stride(from: 0.0, to: M.cycleDuration, by: 0.05) {
            let v = G.visual(path: edge, elapsed: t, reduceMotion: false)
            if v.isDrawn { let w = TourPanelGhostRegion.windowFrame(for: v); XCTAssertLessThan(w.width * w.height, 1.2 * panelArea, "edge t=\(t)") }
        }
        // The art of a glide at constant size does not change (a glide republishes nothing to SwiftUI).
        let a = TourPanelGhostRegion.art(for: G.visual(path: move, elapsed: G.glideStart + 0.2, reduceMotion: false), window: .zero)
        let b = TourPanelGhostRegion.art(for: G.visual(path: move, elapsed: G.glideStart + 0.4, reduceMotion: false), window: .zero)
        XCTAssertEqual(a, b)
    }

    func test_motion_ghostRidesTheGlyphClock_stopsOnDemand_andReplaysForANewMoveOrAHoverReplay() throws {
        let a = try suggestion(.corner, from: .topRight), b = try suggestion(.diagonal, from: .bottomLeft)
        let m = TourGuidanceMotion(reduceMotion: false)
        m.setGhost(a)
        m.advance(by: 0.5)
        XCTAssertFalse(m.makeFrame().panelGhost.isDrawn, "no glyph on the card = no ghost")
        m.setGlyph(present: true, animated: false)
        m.setGhost(a)
        m.advance(by: 0.12 + G.glideStart + 0.3)
        XCTAssertTrue(m.makeFrame().panelGhost.isDrawn)
        XCTAssertNotEqual(m.makeFrame().panelGhost.rect, a.from, "mid-glide")
        XCTAssertNotNil(m.makeFrame().glyphElapsed, "and the same clock is the glyph's")

        m.stopGhost()
        XCTAssertFalse(m.makeFrame().panelGhost.isDrawn, "stopped at once")
        m.setGhost(a)                                       // same move, refreshed geometry: stays stopped
        m.advance(by: 0.05)
        XCTAssertFalse(m.makeFrame().panelGhost.isDrawn)
        m.setGhost(b)                                       // a DIFFERENT move plays again
        m.setGlyph(present: true, animated: true, restart: true)
        m.advance(by: G.glideStart + 0.3)
        XCTAssertTrue(m.makeFrame().panelGhost.isDrawn)
        m.stopGhost()
        m.replayGlyph()                                     // hovering the glyph replays both
        m.advance(by: G.glideStart + 0.3)
        XCTAssertTrue(m.makeFrame().panelGhost.isDrawn)
        // Two cycles, then it rests.
        m.advance(by: 2 * M.cycleDuration + 1)
        XCTAssertFalse(m.makeFrame().panelGhost.isDrawn)
        XCTAssertFalse(m.isAnimating, "a resting ghost costs nothing")
        // The beat is over: the ghost is gone with the glyph.
        m.setGhost(nil)
        XCTAssertFalse(m.makeFrame().panelGhost.isDrawn)
    }

    func test_motion_reduceMotion_isAStaticPathFromTheStart() throws {
        let a = try suggestion(.corner, from: .topLeft)
        let m = TourGuidanceMotion(reduceMotion: true)
        m.setGlyph(present: true, animated: false)
        m.setGhost(a)
        for _ in 0..<10 {
            m.advance(by: 0.3)
            XCTAssertEqual(m.makeFrame().panelGhost.staticPath, TourGhostStaticPath(from: a.from, to: a.to))
            XCTAssertTrue(m.makeFrame().panelGhost.rect.isEmpty)
        }
        m.stopGhost()
        XCTAssertFalse(m.makeFrame().panelGhost.isDrawn, "a gesture hides the static line too")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Real panel, real windows
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor
final class TourPanelGhostRealPanelTests: XCTestCase {
    private var f: TourRealPanelFixture!
    private let L = { (key: String) in L10n.localized(key) }
    private let allButMoveAndBack = Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    /// Spins until the glyph clock is `seconds` into its cycle (the ghost rides it).
    private func spinToGlyph(_ seconds: Double) {
        let end = Date().addingTimeInterval(10)
        while Date() < end, (f.controller.guidance.lastFrame.glyphElapsed ?? 0) < seconds { f.spin(0.004) }
    }

    private func start(corner: ScreenCorner = .topRight, reduceMotion: Bool = false) {
        f = TourRealPanelFixture(corner: corner, reduceMotion: reduceMotion, page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
    }

    private func land(_ corner: ScreenCorner) throws {
        let landing = try XCTUnwrap(f.panel.cornerLandingFrames()[corner])
        f.panel.setFrameOrigin(landing.origin)
        f.controller.send(.panelSettled(corner: corner))
        f.spin(0.3)
    }

    func test_firstCornerBeat_aGhostGlidesFromThePanelToTheEmphasisedMark_inOneSmallClickThroughWindow() throws {
        start()
        spinToGlyph(1.25)
        let ghost = f.controller.debugGhost
        XCTAssertTrue(ghost.isDrawn)
        let marks = f.controller.debugSnapMarks
        let target = try XCTUnwrap(marks.target)
        XCTAssertNotEqual(ghost.rect, f.panel.frame, "mid-glide")
        let from = f.panel.frame, to = marks.rects[target]
        XCTAssertTrue(ghost.rect.midX >= min(from.midX, to.midX) - 1 && ghost.rect.midX <= max(from.midX, to.midX) + 1)
        XCTAssertTrue(ghost.rect.midY >= min(from.midY, to.midY) - 1 && ghost.rect.midY <= max(from.midY, to.midY) + 1)
        let w = try XCTUnwrap(f.controller.debugGhostWindow)
        XCTAssertTrue(w.isVisible); XCTAssertTrue(w.ignoresMouseEvents, "click-through")
        XCTAssertEqual(w.level, .tourOverlay)
        XCTAssertLessThan(w.frame.width * w.frame.height, 1.2 * f.panel.frame.width * f.panel.frame.height, "panel-sized, not path-sized")
        XCTAssertEqual(w.frame.size, TourPanelGhostRegion.windowFrame(for: ghost).size, "the window is the ghost's rect plus room for its outline")
    }

    func test_theGhostStopsTheMomentATwoFingerGestureBegins_andDoesNotComeBackForTheSameMove() throws {
        start()
        spinToGlyph(1.0)
        XCTAssertTrue(f.controller.debugGhost.isDrawn)
        // The gesture's first moving event is "scroll began" for the panel.
        if let e = f.gestureEvent(dx: 0, dy: 0, phase: .began) { f.panel.sendEvent(e) }
        if let e = f.gestureEvent(dx: -6, dy: 4, phase: .changed) { f.panel.sendEvent(e) }
        XCTAssertFalse(f.controller.debugGhost.isDrawn, "stopped at once")
        f.spin(0.1)
        XCTAssertTrue(f.controller.debugGhostWindow?.isVisible != true, "and its window is off the screen")
        for _ in 0..<8 { if let e = f.gestureEvent(dx: -6, dy: 4, phase: .changed) { f.panel.sendEvent(e) }; f.spin(0.05) }
        XCTAssertFalse(f.controller.debugGhost.isDrawn, "the real panel is being moved; the ghost never competes")
        if let e = f.gestureEvent(dx: 0, dy: 0, phase: .ended) { f.panel.sendEvent(e) }
    }

    func test_cornerThenDiagonalThenEdge_theGhostAndTheCardFollowEachBeat() throws {
        start(corner: .topRight)
        spinToGlyph(0.2)
        // Beat 1: a corner. Copy for it.
        XCTAssertEqual(f.controller.debugCardStore?.model.body, L("tour.move.body"))
        XCTAssertEqual(f.controller.debugCardStore?.model.beats.map(\.id), [0, 1, 2])
        XCTAssertEqual(f.controller.debugCardStore?.model.beats.map(\.text), [L("tour.move.beat1"), L("tour.move.beatDiagonal"), L("tour.move.beat2")])
        let firstTarget = try XCTUnwrap(f.controller.moveSuggestion()?.targetCorner)

        // The panel lands in the bottom left (a new corner): beat 1 ticks, beat 2 is the diagonal, to the OPPOSITE corner.
        try land(.bottomLeft)
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, false, false]))
        f.spin(0.8)
        XCTAssertEqual(f.controller.debugCardStore?.model.body, L("tour.move.bodyDiagonal"), "the copy changes when the beat becomes current")
        let diag = try XCTUnwrap(f.controller.moveSuggestion())
        XCTAssertEqual(diag.beat, .diagonal)
        XCTAssertEqual(diag.targetCorner, .topRight)
        XCTAssertEqual(f.controller.debugSnapMarks.target, ScreenCorner.allCases.firstIndex(of: .topRight), "the emphasised mark is the ghost's target")
        spinToGlyph(1.25)
        let g = f.controller.debugGhost
        XCTAssertTrue(g.isDrawn, "the ghost replays toward the opposite corner")
        XCTAssertNotEqual(g.rect, f.panel.frame)
        let landing = try XCTUnwrap(f.panel.cornerLandingFrames()[.topRight])
        XCTAssertEqual(diag.to, landing)
        _ = firstTarget

        // Landing in the opposite corner: ticks. The edge beat follows, with the ghost sliding into the nearest edge.
        try land(.topRight)
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, true, false]))
        f.spin(0.8)
        let body = try XCTUnwrap(f.controller.debugCardStore?.model.body)
        XCTAssertTrue(body == L("tour.move.bodyTuckRight") || body == L("tour.move.bodyTuckLeft"), "the opposite corner: the 'far corner' acknowledgement; \(body)")
        let edge = try XCTUnwrap(f.controller.moveSuggestion())
        XCTAssertEqual(edge.beat, .edge)
        XCTAssertEqual(edge.to.size, LiquidEdgeTokens.sliverSize)
        spinToGlyph(1.4)
        let e = f.controller.debugGhost
        XCTAssertTrue(e.isDrawn)
        XCTAssertLessThan(e.rect.width, f.panel.frame.width, "the ghost shrinks toward the sliver while it slides into the edge")
        guard case .swipeToEdge? = f.controller.debugCardStore?.gestureKind else { return XCTFail("the glyph swipes to the edge too") }
        XCTAssertNil(f.controller.debugSnapMarks.target)
    }

    func test_theDiagonalBeat_acceptsAnyOtherNewCornerGently_andNotAUsedOne() throws {
        start(corner: .topRight)
        spinToGlyph(0.2)
        try land(.bottomLeft)
        f.spin(0.6)
        // A used corner (the one just landed in): nothing ticks.
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.3)
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, false, false]))
        // Another new corner that is not the opposite one: ticks, with its own gentle acknowledgement.
        try land(.topLeft)
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, true, false]))
        f.spin(0.8)
        let body = try XCTUnwrap(f.controller.debugCardStore?.model.body)
        XCTAssertTrue(body == L("tour.move.bodyTuckOtherRight") || body == L("tour.move.bodyTuckOtherLeft"), body)
        XCTAssertFalse(body.contains("far corner"))
    }

    func test_tuckForMe_stillCompletesTheStep_fromAnyBeat() throws {
        start()
        spinToGlyph(0.2)
        f.controller.send(.panelTucked)
        guard case .step(.back, _) = f.controller.state.phase else { return XCTFail("got \(f.controller.state.phase)") }
        XCTAssertTrue(f.wait(3) { !f.controller.debugGhost.isDrawn })
        XCTAssertTrue(f.wait(2) { f.controller.debugGhostWindow?.isVisible != true })
    }

    func test_reduceMotion_aStaticDottedPathAndTheEmphasisedMark_noGlide() throws {
        start(reduceMotion: true)
        f.spin(1.5)
        let g = f.controller.debugGhost
        let path = try XCTUnwrap(g.staticPath, "a dotted line from the panel to the target")
        XCTAssertEqual(path.from, f.panel.frame)
        let move = try XCTUnwrap(f.controller.moveSuggestion())
        XCTAssertEqual(path.to, move.to)
        XCTAssertTrue(g.rect.isEmpty)
        XCTAssertNotNil(f.controller.debugSnapMarks.target, "the target mark stays emphasised")
        f.spin(1.0)
        XCTAssertEqual(f.controller.debugGhost, g, "nothing moves")
    }

    func test_nonMoveSteps_haveNoGhost() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.lyrics, .translate, .moveTuck, .back])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(2.5)
        XCTAssertFalse(f.controller.debugGhost.isDrawn)
        XCTAssertNil(f.controller.debugGhostWindow)
    }

    func test_copy_zhAndEn_noBannedWord_forEveryBeat() throws {
        for key in ["tour.move.body", "tour.move.bodyDiagonal", "tour.move.bodyTuckRight", "tour.move.bodyTuckLeft", "tour.move.bodyTuckOtherRight",
                    "tour.move.bodyTuckOtherLeft", "tour.move.beat1", "tour.move.beatDiagonal", "tour.move.beat2"] {
            let pair = try XCTUnwrap(L10n.allStrings[key], key)
            XCTAssertFalse(pair.zh.isEmpty); XCTAssertFalse(pair.en.isEmpty)
            XCTAssertFalse(pair.zh.contains("甩"), key); XCTAssertFalse(pair.en.lowercased().contains("fling"), key)
        }
    }
}
