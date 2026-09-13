import XCTest
@testable import MusicMiniPlayerCore

/// Gap 1 (2026-09-11): the CN artist-only translated-candidate arm
/// (`matchCNResult` + `promoteSafeTranslatedCandidates`) admitted a
/// "translated" candidate whose CJK title has NO relation to the input
/// title whenever `LanguageUtils.isLikelyEnglishTitle(title)` was true —
/// the corroboration check was skipped entirely for English-looking input.
/// A same-artist, same-duration SIBLING track (postmortem 006 class: a
/// storefront artist query can return exactly one unrelated song) was then
/// promoted as if it were a translation of the input, because the
/// artist-only branch of `promoteSafeTranslatedCandidates` only required
/// uniqueness + a tight duration window — never a title relation.
///
/// Uses the DEBUG-only `MetadataResolver.searchITunesOverrideForTesting`
/// seam so the repro is a pure algorithmic assertion, no network.
final class MetadataArtistOnlyTitleEvidenceTests: XCTestCase {

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

    /// RED (pre-fix): an artist-only CN search wave returns exactly one
    /// same-artist, same-duration, CJK-titled sibling track that has no
    /// phonetic or catalog-alias relation to "Shape of You" — the old code
    /// promoted it as a translated match on uniqueness + duration alone.
    /// GREEN (post-fix): with no title evidence and the search itself not
    /// scoped by the input title, the candidate must never be admitted —
    /// the whole song-scoped + artist-only search comes back unresolved
    /// (nil), not a wrong sibling.
    func testArtistOnlySiblingWithNoTitleRelationIsNotPromoted() async {
        let resolver = makeResolver()
        let title = "Shape of You"
        let artist = "Ed Sheeran"
        let duration: TimeInterval = 233.0

        MetadataResolver.searchITunesOverrideForTesting = { term, _, _ in
            let lowered = term.lowercased()
            if lowered == artist.lowercased() {
                // Same artist, near-identical duration, CJK title with NO
                // relation whatsoever to "Shape of You" — a sibling track,
                // not a translation.
                return [[
                    "trackName": "无关的歌曲",
                    "artistName": artist,
                    "trackTimeMillis": Int((duration + 0.05) * 1000)
                ]]
            }
            // Combined "title artist" and title-only waves: no results.
            return []
        }

        let result = await resolver.fetchChineseMetadata(title: title, artist: artist, duration: duration)
        XCTAssertNil(result, "an artist-only sibling with no title relation must not replace identity — expected unresolved (nil), not a wrong sibling")
    }

    /// Contrast: when the katakana-loanword or pinyin/romaji reading DOES
    /// corroborate the CJK candidate, the artist-only arm must still admit
    /// it — the fix only removes the blanket bypass for English-looking
    /// titles, it does not disable corroborated matches.
    func testArtistOnlyCandidateWithGenuineTitleRelationIsStillPromoted() async {
        let resolver = makeResolver()
        let title = "Lemon"
        let artist = "Kenshi Yonezu"
        let duration: TimeInterval = 255.0

        MetadataResolver.searchITunesOverrideForTesting = { term, _, _ in
            let lowered = term.lowercased()
            if lowered == artist.lowercased() {
                return [[
                    "trackName": "レモン",
                    "artistName": artist,
                    "trackTimeMillis": Int((duration + 0.05) * 1000)
                ]]
            }
            return []
        }

        let result = await resolver.fetchChineseMetadata(title: title, artist: artist, duration: duration)
        XCTAssertEqual(result?.title, "レモン", "a genuinely corroborated katakana-loanword title must still be promoted")
    }
}
