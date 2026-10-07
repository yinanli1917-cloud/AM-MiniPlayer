/**
 * [INPUT]: TourMachine (pure reducer), TourPersistence (isolated UserDefaults suite), TourStep.
 * [OUTPUT]: TourTranslateTipTests — translation left the tour (founder 2026-10-06): six steps, no deferral note, and
 *           the one-time tip that arms when the tour ends, plus the migration of old saved states.
 * [POS]: Tests. The tip's WHERE (lyrics page, button really there) is TourDeferredWatcherTests'; the card on a real panel is
 *        TourTranslateTipCardTests'.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class TourTranslateTipTests: XCTestCase {
    private let snapshot = TourSnapshot(automationAuthorized: true, canTranslate: false, showTranslation: false)

    // MARK: - The tour has six steps and never stops at translation

    func test_theTour_hasSixSteps_andTranslateIsNotOne() {
        XCTAssertEqual(TourStep.orderedSteps, [.connect, .reveal, .corners, .lyrics, .moveTuck, .back])
        XCTAssertEqual(TourStep.orderedSteps.count, 6)
        XCTAssertNil(TourMachine.next(after: .translate), "the tip's name is not a place in the sequence")
    }

    func test_afterLyrics_moveStepComesNext_evenWhenTheSongCannotBeTranslated() {
        var state = TourState()
        for step in [TourStep.connect, .reveal, .corners] { state.stepStates[step] = .completed }
        state.phase = .step(.lyrics, beats: [false])
        var effects: [TourEffect]
        (state, effects) = TourMachine.reduce(state, .signal(.onLyricsPage), snapshot: snapshot)
        XCTAssertEqual(state.phase, .transitioning(from: .lyrics, to: .moveTuck))
        (state, effects) = TourMachine.reduce(state, .advanceTransition, snapshot: snapshot)
        XCTAssertEqual(state.phase, .step(.moveTuck, beats: [false, false, false]))
        XCTAssertEqual(effects, [.showStepCard(.moveTuck), .persist], "no note, no extra card")
        XCTAssertNil(state.stepStates[.translate], "and nothing about translation is recorded")
    }

    func test_translationToggledDuringTheTour_isSilent_ringAndPhaseUntouched() {
        var state = TourState()
        state.phase = .step(.reveal, beats: [false, false])
        let (next, effects) = TourMachine.reduce(state, .signal(.translationEnabled), snapshot: snapshot)
        XCTAssertEqual(next.phase, .step(.reveal, beats: [false, false]))
        XCTAssertEqual(next.stepStates[.translate], .completed, "nothing left to teach")
        XCTAssertEqual(next.completedCount, 0)
        XCTAssertEqual(effects, [.persist], "no ring growth, no spark")
        let (end, _) = TourMachine.reduce({ var s = next; s.phase = .finale; return s }(), .finaleDismiss, snapshot: snapshot)
        XCTAssertEqual(end.phase, .idle(deferredArmed: false), "so the tour's end arms no tip")
    }

    // MARK: - Arming: the tour ended (finished or stopped), and only then

    func test_stoppedAfterTheTourRan_armsTheTip() {
        var state = TourState()
        state.phase = .step(.lyrics, beats: [false])
        let (next, effects) = TourMachine.reduce(state, .stopTour, snapshot: snapshot)
        XCTAssertEqual(next.phase, .idle(deferredArmed: true))
        XCTAssertEqual(next.stepStates[.translate], .deferred)
        XCTAssertTrue(effects.contains(.armDeferredWatcher))
    }

    func test_laterOnTheWelcomeCard_neverRanTheTour_noTip() {
        var state = TourState()
        state.phase = .welcome
        let (next, effects) = TourMachine.reduce(state, .stopTour, snapshot: snapshot)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertNil(next.stepStates[.translate])
        XCTAssertFalse(effects.contains(.armDeferredWatcher))
    }

    func test_whileTheTourRuns_theTipIsNotArmed_andIgnoresEverything() {
        var state = TourState()
        state.phase = .step(.corners, beats: [false, false])
        for event in [TourEvent.canTranslateBecameTrue(secondsIntoSong: 30), .songChanged, .deferredTipUnavailable] {
            let (next, effects) = TourMachine.reduce(state, event, snapshot: snapshot)
            XCTAssertEqual(next, state, "\(event)")
            XCTAssertTrue(effects.isEmpty, "\(event)")
        }
    }

    // MARK: - The tip: only after 3 s, closes when its ground goes, dismissable

    private var armed: TourState {
        var s = TourState()
        s.status = .completed
        s.stepStates[.translate] = .deferred
        s.phase = .idle(deferredArmed: true)
        return s
    }

    func test_tipShowsAfterThreeSeconds_notBefore() {
        let (early, e1) = TourMachine.reduce(armed, .canTranslateBecameTrue(secondsIntoSong: 2.9), snapshot: snapshot)
        XCTAssertEqual(early.phase, .idle(deferredArmed: true))
        XCTAssertTrue(e1.isEmpty)
        let (shown, e2) = TourMachine.reduce(armed, .canTranslateBecameTrue(secondsIntoSong: 3.0), snapshot: snapshot)
        XCTAssertEqual(shown.phase, .deferredTip(.translate))
        XCTAssertEqual(e2, [.showDeferredTipCard])
    }

    func test_tipAlreadyOn_completesSilently() {
        let on = TourSnapshot(automationAuthorized: true, canTranslate: true, showTranslation: true)
        let (next, effects) = TourMachine.reduce(armed, .canTranslateBecameTrue(secondsIntoSong: 5), snapshot: on)
        XCTAssertEqual(next.stepStates[.translate], .completed)
        XCTAssertFalse(effects.contains(.showDeferredTipCard))
    }

    func test_leavingTheLyricsPage_closesTheTip_withoutCostingAnAttempt() {
        var (open, _) = TourMachine.reduce(armed, .canTranslateBecameTrue(secondsIntoSong: 5), snapshot: snapshot)
        var effects: [TourEffect]
        (open, effects) = TourMachine.reduce(open, .deferredTipUnavailable, snapshot: snapshot)
        XCTAssertEqual(open.phase, .idle(deferredArmed: true))
        XCTAssertEqual(open.deferredAttempts, 0)
        XCTAssertEqual(effects, [.hideCard])
        XCTAssertTrue(open.deferredShownThisLaunch, "once per launch: it does not pop back up when they return")
    }

    func test_tipDismissed_isDoneForGood_andLeavesTheTourStatusAlone() {
        var (open, _) = TourMachine.reduce(armed, .canTranslateBecameTrue(secondsIntoSong: 5), snapshot: snapshot)
        var effects: [TourEffect]
        (open, effects) = TourMachine.reduce(open, .stopTour, snapshot: snapshot)
        XCTAssertEqual(open.stepStates[.translate], .skipped)
        XCTAssertEqual(open.status, .completed, "dismissing the tip does not turn a finished tour into a stopped one")
        XCTAssertEqual(open.phase, .idle(deferredArmed: false))
        XCTAssertEqual(effects, [.hideCard, .cancelDeferredWatcher, .persist])
    }

    func test_toggleOutsideTheTipCard_whileArmed_completesAndCancelsTheWatcher() {
        let (next, effects) = TourMachine.reduce(armed, .signal(.translationEnabled), snapshot: snapshot)
        XCTAssertEqual(next.stepStates[.translate], .completed)
        XCTAssertEqual(next.phase, .idle(deferredArmed: false))
        XCTAssertTrue(effects.contains(.cancelDeferredWatcher))
    }

    // MARK: - Migration of old saved states

    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "TourTranslateTipTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    func test_oldDeferredTranslate_afterAFinishedTour_isTheTipArmed() {
        let (defaults, cleanup) = isolatedDefaults(); defer { cleanup() }
        defaults.set(TourRunStatus.completed.rawValue, forKey: TourPersistence.statusKey)
        defaults.set(["connect", "reveal", "corners", "lyrics", "moveTuck", "back"], forKey: TourPersistence.completedStepsKey)
        defaults.set(["translate": 2], forKey: TourPersistence.deferredKey)
        let loaded = TourPersistence.load(from: defaults)
        XCTAssertEqual(loaded.stepStates[.translate], .deferred)
        XCTAssertEqual(loaded.deferredAttempts, 2, "the old attempt count carries over")
        XCTAssertEqual(loaded.phase, .idle(deferredArmed: true))
        XCTAssertEqual(loaded.completedCount, 6, "and the ring counts the six steps")
    }

    func test_oldDeferredTranslate_midTour_armsAtTheEndOfTheTour_notBefore() {
        let (defaults, cleanup) = isolatedDefaults(); defer { cleanup() }
        defaults.set(TourRunStatus.inProgress.rawValue, forKey: TourPersistence.statusKey)
        defaults.set(["translate": 0], forKey: TourPersistence.deferredKey)
        let loaded = TourPersistence.load(from: defaults)
        XCTAssertEqual(loaded.phase, .idle(deferredArmed: false), "the welcome-back card must still show")
        let (welcome, _) = TourMachine.reduce(loaded, .launch, snapshot: snapshot)
        XCTAssertEqual(welcome.phase, .welcome)
    }

    func test_oldCompletedTranslate_isTheTipDone_andIsNotAStepAnyMore() {
        let (defaults, cleanup) = isolatedDefaults(); defer { cleanup() }
        defaults.set(TourRunStatus.inProgress.rawValue, forKey: TourPersistence.statusKey)
        defaults.set(["connect", "reveal", "corners", "lyrics", "translate"], forKey: TourPersistence.completedStepsKey)
        let loaded = TourPersistence.load(from: defaults)
        XCTAssertEqual(loaded.stepStates[.translate], .completed)
        XCTAssertEqual(loaded.completedSteps, [.connect, .reveal, .corners, .lyrics], "translate is not one of the ring's steps")
        let (resumed, _) = TourMachine.reduce(loaded, .resume(completed: loaded.completedSteps), snapshot: snapshot)
        XCTAssertEqual(resumed.phase, .step(.moveTuck, beats: [false, false, false]), "resuming skips straight past it")
        var finished = resumed
        finished.phase = .finale
        XCTAssertEqual(TourMachine.reduce(finished, .finaleDismiss, snapshot: snapshot).0.phase, .idle(deferredArmed: false))
    }

    func test_tipDone_survivesASaveLoadRoundTrip_andTheCompletedListStaysDecodable() {
        let (defaults, cleanup) = isolatedDefaults(); defer { cleanup() }
        var state = TourState()
        state.status = .completed
        state.stepStates[.translate] = .completed
        TourPersistence.save(state, to: defaults)
        let loaded = TourPersistence.load(from: defaults)
        XCTAssertEqual(loaded.stepStates[.translate], .completed)
        XCTAssertEqual(loaded.phase, .idle(deferredArmed: false))
        XCTAssertNil(defaults.dictionary(forKey: TourPersistence.deferredKey))
    }
}
