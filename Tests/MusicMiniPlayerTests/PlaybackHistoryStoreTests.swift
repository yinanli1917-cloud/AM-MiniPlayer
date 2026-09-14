/**
 * [INPUT]: MusicMiniPlayerCore.PlaybackHistoryStore / PlaybackHistoryEntry
 * [OUTPUT]: Unit tests — dedupe rules, capacity trim, round-trip encode/decode,
 *           corrupt file recovery, debounced-write coalescing
 * [POS]: Test module (WT-D plan H1)
 */

import XCTest
@testable import MusicMiniPlayerCore

final class PlaybackHistoryStoreTests: XCTestCase {

    private func entry(
        pid: String = "AAAA",
        title: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        duration: TimeInterval = 200,
        sourceKind: PlaybackHistoryEntry.SourceKind = .library,
        startedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> PlaybackHistoryEntry {
        PlaybackHistoryEntry(
            persistentID: pid, title: title, artist: artist, album: album,
            duration: duration, sourceKind: sourceKind, startedAt: startedAt
        )
    }

    // MARK: - make(...) sourceKind derivation

    func test_make_amPrefixedPID_isAppleMusicCatalog() {
        let e = PlaybackHistoryEntry.make(
            title: "T", artist: "A", album: "Al", persistentID: "am:12345",
            duration: 180, isURLTrack: false, startedAt: Date()
        )
        XCTAssertEqual(e.sourceKind, .appleMusicCatalog)
    }

    func test_make_urlTrack_isRadioOrStream() {
        let e = PlaybackHistoryEntry.make(
            title: "T", artist: "A", album: "Al", persistentID: "",
            duration: 0, isURLTrack: true, startedAt: Date()
        )
        XCTAssertEqual(e.sourceKind, .radioOrStream)
    }

    func test_make_emptyPID_notURLTrack_isRadioOrStream() {
        let e = PlaybackHistoryEntry.make(
            title: "T", artist: "A", album: "Al", persistentID: "",
            duration: 180, isURLTrack: false, startedAt: Date()
        )
        XCTAssertEqual(e.sourceKind, .radioOrStream)
    }

    func test_make_libraryPID_isLibrary() {
        let e = PlaybackHistoryEntry.make(
            title: "T", artist: "A", album: "Al", persistentID: "E6CA87B2C0269A9C",
            duration: 180, isURLTrack: false, startedAt: Date()
        )
        XCTAssertEqual(e.sourceKind, .library)
    }

    // MARK: - shouldRecord dedupe rules

    func test_shouldRecord_noLastEntry_alwaysRecords() {
        XCTAssertTrue(PlaybackHistoryStore.shouldRecord(candidate: entry(), last: nil, now: Date()))
    }

    func test_shouldRecord_samePID_asLast_skipped() {
        let last = entry(pid: "AAAA", title: "Old")
        let candidate = entry(pid: "AAAA", title: "New")
        XCTAssertFalse(PlaybackHistoryStore.shouldRecord(candidate: candidate, last: last, now: Date(timeIntervalSince1970: 1001)))
    }

    func test_shouldRecord_differentPID_recorded() {
        let last = entry(pid: "AAAA")
        let candidate = entry(pid: "BBBB")
        XCTAssertTrue(PlaybackHistoryStore.shouldRecord(candidate: candidate, last: last, now: Date(timeIntervalSince1970: 1001)))
    }

    func test_shouldRecord_emptyPID_sameTitleArtist_within3s_skipped() {
        let last = entry(pid: "", title: "Radio Song", artist: "DJ", startedAt: Date(timeIntervalSince1970: 1000))
        let candidate = entry(pid: "", title: "Radio Song", artist: "DJ")
        XCTAssertFalse(PlaybackHistoryStore.shouldRecord(candidate: candidate, last: last, now: Date(timeIntervalSince1970: 1002.9)))
    }

    func test_shouldRecord_emptyPID_sameTitleArtist_after3s_recorded() {
        let last = entry(pid: "", title: "Radio Song", artist: "DJ", startedAt: Date(timeIntervalSince1970: 1000))
        let candidate = entry(pid: "", title: "Radio Song", artist: "DJ")
        XCTAssertTrue(PlaybackHistoryStore.shouldRecord(candidate: candidate, last: last, now: Date(timeIntervalSince1970: 1003.1)))
    }

    func test_shouldRecord_emptyPID_differentTitle_recordedImmediately() {
        let last = entry(pid: "", title: "Radio Song A", startedAt: Date(timeIntervalSince1970: 1000))
        let candidate = entry(pid: "", title: "Radio Song B")
        XCTAssertTrue(PlaybackHistoryStore.shouldRecord(candidate: candidate, last: last, now: Date(timeIntervalSince1970: 1000.5)))
    }

    // MARK: - record() capacity trim

    func test_record_capacity50_trimsOldest() {
        let store = PlaybackHistoryStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            clock: { Date() },
            scheduler: { _, _ in }, // never fires — persistence not under test here
            writeHook: { _, _ in }
        )
        for i in 0..<60 {
            store.record(
                entry(pid: "PID-\(i)", title: "Song \(i)", startedAt: Date(timeIntervalSince1970: Double(i) * 10)),
                now: Date(timeIntervalSince1970: Double(i) * 10)
            )
        }
        XCTAssertEqual(store.entries.count, PlaybackHistoryStore.capacity)
        // Newest-first: the most recently recorded (PID-59) is at index 0.
        XCTAssertEqual(store.entries.first?.persistentID, "PID-59")
        XCTAssertEqual(store.entries.last?.persistentID, "PID-10")
    }

    // MARK: - Round-trip encode/decode + corrupt file recovery

    func test_roundTrip_encodeDecode_viaFileWriteHook() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("playback-history.json")

        let writerStore = PlaybackHistoryStore(
            directory: dir,
            scheduler: { _, block in block() }, // fire immediately, deterministic
            writeHook: { data, url in try? data.write(to: url) }
        )
        writerStore.record(entry(pid: "AAAA", title: "Song One"), now: Date(timeIntervalSince1970: 2000))
        writerStore.record(entry(pid: "BBBB", title: "Song Two"), now: Date(timeIntervalSince1970: 2100))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let readerStore = PlaybackHistoryStore(directory: dir)
        XCTAssertEqual(readerStore.entries.count, 2)
        XCTAssertEqual(readerStore.entries.first?.persistentID, "BBBB")
        XCTAssertEqual(readerStore.entries.last?.persistentID, "AAAA")
    }

    func test_corruptFile_loadsAsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("playback-history.json")
        try? "not valid json {".data(using: .utf8)?.write(to: fileURL)

        let store = PlaybackHistoryStore(directory: dir)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_missingFile_loadsAsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PlaybackHistoryStore(directory: dir)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - clear()

    func test_clear_emptiesEntriesAndSchedulesWrite() {
        var writeCount = 0
        let store = PlaybackHistoryStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            scheduler: { _, block in block() },
            writeHook: { _, _ in writeCount += 1 }
        )
        store.record(entry(pid: "AAAA"), now: Date(timeIntervalSince1970: 3000))
        XCTAssertFalse(store.entries.isEmpty)
        let countBeforeClear = writeCount
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertGreaterThan(writeCount, countBeforeClear)
    }

    func test_clear_onEmptyStore_doesNotScheduleWrite() {
        var writeCount = 0
        let store = PlaybackHistoryStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            scheduler: { _, block in block() },
            writeHook: { _, _ in writeCount += 1 }
        )
        store.clear()
        XCTAssertEqual(writeCount, 0)
    }

    // MARK: - Debounce coalescing (fake scheduler — no real timers)

    func test_debounce_coalescesBurstOfRecordsIntoOneWrite() {
        var writeCount = 0
        var pendingBlocks: [() -> Void] = []
        let store = PlaybackHistoryStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            scheduler: { _, block in pendingBlocks.append(block) },
            writeHook: { _, _ in writeCount += 1 }
        )

        store.record(entry(pid: "AAAA", title: "One"), now: Date(timeIntervalSince1970: 4000))
        store.record(entry(pid: "BBBB", title: "Two"), now: Date(timeIntervalSince1970: 4001))
        store.record(entry(pid: "CCCC", title: "Three"), now: Date(timeIntervalSince1970: 4002))

        XCTAssertEqual(pendingBlocks.count, 3, "each record schedules a debounce slot")

        // Firing all three (as a real timer eventually would) must coalesce
        // to exactly one write — only the LAST scheduled generation performs it.
        pendingBlocks.forEach { $0() }
        XCTAssertEqual(writeCount, 1)
    }

    func test_debounce_singleRecord_singleWrite() {
        var writeCount = 0
        var pendingBlocks: [() -> Void] = []
        let store = PlaybackHistoryStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            scheduler: { _, block in pendingBlocks.append(block) },
            writeHook: { _, _ in writeCount += 1 }
        )
        store.record(entry(pid: "AAAA"), now: Date(timeIntervalSince1970: 5000))
        pendingBlocks.forEach { $0() }
        XCTAssertEqual(writeCount, 1)
    }
}
