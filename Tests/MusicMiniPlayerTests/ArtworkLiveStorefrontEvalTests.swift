/**
 * [INPUT]: MusicMiniPlayerCore MusicController.fetchArtworkViaITunesAPIDetailed
 *          (real `.live` transport, real network)
 * [OUTPUT]: One-shot, opt-in acceptance eval for the 2026-09-22 multi-
 *           storefront artwork fix
 * [POS]: Test module, but NOT part of the normal suite. Gated behind
 *        NANOPOD_LIVE_ARTWORK_EVAL=1 (mirrors the existing NANOPOD_LIVE_TESTS
 *        gate in LyricsKindTests.swift) because it hits the real iTunes
 *        Search API.
 *
 *        2026-09-22 coordinator revision after the first real run (5/26
 *        hits, then iTunes 403'd again immediately after): plain hit/miss
 *        cannot be trusted once a run is anywhere near iTunes' rate limit —
 *        a miss returned in 130-400ms is indistinguishable from a
 *        rate-limited rejection. This version wraps the REAL `.live`
 *        transport (not a second network path) to record every individual
 *        storefront request's raw outcome (HTTP status / empty / non-JSON /
 *        timeout / hit) plus whether the circuit breaker was open at that
 *        moment, classifies a track as HIT / miss / INVALID (rate-limited)
 *        accordingly (a miss that saw ANY rate-limit-shaped storefront
 *        response is INVALID, excluded from the hit-rate denominator — a
 *        real HIT still counts as HIT even if some other storefront in the
 *        same track's requests was rate-limited), and aborts the whole eval
 *        the moment 2 CONSECUTIVE tracks come back rate-limited so it never
 *        keeps hammering an already-blocked host. Spacing between tracks is
 *        `NANOPOD_LIVE_ARTWORK_EVAL_SPACING` seconds (default 60, up from
 *        the first version's fixed 4s — still not enough to stay under
 *        iTunes' ~30-requests-per-~2-minutes budget on its own, which is
 *        exactly why the outcome-aware classification + abort exist).
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

    /// Default spacing (seconds) if `NANOPOD_LIVE_ARTWORK_EVAL_SPACING` is
    /// unset. iTunes' observed budget is ~30 requests per ~2 minutes; even
    /// spaced 60s apart, a single track's own request burst (up to 8
    /// storefront searches across 2 rounds) can still trip it — that's
    /// exactly why classification + early-abort exist rather than relying
    /// on spacing alone to stay under the limit.
    private static let defaultSpacingSeconds: Double = 60

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Per-storefront-request outcome recording (wraps the REAL .live transport)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private struct StorefrontRequestOutcome {
        let country: String
        /// "hit (N)" / "empty" / "HTTP 403" / "non-JSON" / "timeout" / "error(Type): description"
        let description: String
        let isRateLimitShaped: Bool
        let breakerWasOpenAtRequestTime: Bool
    }

    /// Actor because now-playing priority fans out storefronts in TRUE
    /// parallel child tasks — a plain class recorder mutated from 4
    /// concurrent closures is a real data race (this crashed a similarly-
    /// shaped test harness once already in ArtworkStorefrontSelectionTests'
    /// history; see that file's TransportHarness comment).
    private actor OutcomeRecorder {
        private(set) var outcomes: [StorefrontRequestOutcome] = []

        func reset() {
            outcomes.removeAll()
        }

        func record(_ outcome: StorefrontRequestOutcome) {
            outcomes.append(outcome)
        }
    }

    /// Classifies a raw transport `Result` into the outcome vocabulary the
    /// coordinator asked for: HTTP status / empty / non-JSON / timeout / hit.
    private func classify(_ result: Result<[[String: Any]], Error>) -> (description: String, isRateLimitShaped: Bool) {
        switch result {
        case .success(let results):
            return results.isEmpty ? ("empty", false) : ("hit (\(results.count))", false)
        case .failure(let error):
            let isRateLimit = MusicController.isITunesRateLimitSignal(error)
            if let httpError = error as? HTTPClient.HTTPError {
                switch httpError {
                case .httpError(let code): return ("HTTP \(code)", isRateLimit)
                case .decodingFailed: return ("non-JSON", isRateLimit)
                case .notFound: return ("HTTP 404", isRateLimit)
                case .invalidResponse: return ("invalid-response", isRateLimit)
                case .noData: return ("no-data", isRateLimit)
                case .invalidURL: return ("invalid-url", isRateLimit)
                }
            }
            if let urlError = error as? URLError, urlError.code == .timedOut {
                return ("timeout", isRateLimit)
            }
            return ("error(\(type(of: error))): \(error.localizedDescription)", isRateLimit)
        }
    }

    /// Wraps `ITunesArtworkTransport.live` — the SAME production network
    /// path `fetchArtwork` uses — recording each call's outcome instead of
    /// routing through a second, separate implementation that could drift
    /// from what production actually does.
    private func makeObservingTransport(
        recorder: OutcomeRecorder, breaker: MusicController.ArtworkITunesCircuitBreaker
    ) -> MusicController.ITunesArtworkTransport {
        let live = MusicController.ITunesArtworkTransport.live
        return MusicController.ITunesArtworkTransport(
            search: { term, storefront in
                let breakerWasOpen = breaker.isOpen()
                let result = await live.search(term, storefront)
                let (description, isRateLimit) = self.classify(result)
                await recorder.record(StorefrontRequestOutcome(
                    country: storefront.country,
                    description: description,
                    isRateLimitShaped: isRateLimit,
                    breakerWasOpenAtRequestTime: breakerWasOpen
                ))
                return result
            },
            fetchImageData: live.fetchImageData
        )
    }

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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - The eval
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testLiveArtworkEval_18FailedTracksPlus8Controls() async throws {
        guard ProcessInfo.processInfo.environment["NANOPOD_LIVE_ARTWORK_EVAL"] == "1" else {
            throw XCTSkip("NANOPOD_LIVE_ARTWORK_EVAL=1 not set — skipping live network eval")
        }
        let spacingSeconds: Double = ProcessInfo.processInfo.environment["NANOPOD_LIVE_ARTWORK_EVAL_SPACING"]
            .flatMap(Double.init) ?? Self.defaultSpacingSeconds

        let allTracks = Self.failedToday + Self.controls
        // A fresh breaker for this eval run only — must never share process
        // state with `.shared` (which real app usage on this machine may
        // have already tripped), and must never let one eval run's rate
        // limiting silently swallow the rest of ITS OWN tracks either.
        let breaker = MusicController.ArtworkITunesCircuitBreaker()

        var rows: [String] = []
        rows.append("| Track (was failing?) | Artist | Verdict | Storefront requests (country:outcome) | Breaker open at any request? | Winning storefront | Matched trackName / artistName / collectionName | Latency (ms) | Same song? |")
        rows.append("|---|---|---|---|---|---|---|---:|---|")

        var hitCount = 0
        var invalidCount = 0
        var wrongMatchCount = 0
        var consecutiveRateLimited = 0
        var abortedEarly = false

        for (index, track) in allTracks.enumerated() {
            let recorder = OutcomeRecorder()
            let observingTransport = makeObservingTransport(recorder: recorder, breaker: breaker)

            let start = Date()
            let match = await MusicController.fetchArtworkViaITunesAPIDetailed(
                title: track.title, artist: track.artist, album: "",
                priority: .nowPlaying, transport: observingTransport, breaker: breaker
            )
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

            let outcomes = await recorder.outcomes
            let outcomeSummary = outcomes.map { "\($0.country):\($0.description)" }.joined(separator: ", ")
            let anyBreakerOpen = outcomes.contains { $0.breakerWasOpenAtRequestTime }
            let anyRateLimited = outcomes.contains { $0.isRateLimitShaped }
            let label = track.failedToday ? "failed" : "control"

            if let match {
                hitCount += 1
                let sameSong = looksLikeSameSong(requestedTitle: track.title, requestedArtist: track.artist, match: match)
                if !sameSong { wrongMatchCount += 1 }
                rows.append("| \(track.title) (\(label)) | \(track.artist) | HIT | \(outcomeSummary) | \(anyBreakerOpen ? "yes" : "no") | \(match.country) | \(match.trackName) / \(match.artistName) / \(match.collectionName) | \(elapsedMs) | \(sameSong ? "yes" : "⚠️ NO — WRONG MATCH") |")
            } else if anyRateLimited {
                // Coordinator's rule: a miss contaminated by a rate-limit
                // signal is unknowable, not a real negative — exclude it
                // from the hit-rate denominator entirely.
                invalidCount += 1
                rows.append("| \(track.title) (\(label)) | \(track.artist) | INVALID (rate-limited) | \(outcomeSummary) | \(anyBreakerOpen ? "yes" : "no") | — | — | \(elapsedMs) | — |")
            } else {
                rows.append("| \(track.title) (\(label)) | \(track.artist) | miss | \(outcomeSummary) | \(anyBreakerOpen ? "yes" : "no") | — | — | \(elapsedMs) | — |")
            }

            // Abort as soon as iTunes looks actively hostile for 2 tracks in
            // a row — a real HIT still resets the streak even if some other
            // storefront in that same track's requests got rate-limited,
            // because a definitive positive result means the host answered
            // us for real at least once in that round.
            if anyRateLimited && match == nil {
                consecutiveRateLimited += 1
            } else {
                consecutiveRateLimited = 0
            }
            if consecutiveRateLimited >= 2 {
                abortedEarly = true
                break
            }

            if index < allTracks.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(spacingSeconds * 1_000_000_000))
            }
        }

        let attemptedCount = rows.count - 2 // minus the 2 header rows
        let validDenominator = attemptedCount - invalidCount
        let summary = """

        ## Live eval results (\(Date()))
        Spacing: \(spacingSeconds)s · Aborted early (2 consecutive rate-limited): \(abortedEarly)
        Hit rate: \(hitCount)/\(validDenominator) valid tracks (\(invalidCount) excluded as rate-limit-contaminated, out of \(attemptedCount) attempted)
        Wrong matches flagged: \(wrongMatchCount)

        \(rows.joined(separator: "\n"))
        """
        print(summary)
        // Intentionally no XCTAssert on hit rate: this is a recorded
        // real-world measurement for the spec's 结果 section, not a
        // pass/fail gate — iTunes catalog availability and rate-limit
        // state can change over time, and the point is to capture today's
        // real numbers (including invalid/aborted ones honestly), not to
        // make CI flaky against a live third party.
    }
}
