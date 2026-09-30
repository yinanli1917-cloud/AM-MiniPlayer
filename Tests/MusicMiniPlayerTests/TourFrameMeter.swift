/**
 * [INPUT]: CoreFoundation run-loop observers, MusicMiniPlayerAppKit's TourPerfProbe (DEBUG).
 * [OUTPUT]: TourFrameMeter — per-run-loop-turn busy time of the main thread plus the tour's own tick
 *           intervals and apply() times; TourFrameStats (max / p95 / count over 16.7 ms).
 * [POS]: Tests. "Measure before changing anything" (founder 2026-09-29, item 5): every frame of the
 *        check -> handoff -> transition sequence is timed on the real windows, and the same meter is the
 *        regression guard after the fix.
 */

import Foundation
import QuartzCore
@testable import MusicMiniPlayerAppKit

struct TourFrameStats: CustomStringConvertible {
    var count = 0
    var maxMs = 0.0
    var p95Ms = 0.0
    var over16 = 0
    var over33 = 0

    init(_ seconds: [Double], budget: Double = 1.0 / 60.0) {
        let ms = seconds.map { $0 * 1000 }.sorted()
        count = ms.count
        maxMs = ms.last ?? 0
        p95Ms = ms.isEmpty ? 0 : ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))]
        over16 = ms.filter { $0 > budget * 1000 }.count
        over33 = ms.filter { $0 > 33.4 }.count
    }

    var description: String {
        String(format: "n=%d max=%.2fms p95=%.2fms >16.7ms=%d >33ms=%d", count, maxMs, p95Ms, over16, over33)
    }
}

@MainActor
final class TourFrameMeter {
    private var observer: CFRunLoopObserver?
    private var turnStart: CFAbsoluteTime?
    private(set) var busy: [Double] = []
    private(set) var busyAt: [(t: Double, busy: Double)] = []
    private(set) var intervals: [String: [Double]] = [:]
    private(set) var applies: [String: [Double]] = [:]
    private var startedAt = CACurrentMediaTime()

    func start() {
        busy = []; busyAt = []; intervals = [:]; applies = [:]
        startedAt = CACurrentMediaTime()
        #if DEBUG
        TourPerfProbe.resetCounts()
        TourPerfProbe.tickSink = { [weak self] source, interval, apply in
            // Called on the main thread from the tour's own tick.
            MainActor.assumeIsolated {
                self?.intervals[source, default: []].append(interval)
                self?.applies[source, default: []].append(apply)
            }
        }
        #endif
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 4_000_000) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting {
                    self.turnStart = now
                } else if let start = self.turnStart {
                    let b = now - start
                    self.busy.append(b)
                    self.busyAt.append((CACurrentMediaTime() - self.startedAt, b))
                    self.turnStart = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        #if DEBUG
        TourPerfProbe.tickSink = nil
        #endif
    }

    var busyStats: TourFrameStats { TourFrameStats(busy) }
    /// Only the turns that did real work (>= 0.5 ms): idle wake-ups (timers, input) would drown the percentiles.
    var workStats: TourFrameStats { TourFrameStats(busy.filter { $0 >= 0.0005 }) }
    func applyStats(_ source: String) -> TourFrameStats { TourFrameStats(applies[source] ?? []) }
    func intervalStats(_ source: String) -> TourFrameStats { TourFrameStats(intervals[source] ?? []) }

    func report(_ title: String) -> String {
        var lines = ["[frames] \(title)"]
        lines.append("[frames]   run-loop turn busy      : \(busyStats)")
        lines.append("[frames]   turns doing work (>=0.5ms): \(workStats)")
        for k in intervals.keys.sorted() {
            lines.append("[frames]   \(k) tick interval   : \(intervalStats(k))")
            lines.append("[frames]   \(k) apply() time    : \(applyStats(k))")
        }
        #if DEBUG
        var counts = ""
        for c in TourPerfProbe.Counter.allCases { counts += " \(c.rawValue)=\(TourPerfProbe.count(c))" }
        lines.append("[frames]   redraws:\(counts)")
        #endif
        let worst = busyAt.sorted { $0.busy > $1.busy }.prefix(5).map { String(format: "%.2fs:%.1fms", $0.t, $0.busy * 1000) }
        lines.append("[frames]   worst turns: \(worst.joined(separator: " "))")
        return lines.joined(separator: "\n")
    }
}
