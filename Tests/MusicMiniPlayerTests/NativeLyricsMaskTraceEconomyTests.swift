import XCTest
@testable import MusicMiniPlayerCore

/// Guards the 2026-09-20 (stage bundle 3r) fix for `NativeLyricsMaskTrace`'s per-frame probe
/// cost, called out by the founder's `/tmp/nanopod_mask_trace.jsonl` session evidence (127s of
/// a line-level song produced 209,673 lines — a `tick` line was written on every single
/// presentation tick regardless of whether anything happened). Fix: `recordTick` now only emits
/// a full `tick` line on a line switch (`activeBefore != activeAfter`) or a real hitch
/// (`dtMs > 4`), and folds every other tick into a running aggregate flushed as ONE
/// `tick_summary` line every 600 ticks.
final class NativeLyricsMaskTraceEconomyTests: XCTestCase {
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

    /// 1000 `recordTick` calls with the SAME active index and a small (non-hitch) `dtMs` must
    /// not each produce a `tick` line — they should collapse into at most 2 lines: one
    /// `tick_summary` flush at the 600-tick boundary plus, at most, one more for the remainder.
    func test_recordTick_1000SameActiveSmallDt_producesAtMostTwoLines() {
        for _ in 0..<1000 {
            NativeLyricsMaskTrace.recordTick(
                dtMs: 1.5,
                intervalMs: 8.33,
                activeBefore: 3,
                activeAfter: 3,
                mountedRows: 30
            )
        }
        NativeLyricsMaskTrace.flushForTesting()

        guard let data = FileManager.default.contents(atPath: outputPath),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("expected output file to exist")
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertLessThanOrEqual(lines.count, 2,
            "1000 idle ticks (same active index, small dt) must not each write a tick line; got \(lines.count) lines: \(lines)")
        XCTAssertTrue(lines.allSatisfy { $0.contains("\"event\":\"tick_summary\"") },
            "idle ticks must only ever produce tick_summary lines, not per-tick tick lines: \(lines)")
    }

    /// A line switch must still be individually visible as a `tick` event.
    func test_recordTick_lineSwitch_stillEmitsTickLine() {
        NativeLyricsMaskTrace.recordTick(
            dtMs: 1.0, intervalMs: 8.33, activeBefore: 1, activeAfter: 2, mountedRows: 30
        )
        NativeLyricsMaskTrace.flushForTesting()

        guard let data = FileManager.default.contents(atPath: outputPath),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("expected output file to exist")
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("\"event\":\"tick\"") && $0.contains("\"activeBefore\":1") && $0.contains("\"activeAfter\":2") },
            "a line switch must emit a tick line: \(lines)")
    }

    /// A real hitch (dtMs above the threshold) must still be individually visible as a `tick`
    /// event even with no line switch.
    func test_recordTick_hitch_stillEmitsTickLine() {
        NativeLyricsMaskTrace.recordTick(
            dtMs: 12.0, intervalMs: 8.33, activeBefore: 5, activeAfter: 5, mountedRows: 30
        )
        NativeLyricsMaskTrace.flushForTesting()

        guard let data = FileManager.default.contents(atPath: outputPath),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("expected output file to exist")
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("\"event\":\"tick\"") && $0.contains("\"dt_ms\":12.00") },
            "a hitch tick must emit a tick line: \(lines)")
    }
}
