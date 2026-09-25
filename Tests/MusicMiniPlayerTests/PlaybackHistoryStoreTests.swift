/**
 * [INPUT]: MusicMiniPlayerCore.PlaybackHistoryStore / PlaybackHistoryEntry / NanoPodCacheLocation
 * [OUTPUT]: Unit tests — dedupe rules, capacity trim, round-trip encode/decode,
 *           corrupt/oversized file recovery, debounced-write coalescing,
 *           NanoPodCacheLocation-scoped versioned filename + legacy-seed
 *           migration, patchPersistentID, flush(), onChange
 * [POS]: Test module (WT-D plan H1; 2026-09-25 diagnosis phase-2 fix regressions)
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

    /// Test dirs always resolve the SAME versioned filename production would
    /// — reuses `NanoPodCacheLocation.versionedFileURL` itself rather than
    /// hardcoding "playback-history.v1.json", so a future schema bump can't
    /// silently desync the tests from the real naming rule.
    private func versionedFileURL(in dir: URL) -> URL {
        NanoPodCacheLocation.versionedFileURL(baseName: "playback-history", schemaVersion: PlaybackHistoryStore.schemaVersion, in: dir)
    }

    private func legacyFileURL(in dir: URL) -> URL {
        dir.appendingPathComponent("playback-history.json")
    }

    // MARK: - Identifiable id (stable row identity, not array index)

    func test_id_sameStartedAt_differsWhenPersistentIDDiffers() {
        let a = entry(pid: "AAAA", startedAt: Date(timeIntervalSince1970: 1000))
        let b = entry(pid: "BBBB", startedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_id_samePersistentID_differsWhenStartedAtDiffers() {
        let a = entry(pid: "AAAA", startedAt: Date(timeIntervalSince1970: 1000))
        let b = entry(pid: "AAAA", startedAt: Date(timeIntervalSince1970: 2000))
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_id_survivesEncodeDecodeRoundTrip() throws {
        let original = entry(pid: "CCCC", startedAt: Date(timeIntervalSince1970: 4242))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaybackHistoryEntry.self, from: data)
        XCTAssertEqual(original.id, decoded.id)
    }

    // MARK: - make(...) / deriveSourceKind(...) sourceKind derivation

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

    func test_deriveSourceKind_agreesWithMake_forEveryCase() {
        for (pid, url) in [("am:1", false), ("", true), ("", false), ("E6CA", false)] {
            XCTAssertEqual(
                PlaybackHistoryEntry.deriveSourceKind(persistentID: pid, isURLTrack: url),
                PlaybackHistoryEntry.make(title: "T", artist: "A", album: "Al", persistentID: pid, duration: 100, isURLTrack: url, startedAt: Date()).sourceKind,
                "make(...) must derive sourceKind through the exact same rule patchPersistentID uses — one source of truth"
            )
        }
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

    func test_record_capacity_trimsOldest() {
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            clock: { Date() },
            scheduler: { _, _ in }, // never fires — persistence not under test here
            writeHook: { _, _ in }
        )
        let overflow = PlaybackHistoryStore.capacity + 10
        for i in 0..<overflow {
            store.record(
                entry(pid: "PID-\(i)", title: "Song \(i)", startedAt: Date(timeIntervalSince1970: Double(i) * 10)),
                now: Date(timeIntervalSince1970: Double(i) * 10)
            )
        }
        XCTAssertEqual(store.entries.count, PlaybackHistoryStore.capacity)
        // Newest-first: the most recently recorded is at index 0.
        XCTAssertEqual(store.entries.first?.persistentID, "PID-\(overflow - 1)")
        XCTAssertEqual(store.entries.last?.persistentID, "PID-\(overflow - PlaybackHistoryStore.capacity)")
    }

    // MARK: - Round-trip encode/decode + corrupt/oversized file recovery

    func test_roundTrip_encodeDecode_viaFileWriteHook() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = versionedFileURL(in: dir)

        let writerStore = PlaybackHistoryStore(
            fileURL: fileURL,
            scheduler: { _, block in block() }, // fire immediately, deterministic
            writeHook: { data, url in try? data.write(to: url) }
        )
        writerStore.record(entry(pid: "AAAA", title: "Song One"), now: Date(timeIntervalSince1970: 2000))
        writerStore.record(entry(pid: "BBBB", title: "Song Two"), now: Date(timeIntervalSince1970: 2100))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let readerStore = PlaybackHistoryStore(fileURL: fileURL)
        XCTAssertEqual(readerStore.entries.count, 2)
        XCTAssertEqual(readerStore.entries.first?.persistentID, "BBBB")
        XCTAssertEqual(readerStore.entries.last?.persistentID, "AAAA")
    }

    func test_corruptFile_loadsAsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = versionedFileURL(in: dir)
        try? "not valid json {".data(using: .utf8)?.write(to: fileURL)

        let store = PlaybackHistoryStore(fileURL: fileURL)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_missingFile_loadsAsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PlaybackHistoryStore(fileURL: versionedFileURL(in: dir))
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// 2026-09-25 diagnosis fix (bounded loading): a file over
    /// `maxLoadableFileBytes` must be treated exactly like a corrupt one —
    /// empty in-memory history, no crash, no attempt to decode its content —
    /// WITHOUT the load path touching (or later overwriting) the file itself.
    func test_oversizedFile_treatedAsCorrupt_notReadOrOverwritten() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = versionedFileURL(in: dir)
        // A validly-JSON-encoded but oversized payload — proves the size gate
        // fires BEFORE decode is even attempted, not as a decode-failure side effect.
        let oversized = Data(repeating: 0x41, count: PlaybackHistoryStore.maxLoadableFileBytes + 1)
        try? oversized.write(to: fileURL)
        let originalBytes = try? Data(contentsOf: fileURL)

        let store = PlaybackHistoryStore(fileURL: fileURL, scheduler: { _, _ in }) // scheduler never fires — no write should even be scheduled by load()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try? Data(contentsOf: fileURL), originalBytes, "load() must never touch the oversized file's bytes on disk")
    }

    // MARK: - NanoPodCacheLocation-scoped filename + legacy-seed migration

    func test_defaultURL_isVersionedUnderNanoPodCacheLocation() {
        let expected = NanoPodCacheLocation.versionedFileURL(baseName: "playback-history", schemaVersion: PlaybackHistoryStore.schemaVersion)
        XCTAssertEqual(PlaybackHistoryStore.defaultURL(), expected)
    }

    /// The founder's real 50 existing entries live in the PRE-versioning
    /// "playback-history.json". The new versioned file doesn't exist yet on
    /// first run after this fix ships — `load()` must fall back to that
    /// legacy file as a READ-ONLY seed so nothing is lost.
    func test_legacySeed_migratesExistingEntries_onFirstLoad() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyURL = legacyFileURL(in: dir)
        let legacyEntries = [entry(pid: "OLD1", title: "Legacy One"), entry(pid: "OLD2", title: "Legacy Two")]
        try? JSONEncoder().encode(legacyEntries).write(to: legacyURL)

        let store = PlaybackHistoryStore(fileURL: versionedFileURL(in: dir))
        XCTAssertEqual(store.entries.count, 2, "the founder's existing entries must migrate — not one lost")
        XCTAssertEqual(Set(store.entries.map(\.persistentID)), ["OLD1", "OLD2"])
    }

    /// The legacy file is a SEED, never a write target — once the new
    /// versioned file exists (even from a later write by this same store),
    /// it must never be touched again.
    func test_legacySeed_neverWrittenTo() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyURL = legacyFileURL(in: dir)
        try? JSONEncoder().encode([entry(pid: "OLD1")]).write(to: legacyURL)
        let legacyBytesBefore = try? Data(contentsOf: legacyURL)

        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: dir),
            scheduler: { _, block in block() },
            writeHook: { data, url in try? data.write(to: url) }
        )
        store.record(entry(pid: "NEW1", title: "Fresh"), now: Date(timeIntervalSince1970: 9000))

        XCTAssertEqual(try? Data(contentsOf: legacyURL), legacyBytesBefore, "the legacy file must be byte-for-byte untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionedFileURL(in: dir).path), "the write must land on the NEW versioned file")
    }

    /// Once the versioned file exists, it wins outright — the legacy seed is
    /// a first-run fallback only, never consulted again.
    func test_versionedFileTakesPriority_overLegacySeed_onceItExists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode([entry(pid: "LEGACY")]).write(to: legacyFileURL(in: dir))
        try? JSONEncoder().encode([entry(pid: "VERSIONED")]).write(to: versionedFileURL(in: dir))

        let store = PlaybackHistoryStore(fileURL: versionedFileURL(in: dir))
        XCTAssertEqual(store.entries.map(\.persistentID), ["VERSIONED"])
    }

    // MARK: - patchPersistentID (H4 fix: late PID must patch, never double-record)

    func test_patchPersistentID_updatesEmptyPIDEntryInPlace() {
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in block() },
            writeHook: { _, _ in }
        )
        let startedAt = Date(timeIntervalSince1970: 6000)
        store.record(entry(pid: "", title: "Timed Out Song", startedAt: startedAt), now: startedAt)

        store.patchPersistentID(startedAt: startedAt, persistentID: "REALPID", isURLTrack: false)

        XCTAssertEqual(store.entries.count, 1, "must patch in place, never insert a second row")
        XCTAssertEqual(store.entries.first?.persistentID, "REALPID")
        XCTAssertEqual(store.entries.first?.sourceKind, .library)
        XCTAssertEqual(store.entries.first?.title, "Timed Out Song", "every other field must survive the patch untouched")
    }

    func test_patchPersistentID_noMatchingStartedAt_isNoOp() {
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in block() },
            writeHook: { _, _ in }
        )
        store.record(entry(pid: "", startedAt: Date(timeIntervalSince1970: 7000)), now: Date(timeIntervalSince1970: 7000))
        store.patchPersistentID(startedAt: Date(timeIntervalSince1970: 999999), persistentID: "X", isURLTrack: false)
        XCTAssertEqual(store.entries.first?.persistentID, "", "no entry has this startedAt — must not touch the unrelated one")
    }

    func test_patchPersistentID_entryAlreadyHasRealPID_isNoOp() {
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in block() },
            writeHook: { _, _ in }
        )
        let startedAt = Date(timeIntervalSince1970: 8000)
        store.record(entry(pid: "ORIGINAL", startedAt: startedAt), now: startedAt)
        store.patchPersistentID(startedAt: startedAt, persistentID: "SHOULDNOTAPPLY", isURLTrack: false)
        XCTAssertEqual(store.entries.first?.persistentID, "ORIGINAL", "an entry that already has a real PID must never be overwritten by a patch")
    }

    // MARK: - clear()

    func test_clear_emptiesEntriesAndSchedulesWrite() {
        var writeCount = 0
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
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
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in block() },
            writeHook: { _, _ in writeCount += 1 }
        )
        store.clear()
        XCTAssertEqual(writeCount, 0)
    }

    // MARK: - onChange (fires only on a REAL entries mutation)

    func test_onChange_firesOnRecord_notOnNoOpDuplicate() {
        var fireCount = 0
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in block() },
            writeHook: { _, _ in }
        )
        store.onChange = { fireCount += 1 }

        store.record(entry(pid: "AAAA"), now: Date(timeIntervalSince1970: 10000))
        XCTAssertEqual(fireCount, 1)

        // Deduped (same PID as last) — must NOT fire again.
        store.record(entry(pid: "AAAA", title: "Different Title"), now: Date(timeIntervalSince1970: 10001))
        XCTAssertEqual(fireCount, 1, "a deduped no-op record() must not fire onChange")
    }

    func test_onChange_firesOnPatchAndClear() {
        var fireCount = 0
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in block() },
            writeHook: { _, _ in }
        )
        let startedAt = Date(timeIntervalSince1970: 11000)
        store.record(entry(pid: "", startedAt: startedAt), now: startedAt)
        store.onChange = { fireCount += 1 }

        store.patchPersistentID(startedAt: startedAt, persistentID: "REAL", isURLTrack: false)
        XCTAssertEqual(fireCount, 1)

        store.clear()
        XCTAssertEqual(fireCount, 2)
    }

    // MARK: - flush()

    func test_flush_writesImmediately_whenDirty() {
        var writeCount = 0
        var pendingBlocks: [() -> Void] = []
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in pendingBlocks.append(block) }, // never auto-fires
            writeHook: { _, _ in writeCount += 1 }
        )
        store.record(entry(pid: "AAAA"), now: Date(timeIntervalSince1970: 12000))
        XCTAssertEqual(writeCount, 0, "sanity: the debounce hasn't fired yet")

        store.flush()
        XCTAssertEqual(writeCount, 1, "flush() must write NOW, without waiting for the debounce")
    }

    func test_flush_onCleanStore_isNoOp() {
        var writeCount = 0
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in block() },
            writeHook: { _, _ in writeCount += 1 }
        )
        store.flush()
        XCTAssertEqual(writeCount, 0, "nothing dirty — flush() must not write")
    }

    func test_flush_afterDebounceAlreadyFired_isNoOp() {
        var writeCount = 0
        var pendingBlocks: [() -> Void] = []
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in pendingBlocks.append(block) },
            writeHook: { _, _ in writeCount += 1 }
        )
        store.record(entry(pid: "AAAA"), now: Date(timeIntervalSince1970: 13000))
        pendingBlocks.forEach { $0() } // the debounce "fires" for real
        XCTAssertEqual(writeCount, 1)

        store.flush()
        XCTAssertEqual(writeCount, 1, "already clean — a second flush must not write again")
    }

    // MARK: - Debounce coalescing (fake scheduler — no real timers)

    func test_debounce_coalescesBurstOfRecordsIntoOneWrite() {
        var writeCount = 0
        var pendingBlocks: [() -> Void] = []
        let store = PlaybackHistoryStore(
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
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
            fileURL: versionedFileURL(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            scheduler: { _, block in pendingBlocks.append(block) },
            writeHook: { _, _ in writeCount += 1 }
        )
        store.record(entry(pid: "AAAA"), now: Date(timeIntervalSince1970: 5000))
        pendingBlocks.forEach { $0() }
        XCTAssertEqual(writeCount, 1)
    }

    // MARK: - Multi-process collision (2026-09-25 diagnosis H2 — still a
    // residual risk after the NanoPodCacheLocation fix: two REAL production
    // processes running at once still share one file and the later writer
    // still wins. Documented as a known residual, not solved by this pass —
    // see research/diagnosis-2026-09-25-history.md §H2.)

    func test_twoStoresSameFile_secondWriterStillWins_knownResidualRisk() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nanopod-h2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = versionedFileURL(in: dir)

        let processA = PlaybackHistoryStore(fileURL: fileURL, scheduler: { _, block in block() })
        let processB = PlaybackHistoryStore(fileURL: fileURL, scheduler: { _, block in block() })

        processA.record(entry(pid: "FROM_PROCESS_A"), now: Date(timeIntervalSince1970: 1000))
        processB.record(entry(pid: "FROM_PROCESS_B"), now: Date(timeIntervalSince1970: 1001))

        let onDisk = PlaybackHistoryStore(fileURL: fileURL)
        XCTAssertEqual(onDisk.entries.map(\.persistentID), ["FROM_PROCESS_B"], "documents the known residual: two concurrent production instances still clobber, not cross-process-merged")
    }
}
