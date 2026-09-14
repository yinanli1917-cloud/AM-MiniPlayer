/**
 * [INPUT]: MusicMiniPlayerCore.MusicController / PlaybackHistoryEntry
 * [OUTPUT]: Unit tests — preview seeding + clearPlaybackHistory() + the pure
 *           confirmed-track → PlaybackHistoryEntry mapping used at both
 *           confirmed-change call sites in MusicController.swift
 * [POS]: Test module (WT-D plan H2)
 *
 * NOTE: The two confirmed-track-change call sites (handleTrackChange's SB
 * completion block, and applySnapshot's trackChanged branch) live behind
 * ScriptingBridge / AppleScript reads with no injectable seam — driving them
 * directly would require a live Music.app. Per plan H2, this file instead
 * pins (a) the pure mapping those call sites feed into
 * (`PlaybackHistoryEntry.make`, already unit-tested standalone in
 * PlaybackHistoryStoreTests) against the exact argument shapes each call site
 * passes, and (b) the MusicController-level surface built on top of the
 * store: preview seeding and clearPlaybackHistory().
 */

import XCTest
@testable import MusicMiniPlayerCore

final class PlaybackHistoryWiringTests: XCTestCase {

    // MARK: - Preview seeding

    func test_previewController_seedsTwoHistoryEntries() {
        let controller = MusicController(preview: true)
        XCTAssertEqual(controller.playbackHistory.count, 2)
        XCTAssertEqual(controller.playbackHistory[0].title, "History Song 1")
        XCTAssertEqual(controller.playbackHistory[1].title, "History Song 2")
    }

    // MARK: - clearPlaybackHistory()

    func test_clearPlaybackHistory_emptiesPublishedHistory() {
        let controller = MusicController(preview: true)
        XCTAssertFalse(controller.playbackHistory.isEmpty)
        controller.clearPlaybackHistory()
        XCTAssertTrue(controller.playbackHistory.isEmpty)
    }

    // MARK: - Pure mapping at the notification-path call site
    // (handleTrackChange: persistentID resolved via SB, duration falls back
    // to the captured pre-notification duration when SB's read is 0)

    func test_notificationPathMapping_libraryTrack_usesResolvedPID() {
        let entry = PlaybackHistoryEntry.make(
            title: "Song", artist: "Artist", album: "Album",
            persistentID: "E6CA87B2C0269A9C", duration: 210.0,
            isURLTrack: false, startedAt: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(entry.sourceKind, .library)
        XCTAssertEqual(entry.persistentID, "E6CA87B2C0269A9C")
        XCTAssertEqual(entry.duration, 210.0)
    }

    func test_notificationPathMapping_radioTrack_emptyPID_isRadioOrStream() {
        let entry = PlaybackHistoryEntry.make(
            title: "Radio Song", artist: "Radio Artist", album: "",
            persistentID: "", duration: 0,
            isURLTrack: true, startedAt: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(entry.sourceKind, .radioOrStream)
    }

    // MARK: - Pure mapping at the snapshot-path call site
    // (applySnapshot: persistentID + duration come straight off the
    // AppleScript snapshot struct)

    func test_snapshotPathMapping_matchesSnapshotFields() {
        let entry = PlaybackHistoryEntry.make(
            title: "Snapshot Song", artist: "Snapshot Artist", album: "Snapshot Album",
            persistentID: "1234", duration: 95.5,
            isURLTrack: false, startedAt: Date(timeIntervalSince1970: 2000)
        )
        XCTAssertEqual(entry.title, "Snapshot Song")
        XCTAssertEqual(entry.artist, "Snapshot Artist")
        XCTAssertEqual(entry.album, "Snapshot Album")
        XCTAssertEqual(entry.persistentID, "1234")
        XCTAssertEqual(entry.duration, 95.5)
        XCTAssertEqual(entry.sourceKind, .library)
    }
}
