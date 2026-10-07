/**
 * [INPUT]: Combine, Foundation (Date, DispatchQueue); TourModel's TourEvent.
 * [OUTPUT]: Exports TourDeferredWatcher.
 * [POS]: MusicMiniPlayerCore/Onboarding. The ONE thing allowed to outlive a
 *        finished tour (proposal §3.3 S4L / §5.2 `idle(deferredArmed: true)`)
 *        — watches the standalone translation tip's ground: the panel is on
 *        screen, on the LYRICS page, and `canTranslate` is true (the button is
 *        really there). Turns it, with the track-title publisher, into the
 *        `TourEvent`s `TourMachine` already knows how to interpret
 *        (`.canTranslateBecameTrue`, `.deferredTipUnavailable`, `.songChanged`,
 *        `.launch`), so the reducer stays the single source of truth for the
 *        3 s gate, the 3-song/20-launch caps and the "already on" silent
 *        completion. Ground reached before the 3 s mark is re-sent once the
 *        mark passes (a user sitting on the lyrics page would otherwise never
 *        see the tip for that song).
 */

import Combine
import Foundation

@MainActor
public final class TourDeferredWatcher {
    private var cancellables = Set<AnyCancellable>()
    private var recheck: AnyCancellable?
    private var songStartedAt: Date?
    private var canTranslateNow = false
    private var onLyricsPageNow = false
    private var wasEligible = false
    private var panelVisible: () -> Bool = { true }
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable

    /// The gate the reducer applies (seconds into the song); the watcher re-sends when it passes.
    public static let tipGateSeconds: TimeInterval = 3

    /// Fires `.canTranslateBecameTrue`/`.deferredTipUnavailable`/`.songChanged`. Set by `TourController`
    /// to feed straight back into `TourMachine.reduce`.
    public var onEvent: ((TourEvent) -> Void)?

    /// `schedule` runs a closure after a delay and returns what cancels it (tests inject a manual one).
    public init(
        now: @escaping () -> Date = Date.init,
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable = TourDeferredWatcher.mainQueueSchedule
    ) {
        self.now = now
        self.schedule = schedule
    }

    public static func mainQueueSchedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return AnyCancellable { item.cancel() }
    }

    public var isArmed: Bool { !cancellables.isEmpty }

    /// Starts the subscriptions. `panelVisible` is sampled (not subscribed to) whenever the ground is re-evaluated — the
    /// tip only ever shows while the panel is on screen (§3.3 S4L). `onLyricsPage` replays its current value on subscribe
    /// (a `@Published`-backed publisher does); by default the page is not part of the ground. `trackTitle`
    /// must be a CHANGE stream (e.g. `MusicController.shared.$currentTrackTitle.dropFirst()`)
    /// — this watcher treats every emission as a real song change, since it
    /// has no way to tell a `@Published` publisher's initial replay apart
    /// from a genuine change on its own.
    public func arm(
        canTranslate: AnyPublisher<Bool, Never>,
        onLyricsPage: AnyPublisher<Bool, Never> = Just(true).eraseToAnyPublisher(),
        trackTitle: AnyPublisher<String, Never>,
        panelVisible: @escaping () -> Bool
    ) {
        cancel()
        self.panelVisible = panelVisible
        songStartedAt = now()

        trackTitle.sink { [weak self] _ in
            guard let self else { return }
            self.songStartedAt = self.now()
            self.onEvent?(.songChanged)
            self.reevaluate(forceSend: true)
        }.store(in: &cancellables)

        // (A `@Published` publisher fires BEFORE its value lands: the closures keep the values they were handed.)
        canTranslate.sink { [weak self] value in
            guard let self else { return }
            self.canTranslateNow = value
            self.reevaluate()
        }.store(in: &cancellables)

        onLyricsPage.sink { [weak self] value in
            guard let self else { return }
            self.onLyricsPageNow = value
            self.reevaluate()
        }.store(in: &cancellables)
    }

    /// The ground is: panel on screen + lyrics page + `canTranslate`. Reaching it sends the eligible event; losing it sends
    /// the unavailable one; while it holds and the 3 s mark is ahead, one re-send is scheduled for when it passes.
    private func reevaluate(forceSend: Bool = false) {
        let eligible = canTranslateNow && onLyricsPageNow && panelVisible()
        let before = wasEligible
        wasEligible = eligible
        recheck = nil
        guard eligible else {
            if before { onEvent?(.deferredTipUnavailable) }
            return
        }
        guard let started = songStartedAt else { return }
        if !before || forceSend { send(secondsSince: started) }
        let seconds = now().timeIntervalSince(started)
        if seconds < Self.tipGateSeconds {
            recheck = schedule(Self.tipGateSeconds - seconds + 0.05) { [weak self] in
                guard let self else { return }
                self.recheck = nil
                self.reevaluate(forceSend: true)
            }
        }
    }

    private func send(secondsSince started: Date) {
        onEvent?(.canTranslateBecameTrue(secondsIntoSong: now().timeIntervalSince(started)))
    }

    /// Called once per app launch while armed (§5.2's 20-launch cap).
    public func recordLaunch() {
        guard isArmed else { return }
        onEvent?(.launch)
    }

    /// `.cancelDeferredWatcher` effect, or teardown with nothing deferred.
    public func cancel() {
        cancellables.removeAll()
        recheck = nil
        songStartedAt = nil
        canTranslateNow = false
        onLyricsPageNow = false
        wasEligible = false
    }
}
