/**
 * [INPUT]: MusicMiniPlayerCore LyricsFetcher.buildCandidates + SearchParams
 * [OUTPUT]: Unit tests for the duration-unknown (radio/URL stream) matching mode
 * [POS]: Test module. Pins the 2026-07-19 radio diagnosis: URL/radio tracks
 *        report duration 0, and `durationDiff = |candidate - 0|` exceeded the
 *        45s hard limit for every real song — lyrics were a guaranteed miss on
 *        radio no matter how good the title/artist match. Rule: an unknown
 *        duration is an ABSENT signal, not a perfect one — admission then
 *        requires BOTH text signals (title AND artist), honoring the
 *        three-rule principle with the remaining two signals mandatory.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class RadioDurationlessMatchingTests: XCTestCase {

    private let fetcher = LyricsFetcher.shared

    private func extract(_ song: [String: Any]) -> (id: Int, name: String, artist: String, duration: Double, album: String)? {
        guard let id = song["id"] as? Int,
              let name = song["name"] as? String,
              let artist = song["artist"] as? String,
              let duration = song["duration"] as? Double,
              let album = song["album"] as? String else { return nil }
        return (id, name, artist, duration, album)
    }

    private func candidates(duration: TimeInterval, songs: [[String: Any]]) -> [LyricsFetcher.SearchCandidate<Int>] {
        let params = LyricsFetcher.SearchParams(
            title: "Vivre Pour Vivre",
            artist: "Francis Lai",
            originalTitle: "Vivre Pour Vivre",
            originalArtist: "Francis Lai",
            duration: duration,
            album: ""
        )
        return fetcher.buildCandidates(songs: songs, params: params, searchDescriptor: "title+artist", extractSong: extract)
    }

    private var fullMatchSong: [String: Any] {
        ["id": 1, "name": "Vivre Pour Vivre", "artist": "Francis Lai", "duration": 191.0, "album": "Vivre Pour Vivre"]
    }

    func test_unknownDuration_admitsTitleArtistMatch() {
        // Radio: params.duration == 0; the 191s candidate used to be vetoed by
        // the duration limit (|191 - 0| > 45) before selection ever ran.
        let result = candidates(duration: 0, songs: [fullMatchSong])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].titleMatch)
        XCTAssertTrue(result[0].artistMatch)
    }

    func test_unknownDuration_rejectsTitleOnlyMatch() {
        // With the duration signal absent, BOTH remaining signals are mandatory:
        // a title-only collision must not slip in (three-rule principle).
        let titleOnly: [String: Any] =
            ["id": 2, "name": "Vivre Pour Vivre", "artist": "Hatsune Miku", "duration": 191.0, "album": "X"]
        XCTAssertTrue(candidates(duration: 0, songs: [titleOnly]).isEmpty)
    }

    func test_unknownDuration_rejectsArtistOnlyMatch() {
        let artistOnly: [String: Any] =
            ["id": 3, "name": "Un Homme Et Une Femme", "artist": "Francis Lai", "duration": 191.0, "album": "X"]
        XCTAssertTrue(candidates(duration: 0, songs: [artistOnly]).isEmpty)
    }

    func test_knownDuration_gateUnchanged() {
        // A known duration keeps today's hard limit: a 191s candidate against a
        // 300s request is still vetoed even with title+artist matching.
        XCTAssertTrue(candidates(duration: 300, songs: [fullMatchSong]).isEmpty)
        // And a close duration still admits.
        XCTAssertEqual(candidates(duration: 190, songs: [fullMatchSong]).count, 1)
    }
}
