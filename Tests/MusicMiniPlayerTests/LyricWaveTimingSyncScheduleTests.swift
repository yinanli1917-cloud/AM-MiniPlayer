import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Pure schedule tables for the `wave` feel A/B (nanopod://debug/feel/wave/<topdown|sync>).
//
// `.topDown` must stay byte-identical to the pre-existing (default-shape) output —
// this is a non-regression pin, not a new spec. `.syncPair` pins the new shape:
// outgoing row (newIndex-1) and incoming row (newIndex) start on the SAME frame,
// and the wave spreads outward from that pair in both directions, with the same
// 1.05 tail acceleration applied above newIndex (never below it — same as topDown).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricWaveTimingSyncScheduleTests: XCTestCase {

    private func delays(_ schedule: [LyricWaveTiming.StaggerTarget]) -> [Int: TimeInterval] {
        Dictionary(uniqueKeysWithValues: schedule.map { ($0.lineIndex, $0.delay) })
    }

    private func printTable(_ label: String, _ schedule: [LyricWaveTiming.StaggerTarget]) {
        print("[WaveScheduleTable] \(label):")
        for target in schedule.sorted(by: { $0.lineIndex < $1.lineIndex }) {
            print("[WaveScheduleTable]   \(target.lineIndex): \(String(format: "%.4f", target.delay))")
        }
    }

    func test_topDown_defaultShapeParameterMatchesExplicitTopDownShape() {
        let indices = Array(0..<20)
        let newIndex = 6

        let implicitDefault = LyricWaveTiming.staggerSchedule(for: indices, newIndex: newIndex)
        let explicitTopDown = LyricWaveTiming.staggerSchedule(
            for: indices, newIndex: newIndex, shape: .topDown
        )

        printTable("topDown (default parameter)", implicitDefault)
        printTable("topDown (explicit shape)", explicitTopDown)

        XCTAssertEqual(implicitDefault.count, explicitTopDown.count)
        let a = delays(implicitDefault)
        let b = delays(explicitTopDown)
        XCTAssertEqual(a.keys.sorted(), b.keys.sorted())
        for key in a.keys {
            XCTAssertEqual(a[key]!, b[key]!, accuracy: 0.0000001,
                            "omitting `shape:` must be byte-identical to passing .topDown for row \(key)")
        }

        // Pin the known-good boundary rows so a future change to the topDown
        // algorithm itself (not just the new shape parameter) also fails loudly.
        XCTAssertEqual(a[3]!, 0, accuracy: 0.0001)
        XCTAssertEqual(a[4]!, LyricWaveTiming.defaultBaseDelay, accuracy: 0.0001)
        XCTAssertEqual(a[5]!, LyricWaveTiming.defaultBaseDelay * 2, accuracy: 0.0001)
        XCTAssertEqual(a[6]!, LyricWaveTiming.defaultBaseDelay * 3, accuracy: 0.0001)
        // Rows 0..2 are the lead-in above the visible window (newIndex - 3): flat 0.
        XCTAssertEqual(a[0]!, 0, accuracy: 0.0001)
        XCTAssertEqual(a[1]!, 0, accuracy: 0.0001)
        XCTAssertEqual(a[2]!, 0, accuracy: 0.0001)
    }

    func test_syncPair_boundaryPairStartsOnSameFrame_andSpreadsSymmetrically() {
        let indices = Array(0..<20)
        let newIndex = 6
        let oldIndex = newIndex - 1 // 5

        let schedule = LyricWaveTiming.staggerSchedule(
            for: indices, newIndex: newIndex, shape: .syncPair
        )
        printTable("syncPair", schedule)
        let d = delays(schedule)

        // The boundary pair: both zero, same frame.
        XCTAssertEqual(d[oldIndex]!, 0, accuracy: 0.0001, "outgoing row must start at the boundary")
        XCTAssertEqual(d[newIndex]!, 0, accuracy: 0.0001, "incoming row must start at the boundary")

        // Downward (no acceleration): constant baseDelay per row.
        XCTAssertEqual(d[oldIndex - 1]!, LyricWaveTiming.defaultBaseDelay, accuracy: 0.0001, "i-1")
        XCTAssertEqual(d[oldIndex - 2]!, LyricWaveTiming.defaultBaseDelay * 2, accuracy: 0.0001, "i-2")

        // Upward (tail-accelerated): first step is a full baseDelay, later steps shrink.
        XCTAssertEqual(d[newIndex + 1]!, LyricWaveTiming.defaultBaseDelay, accuracy: 0.0001, "i+2")
        let expectedIPlus3 = LyricWaveTiming.defaultBaseDelay
            + LyricWaveTiming.defaultBaseDelay / LyricWaveTiming.tailAccelerationFactor
        XCTAssertEqual(d[newIndex + 2]!, expectedIPlus3, accuracy: 0.0001, "i+3 (post tail-accel step)")
        XCTAssertLessThan(d[newIndex + 2]!, d[newIndex + 1]! * 2,
                           "tail acceleration must make the upward increments shrink, not stay linear")

        // Lead-in rows above the visible window (newIndex - 3): flat 0, same as topDown.
        XCTAssertEqual(d[0]!, 0, accuracy: 0.0001)
        XCTAssertEqual(d[1]!, 0, accuracy: 0.0001)
        XCTAssertEqual(d[2]!, 0, accuracy: 0.0001)

        // Radius/coverage: same set of rows carries a schedule entry as topDown.
        let topDown = LyricWaveTiming.staggerSchedule(for: indices, newIndex: newIndex, shape: .topDown)
        XCTAssertEqual(Set(delays(topDown).keys), Set(d.keys), "sync must not change which rows are scheduled")
    }

    func test_syncPair_isNotByteIdenticalToTopDown_forTheHandoffRows() {
        // The whole point of the new arm: rows i and i+1 differ in onset from topDown.
        let indices = Array(0..<20)
        let newIndex = 6
        let topDown = delays(LyricWaveTiming.staggerSchedule(for: indices, newIndex: newIndex, shape: .topDown))
        let sync = delays(LyricWaveTiming.staggerSchedule(for: indices, newIndex: newIndex, shape: .syncPair))

        XCTAssertGreaterThan(topDown[newIndex - 1]!, 0, "topDown staggers the outgoing row")
        XCTAssertEqual(sync[newIndex - 1]!, 0, "sync fires the outgoing row at the boundary")
        XCTAssertNotEqual(topDown[newIndex]!, sync[newIndex]!,
                           "topDown and sync must disagree on the incoming row's onset")
    }
}
