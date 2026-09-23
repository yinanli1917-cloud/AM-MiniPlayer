/**
 * [INPUT]: DEBUG test seams — LyricsFetcher.shared.lyricsDiskCache,
 *          MetadataResolver.shared.diskCache, HTTPClient.requestGateForTesting,
 *          LyricsService.drainFetchTasksForTesting — plus the backfill census's
 *          UserDefaults kill switch.
 * [OUTPUT]: LyricsPipelineTestIsolation — a per-test sandbox for any test that
 *           calls the real `LyricsService.fetchLyrics`.
 * [POS]: Test support. A disk-cache miss inside such a test falls through to the
 *        real fetch pipeline. Without this sandbox that pipeline reads/writes the
 *        user's ~/Library/Application Support/nanoPod files and calls the real
 *        providers (2026-09-22: a fuzz draft shrank the real metadata_cache.json
 *        from ~149 to 24 rows and tripped the iTunes rate limit). With it, both
 *        caches live in a temp directory, every HTTP request is refused as
 *        offline, and the census writes nothing.
 */

import Foundation
@testable import MusicMiniPlayerCore

final class LyricsPipelineTestIsolation {

    /// Temp lyrics cache installed as `LyricsFetcher.shared.lyricsDiskCache`; seed it directly.
    let lyricsCache: LyricsDiskCache
    /// Temp metadata cache installed as `MetadataResolver.shared.diskCache`.
    let metadataCache: MetadataDiskCache

    /// URLs the pipeline tried to reach while isolated. Every one was refused.
    var deniedRequestURLs: [URL] { denied.urls }

    private let directory: URL
    private let savedLyricsCache: LyricsDiskCache
    private let savedMetadataCache: MetadataDiskCache
    private let savedGate: (@Sendable (URLRequest) -> Error?)?
    private let savedCensusKillSwitch: Any?
    private let denied = DeniedRequestLog()

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lyricsCache = LyricsDiskCache(fileURL: directory.appendingPathComponent("lyrics_cache.json"))
        metadataCache = MetadataDiskCache(fileURL: directory.appendingPathComponent("metadata_cache.json"))

        savedLyricsCache = LyricsFetcher.shared.lyricsDiskCache
        savedMetadataCache = MetadataResolver.shared.diskCache
        savedGate = HTTPClient.requestGateForTesting
        savedCensusKillSwitch = UserDefaults.standard.object(forKey: LyricsBackfillCensus.killSwitchKey)

        LyricsFetcher.shared.lyricsDiskCache = lyricsCache
        MetadataResolver.shared.diskCache = metadataCache
        let denied = self.denied
        HTTPClient.requestGateForTesting = { request in
            denied.append(request.url)
            return URLError(.notConnectedToInternet)
        }
        // The test process's own defaults domain, not the app's.
        UserDefaults.standard.set(true, forKey: LyricsBackfillCensus.killSwitchKey)
    }

    /// Drains the fetch work the test started BEFORE restoring: a task that
    /// outlived the test would otherwise reach the real caches and network.
    func tearDown() async {
        await LyricsService.shared.drainFetchTasksForTesting()
        LyricsFetcher.shared.lyricsDiskCache = savedLyricsCache
        MetadataResolver.shared.diskCache = savedMetadataCache
        HTTPClient.requestGateForTesting = savedGate
        UserDefaults.standard.set(savedCensusKillSwitch, forKey: LyricsBackfillCensus.killSwitchKey)
        metadataCache.flush()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class DeniedRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] { lock.withLock { storage } }

    func append(_ url: URL?) {
        guard let url else { return }
        lock.withLock { storage.append(url) }
    }
}
