/**
 * [INPUT]: MusicMiniPlayerCore's TourGuidanceResolver / TourSurface / TourPhase / TourMachine.
 * [OUTPUT]: TourGuidanceResolverTests — every step / beat / page / controls-visible
 *           combination the ring can be in, table-tested.
 * [POS]: Tests. Pins the ring's target rules (founder walk 2026-09-29, items 5, 6, 7,
 *        8, 10): next UNFINISHED beat's control, hint vs press-now, sliver then peek card,
 *        the move step's "back to the cover" ring, and the machine's quiet lyrics step.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class TourGuidanceResolverTests: XCTestCase {
    private func surface(_ page: PlayerPage = .album, visible: Bool = true, edge: LiquidEdgeState = .card) -> TourSurface {
        TourSurface(page: page, controlsVisible: visible, edge: edge)
    }

    // MARK: - reveal

    func test_reveal_ringIsOnPlay_dashedUntilTheControlsAreOut() {
        let phase = TourPhase.step(.reveal, beats: [false, false])
        let hidden = TourGuidanceResolver.target(phase: phase, surface: surface(visible: false))
        XCTAssertEqual(hidden?.subject, .control(.playPause))
        XCTAssertEqual(hidden?.mode, .hint, "controls hidden: dashed hint")
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(visible: true))?.mode, .pressNow)
        XCTAssertEqual(hidden?.size, CGSize(width: 40, height: 40))
    }

    func test_reveal_sameOnEveryPage() {
        for page in [PlayerPage.album, .lyrics, .playlist] {
            let t = TourGuidanceResolver.target(phase: .step(.reveal, beats: [true, false]), surface: surface(page))
            XCTAssertEqual(t?.subject, .control(.playPause), "\(page)")
        }
    }

    // MARK: - corners (item 5)

    func test_corners_ringFollowsTheNextUnfinishedBeat() {
        func subject(_ beats: [Bool]) -> TourRingSubject? {
            TourGuidanceResolver.target(phase: .step(.corners, beats: beats), surface: surface())?.subject
        }
        XCTAssertEqual(subject([false, false]), .control(.audioOutput))
        XCTAssertEqual(subject([true, false]), .control(.musicButton), "output done: the ring must JUMP to Music, not vanish")
        XCTAssertEqual(subject([false, true]), .control(.audioOutput), "Music first: the ring goes back to the output button")
        XCTAssertNil(subject([true, true]))
    }

    func test_corners_musicRingIsTheCapsule() {
        let t = TourGuidanceResolver.target(phase: .step(.corners, beats: [true, false]), surface: surface())
        XCTAssertEqual(t?.size, CGSize(width: 82, height: 42))
    }

    // MARK: - lyrics / translate (items 6, 7)

    func test_lyrics_ringIsOnTheSpeechBubble() {
        let t = TourGuidanceResolver.target(phase: .step(.lyrics, beats: [false]), surface: surface())
        XCTAssertEqual(t?.subject, .control(.lyricsNav))
        XCTAssertEqual(t?.size, CGSize(width: 36, height: 36))
    }

    func test_translate_ringStaysOnTheButtonUntilTheStepCompletes() {
        let phase = TourPhase.step(.translate, beats: [false])
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.lyrics))?.subject, .control(.translate))
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.lyrics))?.mode, .pressNow)
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.album))?.mode, .hint,
                       "not on the lyrics page: the button is not there yet")
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.lyrics, visible: false))?.mode, .hint)
    }

    // MARK: - leading beats: a control that lives on only some pages (device 2026-09-29)

    func test_preface_neededOnlyWhenTheStepBeginsOffThePagesWhereItsControlExists() {
        // The table: step x page -> the leading beat.
        let table: [(TourStep, PlayerPage, TourPreface?)] = [
            (.translate, .album, .toLyrics), (.translate, .playlist, .toLyrics), (.translate, .lyrics, nil),
            (.moveTuck, .lyrics, .backToCover), (.moveTuck, .playlist, .backToCover), (.moveTuck, .album, nil),
            (.corners, .playlist, .leaveQueue), (.corners, .album, nil), (.corners, .lyrics, nil),
            // Controls that exist on every page (play, the speech bubble) or are not controls: never a leading beat.
            (.reveal, .album, nil), (.reveal, .lyrics, nil), (.reveal, .playlist, nil),
            (.lyrics, .album, nil), (.lyrics, .lyrics, nil), (.lyrics, .playlist, nil),
            (.back, .album, nil), (.connect, .album, nil),
        ]
        for (step, page, want) in table {
            XCTAssertEqual(TourPreface.needed(for: step, on: page), want, "\(step) begun on \(page)")
        }
    }

    func test_translate_beganOffTheLyricsPage_ringIsOnTheBubbleUntilThePanelArrives_thenTheTranslateButton() {
        let phase = TourPhase.step(.translate, beats: [false])
        for page in [PlayerPage.album, .playlist] {
            let t = TourGuidanceResolver.target(phase: phase, surface: surface(page), preface: .toLyrics)
            XCTAssertEqual(t?.subject, .control(.lyricsNav), "\(page): the bubble is what gets the user to the lyrics")
            XCTAssertEqual(t?.mode, .pressNow)
            XCTAssertEqual(t?.size, CGSize(width: 36, height: 36))
        }
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.album, visible: false), preface: .toLyrics)?.mode, .hint,
                       "controls hidden: the bubble is not out yet")
        let arrived = TourGuidanceResolver.target(phase: phase, surface: surface(.lyrics), preface: .toLyrics)
        XCTAssertEqual(arrived?.subject, .control(.translate), "on the lyrics page the ring springs to the translate button")
        XCTAssertEqual(arrived?.mode, .pressNow)
    }

    func test_translate_beganOnTheLyricsPage_isUnchanged() {
        let phase = TourPhase.step(.translate, beats: [false])
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.lyrics), preface: nil)?.subject, .control(.translate))
    }

    func test_corners_beganOnTheQueue_ringOnTheBubbleUntilTheQueueIsLeft() {
        let phase = TourPhase.step(.corners, beats: [false, false])
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.playlist), preface: .leaveQueue)?.subject, .control(.lyricsNav))
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.album), preface: .leaveQueue)?.subject, .control(.audioOutput))
        XCTAssertEqual(TourGuidanceResolver.target(phase: phase, surface: surface(.lyrics), preface: .leaveQueue)?.subject, .control(.audioOutput),
                       "the corner buttons are on the lyrics page too")
    }

    func test_preface_neverTouchesAPhaseThatIsNotAStep() {
        XCTAssertNil(TourGuidanceResolver.target(phase: .welcome, surface: surface(.album), preface: .toLyrics))
        XCTAssertNil(TourGuidanceResolver.target(phase: .finale, surface: surface(.album), preface: .toLyrics))
    }

    // MARK: - move (item 8)

    func test_move_ringOnlyWhenTheFirstBeatIsBackToTheCoverPage() {
        let phase = TourPhase.step(.moveTuck, beats: [false, false])
        XCTAssertNil(TourGuidanceResolver.target(phase: phase, surface: surface(.album)))
        XCTAssertNil(TourGuidanceResolver.target(phase: phase, surface: surface(.lyrics)), "no album-first beat: no ring")
        let t = TourGuidanceResolver.target(phase: phase, surface: surface(.lyrics), preface: .backToCover)
        XCTAssertEqual(t?.subject, .control(.lyricsNav), "the bubble is what turns the lyrics page back into the cover")
        XCTAssertNil(TourGuidanceResolver.target(phase: phase, surface: surface(.album), preface: .backToCover),
                     "back on the cover: the precondition is met")
    }

    func test_panelHint_moveOnTheCoverIsAGlow_notOnLyrics() {
        let phase = TourPhase.step(.moveTuck, beats: [false, false])
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: phase, surface: surface(.album)), .gestureInvite)
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: phase, surface: surface(.lyrics)), .none)
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: .step(.moveTuck, beats: [true, true]), surface: surface(.album)), .none)
    }

    // MARK: - back (item 10)

    func test_back_sliverThenPeekCard() {
        let first = TourGuidanceResolver.target(phase: .step(.back, beats: [false, false]), surface: surface(edge: .tucked))
        XCTAssertEqual(first?.subject, .sliver)
        XCTAssertEqual(first?.size, CGSize(width: 18, height: 72))
        let second = TourGuidanceResolver.target(phase: .step(.back, beats: [true, false]), surface: surface(edge: .floating))
        XCTAssertEqual(second?.subject, .peekCard, "the ring must jump from the strip to the peek card")
        XCTAssertEqual(second?.size, CGSize(width: 132, height: 216))
        XCTAssertEqual(second?.cornerRadius, 32)
        XCTAssertEqual(first?.mode, .pressNow)
    }

    func test_back_noRingOnceThePanelIsReturning_andNoPeekRingWhileOnlyTheStripIsOut() {
        for edge in [LiquidEdgeState.expanding, .card] {
            for beats in [[false, false], [true, false]] {
                XCTAssertNil(TourGuidanceResolver.target(phase: .step(.back, beats: beats), surface: surface(edge: edge)),
                             "\(edge) \(beats): the strip and the peek card are gone, so is their ring")
            }
        }
        let backOnStrip = TourGuidanceResolver.target(phase: .step(.back, beats: [true, false]), surface: surface(edge: .tucked))
        XCTAssertEqual(backOnStrip?.subject, .sliver, "the peek withdrew (hover left): point at the strip again")
    }

    // MARK: - hints (C.4.2)

    func test_hoverInvite_onlyWhileTheMouseIsAway() {
        let phase = TourPhase.step(.reveal, beats: [false, false])
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: phase, surface: surface(visible: false)), .hoverInvite)
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: phase, surface: surface(visible: true)), .none,
                       "the mouse is over the panel: ghost cursor and glow stop")
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: .step(.reveal, beats: [true, false]), surface: surface(visible: false)), .none)
    }

    // MARK: - beat subjects (row hover peeks)

    func test_beatSubjects() {
        XCTAssertEqual(TourGuidanceResolver.beatSubjects(for: .corners), [.control(.audioOutput), .control(.musicButton)])
        XCTAssertEqual(TourGuidanceResolver.beatSubjects(for: .back), [.sliver, .peekCard])
        XCTAssertEqual(TourGuidanceResolver.beatSubjects(for: .reveal), [.control(.playPause), .control(.playPause)])
    }

    // MARK: - The machine: the lyrics step is quiet when the panel is already on the lyrics page (item 6)

    func test_machine_lyricsStep_isSkippedQuietlyWhenAlreadyOnTheLyricsPage() {
        var state = TourState()
        state.status = .inProgress
        state.stepStates = [.connect: .completed, .reveal: .completed, .corners: .completed]
        let onLyrics = TourSnapshot(canTranslate: true, onLyricsPage: true)
        let (next, effects) = TourMachine.reduce(state, .resume(completed: state.completedSteps), snapshot: onLyrics)
        XCTAssertEqual(next.stepStates[.lyrics], .completed, "already there: the step counts")
        XCTAssertEqual(next.phase, .step(.translate, beats: [false]), "and the tour moves on to translation")
        XCTAssertTrue(effects.contains(.growRing(to: 4)))
        XCTAssertFalse(effects.contains(.showStepCard(.lyrics)))
    }

    func test_machine_lyricsStep_showsItsCardOffTheLyricsPage() {
        var state = TourState()
        state.stepStates = [.connect: .completed, .reveal: .completed, .corners: .completed]
        let off = TourSnapshot(canTranslate: true, onLyricsPage: false)
        let (next, _) = TourMachine.reduce(state, .resume(completed: state.completedSteps), snapshot: off)
        XCTAssertEqual(next.phase, .step(.lyrics, beats: [false]))
    }
}
