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

    func test_provenance_noCurrentPlaylistForTrackClass_mapsToUnavailableWithTrackClass() {
        // AM catalog content (URL track): currentPlaylist resolves to an unresolved
        // SBObject proxy whose .name silently reads nil, but the track's own `kind`
        // string was readable — carry it through for the source-specific message.
        let provenance = MusicController.provenance(for: .noCurrentPlaylistForTrackClass("URL track"))
        XCTAssertEqual(provenance, .unavailable(reason: .noCurrentPlaylistForTrackClass("URL track")))
        XCTAssertTrue(provenance.isUnavailable)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - MusicController.classifyPlaylistProxy(playlistName:trackCount:currentTrackKind:)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_classifyPlaylistProxy_nilName_withTrackClass_isNoCurrentPlaylistForTrackClass() {
        // Real-machine finding (docs/wt-d-queue-source-matrix-2026-09-12.md): Apple
        // Music catalog content (URL track) resolves `currentPlaylist` to a live but
        // unresolved SBObject proxy — `.name` reads back nil, `.tracks.count` is 0,
        // no exception, `lastError` stays nil. Must not be read as a real, empty playlist.
        let outcome = MusicController.classifyPlaylistProxy(playlistName: nil, trackCount: 0, currentTrackKind: "URL track")
        XCTAssertEqual(outcome, .noCurrentPlaylistForTrackClass("URL track"))
    }

    func test_classifyPlaylistProxy_nilName_withoutTrackClass_fallsBackToNoCurrentPlaylist() {
        // Track `kind` itself wasn't readable either — fall back to the generic
        // source-limitation reason rather than inventing a track class.
        let outcome = MusicController.classifyPlaylistProxy(playlistName: nil, trackCount: 0, currentTrackKind: nil)
        XCTAssertEqual(outcome, .noCurrentPlaylist)
    }

    func test_classifyPlaylistProxy_blankTrackClass_fallsBackToNoCurrentPlaylist() {
        let outcome = MusicController.classifyPlaylistProxy(playlistName: nil, trackCount: 0, currentTrackKind: "   ")
        XCTAssertEqual(outcome, .noCurrentPlaylist)
    }

    func test_classifyPlaylistProxy_nonNilName_zeroTracks_isSuccessNotUnavailable() {
        // A genuinely empty library playlist is a real empty queue, not "unavailable" —
        // trackCount == 0 alone must never trigger the unresolved-proxy path.
        let outcome = MusicController.classifyPlaylistProxy(playlistName: "Empty Playlist", trackCount: 0, currentTrackKind: "file track")
        XCTAssertEqual(outcome, .success(playlistName: "Empty Playlist"))
    }

    func test_classifyPlaylistProxy_nonNilName_withTracks_isSuccess() {
        let outcome = MusicController.classifyPlaylistProxy(playlistName: "Piano Chronicle", trackCount: 217, currentTrackKind: "shared track")
        XCTAssertEqual(outcome, .success(playlistName: "Piano Chronicle"))
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

    func test_messageKey_emptyAndNoCurrentPlaylistForTrackClass_explainsNoQueueForSource() {
        XCTAssertEqual(
            UpNextEmptyState.messageKey(provenance: .unavailable(reason: .noCurrentPlaylistForTrackClass("URL track")), isEmpty: true),
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

    func test_messageKey_emptyAndNonSourceUnavailableReasons_areGenericQueueEmpty() {
        // Startup default (pendingPublicRefresh), nothing playing (noCurrentTrack),
        // and Music.app not running (musicAppUnavailable) are not "this source
        // exposes no queue" — they must not claim a source limitation.
        for reason: MusicQueueUnavailableReason in [.pendingPublicRefresh, .noCurrentTrack, .musicAppUnavailable] {
            XCTAssertEqual(
                UpNextEmptyState.messageKey(provenance: .unavailable(reason: reason), isEmpty: true),
                "queueEmpty"
            )
        }
    }
}
