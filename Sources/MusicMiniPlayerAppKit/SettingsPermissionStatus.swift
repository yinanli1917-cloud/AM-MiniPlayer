/**
 * [INPUT]: Depends on MusicMiniPlayerCore's OnboardingAuthorizationStatus (and, through the
 *          injected providers, OnboardingState's TCC / MusicKit queries).
 * [OUTPUT]: Exports SettingsPermissionStatusStore (last-known permission statuses, refreshed off the
 *           main thread).
 * [POS]: The General page's permission rows read statuses from here instead of asking the system
 *        inside `body`. Both queries are synchronous system calls on the calling thread
 *        (`AEDeterminePermissionToAutomateTarget` ~10 ms, `MusicAuthorization.currentStatus` ~11 ms
 *        measured on the main thread) and `body` ran them on EVERY evaluation (a tab switch evaluates
 *        it several times), which made the switch to General a ~210 ms main-thread block. Now the page
 *        shows the last known value (process-wide, so a re-opened window has it immediately) and a
 *        background refresh updates it on appear, on app re-activation (the user may have changed it in
 *        System Settings) and after a grant.
 */

import SwiftUI
import MusicMiniPlayerCore

@MainActor
final class SettingsPermissionStatusStore: ObservableObject {

    /// nil = not asked yet (the row reserves its space and shows nothing, instead of flashing a wrong status).
    @Published private(set) var automation: OnboardingAuthorizationStatus?
    @Published private(set) var appleMusic: OnboardingAuthorizationStatus?

    /// The newest answer seen by any store in this process.
    private static var lastKnown: (automation: OnboardingAuthorizationStatus?, appleMusic: OnboardingAuthorizationStatus?) = (nil, nil)

    private var generation = 0

    init() {
        automation = Self.lastKnown.automation
        appleMusic = Self.lastKnown.appleMusic
    }

    /// Ask both providers on a background queue, publish the answers on the main thread.
    /// A newer refresh supersedes an older one still in flight.
    func refresh(
        automation automationProvider: @escaping @Sendable () -> OnboardingAuthorizationStatus,
        appleMusic appleMusicProvider: @escaping @Sendable () -> OnboardingAuthorizationStatus
    ) {
        generation += 1
        let mine = generation
        Self.query(automation: automationProvider, appleMusic: appleMusicProvider) { [weak self] a, m in
            guard let self, self.generation == mine else { return }
            self.automation = a
            self.appleMusic = m
        }
    }

    /// Fill the process-wide cache before any page exists (window creation), so the first visit to
    /// General already has real values.
    static func warm(
        automation: @escaping @Sendable () -> OnboardingAuthorizationStatus = { OnboardingState.queryAutomationStatus() },
        appleMusic: @escaping @Sendable () -> OnboardingAuthorizationStatus = { OnboardingState.queryMusicKitStatus() }
    ) {
        query(automation: automation, appleMusic: appleMusic) { _, _ in }
    }

    private static func query(
        automation: @escaping @Sendable () -> OnboardingAuthorizationStatus,
        appleMusic: @escaping @Sendable () -> OnboardingAuthorizationStatus,
        deliver: @escaping @MainActor (OnboardingAuthorizationStatus, OnboardingAuthorizationStatus) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let a = automation()
            let m = appleMusic()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    lastKnown = (a, m)
                    deliver(a, m)
                }
            }
        }
    }

    #if DEBUG
    /// Test seam: forget the process-wide cache.
    static func resetLastKnown() { lastKnown = (nil, nil) }
    #endif
}
