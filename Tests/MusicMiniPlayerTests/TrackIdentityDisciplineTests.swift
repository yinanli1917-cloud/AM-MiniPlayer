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
}
