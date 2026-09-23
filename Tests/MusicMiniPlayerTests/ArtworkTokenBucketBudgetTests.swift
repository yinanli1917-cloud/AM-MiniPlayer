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
 *        PROACTIVE half.
 *
 *        Fifth-round retune (this file): the first tuning (capacity 8,
 *        refill 12/min) left two sustained-demand scenarios (10 skips/60s,
 *        a cold playlist spread over 60s) mathematically unable to stay
 *        ≤12 in any 60s window, because the bucket's own ceiling for such a
 *        window is `capacity + refillPerMinute` = 20 — a hard fact about
 *        ANY token bucket, independent of how it's used. Retuned to
 *        capacity 6 + refill 6/min so `capacity + refillPerMinute == 12`
 *        EXACTLY: the ≤12/60s target is now a mathematical GUARANTEE for
 *        any demand pattern, not a per-scenario coincidence — which is
 *        exactly what the property-based test at the bottom of this file
 *        checks directly (500 random seeds, mixed priorities).
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
        XCTAssertEqual(bucket.available(now: t0), 6)
    }

    func test_bucket_refillsAtDeclaredRate_capsAtCapacity() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        XCTAssertEqual(bucket.reserve(upTo: 6, now: t0), 6, "drain it fully first")
        XCTAssertEqual(bucket.available(now: t0), 0)

        // 6/min = 1 token per 10s.
        XCTAssertEqual(bucket.available(now: t0.addingTimeInterval(9)), 0, "not yet a whole token")
        XCTAssertEqual(bucket.available(now: t0.addingTimeInterval(10)), 1)
        XCTAssertEqual(bucket.available(now: t0.addingTimeInterval(60)), 6, "a full 60s window refills exactly capacity's worth")
        XCTAssertEqual(bucket.available(now: t0.addingTimeInterval(600)), 6, "must cap at capacity, never grow unbounded")
    }

    func test_bucket_reserve_takesUpToAvailable_neverMore() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        XCTAssertEqual(bucket.reserve(upTo: 3, now: t0), 3, "min(storefront count, available, ≥1 if any) with plenty available")
        XCTAssertEqual(bucket.available(now: t0), 3)
        XCTAssertEqual(bucket.reserve(upTo: 100, now: t0), 3, "never returns more than truly available")
        XCTAssertEqual(bucket.reserve(upTo: 3, now: t0), 0, "0 tokens left — must return 0, the 'at least 1 if any' floor only applies when any exist")
    }

    func test_bucket_tryReserve_respectsKeepAtLeast() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        XCTAssertEqual(bucket.reserve(upTo: 2, now: t0), 2) // bucket now at 4
        XCTAssertTrue(bucket.tryReserve(1, keepAtLeast: 3, now: t0), "4 - 1 = 3, exactly at the floor — must succeed")
        XCTAssertEqual(bucket.available(now: t0), 3)
        XCTAssertFalse(bucket.tryReserve(1, keepAtLeast: 3, now: t0), "3 - 1 = 2 < 3 — must refuse and NOT consume")
        XCTAssertEqual(bucket.available(now: t0), 3, "a refused tryReserve must not have deducted anything")
    }

    func test_bucket_capacityOverride_forTestsThatWantEffectivelyUnlimitedTokens() {
        let bucket = MusicController.ArtworkITunesTokenBucket(capacity: 1000)
        XCTAssertEqual(bucket.available(), 1000)
    }

    /// Pins the coordinator's own reasoning: for a bucket starting a window
    /// at full charge, the max tokens obtainable across ANY window of
    /// `windowSeconds` is `capacity + refillPerMinute * (windowSeconds/60)`
    /// — for a 60s window with these constants that's exactly 12, with zero
    /// slack. This is what makes the ≤12/60s target a guarantee rather than
    /// a per-scenario coincidence (see the property test at the bottom).
    func test_bucket_capacityPlusRefillPerMinute_isExactly12() {
        XCTAssertEqual(
            MusicController.ArtworkITunesTokenBucket.capacity + MusicController.ArtworkITunesTokenBucket.refillPerMinute,
            12,
            "capacity + refill/min must equal the ≤12-per-60s target exactly for the guarantee to hold with zero slack"
        )
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
        private(set) var searchTimestamps: [Date] = []
        /// The fake-clock instant the driving test is currently simulating —
        /// NOT the real wall clock. Every scenario/property test sets this
        /// (via `setSimulatedNow`) to the same `now` it's about to pass to
        /// `fetchArtworkViaITunesAPIDetailed`, so a request fired from
        /// inside that call — including now-playing's parallel storefront
        /// fan-out, all "simultaneous" for one event — is timestamped at
        /// the SIMULATED instant, not whenever this closure actually runs
        /// on the real clock (a multi-minute synthetic timeline is meant to
        /// evaluate near-instantly in real time).
        private var simulatedNow = Date()

        func setSimulatedNow(_ date: Date) {
            simulatedNow = date
        }

        nonisolated func makeTransport() -> MusicController.ITunesArtworkTransport {
            MusicController.ITunesArtworkTransport(
                search: { [self] _, _ in
                    await self.recordAtSimulatedNow()
                    return .success([])
                },
                fetchImageData: { _ in nil }
            )
        }

        private func recordAtSimulatedNow() {
            searchCallCount += 1
            searchTimestamps.append(simulatedNow)
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
    /// `Task.sleep`, well under one 10s refill tick).
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

        let match = await simulateOneTrackChange(
            title: Self.worstCaseTitle, artist: Self.worstCaseArtist,
            transport: harness.makeTransport(), breaker: breaker, bucket: bucket, now: t0
        )
        XCTAssertNotNil(match)
        let searchCount = await harness.searchCallCount
        // storefront count (all fire in parallel, all "hit") + 1 image download.
        let expected = MusicController.artworkITunesStorefronts.count + 1
        XCTAssertEqual(searchCount + 1 /* the image download */, expected)
        XCTAssertLessThanOrEqual(expected, 12)
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
        XCTAssertLessThanOrEqual(searchCount, 12)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - PINNED: 5 skips in 30 seconds (+ per-skip storefront width)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Worst case: every one of the 5 skipped tracks is a genuine content
    /// gap (bracket-laden title, so round 2 is eligible; nothing anywhere,
    /// so round 2 + the retry both actually get attempted whenever tokens
    /// allow) — the most pessimistic realistic trace for request COUNT.
    /// Also reports, per skip, how many storefronts round 1's fan-out
    /// actually got (`min(3, tokens available at that instant)`) — the
    /// coordinator's ask for "where it degrades to one storefront".
    func test_fiveSkipsIn30Seconds_worstCase_totalRequestsAndRollingWindowPeak() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let bucket = MusicController.ArtworkITunesTokenBucket(now: t0)
        let harness = CountingEmptyTransport()
        let transport = harness.makeTransport()

        var perTrackCounts: [Int] = []
        var round1Widths: [Int] = []
        var previousTotal = 0
        for i in 0..<5 {
            let now = t0.addingTimeInterval(Double(i) * 6) // 5 skips spread over 30s
            // Round 1's actual fan-out width is exactly min(storefront
            // count, tokens available right now) — read here BEFORE the
            // call consumes anything, matching production's own formula.
            let storefrontCount = MusicController.orderedArtworkStorefronts(
                title: Self.worstCaseTitle, artist: Self.worstCaseArtist
            ).count
            round1Widths.append(min(storefrontCount, bucket.available(now: now)))

            _ = await simulateOneTrackChange(
                title: Self.worstCaseTitle, artist: Self.worstCaseArtist,
                transport: transport, breaker: breaker, bucket: bucket, now: now
            )
            let runningTotal = await harness.searchCallCount
            perTrackCounts.append(runningTotal - previousTotal)
            previousTotal = runningTotal
        }

        let total = await harness.searchCallCount
        print("[budget] 5 skips in 30s, worst case: per-track requests=\(perTrackCounts), round1 storefront width per skip=\(round1Widths), total=\(total) iTunes requests")
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
        // fan-out plus prior tracks' downloads have drawn the bucket down
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
        let totalRequests = searchCount + imagesDelivered
        print("[budget] 5 skips in 30s, best case (round 1 always finds a candidate): \(searchCount) search requests, \(imagesDelivered)/5 image downloads actually completed, \(totalRequests) total iTunes requests")
        XCTAssertLessThanOrEqual(totalRequests, 12, "60s-window peak must stay ≤12 (coordinator requirement)")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - PINNED: 10 skips in 60 seconds
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
        // With capacity 6 + refill 6/min (ceiling 12 for ANY 60s window),
        // this now holds unconditionally — see test_bucket_capacityPlusRefillPerMinute_isExactly12.
        XCTAssertLessThanOrEqual(total, 12, "60s-window peak must stay ≤12 (coordinator requirement) — now a mathematical guarantee, not a coincidence")
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
    /// as the user scrolls) instead of mounting all at once — sustained
    /// demand, the harder case for the ≤12 guarantee.
    func test_cold20RowPlaylist_spreadOverOneMinute_staysWithinPeak() async {
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
            XCTAssertGreaterThanOrEqual(tokensLeft, MusicController.ArtworkITunesTokenBucket.reserveForNowPlaying, "reserve floor must hold after every single row, not just at the end")
        }

        let total = await harness.searchCallCount
        print("[budget] cold 20-row playlist spread over 60s (1 row/3s), sustained demand: \(total) iTunes requests total")
        // With capacity 6 + refill 6/min (ceiling 12 for ANY 60s window),
        // this now holds unconditionally, including under sustained demand.
        XCTAssertLessThanOrEqual(total, 12, "60s-window peak must stay ≤12 (coordinator requirement) — now a mathematical guarantee, not a coincidence")
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
        // land at the exact same nanosecond — 10s later (one refill tick at
        // the new 6/min rate) the bucket is at 4: exactly enough for
        // now-playing's round 1 (≤3 storefronts) AND its own image
        // download. At the reserve floor's exact instant (t0, 0 elapsed),
        // round 1 alone can consume all 3 remaining tokens and leave
        // nothing for the image — a real, narrow edge case, not a guarantee
        // this bucket design makes (the coordinator's ask was "leave ≥3 for
        // now-playing", not "now-playing always completes from exactly 3");
        // it self-heals within one refill tick, which this test reflects
        // honestly.
        let npHarness = HitTransport()
        let nowPlayingMoment = t0.addingTimeInterval(10)
        let match = await MusicController.fetchArtworkViaITunesAPIDetailed(
            title: "Now Playing Song", artist: "Now Playing Artist", album: "",
            priority: .nowPlaying, transport: npHarness.makeTransport(), breaker: breaker, bucket: bucket, now: nowPlayingMoment
        )
        XCTAssertNotNil(match, "now-playing must still be able to fetch real art shortly after a full background storm")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Property test: random demand, 500 seeds, never exceeds 12/60s
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Deterministic, seedable PRNG (xorshift64*) — NOT cryptographic, just
    /// reproducible: the same seed always generates the same demand
    /// sequence, so a failure is re-runnable and debuggable.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) {
            self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545F4914F6CDD1D
        }
    }

    /// Maximum number of timestamps falling within ANY window of
    /// `windowSeconds` — the "peak requests in any sliding 60s window"
    /// metric the coordinator's ≤12 target is stated in terms of. Two-
    /// pointer sweep over sorted timestamps, O(n log n).
    private func maxCountInAnySlidingWindow(_ timestamps: [TimeInterval], windowSeconds: TimeInterval) -> Int {
        guard !timestamps.isEmpty else { return 0 }
        let sorted = timestamps.sorted()
        var maxCount = 0
        var left = 0
        for right in 0..<sorted.count {
            while sorted[right] - sorted[left] > windowSeconds {
                left += 1
            }
            maxCount = max(maxCount, right - left + 1)
        }
        return maxCount
    }

    /// 500 seeds × a random mix of now-playing/background "events" over a
    /// multi-minute synthetic timeline, always-miss transport (the worst
    /// case for request COUNT — see `CountingEmptyTransport`'s doc comment),
    /// bracket-or-not titles chosen at random (varies round-2 eligibility).
    /// Every actual iTunes request fired is timestamped at the simulated
    /// `now` of its owning event; the sliding-window peak across the WHOLE
    /// timeline must never exceed 12, for every one of the 500 seeds.
    func test_property_randomDemandSequences_neverExceed12RequestsInAnySlidingWindow() async {
        let seedCount = 500
        let simulatedDurationSeconds: Double = 180 // 3 minutes of synthetic activity per seed
        var worstSeed: UInt64?
        var worstPeak = 0

        for seed in 0..<UInt64(seedCount) {
            var rng = SeededGenerator(seed: seed &+ 1) // avoid the seed=0 special case reading as "unseeded"
            let breaker = MusicController.ArtworkITunesCircuitBreaker()
            let bucket = MusicController.ArtworkITunesTokenBucket(now: Date(timeIntervalSince1970: 0))
            let harness = CountingEmptyTransport()
            let transport = harness.makeTransport()

            var t: Double = 0
            while t < simulatedDurationSeconds {
                let now = Date(timeIntervalSince1970: t)
                await harness.setSimulatedNow(now)
                let isNowPlaying = Bool.random(using: &rng)
                let hasBrackets = Bool.random(using: &rng)
                let title = hasBrackets ? "Random Title (Live Version)" : "Random Title"
                let artist = "Random Artist \(Int.random(in: 0..<5, using: &rng))"

                if isNowPlaying {
                    // Reproduce the SAME retry-after-miss gate the harness
                    // above uses, but timestamp every request against `now`
                    // (the fake clock), not the real wall clock, since the
                    // whole point is a synthetic multi-minute timeline
                    // evaluated instantly.
                    let firstMatch = await MusicController.fetchArtworkViaITunesAPIDetailed(
                        title: title, artist: artist, album: "",
                        priority: .nowPlaying, transport: transport, breaker: breaker, bucket: bucket, now: now
                    )
                    if firstMatch == nil, !breaker.isOpen(now: now), bucket.available(now: now) >= 1 {
                        _ = await MusicController.fetchArtworkViaITunesAPIDetailed(
                            title: title, artist: artist, album: "",
                            priority: .nowPlaying, transport: transport, breaker: breaker, bucket: bucket, now: now
                        )
                    }
                } else {
                    _ = await MusicController.fetchArtworkViaITunesAPIDetailed(
                        title: title, artist: artist, album: "",
                        priority: .background, transport: transport, breaker: breaker, bucket: bucket, now: now
                    )
                }

                // Random inter-arrival: 0.5s-8s, covering both rapid-skip
                // bursts and slower, spread-out row mounting.
                t += Double.random(in: 0.5...8.0, using: &rng)
            }

            let timestamps = await harness.searchTimestamps.map { $0.timeIntervalSince1970 }
            let peak = maxCountInAnySlidingWindow(timestamps, windowSeconds: 60)
            if peak > worstPeak {
                worstPeak = peak
                worstSeed = seed
            }
            XCTAssertLessThanOrEqual(peak, 12, "seed \(seed): sliding 60s window peak was \(peak), must be ≤12")
        }

        print("[budget] property test: \(seedCount) seeds, worst observed 60s-window peak = \(worstPeak) (seed \(worstSeed.map(String.init) ?? "none"))")
    }
}
