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
 *        completion. The ground must HOLD for a short settle window (and the
 *        song be past the 3 s mark) before the event is sent: entering the
 *        lyrics page can carry a stale `canTranslate == true` that is
 *        re-derived to false a moment later, and a tip that opened on it
 *        would flash and burn its once-per-launch slot. A user sitting on the
 *        lyrics page still gets it: the event is sent when both have passed.
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
    /// When the ground (panel + lyrics page + canTranslate) last became true; nil while it does not hold.
    private var groundSince: Date?
    /// The eligible event went out and the ground has held since (so losing it is worth reporting).
    private var sent = false
    private var panelVisible: () -> Bool = { true }
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable

    /// The gate the reducer applies (seconds into the song); the watcher holds the event until it has passed.
    public static let tipGateSeconds: TimeInterval = 3
    /// How long the ground must hold before the event is sent (a stale `canTranslate` is re-derived well inside this).
    public static let settleSeconds: TimeInterval = 0.6

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
            self.sent = false
            self.reevaluate()
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

    /// The ground is: panel on screen + lyrics page + `canTranslate`. Once it has held for the settle window and the song is
    /// past the 3 s mark, the eligible event is sent (once); until then one check is scheduled for when both will have
    /// passed. Losing the ground cancels that check, and reports the tip unavailable if the event had gone out.
    private func reevaluate() {
        recheck = nil
        guard canTranslateNow, onLyricsPageNow, panelVisible() else {
            groundSince = nil
            if sent {
                sent = false
                onEvent?(.deferredTipUnavailable)
            }
            return
        }
        guard !sent, let started = songStartedAt else { return }
        let t = now()
        if groundSince == nil { groundSince = t }
        let toWait = max(Self.settleSeconds - t.timeIntervalSince(groundSince ?? t), Self.tipGateSeconds - t.timeIntervalSince(started))
        if toWait <= 0 {
            sent = true
            onEvent?(.canTranslateBecameTrue(secondsIntoSong: t.timeIntervalSince(started)))
            return
        }
        recheck = schedule(toWait + 0.05) { [weak self] in self?.reevaluate() }
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
        groundSince = nil
        sent = false
    }
}
