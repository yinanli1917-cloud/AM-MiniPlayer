/**
 * [INPUT]: TourModel's TourStep/TourState/TourEvent/TourSnapshot/TourEffect.
 * [OUTPUT]: Exports TourMachine — the pure reducer `(state, event, snapshot)
 *           -> (state, effects)` driving the "认识 nanoPod" tour.
 * [POS]: MusicMiniPlayerCore/Onboarding. Same shape as LiquidEdgeReducer —
 *        no window, no Combine, no clock; `TourController` (AppKit) is the
 *        only thing that touches a window or schedules a timer.
 */

import Foundation

public enum TourMachine {

    /// The step after `step` in fixed order, or `nil` past the last one.
    public static func next(after step: TourStep) -> TourStep? {
        let steps = TourStep.orderedSteps
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return nil }
        return steps[i + 1]
    }

    /// Which step + beat index a completion hook maps to (§6). `.translate`
    /// via `.translationEnabled` is not a tour step: `handleSignal` treats it as
    /// the translation tip's completion (S4L closing choreography when the tip card is
    /// up, a silent "done" otherwise) — this table only says WHERE the beat lands.
    static func target(for signal: TourSignal) -> (TourStep, Int) {
        switch signal {
        case .automationAuthorized: return (.connect, 0)
        case .controlsRevealed: return (.reveal, 0)
        case .isPlaying: return (.reveal, 1)
        case .audioOutputMenuOpened: return (.corners, 0)
        case .musicButtonTapped: return (.corners, 1)
        case .onLyricsPage: return (.lyrics, 0)
        case .translationEnabled: return (.translate, 0)
        case .liquidEdgeFloating: return (.back, 0)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - reduce
    // ─────────────────────────────────────────────────────────────

    public static func reduce(_ state: TourState, _ event: TourEvent, snapshot: TourSnapshot) -> (TourState, [TourEffect]) {
        var state = state
        var effects: [TourEffect] = []

        switch event {

        case .start:
            if snapshot.automationAuthorized { state.stepStates[.connect] = .completed }
            state.status = .inProgress
            let (nextState, entryEffects) = enterStep(.connect, state: state, snapshot: snapshot)
            state = nextState
            effects = entryEffects + [.persist]

        case .resume(let completed):
            for step in completed { state.stepStates[step] = .completed }
            state.status = .inProgress
            state.resumeCount += 1
            let (nextState, entryEffects) = enterStep(.connect, state: state, snapshot: snapshot)
            state = nextState
            effects = entryEffects + [.persist]

        case .stopTour:
            if case .deferredTip = state.phase {
                // The translation tip's own "dismiss": the tip is done with, the tour's status is not touched.
                state.stepStates[.translate] = .skipped
                state.phase = .idle(deferredArmed: false)
                effects = [.hideCard, .cancelDeferredWatcher, .persist]
                break
            }
            // A user who stops a tour that actually ran (a step, the finale) still gets the translation tip later; one who
            // says "later" on the welcome card never started it and gets none.
            var ranTheTour = false
            switch state.phase {
            case .step, .transitioning, .finale: ranTheTour = true
            case .idle, .welcome, .deferredTip: break
            }
            state.status = .skipped
            let armTip = ranTheTour && armTranslateTip(&state)
            state.phase = .idle(deferredArmed: armTip)
            effects = [.hideCard, .teardown]
            if armTip { effects.append(.armDeferredWatcher) }
            effects.append(.persist)

        case .skipStep:
            if case .step(let s, _) = state.phase {
                state.stepStates[s] = .skipped
                let (nextState, entryEffects) = enterStep(next(after: s), state: state, snapshot: snapshot)
                state = nextState
                effects = entryEffects + [.persist]
            }

        case .signal(let signal):
            (state, effects) = handleSignal(signal, state: state, snapshot: snapshot)

        case .anchorUnavailable, .anchorRestored, .panelHidden, .panelShown, .panelMoving:
            // The card window itself hides/shows/relocates in response to
            // these — no step transition, so no reducer work.
            break

        case .panelSettled(let corner):
            // The move step: corner -> across the diagonal -> the edge. The first beat ticks for any corner but the one the
            // panel started in. The diagonal beat ticks only for the corner ACROSS the screen from the one the panel was in
            // just before this move (`moveLastCorner`, which follows every settle, ticking or not); a corner next door ticks
            // nothing and the card says so. The edge beat is `panelTucked`'s.
            if case .step(.moveTuck, var beats) = state.phase, beats.count == 3, let corner {
                let before = state.moveLastCorner
                state.moveLastCorner = corner
                if !beats[0] {
                    if corner != state.moveStartCorner {
                        beats[0] = true
                        state.cornersLanded.append(corner)
                        state.phase = .step(.moveTuck, beats: beats)
                        effects = [.checkBeat(.moveTuck, index: 0), .haptic(.levelChange), .relocateCardToPanel, .persist]
                    }
                } else if !beats[1], let before, corner != before {
                    if corner == before.opposite {
                        beats[1] = true
                        state.cornersLanded.append(corner)
                        state.phase = .step(.moveTuck, beats: beats)
                        effects = [.checkBeat(.moveTuck, index: 1), .haptic(.levelChange), .relocateCardToPanel, .persist]
                    } else {
                        effects = [.relocateCardToPanel]   // nothing ticks: the card follows the panel and says what to do
                    }
                }
            }

        case .panelTucked:
            let alreadyOnMoveTuckCard: Bool = { if case .step(.moveTuck, _) = state.phase { return true }; return false }()
            let mayTuckFromAnyStep: Bool = { if case .step = state.phase { return true }; return false }()
            if (alreadyOnMoveTuckCard || mayTuckFromAnyStep), !state.isResolved(.moveTuck) {
                state.stepStates[.moveTuck] = .completed
                effects.append(.growRing(to: state.completedCount))
                let (nextState, entryEffects) = enterStep(.back, state: state, snapshot: snapshot)
                state = nextState
                effects += entryEffects + [.persist]
            }

        case .panelExpanded:
            if case .step(.back, let beats) = state.phase, beats.count == 2 {
                state.stepStates[.back] = .completed
                effects = [.checkBeat(.back, index: 0), .checkBeat(.back, index: 1),
                           .growRing(to: state.completedCount), .haptic(.alignment), .pulseRing, .confetti]
                state.status = .inProgress // still needs finaleDismiss/timeout to become .completed
                state.phase = .finale
                effects.append(.showFinaleCard)
                effects.append(.persist)
            }

        case .canTranslateBecameTrue(let seconds):
            // The watcher only sends this while the panel is up, on the lyrics page, with the button really there. The tip
            // is armed only after the tour ended, so an idle armed phase also means no tour card is on screen.
            if case .idle(let armed) = state.phase, armed, seconds >= 3, !state.deferredShownThisLaunch {
                state.deferredShownThisLaunch = true
                if snapshot.showTranslation {
                    // Already on (the user opened it from Settings) — nothing
                    // to teach; complete silently, cancel the watcher.
                    state.stepStates[.translate] = .completed
                    state.phase = .idle(deferredArmed: false)
                    effects = [.cancelDeferredWatcher, .persist]
                } else {
                    state.phase = .deferredTip(.translate)
                    effects = [.showDeferredTipCard]
                }
            }

        case .deferredTipUnavailable:
            // Left the lyrics page (or the button went away) with the tip open: it closes without costing an attempt, and
            // `deferredShownThisLaunch` stays set, so it does not come back in this launch.
            if case .deferredTip = state.phase {
                state.phase = .idle(deferredArmed: true)
                effects = [.hideCard]
            }

        case .songChanged:
            // Only closes an OPEN S4L card (the user didn't act before the
            // song changed) — `deferredShownThisLaunch` stays true, because
            // the card may show at most once per launch (§11.1); "up to 3
            // songs" (§3.3 S4L) is spent one attempt per LAUNCH that ever got
            // an unfinished tip, not by re-showing repeatedly within one.
            if case .deferredTip(.translate) = state.phase {
                state.deferredAttempts += 1
                effects.append(.hideCard)
                if state.deferredAttempts >= 3 {
                    state.stepStates[.translate] = .skipped
                    state.phase = .idle(deferredArmed: false)
                    effects.append(.cancelDeferredWatcher)
                } else {
                    state.phase = .idle(deferredArmed: true)
                }
                effects.append(.persist)
            }

        case .launch:
            // Two independent jobs share this event, matched by phase:
            // an armed deferred watcher counts launches toward its 20-launch
            // cap (§5.2); otherwise, if the tour hasn't been explicitly
            // stopped or finished, this is TourController's cue (already
            // gated by `TourPreconditions.shouldPresent`) to show the S0
            // welcome card — "见面" fresh, or its "欢迎回来" resume variant
            // (§5.4).
            if case .idle(let armed) = state.phase {
                if armed {
                    state.deferredLaunches += 1
                    state.deferredShownThisLaunch = false
                    if state.deferredLaunches >= 20 {
                        state.stepStates[.translate] = .skipped
                        state.phase = .idle(deferredArmed: false)
                        effects = [.cancelDeferredWatcher, .persist]
                    }
                } else if state.status == .notStarted || state.status == .inProgress {
                    state.phase = .welcome
                    effects = [.showWelcomeCard(resuming: state.status == .inProgress)]
                }
            }

        case .appWillTerminate:
            effects = [.persist]

        case .advanceTransition:
            if case .transitioning(_, let to) = state.phase {
                let (nextState, entryEffects) = enterStep(to, state: state, snapshot: snapshot)
                state = nextState
                effects = entryEffects + [.persist]
            }

        case .finaleDismiss:
            if case .finale = state.phase {
                let armTip = armTranslateTip(&state)
                state.status = .completed
                state.phase = .idle(deferredArmed: armTip)
                effects = [.hideCard, .teardown]
                if armTip { effects.append(.armDeferredWatcher) }
                effects.append(.persist)
            }
        }

        return (state, effects)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Beat signals (§5.2, §6)
    // ─────────────────────────────────────────────────────────────

    private static func handleSignal(_ signal: TourSignal, state: TourState, snapshot: TourSnapshot) -> (TourState, [TourEffect]) {
        var state = state
        var effects: [TourEffect] = []
        let (target, beatIndex) = TourMachine.target(for: signal)

        // The S4L deferred-tip card closes through its own choreography
        // (§3.3 S4L): last segment fills, spark, haptic .alignment, a quiet
        // ring pulse (no confetti — that already played at S7), watcher
        // cancelled, back to idle. The tip card shows a closed ring whatever
        // the tour reached, so the ring it seals is always the full one.
        if case .deferredTip(let tip) = state.phase, tip == target {
            state.stepStates[tip] = .completed
            effects = [.checkBeat(tip, index: beatIndex), .growRing(to: TourStep.orderedSteps.count),
                       .spark, .haptic(.alignment), .pulseRing, .cancelDeferredWatcher]
            state.phase = .idle(deferredArmed: false)
            effects.append(.persist)
            return (state, effects)
        }

        // Translation is not a tour step. Toggling it anywhere else (Settings, the button before the tip ever showed, mid-tour)
        // means there is nothing left to teach: the tip is done, silently, and a running tour is left alone.
        if target == .translate {
            switch state.stepStates[.translate] {
            case .completed?, .skipped?: return (state, effects)
            default: break
            }
            state.stepStates[.translate] = .completed
            if case .idle(true) = state.phase {
                state.phase = .idle(deferredArmed: false)
                effects.append(.cancelDeferredWatcher)
            }
            effects.append(.persist)
            return (state, effects)
        }

        guard !state.isResolved(target) else { return (state, effects) }

        if case .step(let current, var beats) = state.phase, current == target {
            guard beats.indices.contains(beatIndex), !beats[beatIndex] else { return (state, effects) }
            beats[beatIndex] = true
            state.phase = .step(current, beats: beats)
            effects = [.checkBeat(current, index: beatIndex), .haptic(.levelChange)]
            if beats.allSatisfy({ $0 }) {
                state.stepStates[current] = .completed
                effects += [.growRing(to: state.completedCount), .spark]
                state.phase = .transitioning(from: current, to: TourMachine.next(after: current))
            }
            effects.append(.persist)
            return (state, effects)
        }

        // Out-of-order / pre-emptive (§5.2 "乱序完成", §5.4 "提前做过"):
        // record the beat against `target` even though its card isn't
        // showing (or already passed by). Only a FULL step completion here
        // grows the ring — a lone beat toward a still-partial future step
        // stays silent until that step's own card catches up.
        var beats = state.pendingBeats[target] ?? Array(repeating: false, count: target.beatCount)
        guard beats.indices.contains(beatIndex), !beats[beatIndex] else { return (state, effects) }
        beats[beatIndex] = true
        state.pendingBeats[target] = beats
        if beats.allSatisfy({ $0 }) {
            state.stepStates[target] = .completed
            effects = [.growRing(to: state.completedCount), .spark, .persist]
        }
        return (state, effects)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Entry (walks past already-resolved/prefilled steps)
    // ─────────────────────────────────────────────────────────────

    /// Walks forward from `step`, skipping any step that's already resolved
    /// (completed/skipped/deferred) or whose pending beats were all already
    /// satisfied before its card ever showed, and lands on the first step
    /// that needs a real card — or `.finale` if none remain.
    static func enterStep(_ step: TourStep?, state: TourState, snapshot: TourSnapshot) -> (TourState, [TourEffect]) {
        var state = state
        var effects: [TourEffect] = []
        var cursor = step

        while let s = cursor {
            if state.isResolved(s) {
                cursor = TourMachine.next(after: s)
                continue
            }

            // The panel is already on the lyrics page: nothing to open.
            if s == .lyrics, snapshot.onLyricsPage {
                state.stepStates[.lyrics] = .completed
                effects.append(.growRing(to: state.completedCount))
                cursor = TourMachine.next(after: s)
                continue
            }

            let initialBeats = state.pendingBeats[s] ?? Array(repeating: false, count: s.beatCount)
            if !initialBeats.isEmpty, initialBeats.allSatisfy({ $0 }) {
                state.stepStates[s] = .completed
                effects.append(.growRing(to: state.completedCount))
                cursor = TourMachine.next(after: s)
                continue
            }

            if s == .moveTuck {
                state.moveStartCorner = snapshot.panelCorner
                state.moveLastCorner = snapshot.panelCorner
                state.cornersLanded = []
            }
            state.phase = .step(s, beats: initialBeats)
            effects.append(.showStepCard(s))
            return (state, effects)
        }

        state.phase = .finale
        effects.append(.showFinaleCard)
        return (state, effects)
    }

    /// The tour is over (finished or stopped after it ran): the standalone translation tip arms, unless it is already done
    /// with (the user turned translation on themselves, or it gave up). True when it is armed after this call.
    static func armTranslateTip(_ state: inout TourState) -> Bool {
        switch state.stepStates[.translate] {
        case .completed?, .skipped?: return false
        default:
            state.stepStates[.translate] = .deferred
            return true
        }
    }
}
