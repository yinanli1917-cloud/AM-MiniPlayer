/**
 * [INPUT]: EdgeHitchTrace (per-frame deadline accounting while an edge motion
 *          runs, stack sampling of long turns, capped off-main log file).
 * [OUTPUT]: Tests: nothing recorded outside a motion, a deadline miss over
 *           25ms is logged with what ran, a clean motion writes nothing, the
 *           log stays under its cap, tests never reach the real log.
 * [POS]: Guards the real-device evidence path of the edge-animation stutter fix.
 */

import XCTest
import QuartzCore
@testable import MusicMiniPlayerCore

@MainActor
final class EdgeHitchTraceTests: XCTestCase {
    private var logURL: URL!
    private var trace: EdgeHitchTrace!
    private var entries: [EdgeHitchTrace.Entry] = []

    override func setUp() {
        super.setUp()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("eh-trace-\(UUID().uuidString)/edge-hitch.log")
        trace = EdgeHitchTrace.shared   // `measure` notes against the shared trace
        trace.logURLOverride = logURL
        entries = []
        trace.entrySink = { [unowned self] in self.entries.append($0) }
    }

    override func tearDown() {
        trace.end()
        spin(0.05)
        trace.entrySink = nil
        trace.logURLOverride = nil
        try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    @inline(never)
    private func burnCPU(milliseconds: Double) {
        let end = CACurrentMediaTime() + milliseconds / 1000
        var x = 1.0
        while CACurrentMediaTime() < end { x = x * 1.0000001 + 0.0000001 }
        XCTAssertGreaterThan(x, 0)
    }

    /// One traced frame whose turn runs `busyMs` past its target.
    private func runMotion(busyMs: Double, motion: String = "unit", note: Bool = false) {
        trace.begin(motion: motion, nominalInterval: 1.0 / 120)
        let now = CACurrentMediaTime()
        trace.frameBegan(target: now + 0.004, timestamp: now - 0.004)
        if note { EdgeHitchTrace.measure("unit.work") { burnCPU(milliseconds: 2) } }
        burnCPU(milliseconds: busyMs)
        trace.frameTicked(cost: busyMs / 1000)
        trace.end()
        spin(0.1)           // the turn ends, the last frame is accounted
        trace.drainLogWrites()
    }

    func test_outsideAMotion_nothingIsRecorded() {
        XCTAssertFalse(EdgeHitchTrace.isRecording)
        var ran = false
        let v = EdgeHitchTrace.measure("unit.idle") { ran = true; return 7 }
        XCTAssertEqual(v, 7)
        XCTAssertTrue(ran)
        spin(0.05)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func test_missOver25ms_isLogged_withWhatRan() {
        runMotion(busyMs: 45, note: true)
        let frame = entries.first { $0.kind == .frame }
        XCTAssertNotNil(frame)
        XCTAssertGreaterThan(frame?.missMs ?? 0, 25, "the turn ended 45ms after a target 4ms away")
        XCTAssertTrue(frame?.notes.contains { "\($0.name)" == "unit.work" } == true, "the marked work is attached to its frame")
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("motion=unit"), text)
        XCTAssertTrue(text.contains("frame[unit]"), text)
        XCTAssertTrue(text.contains("unit.work"), text)
        XCTAssertFalse(EdgeHitchTrace.isRecording, "recording stops with the motion")
    }

    func test_smallMiss_isCounted_butNotLogged() {
        runMotion(busyMs: 12)
        XCTAssertGreaterThan(entries.first { $0.kind == .frame }?.missMs ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path), "only misses over 25ms reach the file")
    }

    func test_longTurn_isSampled_whenItRunsPastTheStallThreshold() throws {
        #if !arch(arm64)
        throw XCTSkip("stack sampling is arm64 only")
        #endif
        runMotion(busyMs: 80)
        let stacks = entries.flatMap(\.stacks)
        XCTAssertFalse(stacks.isEmpty, "an 80ms turn must have been sampled at least once")
        let symbolicated = stacks.map(EdgeHitchTrace.symbolicate).joined(separator: "\n")
        XCTAssertTrue(symbolicated.contains("burnCPU"), "the sample names the function that was running:\n\(symbolicated)")
    }

    func test_logIsCapped() throws {
        let entry = EdgeHitchTrace.Entry(kind: .frame, motion: "cap", wall: Date(), target: 1, gapMs: 40, nominalMs: 8.3,
                                         startDelayMs: 0, tickMs: 1, turnMs: 40, turnCpuMs: 30, lateMs: 40,
                                         notes: [], stacks: [[0x1000, 0x2000]])
        let batch = [EdgeHitchTrace.Entry](repeating: entry, count: 400)
        for _ in 0..<40 { EdgeHitchTrace.append(batch, motion: "cap", worstMs: 40, to: logURL) }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, EdgeHitchTrace.maxLogBytes + 64 * 1024, "the log is trimmed to its cap (\(size) bytes)")
        XCTAssertGreaterThan(size, 0)
    }

    func test_underXCTest_theDefaultLogIsNone() {
        XCTAssertNil(EdgeHitchTrace.defaultLogURL, "a test process never writes the founder's ~/Library/Logs/nanoPod")
    }
}
