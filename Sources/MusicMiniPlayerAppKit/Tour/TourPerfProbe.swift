/**
 * [INPUT]: Foundation only.
 * [OUTPUT]: Exports TourPerfProbe — DEBUG-only counters and a tick sink the frame-budget tests read.
 * [POS]: MusicMiniPlayerAppKit/Tour. The tour's smoothness is judged on numbers (founder 2026-09-29: "完全不丝滑"),
 *        so the real windows report how often each of them redraws and how long each frame's apply() took.
 *        Compiled out of release builds; in DEBUG a counter bump is one locked integer add.
 */

import Foundation

#if DEBUG
enum TourPerfProbe {
    enum Counter: String, CaseIterable {
        case overlayRender      // the ring overlay's Canvas closure
        case cardBody           // TourCardRoot.body
        case fxRender           // the FX window's Canvas closure
        case cardSetFrame       // card window setFrame calls
        case overlaySetFrame
    }

    private static let lock = NSLock()
    private static var counts: [Counter: Int] = [:]
    private static var sinkStorage: ((String, Double, Double) -> Void)?

    static func bump(_ c: Counter) {
        lock.lock(); counts[c, default: 0] += 1; lock.unlock()
    }

    static func count(_ c: Counter) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[c, default: 0]
    }

    static func resetCounts() {
        lock.lock(); counts = [:]; lock.unlock()
    }

    /// (source, seconds since the previous tick of that source, seconds spent applying this tick).
    static var tickSink: ((String, Double, Double) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sinkStorage }
        set { lock.lock(); sinkStorage = newValue; lock.unlock() }
    }

    static func tick(_ source: String, interval: Double, apply: Double) {
        tickSink?(source, interval, apply)
    }
}
#endif
