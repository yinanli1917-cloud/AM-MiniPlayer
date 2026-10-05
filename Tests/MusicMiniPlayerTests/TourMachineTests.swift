import XCTest
@testable import MusicMiniPlayerCore

/// The tour's pure reducer (`TourMachine.reduce`) — no window, no clock, no
/// Combine. Exercises proposal §5.2's transition table directly: sequential
/// completion, out-of-order beats, early tuck, stop/skip, resume, the
/// translate deferral and its S4L reappearance, and the 8s/`finaleDismiss`
/// teardown split.
final class TourMachineTests: XCTestCase {
    private let authorized = TourSnapshot(automationAuthorized: true, canTranslate: true, showTranslation: false)
    private let unauthorized = TourSnapshot(automationAuthorized: false, canTranslate: true, showTranslation: false)
    private let cannotTranslate = TourSnapshot(automationAuthorized: true, canTranslate: false, showTranslation: false)

    // MARK: - Welcome / start

    func test_launch_showsWelcomeCard_whenNotStarted() {
        let (state, effects) = TourMachine.reduce(TourState(), .launch, snapshot: authorized)
        XCTAssertEqual(state.phase, .welcome)
        XCTAssertEqual(effects, [.showWelcomeCard(resuming: false)])
    }

    func test_launch_doesNothing_whenAlreadyCompleted() {
        var state = TourState()
        state.status = .completed
        let (next, effects) = TourMachine.reduce(state, .launch, snapshot: authorized)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertTrue(effects.isEmpty)
    }

    func test_start_authorized_skipsConnect_entersReveal() {
        let (state, effects) = TourMachine.reduce(TourState(), .start, snapshot: authorized)
        guard case .step(.reveal, let beats) = state.phase else {
            return XCTFail("expected .step(.reveal), got \(state.phase)")
        }
        XCTAssertEqual(beats, [false, false])
        XCTAssertEqual(state.stepStates[.connect], .completed)
        XCTAssertTrue(effects.contains(.showStepCard(.reveal)))
        XCTAssertTrue(effects.contains(.persist))
    }

    func test_start_unauthorized_entersConnect() {
        let (state, effects) = TourMachine.reduce(TourState(), .start, snapshot: unauthorized)
        guard case .step(.connect, let beats) = state.phase else {
            return XCTFail("expected .step(.connect), got \(state.phase)")
        }
        XCTAssertEqual(beats, [false])
        XCTAssertTrue(effects.contains(.showStepCard(.connect)))
    }

    // MARK: - Sequential completion, phase & effects table

    func test_sequentialCompletion_walksAllSevenSteps() throws {
        var state = TourState()
        (state, _) = TourMachine.reduce(state, .start, snapshot: authorized)

        // reveal: two beats, out-of-order-safe.
        var effects: [TourEffect]
        (state, effects) = TourMachine.reduce(state, .signal(.controlsRevealed), snapshot: authorized)
        XCTAssertEqual(effects.first, .checkBeat(.reveal, index: 0))
        guard case .step(.reveal, [true, false]) = state.phase else { return XCTFail() }

        (state, effects) = TourMachine.reduce(state, .signal(.isPlaying), snapshot: authorized)
        XCTAssertTrue(effects.contains(.growRing(to: 2))) // connect + reveal
        XCTAssertTrue(effects.contains(.spark))
        guard case .transitioning(.reveal, .corners) = state.phase else { return XCTFail("got \(state.phase)") }

        (state, _) = TourMachine.reduce(state, .advanceTransition, snapshot: authorized)
        guard case .step(.corners, [false, false]) = state.phase else { return XCTFail("got \(state.phase)") }

        (state, _) = TourMachine.reduce(state, .signal(.audioOutputMenuOpened), snapshot: authorized)
        (state, _) = TourMachine.reduce(state, .signal(.musicButtonTapped), snapshot: authorized)
        guard case .transitioning(.corners, .lyrics) = state.phase else { return XCTFail("got \(state.phase)") }
        (state, _) = TourMachine.reduce(state, .advanceTransition, snapshot: authorized)
        guard case .step(.lyrics, [false]) = state.phase else { return XCTFail() }

        (state, _) = TourMachine.reduce(state, .signal(.onLyricsPage), snapshot: authorized)
        guard case .transitioning(.lyrics, .translate) = state.phase else { return XCTFail("got \(state.phase)") }
        (state, _) = TourMachine.reduce(state, .advanceTransition, snapshot: authorized)
        guard case .step(.translate, [false]) = state.phase else { return XCTFail("got \(state.phase)") }

        (state, _) = TourMachine.reduce(state, .signal(.translationEnabled), snapshot: authorized)
        guard case .transitioning(.translate, .moveTuck) = state.phase else { return XCTFail("got \(state.phase)") }
        (state, _) = TourMachine.reduce(state, .advanceTransition, snapshot: authorized)
        guard case .step(.moveTuck, [false, false, false]) = state.phase else { return XCTFail() }

        (state, effects) = TourMachine.reduce(state, .panelSettled(corner: .bottomRight), snapshot: authorized)
        XCTAssertTrue(effects.contains(.relocateCardToPanel))
        guard case .step(.moveTuck, [true, false, false]) = state.phase else { return XCTFail() }

        (state, effects) = TourMachine.reduce(state, .panelTucked, snapshot: authorized)
        XCTAssertEqual(state.stepStates[.moveTuck], .completed)
        guard case .step(.back, [false, false]) = state.phase else { return XCTFail("got \(state.phase)") }

        (state, _) = TourMachine.reduce(state, .signal(.liquidEdgeFloating), snapshot: authorized)
        guard case .step(.back, [true, false]) = state.phase else { return XCTFail() }

        (state, effects) = TourMachine.reduce(state, .panelExpanded, snapshot: authorized)
        XCTAssertEqual(state.stepStates[.back], .completed)
        XCTAssertEqual(state.completedCount, 7)
        XCTAssertTrue(effects.contains(.pulseRing))
        XCTAssertTrue(effects.contains(.confetti))
        XCTAssertTrue(effects.contains(.showFinaleCard(deferred: false)))
        XCTAssertEqual(state.phase, .finale)
    }

    // MARK: - Beats in either order

    func test_corners_beatsCompleteInEitherOrder() {
        var state = TourState()
        state.phase = .step(.corners, beats: [false, false])
        state.stepStates[.connect] = .completed
        state.stepStates[.reveal] = .completed

        let (afterMusicFirst, _) = TourMachine.reduce(state, .signal(.musicButtonTapped), snapshot: authorized)
        guard case .step(.corners, [false, true]) = afterMusicFirst.phase else { return XCTFail() }
        let (done, effects) = TourMachine.reduce(afterMusicFirst, .signal(.audioOutputMenuOpened), snapshot: authorized)
        XCTAssertTrue(effects.contains(.spark))
        guard case .transitioning(.corners, .lyrics) = done.phase else { return XCTFail() }
    }

    // MARK: - Out-of-order completion doesn't jump the card

    func test_outOfOrderSignal_recordsCompletion_doesNotChangeCurrentCard() {
        var state = TourState()
        (state, _) = TourMachine.reduce(state, .start, snapshot: authorized) // -> .step(.reveal, ...)

        // The user opens the output menu (a corners beat) while still on reveal.
        let (afterEarly, effects) = TourMachine.reduce(state, .signal(.audioOutputMenuOpened), snapshot: authorized)
        guard case .step(.reveal, [false, false]) = afterEarly.phase else {
            return XCTFail("current card must not change, got \(afterEarly.phase)")
        }
        // A single beat toward a two-beat step does not complete it or grow the ring.
        XCTAssertNil(afterEarly.stepStates[.corners])
        XCTAssertTrue(effects.isEmpty)

        // The other corners beat lands too — NOW corners is fully resolved,
        // silently, still without disturbing the reveal card.
        let (afterBoth, effects2) = TourMachine.reduce(afterEarly, .signal(.musicButtonTapped), snapshot: authorized)
        guard case .step(.reveal, [false, false]) = afterBoth.phase else { return XCTFail() }
        XCTAssertEqual(afterBoth.stepStates[.corners], .completed)
        XCTAssertTrue(effects2.contains(.spark))

        // Finish reveal normally; corners must be skipped over on arrival.
        var state2 = afterBoth
        (state2, _) = TourMachine.reduce(state2, .signal(.controlsRevealed), snapshot: authorized)
        (state2, _) = TourMachine.reduce(state2, .signal(.isPlaying), snapshot: authorized)
        (state2, _) = TourMachine.reduce(state2, .advanceTransition, snapshot: authorized)
        guard case .step(.lyrics, _) = state2.phase else { return XCTFail("expected corners to be skipped straight to lyrics, got \(state2.phase)") }
    }

    // MARK: - Early tuck jumps directly to S6

    func test_earlyTuck_fromAnyStep_jumpsDirectlyToBack() {
        var state = TourState()
        state.phase = .step(.reveal, beats: [false, false])
        state.stepStates[.connect] = .completed

        let (next, effects) = TourMachine.reduce(state, .panelTucked, snapshot: authorized)
        XCTAssertEqual(next.stepStates[.moveTuck], .completed)
        guard case .step(.back, [false, false]) = next.phase else { return XCTFail("got \(next.phase)") }
        XCTAssertTrue(effects.contains(.showStepCard(.back)))
    }

    // MARK: - stopTour / skipStep

    func test_stopTour_fromAnyPhase_tearsDownAndMarksSkipped() {
        var state = TourState()
        state.phase = .step(.corners, beats: [true, false])
        let (next, effects) = TourMachine.reduce(state, .stopTour, snapshot: authorized)
        XCTAssertEqual(next.status, .skipped)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertEqual(effects, [.hideCard, .teardown, .persist])
    }

    func test_skipStep_marksSkipped_ringDoesNotGrow_advancesToNext() {
        var state = TourState()
        state.phase = .step(.lyrics, beats: [false])
        let (next, effects) = TourMachine.reduce(state, .skipStep, snapshot: authorized)
        XCTAssertEqual(next.stepStates[.lyrics], .skipped)
        XCTAssertEqual(next.completedCount, 0)
        XCTAssertFalse(effects.contains(where: { if case .growRing = $0 { return true }; return false }))
        guard case .step(.translate, _) = next.phase else { return XCTFail("got \(next.phase)") }
    }

    // MARK: - Resume

    func test_resume_prefillsCompletedSteps_entersFirstPending() {
        let (state, _) = TourMachine.reduce(TourState(), .resume(completed: [.connect, .reveal, .corners]), snapshot: authorized)
        XCTAssertEqual(state.completedSteps, [.connect, .reveal, .corners])
        guard case .step(.lyrics, _) = state.phase else { return XCTFail("got \(state.phase)") }
        XCTAssertEqual(state.resumeCount, 1)
    }

    func test_resume_allStepsDone_goesStraightToFinale() {
        let all = Set(TourStep.orderedSteps)
        let (state, effects) = TourMachine.reduce(TourState(), .resume(completed: all), snapshot: authorized)
        XCTAssertEqual(state.phase, .finale)
        XCTAssertTrue(effects.contains(.showFinaleCard(deferred: false)))
    }

    // MARK: - finaleDismiss vs 8s auto-dismiss both teardown

    func test_finaleDismiss_marksCompleted_andTearsDown() {
        var state = TourState()
        state.phase = .finale
        let (next, effects) = TourMachine.reduce(state, .finaleDismiss, snapshot: authorized)
        XCTAssertEqual(next.status, .completed)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertTrue(effects.contains(.teardown))
        XCTAssertTrue(effects.contains(.hideCard))
        XCTAssertFalse(effects.contains(.armDeferredWatcher))
    }

    /// TourController sends the SAME event whether the user tapped "好" or
    /// the 8s auto-dismiss timer fired — both are `.finaleDismiss` as far as
    /// the reducer is concerned; the distinction is purely in what triggers
    /// the send, which lives in TourController, not the reducer.
    func test_finaleDismiss_afterAutoTimeout_sameEffectsAsManualDismiss() {
        var state = TourState()
        state.phase = .finale
        let (viaAuto, autoEffects) = TourMachine.reduce(state, .finaleDismiss, snapshot: authorized)
        state.phase = .finale
        let (viaManual, manualEffects) = TourMachine.reduce(state, .finaleDismiss, snapshot: authorized)
        XCTAssertEqual(viaAuto, viaManual)
        XCTAssertEqual(autoEffects, manualEffects)
    }

    // MARK: - Deferral (§3.3 S4′)

    func test_enteringTranslate_canTranslateFalse_defersWithoutGrowingRing() {
        var state = TourState()
        state.stepStates[.connect] = .completed
        state.stepStates[.reveal] = .completed
        state.stepStates[.corners] = .completed
        state.stepStates[.lyrics] = .completed
        let before = state.completedCount

        let (next, effects) = TourMachine.enterStep(.translate, state: state, snapshot: cannotTranslate)
        XCTAssertEqual(next.stepStates[.translate], .deferred)
        XCTAssertEqual(next.completedCount, before, "deferring must not grow the ring")
        XCTAssertTrue(effects.contains(.showDeferralNote))
        guard case .transitioning(.translate, .moveTuck) = next.phase else { return XCTFail("got \(next.phase)") }
    }

    /// The deferral note waits for the user (2026-10-04: it flashed by in 1.1 s). "Later" is `.advanceTransition`: the same
    /// outcome the old timer had — translate stays deferred, the move step comes up.
    func test_deferralNote_laterContinuesToTheMoveStep_translateStaysDeferred() {
        var state = deferralNoteState()
        var effects: [TourEffect]
        (state, effects) = TourMachine.reduce(state, .advanceTransition, snapshot: cannotTranslate)
        guard case .step(.moveTuck, _) = state.phase else { return XCTFail("got \(state.phase)") }
        XCTAssertEqual(state.stepStates[.translate], .deferred)
        XCTAssertTrue(state.hasDeferredTranslate)
        XCTAssertTrue(effects.contains(.showStepCard(.moveTuck)))
    }

    /// A translatable song starts while the note is up: the note becomes the real translate step, right there.
    func test_deferralNote_canTranslateBecomingTrue_entersTheTranslateStep() {
        let state = deferralNoteState()
        XCTAssertTrue(state.isShowingDeferralNote)
        // The snapshot may still carry the old canTranslate (the publisher fires before the value lands).
        let (next, effects) = TourMachine.reduce(state, .canTranslateBecameTrue(secondsIntoSong: 0), snapshot: cannotTranslate)
        XCTAssertEqual(next.phase, .step(.translate, beats: [false]))
        XCTAssertEqual(next.stepStates[.translate], .pending)
        XCTAssertFalse(next.hasDeferredTranslate)
        XCTAssertTrue(effects.contains(.showStepCard(.translate)))
    }

    func test_deferralNote_isNotTheRealTranslateCompletionTransition() {
        var state = TourState()
        state.stepStates[.translate] = .completed
        state.phase = .transitioning(from: .translate, to: .moveTuck)
        XCTAssertFalse(state.isShowingDeferralNote)
        let (next, _) = TourMachine.reduce(state, .canTranslateBecameTrue(secondsIntoSong: 0), snapshot: authorized)
        XCTAssertEqual(next.phase, state.phase, "only the note reacts")
    }

    private func deferralNoteState() -> TourState {
        var state = TourState()
        for step in [TourStep.connect, .reveal, .corners, .lyrics] { state.stepStates[step] = .completed }
        return TourMachine.enterStep(.translate, state: state, snapshot: cannotTranslate).0
    }

    // MARK: - Move step: the diagonal beat takes only the corner across the screen from where the panel just was

    private func moveStepState(startingIn corner: ScreenCorner) -> TourState {
        var state = TourState()
        for step in TourStep.orderedSteps where step != .moveTuck && step != .back { state.stepStates[step] = .completed }
        let snapshot = TourSnapshot(automationAuthorized: true, canTranslate: true, panelCorner: corner)
        return TourMachine.enterStep(.moveTuck, state: state, snapshot: snapshot).0
    }

    private func settle(_ state: TourState, _ corner: ScreenCorner) -> (TourState, [TourEffect]) {
        TourMachine.reduce(state, .panelSettled(corner: corner), snapshot: authorized)
    }

    func test_moveStep_diagonalBeat_ticksOnlyForTheOppositeOfTheCornerThePanelWasIn() {
        var state = moveStepState(startingIn: .topRight)
        var effects: [TourEffect]
        (state, effects) = settle(state, .topLeft)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]), "any corner but the start ticks the first beat")

        // The corner next door (bottom-left is adjacent to top-left): no tick, the card is asked to follow the panel.
        (state, effects) = settle(state, .bottomLeft)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]))
        XCTAssertFalse(effects.contains(.checkBeat(.moveTuck, index: 1)))
        XCTAssertTrue(effects.contains(.relocateCardToPanel))

        // The opposite of where it sits NOW (bottom-left -> top-right, a corner it started in) ticks.
        (state, effects) = settle(state, .topRight)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, true, false]))
        XCTAssertTrue(effects.contains(.checkBeat(.moveTuck, index: 1)))
    }

    /// Every settle moves the reference corner, including the ones that tick nothing and the ones in corners already visited.
    func test_moveStep_diagonalBeat_followsEverySettle() {
        var state = moveStepState(startingIn: .topRight)
        (state, _) = settle(state, .topLeft)                 // beat 0
        (state, _) = settle(state, .topRight)                // back in the start corner: adjacent to top-left, no tick
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]))
        (state, _) = settle(state, .bottomRight)             // the opposite of where it was before (top-right is not it): no tick
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]))
        // Across from bottom-right is top-left, a corner already landed in: still the diagonal.
        (state, _) = settle(state, .topLeft)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, true, false]))
    }

    func test_moveStep_firstBeat_ignoresTheStartCornerAndTheSameCornerAgain() {
        var state = moveStepState(startingIn: .bottomLeft)
        (state, _) = settle(state, .bottomLeft)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [false, false, false]))
        (state, _) = settle(state, .topRight)                // across the screen straight away still counts as the first corner
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [true, false, false]))
    }

    func test_finale_withDeferredTranslate_armsWatcherInstead_ofFullIdle() {
        var state = TourState()
        state.stepStates[.translate] = .deferred
        state.phase = .finale
        let (next, effects) = TourMachine.reduce(state, .finaleDismiss, snapshot: authorized)
        XCTAssertEqual(next.phase, .idle(deferredArmed: true))
        XCTAssertTrue(effects.contains(.armDeferredWatcher))
    }

    // MARK: - canTranslateBecameTrue: 3s gate, panel-visibility, once per launch

    func test_canTranslateBecameTrue_underThreeSeconds_doesNotShowTip() {
        var state = TourState()
        state.phase = .idle(deferredArmed: true)
        let (next, effects) = TourMachine.reduce(state, .canTranslateBecameTrue(secondsIntoSong: 1.5), snapshot: authorized)
        XCTAssertEqual(next.phase, .idle(deferredArmed: true))
        XCTAssertTrue(effects.isEmpty)
    }

    func test_canTranslateBecameTrue_notArmed_isIgnored() {
        var state = TourState()
        state.phase = .idle(deferredArmed: false)
        let (next, effects) = TourMachine.reduce(state, .canTranslateBecameTrue(secondsIntoSong: 5), snapshot: authorized)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertTrue(effects.isEmpty)
    }

    func test_canTranslateBecameTrue_showsOnce_perLaunch() {
        var state = TourState()
        state.phase = .idle(deferredArmed: true)
        let (afterFirst, effects1) = TourMachine.reduce(state, .canTranslateBecameTrue(secondsIntoSong: 4), snapshot: authorized)
        XCTAssertEqual(afterFirst.phase, .deferredTip(.translate))
        XCTAssertEqual(effects1, [.showDeferredTipCard])
        XCTAssertTrue(afterFirst.deferredShownThisLaunch)

        // The song changes before the user acts — the open tip closes
        // (counts as one of the 3 attempts) and it stays armed for a LATER
        // launch, but `deferredShownThisLaunch` must NOT reset: the card
        // shows at most once per launch (§11.1), even if another foreign
        // song plays before this launch ends.
        var afterClose = afterFirst
        (afterClose, _) = TourMachine.reduce(afterClose, .songChanged, snapshot: authorized)
        XCTAssertEqual(afterClose.phase, .idle(deferredArmed: true))
        XCTAssertEqual(afterClose.deferredAttempts, 1)
        XCTAssertTrue(afterClose.deferredShownThisLaunch, "must not re-arm within the same launch")

        let (afterSecond, effects2) = TourMachine.reduce(afterClose, .canTranslateBecameTrue(secondsIntoSong: 4), snapshot: authorized)
        XCTAssertTrue(effects2.isEmpty, "must not show a second S4L card in the same launch")
        XCTAssertEqual(afterSecond.phase, .idle(deferredArmed: true))

        // A fresh `.launch` re-arms eligibility for the NEXT launch.
        let (afterRelaunch, _) = TourMachine.reduce(afterSecond, .launch, snapshot: authorized)
        XCTAssertFalse(afterRelaunch.deferredShownThisLaunch)
        let (afterThird, effects3) = TourMachine.reduce(afterRelaunch, .canTranslateBecameTrue(secondsIntoSong: 4), snapshot: authorized)
        XCTAssertEqual(effects3, [.showDeferredTipCard], "a later launch may show the tip again")
        XCTAssertEqual(afterThird.phase, .deferredTip(.translate))
    }

    func test_canTranslateBecameTrue_showTranslationAlreadyOn_completesSilently() {
        var state = TourState()
        state.phase = .idle(deferredArmed: true)
        let alreadyOn = TourSnapshot(automationAuthorized: true, canTranslate: true, showTranslation: true)
        let (next, effects) = TourMachine.reduce(state, .canTranslateBecameTrue(secondsIntoSong: 4), snapshot: alreadyOn)
        XCTAssertEqual(next.stepStates[.translate], .completed)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertTrue(effects.contains(.cancelDeferredWatcher))
        XCTAssertFalse(effects.contains(.showDeferredTipCard))
    }

    // MARK: - S4L completion closes quietly (no confetti — already played at S7)

    func test_deferredTip_signalCompletes_quietly_noConfetti() {
        var state = TourState()
        state.phase = .deferredTip(.translate)
        let (next, effects) = TourMachine.reduce(state, .signal(.translationEnabled), snapshot: authorized)
        XCTAssertEqual(next.stepStates[.translate], .completed)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertTrue(effects.contains(.pulseRing))
        XCTAssertTrue(effects.contains(.haptic(.alignment)))
        XCTAssertFalse(effects.contains(.confetti))
        XCTAssertTrue(effects.contains(.cancelDeferredWatcher))
    }

    // MARK: - 3 songs without completing, or 20 launches, silently skip

    func test_threeSongsWithoutCompleting_marksSkipped() {
        var state = TourState()
        state.phase = .idle(deferredArmed: true)
        state.deferredAttempts = 2
        state.phase = .deferredTip(.translate)
        let (next, effects) = TourMachine.reduce(state, .songChanged, snapshot: authorized)
        XCTAssertEqual(next.stepStates[.translate], .skipped)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertTrue(effects.contains(.cancelDeferredWatcher))
    }

    func test_twentyLaunches_marksSkipped() {
        var state = TourState()
        state.phase = .idle(deferredArmed: true)
        state.deferredLaunches = 19
        let (next, effects) = TourMachine.reduce(state, .launch, snapshot: authorized)
        XCTAssertEqual(next.stepStates[.translate], .skipped)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertTrue(effects.contains(.cancelDeferredWatcher))
    }

    func test_launchesBelowCap_justCounts_staysArmed() {
        var state = TourState()
        state.phase = .idle(deferredArmed: true)
        state.deferredLaunches = 3
        let (next, effects) = TourMachine.reduce(state, .launch, snapshot: authorized)
        XCTAssertEqual(next.deferredLaunches, 4)
        XCTAssertEqual(next.phase, .idle(deferredArmed: true))
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Schema migration only shows new steps

    func test_newSteps_sinceOlderSchema_onlyReturnsStepsIntroducedSince() {
        // All v3 steps share introducedIn == 2 today; this exercises the
        // >schema filter itself with a synthetic future baseline.
        XCTAssertEqual(TourPersistence.newSteps(sinceSchema: 2), [])
        XCTAssertEqual(TourPersistence.newSteps(sinceSchema: 1), TourStep.orderedSteps)
    }
}
