/**
 * [INPUT]: MusicMiniPlayerCore RowArtworkVisibilityPolicy, RowArtworkTaskKey,
 *          RowArtworkSourceGate, RowArtworkFetchGate, RowArtworkNegativeCache
 * [OUTPUT]: Unit tests pinning the 2026-09-15 artwork-storm fix
 * [POS]: Test module. History/Up Next rows used to fetch artwork the instant
 *        they mounted regardless of page (PlaylistView never leaves the tree;
 *        History is a non-lazy VStack) — a 13-row burst measured ~12s of
 *        continuous serial ScriptingBridge activity, and app CPU median rose
 *        1.3% (1a8e4aa, pre-plan-H) → 26.1% (928e5e4, plan-H merged) on the
 *        same 30s Fureai measurement. These tests pin: zero fetches while the
 *        Playlist page is not on screen, bounded fetch concurrency, and
 *        non-library rows never attempting the ScriptingBridge tier.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class RowArtworkFetchPolicyTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Visibility policy: zero fetches while the page is invisible
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_shouldFetch_onlyWhenPlaylistPageVisible() {
        XCTAssertFalse(RowArtworkVisibilityPolicy.shouldFetch(currentPage: .album))
        XCTAssertFalse(RowArtworkVisibilityPolicy.shouldFetch(currentPage: .lyrics))
        XCTAssertTrue(RowArtworkVisibilityPolicy.shouldFetch(currentPage: .playlist))
    }

    /// The exact scenario that caused the storm: cold launch defaults to
    /// `.album`, then `playbackHistory` jumps from empty to its full
    /// persisted list on the first confirmed track change — while still on
    /// `.album`/`.lyrics`. The policy must refuse regardless of how many
    /// rows exist or how history changed underneath it.
    func test_shouldFetch_coldStartOnAlbumOrLyrics_refusesRegardlessOfHistorySize() {
        for page: PlayerPage in [.album, .lyrics] {
            XCTAssertFalse(RowArtworkVisibilityPolicy.shouldFetch(currentPage: page))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Task identity: SwiftUI .task(id:) actually re-fires on visibility flip
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_taskKey_differsOnlyWhenVisibilityOrIdentityChanges() {
        let invisible = RowArtworkTaskKey(persistentID: "ABC123", visible: false)
        let sameInvisible = RowArtworkTaskKey(persistentID: "ABC123", visible: false)
        let becameVisible = RowArtworkTaskKey(persistentID: "ABC123", visible: true)
        let differentTrack = RowArtworkTaskKey(persistentID: "XYZ789", visible: false)

        XCTAssertEqual(invisible, sameInvisible, "re-render with no real change must not refire .task")
        XCTAssertNotEqual(invisible, becameVisible, "becoming visible must refire .task so a still-missing row can fetch on demand")
        XCTAssertNotEqual(invisible, differentTrack)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Source gate: non-library rows skip the ScriptingBridge tier
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_allowsScriptingBridgeLookup_onlyForLibrarySourceKind() {
        XCTAssertTrue(RowArtworkSourceGate.allowsScriptingBridgeLookup(sourceKind: .library))
        XCTAssertFalse(RowArtworkSourceGate.allowsScriptingBridgeLookup(sourceKind: .radioOrStream))
        XCTAssertFalse(
            RowArtworkSourceGate.allowsScriptingBridgeLookup(sourceKind: .appleMusicCatalog),
            "an 'am:'-prefixed catalog stream was never in currentPlaylist or the local library — the scan is guaranteed-wasted Apple Event traffic"
        )
        XCTAssertFalse(RowArtworkSourceGate.allowsScriptingBridgeLookup(sourceKind: .unknown))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Fetch gate: bounded concurrency
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private actor ConcurrencyWitness {
        private var current = 0
        private(set) var maxObserved = 0
        func enter() { current += 1; maxObserved = max(maxObserved, current) }
        func leave() { current -= 1 }
    }

    /// 13 rows racing a limit-3 gate must never let more than 3 fetches run
    /// at once — the exact regression this fix closes (13 rows, unbounded,
    /// all serialized on one queue for ~12s continuous).
    func test_gate_neverExceedsLimit_underConcurrentLoad() async {
        let limit = 3
        let gate = RowArtworkFetchGate(limit: limit)
        let witness = ConcurrencyWitness()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<13 {
                group.addTask {
                    await gate.acquire()
                    await witness.enter()
                    // Yield a few times so slower tasks have a chance to pile
                    // up behind the gate before this one releases — makes the
                    // "did we actually get overlap" check meaningful without
                    // any wall-clock sleep.
                    for _ in 0..<5 { await Task.yield() }
                    await witness.leave()
                    gate.release()
                }
            }
        }

        let maxObserved = await witness.maxObserved
        XCTAssertLessThanOrEqual(maxObserved, limit)
        XCTAssertGreaterThan(maxObserved, 0)
    }

    func test_gate_acquireBeyondLimit_suspendsUntilRelease() async {
        let gate = RowArtworkFetchGate(limit: 1)
        await gate.acquire()
        XCTAssertEqual(gate.currentCountForTesting(), 1)

        let secondAcquired = ConcurrencyWitness()
        let secondTask = Task {
            await gate.acquire()
            await secondAcquired.enter()
        }

        // Give the second task a chance to run; it must still be waiting
        // because the only slot is held.
        await Task.yield()
        await Task.yield()
        let observedBeforeRelease = await secondAcquired.maxObserved
        XCTAssertEqual(observedBeforeRelease, 0, "second acquire must not proceed while the only slot is held")

        gate.release()
        _ = await secondTask.value
        let observedAfterRelease = await secondAcquired.maxObserved
        XCTAssertEqual(observedAfterRelease, 1, "releasing the held slot must hand it to the waiting acquire")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Negative cache: backoff, not a blind 8s retry
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_backoff_doublesPerFailure_cappedAtMax() {
        XCTAssertEqual(RowArtworkNegativeCache.backoff(forFailureCount: 1), 5)
        XCTAssertEqual(RowArtworkNegativeCache.backoff(forFailureCount: 2), 10)
        XCTAssertEqual(RowArtworkNegativeCache.backoff(forFailureCount: 3), 20)
        XCTAssertEqual(RowArtworkNegativeCache.backoff(forFailureCount: 4), 40)
        // Large failure counts must clamp, never grow unbounded.
        XCTAssertEqual(RowArtworkNegativeCache.backoff(forFailureCount: 20), RowArtworkNegativeCache.maxBackoff)
    }

    func test_shouldSkip_falseBeforeAnyFailure() {
        let cache = RowArtworkNegativeCache()
        XCTAssertFalse(cache.shouldSkip(key: "pid1"))
    }

    func test_recordFailure_thenShouldSkip_trueWithinBackoffWindow_falseAfter() {
        let cache = RowArtworkNegativeCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        cache.recordFailure(key: "pid1", now: t0)

        XCTAssertTrue(cache.shouldSkip(key: "pid1", now: t0.addingTimeInterval(1)))
        XCTAssertTrue(cache.shouldSkip(key: "pid1", now: t0.addingTimeInterval(4.9)))
        XCTAssertFalse(cache.shouldSkip(key: "pid1", now: t0.addingTimeInterval(5.1)))
    }

    func test_repeatedFailures_extendBackoffWindow() {
        let cache = RowArtworkNegativeCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        cache.recordFailure(key: "pid1", now: t0)               // backoff 5s -> retry at t0+5
        cache.recordFailure(key: "pid1", now: t0.addingTimeInterval(5)) // 2nd failure -> backoff 10s -> retry at t0+15

        XCTAssertTrue(cache.shouldSkip(key: "pid1", now: t0.addingTimeInterval(10)))
        XCTAssertFalse(cache.shouldSkip(key: "pid1", now: t0.addingTimeInterval(15.1)))
    }

    func test_recordSuccess_clearsFailureHistory() {
        let cache = RowArtworkNegativeCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        cache.recordFailure(key: "pid1", now: t0)
        XCTAssertTrue(cache.shouldSkip(key: "pid1", now: t0.addingTimeInterval(1)))

        cache.recordSuccess(key: "pid1")
        XCTAssertFalse(cache.shouldSkip(key: "pid1", now: t0.addingTimeInterval(1)))

        // A later failure after a success starts backoff fresh (count 1),
        // not compounded from before the success.
        cache.recordFailure(key: "pid1", now: t0.addingTimeInterval(2))
        XCTAssertEqual(cache.entryForTesting(key: "pid1")?.failureCount, 1)
    }

    func test_differentKeys_trackIndependentBackoff() {
        let cache = RowArtworkNegativeCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        cache.recordFailure(key: "pidA", now: t0)
        XCTAssertTrue(cache.shouldSkip(key: "pidA", now: t0))
        XCTAssertFalse(cache.shouldSkip(key: "pidB", now: t0))
    }
}
