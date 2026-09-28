/**
 * [INPUT]: Combine, Foundation (Date); TourModel's TourEvent.
 * [OUTPUT]: Exports TourDeferredWatcher.
 * [POS]: MusicMiniPlayerCore/Onboarding. The ONE thing allowed to outlive a
 *        finished tour (proposal §3.3 S4L / §5.2 `idle(deferredArmed: true)`)
 *        — turns raw `canTranslate`/track-title publishers into the three
 *        `TourEvent`s `TourMachine` already knows how to interpret
 *        (`.canTranslateBecameTrue`, `.songChanged`, `.launch`), so the
 *        reducer stays the single source of truth for the 3-song/20-launch
 *        caps and the "already on" silent-completion case.
 */

import Combine
import Foundation

@MainActor
public final class TourDeferredWatcher {
    private var cancellables = Set<AnyCancellable>()
    private var songStartedAt: Date?
    private let now: () -> Date

    /// Fires `.canTranslateBecameTrue`/`.songChanged`. Set by `TourController`
    /// to feed straight back into `TourMachine.reduce`.
    public var onEvent: ((TourEvent) -> Void)?

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public var isArmed: Bool { !cancellables.isEmpty }

    /// Starts the single subscription. `panelVisible` is sampled (not
    /// subscribed to) at the moment `canTranslate` flips true — the S4L card
    /// only ever shows while the panel is on screen (§3.3 S4L). `trackTitle`
    /// must be a CHANGE stream (e.g. `MusicController.shared.$currentTrackTitle.dropFirst()`)
    /// — this watcher treats every emission as a real song change, since it
    /// has no way to tell a `@Published` publisher's initial replay apart
    /// from a genuine change on its own.
    public func arm(
        canTranslate: AnyPublisher<Bool, Never>,
        trackTitle: AnyPublisher<String, Never>,
        panelVisible: @escaping () -> Bool
    ) {
        cancel()
        songStartedAt = now()

        trackTitle.sink { [weak self] _ in
            guard let self else { return }
            self.songStartedAt = self.now()
            self.onEvent?(.songChanged)
        }.store(in: &cancellables)

        canTranslate.filter { $0 }.sink { [weak self] _ in
            guard let self, panelVisible(), let started = self.songStartedAt else { return }
            self.onEvent?(.canTranslateBecameTrue(secondsIntoSong: self.now().timeIntervalSince(started)))
        }.store(in: &cancellables)
    }

    /// Called once per app launch while armed (§5.2's 20-launch cap).
    public func recordLaunch() {
        guard isArmed else { return }
        onEvent?(.launch)
    }

    /// `.cancelDeferredWatcher` effect, or teardown with nothing deferred.
    public func cancel() {
        cancellables.removeAll()
        songStartedAt = nil
    }
}
