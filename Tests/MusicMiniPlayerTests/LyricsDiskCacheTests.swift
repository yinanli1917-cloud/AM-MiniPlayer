import XCTest
@testable import MusicMiniPlayerCore

final class LyricsDiskCacheTests: XCTestCase {
    func testCacheKeyIncludesAlbumToAvoidSameTrackVersionCollisions() {
        let a = LyricsDiskCache.cacheKeys(
            title: "There's A Kind Of Hush",
            artist: "Carpenters",
            duration: 184,
            album: "Carpenters Gold (35th Anniversary Edition)"
        )
        let b = LyricsDiskCache.cacheKeys(
            title: "There's A Kind Of Hush",
            artist: "Carpenters",
            duration: 184,
            album: "The Singles 1969-1973"
        )

        XCTAssertNotEqual(a, b)
    }

    func testAlbumScopedCacheDoesNotReturnDifferentAlbumEntry() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let cache = LyricsDiskCache(fileURL: url)
        let line = LyricLine(text: "Long ago and oh so far away", startTime: 12, endTime: 15)

        cache.set(
            title: "Superstar",
            artist: "Carpenters",
            duration: 232,
            album: "Carpenters",
            source: "NetEase",
            lines: [line],
            matchedDurationDiff: 0.1
        )

        XCTAssertNotNil(cache.get(title: "Superstar", artist: "Carpenters", duration: 232, album: "Carpenters"))
        XCTAssertNil(cache.get(title: "Superstar", artist: "Carpenters", duration: 232, album: "Close To You"))
    }

    func testCandidatesReturnNearbyDurationEntriesForUsabilityFiltering() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let cache = LyricsDiskCache(fileURL: url)

        cache.set(
            title: "Dance Around the Fire",
            artist: "Why These Coyotes",
            duration: 200,
            album: "Dance Around the Fire - Single",
            source: "NetEase",
            lines: [LyricLine(text: "움직일 수 없어", startTime: 30, endTime: 35)],
            matchedDurationDiff: 0.1
        )
        cache.set(
            title: "Dance Around the Fire",
            artist: "Why These Coyotes",
            duration: 201,
            album: "Dance Around the Fire - Single",
            source: "LRCLIB",
            lines: [LyricLine(text: "Sneaking out for the weekend", startTime: 29, endTime: 33)],
            matchedDurationDiff: 0.9
        )

        let candidates = cache.candidates(
            title: "Dance Around the Fire",
            artist: "Why These Coyotes",
            duration: 200.869,
            album: "Dance Around the Fire - Single"
        )
        XCTAssertGreaterThanOrEqual(candidates.count, 2)
        XCTAssertTrue(candidates.contains { $0.source == "LRCLIB" })
    }

    func testAvailabilityCachePreservesInstrumentalKind() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let cache = LyricsDiskCache(fileURL: url)
        let line = LyricLine(text: "Instrumental", startTime: 0, endTime: 228)

        cache.setAvailability(
            title: "Memento",
            artist: "Resavoir & Matt Gold",
            duration: 228,
            album: "Horizon",
            source: "QQ",
            kind: .instrumental,
            lines: [line],
            matchedDurationDiff: 0.3
        )

        let cached = cache.get(title: "Memento", artist: "Resavoir & Matt Gold", duration: 228, album: "Horizon")
        XCTAssertEqual(cached?.kind, .instrumental)
        XCTAssertEqual(cached?.source, "QQ")
        XCTAssertEqual(cached?.lines?.first?.text, "Instrumental")
    }

    // Provider-unavailable is retryable evidence, never a durable negative
    // verdict: setAvailability must drop it instead of persisting a 24h row
    // (spec: lyrics-pipeline.md "Provider unavailable is not song unavailable").
    func testAvailabilityCacheDropsUnavailableKind() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let cache = LyricsDiskCache(fileURL: url)

        cache.setAvailability(
            title: "Memento",
            artist: "Resavoir & Matt Gold",
            duration: 228,
            album: "Horizon",
            source: "NetEase",
            kind: .unavailable,
            lines: [],
            matchedDurationDiff: 0.2
        )

        let cached = cache.get(title: "Memento", artist: "Resavoir & Matt Gold", duration: 228, album: "Horizon")
        XCTAssertNil(cached)
    }

    func testCachePrunesOldEntriesToBoundMemoryGrowth() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let cache = LyricsDiskCache(fileURL: url, maxEntryCount: 9)
        let line = LyricLine(text: "bounded cache", startTime: 1, endTime: 2)

        for index in 0..<8 {
            cache.set(
                title: "Song \(index)",
                artist: "Artist",
                duration: TimeInterval(200 + index),
                album: "Album",
                source: "NetEase",
                lines: [line],
                matchedDurationDiff: 0.1
            )
        }

        XCTAssertLessThanOrEqual(cache.entryCountForTesting(), 9)
        XCTAssertNil(cache.get(title: "Song 0", artist: "Artist", duration: 200, album: "Album"))
        XCTAssertNotNil(cache.get(title: "Song 7", artist: "Artist", duration: 207, album: "Album"))

        let reloaded = LyricsDiskCache(fileURL: url, maxEntryCount: 9)
        XCTAssertLessThanOrEqual(reloaded.entryCountForTesting(), 9)
        XCTAssertNil(reloaded.get(title: "Song 0", artist: "Artist", duration: 200, album: "Album"))
        XCTAssertNotNil(reloaded.get(title: "Song 7", artist: "Artist", duration: 207, album: "Album"))
    }

    func testLyricLinesRepairMergedLatinContractionTokensFromCache() {
        let cached = [
            CachedLyricLine(
                text: "STARDUST NIGHTIT'S SO LIGHT",
                startTime: 204.42,
                endTime: 210.65,
                words: [
                    CachedLyricWord(word: "STARDUST ", startTime: 204.42, endTime: 205.64),
                    CachedLyricWord(word: "NIGHTIT'S ", startTime: 205.64, endTime: 208.64),
                    CachedLyricWord(word: "SO ", startTime: 209.73, endTime: 210.21),
                    CachedLyricWord(word: "LIGHT", startTime: 210.21, endTime: 210.65),
                ],
                translation: "这流光四溢的星尘之夜啊"
            )
        ]

        let repaired = LyricsDiskCache.lyricLines(from: cached)

        XCTAssertEqual(repaired.count, 1)
        XCTAssertEqual(repaired[0].text, "STARDUST NIGHT IT'S SO LIGHT")
        XCTAssertEqual(
            repaired[0].words.map(\.word),
            ["STARDUST ", "NIGHT ", "IT'S ", "SO ", "LIGHT"]
        )
        XCTAssertEqual(repaired[0].translation, "这流光四溢的星尘之夜啊")
    }
}
