/**
 * [INPUT]: CFTimeInterval t0 (transition start, CACurrentMediaTime()),
 *          EdgePresentation, clock name, event name, CGRect (for frame logs)
 * [OUTPUT]: EdgeCollapseLog.clock(...) / .frame(...) — timestamped stdout
 *           lines, format pinned by design §9: "code-level gate (not eyes on
 *           screen)" + top-level task instruction #9.
 * [POS]: Standalone spike logging. App-portable in spirit (mirrors
 *        MusicMiniPlayerCore/Utils/DebugLogger.swift's plain-print style) but
 *        kept spike-local since the real app's DebugLogger has file-sink/
 *        release-strip plumbing this prototype doesn't need.
 * [PROTOCOL]: Keep the two line formats byte-stable — they're what a founder
 *             or a future deterministic-replay test greps for.
 */

import Foundation
import QuartzCore

public enum EdgeCollapseLog {
    /// `[EdgeCollapse] t=<ms since transition start> state=<..> clock=<geometry|hero|material|goo> event=<start|settle>`
    public static func clock(
        t0: CFTimeInterval,
        now: CFTimeInterval = CACurrentMediaTime(),
        state: EdgePresentation,
        clock: String,
        event: String
    ) {
        let ms = Int(((now - t0) * 1000).rounded())
        print("[EdgeCollapse] t=\(ms) state=\(state.rawValue) clock=\(clock) event=\(event)")
    }

    /// `[EdgeCollapse] frame=<x,y,w,h> state=<..>`
    public static func frame(_ rect: CGRect, state: EdgePresentation) {
        let x = Int(rect.origin.x.rounded())
        let y = Int(rect.origin.y.rounded())
        let w = Int(rect.width.rounded())
        let h = Int(rect.height.rounded())
        print("[EdgeCollapse] frame=\(x),\(y),\(w),\(h) state=\(state.rawValue)")
    }
}
