/**
 * [INPUT]: MusicMiniPlayerCore.PendingPlaybackAccumulator / PendingPlaybackRules /
 *          PendingPlay / PlaybackHistoryStore / PlaybackHistoryEntry
 * [OUTPUT]: Unit tests — the "待定播放 → 达标入账" mechanism: pure listened-time
 *           math, qualification threshold (0 and 10s), pause-excluded timing,
 *           redundant re-detection dedup, the H3 rapid-double-skip regression,
 *           the H4 late-PID regression (both the still-pending and
 *           already-committed patch paths), app-quit flush, a 100k-tick
 *           soak, and the wiring-layer pause-gap (2026-09-25 review round 2:
 *           `tick()` only reaching PendingPlaybackAccumulator through
 *           `applySnapshot`-equivalent boundaries, never through an
 *           `isPlaying`-change subscription) — all fake-clock-driven, zero
 *           real timers.
 * [POS]: Test module (2026-09-25 diagnosis phase-2 fix)
 */

import XCTest
import Combine
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

    /// 2026-09-25 review round 2, item 2: the notification path always opens
    /// with `isURLTrack: false` (unknown until the SB read classifies
    /// trackClass) — a PID-bearing URL track that only qualifies AFTER that
    /// classification resolves must still commit as `.radioOrStream`, not
    /// `.library`. Requires `isURLTrack` to be patchable on the STILL-PENDING
    /// play (round 1 only patched an already-committed store row's classification).
    func test_h4_updatePersistentID_alsoPatchesIsURLTrackOnStillPendingPlay() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 9200)
        acc.beginPendingPlay(title: "Stream Song", artist: "Artist", album: "Album", duration: 200, persistentID: "", isURLTrack: false, isPlaying: true, now: t0)

        // SB resolves BOTH a real PID and reveals trackClass == "URL track" —
        // well before the 10s threshold, so this patches the PENDING play.
        acc.updatePersistentID(startedAt: t0, persistentID: "URLPID123", isURLTrack: true, now: t0.addingTimeInterval(1))

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.persistentID, "URLPID123")
        XCTAssertEqual(store.entries.first?.sourceKind, .radioOrStream, "isURLTrack must have been corrected on the pending play BEFORE commit, not left at the notification-time default (false)")
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

    // MARK: - Music.app quits mid-session, then reopens (2026-09-25 review round 2, item 3)
    //
    // nanoPod (the menu bar app) keeps running and polling while Music.app
    // itself quits — from the accumulator's point of view this looks like:
    // isPlaying goes false (whatever mechanism detects "not running" drives a
    // tick, exactly like a pause), a gap passes, then a fresh confirmed
    // identity arrives once Music.app reopens and starts playing again
    // (`currentTrackTitle` was poisoned to the sentinel while gone, so
    // `snapshotIndicatesTrackChange`'s heal branch treats the next valid
    // snapshot as a change even if it's the SAME song — MusicController.swift's
    // existing poisoned-display heal, unchanged by this fix).

    /// SAME song resumes after reopen. `isSameSong` matches (same PID) —
    /// per the coordinator's own closing note ("一首歌播完…隔很久又放同一首
    /// 时…会并进上一次播放…不算回归"), a redundant re-detection of a song
    /// still held as `current` merges into it rather than starting fresh.
    /// This is that exact accepted behavior, not a new gap: the pre-quit and
    /// post-reopen listening on the SAME song combine into one entry.
    func test_musicAppQuitAndReopen_sameSongResumes_mergesIntoOnePlay_perAcceptedRedetectionRule() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 300_000)

        acc.beginPendingPlay(title: "Song A", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_A", isURLTrack: false, isPlaying: true, now: t0)
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(3)) // 3s listened
        acc.tick(isPlaying: false, now: t0.addingTimeInterval(3)) // Music.app quits — isPlaying observed false, segment closes
        XCTAssertTrue(store.entries.isEmpty, "only 3s listened so far — must not have qualified yet")

        // Music.app is closed for two real minutes; nanoPod keeps polling but
        // isPlaying stays false throughout (nothing accrues).
        acc.tick(isPlaying: false, now: t0.addingTimeInterval(123))

        // Reopened: Music.app resumes the SAME song (same PID) — the
        // poisoned-title heal makes MusicController call beginPendingPlay
        // again even though it's the same identity. `beginPendingPlay`'s
        // redundant-re-detection branch returns early and does NOT itself
        // reopen the segment (it only logs) — in the real system, resuming
        // playback is a SEPARATE signal: `self.isPlaying` transitions
        // false→true independently, firing the `$isPlaying` subscription's
        // own `tick(isPlaying: true)` (item 1's fix). Model both signals,
        // exactly like the real wiring fires both.
        acc.beginPendingPlay(title: "Song A", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_A", isURLTrack: false, isPlaying: true, now: t0.addingTimeInterval(123))
        XCTAssertTrue(store.entries.isEmpty, "redundant re-detection of the still-tracked song must not itself commit or restart progress")
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(123)) // the isPlaying subscription firing at the reopen moment — reopens the segment

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(123 + 7)) // +7s post-reopen = 10s total real listening
        XCTAssertEqual(store.entries.count, 1, "3s pre-quit + 7s post-reopen = 10s of ACTUAL listening on the same song must qualify exactly once")
        XCTAssertEqual(store.entries.first?.persistentID, "PID_A")
        XCTAssertEqual(store.entries.first?.startedAt, t0, "the committed entry's startedAt is the ORIGINAL play's, not the reopen moment — one continuous listen, not two")
    }

    /// DIFFERENT song plays after reopen — the ordinary, already-well-tested
    /// track-change path, exercised specifically through an app-quit gap:
    /// the pre-quit song (never qualified) must be correctly discarded, and
    /// the post-reopen different song must accumulate and commit independently.
    func test_musicAppQuitAndReopen_differentSongPlays_preQuitSongDiscarded_newSongIndependent() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 310_000)

        acc.beginPendingPlay(title: "Song A", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_A", isURLTrack: false, isPlaying: true, now: t0)
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(4)) // 4s — under threshold
        acc.tick(isPlaying: false, now: t0.addingTimeInterval(4)) // quits

        acc.tick(isPlaying: false, now: t0.addingTimeInterval(200)) // closed for a while

        // Reopened with a DIFFERENT song playing.
        acc.beginPendingPlay(title: "Song B", artist: "Other Artist", album: "Other Album", duration: 180, persistentID: "PID_B", isURLTrack: false, isPlaying: true, now: t0.addingTimeInterval(200))
        XCTAssertTrue(store.entries.isEmpty, "Song A's pre-quit 4s must be discarded (correctly, it never reached 10s) when a genuinely different song supersedes it")

        acc.tick(isPlaying: true, now: t0.addingTimeInterval(200 + 10))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.persistentID, "PID_B", "only the post-reopen different song qualifies, independently of the discarded pre-quit one")
    }

    // MARK: - System clock rollback (2026-09-25 review round 2, item 3)

    /// The system clock jumping backward must never manufacture a negative
    /// or absurdly large listened-time value, and PlaybackHistoryStore's
    /// insertion-order guarantee (always `insert(at: 0)`, never re-sorted by
    /// `startedAt`) must hold even when a later-inserted entry's own
    /// timestamp is numerically EARLIER than an already-stored one's.
    func test_systemClockRollback_noNegativeOrHugeAccumulation_insertionOrderPreserved() {
        let store = makeStore(dir: freshDir())
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 400_000)

        acc.beginPendingPlay(title: "Song 1", artist: "Artist", album: "Album", duration: 200, persistentID: "P1", isURLTrack: false, isPlaying: true, now: t0)
        acc.tick(isPlaying: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.entries.count, 1, "sanity: Song 1 committed normally")

        // System clock rolls back by an hour at the next confirmed change.
        let rolledBack = t0.addingTimeInterval(10 - 3600)
        acc.beginPendingPlay(title: "Song 2", artist: "Artist", album: "Album", duration: 200, persistentID: "P2", isURLTrack: false, isPlaying: true, now: rolledBack)

        // A tick arrives with `now` even further behind `rolledBack` (clock
        // still unstable / jittering backward) — segmentStart > now.
        acc.tick(isPlaying: true, now: rolledBack.addingTimeInterval(-100))
        let listenedDuringRollback = acc.current.map { PendingPlaybackRules.totalListenedSeconds($0, at: rolledBack.addingTimeInterval(-100)) }
        XCTAssertNotNil(listenedDuringRollback)
        XCTAssertGreaterThanOrEqual(listenedDuringRollback ?? -1, 0, "must never go negative when segmentStart is after `now`")
        XCTAssertLessThan(listenedDuringRollback ?? .infinity, 1000, "must never explode into a huge bogus value")
        XCTAssertEqual(store.entries.count, 1, "Song 2 must not have spuriously qualified from a clock artifact")

        // Clock corrects itself and real forward progress resumes.
        acc.tick(isPlaying: true, now: rolledBack.addingTimeInterval(10))
        XCTAssertEqual(store.entries.count, 2, "Song 2 must still be able to qualify once real forward progress resumes")

        // Insertion order: always newest-BY-RECORDING-ORDER at index 0, never
        // re-sorted by startedAt — Song 2's `startedAt` (rolledBack, an hour
        // before Song 1's) must not reorder or corrupt the list.
        XCTAssertEqual(store.entries.map(\.persistentID), ["P2", "P1"], "store must never re-sort by startedAt; a clock rollback must not reorder or corrupt existing rows")
    }
}

// ============================================================
// MARK: - Wiring-layer pause gap (2026-09-25 review round 2)
//
// PendingPlaybackAccumulator.tick's own math is correct GIVEN it receives a
// tick at every isPlaying transition — that contract held in every test
// above because each one calls tick() explicitly at the pause/resume
// moment. The real bug was never in that math: it's that MusicController
// never called tick() at an isPlaying transition at all. `applySnapshot`
// (the only place `tick` was wired, round 1) is reached during ordinary
// steady playback ONLY at confirmed track changes and the 30s fullSyncTimer
// — pollPositionViaSB's 2s poll and the 5s identity heartbeat both mutate
// `self.isPlaying` directly (MusicController.swift, "Update playing state"
// and the velocity-pause-inference branch) WITHOUT going through
// applySnapshot at all. A pause between two such boundaries — easily up to
// 30 real seconds — got its whole wall-clock span counted as "listened".
//
// These tests drive PendingPlaybackAccumulator through a real Combine
// `PassthroughSubject<Bool, Never>` standing in for MusicController's real
// `$isPlaying`, on an injected MUTABLE fake clock (deterministic, no real
// waiting) — the RED test reproduces today's gap by leaving the publisher
// UNSUBSCRIBED (matching current MusicController: nothing listens to
// isPlaying changes) and driving only 30s-fullSyncTimer-shaped boundary
// ticks; the GREEN test proves the fix's exact shape
// (`$isPlaying.removeDuplicates().sink { tick(isPlaying:) }`) closes it.
// ============================================================

/// Simple mutable fake clock — a class (not a struct) so a `.sink` closure
/// can read its CURRENT value at the moment a Combine event actually fires,
/// exactly like `Date()` would in the real MusicController subscription,
/// but fully deterministic and controlled by the test.
private final class MutableFakeClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class PendingPlaybackAccumulatorWiringGapTests: XCTestCase {

    private func makeStore(dir: URL) -> PlaybackHistoryStore {
        PlaybackHistoryStore(
            fileURL: NanoPodCacheLocation.versionedFileURL(baseName: "playback-history", schemaVersion: PlaybackHistoryStore.schemaVersion, in: dir),
            scheduler: { _, _ in },
            writeHook: { _, _ in }
        )
    }

    private func freshDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// Documents the round-1 gap this file's OTHER test proves the fix for.
    /// Originally run RED (before the fix, `swift test` output: "XCTAssertNil
    /// failed: ... PID_OLD ... committed" — reproducing exactly the round-2
    /// review finding) against a harness with NO isPlaying subscription —
    /// only 30s-fullSyncTimer-shaped boundary ticks, matching MusicController's
    /// ACTUAL round-1 wiring during steady, non-track-changing playback. Old
    /// Song genuinely plays 3s, is paused, and 17s later (no boundary crossed
    /// in between) the user skips to Next Song. Kept — assertion inverted —
    /// as a permanent characterization test: this is the anti-pattern the
    /// real MusicController.init subscription (item 1's fix) exists to avoid;
    /// it intentionally does NOT exercise MusicController at all, so removing
    /// that subscription later would NOT be caught here — the actual
    /// regression pin is the very next test, `_withIsPlayingSubscription_`.
    func test_withoutIsPlayingSubscription_illustratesWhyItsNecessary_pausedTimeWronglyCounted() {
        let store = makeStore(dir: freshDir())
        let clock = MutableFakeClock(Date(timeIntervalSince1970: 50_000))
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10, clock: { clock.now })

        // `$isPlaying` stand-in — deliberately left UNSUBSCRIBED, matching
        // today's MusicController (nothing observes isPlaying transitions).
        let isPlayingChanges = PassthroughSubject<Bool, Never>()
        var cancellables = Set<AnyCancellable>()
        _ = (isPlayingChanges, cancellables) // exists, unused — that omission IS the bug

        acc.beginPendingPlay(title: "Old Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_OLD", isURLTrack: false, isPlaying: true, now: clock.now)

        clock.advance(by: 3)
        isPlayingChanges.send(false) // Music.app really paused here — nobody's listening
        clock.advance(by: 17) // genuinely paused for 17 more real seconds; no 30s fullSync boundary crossed

        // The user resumes and skips — a real confirmed track change at t+20.
        acc.beginPendingPlay(title: "Next Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_NEXT", isURLTrack: false, isPlaying: true, now: clock.now)

        // INVERTED on purpose (was XCTAssertNil, failed, before the fix):
        // this harness deliberately has NO isPlaying subscription, so Old
        // Song's 17s pause is wrongly folded into "listened" time and it
        // wrongly qualifies — exactly the round-1 gap. Asserting that HERE
        // (in a harness that will never have the real fix applied to it)
        // keeps the suite green while leaving the reproduction executable
        // and readable, instead of deleting the evidence once it stopped
        // being "red".
        XCTAssertNotNil(
            store.entries.first(where: { $0.persistentID == "PID_OLD" }),
            "documents the round-1 anti-pattern: without an isPlaying subscription, only ~3s genuinely listened (paused for 17s) still wrongly crosses the 10s threshold and commits"
        )
    }

    /// GREEN: the actual fix shape — `$isPlaying.removeDuplicates().sink { tick(isPlaying:) }`
    /// — applied to the SAME scenario. `removeDuplicates()` matters here too:
    /// a redundant `send(true)` at the same value must not restart the segment.
    func test_pauseGap_withIsPlayingSubscription_correctlyExcludesPausedTime() {
        let store = makeStore(dir: freshDir())
        let clock = MutableFakeClock(Date(timeIntervalSince1970: 60_000))
        let acc = PendingPlaybackAccumulator(store: store, minimumListenSeconds: 10, clock: { clock.now })

        let isPlayingChanges = PassthroughSubject<Bool, Never>()
        var cancellables = Set<AnyCancellable>()
        isPlayingChanges
            .removeDuplicates()
            .sink { playing in acc.tick(isPlaying: playing) }
            .store(in: &cancellables)

        acc.beginPendingPlay(title: "Old Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_OLD", isURLTrack: false, isPlaying: true, now: clock.now)

        clock.advance(by: 3)
        isPlayingChanges.send(false) // pause — the subscription ticks NOW, closing the 3s segment
        isPlayingChanges.send(false) // a redundant duplicate signal (e.g. two paths both observing the same pause) — removeDuplicates must swallow it
        clock.advance(by: 17) // paused; nothing accrues

        acc.beginPendingPlay(title: "Next Song", artist: "Artist", album: "Album", duration: 200, persistentID: "PID_NEXT", isURLTrack: false, isPlaying: true, now: clock.now)

        XCTAssertNil(
            store.entries.first(where: { $0.persistentID == "PID_OLD" }),
            "with the isPlaying subscription wired, only the true ~3s listened must be counted — 3s < the 10s threshold, so Old Song must NOT qualify"
        )

        // Now let it actually cross the threshold: Next Song plays 12 real
        // seconds with a duplicate-suppressed same-value signal in the middle.
        clock.advance(by: 6)
        isPlayingChanges.send(true) // still playing — must be swallowed by removeDuplicates, not treated as a fresh resume
        clock.advance(by: 6)
        acc.tick(isPlaying: true) // the regular applySnapshot-cadence tick also still runs alongside the subscription

        XCTAssertEqual(store.entries.first?.persistentID, "PID_NEXT", "12 real seconds of Next Song must qualify and commit")
    }
}
