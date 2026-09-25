import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Pure hover-intent reducer for the progress-bar thickening trigger
// (founder 2026-09-25: a fast pass over the bar was thickening it — too
// easy to trigger by accident). Every test drives ProgressHoverIntentEngine
// with an explicit synthetic `now` — no real waiting, no timers, fully
// deterministic. See Sources/.../Components/SharedControls.swift for the
// reducer itself and MicroInteractionFeel.Tokens.progressHoverIntent* for
// the tuned numbers + research citations.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class ProgressHoverIntentEngineTests: XCTestCase {
    private typealias Engine = ProgressHoverIntentEngine
    private let cfg = Engine.Config.default

    // MARK: - Fast transit never commits

    /// ~30ms horizontal skim across the bar: enter, drift far past the
    /// tolerance mid-transit (still pending, timer re-armed), then exit
    /// well before the dwell deadline. Must never reach `.commit`.
    func test_fastHorizontalSkim_neverCommits() {
        var state = Engine.State.idle
        var effect: Engine.Effect

        (state, effect) = Engine.enter(state: state, at: CGPoint(x: 20, y: 7), now: 0.000, config: cfg)
        XCTAssertEqual(effect, .armTimer(deadline: 0.000 + cfg.dwellDuration))

        (state, effect) = Engine.move(state: state, to: CGPoint(x: 120, y: 7), now: 0.015, config: cfg)
        XCTAssertEqual(effect, .armTimer(deadline: 0.015 + cfg.dwellDuration), "large horizontal drift must re-arm, not commit")

        (state, effect) = Engine.exit(state: state, now: 0.030, config: cfg)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(effect, .cancelTimer, "exiting from pending resets immediately (cancelling the dwell timer) with no commit and no grace")
    }

    /// ~30ms diagonal skim (both axes move).
    func test_fastDiagonalSkim_neverCommits() {
        var state = Engine.State.idle
        var effect: Engine.Effect

        (state, effect) = Engine.enter(state: state, at: CGPoint(x: 20, y: 2), now: 0.000, config: cfg)
        XCTAssertEqual(effect, .armTimer(deadline: 0.15))

        (state, effect) = Engine.move(state: state, to: CGPoint(x: 90, y: 12), now: 0.018, config: cfg)
        XCTAssertEqual(effect, .armTimer(deadline: 0.018 + cfg.dwellDuration))

        (state, effect) = Engine.exit(state: state, now: 0.031, config: cfg)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(effect, .cancelTimer)
    }

    /// A slow, continuous drag-through that takes almost the full dwell but
    /// exits a hair before the timer would have fired — must still not
    /// commit (no stale timer left armed at the old deadline either, which
    /// callers rely on via single-slot scheduling: each `.armTimer` effect
    /// supersedes whatever was scheduled before).
    func test_exitJustBeforeDwellDeadline_stillDoesNotCommit() {
        var state = Engine.State.idle
        (state, _) = Engine.enter(state: state, at: CGPoint(x: 20, y: 7), now: 0, config: cfg)
        let (finalState, effect) = Engine.exit(state: state, now: cfg.dwellDuration - 0.001, config: cfg)
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(effect, .cancelTimer)
    }

    // MARK: - Slow entry commits after dwell

    func test_slowEntryThenStop_commitsExactlyAtDwellDeadline() {
        var state = Engine.State.idle
        (state, _) = Engine.enter(state: state, at: CGPoint(x: 100, y: 7), now: 0, config: cfg)

        // One instant before the deadline: must not fire yet.
        var (notYetState, notYetEffect) = Engine.timerFired(state: state, now: cfg.dwellDuration - 0.001)
        XCTAssertEqual(notYetEffect, .none)
        XCTAssertEqual(notYetState, state, "must still be pending, unchanged")

        // At (or past) the deadline: commits.
        let (committedState, effect) = Engine.timerFired(state: state, now: cfg.dwellDuration)
        XCTAssertEqual(committedState, .committed)
        XCTAssertEqual(effect, .commit)
        _ = notYetState; _ = notYetEffect
    }

    // MARK: - Sub-threshold jitter does not reset the dwell clock

    func test_subToleranceJitter_doesNotResetDeadlineOrEffect() {
        var state = Engine.State.idle
        (state, _) = Engine.enter(state: state, at: CGPoint(x: 100, y: 7), now: 0, config: cfg)

        // 2pt drift, tolerance is 4pt — must be ignored entirely.
        let (afterJitter, effect) = Engine.move(state: state, to: CGPoint(x: 102, y: 7), now: 0.05, config: cfg)
        XCTAssertEqual(effect, .none, "jitter within tolerance must not re-arm")
        XCTAssertEqual(afterJitter, state, "jitter within tolerance must not touch the anchor/deadline")

        // The ORIGINAL deadline (from t=0) still fires on schedule.
        let (committed, commitEffect) = Engine.timerFired(state: afterJitter, now: cfg.dwellDuration)
        XCTAssertEqual(committed, .committed)
        XCTAssertEqual(commitEffect, .commit)
    }

    /// Guards against an infinite-delay livelock: many tiny sub-tolerance
    /// moves in a row (simulating hand tremor / a noisy high-poll-rate
    /// mouse) must never keep pushing the deadline out.
    func test_manySubToleranceJitters_neverExtendDeadline() {
        var state = Engine.State.idle
        (state, _) = Engine.enter(state: state, at: CGPoint(x: 100, y: 7), now: 0, config: cfg)
        for i in 1...20 {
            let t = Double(i) * 0.005 // 5ms apart, well within the 150ms dwell
            let (next, effect) = Engine.move(state: state, to: CGPoint(x: 100 + CGFloat(i % 3), y: 7), now: t, config: cfg)
            XCTAssertEqual(effect, .none, "iteration \(i) must stay within tolerance")
            state = next
        }
        let (committed, effect) = Engine.timerFired(state: state, now: cfg.dwellDuration)
        XCTAssertEqual(committed, .committed)
        XCTAssertEqual(effect, .commit)
    }

    // MARK: - Movement beyond tolerance re-arms the dwell

    func test_movementBeyondTolerance_reArmsWithNewDeadline() {
        var state = Engine.State.idle
        (state, _) = Engine.enter(state: state, at: CGPoint(x: 100, y: 7), now: 0, config: cfg)

        let (rearmed, effect) = Engine.move(state: state, to: CGPoint(x: 110, y: 7), now: 0.05, config: cfg)
        XCTAssertEqual(effect, .armTimer(deadline: 0.05 + cfg.dwellDuration))
        XCTAssertEqual(rearmed, .pending(anchor: CGPoint(x: 110, y: 7), commitDeadline: 0.05 + cfg.dwellDuration))

        // The OLD deadline (0.15) must not fire anymore.
        let (stillPending, noEffect) = Engine.timerFired(state: rearmed, now: cfg.dwellDuration)
        XCTAssertEqual(noEffect, .none)
        XCTAssertEqual(stillPending, rearmed)

        // The NEW deadline (0.20) does fire.
        let (committed, commitEffect) = Engine.timerFired(state: rearmed, now: 0.05 + cfg.dwellDuration)
        XCTAssertEqual(committed, .committed)
        XCTAssertEqual(commitEffect, .commit)
    }

    // MARK: - Direct manipulation (mouseDown) always wins immediately

    func test_commitImmediately_fromIdle() {
        let (state, effect) = Engine.commitImmediately(state: .idle)
        XCTAssertEqual(state, .committed)
        XCTAssertEqual(effect, .commit)
    }

    func test_commitImmediately_fromPending_bypassesDwell() {
        let pending = Engine.State.pending(anchor: .zero, commitDeadline: 100) // deadline far in the future
        let (state, effect) = Engine.commitImmediately(state: pending)
        XCTAssertEqual(state, .committed)
        XCTAssertEqual(effect, .commit)
    }

    func test_commitImmediately_fromExitGrace() {
        let (state, effect) = Engine.commitImmediately(state: .exitGrace(graceDeadline: 100))
        XCTAssertEqual(state, .committed)
        XCTAssertEqual(effect, .commit)
    }

    func test_commitImmediately_idempotent_whenAlreadyCommitted() {
        let (state, effect) = Engine.commitImmediately(state: .committed)
        XCTAssertEqual(state, .committed)
        XCTAssertEqual(effect, .none, "must not re-fire .commit (caller would needlessly re-cancel/re-apply)")
    }

    // MARK: - Exit resets; committed exit gets a short grace before resetting

    func test_exitFromPending_resetsImmediately_noGrace() {
        let pending = Engine.State.pending(anchor: .zero, commitDeadline: 5)
        let (state, effect) = Engine.exit(state: pending, now: 1, config: cfg)
        XCTAssertEqual(state, .idle, "nothing is visible yet — reset immediately")
        XCTAssertEqual(effect, .cancelTimer, "the in-flight dwell timer must be cancelled, or it would fire later and thicken the bar after the pointer already left")
    }

    /// Regression pin for the bug ProgressHoverIntentViewTests caught: a
    /// sub-tolerance jitter's `.none` and an exit-from-pending's timer
    /// cancellation must NOT collapse into the same effect, because a
    /// caller applying effects generically (cancel-then-branch) would
    /// otherwise cancel the still-wanted dwell timer on every jitter move.
    func test_noneAndCancelTimer_areDistinctEffects() {
        XCTAssertNotEqual(Engine.Effect.none, Engine.Effect.cancelTimer)
    }

    func test_exitFromCommitted_entersGraceThenResetsAfterGraceElapses() {
        let (grace, armEffect) = Engine.exit(state: .committed, now: 0, config: cfg)
        XCTAssertEqual(grace, .exitGrace(graceDeadline: cfg.exitGrace))
        XCTAssertEqual(armEffect, .armTimer(deadline: cfg.exitGrace))

        // Not yet — the bar must still read as committed to the caller
        // (uncommit has not fired) right up to the deadline.
        let (notYet, noEffect) = Engine.timerFired(state: grace, now: cfg.exitGrace - 0.001)
        XCTAssertEqual(noEffect, .none)
        XCTAssertEqual(notYet, grace)

        let (idle, uncommitEffect) = Engine.timerFired(state: grace, now: cfg.exitGrace)
        XCTAssertEqual(idle, .idle)
        XCTAssertEqual(uncommitEffect, .uncommit)
    }

    func test_exitFromIdleOrExitGrace_isNoOp() {
        let (idleState, idleEffect) = Engine.exit(state: .idle, now: 1, config: cfg)
        XCTAssertEqual(idleState, .idle)
        XCTAssertEqual(idleEffect, .none)

        let grace = Engine.State.exitGrace(graceDeadline: 5)
        let (graceState, graceEffect) = Engine.exit(state: grace, now: 1, config: cfg)
        XCTAssertEqual(graceState, grace)
        XCTAssertEqual(graceEffect, .none)
    }

    // MARK: - Re-entry within the exit grace resumes with zero visual change

    func test_reEntryWithinGrace_resumesCommittedWithNoFlicker() {
        let (grace, _) = Engine.exit(state: .committed, now: 0, config: cfg)

        // Re-entered at 0.05s, still inside the 0.08s grace window.
        let (resumed, effect) = Engine.enter(state: grace, at: CGPoint(x: 100, y: 7), now: 0.05, config: cfg)
        XCTAssertEqual(resumed, .committed)
        XCTAssertEqual(effect, .commit, "idempotent re-affirmation — the caller's setter is a guarded no-op if already true")

        // A stale grace-timer fire against the now-`.committed` state must
        // never uncommit (defense in depth; the real view also cancels the
        // scheduled work item on every transition, so this should not
        // normally be reachable).
        let (afterStaleFire, staleEffect) = Engine.timerFired(state: resumed, now: cfg.exitGrace)
        XCTAssertEqual(afterStaleFire, .committed)
        XCTAssertEqual(staleEffect, .none)
    }

    func test_reEntryAfterGraceExpires_isFreshEntry() {
        let (grace, _) = Engine.exit(state: .committed, now: 0, config: cfg)
        let (idle, uncommitEffect) = Engine.timerFired(state: grace, now: cfg.exitGrace)
        XCTAssertEqual(idle, .idle)
        XCTAssertEqual(uncommitEffect, .uncommit)

        // A subsequent entry behaves exactly like any fresh entry — full
        // dwell required again, not a partial/resumed one.
        let (pending, effect) = Engine.enter(state: idle, at: CGPoint(x: 50, y: 7), now: cfg.exitGrace + 1, config: cfg)
        XCTAssertEqual(pending, .pending(anchor: CGPoint(x: 50, y: 7), commitDeadline: cfg.exitGrace + 1 + cfg.dwellDuration))
        XCTAssertEqual(effect, .armTimer(deadline: cfg.exitGrace + 1 + cfg.dwellDuration))
    }

    // MARK: - Defensive no-ops (states/events that should not occur via real AppKit event sequences)

    func test_enter_isNoOp_whenAlreadyPendingOrCommitted() {
        let pending = Engine.State.pending(anchor: CGPoint(x: 1, y: 1), commitDeadline: 9)
        let (p1, e1) = Engine.enter(state: pending, at: CGPoint(x: 99, y: 99), now: 0, config: cfg)
        XCTAssertEqual(p1, pending, "must not clobber the in-flight anchor/deadline")
        XCTAssertEqual(e1, .none)

        let (c1, e2) = Engine.enter(state: .committed, at: CGPoint(x: 99, y: 99), now: 0, config: cfg)
        XCTAssertEqual(c1, .committed)
        XCTAssertEqual(e2, .none)
    }

    func test_move_isNoOp_inNonPendingStates() {
        for state: Engine.State in [.idle, .committed, .exitGrace(graceDeadline: 5)] {
            let (next, effect) = Engine.move(state: state, to: CGPoint(x: 500, y: 500), now: 1, config: cfg)
            XCTAssertEqual(next, state)
            XCTAssertEqual(effect, .none)
        }
    }

    func test_timerFired_staleOrEarly_isNoOp() {
        let (idleState, idleEffect) = Engine.timerFired(state: .idle, now: 100)
        XCTAssertEqual(idleState, .idle)
        XCTAssertEqual(idleEffect, .none)

        let (committedState, committedEffect) = Engine.timerFired(state: .committed, now: 100)
        XCTAssertEqual(committedState, .committed)
        XCTAssertEqual(committedEffect, .none)
    }

    // MARK: - resolve() delegates to enter/exit (used by the passive re-sync path)

    func test_resolve_insideRegion_matchesEnter() {
        let enterResult = Engine.enter(state: .idle, at: CGPoint(x: 10, y: 10), now: 3, config: cfg)
        let resolveResult = Engine.resolve(state: .idle, insideRegion: true, at: CGPoint(x: 10, y: 10), now: 3, config: cfg)
        XCTAssertEqual(resolveResult.0, enterResult.0)
        XCTAssertEqual(resolveResult.1, enterResult.1)
    }

    func test_resolve_outsideRegion_matchesExit() {
        let exitResult = Engine.exit(state: .committed, now: 3, config: cfg)
        let resolveResult = Engine.resolve(state: .committed, insideRegion: false, at: CGPoint(x: 10, y: 10), now: 3, config: cfg)
        XCTAssertEqual(resolveResult.0, exitResult.0)
        XCTAssertEqual(resolveResult.1, exitResult.1)
    }

    // MARK: - Config is actually threaded through (not hardcoded)

    func test_customConfig_dwellAndToleranceAreRespected() {
        let custom = Engine.Config(dwellDuration: 1.0, movementTolerance: 50, exitGrace: 0.2)

        var state = Engine.State.idle
        (state, _) = Engine.enter(state: state, at: CGPoint(x: 0, y: 0), now: 0, config: custom)

        // 30pt move is within the custom 50pt tolerance — must not re-arm.
        let (afterSmallMove, smallEffect) = Engine.move(state: state, to: CGPoint(x: 30, y: 0), now: 0.1, config: custom)
        XCTAssertEqual(smallEffect, .none)
        XCTAssertEqual(afterSmallMove, state)

        // The custom 1.0s dwell must still be in force at t=0.15 (the
        // DEFAULT dwell would have already committed by now).
        let (notYet, noEffect) = Engine.timerFired(state: afterSmallMove, now: 0.15)
        XCTAssertEqual(noEffect, .none)
        XCTAssertEqual(notYet, afterSmallMove)

        let (committed, effect) = Engine.timerFired(state: afterSmallMove, now: 1.0)
        XCTAssertEqual(committed, .committed)
        XCTAssertEqual(effect, .commit)
    }

    func test_defaultConfig_matchesProductionTokens() {
        XCTAssertEqual(Engine.Config.default.dwellDuration, MicroInteractionFeel.Tokens.progressHoverIntentDwellDuration)
        XCTAssertEqual(Engine.Config.default.movementTolerance, MicroInteractionFeel.Tokens.progressHoverIntentMovementTolerance)
        XCTAssertEqual(Engine.Config.default.exitGrace, MicroInteractionFeel.Tokens.progressHoverIntentExitGrace)
    }
}
