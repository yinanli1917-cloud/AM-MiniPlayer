/**
 * [INPUT]: PlaylistRowContinuousAnimationPolicy, PlaybackHistoryDisplayPolicy
 * [OUTPUT]: Regression pins for the WT-D plan H CPU postmortem, part 2 (2026-09-15
 *           real-machine sample: `-[RBLayer display]` every frame, traced to the
 *           current-track waveform row's `.symbolEffect(.variableColor.iterative,
 *           isActive:)` running continuously off the Playlist page)
 * [POS]: Tests/ — pure-logic tests, no SwiftUI hosting needed (unlike
 *        PlaylistViewRenderChurnTests, which measures body re-render behavior;
 *        these pin the two DECISIONS that feed that behavior)
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import XCTest
@testable import MusicMiniPlayerCore

final class PlaylistRowContinuousAnimationPolicyTests: XCTestCase {

    // MARK: - Page visibility gates the animation

    func test_playing_playlistPageVisible_active() {
        XCTAssertTrue(
            PlaylistRowContinuousAnimationPolicy.isActive(isPlaying: true, currentPage: .playlist)
        )
    }

    func test_playing_lyricsPageVisible_notActive() {
        XCTAssertFalse(
            PlaylistRowContinuousAnimationPolicy.isActive(isPlaying: true, currentPage: .lyrics),
            "the current-track row is mounted (History always includes it in the data model) but off-screen — its waveform must not animate"
        )
    }

    func test_playing_albumPageVisible_notActive() {
        XCTAssertFalse(
            PlaylistRowContinuousAnimationPolicy.isActive(isPlaying: true, currentPage: .album)
        )
    }

    // MARK: - Not playing never animates, regardless of page

    func test_notPlaying_playlistPageVisible_notActive() {
        XCTAssertFalse(
            PlaylistRowContinuousAnimationPolicy.isActive(isPlaying: false, currentPage: .playlist)
        )
    }

    func test_notPlaying_lyricsPageVisible_notActive() {
        XCTAssertFalse(
            PlaylistRowContinuousAnimationPolicy.isActive(isPlaying: false, currentPage: .lyrics)
        )
    }
}

final class PlaybackHistoryDisplayPolicyTests: XCTestCase {

    private func entry(_ id: String, title: String = "T") -> PlaybackHistoryEntry {
        PlaybackHistoryEntry(
            persistentID: id, title: title, artist: "A", album: "Al",
            duration: 200, sourceKind: id.isEmpty ? .radioOrStream : .library,
            startedAt: Date()
        )
    }

    // MARK: - Currently playing track is filtered out

    func test_currentTrack_excludedFromDisplay() {
        let history = [entry("current"), entry("older1"), entry("older2")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentPersistentID: "current")

        XCTAssertEqual(displayed.map(\.persistentID), ["older1", "older2"])
    }

    func test_currentTrack_notInHistoryYet_leavesHistoryUnchanged() {
        let history = [entry("older1"), entry("older2")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentPersistentID: "current")

        XCTAssertEqual(displayed.map(\.persistentID), ["older1", "older2"])
    }

    func test_nilCurrentPersistentID_leavesHistoryUnchanged() {
        let history = [entry("a"), entry("b")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentPersistentID: nil)

        XCTAssertEqual(displayed.count, 2)
    }

    // MARK: - Empty-persistentID (radio/URL) safety: never blanket-match ""

    func test_emptyCurrentPersistentID_doesNotHideOtherEmptyIDRows() {
        // Two PAST radio/URL entries, both with "" persistentID, plus one
        // library entry. Empty currentPersistentID must not be treated as "a
        // real identity" and match against them.
        let history = [entry(""), entry(""), entry("lib1")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentPersistentID: "")

        XCTAssertEqual(displayed.count, 3, "an empty currentPersistentID must leave the list unfiltered, not blanket-match every empty-ID row")
    }

    func test_libraryCurrentTrack_doesNotAffectUnrelatedEmptyIDRows() {
        let history = [entry("current"), entry(""), entry("")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentPersistentID: "current")

        XCTAssertEqual(displayed.map(\.persistentID), ["", ""], "only the actual current-track row should be removed")
    }
}
