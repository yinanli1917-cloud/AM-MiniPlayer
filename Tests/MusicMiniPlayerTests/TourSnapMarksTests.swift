/**
 * [INPUT]: TourMachine (pure reducer), TourGuidanceResolver, TourGuidanceMotion (fake clock), TourRealPanelFixture
 *          (real panel + real tour windows), L10n.
 * [OUTPUT]: TourSnapMarksTests — the move step's two corner beats and the four snap-target marks (2026-10-03):
 *           a landing in a new corner ticks beat 1, a landing in a third corner ticks beat 2, a corner already used
 *           (or the one the panel started in) ticks nothing; the marks show on the corner beats on the cover page only,
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

    func test_theMoveStepStillNeedsTwoMoves_aCornerAndTheEdge() {
        XCTAssertEqual(TourStep.moveTuck.beatCount, 2)
        XCTAssertEqual(moveStep(startingIn: .topRight).phase, .step(.moveTuck, beats: [false, false]))
    }

    func test_aLandingInAnyOtherCorner_adjacentOrDiagonal_ticksTheCornerBeat_allTwelvePairs() {
        for start in ScreenCorner.allCases {
            for landing in ScreenCorner.allCases where landing != start {
                let (state, effects) = settle(moveStep(startingIn: start), landing)
                XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false]), "\(start) -> \(landing)")
                XCTAssertTrue(effects.contains(.checkBeat(.moveTuck, index: 0)), "\(start) -> \(landing)")
                XCTAssertEqual(state.cornersLanded, [landing])
            }
        }
    }

    func test_aSecondCorner_isOptional_itTicksNothing_blocksNothing_andIsRemembered() {
        var (state, _) = settle(moveStep(startingIn: .topRight), .bottomLeft)
        let effects: [TourEffect]
        (state, effects) = settle(state, .topLeft)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false]), "no beat for it")
        XCTAssertFalse(effects.contains { if case .checkBeat = $0 { return true }; return false })
        XCTAssertTrue(effects.contains(.relocateCardToPanel), "the card comes back to the panel")
        XCTAssertEqual(state.cornersLanded, [.bottomLeft, .topLeft], "the mark of the new corner gets its acknowledgement")
        // Tucking completes the step with one corner, with two, or with none.
        for corners in [[], [ScreenCorner.bottomLeft], [.bottomLeft, .topLeft]] {
            var s = moveStep(startingIn: .topRight)
            for c in corners { (s, _) = settle(s, c) }
            let (after, _) = TourMachine.reduce(s, .panelTucked, snapshot: TourSnapshot())
            XCTAssertEqual(after.stepStates[.moveTuck], .completed, "\(corners)")
        }
    }

    func test_landingBackInTheStartOrAUsedCorner_countsForNothing() {
        var (state, effects) = settle(moveStep(startingIn: .topRight), .topRight)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [false, false]))
        XCTAssertTrue(effects.isEmpty)
        (state, _) = settle(state, .bottomLeft)
        for used in [ScreenCorner.bottomLeft, .topRight] {
            let (next, e) = settle(state, used)
            XCTAssertEqual(next, state, "\(used)")
            XCTAssertTrue(e.isEmpty, "\(used)")
            state = next
        }
        (state, effects) = settle(moveStep(startingIn: nil), nil)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [false, false]), "between corners")
        XCTAssertTrue(effects.isEmpty)
    }

    func test_aStepBegunBetweenCorners_countsTheFirstLandingAnywhere() {
        let (state, _) = settle(moveStep(startingIn: nil), .topRight)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false]))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Resolver, motion, copy
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TourSnapMarksValueTests: XCTestCase {
    private func surface(_ page: PlayerPage, edge: LiquidEdgeState = .card) -> TourSurface { TourSurface(page: page, edge: edge) }

    func test_marksShowThroughTheMoveStep_onTheCoverPageOnly() {
        let corner = TourPhase.step(.moveTuck, beats: [false, false])
        let edge = TourPhase.step(.moveTuck, beats: [true, false])
        XCTAssertTrue(TourGuidanceResolver.snapMarksVisible(phase: corner, surface: surface(.album)))
        XCTAssertTrue(TourGuidanceResolver.snapMarksVisible(phase: edge, surface: surface(.album)), "they stay up on the edge beat so the four corners stay obvious")
        XCTAssertFalse(TourGuidanceResolver.snapMarksVisible(phase: .step(.moveTuck, beats: [true, true]), surface: surface(.album)))
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

    func test_copy_hasBothLanguages_invitesASecondCorner_andNeverUsesTheBannedWord() throws {
        for key in ["tour.move.beat1", "tour.move.body", "tour.move.bodyTuckRight", "tour.move.bodyTuckLeft"] {
            let pair = try XCTUnwrap(L10n.allStrings[key], key)
            XCTAssertFalse(pair.en.isEmpty, key); XCTAssertFalse(pair.zh.isEmpty, key)
            XCTAssertFalse(pair.zh.contains("甩"), key)
            XCTAssertNotEqual(pair.en, pair.zh, key)
        }
        XCTAssertEqual(L10n.allStrings["tour.move.beat1"]?.zh, "推到一个角")
        XCTAssertEqual(L10n.allStrings["tour.move.beat1"]?.en, "Nudge it to a corner")
        XCTAssertNil(L10n.allStrings["tour.move.beatAnother"], "the second corner is not a beat")
        let body = try XCTUnwrap(L10n.allStrings["tour.move.body"])
        XCTAssertTrue(body.en.contains("four"), body.en)
        XCTAssertTrue(body.zh.contains("四个角"), body.zh)
        for key in ["tour.move.bodyTuckRight", "tour.move.bodyTuckLeft"] {
            let pair = try XCTUnwrap(L10n.allStrings[key])
            XCTAssertTrue(pair.en.contains("Try another corner if you like"), pair.en)
            XCTAssertTrue(pair.zh.contains("想的话再换一个角试试，四个角都能停"), pair.zh)
        }
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

        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(0.5)
        XCTAssertTrue(f.controller.debugSnapMarks.opacity > 0.9, "after the first corner the four marks stay (the edge beat)")
        XCTAssertNil(f.controller.debugSnapMarks.target, "and no corner is emphasised any more")
        f.controller.send(.panelTucked)
        XCTAssertTrue(f.wait(3) { f.controller.debugSnapMarks.opacity < 0.01 }, "the step is done: the marks go")
        XCTAssertTrue(f.wait(2) { f.controller.debugMarkWindows.allSatisfy { !$0.isVisible } }, "and their windows leave the screen")
    }

    func test_otherSteps_haveNoMarks() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.lyrics, .translate, .moveTuck, .back])))
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

    /// A real drag: the first landing ticks the corner beat, a second (optional) one only gets its mark ticked.
    func test_aRealDrag_ticksTheCornerBeat_andALaterDragToAnotherCornerBlocksNothing() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.0)
        f.twoFingerDrag(dx: -40, dy: 30)          // top right -> bottom left: a diagonal
        XCTAssertTrue(f.wait(4) { f.controller.state.phase == .step(.moveTuck, beats: [true, false]) })
        f.spin(1.0)
        let br = try XCTUnwrap(ScreenCorner.allCases.firstIndex(of: .bottomRight))
        f.twoFingerDrag(dx: 40, dy: 0)            // bottom left -> bottom right
        XCTAssertTrue(f.wait(4) { f.controller.state.cornersLanded.contains(.bottomRight) })
        XCTAssertEqual(f.controller.state.phase, .step(.moveTuck, beats: [true, false]), "the second corner is not a beat")
        XCTAssertTrue(f.controller.debugSnapMarks.landed[br], "but its mark is ticked")
        XCTAssertEqual(f.panel.currentCorner(), .bottomRight)
    }
}
