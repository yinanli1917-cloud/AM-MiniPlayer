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
    // MARK: - Outer task cancellation
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_outerCancellation_workerCancelledAndCallerGetsNil() async {
        let workerObservedCancellation = ManagedBox<Bool>(false)
        let fetcherRef = fetcher

        let outer = Task<Int?, Never> {
            await fetcherRef.withHardTimeout(seconds: 5.0) { _ in
                // Poll cooperative cancellation instead of sleeping the full
                // window, so the test is fast whether or not cancellation
                // propagates (a false pass here would hide a real bug).
                for _ in 0..<40 {
                    if Task.isCancelled {
                        workerObservedCancellation.value = true
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
        XCTAssertTrue(
            workerObservedCancellation.value,
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
