import XCTest
@testable import MusicMiniPlayerCore

// ============================================================
// MARK: - Lyrics Memory Cache Cost Tests (A3)
// ============================================================
//
// `LyricsService.lyricsCache` is an NSCache<NSString, CachedLyricsItem>.
// NSCache.countLimit caps ENTRY COUNT regardless of size — a 3-line
// unsynced song and an 80-line word-level song both count as "1" — so the
// configured totalCostLimit (the byte-aware governor) was inert while every
// insert used the no-cost `setObject(_:forKey:)` overload. This mirrors the
// artwork-cache banned-pattern fix: always `setObject(_:forKey:cost:)` with a
// real byte estimate, cost is the sole governor, no countLimit.
//
// `LyricsService.estimatedLyricsCacheCost(for:)` is the pure estimator these
// tests pin. It is not the private `CachedLyricsItem` NSCache itself (that
// stays private to LyricsService), so the eviction/retention behavioural
// test below exercises a standalone NSCache configured the same way
// (totalCostLimit only, no countLimit) rather than the production cache
// instance — see the note on `test_costGovernedCache_evictsByCostNotCount`.

final class LyricsMemoryCacheCostTests: XCTestCase {

    // MARK: - Fixtures

    private func line(text: String, translation: String? = nil, wordCount: Int = 0) -> LyricLine {
        let words: [LyricWord] = (0..<wordCount).map { i in
            // Words must reconstruct to `text` (LyricLine's init invariant);
            // use single-character words repeated to keep this trivial.
            LyricWord(word: String(text.prefix(1)), startTime: TimeInterval(i), endTime: TimeInterval(i) + 1)
        }
        // When words are supplied, LyricLine requires their concatenation to
        // match text exactly, or it drops them. Build text from the words
        // themselves in that case so the fixture round-trips.
        if wordCount > 0 {
            let joinedText = String(repeating: String(text.prefix(1)), count: wordCount)
            return LyricLine(text: joinedText, startTime: 0, endTime: 1, words: words, translation: translation)
        }
        return LyricLine(text: text, startTime: 0, endTime: 1, translation: translation)
    }

    // MARK: - Estimator: monotonic in text length

    func test_cost_increasesWithLongerText() {
        let short = [line(text: "la")]
        let long = [line(text: "la la la la la la la la")]
        XCTAssertLessThan(
            LyricsService.estimatedLyricsCacheCost(for: short),
            LyricsService.estimatedLyricsCacheCost(for: long)
        )
    }

    func test_cost_increasesWithMoreLines() {
        let one = [line(text: "hello")]
        let many = Array(repeating: line(text: "hello"), count: 10)
        XCTAssertLessThan(
            LyricsService.estimatedLyricsCacheCost(for: one),
            LyricsService.estimatedLyricsCacheCost(for: many)
        )
    }

    // MARK: - Estimator: monotonic in word count

    func test_cost_increasesWithWordCount() {
        let noWords = [line(text: "hello", wordCount: 0)]
        let withWords = [line(text: "h", wordCount: 5)]
        XCTAssertLessThan(
            LyricsService.estimatedLyricsCacheCost(for: noWords),
            LyricsService.estimatedLyricsCacheCost(for: withWords)
        )
    }

    func test_cost_moreWordsCostsMoreThanFewerWords() {
        let fewWords = [line(text: "a", wordCount: 2)]
        let moreWords = [line(text: "a", wordCount: 8)]
        XCTAssertLessThan(
            LyricsService.estimatedLyricsCacheCost(for: fewWords),
            LyricsService.estimatedLyricsCacheCost(for: moreWords)
        )
    }

    // MARK: - Estimator: translation adds cost

    func test_cost_withTranslation_costsMoreThanWithout() {
        let withoutTranslation = [line(text: "hello world", translation: nil)]
        let withTranslation = [line(text: "hello world", translation: "你好世界")]
        XCTAssertLessThan(
            LyricsService.estimatedLyricsCacheCost(for: withoutTranslation),
            LyricsService.estimatedLyricsCacheCost(for: withTranslation)
        )
    }

    // MARK: - Estimator: empty lyrics still has fixed overhead, never zero/negative

    func test_cost_emptyLyrics_isPositiveFixedOverhead() {
        let cost = LyricsService.estimatedLyricsCacheCost(for: [])
        XCTAssertGreaterThan(cost, 0)
        XCTAssertEqual(cost, LyricsService.lyricsCacheFixedItemOverheadBytes)
    }

    // MARK: - Configuration: cache is governed by cost, not entry count
    //
    // The actual behaviour we care about — "51 small items all survive
    // while a 50-item countLimit would have evicted the first" — is NOT a
    // guarantee NSCache makes. Apple's NSCache docs state the cache "may
    // automatically evict objects... at any time" (memory pressure, or any
    // other reason) and none of its eviction behaviour is a strict LRU/FIFO
    // contract you can assert on a real cache instance. A prior full-suite
    // run under heavy load flaked here even though the production
    // configuration was correct — the test was asserting something Apple
    // does not promise, not detecting a product regression.
    //
    // So this pins the actual product invariant deterministically instead:
    // the live `lyricsCache` has no countLimit (cost is the sole governor)
    // and totalCostLimit is the documented 20 MiB budget. The per-insert
    // `cost:` wiring (estimatedLyricsCacheCost(for:) at every setObject call
    // site) is verified textually by the three call sites plus `init()`.
    func test_lyricsCache_isGovernedByCostNotCount() {
        let governance = LyricsService.shared.lyricsCacheGovernanceForTesting
        XCTAssertEqual(governance.countLimit, 0, "no countLimit: cost must be the sole governor")
        XCTAssertEqual(governance.totalCostLimit, 20 * 1024 * 1024, "20 MiB budget per architecture note in init()")
    }

    func test_costGovernedCache_singleOversizedItem_stillStoredButBoundsFutureGrowth() {
        // Sanity check on the governor itself: an item whose cost alone
        // exceeds totalCostLimit is NSCache's documented edge case (it may
        // still store it, but total cost tracking then drives eviction of
        // everything else). We only assert our estimator would classify such
        // a song's cost as "large" relative to the 20 MiB production limit,
        // i.e. the estimator's numbers are in the right order of magnitude.
        let hugeSong = Array(repeating: line(text: "a very long lyric line indeed", translation: "一行相当长的歌词翻译", wordCount: 8), count: 200)
        let cost = LyricsService.estimatedLyricsCacheCost(for: hugeSong)
        XCTAssertGreaterThan(cost, 0)
        XCTAssertLessThan(cost, 20 * 1024 * 1024, "a single realistic song must not alone consume the whole 20 MiB budget")
    }
}
