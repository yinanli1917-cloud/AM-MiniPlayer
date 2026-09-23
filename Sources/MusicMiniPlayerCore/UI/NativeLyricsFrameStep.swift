import Foundation

/// 2026-09-21: the presentation springs used to advance by the RAW wall-clock gap between display
/// link callbacks. Callback timing jitters by a fraction of a frame while the frames themselves are
/// presented on the fixed vsync grid, so consecutive on-screen displacements came out uneven
/// (founder 60fps recording, 下雨天: per-frame row steps −2,−8,−3,−7… during one smooth wave).
/// Step the simulation by whole display intervals instead: the number of vsyncs that elapsed,
/// never zero once a frame is due, and capped so a long stall does not fling the springs.
enum NativeLyricsFrameStep {
    static let maxIntervalsPerStep: Double = 4

    /// `raw` = wall-clock seconds since the previous tick; `nominal` = the display's frame interval.
    /// Returns k×nominal with k = round(raw / nominal) clamped to 1…maxIntervalsPerStep. Falls back to
    /// `raw` when either input is not usable.
    static func quantizedDelta(raw: TimeInterval, nominal: TimeInterval?) -> TimeInterval {
        guard let nominal, nominal > 0, raw.isFinite, raw >= 0 else { return max(0, raw) }
        let k = (raw / nominal).rounded()
        return min(maxIntervalsPerStep, max(1, k)) * nominal
    }
}
