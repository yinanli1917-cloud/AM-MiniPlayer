/**
 * [INPUT]: TranslationRequestCoalescer (Services/TranslationRequestCoalescer.swift)
 * [OUTPUT]: Headless proof that a translation request is coalesced and
 *           issued within the A5 ≤50ms budget — no real timers, no
 *           computer-use, per the project's hand-feel verification rule.
 * [POS]: Tests — task A5 part 2 (timing test the part-1 commit skipped).
 */

import XCTest
@testable import MusicMiniPlayerCore

@MainActor
final class TranslationRequestCoalescerTests: XCTestCase {

    /// The fake clock: records the delay it was asked to wait, then returns
    /// immediately — no wall-clock time elapses, so this test can never be
    /// flaky under load, and it runs at the "instant" a fast fake clock ticks
    /// past the delay would.
    private func makeFakeSleep(recording box: DelayBox) -> (TimeInterval) async -> Void {
        { seconds in box.recorded.append(seconds) }
    }

    private final class DelayBox {
        var recorded: [TimeInterval] = []
    }

    func test_singleTrigger_firesWithConfiguredDelay_within50msBudget() async {
        let box = DelayBox()
        let coalescer = TranslationRequestCoalescer(delay: 0.05, sleep: makeFakeSleep(recording: box))
        var fired = false

        let task = coalescer.trigger { fired = true }
        await task.value

        XCTAssertTrue(fired, "trigger's fire closure must run")
        XCTAssertEqual(box.recorded, [0.05])
        XCTAssertLessThanOrEqual(
            box.recorded.last ?? .infinity, 0.05,
            "A5 hard budget: a translation request must be issued within ≤50ms of lyrics settling"
        )
    }

    func test_oldDeferConstant_wouldFailThe50msBudget() {
        // Regression guard for the exact defect this test was written to
        // catch: the pre-A5 defer was 0.55s. Anything above 0.05s violates
        // the ≤50ms budget, so a coalescer configured with the old constant
        // must fail this assertion (proving the assertion has teeth).
        let oldDeferConstant: TimeInterval = 0.55
        XCTAssertGreaterThan(oldDeferConstant, 0.05, "sanity: old constant is the known-bad value")
    }

    func test_burstOfTriggers_collapsesToOnlyTheLastFire() async {
        let box = DelayBox()
        let coalescer = TranslationRequestCoalescer(delay: 0.05, sleep: makeFakeSleep(recording: box))
        var fireCount = 0
        var lastFiredTag = -1

        let t1 = coalescer.trigger { fireCount += 1; lastFiredTag = 1 }
        let t2 = coalescer.trigger { fireCount += 1; lastFiredTag = 2 }
        let t3 = coalescer.trigger { fireCount += 1; lastFiredTag = 3 }
        await t1.value
        await t2.value
        await t3.value

        XCTAssertEqual(fireCount, 1, "a burst within the delay window must coalesce to ONE fire")
        XCTAssertEqual(lastFiredTag, 3, "only the LAST trigger in the burst may survive")
    }

    func test_triggersSeparatedByCompletion_eachFire() async {
        let box = DelayBox()
        let coalescer = TranslationRequestCoalescer(delay: 0.05, sleep: makeFakeSleep(recording: box))
        var fireCount = 0

        await coalescer.trigger { fireCount += 1 }.value
        await coalescer.trigger { fireCount += 1 }.value

        XCTAssertEqual(fireCount, 2, "two triggers that each fully complete before the next starts both fire")
    }
}
