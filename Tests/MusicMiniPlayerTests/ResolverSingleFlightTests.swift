/**
 * [INPUT]: MetadataResolver entry points + MetadataResolveProbe (DEBUG seam),
 *          MetadataDiskCache (temp-file instances, seeded replay rows)
 * [OUTPUT]: Single-flight coalescing proofs — N concurrent same-key consults
 *           execute ONE resolution body; different keys never coalesce; an
 *           awaiting caller's cancellation never kills the shared resolution
 * [POS]: Regression tests for the resolver coalescing layer (latency review,
 *        post-round-2 item B)
 */

import XCTest
@testable import MusicMiniPlayerCore

// ============================================================
// MARK: - Test Latch
// ============================================================

/// One-shot async latch. Resolution bodies await it at entry (via
/// `MetadataResolveProbe.entryGate`), so a test can hold a resolution
/// in flight while more callers pile onto the same key, then release
/// every blocked body at once. `entries` counts gate arrivals.
private actor ResolutionLatch {
    private(set) var entries = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entries += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

// ============================================================
// MARK: - ResolverSingleFlightTests
// ============================================================

final class ResolverSingleFlightTests: XCTestCase {

    func testMetadataSearchPlanRunsExactSongBeforeFuzzyRescue() {
        XCTAssertEqual(
            MetadataResolver.songScopedSearchWaves(title: "Song", artist: "Artist"),
            [["Song Artist"], ["Artist", "Song"]]
        )
    }

    func testStrictExactOriginalRejectsSameArtistDurationWrongTitle() {
        let results: [[String: Any]] = [[
            "trackName": "他不爱我",
            "artistName": "Karen Mok",
            "trackTimeMillis": 239_100
        ]]

        XCTAssertNil(MetadataResolver.strictExactOriginalResult(
            in: results,
            title: "A Candlelight Dinner With Only Ice Cream",
            artist: "Karen Mok",
            duration: 239
        ))
    }

    func testStrictExactOriginalAcceptsNormalizedSongIdentity() {
        let results: [[String: Any]] = [[
            "trackName": "A Candlelight Dinner With Only Ice Cream",
            "artistName": "Karen Mok",
            "trackTimeMillis": 239_400
        ]]

        let match = MetadataResolver.strictExactOriginalResult(
            in: results,
            title: "A Candlelight Dinner With Only Ice Cream",
            artist: "Karen Mok",
            duration: 239
        )
        XCTAssertEqual(match?.title, "A Candlelight Dinner With Only Ice Cream")
        XCTAssertEqual(match?.durationDiff ?? -1, 0.4, accuracy: 0.001)
    }

    // Test fixture inputs. All-CJK so every consult stays on deterministic
    // paths: CN/localized replay rows (seeded below) or fast guard exits —
    // zero network in this suite.
    private let title = "测试歌曲"
    private let artist = "测试歌手"
    private let duration: TimeInterval = 240

    override func setUp() {
        super.setUp()
        MetadataResolveProbe.reset()
    }

    override func tearDown() {
        MetadataResolveProbe.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Isolated resolver against a temp cache file — never the user cache.
    private func makeResolver() -> MetadataResolver {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-single-flight-\(UUID().uuidString).json")
        return MetadataResolver(diskCache: MetadataDiskCache(fileURL: url))
    }

    /// Seeds a CN-tier row that passes the matchCNResult replay guards:
    /// title containment + same artist + Δ0.5s — so fetchChineseMetadata
    /// resolves from disk without any network wave.
    private func seedChineseRow(_ resolver: MetadataResolver) {
        resolver.diskCache.setChinese(
            title: title, artist: artist, duration: duration,
            resolvedTitle: "测试歌曲完整版", resolvedArtist: artist,
            durationDiff: 0.5
        )
    }

    /// Seeds a localized-tier row accepted on replay for CJK input
    /// (shouldUseCachedLocalizedMetadata returns true for non-ASCII input).
    private func seedLocalizedRow(_ resolver: MetadataResolver) {
        resolver.diskCache.set(
            title: title, artist: artist, duration: duration,
            resolvedTitle: "テスト曲", resolvedArtist: "テスト歌手",
            region: "JP", durationDiff: 0.3
        )
    }

    /// Polls until at least `count` bodies have entered the gate (or the
    /// timeout passes — the caller asserts on the returned count, so a
    /// miss fails loudly instead of hanging the suite).
    private func waitForEntries(
        _ latch: ResolutionLatch, _ count: Int, timeout: TimeInterval = 5
    ) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = await latch.entries
            if n >= count { return n }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await latch.entries
    }

    /// Settle window: gives spawned callers ample time to either join the
    /// in-flight resolution (coalesced) or enter the gate (uncoalesced)
    /// before the latch opens. Task spawn + actor hop is microseconds;
    /// 300ms is orders-of-magnitude headroom.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - (a) Concurrency: same inputs execute ONE resolution

    func testConcurrentChineseConsultsExecuteResolutionOnce() async {
        let resolver = makeResolver()
        seedChineseRow(resolver)
        let latch = ResolutionLatch()
        MetadataResolveProbe.entryGate = { await latch.enterAndWait() }

        let callers = (0..<8).map { _ in
            Task { await resolver.fetchChineseMetadata(title: self.title, artist: self.artist, duration: self.duration) }
        }
        _ = await waitForEntries(latch, 1)
        await settle()
        await latch.open()

        for caller in callers {
            let value = await caller.value
            XCTAssertEqual(value?.title, "测试歌曲完整版")
            XCTAssertEqual(value?.artist, artist)
            XCTAssertEqual(value?.durationDiff, 0.5)
        }
        XCTAssertEqual(
            MetadataResolveProbe.count("chinese"), 1,
            "8 concurrent CN consults for the same song must share ONE resolution body"
        )
    }

    func testConcurrentLocalizedConsultsExecuteResolutionOnce() async {
        let resolver = makeResolver()
        seedLocalizedRow(resolver)
        let latch = ResolutionLatch()
        MetadataResolveProbe.entryGate = { await latch.enterAndWait() }

        let callers = (0..<6).map { _ in
            Task { await resolver.fetchLocalizedMetadata(title: self.title, artist: self.artist, duration: self.duration) }
        }
        _ = await waitForEntries(latch, 1)
        await settle()
        await latch.open()

        for caller in callers {
            let value = await caller.value
            XCTAssertEqual(value?.title, "テスト曲")
            XCTAssertEqual(value?.region, "JP")
        }
        XCTAssertEqual(
            MetadataResolveProbe.count("localized"), 1,
            "6 concurrent localized consults for the same song must share ONE resolution body"
        )
    }

    func testConcurrentSearchConsultsExecuteResolutionOnce() async {
        let resolver = makeResolver()
        seedChineseRow(resolver)
        let latch = ResolutionLatch()
        MetadataResolveProbe.entryGate = { await latch.enterAndWait() }

        let callers = (0..<6).map { _ in
            Task { await resolver.resolveSearchMetadata(title: self.title, artist: self.artist, duration: self.duration) }
        }
        _ = await waitForEntries(latch, 1)
        await settle()
        await latch.open()

        for caller in callers {
            let value = await caller.value
            XCTAssertEqual(value.title, "测试歌曲完整版")
            XCTAssertEqual(value.artist, artist)
        }
        XCTAssertEqual(
            MetadataResolveProbe.count("search"), 1,
            "6 concurrent resolveSearchMetadata consults must share ONE resolution body"
        )
        XCTAssertEqual(
            MetadataResolveProbe.count("chinese"), 1,
            "the single shared search body consults the CN tier exactly once"
        )
    }

    func testConcurrentAlbumScopedConsultsExecuteResolutionOnce() async {
        let resolver = makeResolver()
        let latch = ResolutionLatch()
        MetadataResolveProbe.entryGate = { await latch.enterAndWait() }

        // All-CJK title AND album → the body exits nil immediately after the
        // probe gate (the romanization guard), keeping the test offline.
        let callers = (0..<4).map { _ in
            Task {
                await resolver.resolveAlbumScopedMetadata(
                    title: self.title, artist: self.artist,
                    duration: self.duration, album: "测试专辑"
                )
            }
        }
        _ = await waitForEntries(latch, 1)
        await settle()
        await latch.open()

        for caller in callers {
            let value = await caller.value
            XCTAssertNil(value?.title)
        }
        XCTAssertEqual(
            MetadataResolveProbe.count("albumScoped"), 1,
            "4 concurrent album-scoped consults must share ONE resolution body"
        )
    }

    // MARK: - (b) Different inputs never coalesce

    func testDifferentInputsDoNotCoalesce() async {
        let resolver = makeResolver()
        seedChineseRow(resolver)
        resolver.diskCache.setChinese(
            title: "另一首歌", artist: "另一歌手", duration: 200,
            resolvedTitle: "另一首歌完整版", resolvedArtist: "另一歌手",
            durationDiff: 0.2
        )
        let latch = ResolutionLatch()
        MetadataResolveProbe.entryGate = { await latch.enterAndWait() }

        let first = Task { await resolver.fetchChineseMetadata(title: self.title, artist: self.artist, duration: self.duration) }
        let second = Task { await resolver.fetchChineseMetadata(title: "另一首歌", artist: "另一歌手", duration: 200) }

        // BOTH bodies must enter the gate — two keys, two executions.
        let entries = await waitForEntries(latch, 2)
        await latch.open()
        XCTAssertEqual(entries, 2, "different songs must run separate resolutions")

        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertEqual(firstValue?.title, "测试歌曲完整版")
        XCTAssertEqual(secondValue?.title, "另一首歌完整版")
        XCTAssertEqual(MetadataResolveProbe.count("chinese"), 2)
    }

    // MARK: - (c) Awaiter cancellation never cancels the shared resolution

    func testAwaiterCancellationDoesNotCancelSharedResolution() async {
        let resolver = makeResolver()
        seedChineseRow(resolver)
        let latch = ResolutionLatch()
        MetadataResolveProbe.entryGate = { await latch.enterAndWait() }

        let cancelledCaller = Task { await resolver.fetchChineseMetadata(title: self.title, artist: self.artist, duration: self.duration) }
        _ = await waitForEntries(latch, 1)

        let survivingCaller = Task { await resolver.fetchChineseMetadata(title: self.title, artist: self.artist, duration: self.duration) }
        await settle()

        // Cancel the FIRST awaiter while the shared resolution is gated.
        // The shared task must keep running for the second awaiter.
        cancelledCaller.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await latch.open()

        let survivorValue = await survivingCaller.value
        XCTAssertEqual(survivorValue?.title, "测试歌曲完整版")
        XCTAssertEqual(survivorValue?.durationDiff, 0.5)
        XCTAssertEqual(
            MetadataResolveProbe.count("chinese"), 1,
            "cancelling one awaiter must not kill or restart the shared resolution"
        )
    }
}
