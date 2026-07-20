/**
 * [INPUT]: MusicMiniPlayerCore MusicController.shouldConfirmSnapshotTrackChange
 * [OUTPUT]: Unit tests for the radio track-change confirmation debounce
 * [POS]: Test module. Pins the 2026-07-19 radio loop: URL/radio tracks have no
 *        persistentID to arbitrate identity, and the 1s backstop asserted a
 *        track change on a SINGLE differing AppleScript read — stream-buffering
 *        title transitions each re-ran the full artwork+lyrics pipeline and
 *        blanked the page. Rule: an identity WITHOUT a PID must survive two
 *        consecutive reads before it counts as a track change.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class RadioTrackChangeDebounceTests: XCTestCase {

    func test_pidArbitratedTracks_confirmImmediately() {
        XCTAssertTrue(MusicController.shouldConfirmSnapshotTrackChange(
            requiresConfirmation: false,
            candidateTitle: "New Song", candidateArtist: "Artist",
            pendingTitle: nil, pendingArtist: nil))
    }

    func test_radio_firstSighting_isNotConfirmed() {
        XCTAssertFalse(MusicController.shouldConfirmSnapshotTrackChange(
            requiresConfirmation: true,
            candidateTitle: "New Song", candidateArtist: "Artist",
            pendingTitle: nil, pendingArtist: nil))
    }

    func test_radio_secondIdenticalSighting_confirms() {
        XCTAssertTrue(MusicController.shouldConfirmSnapshotTrackChange(
            requiresConfirmation: true,
            candidateTitle: "New Song", candidateArtist: "Artist",
            pendingTitle: "New Song", pendingArtist: "Artist"))
    }

    func test_radio_differentSighting_restartsConfirmation() {
        // Buffering transition: "Station Name" then the real title — neither
        // single sighting may fire the pipeline.
        XCTAssertFalse(MusicController.shouldConfirmSnapshotTrackChange(
            requiresConfirmation: true,
            candidateTitle: "Real Title", candidateArtist: "Artist",
            pendingTitle: "Station Name", pendingArtist: ""))
    }
}
