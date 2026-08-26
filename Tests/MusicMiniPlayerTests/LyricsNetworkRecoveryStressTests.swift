import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Offline → recover — NWPathMonitor decision, injected, zero real network.
//
// A fetch that never heard from any server parks on `.networkUnreachable`
// (a statement about the NETWORK, not the song). Recovery is a latch:
// the first path callback is state, not a transition; only `false → true`
// re-issues the fetch; repeated `.satisfied` reports must not oscillate.
// Offline never writes the session miss memo. The spinner is not the
// offline terminal (`isSearchPhase == false`).
//
// Headless. Founder rule 2026-08-21 + stress-gap plan 2026-08-25.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsNetworkRecoveryStressTests: XCTestCase {

    // ── Path latch: exactly one fire per recovery, no oscillation ───────────

    func test_firstCallbackAlreadyOnline_doesNotFire() {
        let latch = LyricsNetworkPathLatch()
        XCTAssertFalse(latch.note(isSatisfied: true), "initial satisfied is state, not a recovery")
        XCTAssertFalse(latch.note(isSatisfied: true), "repeated satisfied must not oscillate")
    }

    func test_offlineThenOnline_firesExactlyOnce() {
        let latch = LyricsNetworkPathLatch()
        XCTAssertFalse(latch.note(isSatisfied: false), "going offline is not a recovery")
        XCTAssertTrue(latch.note(isSatisfied: true), "offline→online must fire")
        XCTAssertFalse(latch.note(isSatisfied: true), "already-online repeats must not re-fire")
        XCTAssertFalse(latch.note(isSatisfied: true))
    }

    func test_twoRecoveries_eachFireOnce() {
        let latch = LyricsNetworkPathLatch()
        var fires = 0
        let reports: [Bool] = [
            false,          // first callback: already offline
            true,           // recovery 1
            true, true,     // chatter — no fire
            false,          // drop
            false,          // still down
            true,           // recovery 2
            true
        ]
        for satisfied in reports {
            if latch.note(isSatisfied: satisfied) { fires += 1 }
        }
        XCTAssertEqual(fires, 2, "exactly one re-fetch per offline→online edge, got \(fires)")
    }

    func test_policy_onlyFalseToTrueFires() {
        XCTAssertFalse(LyricsNetworkRecoveryPolicy.shouldFireRecovery(wasSatisfied: nil, isSatisfied: true))
        XCTAssertFalse(LyricsNetworkRecoveryPolicy.shouldFireRecovery(wasSatisfied: nil, isSatisfied: false))
        XCTAssertFalse(LyricsNetworkRecoveryPolicy.shouldFireRecovery(wasSatisfied: true, isSatisfied: true))
        XCTAssertFalse(LyricsNetworkRecoveryPolicy.shouldFireRecovery(wasSatisfied: true, isSatisfied: false))
        XCTAssertFalse(LyricsNetworkRecoveryPolicy.shouldFireRecovery(wasSatisfied: false, isSatisfied: false))
        XCTAssertTrue(LyricsNetworkRecoveryPolicy.shouldFireRecovery(wasSatisfied: false, isSatisfied: true))
    }

    // ── Retry keying: only the offline terminal + a real title ──────────────

    func test_retryFetch_onlyWhenParkedOnOfflineTerminalWithTitle() {
        XCTAssertTrue(
            LyricsNetworkRecoveryPolicy.shouldRetryFetch(
                displayState: .networkUnreachable, currentSongTitle: "君は1000%"
            )
        )
        XCTAssertFalse(
            LyricsNetworkRecoveryPolicy.shouldRetryFetch(
                displayState: .networkUnreachable, currentSongTitle: ""
            ),
            "no identity → nowhere to re-fetch"
        )
        for state: LyricsDisplayState in [.searching, .deepSearching, .content, .noLyrics] {
            XCTAssertFalse(
                LyricsNetworkRecoveryPolicy.shouldRetryFetch(
                    displayState: state, currentSongTitle: "Song"
                ),
                "\(state) must not self-recover on path chatter"
            )
        }
    }

    // ── Offline is NOT a stuck spinner, and is NOT a confirmed miss ─────────

    func test_offlineTerminal_isNotASearchPhase() {
        XCTAssertFalse(LyricsDisplayState.networkUnreachable.isSearchPhase)
        XCTAssertEqual(
            LyricsService.TerminalMissVerdict.networkUnreachable.displayState,
            .networkUnreachable
        )
        XCTAssertEqual(
            LyricsService.TerminalMissVerdict.networkUnreachable.errorMessage,
            LyricsService.networkUnreachableErrorMessage
        )
    }

    func test_offlineVerdict_neverRecordsSessionMiss() {
        XCTAssertFalse(
            LyricsService.shouldRecordTerminalMiss(verdict: .networkUnreachable),
            "offline is a network statement — memoing it would skip the reconnect search"
        )
        XCTAssertTrue(LyricsService.shouldRecordTerminalMiss(verdict: .noLyrics))
        XCTAssertTrue(LyricsService.shouldRecordTerminalMiss(verdict: .instrumental))
        XCTAssertFalse(LyricsService.shouldRecordTerminalMiss(verdict: .searchIncomplete))
    }

    func test_offlineThenRecover_memoStaysEmptyAndFetchWouldRetry() {
        let memo = LyricsMissMemo<LyricsService.TerminalMissVerdict>()
        let songID = "kimi wa 1000%|1986 omega tribe|another summer|241"
        let key = LyricsService.missMemoKey(forSongID: songID)

        // Terminal apply of the offline verdict: the production chokepoint
        // consults shouldRecordTerminalMiss BEFORE record(). We replay that
        // gate here so a soak cannot accidentally pin a false miss.
        let verdict = LyricsService.TerminalMissVerdict.networkUnreachable
        if LyricsService.shouldRecordTerminalMiss(verdict: verdict) {
            memo.record(verdict, forKey: key)
        }
        XCTAssertNil(memo.confirmedMiss(forKey: key), "offline must not occupy the miss memo")
        XCTAssertEqual(memo.entryCountForTesting(), 0)

        // Recovery: latch fires once, and the empty+error retry gate (what
        // fetchLyrics consults for a parked offline track) allows the re-issue.
        let latch = LyricsNetworkPathLatch()
        XCTAssertFalse(latch.note(isSatisfied: false))
        XCTAssertTrue(latch.note(isSatisfied: true))
        XCTAssertTrue(
            LyricsNetworkRecoveryPolicy.shouldRetryFetch(
                displayState: .networkUnreachable, currentSongTitle: "君は1000%"
            )
        )
        XCTAssertTrue(
            LyricsService.shouldRetryAfterEmptyCurrentResult(
                currentSongID: songID,
                requestSongID: songID,
                isLoading: false,
                hasDisplayedLyrics: false,
                hasError: true,
                forceRefresh: false
            ),
            "parked offline (empty + error, not loading) must be retryable after reconnect"
        )
        XCTAssertFalse(latch.note(isSatisfied: true), "no second fetch on satisfied chatter")
        XCTAssertNil(memo.confirmedMiss(forKey: key), "recovery must still not invent a miss")
    }

    func test_confirmedMissStillMemos_andOfflineDoesNotCollide() {
        let memo = LyricsMissMemo<LyricsService.TerminalMissVerdict>()
        let missKey = LyricsService.missMemoKey(forSongID: "instrumental-a|artist||180")
        let offlineKey = LyricsService.missMemoKey(forSongID: "offline-b|artist||180")

        if LyricsService.shouldRecordTerminalMiss(verdict: .instrumental) {
            memo.record(.instrumental, forKey: missKey)
        }
        if LyricsService.shouldRecordTerminalMiss(verdict: .networkUnreachable) {
            memo.record(.networkUnreachable, forKey: offlineKey)
        }

        XCTAssertEqual(memo.confirmedMiss(forKey: missKey), .instrumental)
        XCTAssertNil(memo.confirmedMiss(forKey: offlineKey))
        XCTAssertEqual(memo.entryCountForTesting(), 1)
    }
}
