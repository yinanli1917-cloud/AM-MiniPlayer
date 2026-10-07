/**
 * [INPUT]: TourMachine (pure reducer), TourGuidanceResolver, TourGuidanceMotion (fake clock), TourRealPanelFixture
 *          (real panel + real tour windows), L10n.
 * [OUTPUT]: TourSnapMarksTests — the move step's three beats (corner -> across the diagonal -> edge) and the four snap-target
 *           marks (2026-10-03): a landing in a new corner ticks the corner beat, the next new corner (the opposite one, or any
 *           other) ticks the diagonal beat, a corner already used (or the one the panel started in) ticks nothing; completion
 *           order is corner -> diagonal -> edge; the marks show on the corner beats on the cover page only,
 *           sit exactly where the panel lands, fade in and swell once, pulse where the panel arrives, and stay still
 *           under Reduce Motion; the copy exists in zh and en and never uses 「甩」.
 * [POS]: Tests. Pure value tests first, then real windows (the panel is the real SnappablePanel).
 */

import XCTest
import AppKit
import MusicMiniPlayerCore
@testable import MusicMiniPlayerAppKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Machine
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TourCornerBeatsMachineTests: XCTestCase {
    private func moveStep(startingIn corner: ScreenCorner?) -> TourState {
        let snapshot = TourSnapshot(automationAuthorized: true, canTranslate: true, panelCorner: corner)
        let (state, _) = TourMachine.reduce(TourState(), .resume(completed: Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])), snapshot: snapshot)
        return state
    }

    private func settle(_ state: TourState, _ corner: ScreenCorner?) -> (TourState, [TourEffect]) {
        TourMachine.reduce(state, .panelSettled(corner: corner), snapshot: TourSnapshot())
    }

    func test_theMoveStepNeedsThreeMoves_aCorner_theDiagonal_andTheEdge() {
        XCTAssertEqual(TourStep.moveTuck.beatCount, 3)
        XCTAssertEqual(moveStep(startingIn: .topRight).phase, .step(.moveTuck, beats: [false, false, false]))
    }

    func test_aLandingInAnyOtherCorner_adjacentOrDiagonal_ticksTheCornerBeat_allTwelvePairs() {
        for start in ScreenCorner.allCases {
            for landing in ScreenCorner.allCases where landing != start {
                let (state, effects) = settle(moveStep(startingIn: start), landing)
                XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]), "\(start) -> \(landing)")
                XCTAssertTrue(effects.contains(.checkBeat(.moveTuck, index: 0)), "\(start) -> \(landing)")
                XCTAssertEqual(state.cornersLanded, [landing])
            }
        }
    }

    /// The diagonal beat takes only the corner ACROSS the screen from the one the panel was in just before the move
    /// (`moveLastCorner`, which follows every settle). A corner next door ticks nothing (the card is asked to follow the panel),
    /// and the corner it is already in does nothing at all.
    func test_theDiagonalBeat_ticksOnlyTheCornerOppositeTheOneJustLeft() {
        for start in ScreenCorner.allCases {
            for first in ScreenCorner.allCases where first != start {
                let (afterFirst, _) = settle(moveStep(startingIn: start), first)
                for second in ScreenCorner.allCases where second != first {
                    let (state, effects) = settle(afterFirst, second)
                    let label = "\(start) -> \(first) -> \(second)"
                    if second == first.opposite {
                        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, true, false]), label)
                        XCTAssertTrue(effects.contains(.checkBeat(.moveTuck, index: 1)), label)
                        XCTAssertTrue(effects.contains(.relocateCardToPanel), label)
                        XCTAssertEqual(state.cornersLanded, [first, second], label)
                    } else {
                        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]), "next door ticks nothing: \(label)")
                        XCTAssertEqual(effects, [.relocateCardToPanel], "the card follows the panel: \(label)")
                        XCTAssertEqual(state.cornersLanded, [first], label)
                        XCTAssertEqual(state.moveLastCorner, second, "and the panel's new corner is remembered: \(label)")
                    }
                }
                // The corner it is already in: nothing.
                let (same, e) = settle(afterFirst, first)
                XCTAssertEqual(same, afterFirst, "\(start) -> \(first) -> \(first)")
                XCTAssertTrue(e.isEmpty)
            }
        }
    }

    func test_theDiagonalBeat_measuresFromTheLastSettle_notFromTheFirstCorner() {
        var (state, _) = settle(moveStep(startingIn: .topRight), .bottomLeft)
        (state, _) = settle(state, .bottomRight)                 // next door: nothing ticks, the panel now sits bottom right
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]))
        (state, _) = settle(state, .bottomLeft)                  // back next door of it again: still nothing
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]))
        (state, _) = settle(state, .topRight)                    // across from bottom left: ticks
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, true, false]))
    }

    func test_completionOrder_isCorner_thenDiagonal_thenEdge_andTheEdgeCannotJumpTheQueueBySettling() {
        var (state, _) = settle(moveStep(startingIn: .topRight), .bottomLeft)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]))
        (state, _) = settle(state, .topRight)                    // across from bottom left
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, true, false]))
        // A third landing ticks nothing more: the edge beat is the tuck's.
        let (afterThird, effects) = settle(state, .bottomRight)
        XCTAssertEqual(afterThird.phase, .step(.moveTuck, beats: [true, true, false]))
        XCTAssertFalse(effects.contains { if case .checkBeat = $0 { return true }; return false })
        let (after, _) = TourMachine.reduce(afterThird, .panelTucked, snapshot: TourSnapshot())
        XCTAssertEqual(after.stepStates[.moveTuck], .completed)
        guard case .step(.back, _) = after.phase else { return XCTFail("got \(after.phase)") }
    }

    func test_tuckingEarly_stillCompletesTheStep_withOneCorner_withTwo_orNone() {
        for corners in [[], [ScreenCorner.bottomLeft], [.bottomLeft, .topRight]] {
            var s = moveStep(startingIn: .topRight)
            for c in corners { (s, _) = settle(s, c) }
            let (after, _) = TourMachine.reduce(s, .panelTucked, snapshot: TourSnapshot())
            XCTAssertEqual(after.stepStates[.moveTuck], .completed, "\(corners)")
        }
    }

    func test_landingBackInTheStartCorner_countsForNothingOnTheCornerBeat() {
        var (state, effects) = settle(moveStep(startingIn: .topRight), .topRight)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [false, false, false]))
        XCTAssertTrue(effects.isEmpty)
        (state, _) = settle(state, .bottomLeft)
        let (next, e) = settle(state, .bottomLeft)
        XCTAssertEqual(next, state)
        XCTAssertTrue(e.isEmpty)
        (state, effects) = settle(moveStep(startingIn: nil), nil)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [false, false, false]), "between corners")
        XCTAssertTrue(effects.isEmpty)
    }

    func test_aStepBegunBetweenCorners_countsTheFirstLandingAnywhere() {
        let (state, _) = settle(moveStep(startingIn: nil), .topRight)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Resolver, motion, copy
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TourSnapMarksValueTests: XCTestCase {
    private func surface(_ page: PlayerPage, edge: LiquidEdgeState = .card) -> TourSurface { TourSurface(page: page, edge: edge) }

    func test_marksShowThroughTheMoveStep_onTheCoverPageOnly() {
        let corner = TourPhase.step(.moveTuck, beats: [false, false, false])
        let edge = TourPhase.step(.moveTuck, beats: [true, true, false])
        XCTAssertTrue(TourGuidanceResolver.snapMarksVisible(phase: corner, surface: surface(.album)))
        XCTAssertTrue(TourGuidanceResolver.snapMarksVisible(phase: edge, surface: surface(.album)), "they stay up on the edge beat so the four corners stay obvious")
        XCTAssertFalse(TourGuidanceResolver.snapMarksVisible(phase: .step(.moveTuck, beats: [true, true, true]), surface: surface(.album)))
        for page in [PlayerPage.lyrics, .playlist] {
            XCTAssertFalse(TourGuidanceResolver.snapMarksVisible(phase: corner, surface: surface(page)), "\(page): corners only work on the cover")
        }
        XCTAssertFalse(TourGuidanceResolver.snapMarksVisible(phase: corner, surface: surface(.album, edge: .tucked)))
        for step in TourStep.orderedSteps where step != .moveTuck {
            XCTAssertFalse(TourGuidanceResolver.snapMarksVisible(phase: .step(step, beats: Array(repeating: false, count: step.beatCount)), surface: surface(.album)), "\(step)")
        }
        for phase in [TourPhase.welcome, .finale, .idle(deferredArmed: false), .transitioning(from: .moveTuck, to: .back), .deferredTip(.translate)] {
            XCTAssertFalse(TourGuidanceResolver.snapMarksVisible(phase: phase, surface: surface(.album)), "\(phase)")
        }
    }

    private let rects = (0..<4).map { CGRect(x: 100 * Double($0), y: 50, width: 80, height: 90) }
    private func motion(reduce: Bool = false) -> TourGuidanceMotion { TourGuidanceMotion(reduceMotion: reduce) }

    func test_marksFadeInGently_swellOnce_andThenStandStill() {
        let m = motion()
        XCTAssertEqual(m.makeFrame().marks.opacity, 0)
        m.showMarks(rects: rects, here: 1, landed: [false, false, false, false])
        m.advance(by: 0.2)
        let early = m.makeFrame().marks.opacity
        XCTAssertGreaterThan(early, 0.05); XCTAssertLessThan(early, 0.95, "a fade, not a pop")
        var peak = 0.0
        for _ in 0..<(5 * 60) { m.step(1.0 / 60); peak = max(peak, m.makeFrame().marks.breath) }
        XCTAssertGreaterThan(peak, 0.9, "one soft swell")
        let rest = m.makeFrame().marks
        XCTAssertEqual(rest.opacity, 1, accuracy: 0.001)
        XCTAssertEqual(rest.breath, 0, "and it does not loop")
        XCTAssertFalse(m.isAnimating, "a resting set of marks costs nothing: no display link")
    }

    func test_aLandingPulsesThatMarkOnly_thenSettles() {
        let m = motion()
        m.showMarks(rects: rects, here: 1, landed: [false, false, false, false])
        m.advance(by: 4)
        m.showMarks(rects: rects, here: 2, landed: [false, false, true, false])
        m.pulseMark(2)
        m.advance(by: 0.2)
        let mid = m.makeFrame().marks
        XCTAssertGreaterThan(mid.pulses[2], 0)
        XCTAssertEqual(mid.pulses[0], 0); XCTAssertEqual(mid.pulses[1], 0); XCTAssertEqual(mid.pulses[3], 0)
        XCTAssertEqual(mid.landed, [false, false, true, false])
        XCTAssertEqual(mid.here, 2)
        m.advance(by: 1.5)
        XCTAssertEqual(m.makeFrame().marks.pulses, [0, 0, 0, 0])
        XCTAssertFalse(m.isAnimating)
    }

    func test_reduceMotion_marksAreStatic_noSwell_noPulse_butTheTickStays() {
        let m = motion(reduce: true)
        m.showMarks(rects: rects, here: 0, landed: [false, false, false, false])
        var sawBreath = false
        for _ in 0..<(4 * 60) { m.step(1.0 / 60); sawBreath = sawBreath || m.makeFrame().marks.breath > 0 }
        XCTAssertFalse(sawBreath)
        XCTAssertEqual(m.makeFrame().marks.opacity, 1, accuracy: 0.001)
        m.showMarks(rects: rects, here: 3, landed: [false, false, false, true])
        m.pulseMark(3)
        m.advance(by: 0.2)
        XCTAssertEqual(m.makeFrame().marks.pulses, [0, 0, 0, 0])
        XCTAssertEqual(m.makeFrame().marks.landed, [false, false, false, true])
        XCTAssertFalse(m.isAnimating)
    }

    func test_hidingFadesOut_andShowingAgainWhileFadingDoesNotJump() {
        let m = motion()
        m.showMarks(rects: rects, here: nil, landed: [false, false, false, false])
        m.advance(by: 3)
        m.hideMarks()
        m.advance(by: 0.1)
        let mid = m.makeFrame().marks.opacity
        XCTAssertGreaterThan(mid, 0); XCTAssertLessThan(mid, 1)
        m.showMarks(rects: rects, here: nil, landed: [false, false, false, false])
        m.step(1.0 / 60)
        XCTAssertGreaterThan(m.makeFrame().marks.opacity, mid - 0.15, "no jump back to zero")
        m.hideMarks()
        m.advance(by: 1)
        XCTAssertFalse(m.makeFrame().marks.isDrawn)
    }

    func test_eachMarkHasItsOwnSmallWindowFrame_theRingOverlayIsNotStretchedToTheScreen() {
        for r in rects {
            let w = TourMarkWindowRegion.frame(for: r)
            XCTAssertTrue(w.contains(r))
            XCTAssertLessThan(w.width * w.height, (r.width + 30) * (r.height + 30), "just the mark and room for its pulse")
        }
        XCTAssertFalse(TourOverlayVisual().hasContent, "marks are not the ring overlay's business")
    }

    func test_copy_hasBothLanguages_forAllThreeBeats_andNeverUsesTheBannedWord() throws {
        let keys = ["tour.move.title", "tour.move.beat1", "tour.move.beatDiagonal", "tour.move.beat2", "tour.move.body", "tour.move.bodyDiagonal",
                    "tour.move.bodyTuckRight", "tour.move.bodyTuckLeft", "tour.move.bodyDiagonalRetry"]
        for key in keys {
            let pair = try XCTUnwrap(L10n.allStrings[key], key)
            XCTAssertFalse(pair.en.isEmpty, key); XCTAssertFalse(pair.zh.isEmpty, key)
            XCTAssertFalse(pair.zh.contains("甩"), key)
            XCTAssertNotEqual(pair.en, pair.zh, key)
        }
        XCTAssertEqual(L10n.allStrings["tour.move.beatDiagonal"]?.zh, "再斜着推到对角")
        XCTAssertEqual(L10n.allStrings["tour.move.beatDiagonal"]?.en, "Now across to the opposite corner")
        XCTAssertEqual(L10n.allStrings["tour.move.beat2"]?.zh, "往边上推，让它藏起来")
        XCTAssertEqual(L10n.allStrings["tour.move.beat1"]?.zh, "推到一个角")
        XCTAssertNil(L10n.allStrings["tour.move.beatAnother"], "the old silent invitation is gone")
        for key in ["tour.move.bodyTuckRight", "tour.move.bodyTuckLeft"] {
            let pair = try XCTUnwrap(L10n.allStrings[key])
            XCTAssertFalse(pair.en.contains("Try another corner"), "the old invitation text is gone: \(pair.en)")
            XCTAssertFalse(pair.zh.contains("再换一个角试试"), pair.zh)
        }
        let right = try XCTUnwrap(L10n.allStrings["tour.move.bodyTuckRight"]), left = try XCTUnwrap(L10n.allStrings["tour.move.bodyTuckLeft"])
        XCTAssertTrue(right.en.contains("right") && right.zh.contains("右边"))
        XCTAssertTrue(left.en.contains("left") && left.zh.contains("左边"))
        XCTAssertNil(L10n.allStrings["tour.move.bodyTuckOtherRight"], "any new corner no longer counts as the diagonal")
        XCTAssertNil(L10n.allStrings["tour.move.bodyTuckOtherLeft"])
        let retry = try XCTUnwrap(L10n.allStrings["tour.move.bodyDiagonalRetry"])
        XCTAssertEqual(retry.zh, "这是旁边的角。斜对面在另一头，跟着虚影再推一次。")
        XCTAssertEqual(retry.en, "That's the corner next door. The opposite one is across the screen; follow the ghost once more.")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Real panel, real windows
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// (the shared fixture builds the real panel, tour controller and windows; its isolated defaults suite keeps the founder's settings
// and logs untouched)

@MainActor
final class TourSnapMarksRealPanelTests: XCTestCase {
    private var f: TourRealPanelFixture!
    private let allButMoveAndBack = Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    func test_marksSitExactlyWhereThePanelLands() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.2)
        let landings = f.panel.cornerLandingFrames()
        let marks = f.controller.debugSnapMarks
        XCTAssertEqual(marks.rects.count, 4)
        for (i, corner) in ScreenCorner.allCases.enumerated() {
            XCTAssertEqual(marks.rects[i], try XCTUnwrap(landings[corner]), "\(corner)")
        }
        XCTAssertEqual(marks.here, ScreenCorner.allCases.firstIndex(of: .topRight), "the fixture starts the panel in the top right")
        XCTAssertEqual(marks.opacity, 1, accuracy: 0.01)
        let windows = f.controller.debugMarkWindows
        XCTAssertEqual(windows.count, 4)
        XCTAssertTrue(windows.allSatisfy { $0.isVisible && $0.ignoresMouseEvents }, "click-through mark windows are on screen")
        for (w, r) in zip(windows, marks.rects) { XCTAssertTrue(w.frame.insetBy(dx: -1, dy: -1).contains(r), "the window covers \(r)") }
        let area = windows.reduce(0) { $0 + $1.frame.width * $1.frame.height }
        let screen = try XCTUnwrap(NSScreen.main).frame
        XCTAssertLessThan(area / (screen.width * screen.height), 0.5, "four small windows, not one the size of the screen")
    }

    func test_marksFollowTheStep_andThePage() throws {
        f = TourRealPanelFixture(page: .lyrics)
        f.showControls(on: .lyrics)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.0)
        XCTAssertEqual(f.controller.debugSnapMarks.opacity, 0, accuracy: 0.001, "on the lyrics page (the preface beat) there are no marks")

        f.music.currentPage = .album
        XCTAssertTrue(f.wait(3) { f.controller.debugSnapMarks.opacity > 0.9 }, "back on the cover: the marks fade in")

        f.panel.setFrameOrigin(try XCTUnwrap(f.panel.cornerLandingFrames()[.bottomLeft]).origin)
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.5)
        XCTAssertTrue(f.controller.debugSnapMarks.opacity > 0.9, "after the first corner the four marks stay (the diagonal beat)")
        XCTAssertEqual(f.controller.debugSnapMarks.target, ScreenCorner.allCases.firstIndex(of: .topRight), "and the opposite corner is the emphasised one")
        f.controller.send(.panelSettled(corner: .topRight))
        f.spin(0.5)
        XCTAssertTrue(f.controller.debugSnapMarks.opacity > 0.9, "after the diagonal the four marks stay (the edge beat)")
        XCTAssertNil(f.controller.debugSnapMarks.target, "and no corner is emphasised any more")
        f.controller.send(.panelTucked)
        XCTAssertTrue(f.wait(3) { f.controller.debugSnapMarks.opacity < 0.01 }, "the step is done: the marks go")
        XCTAssertTrue(f.wait(2) { f.controller.debugMarkWindows.allSatisfy { !$0.isVisible } }, "and their windows leave the screen")
    }

    func test_otherSteps_haveNoMarks() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.lyrics, .moveTuck, .back])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.0)
        XCTAssertEqual(f.controller.state.phase, .step(.lyrics, beats: [false]))
        XCTAssertEqual(f.controller.debugSnapMarks.opacity, 0, accuracy: 0.001)
    }

    func test_aNewCorner_pulsesItsMark_andTicksIt() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.0)
        let bl = try XCTUnwrap(ScreenCorner.allCases.firstIndex(of: .bottomLeft))
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.15)
        let marks = f.controller.debugSnapMarks
        XCTAssertGreaterThan(marks.pulses[bl], 0, "the mark the panel arrived at gives its brief fill")
        XCTAssertEqual(marks.pulses.enumerated().filter { $0.offset != bl }.map(\.element), [0, 0, 0])
        XCTAssertTrue(marks.landed[bl])
        // Landing back in the same corner is not a new landing: no second pulse.
        f.spin(1.2)
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.1)
        XCTAssertEqual(f.controller.debugSnapMarks.pulses, [0, 0, 0, 0])
    }

    func test_reduceMotion_marksAreStatic() throws {
        f = TourRealPanelFixture(reduceMotion: true, page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(0.6)
        var sawBreath = false
        for _ in 0..<30 { f.spin(0.05); sawBreath = sawBreath || f.controller.debugSnapMarks.breath > 0 }
        XCTAssertFalse(sawBreath)
        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.15)
        XCTAssertEqual(f.controller.debugSnapMarks.pulses, [0, 0, 0, 0])
        XCTAssertTrue(f.controller.debugSnapMarks.landed.contains(true))
    }

    /// A real drag: the first landing ticks the corner beat, a second (into a new corner) the diagonal beat.
    func test_aRealDrag_ticksTheCornerBeat_andALaterDragAcrossToTheOppositeCornerTicksTheDiagonal() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.0)
        f.twoFingerDrag(dx: -40, dy: 30)          // top right -> bottom left: a diagonal
        XCTAssertTrue(f.wait(4) { f.controller.state.phase == .step(.moveTuck, beats: [true, false, false]) })
        f.spin(1.0)
        let tr = try XCTUnwrap(ScreenCorner.allCases.firstIndex(of: .topRight))
        f.twoFingerDrag(dx: 40, dy: -30)          // bottom left -> top right: across the screen from where it was
        XCTAssertTrue(f.wait(4) { f.controller.state.cornersLanded.contains(.topRight) })
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, true, false]), "the opposite corner ticks the diagonal beat")
        XCTAssertTrue(f.controller.debugSnapMarks.landed[tr], "and its mark is ticked")
        XCTAssertEqual(f.panel.currentCorner(), .topRight)
    }
}
