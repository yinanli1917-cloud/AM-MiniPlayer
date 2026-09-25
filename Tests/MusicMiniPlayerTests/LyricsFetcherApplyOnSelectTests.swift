import XCTest
@testable import MusicMiniPlayerCore

/// A1 apply-on-select: pins the delivery primitive `LyricsFetcher.withHardTimeout(seconds:operation:)`
/// (the `deliver`-callback overload backing `fetchAllSourcesUncached`).
///
/// Root cause this guards against: the caller used to resume only after (a)
/// `withTaskGroup` finished tearing down every cancelled child and (b) an
/// extra `Task { let value = await worker.value; state.resume(value) }` hop
/// was scheduled — real logs showed a verdict chosen at ~2.0s reaching the
/// screen at ~4.2s. The fix hands `operation` a `deliver` closure it can call
/// the instant it has a verdict; `TimeoutState.resume` (single-resume,
/// lock-guarded) races {deliver, worker completion, wall deadline,
/// cancellation} and the first one wins.
///
/// These tests call the primitive directly (no network, no real lyrics
/// pipeline) with `Date()`-measured wall-clock assertions, per the project's
/// "no computer use / no screen recording for correctness, only code-level
/// evidence" rule for anything not in the hand-feel category — this is a
/// concurrency-timing correctness test, not a hand-feel test.
final class LyricsFetcherApplyOnSelectTests: XCTestCase {

    private let fetcher = LyricsFetcher.shared

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - deliver() resumes immediately; body's own teardown stalls after
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// This is the exact shape of the bug: `deliver` fires at t≈0 (the drain
    /// loop's verdict), then the body simulates ~1.5s of structured-
    /// concurrency teardown (TaskGroup children ignoring cancellation) before
    /// returning. On the OLD single-return `withHardTimeout` overload this
    /// stall was unavoidable because the return value was the only signal.
    func test_deliverResumesCallerBeforeBodyTeardownStallEnds() async {
        let deliveredAt = ManagedBox<Date?>(nil)
        let callerResumeStart = Date()

        let result: Int? = await fetcher.withHardTimeout(seconds: 5.0) { deliver in
            deliveredAt.value = Date()
            deliver(42)
            // Simulate slow group teardown / post-verdict persistence that
            // the caller must NOT have to wait for.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return 42
        }

        let callerResumeElapsed = Date().timeIntervalSince(callerResumeStart)

        XCTAssertEqual(result, 42)
        XCTAssertNotNil(deliveredAt.value)
        XCTAssertLessThan(
            callerResumeElapsed, 0.5,
            "caller should resume the instant deliver() is called, not after the ~1.5s body stall"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Body completes without ever calling deliver
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_bodyReturnWithoutDeliver_callerGetsReturnValue() async {
        let result: String? = await fetcher.withHardTimeout(seconds: 5.0) { _ in
            "no-deliver-path"
        }
        XCTAssertEqual(result, "no-deliver-path")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Wall-clock deadline fires before deliver or return
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_deadlineFiresBeforeDeliverOrReturn_callerGetsNil() async {
        let start = Date()
        let result: Int? = await fetcher.withHardTimeout(seconds: 0.2) { _ in
            // Never calls deliver, and outlives the deadline.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return 999
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 1.5, "must resume at the wall deadline, not wait for the slow body")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Single resume: deliver() called twice, or deliver() then return
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_deliverCalledTwice_callerResumesOnceWithFirstValue() async {
        let result: Int? = await fetcher.withHardTimeout(seconds: 5.0) { deliver in
            deliver(1)
            deliver(2) // must be a no-op — TimeoutState.resume guards on didResume
            return 3
        }
        XCTAssertEqual(result, 1)
    }

    func test_deliverThenBodyReturn_callerResumesOnceWithDeliveredValue() async {
        let result: Int? = await fetcher.withHardTimeout(seconds: 5.0) { deliver in
            deliver(10)
            try? await Task.sleep(nanoseconds: 100_000_000)
            return 20 // must never reach the continuation
        }
        XCTAssertEqual(result, 10)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - deliver() must not cancel its own worker (2026-09-23 regression)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Root cause of the "Off the Wall" word-level→line-level degradation
    /// (research/diagnosis-2026-09-23-off-the-wall-word-level.md): the doc
    /// comment on `withHardTimeout` promises that after `deliver` resumes the
    /// caller, "the worker keeps running to finish teardown and any
    /// post-verdict persistence" — that's exactly what
    /// `LyricsFetcher.fetchAllSourcesWithinForegroundBudget` relies on: it
    /// calls `deliver(sortedResults)` for the UI, then falls through to
    /// `guard !Task.isCancelled ... else { return [] }` before calling
    /// `persistTrustedForegroundLyrics` (the ONLY call that writes a
    /// fast/early-return verdict to the on-disk lyrics cache).
    ///
    /// `TimeoutState.resume(_:)` unconditionally calls `worker?.cancel()`
    /// before resuming the continuation — including when `resume` is invoked
    /// BY the worker's own `deliver` closure. That self-inflicted
    /// cancellation makes `Task.isCancelled` true the moment `deliver`
    /// returns, so the post-verdict persistence guard always bails. Real
    /// debug-log evidence (2026-09-23, Off the Wall / Michael Jackson,
    /// NetEase word-level 47/47 synced, selected + applied to the UI twice)
    /// shows `[LyricsFetcher.swift:1707] cancelled before result
    /// normalization` immediately after every successful apply-on-select
    /// delivery, and the track never appears in lyrics_cache.v31.json —
    /// confirmed by direct inspection of
    /// ~/Library/Application Support/nanoPod/lyrics_cache.v31.json (34
    /// entries, none for this title/artist). Every subsequent play re-races
    /// all 8 sources from scratch instead of being served the known-good
    /// word-level result, so a source race that goes the other way (NetEase
    /// momentarily slow, a line-level source answers first) can display
    /// line-level lyrics for a song nanoPod already proved has word-level
    /// timing.
    func test_deliverDoesNotCancelWorker_postVerdictWorkStillRuns() async {
        let observedCancelledAfterDeliver = ManagedBox<Bool?>(nil)
        let postVerdictWorkRan = ManagedBox<Bool>(false)
        // The caller (this test, standing in for LyricsService) resumes the
        // instant deliver() fires — same as production. The worker's
        // post-verdict work keeps running in the background after that, so
        // the test must wait for IT to finish, not just for the awaited
        // call to return (that's the whole point of apply-on-select: the
        // caller does NOT wait for this).
        let (postVerdictDone, postVerdictContinuation) = AsyncStream<Void>.makeStream()

        let result: Int? = await fetcher.withHardTimeout(seconds: 5.0) { deliver in
            deliver(42)
            // Give the cooperative executor a beat so a (buggy)
            // worker.cancel() triggered by deliver() would already have
            // taken effect by the time we check Task.isCancelled below.
            try? await Task.sleep(nanoseconds: 50_000_000)
            observedCancelledAfterDeliver.value = Task.isCancelled
            // Mirrors the real fetcher's shape at LyricsFetcher.swift:1706 —
            // `guard !Task.isCancelled, let verdict = verdictBox.value else {
            // ...; return [] }` — persistTrustedForegroundLyrics sits right
            // after this guard.
            guard !Task.isCancelled else {
                postVerdictContinuation.finish()
                return 42
            }
            postVerdictWorkRan.value = true
            postVerdictContinuation.finish()
            return 42
        }

        // Wait for the background worker to actually reach the post-verdict
        // check, instead of asserting the instant the caller resumes —
        // which would race the very background work under test. The stream
        // finishes deterministically right after the operation closure's
        // 50ms sleep, so this blocks only as long as that.
        for await _ in postVerdictDone {}

        XCTAssertEqual(result, 42)
        XCTAssertEqual(
            observedCancelledAfterDeliver.value, false,
            "deliver() is the operation's own synchronous ack that a verdict shipped, not an external cancellation — it must not flip Task.isCancelled for the very task that called it"
        )
        XCTAssertTrue(
            postVerdictWorkRan.value,
            "post-verdict persistence never runs if deliver() cancels the worker — this is why fast/early-return word-level results never reach LyricsDiskCache"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Outer task cancellation
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_outerCancellation_workerCancelledAndCallerGetsNil() async {
        let fetcherRef = fetcher
        // Create the stream before the task so we can await it in the test.
        let (cancellationObservedStream, cancellationObservedContinuation) = AsyncStream<Void>.makeStream()
        let continuationBox = ManagedBox<AsyncStream<Void>.Continuation?>(cancellationObservedContinuation)

        let outer = Task<Int?, Never> {
            await fetcherRef.withHardTimeout(seconds: 5.0) { _ in
                // Poll cooperative cancellation instead of sleeping the full
                // window, so the test is fast whether or not cancellation
                // propagates (a false pass here would hide a real bug).
                for _ in 0..<40 {
                    if Task.isCancelled {
                        // Signal that cancellation was observed
                        continuationBox.value?.yield()
                        break
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return 123
            }
        }

        // Let the worker actually start before cancelling.
        try? await Task.sleep(nanoseconds: 50_000_000)
        outer.cancel()
        let result = await outer.value

        XCTAssertNil(result)

        // Wait for the worker to observe cancellation, with a 2s timeout.
        // This ensures the worker has actually observed Task.isCancelled before
        // we verify it did so.
        let observedCancellation = ManagedBox<Bool>(false)
        let waitTask = Task<Void, Never> {
            for await _ in cancellationObservedStream {
                observedCancellation.value = true
                break
            }
        }

        // Give the worker up to 2s to observe cancellation and signal via the stream.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        waitTask.cancel()

        XCTAssertTrue(
            observedCancellation.value,
            "worker task must observe cooperative cancellation after outer cancellation"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Fetcher-level: caller resumes at the verdict, not at teardown end
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// End-to-end through `fetchAllSources`, not just the primitive: arms the
    /// foreground group with an extra child that stalls ~1.5s ignoring
    /// cancellation (the shape of a real slow/uncooperative source task), and
    /// asserts the caller's `await fetchAllSources(...)` resumes at the
    /// drain loop's verdict rather than waiting for that child to finish
    /// tearing down.
    ///
    /// The song is deliberately unmatchable so no real source can select a
    /// result; network calls may still fire in the background and fail/miss
    /// on their own schedule, but the assertion is a GAP relative to the
    /// verdict timestamp (captured via `foregroundVerdictObserverForTesting`,
    /// which fires inside the group closure right where `deliver` is called),
    /// not an absolute wall-clock duration — so per-network-hop variance
    /// doesn't make this flaky. This test does hit real network endpoints
    /// (LyricsFetcher has no injectable network seam at this layer); the
    /// nonsense title/artist keep them fast misses.
    func test_fetchAllSources_callerResumesAtVerdict_notAfterTeardownStall() async {
        let verdictAt = ManagedBox<Date?>(nil)
        let stallDuration: UInt64 = 1_500_000_000

        LyricsFetcher.foregroundVerdictObserverForTesting = { date in
            verdictAt.value = date
        }
        LyricsFetcher.foregroundTeardownStallForTesting = {
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    // Ignore cancellation — this simulates a child task that
                    // does not cooperate with TaskGroup.cancelAll(), which is
                    // exactly the stall this primitive exists to route around.
                    continue
                }
            }
        }
        defer {
            LyricsFetcher.foregroundVerdictObserverForTesting = nil
            LyricsFetcher.foregroundTeardownStallForTesting = nil
        }

        let nonceTitle = "zzqx-no-such-song-\(UUID().uuidString)"
        _ = await LyricsFetcher.shared.fetchAllSources(
            title: nonceTitle,
            artist: "zzqx-nobody",
            duration: 200,
            translationEnabled: false
        )
        let returnedAt = Date()

        guard let verdict = verdictAt.value else {
            XCTFail("foregroundVerdictObserverForTesting never fired — drain loop did not reach a verdict")
            return
        }
        let gap = returnedAt.timeIntervalSince(verdict)

        XCTAssertLessThan(
            gap, 0.3,
            "fetchAllSources should return within ~0.3s of the verdict, not wait out the \(Double(stallDuration) / 1e9)s teardown stall (measured gap: \(gap)s)"
        )
    }
}

/// Plain lock-guarded box — deliberately independent of LyricsFetcher's
/// private `Box<T>` so this test file has no dependency beyond the
/// `internal` seam it is pinning.
private final class ManagedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
