/**
 * [INPUT]: MusicMiniPlayerCore.PendingPlaybackAccumulator / PendingPlaybackRules /
 *          PendingPlay / PlaybackHistoryStore / PlaybackHistoryEntry
 * [OUTPUT]: Unit tests — the "待定播放 → 达标入账" mechanism: pure listened-time
 *           math, qualification threshold (0 and 10s), pause-excluded timing,
 *           redundant re-detection dedup, the H3 rapid-double-skip regression,
 *           the H4 late-PID regression (both the still-pending and
 *           already-committed patch paths), app-quit flush, and a 100k-tick
 *           soak — all fake-clock-driven, zero real timers.
 * [POS]: Test module (2026-09-25 diagnosis phase-2 fix)
 */

import XCTest
@testable import MusicMiniPlayerCore

// ============================================================
// MARK: - PendingPlaybackRules (pure)
// ============================================================

final class PendingPlaybackRulesTests: XCTestCase {

    private func play(
        title: String = "Song", artist: String = "Artist", album: String = "Album",
        duration: TimeInterval = 200, persistentID: String = "PID",
        startedAt: Date = Date(timeIntervalSince1970: 1000),
        accumulated: TimeInterval = 0, segmentStart: Date? = nil
    ) -> PendingPlay {
        PendingPlay(
            title: title, artist: artist, album: album, duration: duration,
            persistentID: persistentID, isURLTrack: false, startedAt: startedAt,
            accumulatedPlayingSeconds: accumulated, playingSegmentStartedAt: segmentStart
        )
    }

    // MARK: totalListenedSeconds

    func test_totalListenedSeconds_noInProgressSegment_returnsAccumulatedOnly() {
        let p = play(accumulated: 7.5, segmentStart: nil)
        XCTAssertEqual(PendingPlaybackRules.totalListenedSeconds(p, at: Date(timeIntervalSince1970: 9999)), 7.5)
    }

    func test_totalListenedSeconds_inProgressSegment_addsElapsedSinceSegmentStart() {
        let p = play(accumulated: 3, segmentStart: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(PendingPlaybackRules.totalListenedSeconds(p, at: Date(timeIntervalSince1970: 1004.5)), 7.5)
    }

    func test_totalListenedSeconds_neverNegative_evenIfNowPrecedesSegmentStart() {
        let p = play(accumulated: 2, segmentStart: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(PendingPlaybackRules.totalListenedSeconds(p, at: Date(timeIntervalSince1970: 990)), 2, "a clock anomaly must not manufacture negative listened time")
    }

    // MARK: qualifiesForHistory

    func test_qualifies_zeroThreshold_alwaysTrue_evenWithNoListening() {
        XCTAssertTrue(PendingPlaybackRules.qualifiesForHistory(listenedSeconds: 0, duration: 200, minimumListenSeconds: 0), "0 = old behavior: every confirmed change qualifies immediately")
    }

    func test_qualifies_belowThreshold_false() {
        XCTAssertFalse(PendingPlaybackRules.qualifiesForHistory(listenedSeconds: 9.9, duration: 200, minimumListenSeconds: 10))
    }

    func test_qualifies_exactlyAtThreshold_true() {
        XCTAssertTrue(PendingPlaybackRules.qualifiesForHistory(listenedSeconds: 10.0, duration: 200, minimumListenSeconds: 10))
    }

    func test_qualifies_shortSong_naturalEnd_usesDurationInsteadOfFlatThreshold() {
        // An 8s song played in full (8s listened) must qualify even though
        // 8 < the 10s flat threshold — "播到自然结束（很短的曲子）".
        XCTAssertTrue(PendingPlaybackRules.qualifiesForHistory(listenedSeconds: 8, duration: 8, minimumListenSeconds: 10))
    }

    func test_qualifies_shortSong_notYetFullyPlayed_stillFalse() {
        XCTAssertFalse(PendingPlaybackRules.qualifiesForHistory(listenedSeconds: 5, duration: 8, minimumListenSeconds: 10))
    }

    func test_qualifies_unknownDuration_usesFlatThresholdOnly() {
        XCTAssertFalse(PendingPlaybackRules.qualifiesForHistory(listenedSeconds: 5, duration: 0, minimumListenSeconds: 10))
        XCTAssertTrue(PendingPlaybackRules.qualifiesForHistory(listenedSeconds: 10, duration: 0, minimumListenSeconds: 10))
    }

    func test_qualifies_longSong_neverLoweredByDuration() {
        // duration (240s) is LONGER than the threshold — effectiveThreshold
        // must stay at minimumListenSeconds, not balloon to the duration.
        XCTAssertTrue(PendingPlaybackRules.qualifiesForHistory(listenedSeconds: 10, duration: 240, minimumListenSeconds: 10))
    }

    // MARK: isSameSong

    func test_isSameSong_pidMatch_true_evenIfTitleDrifted() {
        let p = play(title: "Song (Remastered)", persistentID: "AAAA")
        XCTAssertTrue(PendingPlaybackRules.isSameSong(p, title: "Song", artist: "Artist", persistentID: "AAAA"))
    }

    func test_isSameSong_pidMismatch_false_evenIfTitleMatches() {
        let p = play(title: "Song", persistentID: "AAAA")
        XCTAssertFalse(PendingPlaybackRules.isSameSong(p, title: "Song", artist: "Artist", persistentID: "BBBB"))
    }

    func test_isSameSong_emptyPIDBothSides_fallsBackToTitleArtist() {
        let p = play(title: "Radio Song", artist: "DJ", persistentID: "")
        XCTAssertTrue(PendingPlaybackRules.isSameSong(p, title: "Radio Song", artist: "DJ", persistentID: ""))
        XCTAssertFalse(PendingPlaybackRules.isSameSong(p, title: "Other Song", artist: "DJ", persistentID: ""))
    }
}

// ============================================================
// MARK: - PendingPlaybackAccumulator (stateful, fake clock)
// ============================================================

final class PendingPlaybackAccumulatorTests: XCTestCase {

    private func makeStore(dir: URL) -> PlaybackHistoryStore {
        PlaybackHistoryStore(
            fileURL: NanoPodCacheLocation.versionedFileURL(baseName: "playback-history", schemaVersion: PlaybackHistoryStore.schemaVersion, in: dir),
            scheduler: { _, _ in }, // persistence not under test here
            writeHook: { _, _ in }
        )
    }

    private func freshDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    // MARK: - Basic commit at threshold, both configured values

    func test_threshold10_commitsExactlyOnceOnceCrossed() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 1000)

        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID", isURLTrack: false, isPlaying: true, now: t0)
        XCTAssertEqual(store.entries.count, 0, "must not commit immediately at a 10s threshold")

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.entries.count, 0)

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.entries.count, 1, "must commit the instant 10s of ACTUAL playing time is reached")

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(15))
        XCTAssertEqual(store.entries.count, 1, "must never commit the same play twice")
    }

    func test_threshold0_commitsImmediately_oldBehavior() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 0)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID", isURLTrack: false, isPlaying: true, now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.entries.count, 1, "0 = every confirmed change records immediately, matching the pre-fix behavior")
    }

    /// Explicit boundary the coordinator asked for: 9.9s must not qualify, 10.0s must.
    func test_boundary_9_9SecondsNotQualified_10_0SecondsQualified() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 3000)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID", isURLTrack: false, isPlaying: true, now: t0)

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(9.9))
        XCTAssertEqual(store.entries.count, 0, "9.9s must NOT qualify")

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(10.0))
        XCTAssertEqual(store.entries.count, 1, "10.0s MUST qualify")
    }

    // MARK: - Pause excluded from listened time

    func test_pause_doesNotAdvanceTowardThreshold() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 4000)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID", isURLTrack: false, isPlaying: true, now: t0)

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(5))     // 5s listened
        acc.tick(isPlaying: false, now: t0.addingTimeInterval(6))    // pause — rolls the 1s segment in, stops accumulating
        // 100 real seconds pass while PAUSED — must not count at all.
        acc.tick(isPlaying: false, now: t0.addingTimeInterval(106))
        XCTAssertEqual(store.entries.count, 0, "100s of wall-clock time spent PAUSED must not push a 6s-listened play over a 10s threshold")

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(106))   // resume
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(110))   // +4s listened = 10s total
        XCTAssertEqual(store.entries.count, 1, "6s (pre-pause) + 4s (post-resume) = 10s ACTUAL listened time must qualify")
    }

    // MARK: - Natural end of a short song

    func test_shortSong_naturalEnd_commitsEvenBelowFlatThreshold() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 5000)
        acc.beginPendingPlay(title: "Interlude", artist: "Artist", album: "Album", duration: 7, persistentID: "PID", isURLTrack: false, isPlaying: true, now: t0)

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(7))
        XCTAssertEqual(store.entries.count, 1, "a 7s track played to its own natural end must qualify even though 7 < the 10s threshold")
    }

    // MARK: - Redundant re-detection (real 2026-09-25 02:03:55 "Roses" capture)

    func test_redundantReDetection_sameSongStillTracked_doesNotRestartOrDoubleCommit() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 6000)
        acc.beginPendingPlay(title: "Roses", artist: "Mac Ayres", album: "Album", duration: 272.5, persistentID: "0CD71BE85BC5591D", isURLTrack: false, isPlaying: true, now: t0)
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(8))

        // The snapshot path re-confirms "Roses" (same PID) 17s after it began
        // — the real founder capture from the phase-1 diagnosis. Must NOT
        // reset progress toward the threshold, and must NOT itself count as
        // a second play beginning.
        acc.beginPendingPlay(title: "Roses", artist: "Mac Ayres", album: "Album", duration: 272.5, persistentID: "0CD71BE85BC5591D", isURLTrack: false, isPlaying: true, now: t0.addingTimeInterval(17))
        XCTAssertEqual(store.entries.count, 0, "still under 10s of real accumulated listening — a redundant re-detection must not fast-forward it to committed")

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(20))
        XCTAssertEqual(store.entries.count, 1, "the ONE continuous listen (now 20s in) qualifies exactly once")
    }

    func test_redundantReDetection_emptyPIDBothSides_matchedByTitleArtist() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 6500)
        acc.beginPendingPlay(title: "Radio Song", artist: "DJ", album: "", duration: 0, persistentID: "", isURLTrack: true, isPlaying: true, now: t0)
        acc.beginPendingPlay(title: "Radio Song", artist: "DJ", album: "", duration: 0, persistentID: "", isURLTrack: true, isPlaying: true, now: t0.addingTimeInterval(2))
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.entries.count, 1)
    }

    // MARK: - Under-threshold plays are discarded when superseded ("跳过 N 秒内的歌不计入")

    func test_underThresholdPlay_discardedWhenSuperseded_neverCommits() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 7000)
        acc.beginPendingPlay(title: "Quick Skip", artist: "Artist", album: "Album", duration: 200, persistentID: "SKIPPED", isURLTrack: false, isPlaying: true, now: t0)
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(2)) // only 2s listened

        acc.beginPendingPlay(title: "Next Song", artist: "Artist", album: "Album", duration: 200, persistentID: "NEXT", isURLTrack: false, isPlaying: true, now: t0.addingTimeInterval(2))

        XCTAssertTrue(store.entries.isEmpty, "the 2s-listened skip must never reach History")
        XCTAssertEqual(acc.current?.persistentID, "NEXT")
    }

    // MARK: - H3 regression: rapid double-skip must not lose a play that DID qualify

    /// Mirrors handleTrackChange's exact sequence (MusicController.swift):
    /// beginPendingPlay is called BEFORE the SB persistentID read; if that
    /// read discovers Music.app already moved to a different track (the "SB
    /// track mismatch" branch), the notification path bails — but the
    /// pending play was already open and ticking, so a play that genuinely
    /// crossed the threshold before being superseded is NOT lost.
    func test_h3_rapidDoubleSkip_playThatQualifiedBeforeSupersession_isNotLost() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 8000)

        // Notification for Track A — opened BEFORE any SB read, exactly like
        // handleTrackChange now does.
        acc.beginPendingPlay(title: "Track A", artist: "Artist", album: "Album", duration: 200, persistentID: "", isURLTrack: false, isPlaying: true, now: t0)
        // A genuinely plays for 12s (past the 10s threshold) before Music.app
        // moves on — the regular tick cadence catches the crossing.
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(12))
        XCTAssertEqual(store.entries.count, 1, "Track A crossed the threshold and must already be committed")

        // A's SB read (up to 1.5s) discovers Music.app already moved to B —
        // the notification path's mismatch guard bails WITHOUT calling
        // recordPlaybackHistory directly; the forced refresh's snapshot
        // eventually reports B.
        acc.beginPendingPlay(title: "Track B", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_B", isURLTrack: false, isPlaying: true, now: t0.addingTimeInterval(13))

        XCTAssertTrue(store.entries.contains(where: { $0.title == "Track A" }), "Track A's row must survive the mismatch race")
        XCTAssertEqual(store.entries.first?.persistentID, "", "Track A committed before its PID ever resolved — still a valid row, just PID-less until patched")
    }

    /// Same shape, but A is skipped WITHIN the threshold window — under the
    /// new semantics this is correctly discarded (not a regression: a <10s
    /// listen was never going to qualify even without any race).
    func test_h3_rapidDoubleSkip_underThresholdPlay_correctlyDiscarded_notALoss() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 8500)
        acc.beginPendingPlay(title: "Track A", artist: "Artist", album: "Album", duration: 200, persistentID: "", isURLTrack: false, isPlaying: true, now: t0)
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(1.2)) // 1.2s — the real SB-mismatch race window
        acc.beginPendingPlay(title: "Track B", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_B", isURLTrack: false, isPlaying: true, now: t0.addingTimeInterval(1.3))

        XCTAssertTrue(store.entries.isEmpty, "a 1.2s listen never qualifies at the default 10s threshold — this is the threshold working as designed, not H3 recurring")
    }

    /// At `minimumListenSeconds == 0`, the OLD H3 bug WOULD fully re-manifest
    /// without the "begin before the SB read" fix, since every confirmed
    /// change must record immediately regardless of duration.
    func test_h3_rapidDoubleSkip_zeroThreshold_stillNeverLosesAPlay() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 0)
        let t0 = Date(timeIntervalSince1970: 8600)
        acc.beginPendingPlay(title: "Track A", artist: "Artist", album: "Album", duration: 200, persistentID: "", isURLTrack: false, isPlaying: true, now: t0)
        XCTAssertEqual(store.entries.count, 1, "0 = commits the instant beginPendingPlay runs — BEFORE any SB read could possibly race it")

        acc.beginPendingPlay(title: "Track B", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_B", isURLTrack: false, isPlaying: true, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertTrue(store.entries.contains(where: { $0.title == "Track A" }))
        XCTAssertTrue(store.entries.contains(where: { $0.title == "Track B" }))
    }

    // MARK: - H4 regression: late PID must patch, never double-record

    func test_h4_pidArrivesWhileStillPending_appliesBeforeCommit_singleRecordWithCorrectPID() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 9000)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "", isURLTrack: false, isPlaying: true, now: t0)

        // SB resolves the real PID ~1s later — well before the 10s threshold.
        acc.updatePersistentID(startedAt: t0, persistentID: "REALPID", isURLTrack: false, now: t0.addingTimeInterval(1))

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.persistentID, "REALPID")
        XCTAssertEqual(store.entries.first?.sourceKind, .library)
    }

    func test_h4_pidArrivesAfterAlreadyCommitted_patchesStoreInPlace_neverDoubleRecords() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 0) // commits immediately, PID still unknown
        let t0 = Date(timeIntervalSince1970: 9500)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "", isURLTrack: false, isPlaying: true, now: t0)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.persistentID, "")

        // The SB read (or a pathologically slow one) resolves AFTER the play already committed.
        acc.updatePersistentID(startedAt: t0, persistentID: "LATEPID", isURLTrack: false, now: t0.addingTimeInterval(1.5))

        XCTAssertEqual(store.entries.count, 1, "must patch in place, never insert a second row")
        XCTAssertEqual(store.entries.first?.persistentID, "LATEPID")
    }

    func test_h4_updatePersistentID_supersededPlay_patchesNothingLive_storeStillPatched() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 0)
        let t0 = Date(timeIntervalSince1970: 9600)
        acc.beginPendingPlay(title: "Song A", artist: "Artist", album: "Album", duration: 200, persistentID: "", isURLTrack: false, isPlaying: true, now: t0)
        acc.beginPendingPlay(title: "Song B", artist: "Artist", album: "Album", duration: 200, persistentID: "PIDB", isURLTrack: false, isPlaying: true, now: t0.addingTimeInterval(1))

        // A's late PID resolution arrives after B already superseded it as `current`.
        acc.updatePersistentID(startedAt: t0, persistentID: "LATE_A_PID", isURLTrack: false, now: t0.addingTimeInterval(2))

        XCTAssertEqual(store.entries.first(where: { $0.title == "Song A" })?.persistentID, "LATE_A_PID", "the store patch must still apply even though A is no longer `current` in the accumulator")
        XCTAssertEqual(acc.current?.title, "Song B", "must not disturb the accumulator's actual current play")
    }

    func test_updateCurrentPersistentIDIfPending_noCurrentPlay_isNoOp() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        acc.updateCurrentPersistentIDIfPending(persistentID: "X", isURLTrack: false, now: Date())
        XCTAssertNil(acc.current)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_updateCurrentPersistentIDIfPending_appliesToWhateverIsCurrent() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 9700)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "", isURLTrack: false, isPlaying: true, now: t0)
        acc.updateCurrentPersistentIDIfPending(persistentID: "REFILLED", isURLTrack: false, now: t0.addingTimeInterval(1))
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.entries.first?.persistentID, "REFILLED")
    }

    // MARK: - App-quit flush

    func test_flushForAppTermination_playCrossedThresholdMomentsBeforeQuit_stillCommits() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 10000)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID", isURLTrack: false, isPlaying: true, now: t0)
        // No tick ever ran again before quit — simulates the last poll
        // landing just before the threshold, then the app quitting moments later.
        acc.flushForAppTermination(now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.entries.count, 1, "the app quitting must not lose a play that crossed the threshold in its final second")
    }

    func test_flushForAppTermination_stillUnderThreshold_doesNotFabricateAQualification() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 10100)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID", isURLTrack: false, isPlaying: true, now: t0)
        acc.flushForAppTermination(now: t0.addingTimeInterval(4))
        XCTAssertTrue(store.entries.isEmpty, "flush must not grant unlistened time — under threshold at quit is still under threshold")
    }

    func test_flushForAppTermination_noCurrentPlay_isNoOp() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        acc.flushForAppTermination(now: Date())
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - reset() (Settings → Clear Playback History)

    func test_reset_dropsInFlightPlay_neverResurrectsAfterClear() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 10200)
        acc.beginPendingPlay(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID", isURLTrack: false, isPlaying: true, now: t0)
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(5)) // under threshold, still pending

        acc.reset()
        store.clear() // what MusicController.clearPlaybackHistory() does alongside reset()

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(20)) // would have crossed 10s had it survived
        XCTAssertTrue(store.entries.isEmpty, "a play in flight before Clear Playback History must never resurrect a row afterward")
    }

    // MARK: - Rapid 9-track skip run, none cross threshold

    /// The scenario the coordinator asked for directly: 9 confirmed track
    /// changes inside a 38s span, evenly ~4.2s apart (well under the 10s
    /// threshold every time) — History must gain ZERO new rows.
    func test_rapidNineTrackBurst_evenlySpacedUnderThreshold_zeroNewHistoryEntries() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let base = Date(timeIntervalSince1970: 100_000)
        let titles = ["Roses", "Ocean Side", "Ring Around the Rosie", "Winter Solstice", "谁为我等", "Roses", "Ocean Side", "Ring Around the Rosie", "Winter Solstice"]
        for (i, title) in titles.enumerated() {
            let now = base.addingTimeInterval(Double(i) * 38.0 / 9.0) // ~4.2s apart, spans 38s total
            acc.beginPendingPlay(title: title, artist: "Artist", album: "Album", duration: 300, persistentID: "PID-\(i)", isURLTrack: false, isPlaying: true, now: now)
            acc.tick(isPlaying: true, now: now)
        }
        XCTAssertTrue(store.entries.isEmpty, "9 switches ~4.2s apart are all under the 10s threshold — none should qualify. Got: \(store.entries.map(\.title))")
    }

    /// Accuracy check using the EXACT gaps from the real capture in
    /// research/diagnosis-2026-09-25-history.md (2026-09-25 02:03:37–02:04:15
    /// local, notification-path timestamps gen3..gen11): the first dwell
    /// (Roses, notified at t=0, superseded at t=18 when "Ocean Side" fired)
    /// is genuinely 18 real seconds — long enough to cross a 10s threshold —
    /// while every dwell AFTER that (5s, 2s, 5s, 1s, 3s, 4s) stays well
    /// under it. The precise ground truth is ONE qualifying row from that
    /// window, not zero — asserting zero here would misrepresent the actual
    /// capture (see the diagnosis doc's ground-truth table).
    func test_realCapture_20260925_preciseGaps_exactlyOneQualifyingDwellAmongRapidSkips() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let base = Date(timeIntervalSince1970: 100_000)
        // (title, offsetSeconds) — offsets match the real capture's gen3..gen11 gaps exactly.
        let burst: [(String, TimeInterval)] = [
            ("Roses", 0), ("Ocean Side", 18), ("Roses", 18), ("Ring Around the Rosie", 23),
            ("Ocean Side", 25), ("Roses", 30), ("Winter Solstice", 31), ("谁为我等", 34), ("Winter Solstice", 38)
        ]
        for (title, offset) in burst {
            let now = base.addingTimeInterval(offset)
            acc.beginPendingPlay(title: title, artist: "Artist", album: "Album", duration: 300, persistentID: "PID-\(title)", isURLTrack: false, isPlaying: true, now: now)
        }
        XCTAssertEqual(store.entries.count, 1, "exactly the first Roses dwell (18s, t=0 to t=18) crosses the 10s threshold — every other dwell in the burst is under it")
        XCTAssertEqual(store.entries.first?.title, "Roses")
    }

    // MARK: - 100k-tick soak (fake clock — no real timers, memory/store stay bounded)

    func test_soak_100kTicksAndTrackChanges_storeStaysAtCapacity_noCrash() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        var now = Date(timeIntervalSince1970: 200_000)

        for i in 0..<100_000 {
            // Every 3rd iteration is a track change (well past the 10s
            // threshold each time, so every one qualifies) — 33k+ confirmed
            // plays, one fake-clock tick apiece, zero real waiting.
            if i % 3 == 0 {
                acc.beginPendingPlay(title: "Song \(i)", artist: "Artist", album: "Album", duration: 200, persistentID: "PID-\(i)", isURLTrack: false, isPlaying: true, now: now)
            }
            now = now.addingTimeInterval(11)
            acc.tick(isPlaying: true, now: now)
        }

        XCTAssertEqual(store.entries.count, PlaybackHistoryStore.capacity, "must stay capped, never grow unbounded over 100k events")
    }
}
