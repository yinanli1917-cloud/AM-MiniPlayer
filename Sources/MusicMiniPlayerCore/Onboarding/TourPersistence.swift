/**
 * [INPUT]: Foundation (UserDefaults), TourModel's TourState/TourStep/TourStepState/TourRunStatus.
 * [OUTPUT]: Exports TourPersistence — UserDefaults round-trip for TourState
 *           (§5.3), the one-time legacy-C6-key read (§5.6), and the pure
 *           `shouldPresent` precondition gate (§5.5).
 * [POS]: MusicMiniPlayerCore/Onboarding. Replaces OnboardingState's
 *        `nanoPodOnboardingCompleted`/`nanoPodOnboardingSchema` persistence;
 *        `OnboardingState` itself keeps only the Automation/MusicKit
 *        authorization queries (still used by the new "connect" step).
 */

import Foundation

public enum TourPersistence {

    // MARK: Keys (§5.3)

    public static let schemaKey = "nanoPodTourSchema"
    public static let statusKey = "nanoPodTourStatus"
    public static let completedStepsKey = "nanoPodTourCompletedSteps"
    public static let resumeCountKey = "nanoPodTourResumeCount"
    public static let deferredKey = "nanoPodTourDeferred"
    public static let deferredLaunchesKey = "nanoPodTourDeferredLaunches"

    /// Current content schema. Steps whose `introducedIn` is above a saved
    /// value older than this are "new" for a returning user (§5.6).
    public static let currentSchema = 2

    /// C6's keys, read once for the schema-1→2 handoff (§5.3's key table
    /// footnote). All v3 steps are `introducedIn == 2`, i.e. new relative to
    /// C6's schema 1 — so a user who finished the old three-page wizard gets
    /// the SAME fresh v3 tour as anyone else; there is no per-step progress
    /// to carry over. This function's only real job is to make the read
    /// happen exactly once (idempotent — guarded by `schemaKey` already
    /// being present) so old keys are never consulted again after this.
    static func migrateLegacyOnboardingKeysIfNeeded(_ defaults: UserDefaults) {
        guard defaults.object(forKey: schemaKey) == nil else { return }
        _ = defaults.bool(forKey: "nanoPodOnboardingCompleted")
        _ = defaults.integer(forKey: "nanoPodOnboardingSchema")
        defaults.set(currentSchema, forKey: schemaKey)
    }

    // MARK: Load / Save

    public static func load(from defaults: UserDefaults = .standard) -> TourState {
        migrateLegacyOnboardingKeysIfNeeded(defaults)

        let status = TourRunStatus(rawValue: defaults.string(forKey: statusKey) ?? "") ?? .notStarted
        let completedRaw = defaults.stringArray(forKey: completedStepsKey) ?? []
        var stepStates: [TourStep: TourStepState] = [:]
        for raw in completedRaw {
            if let step = TourStep(rawValue: raw) { stepStates[step] = .completed }
        }

        // Translation stopped being a tour step (2026-10-06). Old saved states still carry `translate`: completed means the tip
        // is done; the old "deferred" record (translate was waiting for a song that could be translated) is exactly "tip armed".
        // (An old skipped translate was never persisted, so it reads as no record: no tip, as before.)
        let deferredDict = defaults.dictionary(forKey: deferredKey) as? [String: Int] ?? [:]
        var deferredAttempts = 0
        if let translateAttempts = deferredDict[TourStep.translate.rawValue], stepStates[.translate] != .completed {
            stepStates[.translate] = .deferred
            deferredAttempts = translateAttempts
        }

        // The tip's watcher runs only once the tour has ended; a tour still in progress arms it at its own end.
        let tourEnded = status == .completed || status == .skipped
        return TourState(
            status: status,
            phase: .idle(deferredArmed: tourEnded && stepStates[.translate] == .deferred),
            stepStates: stepStates,
            pendingBeats: [:],
            deferredAttempts: deferredAttempts,
            deferredLaunches: defaults.integer(forKey: deferredLaunchesKey),
            deferredShownThisLaunch: false,
            resumeCount: defaults.integer(forKey: resumeCountKey)
        )
    }

    public static func save(_ state: TourState, to defaults: UserDefaults = .standard) {
        defaults.set(currentSchema, forKey: schemaKey)
        defaults.set(state.status.rawValue, forKey: statusKey)
        // `completedSteps` is the ring's six; the translation tip's "done" rides in the same list under its old raw value.
        var completed = state.completedSteps.map(\.rawValue)
        if state.stepStates[.translate] == .completed { completed.append(TourStep.translate.rawValue) }
        defaults.set(completed.sorted(), forKey: completedStepsKey)
        defaults.set(state.resumeCount, forKey: resumeCountKey)
        defaults.set(state.deferredLaunches, forKey: deferredLaunchesKey)

        if state.hasDeferredTranslate {
            defaults.set([TourStep.translate.rawValue: state.deferredAttempts], forKey: deferredKey)
        } else {
            defaults.removeObject(forKey: deferredKey)
        }
    }

    /// Debug reset (`nanopod://debug/tour/reset`) and tests.
    public static func reset(_ defaults: UserDefaults = .standard) {
        for key in [schemaKey, statusKey, completedStepsKey, resumeCountKey, deferredKey, deferredLaunchesKey] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Preconditions (§5.5)

    /// `forced` (`nanopod://debug/tour/show`) always presents. Otherwise,
    /// same shape as C6's own gate (§5.5 "沿用 C6 思路") plus the resume cap
    /// §5.4 adds: a never-started tour only auto-presents on the app's
    /// actual first-ever launch (`launchCount <= 1`, C6's own rule — it is
    /// NOT a nag shown again every subsequent launch); an in-progress one
    /// (quit mid-tour) auto-resumes on ANY later launch, up to 3 times; a
    /// completed or explicitly-stopped one never re-presents on its own —
    /// the Settings row ("接着认识 nanoPod" / "重新认识 nanoPod") is the only
    /// way back in.
    public static func shouldPresent(status: TourRunStatus, launchCount: Int, resumeCount: Int, forced: Bool) -> Bool {
        if forced { return true }
        switch status {
        case .notStarted: return launchCount <= 1
        case .inProgress: return resumeCount < 3
        case .completed, .skipped: return false
        }
    }

    /// §5.6: a returning user who already completed an OLDER schema only
    /// gets the steps introduced since then, as a mini tour. All v3 steps
    /// share `introducedIn == 2`, so this is here for the NEXT schema bump —
    /// exercised today only by a synthetic future schema in tests.
    public static func newSteps(sinceSchema savedSchema: Int) -> [TourStep] {
        TourStep.orderedSteps.filter { $0.introducedIn > savedSchema }
    }
}
