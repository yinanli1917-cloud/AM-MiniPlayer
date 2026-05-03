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
}
