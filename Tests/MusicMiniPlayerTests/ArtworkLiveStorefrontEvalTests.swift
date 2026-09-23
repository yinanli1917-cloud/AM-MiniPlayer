/**
 * [INPUT]: MusicMiniPlayerCore MusicController.fetchArtworkViaITunesAPIDetailed
 *          (real `.live` transport, real network)
 * [OUTPUT]: One-shot, opt-in acceptance eval for the 2026-09-22 multi-
 *           storefront artwork fix
 * [POS]: Test module, but NOT part of the normal suite. Gated behind
 *        NANOPOD_LIVE_ARTWORK_EVAL=1 (mirrors the existing NANOPOD_LIVE_TESTS
 *        gate in LyricsKindTests.swift) because it hits the real iTunes
 *        Search API for 26 real songs with a >=4s gap between each to stay
 *        under iTunes' own rate limit (research/diagnosis-2026-09-22-radio-
 *        artwork.md: non-JSON rejections after ~25 requests/minute).
 *
 *        Coordinator's ask: run this ONCE against the 18 tracks that failed
 *        in today's real capture plus 8 controls that succeeded, using
 *        now-playing priority (the real production path for the visible
 *        track), and record hit/miss, winning storefront, matched
 *        trackName/artistName/collectionName, and latency — flagging any
 *        hit whose matched song is NOT the same song as requested (wrong
 *        art is worse than no art).
 */

import XCTest
@testable import MusicMiniPlayerCore

final class ArtworkLiveStorefrontEvalTests: XCTestCase {

    private struct EvalTrack {
        let title: String
        let artist: String
        /// Whether this track failed to get artwork in today's real capture.
        let failedToday: Bool
    }

    /// Album is passed "" for every track: `fetchArtwork`'s own now-playing
    /// call site (`MusicController+Artwork.swift`'s Path 1) receives album
    /// from Music.app's radio metadata, but the debug log's `fetchArtwork:
    /// <title> - <artist> gen=N` line never includes album, and radio
    /// metadata routinely reports it empty/absent for streamed tracks —
    /// mirroring that here (album is NOT part of the search term; it only
    /// contributes to `scoreArtworkCandidate`'s reliability check, and
    /// title+artist alone already satisfy that gate for every track below).
    private static let failedToday: [EvalTrack] = [
        EvalTrack(title: "Tell Me Oh Mama", artist: "Naoko Gushima", failedToday: true),
        EvalTrack(title: "some (feat. LiI Boi)", artist: "SoYou & Junggigo", failedToday: true),
        EvalTrack(title: "Let's Stay In Tonight", artist: "Brian Culbertson", failedToday: true),
        EvalTrack(title: "Jellyfish (feat. Michael Seyer)", artist: "Sunset Rollercoaster", failedToday: true),
        EvalTrack(title: "春天", artist: "Xun Zhou", failedToday: true),
        EvalTrack(title: "Time After Time", artist: "Sarah Menescal", failedToday: true),
        EvalTrack(title: "Roland Reve (From \"Lola\")", artist: "Jacqueline Danno", failedToday: true),
        EvalTrack(title: "SHYNESS BOY", artist: "Anri", failedToday: true),
        EvalTrack(title: "Starlight Ballet", artist: "Piper", failedToday: true),
        EvalTrack(title: "Gatsby Woman (2020 Remastered)", artist: "Kingo Hamada", failedToday: true),
        EvalTrack(title: "Who Are You? (DJ Version) [2022 Remaster]", artist: "Fujimaru Yoshino", failedToday: true),
        EvalTrack(title: "Gatsby Woman", artist: "Hamada Kingo", failedToday: true),
        EvalTrack(title: "葉子 (電視劇《薔薇之戀》原聲帶版)", artist: "A-Sun", failedToday: true),
        EvalTrack(title: "Ripples", artist: "Danny Chan", failedToday: true),
        EvalTrack(title: "Misty (feat. Glenn Osser and His Orchestra)", artist: "Johnny Mathis", failedToday: true),
        EvalTrack(title: "Second Love", artist: "Akina Nakamori", failedToday: true),
        EvalTrack(title: "A House Is Not a Home (French & English)", artist: "Dionne Warwick", failedToday: true),
        EvalTrack(title: "Oceanside Café", artist: "CinCin Lee", failedToday: true),
    ]

    private static let controls: [EvalTrack] = [
        EvalTrack(title: "Supernatural", artist: "NewJeans", failedToday: false),
        EvalTrack(title: "啟程", artist: "Christine Fan", failedToday: false),
        EvalTrack(title: "Yume No Tsuzuki (2017 Remaster)", artist: "Mariya Takeuchi", failedToday: false),
        EvalTrack(title: "Private Beach", artist: "Meiko Nakahara", failedToday: false),
        EvalTrack(title: "If You Want It", artist: "Niteflyte", failedToday: false),
        EvalTrack(title: "Mc's Road De Aimasho", artist: "Kazuhito Murata", failedToday: false),
        EvalTrack(title: "Soiree", artist: "Bill Evans", failedToday: false),
        EvalTrack(title: "Where Is My Mind", artist: "Jacques Astor", failedToday: false),
    ]

    /// Loose "is this even plausibly the same song" check for the report's
    /// wrong-match flag — NOT a replacement for a human reading the printed
    /// table. A wrong match is one where the matched trackName/artistName
    /// share essentially nothing with what was requested.
    private func looksLikeSameSong(requestedTitle: String, requestedArtist: String, match: MusicController.ITunesArtworkMatch) -> Bool {
        let score = MusicController.scoreArtworkCandidate(
            title: requestedTitle, artist: requestedArtist, album: "",
            candidateTitle: match.trackName, candidateArtist: match.artistName, candidateAlbum: match.collectionName
        )
        return score.isReliable
    }

    func testLiveArtworkEval_18FailedTracksPlus8Controls() async throws {
        guard ProcessInfo.processInfo.environment["NANOPOD_LIVE_ARTWORK_EVAL"] == "1" else {
            throw XCTSkip("NANOPOD_LIVE_ARTWORK_EVAL=1 not set — skipping live network eval")
        }

        let allTracks = Self.failedToday + Self.controls
        // A fresh breaker for this eval run only — must never share process
        // state with `.shared` (which real app usage on this machine may
        // have already tripped), and must never let one eval run's rate
        // limiting silently swallow the rest of ITS OWN tracks either;
        // that's exactly what >=4s spacing between tracks is for.
        let breaker = MusicController.ArtworkITunesCircuitBreaker()

        var rows: [String] = []
        rows.append("| Track (was failing?) | Artist | Result | Storefront | Matched trackName / artistName / collectionName | Latency (ms) | Same song? |")
        rows.append("|---|---|---|---|---|---:|---|")

        var hitCount = 0
        var wrongMatchCount = 0

        for (index, track) in allTracks.enumerated() {
            let start = Date()
            let match = await MusicController.fetchArtworkViaITunesAPIDetailed(
                title: track.title, artist: track.artist, album: "",
                priority: .nowPlaying, breaker: breaker
            )
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

            if let match {
                hitCount += 1
                let sameSong = looksLikeSameSong(requestedTitle: track.title, requestedArtist: track.artist, match: match)
                if !sameSong { wrongMatchCount += 1 }
                rows.append("| \(track.title) (\(track.failedToday ? "failed" : "control")) | \(track.artist) | HIT | \(match.country) | \(match.trackName) / \(match.artistName) / \(match.collectionName) | \(elapsedMs) | \(sameSong ? "yes" : "⚠️ NO — WRONG MATCH") |")
            } else {
                rows.append("| \(track.title) (\(track.failedToday ? "failed" : "control")) | \(track.artist) | miss | — | — | \(elapsedMs) | — |")
            }

            // Stay under iTunes' observed ~25 requests/minute rate limit —
            // coordinator's ask: sleep >=4s between tracks. Skip the sleep
            // after the last track.
            if index < allTracks.count - 1 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }

        let summary = """

        ## Live eval results (\(Date()))
        Hit rate: \(hitCount)/\(allTracks.count) (previously failing subset target: \(Self.failedToday.count)/\(Self.failedToday.count))
        Wrong matches flagged: \(wrongMatchCount)

        \(rows.joined(separator: "\n"))
        """
        print(summary)
        // Intentionally no XCTAssert on hit rate: this is a recorded
        // real-world measurement for the spec's 结果 section, not a
        // pass/fail gate — iTunes catalog availability can change over time
        // and the point is to capture today's real numbers, wrong-match
        // flags included, not to make CI flaky against a live third party.
    }
}
