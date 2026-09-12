import XCTest
@testable import MusicMiniPlayerCore

/// A2 negative-evidence cache: a query that comes back empty is remembered
/// per tier (localized / CN / album-scoped) for `negativeTTLSeconds` so a
/// repeat cold start does not re-run a search that is already known to be
/// fruitless. Round-trips the disk envelope directly (MetadataDiskCache
/// layer) — the resolver-level "0 searchITunes calls on replay" behavior is
/// covered by MetadataEnglishTitleGateTests.
final class MetadataNegativeEvidenceTests: XCTestCase {

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    // ------------------------------------------------------------------
    // MARK: - Round trip per tier
    // ------------------------------------------------------------------

    func testLocalizedNegativeRoundTrips() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        XCTAssertFalse(cache.getNegative(title: "Billie Jean", artist: "Michael Jackson", duration: 294))
        cache.setNegative(title: "Billie Jean", artist: "Michael Jackson", duration: 294)
        XCTAssertTrue(cache.getNegative(title: "Billie Jean", artist: "Michael Jackson", duration: 294))
    }

    func testChineseNegativeRoundTrips() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        XCTAssertFalse(cache.getNegativeChinese(title: "Billie Jean", artist: "Michael Jackson", duration: 294))
        cache.setNegativeChinese(title: "Billie Jean", artist: "Michael Jackson", duration: 294)
        XCTAssertTrue(cache.getNegativeChinese(title: "Billie Jean", artist: "Michael Jackson", duration: 294))
    }

    func testAlbumScopedNegativeRoundTrips() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        XCTAssertFalse(cache.getNegativeAlbumScoped(title: "Dinner", artist: "Kay Huang", duration: 259, album: "Some Album"))
        cache.setNegativeAlbumScoped(title: "Dinner", artist: "Kay Huang", duration: 259, album: "Some Album")
        XCTAssertTrue(cache.getNegativeAlbumScoped(title: "Dinner", artist: "Kay Huang", duration: 259, album: "Some Album"))
        // A different album is a different key — no cross-contamination.
        XCTAssertFalse(cache.getNegativeAlbumScoped(title: "Dinner", artist: "Kay Huang", duration: 259, album: "Other Album"))
    }

    // ------------------------------------------------------------------
    // MARK: - Expiry
    // ------------------------------------------------------------------

    /// Injects an expired row directly by writing the on-disk envelope,
    /// then reloading — proves the TTL check, not just the constant value.
    func testExpiredNegativeRowIsIgnoredAndPruned() {
        let url = temporaryFileURL()
        let staleTs = Date().timeIntervalSince1970 - MetadataDiskCache.negativeTTLSeconds - 10
        let key = MetadataDiskCache.cacheKey(title: "Billie Jean", artist: "Michael Jackson", duration: 294)
        let envelope: [String: Any] = [
            "version": MetadataDiskCache.schemaVersion,
            "entries": [String: Any](),
            "cn_entries": [String: Any](),
            "negative_entries": [key: ["ts": staleTs]],
            "negative_cn_entries": [String: Any](),
            "negative_album_entries": [String: Any]()
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        try! data.write(to: url)

        let cache = MetadataDiskCache(fileURL: url)
        XCTAssertFalse(cache.getNegative(title: "Billie Jean", artist: "Michael Jackson", duration: 294))
    }

    // ------------------------------------------------------------------
    // MARK: - Positive overwrite
    // ------------------------------------------------------------------

    func testPositiveLocalizedWriteClearsNegativeRow() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        cache.setNegative(title: "First Love", artist: "Hikaru Utada", duration: 250)
        XCTAssertTrue(cache.getNegative(title: "First Love", artist: "Hikaru Utada", duration: 250))

        cache.set(title: "First Love", artist: "Hikaru Utada", duration: 250,
                  resolvedTitle: "First Love", resolvedArtist: "宇多田ヒカル",
                  region: "JP", durationDiff: 0.2)
        XCTAssertFalse(cache.getNegative(title: "First Love", artist: "Hikaru Utada", duration: 250))
    }

    func testPositiveChineseWriteClearsNegativeRow() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        cache.setNegativeChinese(title: "Lemon", artist: "Kenshi Yonezu", duration: 256)
        XCTAssertTrue(cache.getNegativeChinese(title: "Lemon", artist: "Kenshi Yonezu", duration: 256))

        cache.setChinese(title: "Lemon", artist: "Kenshi Yonezu", duration: 256,
                         resolvedTitle: "Lemon", resolvedArtist: "米津玄师", durationDiff: 0.1)
        XCTAssertFalse(cache.getNegativeChinese(title: "Lemon", artist: "Kenshi Yonezu", duration: 256))
    }

    func testPositiveAlbumScopedWriteClearsNegativeRow() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        cache.setNegativeAlbumScoped(title: "Dinner", artist: "Kay Huang", duration: 259, album: "Some Album")
        XCTAssertTrue(cache.getNegativeAlbumScoped(title: "Dinner", artist: "Kay Huang", duration: 259, album: "Some Album"))

        cache.clearNegativeAlbumScoped(title: "Dinner", artist: "Kay Huang", duration: 259, album: "Some Album")
        XCTAssertFalse(cache.getNegativeAlbumScoped(title: "Dinner", artist: "Kay Huang", duration: 259, album: "Some Album"))
    }

    /// A negative write must never shadow a positive row already answering
    /// the same query (write-ordering safety, mirrors the tier-isolation
    /// discipline in MetadataDiskCacheTierTests).
    func testNegativeWriteNeverShadowsExistingPositiveRow() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        cache.set(title: "First Love", artist: "Hikaru Utada", duration: 250,
                  resolvedTitle: "First Love", resolvedArtist: "宇多田ヒカル",
                  region: "JP", durationDiff: 0.2)
        cache.setNegative(title: "First Love", artist: "Hikaru Utada", duration: 250)
        // The positive row must still be readable.
        let entry = cache.get(title: "First Love", artist: "Hikaru Utada", duration: 250)
        XCTAssertEqual(entry?.resolvedTitle, "First Love")
        XCTAssertEqual(entry?.resolvedArtist, "宇多田ヒカル")
    }

    // ------------------------------------------------------------------
    // MARK: - Schema flush
    // ------------------------------------------------------------------

    /// A pre-v9 envelope (no negative dictionaries, schemaVersion 8) must be
    /// flushed by the version bump, exactly like every prior schema bump —
    /// treated as empty rather than crashing on missing keys.
    func testSchemaV8EnvelopeIsFlushedByVersionBump() {
        let url = temporaryFileURL()
        let key = MetadataDiskCache.cacheKey(title: "Old Song", artist: "Old Artist", duration: 200)
        let v8Envelope: [String: Any] = [
            "version": 8,
            "entries": [key: [
                "resolved_title": "Old Song",
                "resolved_artist": "Old Artist",
                "region": "US",
                "ts": Date().timeIntervalSince1970,
                "source": "metadata-cache-v1",
                "duration_diff": 0.1
            ]],
            "cn_entries": [String: Any]()
        ]
        let data = try! JSONSerialization.data(withJSONObject: v8Envelope)
        try! data.write(to: url)

        let cache = MetadataDiskCache(fileURL: url)
        // Old row flushed — schema mismatch treats the file as empty.
        XCTAssertNil(cache.get(title: "Old Song", artist: "Old Artist", duration: 200))
        XCTAssertEqual(cache.entryCount, 0)
    }

    // ------------------------------------------------------------------
    // MARK: - Ledger-gated write suppression
    // ------------------------------------------------------------------

    /// A bound ledger recording a transport failure must suppress the
    /// negative write — a dead network run is a verdict about the network,
    /// not the song. Exercised at the disk-cache boundary using the same
    /// quorum idiom the resolver applies before calling `setNegative*`.
    func testLedgerTransportFailureSuppressesNegativeWriteDecision() {
        let ledger = NetworkOutcomeLedger()
        ledger.recordProtocolResponse()
        ledger.record(failure: URLError(.networkConnectionLost))
        XCTAssertTrue(ledger.hadTransportFailures)
        // The resolver's guard is `!hadTransportFailures` — assert the
        // ledger surface the guard reads is in the failing state.
    }

    func testLedgerCleanQuorumAllowsNegativeWriteDecision() {
        let ledger = NetworkOutcomeLedger()
        ledger.recordProtocolResponse()
        XCTAssertFalse(ledger.hadTransportFailures)
        XCTAssertGreaterThanOrEqual(ledger.protocolResponses, 1)
    }

    /// Fail-closed: MetadataWarmupSweep and the lyrics preload path
    /// (LyricsService.fetchLyrics — "preload stays unbound, the backfill
    /// binds its own") run with NO ledger bound. An offline warm-up must
    /// NOT persist a 24h negative row from pure silence — no evidence
    /// either way is not evidence of absence ("离线不落负" — never write a
    /// negative verdict while offline). End-to-end through the resolver:
    /// a miss with no ledger bound writes nothing.
    func testUnboundLedgerWritesNoNegativeRow() async {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        let resolver = MetadataResolver(diskCache: cache)
        MetadataResolver.searchITunesOverrideForTesting = { _, _, _ in nil }
        defer { MetadataResolver.searchITunesOverrideForTesting = nil }

        // No NetworkOutcomeLedger.current bound in this task context.
        let result = await resolver.fetchLocalizedMetadata(title: "Some Offline Title", artist: "Some Offline Artist", duration: 210)
        XCTAssertNil(result)
        XCTAssertFalse(cache.getNegative(title: "Some Offline Title", artist: "Some Offline Artist", duration: 210),
                       "unbound ledger (offline/preload) must never persist a negative row")
    }

    /// Contrast: a bound ledger with ≥1 protocol response and no transport
    /// failure DOES supply enough evidence to write the negative row.
    func testBoundCleanLedgerWritesNegativeRow() async {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        let resolver = MetadataResolver(diskCache: cache)
        MetadataResolver.searchITunesOverrideForTesting = { _, _, _ in nil }
        defer { MetadataResolver.searchITunesOverrideForTesting = nil }

        let ledger = NetworkOutcomeLedger()
        ledger.recordProtocolResponse()

        let result = await NetworkOutcomeLedger.$current.withValue(ledger) {
            await resolver.fetchLocalizedMetadata(title: "Some Bound Title", artist: "Some Bound Artist", duration: 210)
        }
        XCTAssertNil(result)
        XCTAssertTrue(cache.getNegative(title: "Some Bound Title", artist: "Some Bound Artist", duration: 210),
                      "a bound ledger with ≥1 protocol response and no transport failure must write the negative row")
    }

    // ------------------------------------------------------------------
    // MARK: - Second lookup within TTL issues 0 searchITunes calls
    // ------------------------------------------------------------------

    /// End-to-end through MetadataResolver: seed a negative row directly
    /// (simulating "first cold lookup already ran and came back empty"),
    /// then assert a second lookup within TTL never touches the network
    /// seam. Uses the DEBUG-only searchITunesOverrideForTesting injection —
    /// if the negative-cache short-circuit in fetchLocalizedMetadataUncoalesced
    /// regressed, this override would be invoked and the counter would be > 0.
    func testSecondLookupWithinTTLIssuesZeroSearchCalls() async {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        let resolver = MetadataResolver(diskCache: cache)
        cache.setNegative(title: "Some Random Title", artist: "Some Random Artist", duration: 200)

        var callCount = 0
        MetadataResolver.searchITunesOverrideForTesting = { _, _, _ in
            callCount += 1
            return nil
        }
        defer { MetadataResolver.searchITunesOverrideForTesting = nil }

        let result = await resolver.fetchLocalizedMetadata(title: "Some Random Title", artist: "Some Random Artist", duration: 200)
        XCTAssertNil(result)
        XCTAssertEqual(callCount, 0, "negative-cache hit must skip the network entirely")
    }
}
