/**
 * [INPUT]: MusicMiniPlayerCore MusicController.{shouldClearQueueRows, shouldSkipQueueApply,
 *          shouldAbortScan, provenance(for:), sameTrackIdentity}
 * [OUTPUT]: Unit tests for D4 queue-sync hardening decisions (WT-D D4, 2026-09-11):
 *           SB timeout must not be mistaken for an empty/unavailable queue, and the
 *           recent-history scan must abort on a stale generation the same way the
 *           Up Next scan already does.
 * [POS]: Test module. Pure mappings only — no ScriptingBridge, no SwiftUI, no live app.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class QueueSyncHardeningTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - shouldSkipQueueApply(for:) — SB timeout keeps existing rows
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_shouldSkipQueueApply_timedOut_isTrue() {
        XCTAssertTrue(MusicController.shouldSkipQueueApply(for: .timedOut))
    }

    func test_shouldSkipQueueApply_everyOtherOutcome_isFalse() {
        let outcomes: [MusicController.QueueFetchOutcome] = [
            .success(playlistName: "Library"),
            .success(playlistName: nil),
            .noCurrentPlaylist,
            .noCurrentTrack,
            .appUnavailable
        ]
        for outcome in outcomes {
            XCTAssertFalse(
                MusicController.shouldSkipQueueApply(for: outcome),
                "\(outcome) must be applied, not skipped"
            )
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - shouldClearQueueRows(for:) — ghost-row cleanup on real unavailability
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_shouldClearQueueRows_appUnavailable_clearsRows() {
        // Music.app quit / not running: the residual Up Next / Recent rows from
        // the previous session must not linger as a ghost queue.
        XCTAssertTrue(MusicController.shouldClearQueueRows(for: .appUnavailable))
    }

    func test_shouldClearQueueRows_noCurrentTrack_clearsRows() {
        // Nothing is playing: no track identity to anchor a queue against.
        XCTAssertTrue(MusicController.shouldClearQueueRows(for: .noCurrentTrack))
    }

    func test_shouldClearQueueRows_noCurrentPlaylist_clearsRows() {
        // Radio / Apple Music streaming URL tracks expose no public queue object.
        XCTAssertTrue(MusicController.shouldClearQueueRows(for: .noCurrentPlaylist))
    }

    func test_shouldClearQueueRows_success_doesNotForceClear() {
        // A successful fetch replaces rows with whatever it found (including
        // legitimately empty at end-of-playlist) — clearing is not this
        // function's job for success, `applyUpNextTracksIfChanged` already
        // diffs against the fetched (possibly empty) snapshot.
        XCTAssertFalse(MusicController.shouldClearQueueRows(for: .success(playlistName: "Library")))
    }

    func test_shouldClearQueueRows_timedOut_doesNotClear() {
        // The core of the D4 fix: a slow SB read is not evidence the queue is
        // gone. Clearing on timeout would flash away a perfectly valid queue
        // every time Music.app's IPC is briefly slow.
        XCTAssertFalse(MusicController.shouldClearQueueRows(for: .timedOut))
    }

    func test_shouldClearQueueRows_libraryToRadioContextChange_clearsRows() {
        // §5 item 3 / audit (d): switching from a library playlist to a radio
        // station lands on `.noCurrentPlaylist` on the very next fetch — that
        // transition must clear the previous library queue's rows.
        XCTAssertFalse(MusicController.shouldClearQueueRows(for: .success(playlistName: "Library")))
        XCTAssertTrue(MusicController.shouldClearQueueRows(for: .noCurrentPlaylist))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - shouldAbortScan(capturedGeneration:currentGeneration:)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_shouldAbortScan_sameGeneration_isFalse() {
        XCTAssertFalse(MusicController.shouldAbortScan(capturedGeneration: 5, currentGeneration: 5))
    }

    func test_shouldAbortScan_differentGeneration_isTrue() {
        // A track change bumped `artworkFetchGeneration` mid-scan — both the
        // Up Next scan and the Recent scan must abort identically rather than
        // iterate over now-stale SBElementArray objects.
        XCTAssertTrue(MusicController.shouldAbortScan(capturedGeneration: 5, currentGeneration: 6))
        XCTAssertTrue(MusicController.shouldAbortScan(capturedGeneration: 0, currentGeneration: 1))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Apply-decision drive: pure simulation of the fetch-result handler
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private typealias Track = (title: String, artist: String, album: String, persistentID: String, duration: Double)

    /// Mirrors the decision `fetchUpNextViaBridge`'s MainActor apply block
    /// makes: given a previous row set, a fetch's tracks + outcome, decide
    /// the resulting rows and whether provenance should be updated. Pure —
    /// no MusicController instance, no ScriptingBridge.
    private func applyFetchResult(
        previousRows: [Track],
        fetchedTracks: [Track],
        outcome: MusicController.QueueFetchOutcome
    ) -> (rows: [Track], provenanceUpdated: Bool) {
        guard !MusicController.shouldSkipQueueApply(for: outcome) else {
            return (previousRows, false)
        }
        if MusicController.sameTrackIdentity(previousRows, fetchedTracks) {
            return (previousRows, true)
        }
        return (fetchedTracks, true)
    }

    func test_applyFetchResult_timeout_keepsPreviousRowsAndSkipsProvenance() {
        let previous: [Track] = [("Song A", "Artist A", "Album A", "id-a", 180)]
        let result = applyFetchResult(previousRows: previous, fetchedTracks: [], outcome: .timedOut)
        XCTAssertEqual(result.rows.map(\.persistentID), previous.map(\.persistentID))
        XCTAssertFalse(result.provenanceUpdated)
    }

    func test_applyFetchResult_appUnavailable_clearsRowsAndUpdatesProvenance() {
        let previous: [Track] = [("Song A", "Artist A", "Album A", "id-a", 180)]
        let result = applyFetchResult(previousRows: previous, fetchedTracks: [], outcome: .appUnavailable)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.provenanceUpdated)
    }

    func test_applyFetchResult_successWithNewTracks_replacesRows() {
        let previous: [Track] = [("Song A", "Artist A", "Album A", "id-a", 180)]
        let fetched: [Track] = [("Song B", "Artist B", "Album B", "id-b", 200)]
        let result = applyFetchResult(previousRows: previous, fetchedTracks: fetched, outcome: .success(playlistName: "Library"))
        XCTAssertEqual(result.rows.map(\.persistentID), ["id-b"])
        XCTAssertTrue(result.provenanceUpdated)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Live preview MusicController: upNextTracks is the real @Published surface
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @MainActor
    func test_previewController_upNextTracksIsAssignableWithoutScriptingBridge() {
        // Exercises the real @Published upNextTracks surface on a preview
        // (non-ScriptingBridge) controller — the same property the timeout
        // path leaves untouched and the unavailable path clears to [].
        let controller = MusicController(preview: true)
        controller.upNextTracks = [("Song A", "Artist A", "Album A", "id-a", 180)]
        XCTAssertEqual(controller.upNextTracks.count, 1)
        controller.upNextTracks = []
        XCTAssertTrue(controller.upNextTracks.isEmpty)
    }
}
