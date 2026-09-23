/**
 * [INPUT]: MusicMiniPlayerCore MusicController.ArtworkFetchPriority,
 *          ArtworkITunesCircuitBreaker, isITunesRateLimitSignal,
 *          fetchArtworkViaITunesAPI
 * [OUTPUT]: Unit tests pinning the 2026-09-22 rate-limit regression fix
 * [POS]: Test module. Code review on the multi-storefront artwork fix (see
 *        ArtworkStorefrontSelectionTests.swift) flagged that
 *        `fetchArtworkResult` also serves playlist ROW artwork
 *        (`makeRowArtworkStore`, `fetchMusicKitArtwork`) and
 *        `preloadArtwork` — a cold ~20-row playlist would fan out 4
 *        PARALLEL iTunes requests per row instead of the old ~1, risking
 *        the same iTunes rate-limit the main session hit today (non-JSON
 *        rejections after ~25 requests/minute). These tests pin: (1)
 *        background priority queries storefronts SEQUENTIALLY and stops at
 *        the first reliable hit, so a row costs at most 1 in-flight request
 *        at a time; (2) now-playing priority keeps the full parallel
 *        fan-out; (3) a rate-limit-shaped failure (HTTP 403/429, or a
 *        non-JSON body) trips a shared circuit breaker that makes
 *        background fetches skip iTunes entirely for a cooldown window
 *        while now-playing still gets one storefront; (4) the breaker is a
 *        pure NSLock + injectable-clock type, unit-tested exactly like
 *        `RowArtworkNegativeCache` — no real sleep.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class ArtworkPriorityAndCircuitBreakerTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Circuit breaker: pure NSLock + injected clock (RowArtworkNegativeCache pattern)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_breaker_closedByDefault() {
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        XCTAssertFalse(breaker.isOpen())
    }

    func test_breaker_tripOpensForDeclaredDuration_thenAutoCloses() {
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        breaker.trip(now: t0)

        XCTAssertTrue(breaker.isOpen(now: t0))
        XCTAssertTrue(breaker.isOpen(now: t0.addingTimeInterval(MusicController.ArtworkITunesCircuitBreaker.openDuration - 1)))
        XCTAssertFalse(breaker.isOpen(now: t0.addingTimeInterval(MusicController.ArtworkITunesCircuitBreaker.openDuration + 1)))
    }

    func test_breaker_trip_returnsTrueOnlyOnClosedToOpenTransition() {
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(breaker.trip(now: t0), "first trip is a real transition — callers should log it")
        // This second trip ALSO extends the window (to t0+5+45=t0+50) —
        // that's the "extends window" behavior pinned separately below —
        // so the next check must be well past THAT point, not just past
        // the first trip's original t0+45.
        XCTAssertFalse(breaker.trip(now: t0.addingTimeInterval(5)), "still open — must not re-log every rate-limited request inside the same outage")

        // After the (extended) window fully elapses, a fresh trip is a new
        // transition again.
        let t1 = t0.addingTimeInterval(5 + MusicController.ArtworkITunesCircuitBreaker.openDuration + 1)
        XCTAssertTrue(breaker.trip(now: t1))
    }

    func test_breaker_retrip_extendsWindow_fromLatestTripTime() {
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        breaker.trip(now: t0)
        let extendPoint = t0.addingTimeInterval(30)
        breaker.trip(now: extendPoint) // still inside the first window — extends it

        // Without the extension the breaker would have closed at t0+45; the
        // extension pushes the close point to extendPoint+45.
        XCTAssertTrue(breaker.isOpen(now: t0.addingTimeInterval(46)))
        XCTAssertFalse(breaker.isOpen(now: extendPoint.addingTimeInterval(46)))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Rate-limit signal classification
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_rateLimitSignal_httpCodes403And429() {
        XCTAssertTrue(MusicController.isITunesRateLimitSignal(HTTPClient.HTTPError.httpError(statusCode: 403)))
        XCTAssertTrue(MusicController.isITunesRateLimitSignal(HTTPClient.HTTPError.httpError(statusCode: 429)))
    }

    func test_rateLimitSignal_nonJSONBody_isDecodingFailed() {
        // ITunesArtworkTransport.live only ever produces .decodingFailed
        // when JSON parsing fails on an otherwise-2xx response — exactly
        // iTunes' own "started rejecting us" tell from the research report.
        XCTAssertTrue(MusicController.isITunesRateLimitSignal(HTTPClient.HTTPError.decodingFailed))
    }

    func test_rateLimitSignal_ordinaryHTTPErrors_areNotRateLimits() {
        XCTAssertFalse(MusicController.isITunesRateLimitSignal(HTTPClient.HTTPError.httpError(statusCode: 500)))
        XCTAssertFalse(MusicController.isITunesRateLimitSignal(HTTPClient.HTTPError.notFound))
        XCTAssertFalse(MusicController.isITunesRateLimitSignal(HTTPClient.HTTPError.invalidURL))
    }

    func test_rateLimitSignal_nonHTTPError_isNotARateLimit() {
        struct SomeOtherError: Error {}
        XCTAssertFalse(MusicController.isITunesRateLimitSignal(SomeOtherError()))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Priority-aware request shape (injected transport, zero network)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    private func onePixelImageData() -> Data {
        Data(base64Encoded: Self.onePixelPNGBase64)!
    }

    /// Same actor-based thread-safe harness pattern as
    /// ArtworkStorefrontSelectionTests (the 4 storefronts race in true
    /// parallel child tasks for `.nowPlaying`, so a plain class harness is a
    /// real data race). Also records the ORDER search calls arrive in, so
    /// sequential-vs-parallel behavior is directly observable: a sequential
    /// caller awaits each search before issuing the next, so recorded
    /// timestamps/order strictly follow storefront order and each call
    /// completes before the next starts; a parallel caller issues them
    /// together.
    private actor TransportHarness {
        private(set) var searchCallCount = 0
        private(set) var countriesCalledInOrder: [String] = []
        private var responses: [String: Result<[[String: Any]], Error>] = [:]
        private var imageDataToReturn: Data?
        /// When set, every search call sleeps this long before returning —
        /// used to prove sequential calls never overlap (a concurrent second
        /// call would observe `inFlight > 0` set by the first).
        private var perCallDelayNanoseconds: UInt64 = 0
        private(set) var maxConcurrentInFlight = 0
        private var currentInFlight = 0

        func setResponse(_ result: Result<[[String: Any]], Error>, country: String, term: String) {
            responses["\(country)|\(term)"] = result
        }

        func setImageData(_ data: Data?) {
            imageDataToReturn = data
        }

        func setPerCallDelay(nanoseconds: UInt64) {
            perCallDelayNanoseconds = nanoseconds
        }

        private func enter() {
            currentInFlight += 1
            maxConcurrentInFlight = max(maxConcurrentInFlight, currentInFlight)
        }

        private func leave() {
            currentInFlight -= 1
        }

        private func recordSearch(country: String, term: String) async -> Result<[[String: Any]], Error> {
            searchCallCount += 1
            countriesCalledInOrder.append(country)
            enter()
            if perCallDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: perCallDelayNanoseconds)
            }
            leave()
            return responses["\(country)|\(term)"] ?? .success([])
        }

        nonisolated func makeTransport() -> MusicController.ITunesArtworkTransport {
            MusicController.ITunesArtworkTransport(
                search: { [self] term, storefront in
                    await self.recordSearch(country: storefront.country, term: term)
                },
                fetchImageData: { [self] _ in await self.imageDataToReturn }
            )
        }
    }

    func test_backgroundPriority_stopsAtFirstReliableHit_sequentially() async {
        let harness = TransportHarness()
        let term = "Gatsby Woman (2020 Remastered) Kingo Hamada"
        // JP is queried before TW in the region-inferred order for this
        // pure-ASCII title/artist; put the hit on the FIRST storefront so a
        // correct sequential implementation stops immediately.
        await harness.setResponse(.success([[
            "trackName": "Gatsby Woman (2020 Remastered)",
            "artistName": "Kingo Hamada",
            "collectionName": "",
            "artworkUrl100": "https://example.com/100x100bb.jpg",
        ]]), country: "JP", term: term)
        await harness.setImageData(onePixelImageData())

        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Gatsby Woman (2020 Remastered)", artist: "Kingo Hamada", album: "",
            priority: .background, transport: harness.makeTransport(), breaker: MusicController.ArtworkITunesCircuitBreaker()
        )

        XCTAssertNotNil(image)
        // 1 request total: stopped at the first (and only) storefront tried.
        let callCount = await harness.searchCallCount
        XCTAssertEqual(callCount, 1, "background priority must stop at the first reliable hit, not query every storefront")
    }

    func test_backgroundPriority_neverOverlapsRequests() async {
        let harness = TransportHarness()
        await harness.setPerCallDelay(nanoseconds: 10_000_000) // 10ms — long enough to observe overlap if it happened

        _ = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .background, transport: harness.makeTransport(), breaker: MusicController.ArtworkITunesCircuitBreaker()
        )

        let maxConcurrent = await harness.maxConcurrentInFlight
        XCTAssertEqual(maxConcurrent, 1, "background priority must never have more than 1 iTunes request in flight at a time — that's the whole point of the fix")
    }

    func test_backgroundPriority_totalMiss_queriesAllStorefrontsInOrder_thenRound2() async {
        let harness = TransportHarness()
        // No responses configured anywhere — a genuine content gap.
        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Gatsby Woman (2020 Remastered)", artist: "Kingo Hamada", album: "",
            priority: .background, transport: harness.makeTransport(), breaker: MusicController.ArtworkITunesCircuitBreaker()
        )

        XCTAssertNil(image)
        let callCount = await harness.searchCallCount
        // Worst case matches nowPlaying's worst case in COUNT (2 rounds ×
        // storefront count) — the difference is concurrency, not total
        // requests when everything genuinely misses.
        XCTAssertEqual(callCount, MusicController.artworkITunesStorefronts.count * 2)
        let order = await harness.countriesCalledInOrder
        let expectedOrder = MusicController.orderedArtworkStorefronts(
            title: "Gatsby Woman (2020 Remastered)", artist: "Kingo Hamada"
        ).map(\.country)
        XCTAssertEqual(Array(order.prefix(expectedOrder.count)), expectedOrder, "round 1 must try storefronts in the region-inferred order, one at a time")
    }

    func test_nowPlayingPriority_stillFansOutInParallel_evenThoughBackgroundIsSequential() async {
        let harness = TransportHarness()
        await harness.setPerCallDelay(nanoseconds: 10_000_000)

        _ = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .nowPlaying, transport: harness.makeTransport(), breaker: MusicController.ArtworkITunesCircuitBreaker()
        )

        let maxConcurrent = await harness.maxConcurrentInFlight
        XCTAssertGreaterThan(maxConcurrent, 1, "now-playing must keep the parallel fan-out — this is the priority the coordinator said must NOT change")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Circuit breaker integration: trips on rate-limit, gates background
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_rateLimitFailure_tripsBreaker_andAbortsRemainingSequentialStorefronts() async {
        let harness = TransportHarness()
        let term = "Ripples Danny Chan"
        // "Danny Chan" is pure ASCII, so LanguageUtils.inferRegions puts
        // JP/HK/TW ahead of US (see test_orderedStorefronts_pureASCII... in
        // ArtworkStorefrontSelectionTests) — fail whichever storefront
        // sequential search actually tries FIRST, rather than assuming US.
        let firstStorefront = MusicController.orderedArtworkStorefronts(title: "Ripples", artist: "Danny Chan").first!.country
        await harness.setResponse(.failure(HTTPClient.HTTPError.httpError(statusCode: 429)), country: firstStorefront, term: term)
        let breaker = MusicController.ArtworkITunesCircuitBreaker()

        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .background, transport: harness.makeTransport(), breaker: breaker
        )

        XCTAssertNil(image)
        XCTAssertTrue(breaker.isOpen(), "a 429 must trip the breaker")
        // Aborted after the FIRST rate-limited storefront — never tried the
        // remaining 3 in round 1, and round 2 is skipped entirely because
        // the breaker check at its own entry sees it's already open.
        let callCount = await harness.searchCallCount
        XCTAssertEqual(callCount, 1, "a rate-limit signal must abort the rest of this call's storefronts immediately, not exhaust the list into a host that's already rejecting")
    }

    func test_breakerOpen_backgroundPriority_skipsITunesEntirely_zeroRequests() async {
        let harness = TransportHarness()
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        breaker.trip(now: Date()) // simulate an outage already in progress

        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .background, transport: harness.makeTransport(), breaker: breaker
        )

        XCTAssertNil(image)
        let callCount = await harness.searchCallCount
        XCTAssertEqual(callCount, 0, "while the breaker is open, background priority must not make ANY iTunes request — not even round 1's first storefront")
    }

    func test_breakerOpen_nowPlayingPriority_stillTriesExactlyOneStorefront() async {
        let harness = TransportHarness()
        let term = "Ripples Danny Chan"
        // The reduced-to-1 storefront during an outage is whichever one
        // `orderedArtworkStorefronts` puts FIRST (region-inferred), not
        // necessarily "US" — see the same note in the previous test.
        let firstStorefront = MusicController.orderedArtworkStorefronts(title: "Ripples", artist: "Danny Chan").first!.country
        await harness.setResponse(.success([[
            "trackName": "Ripples", "artistName": "Danny Chan", "collectionName": "",
            "artworkUrl100": "https://example.com/100x100bb.jpg",
        ]]), country: firstStorefront, term: term)
        await harness.setImageData(onePixelImageData())
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        breaker.trip(now: Date())

        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .nowPlaying, transport: harness.makeTransport(), breaker: breaker
        )

        XCTAssertNotNil(image, "now-playing must still get a chance at real art during an outage")
        let callCount = await harness.searchCallCount
        XCTAssertEqual(callCount, 1, "during an outage now-playing is limited to exactly ONE storefront, not the full fan-out")
    }

    func test_breakerTrip_isSharedAcrossCalls_backgroundSeesEarlierNowPlayingTrip() async {
        // The breaker is a HOST-level resource: one call's rate-limit signal
        // must protect every other in-flight/subsequent call that shares the
        // same breaker instance, regardless of which priority tripped it.
        let breaker = MusicController.ArtworkITunesCircuitBreaker()
        let nowPlayingHarness = TransportHarness()
        await nowPlayingHarness.setResponse(.failure(HTTPClient.HTTPError.httpError(statusCode: 403)), country: "US", term: "A B")

        _ = await MusicController.fetchArtworkViaITunesAPI(
            title: "A", artist: "B", album: "",
            priority: .nowPlaying, transport: nowPlayingHarness.makeTransport(), breaker: breaker
        )
        XCTAssertTrue(breaker.isOpen())

        let backgroundHarness = TransportHarness()
        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .background, transport: backgroundHarness.makeTransport(), breaker: breaker
        )

        XCTAssertNil(image)
        let backgroundCallCount = await backgroundHarness.searchCallCount
        XCTAssertEqual(backgroundCallCount, 0, "a breaker tripped by the now-playing path must still gate a later background call sharing the same breaker")
    }
}
