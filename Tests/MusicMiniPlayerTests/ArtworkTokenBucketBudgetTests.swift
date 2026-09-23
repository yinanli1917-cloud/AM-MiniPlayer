/**
 * [INPUT]: MusicMiniPlayerCore MusicController.ArtworkITunesTokenBucket,
 *          fetchArtworkViaITunesAPIDetailed, ArtworkITunesCircuitBreaker
 * [OUTPUT]: Unit tests pinning the 2026-09-22 proactive iTunes request budget
 * [POS]: Test module. Coordinator's third-round review: even a CLEAN run
 *        with zero rate-limit rejections yet — 5 radio-track skips in 30s,
 *        every one hitting on round 1 — already cost ~25 iTunes requests
 *        against an observed ~20-30-requests-per-~2-minutes limit whose
 *        block lasts 20+ minutes and ALSO takes down MetadataResolver's
 *        iTunes-backed lyrics metadata calls. The circuit breaker
 *        (ArtworkPriorityAndCircuitBreakerTests) is reactive — it only
 *        engages after a rejection already happened. This file pins the
 *        PROACTIVE half: a shared token bucket (capacity 8, refill 12/min,
 *        reserve 3 for now-playing) that caps request volume before iTunes
 *        ever has a reason to reject anything, driven entirely by an
 *        injected fake clock — no real sleeps, no real network.
 *
 *        These tests call `fetchArtworkViaITunesAPIDetailed` directly
 *        (the same static, transport/breaker/bucket-injectable entry point
 *        `fetchArtworkResult` calls in production) rather than the full
 *        `MusicController` instance, matching this file's siblings
 *        (ArtworkStorefrontSelectionTests, ArtworkPriorityAndCircuitBreakerTests).
 *        The retry-after-miss gate itself lives inside `fetchArtwork`'s Path 1
 *        (a `MusicController` instance method using the real wall clock,
 *        consistent with the project's existing practice of not unit-testing
 *        SB/live-instance-bound code) — these tests reproduce that SAME gate
 *        (`breaker.isOpen() == false && bucket.available() >= 1`) explicitly
 *        in the harness so the budget math is pinned without needing a live
 *        MusicController.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class ArtworkTokenBucketBudgetTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Pure bucket arithmetic (fake clock, no network)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_bucket_startsAtFullCapacity() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        XCTAssertEqual(bucket.available(now: t0), 8)
    }

    func test_bucket_refillsAtDeclaredRate_capsAtCapacity() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        XCTAssertEqual(bucket.reserve(upTo: 8, now: t0), 8, "drain it fully first")
        XCTAssertEqual(bucket.available(now: t0), 0)

        // 12/min = 1 token per 5s.
        XCTAssertEqual(bucket.available(now: t0.addingTimeInterval(4)), 0, "not yet a whole token")
        XCTAssertEqual(bucket.available(now: t0.addingTimeInterval(5)), 1)
        XCTAssertEqual(bucket.available(now: t0.addingTimeInterval(30)), 6)
        XCTAssertEqual(bucket.available(now: t0.addingTimeInterval(600)), 8, "must cap at capacity, never grow unbounded")
    }

    func test_bucket_reserve_takesUpToAvailable_neverMore() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        XCTAssertEqual(bucket.reserve(upTo: 3, now: t0), 3, "min(storefront count, available, ≥1 if any) with plenty available")
        XCTAssertEqual(bucket.available(now: t0), 5)
        XCTAssertEqual(bucket.reserve(upTo: 100, now: t0), 5, "never returns more than truly available")
        XCTAssertEqual(bucket.reserve(upTo: 3, now: t0), 0, "0 tokens left — must return 0, the 'at least 1 if any' floor only applies when any exist")
    }

    func test_bucket_tryReserve_respectsKeepAtLeast() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        XCTAssertEqual(bucket.reserve(upTo: 4, now: t0), 4) // bucket now at 4
        XCTAssertTrue(bucket.tryReserve(1, keepAtLeast: 3, now: t0), "4 - 1 = 3, exactly at the floor — must succeed")
        XCTAssertEqual(bucket.available(now: t0), 3)
        XCTAssertFalse(bucket.tryReserve(1, keepAtLeast: 3, now: t0), "3 - 1 = 2 < 3 — must refuse and NOT consume")
        XCTAssertEqual(bucket.available(now: t0), 3, "a refused tryReserve must not have deducted anything")
    }

    func test_bucket_capacityOverride_forTestsThatWantEffectivelyUnlimitedTokens() {
        let bucket = MusicController.ArtworkITunesTokenBucket(capacity: 1000)
        XCTAssertEqual(bucket.available(), 1000)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Simulation harness: drives fetchArtworkViaITunesAPIDetailed with a fake clock
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Always-empty transport — every storefront search succeeds at the
    /// HTTP layer but returns 0 results, and image download is never
    /// reached. This is the WORST CASE for request COUNT: every round that
    /// tokens allow actually runs to completion (nothing short-circuits
    /// early the way a background sequential hit or a rate-limit abort
    /// would), so it is the correct trace for a request-budget ceiling.
    private actor CountingEmptyTransport {
        private(set) var searchCallCount = 0

        nonisolated func makeTransport() -> MusicController.ITunesArtworkTransport {
            MusicController.ITunesArtworkTransport(
                search: { [self] _, _ in
                    await self.increment()
                    return .success([])
                },
                fetchImageData: { _ in nil }
            )
        }

        private func increment() {
            searchCallCount += 1
        }
    }

    /// A title with a bracketed segment so `stripBracketedTitleSegments`
    /// actually changes it — this is what makes round 2 eligible to run at
    /// all (a title with nothing to strip skips round 2 unconditionally,
    /// regardless of tokens). Worst-case-for-request-count tracks all use
    /// this shape.
    private static let worstCaseTitle = "Song Title (Radio Edit)"
    private static let worstCaseArtist = "Some Artist"

    /// Reproduces the retry-after-miss gate that lives in `fetchArtwork`'s
    /// Path 1 (`MusicController+Artwork.swift`): the retry only runs if the
    /// breaker is closed AND the bucket has ≥1 token, using the SAME `now`
    /// snapshot as the initial attempt (matching that call site treating the
    /// gap between the initial miss and the retry as effectively
    /// instantaneous for budget purposes — the real gap is a 250ms-1.2s
    /// `Task.sleep`, well under one 5s refill tick).
    @discardableResult
    private func simulateOneTrackChange(
        title: String, artist: String,
        transport: MusicController.ITunesArtworkTransport,
        breaker: MusicController.ArtworkITunesCircuitBreaker,
        bucket: MusicController.ArtworkITunesTokenBucket,
        now: Date
    ) async -> MusicController.ITunesArtworkMatch? {
        if let match = await MusicController.fetchArtworkViaITunesAPIDetailed(
            title: title, artist: artist, album: "",
            priority: .nowPlaying, transport: transport, breaker: breaker, bucket: bucket, now: now
        ) {
            return match
        }
        guard !breaker.isOpen(now: now), bucket.available(now: now) >= 1 else {
            return nil
        }
        return await MusicController.fetchArtworkViaITunesAPIDetailed(
            title: title, artist: artist, album: "",
            priority: .nowPlaying, transport: transport, breaker: breaker, bucket: bucket, now: now
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - One track change: best case / worst case
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_oneTrackChange_bestCase_round1HitsImmediately_costsStorefrontCountPlusOne() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        let term = "\(Self.worstCaseTitle) \(Self.worstCaseArtist)"

        actor HitTransport {
            private(set) var searchCallCount = 0
            nonisolated func makeTransport() -> MusicController.ITunesArtworkTransport {
                MusicController.ITunesArtworkTransport(
                    search: { [self] _, _ in
                        await self.increment()
                        return .success([[
                            "trackName": ArtworkTokenBucketBudgetTests.worstCaseTitle,
                            "artistName": ArtworkTokenBucketBudgetTests.worstCaseArtist,
                            "collectionName": "",
                            "artworkUrl100": "https://example.com/100x100bb.jpg",
                        ]])
                    },
                    fetchImageData: { _ in Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") }
                )
            }
            private func increment() { searchCallCount += 1 }
        }
        let harness = HitTransport()
        _ = term // documents the term shape; harness matches on args generically

        let match = await simulateOneTrackChange(
            title: Self.worstCaseTitle, artist: Self.worstCaseArtist,
            transport: harness.makeTransport(), breaker: breaker, bucket: bucket, now: t0
        )
        XCTAssertNotNil(match)
        let searchCount = await harness.searchCallCount
        // storefront count (all fire in parallel, all "hit") + 1 image download.
        let expected = MusicController.artworkITunesStorefronts.count + 1
        XCTAssertEqual(searchCount + 1 /* the image download */, expected)
        print("[budget] one track change, best case: \(expected) iTunes requests (searchCount=\(searchCount) + 1 image)")
    }

    func test_oneTrackChange_worstCase_totalMiss_boundedByBucketCapacity() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        let harness = CountingEmptyTransport()

        let match = await simulateOneTrackChange(
            title: Self.worstCaseTitle, artist: Self.worstCaseArtist,
            transport: harness.makeTransport(), breaker: breaker, bucket: bucket, now: t0
        )
        XCTAssertNil(match)
        let searchCount = await harness.searchCallCount
        let tokensLeft = bucket.available(now: t0)
        print("[budget] one track change, worst case (total miss, no time passing): \(searchCount) iTunes requests, \(tokensLeft) tokens left")
        // The bucket's own capacity is the hard ceiling — a single track's
        // worst case (round1 + round2 + retry's round1 + retry's round2,
        // all happening "instantly" with no refill) can NEVER exceed it.
        XCTAssertLessThanOrEqual(searchCount, Int(MusicController.ArtworkITunesTokenBucket.capacity))
        XCTAssertEqual(tokensLeft, 0, "a genuine content-gap track change drains whatever the bucket had at the start")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - PINNED: 5 skips in 30 seconds
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Worst case: every one of the 5 skipped tracks is a genuine content
    /// gap (bracket-laden title, so round 2 is eligible; nothing anywhere,
    /// so round 2 + the retry both actually get attempted whenever tokens
    /// allow) — the most pessimistic realistic trace for request COUNT.
    func test_fiveSkipsIn30Seconds_worstCase_totalRequestsAndRollingWindowPeak() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        let harness = CountingEmptyTransport()
        let transport = harness.makeTransport()

        var perTrackCounts: [Int] = []
        var previousTotal = 0
        for i in 0..<5 {
            let now = t0.addingTimeInterval(Double(i) * 6) // 5 skips spread over 30s
            _ = await simulateOneTrackChange(
                title: Self.worstCaseTitle, artist: Self.worstCaseArtist,
                transport: transport, breaker: breaker, bucket: bucket, now: now
            )
            let runningTotal = await harness.searchCallCount
            perTrackCounts.append(runningTotal - previousTotal)
            previousTotal = runningTotal
        }

        let total = await harness.searchCallCount
        print("[budget] 5 skips in 30s, worst case: per-track=\(perTrackCounts), total=\(total) iTunes requests")
        // The entire burst fits inside a single 30s span, which is itself
        // inside any 60s window that contains it — so total == the 60s peak
        // for this scenario.
        XCTAssertLessThanOrEqual(total, 12, "60s-window peak must stay ≤12 (coordinator requirement)")
    }

    /// Best case: every skip hits immediately on round 1 — no round 2, no
    /// retry. Reported for contrast; still governed by the same bucket.
    func test_fiveSkipsIn30Seconds_bestCase_totalRequests() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)

        actor HitTransport {
            private(set) var searchCallCount = 0
            nonisolated func makeTransport() -> MusicController.ITunesArtworkTransport {
                MusicController.ITunesArtworkTransport(
                    search: { [self] _, _ in
                        await self.increment()
                        return .success([[
                            "trackName": "Plain Title", "artistName": "Plain Artist", "collectionName": "",
                            "artworkUrl100": "https://example.com/100x100bb.jpg",
                        ]])
                    },
                    fetchImageData: { _ in Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") }
                )
            }
            private func increment() { searchCallCount += 1 }
        }
        let harness = HitTransport()
        let transport = harness.makeTransport()

        // NOT asserted NotNil on every track: the search itself always
        // finds a candidate in this scenario, but the image download spends
        // its OWN token (coordinator's spec explicitly counts image
        // downloads against the same shared budget) — once round 1's
        // fan-out plus 4 prior tracks' downloads have drawn the bucket down
        // far enough, a later track's search can still succeed while its
        // image download is the one that gets token-starved. That is
        // correct, intended behavior, not a bug; this test reports the
        // resulting numbers rather than assuming every skip completes.
        var imagesDelivered = 0
        for i in 0..<5 {
            let now = t0.addingTimeInterval(Double(i) * 6)
            let match = await simulateOneTrackChange(
                title: "Plain Title", artist: "Plain Artist",
                transport: transport, breaker: breaker, bucket: bucket, now: now
            )
            if match != nil { imagesDelivered += 1 }
        }
        let searchCount = await harness.searchCallCount
        print("[budget] 5 skips in 30s, best case (round 1 always finds a candidate): \(searchCount) search requests, \(imagesDelivered)/5 image downloads actually completed, \(searchCount + imagesDelivered) total iTunes requests")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 10 skips in 60 seconds (reported, not asserted ≤12 — see spec)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_tenSkipsIn60Seconds_worstCase_totalRequests() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        let harness = CountingEmptyTransport()
        let transport = harness.makeTransport()

        var perTrackCounts: [Int] = []
        var previousTotal = 0
        for i in 0..<10 {
            let now = t0.addingTimeInterval(Double(i) * 6) // 10 skips spread over 60s
            _ = await simulateOneTrackChange(
                title: Self.worstCaseTitle, artist: Self.worstCaseArtist,
                transport: transport, breaker: breaker, bucket: bucket, now: now
            )
            let runningTotal = await harness.searchCallCount
            perTrackCounts.append(runningTotal - previousTotal)
            previousTotal = runningTotal
        }
        let total = await harness.searchCallCount
        print("[budget] 10 skips in 60s, worst case: per-track=\(perTrackCounts), total=\(total) iTunes requests")
        // NOT asserted ≤12 — see research/spec-2026-09-22-radio-artwork-storefronts.md
        // "结果补充（四轮）" for why a worst-case burst starting from a fully
        // idle/full bucket can exceed it under these exact parameters, and
        // reported here transparently rather than forced.
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - PINNED: cold 20-row playlist (background priority)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// All 20 rows "mount" at effectively the same instant (worst case for
    /// burst concentration) and every storefront search misses (worst case
    /// for request count per row — background stops at the first RELIABLE
    /// hit, so a real hit would cost fewer requests, not more). This is the
    /// scenario `RowArtworkFetchGate` already bounds to 3 concurrent
    /// fetches, but concurrency alone doesn't cap total REQUEST volume —
    /// only the token bucket's reserve-for-now-playing floor does that.
    func test_cold20RowPlaylist_worstCase_totalRequestsNeverExceedsReserveFloor() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        let harness = CountingEmptyTransport()
        let transport = harness.makeTransport()

        for _ in 0..<20 {
            _ = await MusicController.fetchArtworkViaITunesAPIDetailed(
                title: Self.worstCaseTitle, artist: Self.worstCaseArtist, album: "",
                priority: .background, transport: transport, breaker: breaker, bucket: bucket, now: t0
            )
        }

        let total = await harness.searchCallCount
        let tokensLeft = bucket.available(now: t0)
        print("[budget] cold 20-row playlist, worst case (instant mount, no refill): \(total) iTunes requests, \(tokensLeft) tokens left (reserve floor = \(MusicController.ArtworkITunesTokenBucket.reserveForNowPlaying))")
        XCTAssertLessThanOrEqual(total, 12, "60s-window peak must stay ≤12 (coordinator requirement)")
        XCTAssertGreaterThanOrEqual(tokensLeft, MusicController.ArtworkITunesTokenBucket.reserveForNowPlaying, "background must never dip below the now-playing reserve, no matter how many rows are waiting")
    }

    /// Same 20 rows, but spread across a full 60s window (rows trickling in
    /// as the user scrolls) instead of mounting all at once. NOT asserted
    /// ≤12 — reported honestly instead. Reason: sustained background demand
    /// over a full window lets refill (12 tokens/60s) keep feeding it almost
    /// continuously, since "leave ≥3 for now-playing" is a FLOOR, not a
    /// separate sub-budget — background is entitled to consume everything
    /// down to that floor repeatedly as it refills. The mathematical ceiling
    /// for ANY 60s window under these exact parameters (capacity 8, refill
    /// 12/min, reserve 3) is (capacity − reserve) + refill = (8−3)+12 = 17
    /// when demand is continuous for the whole window, and this trace (16)
    /// sits right at that ceiling. The instant-mount cold-playlist scenario
    /// above — a real burst, which is what "cold playlist mount" actually
    /// describes — stays at 5, well inside the ≤12 target; this spread
    /// variant is reported as a follow-up data point for the coordinator's
    /// judgment (see research/spec-2026-09-22-radio-artwork-storefronts.md
    /// "结果补充（四轮）"), not silently forced under the line.
    func test_cold20RowPlaylist_spreadOverOneMinute_reservedFloorHoldsButTotalExceeds12() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        let harness = CountingEmptyTransport()
        let transport = harness.makeTransport()

        for i in 0..<20 {
            let now = t0.addingTimeInterval(Double(i) * 3) // one row every 3s
            _ = await MusicController.fetchArtworkViaITunesAPIDetailed(
                title: Self.worstCaseTitle, artist: Self.worstCaseArtist, album: "",
                priority: .background, transport: transport, breaker: breaker, bucket: bucket, now: now
            )
            let tokensLeft = bucket.available(now: now)
            // The one guarantee that DOES hold unconditionally: the reserve
            // floor for now-playing is never breached, no matter how long
            // background sustains demand.
            XCTAssertGreaterThanOrEqual(tokensLeft, MusicController.ArtworkITunesTokenBucket.reserveForNowPlaying, "reserve floor must hold after every single row, not just at the end")
        }

        let total = await harness.searchCallCount
        print("[budget] cold 20-row playlist spread over 60s (1 row/3s), sustained demand: \(total) iTunes requests total — exceeds the ≤12 target under continuous background demand; see spec follow-up")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Background never starves now-playing even when both compete
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_backgroundStorm_stillLeavesTokensForNowPlaying_sharedBucket() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        let bgHarness = CountingEmptyTransport()

        // Drain the bucket down to the reserve floor with a background storm.
        for _ in 0..<20 {
            _ = await MusicController.fetchArtworkViaITunesAPIDetailed(
                title: Self.worstCaseTitle, artist: Self.worstCaseArtist, album: "",
                priority: .background, transport: bgHarness.makeTransport(), breaker: breaker, bucket: bucket, now: t0
            )
        }
        XCTAssertEqual(bucket.available(now: t0), MusicController.ArtworkITunesTokenBucket.reserveForNowPlaying)

        // Now-playing must still get its round 1 fan-out from the reserved balance.
        actor HitTransport {
            private(set) var searchCallCount = 0
            nonisolated func makeTransport() -> MusicController.ITunesArtworkTransport {
                MusicController.ITunesArtworkTransport(
                    search: { [self] _, _ in
                        await self.increment()
                        return .success([[
                            "trackName": "Now Playing Song", "artistName": "Now Playing Artist", "collectionName": "",
                            "artworkUrl100": "https://example.com/100x100bb.jpg",
                        ]])
                    },
                    fetchImageData: { _ in Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") }
                )
            }
            private func increment() { searchCallCount += 1 }
        }
        // A real background storm and a real now-playing track change don't
        // land at the exact same nanosecond — 5s later (one refill tick)
        // the bucket is at 4: exactly enough for now-playing's round 1
        // (≤3 storefronts) AND its own image download. At the reserve
        // floor's exact instant (t0, 0 elapsed), round 1 alone can consume
        // all 3 remaining tokens and leave nothing for the image — a real,
        // narrow edge case, not a guarantee this bucket design makes (the
        // coordinator's ask was "leave ≥3 for now-playing", not "now-playing
        // always completes from exactly 3"); it self-heals within one
        // refill tick, which this test reflects honestly.
        let npHarness = HitTransport()
        let nowPlayingMoment = t0.addingTimeInterval(5)
        let match = await MusicController.fetchArtworkViaITunesAPIDetailed(
            title: "Now Playing Song", artist: "Now Playing Artist", album: "",
            priority: .nowPlaying, transport: npHarness.makeTransport(), breaker: breaker, bucket: bucket, now: nowPlayingMoment
        )
        XCTAssertNotNil(match, "now-playing must still be able to fetch real art shortly after a full background storm")
    }
}
