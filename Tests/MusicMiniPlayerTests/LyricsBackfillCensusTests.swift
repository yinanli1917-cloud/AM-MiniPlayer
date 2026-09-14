/**
 * [INPUT]: LyricsBackfillCensus (classifiers) + LyricsBackfillCensusWriter (JSONL sink)
 * [OUTPUT]: Unit tests for the A4 data-collection probe (2026-09-11)
 * [POS]: Test module. Pins: outcome classification table (including the
 *        rejected-no-demotion and upgraded-line-to-word cases), the writer's
 *        kill switch / size cap / one-line-per-fetch invariant, and that it
 *        never targets /tmp.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class LyricsBackfillCensusTests: XCTestCase {

    // MARK: - classifyForegroundHitOutcome

    func test_foregroundHit_syncedWithWordLevel_isHitWord() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyForegroundHitOutcome(kind: .synced, hasWordLevel: true),
            .hitWord
        )
    }

    func test_foregroundHit_syncedWithoutWordLevel_isHitLine() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyForegroundHitOutcome(kind: .synced, hasWordLevel: false),
            .hitLine
        )
    }

    func test_foregroundHit_unsynced_isHitUnsynced() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyForegroundHitOutcome(kind: .unsynced, hasWordLevel: false),
            .hitUnsynced
        )
    }

    func test_foregroundHit_instrumental_isInstrumental() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyForegroundHitOutcome(kind: .instrumental, hasWordLevel: false),
            .instrumental
        )
    }

    func test_foregroundHit_unavailable_isMiss() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyForegroundHitOutcome(kind: .unavailable, hasWordLevel: false),
            .miss
        )
    }

    // MARK: - classifyBackfillOutcome

    func test_backfill_notLaunched_isNone() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyBackfillOutcome(
                launched: false, cancelled: false, fetchFoundLyrics: false, applyVerdict: nil
            ),
            .none
        )
    }

    func test_backfill_cancelledBeforeFetch_isCancelled() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyBackfillOutcome(
                launched: true, cancelled: true, fetchFoundLyrics: false, applyVerdict: nil
            ),
            .cancelled
        )
    }

    func test_backfill_foundNothing_isMiss() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyBackfillOutcome(
                launched: true, cancelled: false, fetchFoundLyrics: false, applyVerdict: nil
            ),
            .miss
        )
    }

    func test_backfill_foundLyricsButSongChangedBeforeApply_isCancelled() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyBackfillOutcome(
                launched: true, cancelled: false, fetchFoundLyrics: true, applyVerdict: .notCurrent
            ),
            .cancelled
        )
    }

    func test_backfill_rejectedByNoDemotionGate_isHitRejectedNoDemotion() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyBackfillOutcome(
                launched: true, cancelled: false, fetchFoundLyrics: true, applyVerdict: .rejectedNoDemotion
            ),
            .hitRejectedNoDemotion
        )
    }

    func test_backfill_appliedWithoutUpgrade_isHitApplied() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyBackfillOutcome(
                launched: true, cancelled: false, fetchFoundLyrics: true,
                applyVerdict: .replaced(upgradedLineToWord: false)
            ),
            .hitApplied
        )
    }

    func test_backfill_appliedWithUpgrade_isUpgradedLineToWord() {
        XCTAssertEqual(
            LyricsBackfillCensus.classifyBackfillOutcome(
                launched: true, cancelled: false, fetchFoundLyrics: true,
                applyVerdict: .replaced(upgradedLineToWord: true)
            ),
            .upgradedLineToWord
        )
    }

    // MARK: - Writer

    private func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsBackfillCensusTests-\(UUID().uuidString)", isDirectory: true)
        return dir.appendingPathComponent("lyrics-backfill-census.jsonl")
    }

    private func makeRecord(fetchID: String = "song#1") -> LyricsBackfillCensus.Record {
        LyricsBackfillCensus.Record(
            title: "Test Song",
            artist: "Test Artist",
            duration: 200,
            foregroundOutcome: .hitWord,
            foregroundMs: 1200,
            foregroundSource: "amll",
            backfillLaunched: false,
            backfillOutcome: .none,
            backfillMs: nil,
            backfillSource: nil,
            kind: "synced"
        )
    }

    private func readLines(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func test_writer_appendsOneValidJSONLineOnSettle() {
        let url = makeTempURL()
        let writer = LyricsBackfillCensusWriter(fileURL: url, isEnabledOverride: { true })
        writer.record(makeRecord(), fetchID: "song#1")
        writer.record(makeRecord(fetchID: "song#2"), fetchID: "song#2")
        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        let lines = readLines(url)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let data = Data(line.utf8)
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(obj)
            XCTAssertEqual(obj?["foregroundOutcome"] as? String, "hit-word")
        }
    }

    func test_writer_killSwitch_suppressesWrites() {
        let url = makeTempURL()
        let writer = LyricsBackfillCensusWriter(fileURL: url, isEnabledOverride: { false })
        writer.record(makeRecord(), fetchID: "song#1")
        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_writer_oneLinePerFetchID_secondSettleForSameFetchIsNoOp() {
        let url = makeTempURL()
        let writer = LyricsBackfillCensusWriter(fileURL: url, isEnabledOverride: { true })
        writer.record(makeRecord(), fetchID: "song#1")
        writer.record(makeRecord(), fetchID: "song#1")
        writer.record(makeRecord(), fetchID: "song#1")
        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(readLines(url).count, 1)
    }

    func test_writer_neverTargetsSlashTmp() {
        let defaultURL = LyricsBackfillCensusWriter.defaultFileURL()
        XCTAssertFalse(defaultURL.path.hasPrefix("/tmp"))
        XCTAssertTrue(defaultURL.path.contains("Application Support"))
        XCTAssertTrue(defaultURL.path.contains("nanoPod"))
        XCTAssertEqual(defaultURL.lastPathComponent, "lyrics-backfill-census.jsonl")
    }

    func test_writer_rotatesWhenOverSizeCap() {
        let url = makeTempURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Seed a file already over the cap.
        let oversized = Data(repeating: 0x41, count: Int(LyricsBackfillCensus.maxFileSizeBytes) + 1024)
        try? oversized.write(to: url)

        let writer = LyricsBackfillCensusWriter(fileURL: url, isEnabledOverride: { true })
        writer.record(makeRecord(), fetchID: "song#1")
        let expectation = XCTestExpectation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return XCTFail("expected rotated file to exist")
        }
        XCTAssertLessThan(size, UInt64(oversized.count))
        XCTAssertEqual(readLines(url).count, 1)
    }
}
