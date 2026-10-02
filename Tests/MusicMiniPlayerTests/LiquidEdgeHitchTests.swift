/**
 * [INPUT]: EdgeHitchHarness (real panel + real controller + real MiniPlayerView on a real
 *          display link, under a playback load).
 * [OUTPUT]: Benchmarks that print per-frame deadline statistics for collapse / peek /
 *           expand cycles and for the track-change auto-peek, plus a probe of what one
 *           track change costs the panel's SwiftUI.
 * [POS]: Opt-in measurement of the edge-animation stutter (2026-10-01). They measure, they do
 *        not assert: the wall-clock numbers depend on the machine's load, so they only run
 *        when NANOPOD_EDGE_HITCH_CYCLES is set (the cycle count). NANOPOD_EDGE_HITCH_REPORT
 *        names a file for the full report. Use an optimised build for numbers that mean
 *        anything: swift test -Xswiftc -O --filter LiquidEdgeHitchTests
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

@MainActor
final class LiquidEdgeHitchTests: XCTestCase {
    private var cycles: Int { Int(ProcessInfo.processInfo.environment["NANOPOD_EDGE_HITCH_CYCLES"] ?? "") ?? 3 }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NANOPOD_EDGE_HITCH_CYCLES"] != nil,
                          "benchmark: set NANOPOD_EDGE_HITCH_CYCLES to run")
    }

    private func report(_ title: String, _ r: EdgeHitchReport) {
        let text = "### \(title)\n\(r.summary)\n\(r.byMotion())\n\(r.detail)\n"
        print(text)
        if let path = ProcessInfo.processInfo.environment["NANOPOD_EDGE_HITCH_REPORT"] {
            if let h = FileHandle(forWritingAtPath: path) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8)); try? h.close() }
            else { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
        }
    }

    func test_benchmark_lyricsPage_underLoad() {
        let h = EdgeHitchHarness(page: .lyrics)
        defer { h.tearDown() }
        report("lyrics page, playing, load", h.run(cycles: cycles))
    }

    func test_benchmark_albumPage_underLoad() {
        let h = EdgeHitchHarness(page: .album)
        defer { h.tearDown() }
        report("album page, playing, load", h.run(cycles: cycles))
    }

    /// The track-change auto-peek (the one motion every track change starts), cover and
    /// lyrics arriving while it runs.
    func test_benchmark_autoPeek_lyricsPage() {
        let h = EdgeHitchHarness(page: .lyrics)
        defer { h.tearDown() }
        report("auto-peek on track change, lyrics page", h.runAutoPeek(rounds: cycles))
    }

    func test_benchmark_autoPeek_albumPage() {
        let h = EdgeHitchHarness(page: .album)
        defer { h.tearDown() }
        report("auto-peek on track change, album page", h.runAutoPeek(rounds: cycles))
    }

    /// Hover the sliver, leave 0.15s later (the capsule retracts while it is still settling), 30 times.
    func test_benchmark_quickPeekRetract_lyricsPage() {
        let h = EdgeHitchHarness(page: .lyrics)
        defer { h.tearDown() }
        let stay = Double(ProcessInfo.processInfo.environment["NANOPOD_EDGE_HITCH_STAY"] ?? "") ?? 0.15
        let r = h.runQuickPeek(rounds: Int(ProcessInfo.processInfo.environment["NANOPOD_EDGE_HITCH_CYCLES"] ?? "") ?? 30, stay: stay)
        report("quick peek (floatOut, leave after 0.15s, retract), lyrics page", r)
        print("quickPeek: \(r.turnReport)")
    }

    /// Without playback load: the cost the animation carries by itself.
    func test_benchmark_lyricsPage_quiet() {
        let h = EdgeHitchHarness(page: .lyrics)
        defer { h.tearDown() }
        report("lyrics page, quiet", h.run(cycles: cycles, withLoad: false))
    }

    /// How much main-thread time does one track-change burst cost the panel's SwiftUI while the
    /// panel window is on screen, ordered in at alpha 0, or ordered out?
    func test_probe_trackChangeBurst_byPanelVisibility() {
        for mode in ["visible", "alpha0", "orderedOut"] {
            let h = EdgeHitchHarness(page: .lyrics)
            defer { h.tearDown() }
            let load = PlaybackLoad(music: h.music)
            h.spin(1.0)
            switch mode {
            case "alpha0": h.card.alphaValue = 0
            case "orderedOut": h.card.orderOut(nil)
            default: break
            }
            h.spin(0.5)
            let meter = MainBusyMeter()
            meter.start()
            // Stack samples of every long turn, to see where the time goes.
            let trace = EdgeHitchTrace.shared
            EdgeHitchTrace.stallSampleAfter = 0.003
            defer { EdgeHitchTrace.stallSampleAfter = 0.012 }
            var stacks: [[UInt]] = []
            trace.entrySink = { stacks.append(contentsOf: $0.stacks) }
            trace.begin(motion: "probe", nominalInterval: 1.0 / 120)
            for _ in 0..<5 { load.changeTrackNow(); h.spin(1.5) }
            trace.end()
            h.spin(0.1)
            trace.entrySink = nil
            let total = meter.stop()
            var hist: [String: Int] = [:]
            for st in stacks {
                var seen = Set<String>()
                for pc in st {
                    var info = Dl_info()
                    guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0, let n = info.dli_sname else { continue }
                    seen.insert(String(cString: n))
                }
                for n in seen { hist[n, default: 0] += 1 }
            }
            let top = hist.filter { $0.key.contains("MusicMiniPlayerCore") }.sorted { $0.value > $1.value }.prefix(60).map { "  \($0.value)  \($0.key)" }.joined(separator: "\n")
            print("probe[\(mode)] \(stacks.count) samples, inclusive:\n\(top)")
            print("probe[\(mode)]: main-thread busy over 5 track changes = \(String(format: "%.0f", total))ms, worst turn \(String(format: "%.1f", meter.worst))ms")
            h.card.alphaValue = 1
        }
    }
}

/// Sums run-loop turn busy time on the main thread.
final class MainBusyMeter {
    private var observers: [CFRunLoopObserver] = []
    private var turnStart: CFTimeInterval = 0
    private(set) var total: Double = 0
    private(set) var worst: Double = 0

    func start() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [self] _, _ in turnStart = CACurrentMediaTime() }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { [self] _, _ in
            guard turnStart > 0 else { return }
            let ms = (CACurrentMediaTime() - turnStart) * 1000
            turnStart = 0
            total += ms; worst = max(worst, ms)
        }
        observers = [wake!, sleep!]
        for o in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes) }
    }

    func stop() -> Double {
        for o in observers { CFRunLoopObserverInvalidate(o) }
        return total
    }
}
