import XCTest
@testable import MusicMiniPlayerCore

/// A2 follow-up: the retry button (`forceRefresh: true` into
/// `LyricsService.fetchLyrics`) bypasses+clears `LyricsMissMemo` (session
/// lyrics-miss memo) but, before this fix, left commit 6cef712's
/// metadata negative-evidence rows (`negative_entries` / `negative_cn_entries`
/// / `negative_album_entries`, 24h TTL) untouched — a retry within 24h of a
/// metadata miss still hit the negative short-circuit and skipped the
/// network search the user explicitly asked for.
///
/// `MetadataDiskCache.clearNegatives(title:artist:duration:album:)` is the
/// fix: it clears the localized, CN, and (when an album is known)
/// album-scoped negative rows for one song's keys. LyricsService calls it
/// from the forceRefresh path alongside the existing `missMemo.clear(...)`.
final class MetadataNegativeClearOnRefreshTests: XCTestCase {

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    // ------------------------------------------------------------------
    // MARK: - RED: clearNegatives removes rows across all tiers
    // ------------------------------------------------------------------

    func testClearNegativesRemovesLocalizedCNAndAlbumScopedRowsForTheKey() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        let title = "Dinner", artist = "Kay Huang", duration: TimeInterval = 259
        let album = "Some Album"

        cache.setNegative(title: title, artist: artist, duration: duration)
        cache.setNegativeChinese(title: title, artist: artist, duration: duration)
        cache.setNegativeAlbumScoped(title: title, artist: artist, duration: duration, album: album)

        XCTAssertTrue(cache.getNegative(title: title, artist: artist, duration: duration))
        XCTAssertTrue(cache.getNegativeChinese(title: title, artist: artist, duration: duration))
        XCTAssertTrue(cache.getNegativeAlbumScoped(title: title, artist: artist, duration: duration, album: album))

        cache.clearNegatives(title: title, artist: artist, duration: duration, album: album)

        XCTAssertFalse(cache.getNegative(title: title, artist: artist, duration: duration),
                        "retry within 24h must not be short-circuited by a stale localized negative row")
        XCTAssertFalse(cache.getNegativeChinese(title: title, artist: artist, duration: duration),
                        "retry within 24h must not be short-circuited by a stale CN negative row")
        XCTAssertFalse(cache.getNegativeAlbumScoped(title: title, artist: artist, duration: duration, album: album),
                        "retry within 24h must not be short-circuited by a stale album-scoped negative row")
    }

    /// Empty album means "no album context for this fetch" — clearNegatives
    /// must not derive an album-scoped key from an empty string and must
    /// leave a real album-scoped row (keyed under a DIFFERENT, non-empty
    /// album) untouched.
    func testClearNegativesWithEmptyAlbumSkipsAlbumScopedTierEntirely() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        let title = "Dinner", artist = "Kay Huang", duration: TimeInterval = 259
        let realAlbum = "Some Album"

        cache.setNegativeAlbumScoped(title: title, artist: artist, duration: duration, album: realAlbum)
        cache.clearNegatives(title: title, artist: artist, duration: duration, album: "")

        XCTAssertTrue(cache.getNegativeAlbumScoped(title: title, artist: artist, duration: duration, album: realAlbum),
                       "an unrelated fetch with no album context must not clear a real album-scoped negative row")
    }

    /// Positive rows for the SAME key must survive — clearNegatives only
    /// removes negative rows, it must never touch resolved metadata.
    func testClearNegativesLeavesPositiveRowsUntouched() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        let title = "Dinner", artist = "Kay Huang", duration: TimeInterval = 259

        cache.set(title: title, artist: artist, duration: duration,
                   resolvedTitle: "晚餐", resolvedArtist: "黄韵玲", region: "TW",
                   durationDiff: 0.2)
        cache.setNegative(title: title, artist: artist, duration: duration)

        cache.clearNegatives(title: title, artist: artist, duration: duration, album: "")

        XCTAssertNotNil(cache.get(title: title, artist: artist, duration: duration),
                         "clearNegatives must not remove a positive row for the same key")
    }

    // ------------------------------------------------------------------
    // MARK: - RED: individual per-tier clear helpers
    // ------------------------------------------------------------------

    func testClearNegativeRemovesOnlyLocalizedTierRow() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        let title = "Song", artist = "Artist", duration: TimeInterval = 200

        cache.setNegative(title: title, artist: artist, duration: duration)
        cache.setNegativeChinese(title: title, artist: artist, duration: duration)

        cache.clearNegative(title: title, artist: artist, duration: duration)

        XCTAssertFalse(cache.getNegative(title: title, artist: artist, duration: duration))
        XCTAssertTrue(cache.getNegativeChinese(title: title, artist: artist, duration: duration),
                       "clearNegative must be scoped to the localized tier only")
    }

    func testClearNegativeChineseRemovesOnlyCNTierRow() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())
        let title = "Song", artist = "Artist", duration: TimeInterval = 200

        cache.setNegative(title: title, artist: artist, duration: duration)
        cache.setNegativeChinese(title: title, artist: artist, duration: duration)

        cache.clearNegativeChinese(title: title, artist: artist, duration: duration)

        XCTAssertTrue(cache.getNegative(title: title, artist: artist, duration: duration),
                       "clearNegativeChinese must be scoped to the CN tier only")
        XCTAssertFalse(cache.getNegativeChinese(title: title, artist: artist, duration: duration))
    }
}
