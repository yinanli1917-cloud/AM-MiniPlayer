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

/// 2026-09-25 diagnosis fix (H1): `displayed` used to filter EVERY entry
/// whose persistentID matched the current track, not just the row that
/// duplicates the Now Playing card — an A→B→A repeat listen made the
/// earlier, already-finished play of A vanish from History too. The fix
/// only ever considers `history.first` (the newest row): once
/// PendingPlaybackAccumulator only inserts a row on qualification, "the row
/// for THIS play" is structurally always the newest entry when it IS the
/// currently-playing identity — see research/diagnosis-2026-09-25-history.md §H1.
final class PlaybackHistoryDisplayPolicyTests: XCTestCase {

    private func entry(_ id: String, title: String = "T", artist: String = "A", startedAt: Date = Date()) -> PlaybackHistoryEntry {
        PlaybackHistoryEntry(
            persistentID: id, title: title, artist: artist, album: "Al",
            duration: 200, sourceKind: id.isEmpty ? .radioOrStream : .library,
            startedAt: startedAt
        )
    }

    // MARK: - Only `history.first` is ever considered

    func test_newestRow_matchesCurrentPID_isHidden() {
        let history = [entry("current"), entry("older1"), entry("older2")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "T", currentArtist: "A", currentPersistentID: "current")

        XCTAssertEqual(displayed.map(\.persistentID), ["older1", "older2"])
    }

    /// The regression pin for H1 itself: A→B→A. The earlier, already-finished
    /// play of A shares A's persistentID with the CURRENT (newest) row, but
    /// only the newest row may be hidden.
    func test_earlierPlayOfCurrentSong_staysVisible_onlyNewestRowHidden() {
        let earlierA = entry("SONG_A", title: "Song A", startedAt: Date(timeIntervalSince1970: 1000))
        let songB = entry("SONG_B", title: "Song B", startedAt: Date(timeIntervalSince1970: 2000))
        let currentA = entry("SONG_A", title: "Song A", startedAt: Date(timeIntervalSince1970: 3000))
        let history = [currentA, songB, earlierA] // newest-first

        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "Song A", currentArtist: "A", currentPersistentID: "SONG_A")

        XCTAssertEqual(displayed.count, 2, "only the newest Song A row (duplicating Now Playing) is hidden")
        XCTAssertTrue(displayed.contains(where: { $0.startedAt == earlierA.startedAt }), "the earlier, already-finished play of Song A must remain visible")
        XCTAssertFalse(displayed.contains(where: { $0.startedAt == currentA.startedAt }))
    }

    /// A history whose newest row happens to share the current PID somewhere
    /// DEEPER (not at index 0) must not have that deeper row hidden either —
    /// proves the policy never scans past `history.first`.
    func test_matchDeeperThanFirst_neverHidden() {
        let history = [entry("other"), entry("current", startedAt: Date(timeIntervalSince1970: 500))]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "T", currentArtist: "A", currentPersistentID: "current")

        XCTAssertEqual(displayed.count, 2, "the current PID only appears at index 1 (not the newest row) — nothing should be hidden")
    }

    func test_currentTrack_notInHistoryYet_leavesHistoryUnchanged() {
        let history = [entry("older1"), entry("older2")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "Something Else", currentArtist: "Nobody", currentPersistentID: "current")

        XCTAssertEqual(displayed.map(\.persistentID), ["older1", "older2"])
    }

    func test_emptyHistory_returnsEmpty() {
        XCTAssertTrue(PlaybackHistoryDisplayPolicy.displayed(history: [], currentTitle: "T", currentArtist: "A", currentPersistentID: "x").isEmpty)
    }

    // MARK: - PID authoritative when both sides known; else title+artist fallback

    func test_nilCurrentPersistentID_fallsBackToTitleArtist_hidesOnMatch() {
        let history = [entry("a", title: "Song", artist: "Artist")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "Song", currentArtist: "Artist", currentPersistentID: nil)

        XCTAssertTrue(displayed.isEmpty, "no PID available at all (radio/URL current track) — title+artist match must still hide the current row")
    }

    func test_nilCurrentPersistentID_titleArtistDontMatch_leavesUnchanged() {
        let history = [entry("a", title: "Song", artist: "Artist")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "Different Song", currentArtist: "Different Artist", currentPersistentID: nil)

        XCTAssertEqual(displayed.count, 1)
    }

    // MARK: - Empty-persistentID (radio/URL) safety: never blanket-match "" by PID

    func test_emptyCurrentPersistentID_doesNotBlanketMatchByPID_fallsBackToTitleArtist() {
        // Two PAST radio/URL entries, both with "" persistentID. Empty
        // currentPersistentID must not be treated as "a real PID identity"
        // that matches them by PID — but the title+artist fallback still
        // applies (this is the mechanism radio/URL current plays rely on).
        let history = [entry("", title: "Old Radio Song"), entry("lib1")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "Something Currently Playing", currentArtist: "Nobody", currentPersistentID: "")

        XCTAssertEqual(displayed.count, 2, "empty currentPersistentID + non-matching title/artist must leave the list unfiltered")
    }

    func test_libraryCurrentTrack_doesNotAffectUnrelatedEmptyIDRows() {
        let history = [entry("current"), entry(""), entry("")]
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "T", currentArtist: "A", currentPersistentID: "current")

        XCTAssertEqual(displayed.map(\.persistentID), ["", ""], "only the actual current-track row should be removed")
    }

    // MARK: - Display cap (2026-09-27 founder ruling: History shows at most
    // the 10 most recent plays, not counting the currently-playing row —
    // nanoPod is mini, it should not display an ever-growing list)

    /// Regression pin for the pre-fix bug: `displayed(...)` returned the
    /// entire (dedupe-filtered) history uncapped — PlaylistView rendered
    /// every stored entry (up to `PlaybackHistoryStore.capacity`, formerly
    /// 100). This test must FAIL before the cap is added and PASS after.
    func test_moreThan10Entries_onlyMostRecent10AreDisplayed() {
        let history = (0..<15).map { i in
            entry("PID-\(i)", title: "Song \(i)", startedAt: Date(timeIntervalSince1970: Double(1_000_000 - i)))
        } // newest-first, none of them the currently-playing track
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "Not Playing", currentArtist: "Nobody", currentPersistentID: "not-in-history")

        XCTAssertEqual(displayed.count, 10, "at most 10 entries may be displayed")
        XCTAssertEqual(displayed.map(\.persistentID), (0..<10).map { "PID-\($0)" }, "the cap must keep the MOST RECENT 10 (history is newest-first), not an arbitrary slice")
    }

    func test_exactly10Entries_allDisplayed() {
        let history = (0..<10).map { i in entry("PID-\(i)", startedAt: Date(timeIntervalSince1970: Double(1000 - i))) }
        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "Not Playing", currentArtist: "Nobody", currentPersistentID: "not-in-history")

        XCTAssertEqual(displayed.count, 10)
    }

    func test_capAppliesAfterCurrentRowIsHidden_stillShowsFull10() {
        // 11 stored entries, the newest of which IS the currently-playing
        // track (already qualified while still playing — see
        // PendingPlaybackAccumulator). After hiding it, the remaining 10
        // must ALL display — the cap must not double-subtract.
        var history = (0..<10).map { i in entry("OLD-\(i)", startedAt: Date(timeIntervalSince1970: Double(1000 - i))) }
        history.insert(entry("CURRENT", startedAt: Date(timeIntervalSince1970: 2000)), at: 0)

        let displayed = PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "T", currentArtist: "A", currentPersistentID: "CURRENT")

        XCTAssertEqual(displayed.count, 10, "hiding the current row must not also shrink the display cap below 10")
        XCTAssertEqual(displayed.map(\.persistentID), (0..<10).map { "OLD-\($0)" })
    }
}

/// 2026-09-26 founder ruling (research/evidence/2026-09-26-history-order-and-
/// artwork.webp): History must read top-to-bottom OLDEST→NEWEST — the most
/// recently finished play sits immediately above the Now Playing card,
/// matching Music.app's own History ordering. Before this fix,
/// `displayed(...)`'s newest-first order was rendered as-is, so the OLDEST
/// row (not the newest) ended up adjacent to Now Playing. Kept as a separate
/// pure step from `displayed` so that function's own newest-first contract
/// (and every test above pinned to it) is untouched.
final class PlaybackHistoryDisplayPolicyChronologicalTests: XCTestCase {

    private func entry(_ id: String, startedAt: Date = Date()) -> PlaybackHistoryEntry {
        PlaybackHistoryEntry(
            persistentID: id, title: "T-\(id)", artist: "A", album: "Al",
            duration: 200, sourceKind: id.isEmpty ? .radioOrStream : .library,
            startedAt: startedAt
        )
    }

    func test_reversesNewestFirstIntoOldestFirst() {
        // `displayed(...)`'s own contract: index 0 is the newest surviving row.
        let newestFirst = [entry("newest"), entry("mid"), entry("oldest")]

        let chronological = PlaybackHistoryDisplayPolicy.chronological(newestFirst)

        XCTAssertEqual(
            chronological.map(\.persistentID), ["oldest", "mid", "newest"],
            "oldest must render first (top of the History section), newest last (bottom, adjacent to Now Playing)"
        )
    }

    func test_newestEntryIsLastAfterReordering_adjacentToNowPlayingPosition() {
        let newestFirst = [entry("newest"), entry("older1"), entry("older2")]

        let chronological = PlaybackHistoryDisplayPolicy.chronological(newestFirst)

        XCTAssertEqual(chronological.last?.persistentID, "newest", "the ForEach's LAST row is immediately above the Now Playing section in PlaylistView's VStack")
        XCTAssertEqual(chronological.first?.persistentID, "older2")
    }

    func test_singleEntry_unaffected() {
        let single = [entry("only")]
        XCTAssertEqual(PlaybackHistoryDisplayPolicy.chronological(single).map(\.persistentID), ["only"])
    }

    func test_emptyList_returnsEmpty() {
        XCTAssertTrue(PlaybackHistoryDisplayPolicy.chronological([]).isEmpty)
    }

    /// Composition as `PlaylistView.displayedPlaybackHistory` actually calls
    /// it: `chronological(displayed(...))`. The currently-playing row is
    /// still hidden (unchanged semantics), and everything left over renders
    /// oldest-first.
    func test_composedWithDisplayed_currentRowHidden_remainderOldestFirst() {
        let history = [
            entry("current", startedAt: Date(timeIntervalSince1970: 3000)), // newest, now playing
            entry("mid", startedAt: Date(timeIntervalSince1970: 2000)),
            entry("oldest", startedAt: Date(timeIntervalSince1970: 1000))
        ]

        let result = PlaybackHistoryDisplayPolicy.chronological(
            PlaybackHistoryDisplayPolicy.displayed(history: history, currentTitle: "T", currentArtist: "A", currentPersistentID: "current")
        )

        XCTAssertEqual(result.map(\.persistentID), ["oldest", "mid"], "current row hidden; remainder oldest-first, newest ('mid') last")
    }
}
