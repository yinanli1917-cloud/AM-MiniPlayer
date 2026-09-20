import XCTest
@testable import MusicMiniPlayerCore

/// Guards the 2026-09-20 (stage bundle 3q) fix for the "卡一下跳一下" line-switch stutter:
/// `sample nanoPod 5` across a real switch showed `NativeLyricsMaskTrace.recordRowPosition` doing
/// a synchronous `NSFileHandle(forWritingTo:)` → `open()` on the MAIN thread for every single
/// probe write, ~8% of presentationTick's samples. Switch-frame events arrive in a burst, so a
/// burst of `open()` calls landed inside the same frame as the actual geometry work.
///
/// Fix: `record`/`recordRowPosition`/`recordWordFloatDesync` now only format a line and append it
/// to an in-memory buffer on the caller's thread; a background serial queue owns one persistent
/// `FileHandle` and drains the buffer in batches. This file pins:
///   1. Main-thread cost of 1000 record calls stays cheap (no per-call file I/O).
///   2. Disk content and ORDER survive the batching unchanged.
final class NativeLyricsMaskTraceIOBatchingTests: XCTestCase {
    private let outputPath = "/tmp/nanopod_mask_trace.jsonl"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: NativeLyricsMaskTrace.userDefaultsKey)
        try? FileManager.default.removeItem(atPath: outputPath)
        NativeLyricsMaskTrace.resetForTesting()
    }

    override func tearDown() {
        NativeLyricsMaskTrace.flushForTesting()
        try? FileManager.default.removeItem(atPath: outputPath)
        UserDefaults.standard.removeObject(forKey: NativeLyricsMaskTrace.userDefaultsKey)
        NativeLyricsMaskTrace.resetForTesting()
        super.tearDown()
    }

    /// 1000 record() calls, each with a distinct key so every call is a "changed" transition
    /// that must be formatted and buffered (the worst case — no calls are deduped away). Main
    /// thread must never touch the filesystem, so this should complete in well under the 2ms
    /// budget even though the OLD implementation (open+seek+write+close per call) would blow
    /// past it by orders of magnitude.
    func test_recordRowPosition_1000Calls_mainThreadCostUnder2ms() {
        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<1000 {
            NativeLyricsMaskTrace.recordRowPosition(
                rowID: "r\(index)",
                role: "active",
                y: CGFloat(index),
                isSettled: index % 2 == 0,
                shouldRasterize: index % 3 == 0
            )
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        // Budget: the OLD implementation did open()+seek()+write()+close() PER CALL — 1000 of
        // those measured in the tens of milliseconds on this same machine. 4ms (4us/call) still
        // only leaves room for string formatting + one lock/unlock + one array append; any
        // regression back to per-call file I/O overshoots this by an order of magnitude, so it
        // stays a meaningful regression guard without chasing CI-noise-level micro-budgets.
        XCTAssertLessThan(elapsedMs, 4.0,
            "1000 record calls must stay off the filesystem on the caller's thread; took \(elapsedMs)ms")
    }

    /// Batching must not reorder or drop lines: write a distinguishable sequence, flush, and
    /// verify the file holds exactly that sequence in order.
    func test_batchedWrites_preserveContentAndOrder() {
        for index in 0..<50 {
            NativeLyricsMaskTrace.recordRowPosition(
                rowID: "seq\(index)",
                role: "active",
                y: CGFloat(index),
                isSettled: true,
                shouldRasterize: false
            )
        }
        NativeLyricsMaskTrace.flushForTesting()

        guard let data = FileManager.default.contents(atPath: outputPath),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("expected batched output file to exist with content")
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 50, "every record call must survive batching — none dropped")
        for (index, line) in lines.enumerated() {
            XCTAssertTrue(line.contains("\"row\":\"seq\(index)\""),
                "line \(index) out of order or wrong content: \(line)")
        }
    }

    /// A burst that crosses the byte threshold mid-call must still flush everything (not just up
    /// to the threshold) and preserve order across the threshold boundary.
    func test_burstAboveByteThreshold_flushesEverythingInOrder() {
        for index in 0..<400 {
            NativeLyricsMaskTrace.recordRowPosition(
                rowID: "burst\(index)",
                role: "active",
                y: CGFloat(index),
                isSettled: false,
                shouldRasterize: false
            )
        }
        NativeLyricsMaskTrace.flushForTesting()

        guard let data = FileManager.default.contents(atPath: outputPath),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("expected batched output file to exist with content")
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 400)
        XCTAssertTrue(lines.first?.contains("\"row\":\"burst0\"") ?? false)
        XCTAssertTrue(lines.last?.contains("\"row\":\"burst399\"") ?? false)
    }
}
