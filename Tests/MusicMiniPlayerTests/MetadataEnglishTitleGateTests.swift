import XCTest
@testable import MusicMiniPlayerCore

/// A2 English-title gate: a pure-English title with an ASCII artist (and a
/// non-CJK album, when given) has no CJK romanization to discover. Firing
/// the CN/JP/KR/HK/TW speculative discovery waves for it wastes 10-20+
/// iTunes/MusicKit round trips per cold fetch, every one discarded — the
/// waste was verified against "Billie Jean" / "Michael Jackson" in the task
/// A2 brief.
///
/// IMPORTANT (found while writing these tests, not assumed): the gate is
/// built on `LanguageUtils.isLikelyEnglishTitle`, which is DELIBERATELY
/// conservative (false-positive-averse — see LanguageUtils.swift) and only
/// fires on strong structural signals (function words, morphology,
/// consonant clusters impossible in pinyin/romaji/jyutping). "Billie Jean"
/// itself has none of those signals and is NOT gated by this predicate —
/// its waste is instead shielded by the negative-evidence cache
/// (MetadataNegativeEvidenceTests) on the second and later cold starts.
/// This test file therefore verifies the gate against titles the existing
/// heuristic actually recognizes (e.g. "Shape of You", via the function
/// word "of") — do not restate "Billie Jean" as a gate-predicate example.
///
/// Uses the DEBUG-only `MetadataResolver.searchITunesOverrideForTesting`
/// injection seam so the assertion is a pure call count, no network.
final class MetadataEnglishTitleGateTests: XCTestCase {

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    private func makeResolver() -> MetadataResolver {
        MetadataResolver(diskCache: MetadataDiskCache(fileURL: temporaryFileURL()))
    }

    override func tearDown() {
        MetadataResolver.searchITunesOverrideForTesting = nil
        super.tearDown()
    }

    // ------------------------------------------------------------------
    // MARK: - Gate predicate
    // ------------------------------------------------------------------

    func testGateTrueForPureEnglishTitleAndArtist() {
        // "Shape of You" carries the function word "of" — one of
        // isLikelyEnglishTitle's strong structural signals.
        XCTAssertTrue(MetadataResolver.speculativeCJKDiscoveryIsPointless(title: "Shape of You", artist: "Ed Sheeran"))
    }

    func testGateFalseForRomanizedInput() {
        // "Purasuchikku Rabu" (katakana romanized, not the official English
        // display title) has no English structural signal — inferRegions
        // semantics for genuinely-romanized input must be unchanged.
        XCTAssertFalse(MetadataResolver.speculativeCJKDiscoveryIsPointless(title: "Purasuchikku Rabu", artist: "Takeuchi Mariya"))
    }

    /// "Plastic Love" is the correct OFFICIAL English display title of a
    /// Japanese song (Mariya Takeuchi) — not a romanization — so the gate
    /// correctly reports it as pointless-to-discover-via-network. Finding
    /// the JP-native title ("プラスティック・ラヴ") for this class of song is
    /// the library-native-title probe's job (untouched by this gate, driven
    /// by local Apple Music library data rather than speculative network
    /// discovery) — not the CN/localized speculative waves this gate skips.
    func testGateTrueForOfficialEnglishTitleOfCJKSong() {
        XCTAssertTrue(MetadataResolver.speculativeCJKDiscoveryIsPointless(title: "Plastic Love", artist: "Mariya Takeuchi"))
    }

    func testGateFalseWhenAlbumContainsCJK() {
        XCTAssertFalse(MetadataResolver.speculativeCJKDiscoveryIsPointless(
            title: "Invisible", artist: "Mei Ehara", album: "不確か"
        ))
    }

    func testGateFalseWhenArtistNotPureASCII() {
        XCTAssertFalse(MetadataResolver.speculativeCJKDiscoveryIsPointless(title: "Dinner", artist: "官承华"))
    }

    func testGateTrueWithNonCJKAlbum() {
        XCTAssertTrue(MetadataResolver.speculativeCJKDiscoveryIsPointless(
            title: "Shape of You", artist: "Ed Sheeran", album: "Divide"
        ))
    }

    // ------------------------------------------------------------------
    // MARK: - GREEN: resolveSearchMetadata issues 0 speculative calls
    // ------------------------------------------------------------------
    //
    // RED-phase evidence (recorded before the fix, same assertion): calling
    // resolveSearchMetadata("Shape of You", "Ed Sheeran", 233) against the
    // pre-A2 tree (commit a693c8e, no gate in resolveRomanizedInput/
    // LyricsFetcher) fires the CN wave (2 waves × up to 3 terms) and the
    // localized region fan-out (regions inferred for pure-ASCII input:
    // JP/KR/HK/TW) — every `searchITunes` call landing on the override
    // below, so `callCount` was > 0 (observed 15 in this suite's sibling
    // assertion against "Billie Jean", which has the same shape). After the
    // gate, both assertions below are 0.

    func testPureEnglishInputIssuesZeroSpeculativeSearchCalls() async {
        let resolver = makeResolver()
        var callCount = 0
        MetadataResolver.searchITunesOverrideForTesting = { _, _, _ in
            callCount += 1
            return nil
        }
        let result = await resolver.resolveSearchMetadata(title: "Shape of You", artist: "Ed Sheeran", duration: 233)
        // Gate returns the input unchanged — no discovery, no mutation.
        XCTAssertEqual(result.title, "Shape of You")
        XCTAssertEqual(result.artist, "Ed Sheeran")
        XCTAssertEqual(callCount, 0, "pure-English input must not issue any speculative searchITunes calls")
    }

    func testAnotherPureEnglishSongIssuesZeroSpeculativeSearchCalls() async {
        let resolver = makeResolver()
        var callCount = 0
        MetadataResolver.searchITunesOverrideForTesting = { _, _, _ in
            callCount += 1
            return nil
        }
        _ = await resolver.resolveSearchMetadata(title: "Unconditional", artist: "Some Artist", duration: 200)
        XCTAssertEqual(callCount, 0)
    }

    /// Contrast case: a romanized (non-English) ASCII title MUST still fire
    /// the discovery waves — the gate must not regress the designed
    /// romanized→CJK resolution path.
    func testRomanizedInputStillIssuesSpeculativeSearchCalls() async {
        let resolver = makeResolver()
        var callCount = 0
        MetadataResolver.searchITunesOverrideForTesting = { _, _, _ in
            callCount += 1
            return nil
        }
        _ = await resolver.resolveSearchMetadata(title: "Purasuchikku Rabu", artist: "Takeuchi Mariya", duration: 275)
        XCTAssertGreaterThan(callCount, 0, "romanized (non-English) input must still probe CN/localized regions")
    }

    /// "Billie Jean" is the documented A2 waste example, but it has no
    /// strong English structural signal (see file header) so the PREDICATE
    /// does not gate it — this is the negative-evidence cache's job instead
    /// (MetadataNegativeEvidenceTests.testSecondLookupWithinTTLIssuesZeroSearchCalls).
    /// Pinned here so a future predicate change cannot silently start
    /// gating it without an accompanying test update.
    func testBillieJeanIsNotGatedByThePredicateAlone() {
        XCTAssertFalse(MetadataResolver.speculativeCJKDiscoveryIsPointless(title: "Billie Jean", artist: "Michael Jackson"))
    }

    // ------------------------------------------------------------------
    // MARK: - inferRegions semantics unchanged for non-English input
    // ------------------------------------------------------------------

    func testInferRegionsUnchangedForRomanizedInput() {
        let resolver = makeResolver()
        let regions = resolver.inferRegions(title: "Purasuchikku Rabu", artist: "Takeuchi Mariya")
        XCTAssertFalse(regions.isEmpty, "inferRegions must keep returning candidate regions for romanized input")
    }
}
