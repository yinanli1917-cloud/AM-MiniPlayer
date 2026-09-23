/**
 * [INPUT]: MusicMiniPlayerCore MusicController.ArtworkStorefront,
 *          orderedArtworkStorefronts, stripBracketedTitleSegments,
 *          selectBestITunesArtwork, ITunesArtworkTransport,
 *          fetchArtworkViaITunesAPI
 * [OUTPUT]: Unit tests pinning the 2026-09-22 radio-artwork multi-storefront fix
 * [POS]: Test module. Pins research/diagnosis-2026-09-22-radio-artwork.md +
 *        research/spec-2026-09-22-radio-artwork-storefronts.md: iTunes Search
 *        API queries with no `country` param silently default to the US
 *        storefront, which returns ZERO results for a real batch of
 *        JP/TW/HK-catalog radio tracks that a curl test proved ARE indexed
 *        under the exact same English title+artist in the JP/TW/HK stores.
 *        The repro tests below feed `selectBestITunesArtwork` (and the full
 *        `fetchArtworkViaITunesAPI` orchestration) the REAL fixture shapes
 *        from that curl test: an empty US result set alongside a real TW/HK
 *        hit. "US-only" is exactly what the pre-fix code effectively saw —
 *        it never sent a `country` param, so it only ever got the US answer.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class ArtworkStorefrontSelectionTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Repro: today's single-implicit-storefront (US-only) view of
    //         these real tracks is nil — exactly the reported bug.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// research's real curl test: `itunes.apple.com/search` with no
    /// `country` (→ US) returns 0 results for "Gatsby Woman (2020
    /// Remastered)" / "Kingo Hamada". This is EXACTLY the set of storefront
    /// results the pre-fix code (which never sent `country`) could ever see.
    func test_repro_usOnlyResults_realWorldGatsbyWomanFixture_findsNothing() {
        let winner = MusicController.selectBestITunesArtwork(
            title: "Gatsby Woman (2020 Remastered)",
            artist: "Kingo Hamada",
            album: "",
            storefrontResults: [("US", [])]
        )
        XCTAssertNil(winner, "US storefront alone has 0 results for this track (real curl evidence) — pre-fix code could never find it")
    }

    func test_repro_usOnlyResults_realWorldWhoAreYouFixture_findsNothing() {
        let winner = MusicController.selectBestITunesArtwork(
            title: "Who Are You? (DJ Version) [2022 Remaster]",
            artist: "Fujimaru Yoshino",
            album: "",
            storefrontResults: [("US", [])]
        )
        XCTAssertNil(winner)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Fix: adding the TW/HK storefront to the SAME query finds it
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_fix_multiStorefront_gatsbyWoman_findsTWMatch() {
        let twCandidate: [String: Any] = [
            "trackName": "Gatsby Woman (2020 Remastered)",
            "artistName": "Kingo Hamada",
            "collectionName": "Adventure",
            "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/gatsby100x100bb.jpg",
        ]
        let winner = MusicController.selectBestITunesArtwork(
            title: "Gatsby Woman (2020 Remastered)",
            artist: "Kingo Hamada",
            album: "",
            storefrontResults: [("US", []), ("TW", [twCandidate])]
        )
        XCTAssertEqual(winner?.country, "TW")
        XCTAssertEqual(winner?.artworkUrlString, "https://is1-ssl.mzstatic.com/image/thumb/gatsby300x300bb.jpg")
    }

    func test_fix_multiStorefront_misty_findsTWMatch_viaFeaturedArtistTitle() {
        // research: "Misty (feat. Glenn Osser and His Orchestra)" — real
        // catalog entry omits the featured-artist clause entirely, so this
        // is also a partial-match (contains) exercise, not just an empty-US
        // exercise. TW, not HK — 2026-09-22 coordinator review dropped HK
        // from the storefront set (TW and HK returned identical rows for
        // every probed track, Misty included).
        let twCandidate: [String: Any] = [
            "trackName": "Misty",
            "artistName": "Johnny Mathis",
            "collectionName": "Heavenly",
            "artworkUrl100": "https://example.com/misty100x100bb.jpg",
        ]
        let winner = MusicController.selectBestITunesArtwork(
            title: "Misty (feat. Glenn Osser and His Orchestra)",
            artist: "Johnny Mathis",
            album: "",
            storefrontResults: [("US", []), ("JP", []), ("TW", [twCandidate])]
        )
        XCTAssertEqual(winner?.country, "TW")
        XCTAssertEqual(winner?.artworkUrlString, "https://example.com/misty300x300bb.jpg")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Cross-storefront tie-break: earlier storefront wins on equal score
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_equalScoreAcrossStorefronts_earlierStorefrontWins() {
        let candidate: [String: Any] = [
            "trackName": "Starlight Ballet",
            "artistName": "Piper",
            "collectionName": "",
            "artworkUrl100": "https://example.com/EARLIER-100x100bb.jpg",
        ]
        let sameScoreLater: [String: Any] = [
            "trackName": "Starlight Ballet",
            "artistName": "Piper",
            "collectionName": "",
            "artworkUrl100": "https://example.com/LATER-100x100bb.jpg",
        ]
        let winner = MusicController.selectBestITunesArtwork(
            title: "Starlight Ballet", artist: "Piper", album: "",
            storefrontResults: [("JP", [candidate]), ("TW", [sameScoreLater])]
        )
        XCTAssertEqual(winner?.country, "JP")
        XCTAssertTrue(winner?.artworkUrlString.contains("EARLIER") == true)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Reliability gate still applies across storefronts
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_unreliableCandidate_acrossAllStorefronts_returnsNil() {
        // Title-only, no artist/album corroboration anywhere → never reliable,
        // regardless of how many storefronts offer a same-title candidate.
        let weakMatch: [String: Any] = [
            "trackName": "Once Upon a Time",
            "artistName": "Someone Else Entirely",
            "collectionName": "Unrelated Album",
            "artworkUrl100": "https://example.com/wrong-100x100bb.jpg",
        ]
        let winner = MusicController.selectBestITunesArtwork(
            title: "Once Upon a Time", artist: "Frank Sinatra", album: "",
            storefrontResults: [("US", [weakMatch]), ("JP", [weakMatch])]
        )
        XCTAssertNil(winner)
    }

    func test_missingArtworkUrlKey_isSkipped_notCrashed() {
        let malformed: [String: Any] = [
            "trackName": "Ripples", "artistName": "Danny Chan", "collectionName": "Album",
        ]
        let winner = MusicController.selectBestITunesArtwork(
            title: "Ripples", artist: "Danny Chan", album: "",
            storefrontResults: [("US", [malformed])]
        )
        XCTAssertNil(winner)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Storefront ordering: region inference reorders, never drops
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_orderedStorefronts_pureASCIITitleArtist_putsJPTWBeforeUS() {
        // Matches LanguageUtils.inferRegions' own pure-ASCII fallback order
        // (JP, KR, HK, TW) — KR has no iTunes storefront in our set (never
        // did) and HK was dropped 2026-09-22 (identical rows to TW in every
        // probe), so both are skipped, and the untouched US entry is pushed
        // to the end.
        let ordered = MusicController.orderedArtworkStorefronts(
            title: "Gatsby Woman (2020 Remastered)", artist: "Kingo Hamada"
        )
        XCTAssertEqual(ordered.map(\.country), ["JP", "TW", "US"])
    }

    func test_orderedStorefronts_everyDeclaredStorefrontStillPresent() {
        let ordered = MusicController.orderedArtworkStorefronts(title: "Anything", artist: "Anyone")
        XCTAssertEqual(Set(ordered.map(\.country)), Set(MusicController.artworkITunesStorefronts.map(\.country)))
        XCTAssertEqual(ordered.count, MusicController.artworkITunesStorefronts.count, "reordering must never drop or duplicate a storefront")
    }

    func test_orderedStorefronts_noInference_keepsDeclaredOrder() {
        // LanguageUtils.inferRegions only returns [] when the artist is
        // BOTH non-pure-ASCII (so the "pure ASCII → JP/KR/HK/TW" fallback
        // doesn't fire) AND free of every covered non-Latin script/diacritic
        // set (so no explicit region is detected either) — a plain empty
        // string does NOT qualify (empty is vacuously pure-ASCII).
        let ordered = MusicController.orderedArtworkStorefronts(title: "Something", artist: "Müller")
        XCTAssertEqual(ordered, MusicController.artworkITunesStorefronts)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Bracket/parenthetical stripping (generic, not a keyword list)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_stripBracketedTitleSegments_realWorldExamples() {
        XCTAssertEqual(
            MusicController.stripBracketedTitleSegments("Gatsby Woman (2020 Remastered)"),
            "Gatsby Woman"
        )
        XCTAssertEqual(
            MusicController.stripBracketedTitleSegments("Who Are You? (DJ Version) [2022 Remaster]"),
            "Who Are You?"
        )
        XCTAssertEqual(
            MusicController.stripBracketedTitleSegments("Misty (feat. Glenn Osser and His Orchestra)"),
            "Misty"
        )
        XCTAssertEqual(
            MusicController.stripBracketedTitleSegments("Ripples"),
            "Ripples",
            "a title with nothing to strip must come back unchanged"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Full orchestration (injected transport, zero network)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// This file tests storefront/round SELECTION logic, not the token
    /// budget (ArtworkTokenBucketBudgetTests owns that, at the real
    /// production capacity 6/refill 6-per-minute — deliberately tight
    /// enough that 2 rounds × 3 storefronts + 1 image download can exceed
    /// it). An effectively unlimited bucket keeps these tests focused on
    /// round1/round2/tie-break behavior without being coupled to the exact
    /// budget constants.
    private static func unlimitedBucket() -> MusicController.ArtworkITunesTokenBucket {
        MusicController.ArtworkITunesTokenBucket(capacity: 1000)
    }

    /// 1×1 transparent PNG — small, real, decodable image bytes so
    /// `NSImage(data:)` succeeds inside the orchestration path (unlike the
    /// pure `selectBestITunesArtwork` tests above, this exercises the actual
    /// `fetchArtworkViaITunesAPI` function end to end).
    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    private func onePixelImageData() -> Data {
        Data(base64Encoded: Self.onePixelPNGBase64)!
    }

    /// The 4 storefronts race in TRUE parallel child tasks inside
    /// `fetchArtworkViaITunesAPIRound`'s `withTaskGroup`, so a plain class
    /// harness mutated from the `search` closure is a real data race (it
    /// crashed the test process the first time this was run, with a
    /// corrupted-dictionary `NSInvalidArgumentException` — exactly the kind
    /// of failure concurrent unsynchronized access produces). An actor
    /// serializes every read/write.
    private actor TransportHarness {
        private(set) var searchCallCount = 0
        private var responses: [String: Result<[[String: Any]], Error>] = [:]
        private var imageDataToReturn: Data?

        /// Keyed "\(country)|\(term)" → canned outcome. Missing key = empty success.
        func setResponse(_ result: Result<[[String: Any]], Error>, country: String, term: String) {
            responses["\(country)|\(term)"] = result
        }

        func setImageData(_ data: Data?) {
            imageDataToReturn = data
        }

        private func recordSearch(country: String, term: String) -> Result<[[String: Any]], Error> {
            searchCallCount += 1
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

    func test_orchestration_round1Hit_returnsImage_withoutRound2() async {
        let harness = TransportHarness()
        let term = "Gatsby Woman (2020 Remastered) Kingo Hamada"
        await harness.setResponse(.success([[
            "trackName": "Gatsby Woman (2020 Remastered)",
            "artistName": "Kingo Hamada",
            "collectionName": "",
            "artworkUrl100": "https://example.com/100x100bb.jpg",
        ]]), country: "TW", term: term)
        await harness.setImageData(onePixelImageData())

        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Gatsby Woman (2020 Remastered)", artist: "Kingo Hamada", album: "",
            priority: .nowPlaying, transport: harness.makeTransport(),
            breaker: MusicController.ArtworkITunesCircuitBreaker(), bucket: Self.unlimitedBucket()
        )

        XCTAssertNotNil(image)
        // 3 storefronts (US/JP/TW), round 1 only — round 2 must not fire once round 1 wins.
        let callCount = await harness.searchCallCount
        XCTAssertEqual(callCount, MusicController.artworkITunesStorefronts.count)
    }

    func test_orchestration_round1EmptyEverywhere_fallsBackToStrippedTitleRound2() async {
        let harness = TransportHarness()
        let strippedTerm = "Misty Johnny Mathis"
        // Round 1 (full title with the "(feat. ...)" clause) returns empty
        // everywhere — matches the real curl finding ("US 用完整标题 0 条").
        // TW, not HK (dropped 2026-09-22 — identical rows to TW in every probe).
        await harness.setResponse(.success([[
            "trackName": "Misty",
            "artistName": "Johnny Mathis",
            "collectionName": "",
            "artworkUrl100": "https://example.com/100x100bb.jpg",
        ]]), country: "TW", term: strippedTerm)
        await harness.setImageData(onePixelImageData())

        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Misty (feat. Glenn Osser and His Orchestra)", artist: "Johnny Mathis", album: "",
            priority: .nowPlaying, transport: harness.makeTransport(),
            breaker: MusicController.ArtworkITunesCircuitBreaker(), bucket: Self.unlimitedBucket()
        )

        XCTAssertNotNil(image)
        // Round 1 (3 storefronts, full title) + round 2 (3 storefronts, stripped title).
        let callCount = await harness.searchCallCount
        XCTAssertEqual(callCount, MusicController.artworkITunesStorefronts.count * 2)
    }

    func test_orchestration_noBracketsToStrip_skipsRound2_afterTotalMiss() async {
        let harness = TransportHarness()
        // "Ripples" has nothing to strip — round 2's term would be identical
        // to round 1's, so it must never fire a second wave of requests.
        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .nowPlaying, transport: harness.makeTransport(),
            breaker: MusicController.ArtworkITunesCircuitBreaker(), bucket: Self.unlimitedBucket()
        )

        XCTAssertNil(image)
        let callCount = await harness.searchCallCount
        XCTAssertEqual(callCount, MusicController.artworkITunesStorefronts.count, "no brackets to strip means no round 2 — must not double the request count")
    }

    func test_orchestration_totalMissWithBrackets_costsAtMostTwoRoundsOfStorefronts() async {
        let harness = TransportHarness()
        // Genuine content gap: nothing anywhere, in either round.
        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Gatsby Woman (2020 Remastered)", artist: "Kingo Hamada", album: "",
            priority: .nowPlaying, transport: harness.makeTransport(),
            breaker: MusicController.ArtworkITunesCircuitBreaker(), bucket: Self.unlimitedBucket()
        )

        XCTAssertNil(image)
        let callCount = await harness.searchCallCount
        XCTAssertEqual(callCount, MusicController.artworkITunesStorefronts.count * 2, "worst case is exactly 2 rounds × storefront count search requests, never unbounded")
    }

    func test_orchestration_searchHitButImageDownloadFails_returnsNil() async {
        let harness = TransportHarness()
        let term = "Ripples Danny Chan"
        await harness.setResponse(.success([[
            "trackName": "Ripples", "artistName": "Danny Chan", "collectionName": "",
            "artworkUrl100": "https://example.com/100x100bb.jpg",
        ]]), country: "US", term: term)
        await harness.setImageData(nil) // download fails

        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .nowPlaying, transport: harness.makeTransport(),
            breaker: MusicController.ArtworkITunesCircuitBreaker(), bucket: Self.unlimitedBucket()
        )

        XCTAssertNil(image)
    }

    func test_orchestration_transportError_isTreatedAsUnreliable_notCrashed() async {
        let harness = TransportHarness()
        struct FakeTransportError: Error {}
        let term = "Ripples Danny Chan"
        for country in ["US", "JP", "TW"] {
            await harness.setResponse(.failure(FakeTransportError()), country: country, term: term)
        }

        let image = await MusicController.fetchArtworkViaITunesAPI(
            title: "Ripples", artist: "Danny Chan", album: "",
            priority: .nowPlaying, transport: harness.makeTransport(),
            breaker: MusicController.ArtworkITunesCircuitBreaker(), bucket: Self.unlimitedBucket()
        )

        XCTAssertNil(image)
    }
}
