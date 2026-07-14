import XCTest
@testable import MusicMiniPlayerCore

/// Tier separation (review #9): the CN resolver and the localized resolver
/// cache into DISJOINT stores. The dual-wave pinyin path resolves the SAME
/// `(title, artist, duration)` through both tiers — a single keyspace lets
/// each tier's write overwrite the other's row, so every replay refires the
/// other tier's full network wave. Each tier must replay only rows it
/// produced, and writes must coalesce instead of rewriting the file per set.
final class MetadataDiskCacheTierTests: XCTestCase {

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    // ------------------------------------------------------------------
    // MARK: - (a) Tier-overwrite impossibility
    // ------------------------------------------------------------------

    /// RED-phase history: encoded against the single-keyspace API (two
    /// `set` calls, then `entryCount == 2`) this failed with 1 — the TW
    /// write destroyed the CN row. Ported to the tier API below.
    func testCNTierAndLocalizedTierRowsSurviveIndependently() {
        let cache = MetadataDiskCache(fileURL: temporaryFileURL())

        // CN tier resolves the song first (dual-wave pinyin scenario)...
        cache.setChinese(
            title: "Er Shi Sui De Lang Man", artist: "Lan Xin Mei", duration: 252,
            resolvedTitle: "二十岁的浪漫", resolvedArtist: "蓝心湄",
            durationDiff: 0.5
        )
        // ...then the multi-region tier resolves the SAME song.
        cache.set(
            title: "Er Shi Sui De Lang Man", artist: "Lan Xin Mei", duration: 252,
            resolvedTitle: "二十歲的浪漫", resolvedArtist: "藍心湄",
            region: "TW", durationDiff: 0.8
        )

        // Both rows survive and each tier reads back ONLY its own row.
        let cn = cache.getChinese(title: "Er Shi Sui De Lang Man", artist: "Lan Xin Mei", duration: 252)
        XCTAssertEqual(cn?.resolvedTitle, "二十岁的浪漫")
        XCTAssertEqual(cn?.region, "CN")
        XCTAssertEqual(cn?.durationDiff, 0.5)

        let localized = cache.get(title: "Er Shi Sui De Lang Man", artist: "Lan Xin Mei", duration: 252)
        XCTAssertEqual(localized?.resolvedTitle, "二十歲的浪漫")
        XCTAssertEqual(localized?.region, "TW")
        XCTAssertEqual(localized?.durationDiff, 0.8)

        XCTAssertEqual(
            cache.entryCount, 2,
            "CN and localized rows for the same song must not overwrite each other"
        )
    }

    // ------------------------------------------------------------------
    // MARK: - (a2) Localized admission-evidence round-trip
    // ------------------------------------------------------------------

    /// Localized rows persist the evidence kind that admitted them so
    /// replay can trust the row without re-deriving script heuristics
    /// (English->CJK aliases were re-resolved from network every session).
    func testLocalizedEvidenceKindRoundTripsAcrossReload() {
        let url = temporaryFileURL()
        let cache = MetadataDiskCache(fileURL: url)
        cache.set(
            title: "The Season In The Sun", artist: "TUBE", duration: 244,
            resolvedTitle: "シーズン・イン・ザ・サン", resolvedArtist: "TUBE",
            region: "JP", durationDiff: 0.05, evidence: "catalog-alias"
        )
        cache.flush()

        let reloaded = MetadataDiskCache(fileURL: url)
        let row = reloaded.get(title: "The Season In The Sun", artist: "TUBE", duration: 244)
        XCTAssertEqual(row?.evidence, "catalog-alias")

        // Writers that pass no evidence produce an unstamped (untrusted) row.
        cache.set(
            title: "Other Song", artist: "Artist", duration: 200,
            resolvedTitle: "他曲", resolvedArtist: "歌手",
            region: "TW", durationDiff: 0.2
        )
        XCTAssertNil(cache.get(title: "Other Song", artist: "Artist", duration: 200)?.evidence)
    }

    // ------------------------------------------------------------------
    // MARK: - (b) CN evidence tuple round-trip
    // ------------------------------------------------------------------

    func testChineseTierEvidenceTupleRoundTripsAcrossReload() {
        let url = temporaryFileURL()

        let writer = MetadataDiskCache(fileURL: url)
        writer.setChinese(
            title: "Er Shi Sui De Lang Man", artist: "Lan Xin Mei", duration: 252,
            resolvedTitle: "二十岁的浪漫", resolvedArtist: "蓝心湄",
            durationDiff: 0.5
        )
        writer.flush()

        // Fresh instance at the same URL exercises the full Codable
        // round-trip — the values the CN replay guards read on cold start.
        let reader = MetadataDiskCache(fileURL: url)
        let entry = reader.getChinese(title: "Er Shi Sui De Lang Man", artist: "Lan Xin Mei", duration: 252)
        XCTAssertEqual(entry?.resolvedTitle, "二十岁的浪漫")
        XCTAssertEqual(entry?.resolvedArtist, "蓝心湄")
        XCTAssertEqual(entry?.region, "CN")
        XCTAssertEqual(entry?.durationDiff, 0.5, "replay must carry the REAL measured admission evidence")

        // Cross-tier isolation also holds across reload: the localized
        // tier must not replay a row the CN tier produced.
        XCTAssertNil(reader.get(title: "Er Shi Sui De Lang Man", artist: "Lan Xin Mei", duration: 252))
    }

    // ------------------------------------------------------------------
    // MARK: - (c) Schema-mismatch flush
    // ------------------------------------------------------------------

    func testV5EnvelopeIsFlushedBySchemaBump() throws {
        let url = temporaryFileURL()
        let key = MetadataDiskCache.cacheKey(title: "Song", artist: "Artist", duration: 200)

        // Hand-written v5 envelope: one keyspace mixing both tiers plus the
        // dead preflightExact slot. The v6 loader must treat it as empty so
        // the cache self-heals (no migration code).
        let v5JSON = """
        {
          "version": 5,
          "entries": {
            "\(key)": {
              "resolved_title": "二十岁的浪漫",
              "resolved_artist": "蓝心湄",
              "region": "CN",
              "ts": \(Date().timeIntervalSince1970),
              "source": "metadata-cache-v1",
              "duration_diff": 0.5
            }
          },
          "preflightExact": {}
        }
        """
        try XCTUnwrap(v5JSON.data(using: .utf8)).write(to: url)

        let cache = MetadataDiskCache(fileURL: url)
        XCTAssertNil(
            cache.get(title: "Song", artist: "Artist", duration: 200),
            "v5 rows mixed both tiers in one keyspace and must be flushed once by the v6 bump"
        )
    }

    // ------------------------------------------------------------------
    // MARK: - (d) Debounced persist
    // ------------------------------------------------------------------

    #if DEBUG
    func testDebounceCoalescesRapidSetsIntoFewDiskWrites() {
        let url = temporaryFileURL()
        let cache = MetadataDiskCache(fileURL: url, persistDebounce: 0.25)

        // A burst of writes across both tiers — the old behavior rewrote
        // the whole file once per set (40 writes here).
        for i in 0..<20 {
            cache.set(
                title: "Song \(i)", artist: "Artist", duration: Double(200 + i),
                resolvedTitle: "歌 \(i)", resolvedArtist: "歌手",
                region: "JP", durationDiff: 0.1
            )
            cache.setChinese(
                title: "Song \(i)", artist: "Artist", duration: Double(200 + i),
                resolvedTitle: "歌曲 \(i)", resolvedArtist: "歌手",
                durationDiff: 0.2
            )
        }

        // Trailing-edge debounce: the burst finishes inside the window,
        // so nothing has hit the disk yet.
        XCTAssertEqual(cache.debugDiskWriteCount, 0, "writes inside the window must coalesce")

        let window = expectation(description: "debounce window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { window.fulfill() }
        wait(for: [window], timeout: 5.0)

        // One coalesced write (≤ 2 tolerates a scheduler hiccup splitting
        // the burst across two windows) — yet the disk state is COMPLETE.
        XCTAssertGreaterThanOrEqual(cache.debugDiskWriteCount, 1)
        XCTAssertLessThanOrEqual(cache.debugDiskWriteCount, 2)

        let reader = MetadataDiskCache(fileURL: url)
        for i in 0..<20 {
            XCTAssertEqual(
                reader.get(title: "Song \(i)", artist: "Artist", duration: Double(200 + i))?.resolvedTitle,
                "歌 \(i)"
            )
            XCTAssertEqual(
                reader.getChinese(title: "Song \(i)", artist: "Artist", duration: Double(200 + i))?.resolvedTitle,
                "歌曲 \(i)"
            )
        }
    }

    func testFlushWritesPendingStateImmediatelyAndIsIdempotent() {
        let url = temporaryFileURL()
        let cache = MetadataDiskCache(fileURL: url, persistDebounce: 60)

        cache.setChinese(
            title: "Song", artist: "Artist", duration: 200,
            resolvedTitle: "歌曲", resolvedArtist: "歌手", durationDiff: 0.3
        )
        cache.flush()
        XCTAssertEqual(cache.debugDiskWriteCount, 1, "flush must write pending state without waiting for the window")

        let reader = MetadataDiskCache(fileURL: url)
        XCTAssertEqual(reader.getChinese(title: "Song", artist: "Artist", duration: 200)?.resolvedTitle, "歌曲")

        // Nothing dirty → flush is a no-op, not another disk write.
        cache.flush()
        XCTAssertEqual(cache.debugDiskWriteCount, 1)
    }
    #endif
}
