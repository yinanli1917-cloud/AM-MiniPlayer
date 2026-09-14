import Foundation

// =============================================================================
// [INPUT]: SpotifyScriptingReading (KVC ScriptingBridge over Spotify's public
//          AppleScript dictionary) + PlaybackSource protocol family
// [OUTPUT]: SpotifyPlaybackSource — PlaybackSource conformance polling
//           Spotify.app through SpotifyScriptingReading, never launching it
// [POS]: E1 second adapter. No queue support — Spotify.sdef exposes no
//        playlist/history class (see scratchpad part10), so readQueue is nil.
// =============================================================================

@MainActor
public final class SpotifyPlaybackSource: PlaybackSource {

    public let id: PlaybackSourceID = .spotify

    public let capabilities: PlaybackCapabilities = [
        .play, .seek, .shuffle, .repeatMode, .volume
    ]

    private let reader: SpotifyScriptingReading
    private let pollInterval: TimeInterval
    private let clock: () -> Date

    private var continuation: AsyncStream<PlaybackSourceEvent>.Continuation?
    private var pollTask: Task<Void, Never>?

    private var lastAvailability: PlaybackSourceAvailability?
    private var lastAvailabilityProbeAt: Date?
    private var lastEmittedSnapshot: NowPlayingSnapshot?

    /// Not-running availability is only re-probed/re-yielded every 10s once
    /// it has already been reported, mirroring the "only yield on change"
    /// contract without hammering NSRunningApplication every poll tick.
    private static let availabilityReprobeInterval: TimeInterval = 10

    public private(set) lazy var events: AsyncStream<PlaybackSourceEvent> = {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }()

    public init(
        reader: SpotifyScriptingReading = SpotifyScriptingBridgeReader(),
        pollInterval: TimeInterval = 1.0,
        clock: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.pollInterval = pollInterval
        self.clock = clock
    }

    // MARK: - Lifecycle

    public func start() {
        _ = events
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
        lastAvailability = nil
        lastAvailabilityProbeAt = nil
        lastEmittedSnapshot = nil
    }

    private func pollOnce() {
        guard reader.isRunning else {
            yieldAvailabilityIfNeeded(.appNotRunning)
            return
        }

        // App came back (or this is the first running tick): report available
        // exactly once, then fall through to a normal snapshot read.
        if lastAvailability != .available {
            yieldAvailabilityIfNeeded(.available)
        }

        guard let state = reader.readState() else { return }
        let snapshot = Self.mapSnapshot(state, measuredAt: clock())
        emitSnapshotIfChanged(snapshot)
    }

    /// Only yields an availability event when it differs from the last
    /// reported one, EXCEPT it re-yields `.appNotRunning` at most once per
    /// `availabilityReprobeInterval` so a long-not-running Spotify doesn't
    /// silently stop being reported after the first tick.
    private func yieldAvailabilityIfNeeded(_ availability: PlaybackSourceAvailability) {
        let now = clock()
        if availability == lastAvailability {
            if availability == .appNotRunning,
               let lastProbe = lastAvailabilityProbeAt,
               now.timeIntervalSince(lastProbe) < Self.availabilityReprobeInterval {
                return
            }
        }
        lastAvailability = availability
        lastAvailabilityProbeAt = now
        continuation?.yield(.availability(availability))
    }

    private func emitSnapshotIfChanged(_ snapshot: NowPlayingSnapshot) {
        if let last = lastEmittedSnapshot, Self.snapshotContentEqual(last, snapshot) {
            return
        }
        lastEmittedSnapshot = snapshot
        continuation?.yield(.snapshot(snapshot))
    }

    private static func snapshotContentEqual(_ lhs: NowPlayingSnapshot, _ rhs: NowPlayingSnapshot) -> Bool {
        lhs.identity == rhs.identity
            && lhs.isPlaying == rhs.isPlaying
            && lhs.position == rhs.position
            && lhs.artwork == rhs.artwork
            && lhs.shuffle == rhs.shuffle
            && lhs.repeatMode == rhs.repeatMode
            && lhs.volume == rhs.volume
    }

    // MARK: - Mapping

    private static func mapSnapshot(_ state: SpotifyPlayerState, measuredAt: Date) -> NowPlayingSnapshot {
        let identity: PlaybackTrackIdentity?
        if let track = state.track {
            identity = PlaybackTrackIdentity(
                source: .spotify,
                nativeID: track.spotifyURL,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: Double(track.duration)
            )
        } else {
            identity = nil
        }

        let artwork: ArtworkHint
        if let coverURL = state.track?.coverURL, let url = URL(string: coverURL) {
            artwork = .url(url)
        } else {
            artwork = .lookupByMetadata
        }

        return NowPlayingSnapshot(
            identity: identity,
            isPlaying: state.playerState == 1,
            position: state.playbackPosition,
            measuredAt: measuredAt,
            artwork: artwork,
            shuffle: state.shuffle,
            repeatMode: state.repeatMode ? 2 : 0,
            volume: state.soundVolume
        )
    }

    // MARK: - Reads

    public func readSnapshot() async -> NowPlayingSnapshot? {
        guard reader.isRunning, let state = reader.readState() else { return nil }
        return Self.mapSnapshot(state, measuredAt: clock())
    }

    public func readQueue() async -> QueueSnapshot? {
        // Spotify's public AppleScript dictionary exposes no playlist/queue
        // class (scratchpad part10-spotify-sdef-and-sb-patterns.md § 2).
        nil
    }

    // MARK: - Controls

    public func togglePlayPause() async {
        reader.perform(.playpause)
    }

    public func next() async {
        reader.perform(.nextTrack)
    }

    public func previous() async {
        reader.perform(.previousTrack)
    }

    public func seek(to position: TimeInterval) async {
        reader.perform(.seek(position))
    }

    public func setShuffle(_ on: Bool) async {
        reader.perform(.setShuffle(on))
    }

    public func setRepeatMode(_ mode: Int) async {
        reader.perform(.setRepeat(mode != 0))
    }

    public func setVolume(_ level: Int) async {
        reader.perform(.setVolume(level))
    }

    public func toggleFavorite() async {
        // Not implemented for Spotify: sdef exposes `starred` read-only.
    }

    public func play(itemID: String) async {
        // Not implemented for this step.
    }
}
