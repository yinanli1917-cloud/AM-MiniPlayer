import XCTest
@testable import MusicMiniPlayerCore

/// 2026-09-20 founder recording (下雨天): the incoming row's first word lifted −2pt in place while
/// the row still waited its topDown stagger turn (0.16–0.24s), reading as a 1–2px twitch before
/// the scroll. The per-word float clock may start no earlier than the row's wave-release time;
/// sweep progress (sync) is unaffected.
final class NativeLyricsWordFloatGateTests: XCTestCase {
    private func line() -> LyricLine {
        let words = [
            LyricWord(word: "又", startTime: 10.0, endTime: 10.4),
            LyricWord(word: "独", startTime: 10.4, endTime: 10.8),
            LyricWord(word: "行", startTime: 10.8, endTime: 11.4)
        ]
        return LyricLine(text: "又独行", startTime: 10.0, endTime: 11.4, words: words)
    }

    private func plan(at t: TimeInterval, release: TimeInterval?) -> NativeLyricsTextRenderPlan {
        NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line(), currentTime: t, isActive: true, staticOpacity: 1, showTranslation: false,
            wordFloatReleaseTime: release
        ))
    }

    func test_noGate_floatsFromWordStart_v28Timing() {
        XCTAssertLessThan(plan(at: 10.2, release: nil).wordRuns[0].baseFloatY, 0)
    }

    func test_heldGate_noFloatWhileWaiting_butSweepStillProgresses() {
        let p = plan(at: 10.2, release: .infinity)
        XCTAssertEqual(p.wordRuns[0].baseFloatY, 0)
        XCTAssertGreaterThan(p.wordRuns[0].sweep.progress, 0, "brightness/sweep must not wait for the float gate")
    }

    func test_releasedGate_floatClockStartsAtRelease_notAtWordStart() {
        // Released 0.24s after the word began: float is 0 until then, then eases from the release.
        XCTAssertEqual(plan(at: 10.23, release: 10.24).wordRuns[0].baseFloatY, 0)
        let afterRelease = plan(at: 10.30, release: 10.24).wordRuns[0].baseFloatY
        XCTAssertLessThan(afterRelease, 0)
        XCTAssertGreaterThan(afterRelease, -2)
        // Same elapsed-since-start under no gate at 10.06 must equal the gated value at 10.30.
        XCTAssertEqual(afterRelease, plan(at: 10.06, release: nil).wordRuns[0].baseFloatY, accuracy: 1e-9)
    }

    func test_releaseBeforeWordStart_isNoOp() {
        XCTAssertEqual(plan(at: 10.2, release: 9.0).wordRuns[0].baseFloatY,
                       plan(at: 10.2, release: nil).wordRuns[0].baseFloatY, accuracy: 1e-9)
    }
}
