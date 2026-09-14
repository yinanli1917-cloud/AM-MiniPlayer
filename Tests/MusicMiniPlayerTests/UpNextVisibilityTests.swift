/**
 * [INPUT]: MusicMiniPlayerCore.UpNextVisibility / MusicQueueProvenance
 * [OUTPUT]: Unit tests — all provenance × shuffle combinations
 * [POS]: Test module (WT-D plan H3, founder ruling 2026-09-13)
 */

import XCTest
@testable import MusicMiniPlayerCore

final class UpNextVisibilityTests: XCTestCase {

    func test_playlistContextOnly_shuffleOff_shown() {
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .playlistContextOnly(playlistName: "Library"), shuffleEnabled: false),
            .shown
        )
    }

    func test_playlistContextOnly_noPlaylistName_shuffleOff_shown() {
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .playlistContextOnly(playlistName: nil), shuffleEnabled: false),
            .shown
        )
    }

    func test_playlistContextOnly_shuffleOn_hiddenShuffle() {
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .playlistContextOnly(playlistName: "Library"), shuffleEnabled: true),
            .hidden(reason: .shuffle)
        )
    }

    func test_preview_shuffleOff_shown() {
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .preview, shuffleEnabled: false),
            .shown
        )
    }

    func test_preview_shuffleOn_hiddenShuffle() {
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .preview, shuffleEnabled: true),
            .hidden(reason: .shuffle)
        )
    }

    func test_exactPublicMusicQueue_shuffleOff_hiddenNoQueue() {
        // Founder ruling names ONLY the playlist-context case as exact; the
        // Music.app "exact public queue" provenance is a different source and
        // must NOT show Up Next despite its name.
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .exactPublicMusicQueue(context: "radio"), shuffleEnabled: false),
            .hidden(reason: .sourceHasNoQueue)
        )
    }

    func test_exactPublicMusicQueue_shuffleOn_hiddenNoQueue() {
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .exactPublicMusicQueue(context: "radio"), shuffleEnabled: true),
            .hidden(reason: .sourceHasNoQueue)
        )
    }

    func test_appleMusicAccountRecentlyPlayed_hiddenNoQueue() {
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .appleMusicAccountRecentlyPlayed, shuffleEnabled: false),
            .hidden(reason: .sourceHasNoQueue)
        )
        XCTAssertEqual(
            UpNextVisibility.decide(provenance: .appleMusicAccountRecentlyPlayed, shuffleEnabled: true),
            .hidden(reason: .sourceHasNoQueue)
        )
    }

    func test_unavailable_anyReason_hiddenNoQueue_regardlessOfShuffle() {
        let reasons: [MusicQueueUnavailableReason] = [
            .noPublicQueueObject,
            .noCurrentPlaylistForTrackClass("URL track"),
            .publicSourceUnverified,
            .musicAppUnavailable,
            .noCurrentTrack,
            .pendingPublicRefresh
        ]
        for reason in reasons {
            XCTAssertEqual(
                UpNextVisibility.decide(provenance: .unavailable(reason: reason), shuffleEnabled: false),
                .hidden(reason: .sourceHasNoQueue),
                "reason: \(reason)"
            )
            XCTAssertEqual(
                UpNextVisibility.decide(provenance: .unavailable(reason: reason), shuffleEnabled: true),
                .hidden(reason: .sourceHasNoQueue),
                "reason: \(reason)"
            )
        }
    }
}
