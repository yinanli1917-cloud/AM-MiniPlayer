import XCTest
@testable import MusicMiniPlayerCore

/// Hard-miss songs (every provider answered, none had a lyric payload) used
/// to re-run the FULL ~14s sweep on every replay — the user retried 3x in
/// 45s staring at "searching more sources" (Live log 06:47-06:48,
/// 2026-06-12). The session memo answers a CONFIRMED miss instantly on
/// replay within a short TTL, in memory only: relaunch clears it, TTL
/// expiry re-searches, and a user-initiated retry always really searches.
final class LyricsMissMemoTests: XCTestCase {

    private let key = "ev'ry time we say goodbye|ray charles & betty carter||275"

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Memo set on confirmed miss / hit within TTL
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testRecordedMissIsServedWithinTTL() {
        let memo = LyricsMissMemo<String>()
        let t0 = Date()
        memo.record("noLyrics", forKey: key, at: t0)
        XCTAssertEqual(memo.confirmedMiss(forKey: key, at: t0.addingTimeInterval(60)), "noLyrics")
    }

    func testUnknownKeyMisses() {
        let memo = LyricsMissMemo<String>()
        XCTAssertNil(memo.confirmedMiss(forKey: key))
    }

    /// The memo keys on the exact song identity used for cache lookups —
    /// a different song (track change / skip) must never be answered.
    func testOtherKeysAreUnaffected() {
        let memo = LyricsMissMemo<String>()
        memo.record("noLyrics", forKey: key)
        XCTAssertNil(memo.confirmedMiss(forKey: "dream|deca joins||245"))
    }

    /// The stored payload is the verdict the display machine published —
    /// an instrumental terminal replays as instrumental, not generic.
    func testVerdictPayloadRoundTrips() {
        let memo = LyricsMissMemo<LyricsService.TerminalMissVerdict>()
        memo.record(.instrumental, forKey: key)
        XCTAssertEqual(memo.confirmedMiss(forKey: key), .instrumental)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - TTL expiry re-searches
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testDefaultTTLIsTwentyMinutes() {
        XCTAssertEqual(LyricsMissMemo<String>().ttl, 1200)
    }

    func testExpiredEntryMissesAndStaysGone() {
        let memo = LyricsMissMemo<String>(ttl: 1200)
        let t0 = Date()
        memo.record("noLyrics", forKey: key, at: t0)

        let justInside = t0.addingTimeInterval(1199)
        XCTAssertEqual(memo.confirmedMiss(forKey: key, at: justInside), "noLyrics")

        let expired = t0.addingTimeInterval(1201)
        XCTAssertNil(memo.confirmedMiss(forKey: key, at: expired), "TTL expiry must re-search")
        XCTAssertNil(
            memo.confirmedMiss(forKey: key, at: justInside),
            "an expired entry is pruned — it must not resurrect for earlier clocks"
        )
    }

    func testReRecordingRefreshesTheClock() {
        let memo = LyricsMissMemo<String>(ttl: 1200)
        let t0 = Date()
        memo.record("noLyrics", forKey: key, at: t0)
        let t1 = t0.addingTimeInterval(1000)
        memo.record("noLyrics", forKey: key, at: t1)
        XCTAssertEqual(
            memo.confirmedMiss(forKey: key, at: t0.addingTimeInterval(2100)),
            "noLyrics",
            "a fresh confirmed miss restarts the TTL window"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - forceRefresh bypasses + clears
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testClearRemovesTheKey() {
        let memo = LyricsMissMemo<String>()
        memo.record("noLyrics", forKey: key)
        memo.clear(forKey: key)
        XCTAssertNil(memo.confirmedMiss(forKey: key), "a user retry must always really search")
    }

    func testClearOnUnknownKeyIsHarmless() {
        let memo = LyricsMissMemo<String>()
        memo.clear(forKey: key)
        XCTAssertNil(memo.confirmedMiss(forKey: key))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Record gate: offline never memos; sentinel-bounded misses DO
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// An offline terminal is a statement about the NETWORK, not the song —
    /// it must search again on replay. Cancellation is NOT part of this gate:
    /// the bounded miss path TERMINATES via the 9s sentinel's group
    /// cancellation by design (review #6+#7), so Task.isCancelled is true at
    /// the legitimate terminal (live-log proof 2026-06-12 10:10:18 — backfill
    /// UNAVAILABLE published its verdict, the memo was never set, and the
    /// replay re-ran the full sweep). Track-change and stale publications are
    /// already excluded by the still-current + backfill-generation guards at
    /// the chokepoint, so a verdict-only gate cannot memo a moot search.
    func testOnlyCompletedSongVerdictsRecord() {
        XCTAssertTrue(
            LyricsService.shouldRecordTerminalMiss(verdict: .noLyrics),
            "sentinel-bounded no-lyrics conclusions are the canonical confirmed miss"
        )
        XCTAssertTrue(LyricsService.shouldRecordTerminalMiss(verdict: .instrumental))

        XCTAssertFalse(
            LyricsService.shouldRecordTerminalMiss(verdict: .networkUnreachable),
            "offline is never a confirmed miss"
        )
        XCTAssertFalse(
            LyricsService.shouldRecordTerminalMiss(verdict: .searchIncomplete),
            "a clipped or transport-degraded sweep is never a confirmed miss"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Key drift: duration must not break replay identity
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Live-log proof 2026-06-12: the SAME track produced songID '...|266'
    /// (dur=265.72 from one player snapshot) then '...|265' (dur=265.0 from
    /// the next) — an exact-key memo can never hit across that drift. The
    /// memo therefore keys on title|artist|album and carries the duration in
    /// the payload, with the same ±3s tolerance the disk cache's
    /// nearby-duration lookup and P1 matching already use.
    func testMemoKeyStripsTheDriftingDurationComponent() {
        XCTAssertEqual(
            LyricsService.missMemoKey(forSongID: "oceanside café|cincin lee|story island sunshine for free|266"),
            LyricsService.missMemoKey(forSongID: "oceanside café|cincin lee|story island sunshine for free|265")
        )
        XCTAssertEqual(
            LyricsService.missMemoKey(forSongID: "a|b|c|123"),
            "a|b|c"
        )
    }

    func testMemoDurationParsesTheLastComponent() {
        XCTAssertEqual(
            LyricsService.missMemoDuration(forSongID: "a|b|c|266"), 266
        )
        XCTAssertNil(LyricsService.missMemoDuration(forSongID: "no-pipes-here"))
    }

    /// Serve only when both durations are known and within tolerance —
    /// same-titled same-album sibling recordings (live vs studio) must not
    /// inherit each other's verdict; unparseable durations fail to SEARCH.
    func testMemoHitRequiresNearbyDuration() {
        XCTAssertTrue(LyricsService.shouldServeMemoHit(storedDuration: 266, currentDuration: 265))
        XCTAssertTrue(LyricsService.shouldServeMemoHit(storedDuration: 265, currentDuration: 268))
        XCTAssertFalse(LyricsService.shouldServeMemoHit(storedDuration: 265, currentDuration: 290))
        XCTAssertFalse(LyricsService.shouldServeMemoHit(storedDuration: nil, currentDuration: 265))
        XCTAssertFalse(LyricsService.shouldServeMemoHit(storedDuration: 265, currentDuration: nil))
    }
}
