import XCTest
@testable import MusicMiniPlayerCore

final class LyricsCachePolicyTests: XCTestCase {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsCachePolicyTests-\(UUID().uuidString)-\(name)")
    }

    func testNetworkOnlyBypassesLyricAndMetadataReadsAndWrites() {
        let lyricsURL = temporaryURL("lyrics.json")
        let metadataURL = temporaryURL("metadata.json")
        let lyricsCache = LyricsDiskCache(fileURL: lyricsURL)
        let metadataCache = MetadataDiskCache(fileURL: metadataURL, persistDebounce: 0)
        let lines = [LyricLine(text: "fresh lyric", startTime: 1, endTime: 2)]

        lyricsCache.set(
            title: "Song", artist: "Artist", duration: 120,
            source: "LRCLIB", lines: lines, matchedDurationDiff: 0
        )
        metadataCache.set(
            title: "Song", artist: "Artist", duration: 120,
            resolvedTitle: "本地标题", resolvedArtist: "Artist", region: "CN", durationDiff: 0.2
        )
        metadataCache.flush()
        let lyricsBefore = try? Data(contentsOf: lyricsURL)
        let metadataBefore = try? Data(contentsOf: metadataURL)

        let diagnostics = LyricsCacheDiagnostics()
        let policy = LyricsCachePolicy.networkOnly(diagnostics: diagnostics)

        XCTAssertNil(lyricsCache.get(title: "Song", artist: "Artist", duration: 120, policy: policy))
        XCTAssertNil(metadataCache.get(title: "Song", artist: "Artist", duration: 120, policy: policy))
        lyricsCache.set(
            title: "Song", artist: "Artist", duration: 120,
            source: "LRCLIB", lines: lines, matchedDurationDiff: 0, policy: policy
        )
        metadataCache.set(
            title: "Song", artist: "Artist", duration: 120,
            resolvedTitle: "不要写入", resolvedArtist: "Artist", region: "CN", durationDiff: 0.1,
            policy: policy
        )
        metadataCache.flush()

        XCTAssertEqual(try? Data(contentsOf: lyricsURL), lyricsBefore)
        XCTAssertEqual(try? Data(contentsOf: metadataURL), metadataBefore)
        let snapshot = diagnostics.snapshot(mode: .networkOnly)
        XCTAssertGreaterThanOrEqual(snapshot.lyricReadBypasses, 1)
        XCTAssertGreaterThanOrEqual(snapshot.lyricWriteBypasses, 1)
        XCTAssertGreaterThanOrEqual(snapshot.metadataReadBypasses, 1)
        XCTAssertGreaterThanOrEqual(snapshot.metadataWriteBypasses, 1)
    }

    func testNormalPolicyPreservesExistingCacheBehavior() {
        let lyricsCache = LyricsDiskCache(fileURL: temporaryURL("lyrics.json"))
        let metadataCache = MetadataDiskCache(fileURL: temporaryURL("metadata.json"), persistDebounce: 0)
        let lines = [LyricLine(text: "normal lyric", startTime: 1, endTime: 2)]

        lyricsCache.set(
            title: "Song", artist: "Artist", duration: 120,
            source: "LRCLIB", lines: lines, matchedDurationDiff: 0
        )
        metadataCache.set(
            title: "Song", artist: "Artist", duration: 120,
            resolvedTitle: "标题", resolvedArtist: "Artist", region: "CN", durationDiff: 0.2
        )

        XCTAssertEqual(lyricsCache.get(title: "Song", artist: "Artist", duration: 120)?.lines?.first?.text, "normal lyric")
        XCTAssertEqual(metadataCache.get(title: "Song", artist: "Artist", duration: 120)?.resolvedTitle, "标题")
    }
}
