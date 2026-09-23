/**
 * [INPUT]: CFTimeInterval t0 (transition start, CACurrentMediaTime()),
 *          EdgePresentation from/to, animation name, event name.
 * [OUTPUT]: EdgeCollapseLog.event(...) — timestamped stdout line, format
 *           pinned by top-level task instruction #7.
 * [POS]: Standalone spike logging. App-portable in spirit (mirrors
 *        MusicMiniPlayerCore/Utils/DebugLogger.swift's plain-print style)
 *        but kept spike-local since the real app's DebugLogger has
 *        file-sink/release-strip plumbing this prototype doesn't need.
 * [PROTOCOL]: Keep the line format byte-stable — probe.sh's PASS/FAIL check
 *             and any future deterministic-replay tooling grep for it.
 */

import Foundation
import QuartzCore

public enum EdgeCollapseLog {
    /// `[EdgeCollapse] t=<ms since transition start> state=<from>→<to> anim=<name> event=start|settle`
    public static func event(
        t0: CFTimeInterval,
        now: CFTimeInterval = CACurrentMediaTime(),
        from: EdgePresentation,
        to: EdgePresentation,
        anim: String,
        event: String
    ) {
        let ms = Int(((now - t0) * 1000).rounded())
        print("[EdgeCollapse] t=\(ms) state=\(from.rawValue)\u{2192}\(to.rawValue) anim=\(anim) event=\(event)")
    }
}
