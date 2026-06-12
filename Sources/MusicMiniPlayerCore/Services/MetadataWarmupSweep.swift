/**
 * [INPUT]: MetadataDiskCache.schemaVersion (warm-once stamp), MetadataResolver
 *          entry points (CN + localized tiers), MusicController queue/recent
 *          snapshots, LyricsService.isLoading (foreground yield signal) — all
 *          through injected seams
 * [OUTPUT]: MetadataWarmupSweep — once-per-schema-version background sweep
 *           that re-resolves metadata rows lost to a schema flush, plus
 *           MetadataWarmupTrack (sweep input row)
 * [POS]: Services — launch-time cache warming; metadata ONLY, never lyric
 *        source fetches (latency review, post-round-2 item A)
 * [PROTOCOL]: 变更时更新此头部
 */

import Foundation

// ============================================================
// MARK: - Warmup Track
// ============================================================

/// One sweep candidate. Identity matches the resolver cache keying
/// (title + artist + rounded duration) — album plays no part in the
/// metadata tiers being warmed.
public struct MetadataWarmupTrack: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let duration: TimeInterval

    public init(title: String, artist: String, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}

// ============================================================
// MARK: - MetadataWarmupSweep
// ============================================================

/// Background metadata warm-up: once per `MetadataDiskCache.schemaVersion`,
/// re-resolve queue/recent tracks whose rows a schema bump flushed, so the
/// first real play of each song hits a disk row instead of the multi-second
/// cold resolver chain (root cause of the post-round-2 latency regression).
///
/// Discipline: utility priority, strictly sequential, ~1s between tracks,
/// cancellable as a whole, and it PAUSES while a foreground lyrics fetch is
/// active. It resolves METADATA ONLY — both resolver tiers through the
/// normal entry points (so disk persistence and single-flight coalescing
/// fire exactly as a real fetch would) — never full lyric source fetches.
public final class MetadataWarmupSweep {

    // ------------------------------------------------------------------
    // MARK: - Configuration
    // ------------------------------------------------------------------

    public struct Configuration: Sendable {
        /// Hard cap on tracks processed per sweep.
        public var maxTracks: Int = 50
        /// Pause between consecutive track resolutions (and between
        /// foreground-yield re-checks).
        public var interTrackDelay: TimeInterval = 1.0
        /// The queue/recent snapshot populates asynchronously after launch;
        /// the sweep polls until it is non-empty (or gives up, unstamped).
        public var trackListPollInterval: TimeInterval = 5.0
        public var trackListPollAttempts: Int = 24
        /// Version being warmed — stamped only on sweep COMPLETION.
        public var schemaVersion: Int = MetadataDiskCache.schemaVersion

        public init() {}
    }

    // ------------------------------------------------------------------
    // MARK: - Seams (injected; production wiring below)
    // ------------------------------------------------------------------

    private let tracksProvider: @Sendable () async -> [MetadataWarmupTrack]
    private let hasWarmRows: @Sendable (MetadataWarmupTrack) async -> Bool
    private let resolve: @Sendable (MetadataWarmupTrack) async -> Void
    private let isForegroundFetchActive: @Sendable () async -> Bool
    private let lastWarmedVersion: @Sendable () -> Int?
    private let storeWarmedVersion: @Sendable (Int) -> Void
    private let configuration: Configuration

    /// Owner handle (cancel-and-inspect). Main-actor confined like the
    /// LyricsService fetch/preload handles.
    private var sweepTask: Task<Void, Never>?

    init(
        configuration: Configuration = Configuration(),
        tracksProvider: @escaping @Sendable () async -> [MetadataWarmupTrack],
        hasWarmRows: @escaping @Sendable (MetadataWarmupTrack) async -> Bool,
        resolve: @escaping @Sendable (MetadataWarmupTrack) async -> Void,
        isForegroundFetchActive: @escaping @Sendable () async -> Bool,
        lastWarmedVersion: @escaping @Sendable () -> Int?,
        storeWarmedVersion: @escaping @Sendable (Int) -> Void
    ) {
        self.configuration = configuration
        self.tracksProvider = tracksProvider
        self.hasWarmRows = hasWarmRows
        self.resolve = resolve
        self.isForegroundFetchActive = isForegroundFetchActive
        self.lastWarmedVersion = lastWarmedVersion
        self.storeWarmedVersion = storeWarmedVersion
    }

    // ------------------------------------------------------------------
    // MARK: - API
    // ------------------------------------------------------------------

    /// Starts the sweep unless this schema version is already warmed.
    /// Returns the sweep task (tests await it; production discards).
    @MainActor
    @discardableResult
    public func startIfNeeded() -> Task<Void, Never>? {
        let version = configuration.schemaVersion
        guard lastWarmedVersion() != version else {
            DebugLogger.log("MetadataWarmup", "⏭️ schema v\(version) already warmed — sweep skipped")
            return nil
        }
        if let existing = sweepTask, !existing.isCancelled { return existing }
        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(version: version)
        }
        sweepTask = task
        return task
    }

    /// Cancels the whole sweep. The current track's in-flight resolution
    /// (an unstructured single-flight task) still completes and warms its
    /// own rows; no further tracks are processed and no stamp is written.
    @MainActor
    public func cancel() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    // ------------------------------------------------------------------
    // MARK: - Sweep Body
    // ------------------------------------------------------------------

    private func run(version: Int) async {
        guard let candidates = await collectCandidates() else {
            DebugLogger.log("MetadataWarmup", "⏭️ no queue/recent tracks available — sweep deferred to next launch (schema v\(version) NOT stamped)")
            return
        }
        DebugLogger.log("MetadataWarmup", "🔥 warm-up start: schema v\(version), \(candidates.count) candidate tracks")

        var resolvedCount = 0
        var skippedCount = 0
        for track in candidates {
            if Task.isCancelled { return logAbort(version: version) }
            // Yield to foreground: an interactive lyrics fetch owns the
            // network budget — pause and re-check on the same cadence.
            while await isForegroundFetchActive() {
                await pause()
                if Task.isCancelled { return logAbort(version: version) }
            }
            // Idempotent: rows already on disk → no consult, no network.
            if await hasWarmRows(track) {
                skippedCount += 1
                continue
            }
            await resolve(track)
            if Task.isCancelled { return logAbort(version: version) }
            resolvedCount += 1
            DebugLogger.log("MetadataWarmup", "🔥 resolved '\(track.title)' by '\(track.artist)' (\(resolvedCount) resolved)")
            await pause()
        }

        if Task.isCancelled { return logAbort(version: version) }
        storeWarmedVersion(version)
        DebugLogger.log("MetadataWarmup", "✅ warm-up complete: \(resolvedCount) resolved, \(skippedCount) already warm — schema v\(version) stamped")
    }

    /// Polls the queue/recent snapshot (it populates asynchronously after
    /// launch), then dedupes by resolver-cache identity and applies the cap.
    /// Returns nil when no tracks ever appear — the sweep must NOT stamp,
    /// so the next launch retries.
    private func collectCandidates() async -> [MetadataWarmupTrack]? {
        var tracks = await tracksProvider()
        var attempts = 0
        while tracks.isEmpty, attempts < configuration.trackListPollAttempts, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(configuration.trackListPollInterval * 1_000_000_000))
            tracks = await tracksProvider()
            attempts += 1
        }
        guard !tracks.isEmpty, !Task.isCancelled else { return nil }

        var seen = Set<String>()
        var unique: [MetadataWarmupTrack] = []
        for track in tracks {
            let key = "\(MetadataDiskCache.normalize(track.title))|\(MetadataDiskCache.normalize(track.artist))|\(Int(track.duration))"
            if seen.insert(key).inserted {
                unique.append(track)
            }
            if unique.count >= configuration.maxTracks { break }
        }
        return unique
    }

    private func pause() async {
        try? await Task.sleep(nanoseconds: UInt64(configuration.interTrackDelay * 1_000_000_000))
    }

    private func logAbort(version: Int) {
        DebugLogger.log("MetadataWarmup", "🛑 warm-up cancelled — schema v\(version) NOT stamped")
    }
}

// ============================================================
// MARK: - Production Wiring
// ============================================================

extension MetadataWarmupSweep {

    private static let warmedVersionDefaultsKey = "MetadataWarmupSweep.lastWarmedSchemaVersion"

    /// App-wide instance. Built lazily — tests never touch it (they inject
    /// every seam through the internal initializer).
    public static let shared = MetadataWarmupSweep.production()

    /// Wires the seams to the live app:
    /// - tracks: MusicController's @Published queue/recent snapshots — an
    ///   in-process read on the main actor, NO new ScriptingBridge surface.
    /// - rows/resolve: MetadataResolver disk cache + the two tier entry
    ///   points, so disk persistence and single-flight coalescing fire
    ///   exactly as a real fetch would. Metadata only — never lyric fetches.
    /// - yield: LyricsService.isLoading (true across both spinner phases of
    ///   a foreground fetch).
    /// - stamp: UserDefaults, written only on sweep completion.
    private static func production() -> MetadataWarmupSweep {
        MetadataWarmupSweep(
            tracksProvider: {
                await MainActor.run {
                    let controller = MusicController.shared
                    return (controller.upNextTracks + controller.recentTracks)
                        .filter { !$0.title.isEmpty && $0.title != kNotPlayingSentinel && $0.duration > 0 }
                        .map { MetadataWarmupTrack(title: $0.title, artist: $0.artist, duration: $0.duration) }
                }
            },
            hasWarmRows: { track in
                let cache = MetadataResolver.shared.diskCache
                return cache.getChinese(title: track.title, artist: track.artist, duration: track.duration) != nil
                    && cache.get(title: track.title, artist: track.artist, duration: track.duration) != nil
            },
            resolve: { track in
                // Both tiers, serially — the gentlest cadence the resolver
                // supports. Successful resolutions persist their own rows.
                _ = await MetadataResolver.shared.fetchChineseMetadata(
                    title: track.title, artist: track.artist, duration: track.duration
                )
                _ = await MetadataResolver.shared.fetchLocalizedMetadata(
                    title: track.title, artist: track.artist, duration: track.duration
                )
            },
            isForegroundFetchActive: {
                await MainActor.run { LyricsService.shared.isLoading }
            },
            lastWarmedVersion: {
                UserDefaults.standard.object(forKey: warmedVersionDefaultsKey) as? Int
            },
            storeWarmedVersion: { version in
                UserDefaults.standard.set(version, forKey: warmedVersionDefaultsKey)
            }
        )
    }
}
