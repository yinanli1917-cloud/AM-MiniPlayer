/**
 * [INPUT]: Foundation only.
 * [OUTPUT]: Exports TourStep, TourStepState, TourRunStatus, TourPhase,
 *           TourSignal, TourSnapshot, TourEffect, TourHaptic, TourEvent,
 *           TourState — the pure value types the "认识 nanoPod" tour state
 *           machine (TourMachine) operates on.
 * [POS]: MusicMiniPlayerCore/Onboarding model layer. Replaces the C6
 *        OnboardingState/OnboardingView three-page wizard
 *        (docs/design/2026-09-25-onboarding/proposal.md v3.3).
 */

import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourStep
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The seven steps, in fixed order (proposal §3.1/§5.1). `connect` only ever
/// runs a real card when Automation isn't authorized yet — otherwise it is
/// prefilled at `.start`/`.resume` and never shown (§3.3 "G", §5.4).
public enum TourStep: String, CaseIterable, Codable, Sendable {
    case connect, reveal, corners, lyrics, translate, moveTuck, back

    /// Fixed order — also the ring's fill order. `TourMachine.next(after:)`
    /// walks this array; nothing outside this file should hardcode the order.
    public static let orderedSteps: [TourStep] = [.connect, .reveal, .corners, .lyrics, .translate, .moveTuck, .back]

    /// Schema version this step was introduced in (§5.6). All v3 steps are
    /// 2 — C6's three-page wizard (schema 1) had no equivalent steps, so a
    /// future schema bump is what this field exists for.
    public var introducedIn: Int { 2 }

    /// How many beats must all be true before the step itself completes
    /// (§3.1's user action column, §5.2).
    public var beatCount: Int {
        switch self {
        case .connect, .lyrics, .translate: return 1
        case .reveal, .corners, .moveTuck, .back: return 2
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourStepState / TourRunStatus
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public enum TourStepState: String, Codable, Sendable, Equatable {
    case pending, completed, skipped, deferred
}

/// §5.3's `nanoPodTourStatus`.
public enum TourRunStatus: String, Codable, Sendable, Equatable {
    case notStarted, inProgress, completed, skipped
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourPhase
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public enum TourPhase: Equatable, Sendable {
    case idle(deferredArmed: Bool)
    case welcome
    case step(TourStep, beats: [Bool])
    /// A completed step's card has faded and the next card hasn't landed
    /// yet — real time (or a fake clock in tests) must pass via
    /// `TourEvent.advanceTransition` before `to` (or finale, if `to == nil`)
    /// shows. Also used for the 1.1s "这首不用翻" deferral note (§3.3 S4′).
    case transitioning(from: TourStep?, to: TourStep?)
    case finale
    /// The one card allowed to reappear after the tour otherwise tore down
    /// (§3.3 S4L) — the deferred-translation tip, shown beside the
    /// translate button once a foreign-language song plays.
    case deferredTip(TourStep)
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourSignal
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// One per real completion hook (§6). `panelSettled`/`panelTucked`/
/// `panelExpanded` carry their own `TourEvent` cases instead (they need
/// extra payload, or drive a step transition on their own), so they are not
/// signals here.
public enum TourSignal: Equatable, Sendable {
    case automationAuthorized
    case controlsRevealed
    case isPlaying
    case audioOutputMenuOpened
    case musicButtonTapped
    case onLyricsPage
    case translationEnabled
    /// The capsule peeked out of the tucked sliver — `LiquidEdgeState ==
    /// .floating` (S6 beat ①, "鼠标停上去，它会探出来").
    case liquidEdgeFloating
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourSnapshot
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Read-only context the reducer consults but never mutates.
public struct TourSnapshot: Equatable, Sendable {
    public var automationAuthorized: Bool
    public var canTranslate: Bool
    public var showTranslation: Bool

    public init(automationAuthorized: Bool = false, canTranslate: Bool = false, showTranslation: Bool = false) {
        self.automationAuthorized = automationAuthorized
        self.canTranslate = canTranslate
        self.showTranslation = showTranslation
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourEvent
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public enum TourEvent: Equatable, Sendable {
    case start
    case stopTour
    case skipStep
    case signal(TourSignal)
    case anchorUnavailable(TourStep)
    case anchorRestored(TourStep)
    case panelHidden
    case panelShown
    case panelMoving
    case panelSettled(corner: ScreenCorner?)
    case panelTucked
    case panelExpanded
    case canTranslateBecameTrue(secondsIntoSong: Double)
    case songChanged
    case launch
    case resume(completed: Set<TourStep>)
    case appWillTerminate
    case finaleDismiss
    /// Not in the proposal's §5.1 sketch verbatim — added so `.transitioning`
    /// (real or fake clock, §11.1 "假时钟驱动 transitioning") is the thing
    /// that drives the machine on to the next card/finale, instead of the
    /// reducer jumping there synchronously inside the completion event.
    /// `TourController` sends this after the feedback duration (§8.1: 800ms,
    /// §3.3 S4′: 1.1s for the deferral note).
    case advanceTransition
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourHaptic / TourEffect
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public enum TourHaptic: Equatable, Sendable {
    case levelChange
    case alignment
}

/// What `TourController` (AppKit, @MainActor) must DO in response to a
/// reducer transition. The reducer never touches a window — it only emits
/// these — so `TourMachineTests` can assert on values instead of window
/// state (§11.1).
public enum TourEffect: Equatable, Sendable {
    case showWelcomeCard(resuming: Bool)
    case showStepCard(TourStep)
    case showDeferralNote
    case showFinaleCard(deferred: Bool)
    case showDeferredTipCard
    case hideCard
    case checkBeat(TourStep, index: Int)
    case growRing(to: Int)
    case spark
    case pulseRing
    case confetti
    case haptic(TourHaptic)
    case relocateCardToPanel
    case persist
    case armDeferredWatcher
    case cancelDeferredWatcher
    case teardown
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourState
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The machine's full state. `phase` alone can't carry step-by-step
/// completion across `idle`/`welcome`/`finale` (where no `TourStep` is
/// "current"), so it lives here instead.
public struct TourState: Equatable, Sendable {
    public var status: TourRunStatus
    public var phase: TourPhase
    public var stepStates: [TourStep: TourStepState]
    /// Beats recorded against a step BEFORE its own card ever showed (the
    /// user did the thing out of order, or it was already true when the
    /// tour started) — §5.2 "乱序完成" / §5.4 "提前做过". Consulted by
    /// `TourMachine.enterStep` when that step's turn comes.
    public var pendingBeats: [TourStep: [Bool]]
    /// Songs tried since the deferred-translate watcher armed (§5.2, capped
    /// at 3).
    public var deferredAttempts: Int
    /// Launches since the deferred-translate watcher armed (§5.2, capped at
    /// 20).
    public var deferredLaunches: Int
    /// The S4L card may show at most once per launch.
    public var deferredShownThisLaunch: Bool
    /// Auto-resume count (§5.4, capped at 3) — how many times `.start` has
    /// silently resumed an `inProgress` tour across app launches.
    public var resumeCount: Int

    public init(
        status: TourRunStatus = .notStarted,
        phase: TourPhase = .idle(deferredArmed: false),
        stepStates: [TourStep: TourStepState] = [:],
        pendingBeats: [TourStep: [Bool]] = [:],
        deferredAttempts: Int = 0,
        deferredLaunches: Int = 0,
        deferredShownThisLaunch: Bool = false,
        resumeCount: Int = 0
    ) {
        self.status = status
        self.phase = phase
        self.stepStates = stepStates
        self.pendingBeats = pendingBeats
        self.deferredAttempts = deferredAttempts
        self.deferredLaunches = deferredLaunches
        self.deferredShownThisLaunch = deferredShownThisLaunch
        self.resumeCount = resumeCount
    }

    /// Completed steps only — matches the ring's fill count. `.skipped` and
    /// `.deferred` steps never grow the ring (§5.2, §8.2).
    public var completedCount: Int {
        TourStep.orderedSteps.filter { stepStates[$0] == .completed }.count
    }

    public var completedSteps: Set<TourStep> {
        Set(TourStep.orderedSteps.filter { stepStates[$0] == .completed })
    }

    /// True once a step will never need its own card again — completed,
    /// skipped, or deferred (deferred steps route through automatically
    /// every time their turn comes; §3.3 S4′).
    public func isResolved(_ step: TourStep) -> Bool {
        switch stepStates[step] {
        case .completed?, .skipped?, .deferred?: return true
        default: return false
        }
    }

    public var hasDeferredTranslate: Bool { stepStates[.translate] == .deferred }
}
