/**
 * [INPUT]: NSView (hosting view) whose CALayer tree to walk; started at the
 *          beginning of a collapse/expand request.
 * [OUTPUT]: EdgeCollapseProbe.record(view:label:) — when EDGECOLLAPSE_PROBE=1,
 *           walks the layer tree at ~60Hz for `durationMs` and logs
 *           `[EdgeCollapse] probe frame=<n> t=<ms> label=<name>
 *           layer=<class> boundsW=<> boundsH=<> posX=<> posY=<>` for every
 *           layer whose class name contains "glass" or "backdrop" —
 *           top-level task instruction #7, reusing
 *           research/spikes/glass-morph-spike/main.swift's per-frame CA
 *           layer-tree enumeration technique (`walkLayers`/`recordMorphFrame`).
 * [POS]: Standalone spike probe instrumentation, consumed by `probe.sh`'s
 *        PASS/FAIL continuity check.
 * [PROTOCOL]: Public API only — CALayer/.sublayers/.presentation(), no
 *             CABackdropLayer symbol reference, no other private API. Zero
 *             cost when EDGECOLLAPSE_PROBE is unset (the `isActive` guard is
 *             checked before any Timer is scheduled).
 */

import AppKit
import QuartzCore

enum EdgeCollapseProbe {
    static let isActive = ProcessInfo.processInfo.environment["EDGECOLLAPSE_PROBE"] == "1"

    private static var timer: Timer?
    private static var frameIndex = 0
    private static var t0: CFTimeInterval = 0
    private static weak var trackedView: NSView?

    /// Starts a ~16ms-cadence layer-tree walk for `durationMs` milliseconds
    /// (default covers the longest transition — expand at 360ms — with
    /// margin). Re-entrant: a new `record` call cancels any prior timer.
    static func record(view: NSView, label: String, durationMs: Int = 700) {
        guard isActive else { return }
        timer?.invalidate()
        trackedView = view
        frameIndex = 0
        t0 = CACurrentMediaTime()
        print("[EdgeCollapse] probe begin=\(label)")
        // Called directly (no `Task { @MainActor in ... }` hop): this Timer
        // is added to the main run loop in `.common` mode, which already
        // fires synchronously on the main thread — routing each tick
        // through the Swift concurrency executor instead measurably
        // COALESCED ticks in testing (several identical readings landing at
        // the same millisecond, ~140ms after the previous one), which is a
        // probe-instrument artifact, not a real animation stutter. Calling
        // straight through keeps each tick tied to its actual wall-clock
        // run-loop turn.
        let newTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            tick(label: label)
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(durationMs) / 1000.0) {
            timer?.invalidate()
            timer = nil
            print("[EdgeCollapse] probe end=\(label)")
        }
    }

    private static func tick(label: String) {
        guard let trackedView, let rootLayer = trackedView.layer else { return }
        let now = CACurrentMediaTime()
        let ms = Int(((now - t0) * 1000).rounded())
        var stack: [CALayer] = [rootLayer]
        while let layer = stack.popLast() {
            let className = NSStringFromClass(type(of: layer))
            let lower = className.lowercased()
            if lower.contains("glass") || lower.contains("backdrop") {
                let presented = layer.presentation() ?? layer
                print("[EdgeCollapse] probe frame=\(frameIndex) t=\(ms) label=\(label) layer=\(className) boundsW=\(presented.bounds.width) boundsH=\(presented.bounds.height) posX=\(presented.position.x) posY=\(presented.position.y)")
            }
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        frameIndex += 1
    }
}
