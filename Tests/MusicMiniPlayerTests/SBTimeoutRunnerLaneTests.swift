import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SBTimeoutRunner lane serialization.
//
// Music.app's AppleEvent dispatch (AECreateAppleEvent / AEProcessMessage) corrupts internal
// state and crashes EXC_BAD_ACCESS when two SBApplication proxies hit Music.app concurrently.
// SBTimeoutRunner groups every Music-READ lane onto ONE serial worker queue so the reads can
// never overlap. The artwork lane used its own SBApplication proxy (artworkApp) on a SEPARATE
// queue — so an artwork scan could dispatch an AppleEvent at the same instant as a position
// poll or state read, which is the captured crash (getArtworkImageByPersistentID →
// AECreateAppleEvent). These tests assert the artwork lane is serialized with the other Music
// reads at the BEHAVIOR level: two blocks on the two lanes may never execute concurrently.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class SBTimeoutRunnerLaneTests: XCTestCase {

    /// Run one block on each of the two given lanes concurrently and return the maximum number
    /// of blocks observed executing at the same time. 1 ⇒ the lanes serialize on one queue;
    /// 2 ⇒ they run on independent queues (the concurrent-AE-dispatch crash window).
    private func maxConcurrency(laneA: String, laneB: String) -> Int {
        let lock = NSLock()
        var active = 0
        var maxActive = 0
        let group = DispatchGroup()
        for lane in [laneA, laneB] {
            group.enter()
            DispatchQueue.global().async {
                _ = SBTimeoutRunner.run(timeout: 5.0, lane: lane) { () -> Int? in
                    lock.lock(); active += 1; maxActive = max(maxActive, active); lock.unlock()
                    // Hold the lane briefly so a genuinely-concurrent second block overlaps.
                    Thread.sleep(forTimeInterval: 0.15)
                    lock.lock(); active -= 1; lock.unlock()
                    return 0
                }
                group.leave()
            }
        }
        group.wait()
        return maxActive
    }

    /// The artwork lane must serialize with the position-poll lane: an artwork SB read and a
    /// position poll may never dispatch AppleEvents to Music.app at the same time.
    func test_artworkLane_serializesWith_positionPoll() {
        XCTAssertEqual(
            maxConcurrency(laneA: "artwork", laneB: "positionPoll"), 1,
            "artwork and positionPoll must share the serial musicRead lane — concurrent AppleEvent dispatch to Music.app is the captured EXC_BAD_ACCESS crash"
        )
    }

    /// And with the state-sync lane (the 30s full read), the other heavy Music reader.
    func test_artworkLane_serializesWith_stateSync() {
        XCTAssertEqual(
            maxConcurrency(laneA: "artwork", laneB: "stateSync"), 1,
            "artwork and stateSync must share the serial musicRead lane"
        )
    }

    /// Control: two genuinely independent (non-Music) lanes still run concurrently, proving the
    /// test actually detects parallelism (so the assertions above are meaningful).
    func test_independentLanes_runConcurrently() {
        XCTAssertEqual(
            maxConcurrency(laneA: "unitTestLaneX", laneB: "unitTestLaneY"), 2,
            "distinct non-Music lanes must remain isolated"
        )
    }
}
