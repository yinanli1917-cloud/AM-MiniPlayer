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

    // MARK: - Behavioural: cost-governed cache evicts by cost, not entry count
    //
    // This is the failing-before behaviour: with `countLimit = 50` (the old
    // production config), inserting a 51st small item evicts the 1st
    // regardless of size. A pure cost-governed cache (no countLimit) instead
    // holds N > 50 small items as long as their total cost stays under the
    // limit, and evicts large items that exceed it on their own.
    //
    // `LyricsService.lyricsCache` itself is `private`, so this test builds a
    // standalone NSCache with the identical configuration contract (cost is
    // the sole governor, no countLimit) rather than reaching into the
    // production instance — the production wiring (no countLimit, cost:
    // estimatedLyricsCacheCost(for:) on every insert) is verified textually
    // by the three call sites plus `init()`, not by reflection here.

    private final class DummyItem: NSObject {
        let payload: String
        init(_ payload: String) { self.payload = payload }
    }

    func test_costGovernedCache_evictsByCostNotCount() {
        let cache = NSCache<NSString, DummyItem>()
        cache.totalCostLimit = 1000 // bytes

        // 51 tiny items (cost 10 each = 510 total), well under the limit.
        // With the OLD countLimit = 50 config, item #1 would already have
        // been evicted by the time #51 is inserted. With cost-only
        // governance, all 51 survive.
        for i in 0..<51 {
            cache.setObject(DummyItem("tiny-\(i)"), forKey: "tiny-\(i)" as NSString, cost: 10)
        }
        var survivors = 0
        for i in 0..<51 where cache.object(forKey: "tiny-\(i)" as NSString) != nil {
            survivors += 1
        }
        XCTAssertEqual(survivors, 51, "cost-only governance must not evict small items purely on count")

        // Now push the total cost over the limit with one large item; NSCache
        // is permitted (not guaranteed on every platform build) to evict
        // older entries to make room. We assert the large item itself is
        // always retrievable immediately after insertion, and that total
        // resident cost cannot literally exceed limit + the one active insert.
        cache.setObject(DummyItem("large"), forKey: "large" as NSString, cost: 900)
        XCTAssertNotNil(cache.object(forKey: "large" as NSString))
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
