/**
 * [INPUT]: MusicMiniPlayerCore MusicController.provenance(for:), UpNextEmptyState
 * [OUTPUT]: Unit tests for the queue-provenance decision and the empty-state
 *           copy it selects (D3: explain empty Up Next on radio/stream sources)
 * [POS]: Test module. Pure mappings only — no ScriptingBridge, no SwiftUI.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class QueueProvenanceEmptyStateTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - MusicController.provenance(for:)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_provenance_success_mapsToPlaylistContextOnly() {
        let provenance = MusicController.provenance(for: .success(playlistName: "Library"))
        XCTAssertEqual(provenance, .playlistContextOnly(playlistName: "Library"))
    }

    func test_provenance_noCurrentPlaylist_mapsToUnavailableNoPublicQueueObject() {
        // Radio stations / Apple Music streaming URL tracks: Music.app throws
        // "Can't get current playlist" — this is the case the empty-state copy
        // must explain, not a generic "queue is empty".
        let provenance = MusicController.provenance(for: .noCurrentPlaylist)
        XCTAssertEqual(provenance, .unavailable(reason: .noPublicQueueObject))
        XCTAssertTrue(provenance.isUnavailable)
    }

    func test_provenance_noCurrentTrack_mapsToUnavailableNoCurrentTrack() {
        let provenance = MusicController.provenance(for: .noCurrentTrack)
        XCTAssertEqual(provenance, .unavailable(reason: .noCurrentTrack))
    }

    func test_provenance_appUnavailable_mapsToUnavailableMusicAppUnavailable() {
        let provenance = MusicController.provenance(for: .appUnavailable)
        XCTAssertEqual(provenance, .unavailable(reason: .musicAppUnavailable))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - UpNextEmptyState.messageKey(provenance:isEmpty:)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_messageKey_notEmpty_isQueueEmptyRegardlessOfProvenance() {
        // Rows are present: the key is irrelevant to rendering, but must stay
        // deterministic rather than reading the unavailable provenance as a signal.
        XCTAssertEqual(
            UpNextEmptyState.messageKey(provenance: .unavailable(reason: .noPublicQueueObject), isEmpty: false),
            "queueEmpty"
        )
    }

    func test_messageKey_emptyAndUnavailable_explainsNoQueueForSource() {
        XCTAssertEqual(
            UpNextEmptyState.messageKey(provenance: .unavailable(reason: .noPublicQueueObject), isEmpty: true),
            "queueUnavailableForSource"
        )
    }

    func test_messageKey_emptyAndPlaylistContext_isGenericQueueEmpty() {
        // Fetch succeeded (playlist context resolved) but the queue is genuinely
        // empty (end of playlist) — generic copy, not the source-limitation message.
        XCTAssertEqual(
            UpNextEmptyState.messageKey(provenance: .playlistContextOnly(playlistName: "Library"), isEmpty: true),
            "queueEmpty"
        )
    }

    func test_messageKey_emptyAndPreview_isGenericQueueEmpty() {
        XCTAssertEqual(UpNextEmptyState.messageKey(provenance: .preview, isEmpty: true), "queueEmpty")
    }
}
