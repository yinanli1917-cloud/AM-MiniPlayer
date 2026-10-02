/**
 * [INPUT]: AppKit (NSRunningApplication, NSScreen), CoreGraphics' CGWindowListCopyWindowInfo;
 *          MusicMiniPlayerCore's TourMusicWindowLocator / TourMusicWindowTracker / PlayerAppIdentity.
 * [OUTPUT]: Exports TourMusicWindowWatcher (a main-queue sampling loop around the pure tracker) and
 *           TourMusicWindowSource.liveFrame (the one place the live window list is read).
 * [POS]: MusicMiniPlayerAppKit/Tour. Runs ONLY from the Music-beat tap until the user is back (or the
 *        tour ends): a quick look ~6x/s for at most 2 s while the player app opens, then one look every
 *        0.5 s while the card stands by its window. `stop()` leaves nothing armed. Public API only:
 *        window bounds and owner PID need no Screen Recording permission.
 */

import AppKit
import CoreGraphics
import MusicMiniPlayerCore

enum TourMusicWindowSource {
    /// The player app's main window as an AppKit screen rect, or nil (not running, minimised, on another Space).
    /// Never launches or activates anything: it only asks which window is on screen.
    static func liveFrame(for player: PlayerAppIdentity) -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).first?.processIdentifier,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let cg = TourMusicWindowLocator.mainWindowBounds(in: infos, ownerPID: pid),
              let primary = NSScreen.screens.first else { return nil }
        return TourMusicWindowLocator.appKitRect(fromCG: cg, primaryScreenHeight: primary.frame.height)
    }
}

@MainActor
final class TourMusicWindowWatcher {
    private var tracker: TourMusicWindowTracker
    private let timing: TourMusicWindowTracker.Timing
    private let sample: () -> CGRect?
    private let onEvent: (TourMusicWindowTracker.Event) -> Void
    private var work: DispatchWorkItem?
    private var startedAt = Date()

    init(timing: TourMusicWindowTracker.Timing, sample: @escaping () -> CGRect?, onEvent: @escaping (TourMusicWindowTracker.Event) -> Void) {
        self.timing = timing
        self.tracker = TourMusicWindowTracker(timing: timing)
        self.sample = sample
        self.onEvent = onEvent
    }

    /// True while a sample is scheduled.
    var isRunning: Bool { work != nil }
    /// Bumped by start/stop: a handler that stops (or restarts) the watcher leaves nothing to schedule.
    private var generation = 0

    /// Begins a fresh search. The first look comes one search interval from now (the window cannot exist at the instant of the tap).
    func start() {
        stop()
        tracker = TourMusicWindowTracker(timing: timing)
        startedAt = Date()
        schedule(after: timing.searchInterval)
    }

    func stop() {
        generation += 1
        work?.cancel()
        work = nil
    }

    private func schedule(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.step() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func step() {
        work = nil
        let ticket = generation
        let event = tracker.observe(sample(), elapsed: Date().timeIntervalSince(startedAt))
        if let event { onEvent(event) }
        guard ticket == generation, !tracker.isFinished, let next = tracker.nextInterval else { return }
        schedule(after: next)
    }
}
