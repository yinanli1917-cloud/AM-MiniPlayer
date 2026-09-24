import XCTest
@testable import MusicMiniPlayerCore

/// Cached claims must carry the evidence that admitted them (review #2,
/// postmortem 006): the metadata cache stores the REAL measured durationDiff
/// at write time and replay returns it unchanged — never a fabricated 0 that
/// would let poisoned rows bypass the duration-keyed guard for 30 days.
final class MetadataDiskCacheTests: XCTestCase {

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    func testReplayReturnsRealDurationDiffNotFabricatedZero() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())

        cache.set(
            title: "Er Shi Sui De Lang Man",
            artist: "Lan Xin Mei",
            duration: 252,
            resolvedTitle: "二十岁的浪漫",
            resolvedArtist: "蓝心湄",
            region: "CN",
            durationDiff: 0.5
        )

        let entry = cache.get(title: "Er Shi Sui De Lang Man", artist: "Lan Xin Mei", duration: 252)
        XCTAssertEqual(entry?.durationDiff, 0.5)
        XCTAssertNotEqual(entry?.durationDiff, 0, "replay must not fake a perfect duration match")
    }

    func testDurationDiffSurvivesDiskReload() {
        let url = temporaryFileURL()

        let writer = MetadataDiskCache(fileURL: url)
        writer.set(
            title: "Plastic Love",
            artist: "Mariya Takeuchi",
            duration: 293,
            resolvedTitle: "プラスティック・ラヴ",
            resolvedArtist: "竹内まりや",
            region: "JP",
            durationDiff: 0.42
        )

        // Persist is debounced — force the pending write before reloading.
        writer.flush()

        // Fresh instance at the same URL exercises the full Codable
        // round-trip — the value the guard reads on a cold start.
        let reader = MetadataDiskCache(fileURL: url)
        let entry = reader.get(title: "Plastic Love", artist: "Mariya Takeuchi", duration: 293)
        XCTAssertEqual(entry?.durationDiff, 0.42)
    }

    func testSchemaBumpFlushesRowsWithoutEvidence() throws {
        let url = temporaryFileURL()

        // Hand-written v4 envelope: rows from the pre-evidence schema, whose
        // durationDiff used to be fabricated as 0 on replay. The loader must
        // treat the whole file as empty so those rows are flushed once.
        let key = MetadataDiskCache.cacheKey(title: "Song", artist: "Artist", duration: 200)
        let v4JSON = """
        {
          "version": 4,
          "entries": {
            "\(key)": {
              "resolved_title": "二十岁的浪漫",
              "resolved_artist": "蓝心湄",
              "region": "CN",
              "ts": \(Date().timeIntervalSince1970),
              "source": "metadata-cache-v1"
            }
          }
        }
        """
        try XCTUnwrap(v4JSON.data(using: .utf8)).write(to: url)

        let cache = MetadataDiskCache(fileURL: url)
        XCTAssertNil(
            cache.get(title: "Song", artist: "Artist", duration: 200),
            "v4 rows carry no admission evidence and must be flushed by the schema bump"
        )
    }

    /// The debounced-persist timer promotes `[weak self]` to a strong
    /// reference on the cache's own serial queue. If the caller drops its
    /// last reference while that closure runs, the instance deallocates on
    /// that queue; a deinit that `queue.sync`s back onto it traps (SIGTRAP,
    /// "dispatch_sync called on queue already owned by current thread").
    /// A trap kills the process, so reaching the end is the pass signal.
    func testLastReleaseInsideOwnQueueClosureDoesNotTrap() {
        var urls: [URL] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        for iteration in 0..<300 {
            let url = temporaryFileURL()
            urls.append(url)
            var cache: MetadataDiskCache? = MetadataDiskCache(fileURL: url, persistDebounce: 0)
            for row in 0..<20 {
                cache?.set(title: "Song \(row)", artist: "Artist", duration: 200,
                           resolvedTitle: "歌 \(row)", resolvedArtist: "歌手",
                           region: "CN", durationDiff: 0.1)
            }
            usleep(useconds_t(iteration % 7) * 40)
            cache = nil
        }

        let settle = expectation(description: "queued closures drain")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        let written = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        XCTAssertEqual(written, urls.count, "sync sets are dirty before release; every instance must persist")
    }
}
