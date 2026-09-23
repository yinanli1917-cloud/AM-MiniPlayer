/**
 * [INPUT]: MusicMiniPlayerCore MusicController + LyricsService identity policies
 * [OUTPUT]: Unit tests for track-identity discipline (Tier 1 of the 2026-07-18
 *           architecture program)
 * [POS]: Test module. Pins the three doors behind "whole page + background
 *        refresh mid-song" and "correct lyrics go blank": (1) same-song
 *        playerInfo notifications with drifted title/artist strings must not
 *        register as track changes; (2) an unknown (refilling) persistentID
 *        must never assert a track change by itself; (3) a late artwork result
 *        must not replace an already-applied Apple-authoritative image; and
 *        the persistentID-anchored same-song rule for lyrics preservation.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class TrackIdentityDisciplineTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Notification persistentID parsing
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_notificationPID_parsesIntegerToUppercaseHex() {
        XCTAssertEqual(
            MusicController.notificationPersistentIDString(Int64(bitPattern: 0xE6CA87B2C0269A9C as UInt64)),
            "E6CA87B2C0269A9C"
        )
        XCTAssertEqual(
            MusicController.notificationPersistentIDString(NSNumber(value: Int64(0x0000_0000_0000_002A))),
            "000000000000002A"
        )
    }

    func test_notificationPID_passesStringsThrough_andRejectsAbsence() {
        XCTAssertEqual(MusicController.notificationPersistentIDString("E6CA87B2C0269A9C"), "E6CA87B2C0269A9C")
        XCTAssertNil(MusicController.notificationPersistentIDString(nil))
        XCTAssertNil(MusicController.notificationPersistentIDString(""))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Door 1: same-song notification with drifted strings
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_notification_samePID_driftedMetadata_isNotATrackChange() {
        XCTAssertFalse(MusicController.notificationIndicatesTrackChange(
            notificationPID: "AAAA", currentPID: "AAAA", metadataDiffers: true))
    }

    func test_notification_differentPID_isATrackChange_evenWithEqualMetadata() {
        XCTAssertTrue(MusicController.notificationIndicatesTrackChange(
            notificationPID: "BBBB", currentPID: "AAAA", metadataDiffers: false))
    }

    func test_notification_unknownPID_fallsBackToMetadataComparison() {
        XCTAssertTrue(MusicController.notificationIndicatesTrackChange(
            notificationPID: nil, currentPID: "AAAA", metadataDiffers: true))
        XCTAssertFalse(MusicController.notificationIndicatesTrackChange(
            notificationPID: nil, currentPID: "AAAA", metadataDiffers: false))
        XCTAssertTrue(MusicController.notificationIndicatesTrackChange(
            notificationPID: "AAAA", currentPID: nil, metadataDiffers: true))
        XCTAssertFalse(MusicController.notificationIndicatesTrackChange(
            notificationPID: "AAAA", currentPID: "", metadataDiffers: false))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Door 2: snapshot track-change decision (refilling PID)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func snapshotChange(
        pid: String = "AAAA", url: Bool = false,
        title: String = "Song", artist: String = "Artist", album: String = "Album",
        curPID: String? = "AAAA", curTitle: String = "Song", curArtist: String = "Artist", curAlbum: String = "Album"
    ) -> Bool {
        MusicController.snapshotIndicatesTrackChange(
            snapshotPID: pid, snapshotIsURLTrack: url,
            snapshotTitle: title, snapshotArtist: artist, snapshotAlbum: album,
            currentPID: curPID, currentTitle: curTitle, currentArtist: curArtist, currentAlbum: curAlbum)
    }

    func test_snapshot_knownEqualPID_titleDrift_isNotAChange() {
        XCTAssertFalse(snapshotChange(title: "Song (Remastered)", curTitle: "Song"))
    }

    func test_snapshot_knownDifferentPID_isAChange() {
        XCTAssertTrue(snapshotChange(pid: "BBBB", curPID: "AAAA"))
    }

    func test_snapshot_refillingPID_sameTitleArtist_isNotAChange() {
        // The double-fetch door: notification sets currentPersistentID = nil,
        // heartbeat lands before the SB refill — must NOT re-trigger the pipeline.
        XCTAssertFalse(snapshotChange(curPID: nil))
        XCTAssertFalse(snapshotChange(curPID: ""))
    }

    func test_snapshot_refillingPID_differentTitle_isAChange() {
        XCTAssertTrue(snapshotChange(title: "Other Song", curPID: nil, curTitle: "Song"))
    }

    func test_snapshot_launchSentinel_isAChange() {
        XCTAssertTrue(snapshotChange(curPID: nil, curTitle: kNotPlayingSentinel, curArtist: ""))
    }

    func test_snapshot_poisonedSentinelTitle_healsEvenWithMatchingPID() {
        // Regression (2026-07-18 live): applyNoTrack left title = sentinel with
        // the PID still set; PID-equality then suppressed every heal — panel
        // stuck with no song info and no artwork while music played on.
        XCTAssertTrue(snapshotChange(curPID: "AAAA", curTitle: kNotPlayingSentinel, curArtist: ""))
        XCTAssertTrue(snapshotChange(curPID: "AAAA", curTitle: ""))
    }

    func test_notification_invalidName_neverAdoptedAsIdentity() {
        XCTAssertFalse(MusicController.isValidTrackDisplayName(kNotPlayingSentinel))
        XCTAssertFalse(MusicController.isValidTrackDisplayName(""))
        XCTAssertFalse(MusicController.isValidTrackDisplayName("NOT_PLAYING"))
        XCTAssertTrue(MusicController.isValidTrackDisplayName("Vivre Pour Vivre"))
    }

    func test_snapshot_urlTrack_comparesTitleArtistAlbum() {
        XCTAssertTrue(snapshotChange(pid: "", url: true, album: "Other Album"))
        XCTAssertFalse(snapshotChange(pid: "", url: true))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Door 3: late artwork result vs applied Apple image
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_lateArtwork_droppedOnceAppleApplied_includingSB() {
        for source: MusicController.ArtworkSource in [.sb, .musicKit, .iTunes, .web, .playbackSession] {
            XCTAssertTrue(MusicController.shouldDropLateArtworkResult(
                source: source, appleAppliedForGeneration: true),
                "late \(source) must not replace an applied Apple image (crossfade churn)")
        }
    }

    func test_lateArtwork_keptWhenNothingAppleApplied() {
        for source: MusicController.ArtworkSource in [.sb, .musicKit, .iTunes, .web] {
            XCTAssertFalse(MusicController.shouldDropLateArtworkResult(
                source: source, appleAppliedForGeneration: false))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Lyrics preservation: persistentID anchor
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func sameSong(
        curStable: String? = "song|artist", reqStable: String = "song|artist",
        curDur: TimeInterval = 220, reqDur: TimeInterval = 221,
        curAlbum: String = "Album", reqAlbum: String = "Album",
        reqPID: String? = nil, curPID: String? = nil
    ) -> Bool {
        LyricsService.isLikelySameSongMetadataCorrection(
            currentStableSongID: curStable, requestStableSongID: reqStable,
            currentDuration: curDur, requestDuration: reqDur,
            currentAlbum: curAlbum, requestAlbum: reqAlbum,
            requestPersistentID: reqPID, currentPersistentID: curPID)
    }

    func test_pidMatch_overridesStableIDVariant() {
        // Romanized ↔ CJK title variant used to blank correct lyrics; the pid
        // proves it is the same physical song.
        XCTAssertTrue(sameSong(curStable: "er shi sui|artist", reqStable: "二十岁|artist",
                               reqPID: "AAAA", curPID: "AAAA"))
    }

    func test_pidMatch_overridesLargeDurationDrift() {
        XCTAssertTrue(sameSong(curDur: 220, reqDur: 226, reqPID: "AAAA", curPID: "AAAA"))
    }

    func test_pidMismatch_defeatsMatchingTuple() {
        XCTAssertFalse(sameSong(reqPID: "BBBB", curPID: "AAAA"))
    }

    func test_pidAbsent_keepsLegacyHeuristics() {
        XCTAssertTrue(sameSong())                                  // Δ1s, same stable → same song
        XCTAssertFalse(sameSong(reqDur: 226))                      // Δ6s → not
        XCTAssertFalse(sameSong(reqStable: "other|artist"))        // stable differs → not
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Door 4: deferred lyrics-correction coherence (2026-09-22)
    //
    // MusicController.swift:1531/:1580 each fire a "duration correction"
    // fetchLyrics call from a closure created at track-change time but not
    // executed until after an async SB read + queue hop (up to ~1.5s+ later).
    // Root fix: re-check BOTH the artwork/lyrics generation and the live
    // current title/artist against what the closure captured, immediately
    // before firing — see research/diagnosis-2026-09-22-blank-lyrics-page.md.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_deferredLyricsCorrection_firesWhenGenerationAndIdentityStillMatch() {
        XCTAssertTrue(MusicController.shouldFireDeferredLyricsCorrection(
            capturedGeneration: 5, currentGeneration: 5,
            capturedTitle: "Song", currentTitle: "Song",
            capturedArtist: "Artist", currentArtist: "Artist"
        ), "a legitimate same-song duration correction must still fire")
    }

    func test_deferredLyricsCorrection_dropsOnGenerationMismatch() {
        XCTAssertFalse(MusicController.shouldFireDeferredLyricsCorrection(
            capturedGeneration: 5, currentGeneration: 6,
            capturedTitle: "Song", currentTitle: "Song",
            capturedArtist: "Artist", currentArtist: "Artist"
        ))
    }

    func test_deferredLyricsCorrection_dropsOnLiveTitleDrift_evenIfGenerationStillMatches() {
        // The real bug's exact shape (L52334): the closure captured "Mc's
        // Road De Aimasho" — by the time it's ready to fire, the live
        // identity has already moved on to "Roland Reve". Title/artist alone
        // (not just generation) must be re-checked.
        XCTAssertFalse(MusicController.shouldFireDeferredLyricsCorrection(
            capturedGeneration: 5, currentGeneration: 5,
            capturedTitle: "Mc's Road De Aimasho", currentTitle: "Roland Reve",
            capturedArtist: "Kazuhito Murata", currentArtist: "Jacqueline Danno"
        ))
    }

    func test_deferredLyricsCorrection_dropsOnArtistDriftAlone() {
        XCTAssertFalse(MusicController.shouldFireDeferredLyricsCorrection(
            capturedGeneration: 5, currentGeneration: 5,
            capturedTitle: "Song", currentTitle: "Song",
            capturedArtist: "Artist A", currentArtist: "Artist B"
        ))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Door 5: generic lyrics-identity self-heal (2026-09-22)
    //
    // Backstop for the whole bug class, not just the two races fixed above:
    // reissue a clean fetch when LyricsService's own tracked full identity
    // (title+artist+duration+album) disagrees with the controller's current
    // track while the page is blank.
    //
    // 2026-09-22 hardening (coordinator review of a82aa98): a per-identity
    // cooldown ALONE has no total cap — if the reissued fetch is itself
    // rejected or normalized differently (its own stability guard blocks it,
    // or the mismatch is simply permanent), the heartbeat would reissue
    // forever, every `cooldown` seconds, for the whole song — a silent
    // network-hitting loop. `reissueCountForCurrentTrack` + `maxReissuesPerTrack`
    // is a HARD total cap, reset only by the caller on a real track change
    // (never by these pure-function tests, which is exactly why the "over 60s
    // of fake heartbeats" test below drives the counter itself rather than
    // asserting a single call).
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_selfHeal_reissuesWhenBlankAndIdentityMismatched() {
        XCTAssertTrue(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: true,
            lyricsMatchesControllerIdentity: false,
            reissueCountForCurrentTrack: 0,
            lastReissueAt: nil,
            now: Date()
        ))
    }

    func test_selfHeal_doesNothingWhenContentIsShowing() {
        XCTAssertFalse(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: false,
            lyricsMatchesControllerIdentity: false,
            reissueCountForCurrentTrack: 0,
            lastReissueAt: nil,
            now: Date()
        ), "content on screen must never be interrupted by the self-heal, even if identity bookkeeping looks off")
    }

    func test_selfHeal_doesNothingWhenIdentitiesAlreadyMatch() {
        XCTAssertFalse(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: true,
            lyricsMatchesControllerIdentity: true,
            reissueCountForCurrentTrack: 0,
            lastReissueAt: nil,
            now: Date()
        ), "a genuine, still-in-flight search for the right song must not be reissued")
    }

    func test_selfHeal_repeatedMismatchWithinCooldown_doesNotStorm() {
        let now = Date()
        XCTAssertFalse(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: true,
            lyricsMatchesControllerIdentity: false,
            reissueCountForCurrentTrack: 0,
            lastReissueAt: now.addingTimeInterval(-1.0),
            now: now,
            cooldown: 5.0
        ), "a just-reissued identity must not be reissued again inside the cooldown — no storm")
    }

    func test_selfHeal_reissuesAgainAfterCooldownElapses_ifUnderTheCap() {
        let now = Date()
        XCTAssertTrue(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: true,
            lyricsMatchesControllerIdentity: false,
            reissueCountForCurrentTrack: 1,
            lastReissueAt: now.addingTimeInterval(-6.0),
            now: now,
            cooldown: 5.0
        ))
    }

    // MARK: Door 5b — total cap (2026-09-22 hardening)

    func test_selfHeal_hardCapsAtMaxReissuesPerTrack_evenPastCooldownAndTime() {
        let now = Date()
        // Two attempts already made for this track, cooldown long expired,
        // mismatch still unresolved — a per-identity cooldown alone would say
        // "yes, reissue again". The hard cap (default 2) must say no.
        XCTAssertFalse(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: true,
            lyricsMatchesControllerIdentity: false,
            reissueCountForCurrentTrack: 2,
            lastReissueAt: now.addingTimeInterval(-3600),
            now: now,
            cooldown: 5.0
        ), "the total cap must hold even long after the cooldown has expired — otherwise a permanent mismatch loops forever")
    }

    func test_selfHeal_respectsACustomCap() {
        XCTAssertFalse(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: true,
            lyricsMatchesControllerIdentity: false,
            reissueCountForCurrentTrack: 1,
            maxReissuesPerTrack: 1,
            lastReissueAt: nil,
            now: Date()
        ))
        XCTAssertTrue(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: true,
            lyricsMatchesControllerIdentity: false,
            reissueCountForCurrentTrack: 0,
            maxReissuesPerTrack: 1,
            lastReissueAt: nil,
            now: Date()
        ))
    }

    /// Coordinator's requested test (a): drives the SAME loop MusicController's
    /// heartbeat would run — one simulated tick every 2s for 60s (30 ticks) —
    /// against a mismatch that NEVER resolves (the reissued fetch is imagined
    /// to be rejected/normalized differently every time, exactly the failure
    /// mode under review). Exactly `maxLyricsIdentityReissuesPerTrack` (2)
    /// reissues must fire over the whole 60s, then silence for the rest.
    func test_selfHeal_exactlyCappedReissuesOver60sOfFakeHeartbeats_thenSilence_whenMismatchNeverResolves() {
        var reissueCount = 0
        var lastReissueAt: Date?
        var firedTicks: [Int] = []
        let start = Date()
        let tickInterval: TimeInterval = 2.0
        let totalTicks = Int(60.0 / tickInterval)  // 30 ticks over 60s

        for tick in 0..<totalTicks {
            let now = start.addingTimeInterval(Double(tick) * tickInterval)
            let shouldReissue = MusicController.shouldReissueLyricsFetchForStaleIdentity(
                lyricsRowsAreEmpty: true,
                lyricsMatchesControllerIdentity: false,  // never resolves — the failure mode under review
                reissueCountForCurrentTrack: reissueCount,
                lastReissueAt: lastReissueAt,
                now: now
            )
            if shouldReissue {
                firedTicks.append(tick)
                reissueCount += 1
                lastReissueAt = now
            }
        }

        XCTAssertEqual(reissueCount, MusicController.maxLyricsIdentityReissuesPerTrackForTesting,
            "must fire EXACTLY the capped number of reissues over 60s when the mismatch never resolves, then go silent — never a per-heartbeat storm")
        XCTAssertEqual(firedTicks.count, MusicController.maxLyricsIdentityReissuesPerTrackForTesting)
    }

    /// Coordinator's requested test (b): a sub-second real duration difference
    /// that straddles an integer ROUNDING boundary (137.6 vs 137.4 — only 0.2s
    /// apart, but `Int(_.rounded())` puts them in buckets 138 and 137) must NOT
    /// register as an identity mismatch, because `isLikelySameSongMetadataCorrection`
    /// (which `isCurrentFetchIdentity` defers to) tolerates drift up to 2.0s —
    /// the service itself would treat this as the same song.
    @MainActor
    func test_selfHeal_identityCheck_toleratesSubSecondDurationRoundingFlip() {
        let service = LyricsService.shared
        let uid = UUID().uuidString.prefix(8)
        let title = "Rounding Flip \(uid)"
        let artist = "Artist \(uid)"
        let album = "Album \(uid)"
        service.debugSeedDisplayedLyricsForTesting(
            [LyricLine(text: "line", startTime: 0, endTime: 3)],
            title: title, artist: artist, duration: 137.6, album: album, isUnsynced: false
        )

        // 137.6 rounds to 138; 137.4 rounds to 137 — different integer
        // buckets from only a 0.2s real difference, straddling the .5 cutoff.
        XCTAssertEqual(Int((137.6 as Double).rounded()), 138)
        XCTAssertEqual(Int((137.4 as Double).rounded()), 137)

        XCTAssertTrue(service.isCurrentFetchIdentity(title: title, artist: artist, duration: 137.4, album: album),
            "a sub-second duration difference that only flips the ROUNDING bucket must not count as a mismatch")
    }
}
