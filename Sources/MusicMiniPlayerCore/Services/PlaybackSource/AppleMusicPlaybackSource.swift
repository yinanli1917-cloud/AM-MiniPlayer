import Combine
import Foundation

// =============================================================================
// [INPUT]: MusicController's @Published state + AppleMusicControlSink
// [OUTPUT]: AppleMusicPlaybackSource — PlaybackSource conformance wrapping the
//           existing ScriptingBridge-backed MusicController
// [POS]: E1 first Apple Music adapter. Does not touch ScriptingBridge, SBApplication,
//        or any queue directly — reads/writes only go through @Published state
//        and the AppleMusicControlSink forwarding surface.
// =============================================================================

@MainActor
public final class AppleMusicPlaybackSource: PlaybackSource {

    public let id: PlaybackSourceID = .appleMusic

    public let capabilities: PlaybackCapabilities = [
        .play, .seek, .shuffle, .repeatMode, .volume, .favorite,
        .queueRead, .playByID, .addToLibrary, .share
    ]

    private let controller: MusicController
    private let sink: AppleMusicControlSink

    private var continuation: AsyncStream<PlaybackSourceEvent>.Continuation?
    private var cancellables: Set<AnyCancellable> = []
    private var lastAvailability: PlaybackSourceAvailability = .available
    private var lastEmittedSnapshot: NowPlayingSnapshot?

    public private(set) lazy var events: AsyncStream<PlaybackSourceEvent> = {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }()

    public init(controller: MusicController, sink: AppleMusicControlSink? = nil) {
        self.controller = controller
        self.sink = sink ?? controller
    }

    // MARK: - Lifecycle

    public func start() {
        // Force the lazy stream (and its continuation) into existence before subscribing.
        _ = events

        // Every publisher that can change what readSnapshotSync() returns feeds
        // ONE merged void-signal pipeline into ONE dedupe gate (lastEmittedSnapshot).
        // Two separate Combine chains would each run their own removeDuplicates
        // and could both fire an "initial" event at subscribe time — a
        // cross-chain duplicate that per-chain removeDuplicates can't see.
        Publishers.Merge4(
            controller.$currentTrackTitle.map { _ in () },
            controller.$currentArtist.map { _ in () },
            controller.$currentAlbum.map { _ in () },
            controller.$currentPersistentID.map { _ in () }
        )
        .merge(with:
            Publishers.Merge4(
                controller.$isPlaying.map { _ in () },
                controller.$shuffleEnabled.map { _ in () },
                controller.$repeatMode.map { _ in () },
                controller.$duration.map { _ in () }
            )
        )
        .sink { [weak self] in
            // @Published fires its publisher from `willSet`, BEFORE the new
            // value is actually stored — reading `controller.*` synchronously
            // here would still see the OLD value. Defer one run-loop tick so
            // readSnapshotSync() runs after the property write lands.
            DispatchQueue.main.async {
                self?.emitSnapshotIfChanged()
            }
        }
        .store(in: &cancellables)

        controller.$upNextTracks
            .map { _ in () }
            .sink { [weak self] in
                self?.continuation?.yield(.queueChanged)
            }
            .store(in: &cancellables)

        controller.$recentTracks
            .map { _ in () }
            .sink { [weak self] in
                self?.continuation?.yield(.queueChanged)
            }
            .store(in: &cancellables)

        controller.$connectionError
            .sink { [weak self] error in
                guard let self else { return }
                let availability: PlaybackSourceAvailability = error != nil ? .unreachable(error!) : .available
                if availability != self.lastAvailability {
                    self.lastAvailability = availability
                    self.continuation?.yield(.availability(availability))
                }
            }
            .store(in: &cancellables)
    }

    public func stop() {
        cancellables.removeAll()
        continuation?.finish()
        continuation = nil
        lastEmittedSnapshot = nil
    }

    /// Computes the current snapshot and yields `.snapshot` only when it
    /// differs (ignoring `measuredAt`) from the last one this source emitted.
    /// A single gate across every upstream publisher, so two publishers
    /// firing on the same underlying change (or both firing their initial
    /// value at subscribe time) never produce two events.
    private func emitSnapshotIfChanged() {
        let snapshot = readSnapshotSync()
        if let last = lastEmittedSnapshot, Self.snapshotContentEqual(last, snapshot) {
            return
        }
        lastEmittedSnapshot = snapshot
        continuation?.yield(.snapshot(snapshot))
    }

    /// Content equality ignoring `measuredAt` (always fresh `Date()`) so that
    /// consecutive snapshots with identical playback state collapse into one
    /// emitted event instead of flooding on every re-read.
    private static func snapshotContentEqual(_ lhs: NowPlayingSnapshot, _ rhs: NowPlayingSnapshot) -> Bool {
        lhs.identity == rhs.identity
            && lhs.isPlaying == rhs.isPlaying
            && lhs.position == rhs.position
            && lhs.artwork == rhs.artwork
            && lhs.shuffle == rhs.shuffle
            && lhs.repeatMode == rhs.repeatMode
            && lhs.volume == rhs.volume
    }

    // MARK: - Reads

    public func readSnapshot() async -> NowPlayingSnapshot? {
        readSnapshotSync()
    }

    private func readSnapshotSync() -> NowPlayingSnapshot {
        let identity: PlaybackTrackIdentity?
        if controller.currentTrackTitle == kNotPlayingSentinel {
            identity = nil
        } else {
            identity = PlaybackTrackIdentity(
                source: .appleMusic,
                nativeID: controller.currentPersistentID,
                title: controller.currentTrackTitle,
                artist: controller.currentArtist,
                album: controller.currentAlbum,
                duration: controller.duration
            )
        }

        let artwork: ArtworkHint = controller.currentArtwork != nil ? .image(controller.currentArtwork!) : .lookupByMetadata

        return NowPlayingSnapshot(
            identity: identity,
            isPlaying: controller.isPlaying,
            position: controller.currentTime,
            measuredAt: Date(),
            artwork: artwork,
            shuffle: controller.shuffleEnabled,
            repeatMode: controller.repeatMode,
            volume: nil
        )
    }

    public func readQueue() async -> QueueSnapshot? {
        func mapItem(_ track: (title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)) -> QueueSnapshot.Item {
            let identity = PlaybackTrackIdentity(
                source: .appleMusic,
                nativeID: track.persistentID.isEmpty ? nil : track.persistentID,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration
            )
            return QueueSnapshot.Item(identity: identity, artwork: .lookupByMetadata)
        }

        return QueueSnapshot(
            upNext: controller.upNextTracks.map(mapItem),
            recent: controller.recentTracks.map(mapItem)
        )
    }

    // MARK: - Controls (forward to sink)

    public func togglePlayPause() async {
        sink.togglePlayPause()
    }

    public func next() async {
        sink.nextTrack()
    }

    public func previous() async {
        sink.previousTrack()
    }

    public func seek(to position: TimeInterval) async {
        sink.seek(to: position)
    }

    public func setShuffle(_ on: Bool) async {
        guard controller.shuffleEnabled != on else { return }
        sink.toggleShuffle()
    }

    public func setRepeatMode(_ mode: Int) async {
        var attempts = 0
        while controller.repeatMode != mode && attempts < 3 {
            sink.cycleRepeatMode()
            attempts += 1
        }
    }

    public func setVolume(_ level: Int) async {
        sink.setVolume(level)
    }

    public func toggleFavorite() async {
        sink.toggleStar()
    }

    public func play(itemID: String) async {
        sink.playTrack(persistentID: itemID, completion: nil)
    }
}
