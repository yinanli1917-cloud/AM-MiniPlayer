import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Headless HANDOFF-DESYNC diagnostic — the "previous-line distortion + scale pop" class.
//
// Frame-by-frame perception of the user's recording showed, at every line change: the just-finished
// line FADES IN PLACE first (~0.17s, opacity/brightness drops while Y holds), THEN lurches into the
// scroll — and the scroll itself steps (a single-frame position jump, not a smooth ramp). The prior
// oscillation detector read "clean" because this is a DESYNC + STEP, not a rise-then-fall.
//
// This drives a REAL line handoff at ~1x and dumps the demoting line's channels (opacity, scale, Y)
// so we can measure two things objectively from the MODEL (not the lossy video):
//   1) DESYNC: how many frames pass between opacity starting to move and Y starting to move.
//   2) STEP: the largest single-frame |dY| and |dScale| during the handoff.
// Diagnostic first (prints the numbers); the gate assertions come once the fix target is known.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsHandoffDesyncTests: XCTestCase {

    private var hostWindow: NSWindow?
    override func tearDown() { hostWindow?.orderOut(nil); hostWindow = nil; super.tearDown() }

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
    }

    private func makeRows(_ n: Int) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * 1.8, e = TimeInterval(i) * 1.8 + 1.8
            let d = (e - s) / 3
            let line = LyricLine(
                text: "line \(i) words here", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "line ", startTime: s, endTime: s + d),
                    LyricWord(word: "\(i) ", startTime: s + d, endTime: s + 2 * d),
                    LyricWord(word: "words here", startTime: s + 2 * d, endTime: e),
                ]
            )
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(_ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    @MainActor
    func test_diagnose_previousLineFadeMoveDesyncAcrossHandoff() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(20)

        // Settle on line 2 (active) BEFORE the handoff. Keep the settle short: MusicController
        // interpolates the render clock forward on wall time, so a long spin at a fixed sync would
        // drift the clock past the handoff. A brief settle keeps the clock inside line 2 (t in 3.6..5.4).
        mc.syncPlaybackClock(to: 4.0, playing: true)
        surface.configure(config(rows, current: 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<24 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }

        surface.debugResetCensus()
        surface.debugCensusEnabled = true

        // Drive a MONOTONIC clock (never backward — a backward reset would be held as resync jitter and
        // freeze the semantic index) from inside line 2 across the 2 -> 3 handoff at t=5.4.
        let startReal = Date()
        let clockBase = 4.6            // just past the settle; line 2 still active
        while Date().timeIntervalSince(startReal) < 3.6 {
            let t = clockBase + Date().timeIntervalSince(startReal)
            mc.syncPlaybackClock(to: t, playing: true)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 2, mc: mc))
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }

        let sem = surface.debugSemanticTrace
        func analyze(_ idx: Int, label: String) {
            guard let tr = surface.debugCensusByIndex[idx] else { print("\(label): no census"); return }
            let op = tr.opacity, sc = tr.scale, yy = tr.y
            let n = min(op.count, min(sc.count, min(yy.count, sem.count)))
            guard n > 20 else { print("\(label): too few samples \(n)"); return }
            func onset(_ v: [CGFloat], eps: CGFloat) -> Int {
                guard let b = v.first else { return -1 }
                return (1..<n).first { abs(v[$0] - b) > eps } ?? -1
            }
            func maxStep(_ v: [CGFloat]) -> (CGFloat, Int) {
                var best: CGFloat = 0; var at = -1
                for i in 1..<n { let d = abs(v[i] - v[i-1]); if d > best { best = d; at = i } }
                return (best, at)
            }
            let tg = tr.target
            let opOn = onset(op, eps: 0.02), scOn = onset(sc, eps: 0.005), yOn = onset(yy, eps: 1.0)
            let tgOn = onset(tg, eps: 0.02)
            let (dY, dYat) = maxStep(yy), (dS, dSat) = maxStep(sc), (dO, dOat) = maxStep(op)
            print("\n=== \(label) (index \(idx)) ===")
            print("onset  TARGET:\(tgOn)  opacity:\(opOn)  scale:\(scOn)  Y:\(yOn)   target->opacity lag=\(opOn - tgOn)f")
            print("maxStep |dOpacity|=\(String(format: "%.3f", dO))@\(dOat)  |dScale|=\(String(format: "%.4f", dS))@\(dSat)  |dY|=\(String(format: "%.2f", dY))@\(dYat)")
            print("frame sem  target  opacity  scale     Y")
            for i in 0..<min(n, 60) {
                print(String(format: "%4d  %2d   %5.3f  %6.3f  %6.4f  %7.2f", i, Int(sem[i]), Double(tg[i]), Double(op[i]), Double(sc[i]), Double(yy[i])))
            }
        }
        let handoff = sem.firstIndex(where: { $0 != 2 }) ?? -1
        print("HANDOFF at census frame \(handoff) of \(sem.count) (semantic leaves index 2)")
        // Diagnostic-only: wall-clock pacing decides where the handoff lands. If it didn't capture
        // pre-handoff frames this run, skip rather than fail — this test documents the freeze, it is
        // not a gate.
        guard handoff > 3 else {
            print("(skipped: handoff landed at frame \(handoff); pacing didn't capture the onset this run)")
            return
        }
        analyze(2, label: "DEMOTING line")   // active -> previous
        analyze(3, label: "PROMOTING line")  // next -> active (does its scale POP to 1.0?)
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Is the "scale pop" a PRESENTATION-layer transient? The model scale is a smooth ramp, but the row
    // scale lives on the layer TRANSFORM (setPositioning), and AppKit resets a layer-backed view's
    // transform on its own layout() pass. If the ON-SCREEN (presentation) scale diverges from the
    // model-applied transform scale on a handoff frame, that divergence IS the pop the model census
    // can't see. Sample both per frame across a handoff.
    // ───────────────────────────────────────────────────────────────────────────
    @MainActor
    func test_diagnose_presentationScalePopVsModelScale() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(20)

        mc.syncPlaybackClock(to: 4.0, playing: true)
        surface.configure(config(rows, current: 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<24 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }

        func scale(_ t: CGAffineTransform) -> CGFloat { sqrt(t.a * t.a + t.c * t.c) }
        var samples: [(sem: Int, applied: CGFloat, posScale: CGFloat, host: Int, reuse: Int, y: CGFloat)] = []

        let startReal = Date()
        let clockBase = 4.6
        while Date().timeIntervalSince(startReal) < 3.2 {
            let t = clockBase + Date().timeIntervalSince(startReal)
            mc.syncPlaybackClock(to: t, playing: true)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 2, mc: mc))
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            // Sample the line that was active at start (index 2) as it demotes.
            if let v = surface.debugRowView(forIndex: 2), let layer = v.layer {
                let applied = scale(layer.affineTransform())
                samples.append((surface.debugNativeSemanticIndex ?? 2, applied, v.debugPositioningScale,
                                v.currentRow?.index ?? -1, v.debugPrepareForReuseCount, v.frame.origin.y))
            }
        }

        XCTAssertGreaterThan(samples.count, 30, "must sample the handoff")
        // Only a valid gate when the demotion was actually captured (applied scale fell below 0.97);
        // otherwise pacing missed the handoff and an empty `pops` would be a false pass.
        let demotionCaptured = samples.contains { $0.applied < 0.97 }
        guard demotionCaptured else {
            print("(skipped: demotion not captured this run — pacing missed the handoff)")
            return
        }
        // Frames where applied scale POPPED back up to ~1.0 after having demoted below 0.99.
        var pops: [Int] = []
        for i in 1..<samples.count where samples[i].applied - samples[i-1].applied > 0.03 && samples[i].applied > 0.99 {
            pops.append(i)
        }
        print("\n=== APPLIED scale POPS on the previous line (index 2) ===")
        print("pop frames (applied jumped up to ~1.0): \(pops)")
        // Print around the first pop so the mechanism is visible: does positioningScale jump, does the
        // hosting index change, does prepareForReuse fire?
        let center = pops.first ?? (samples.firstIndex(where: { $0.applied < 0.97 }) ?? 0)
        let lo = max(0, center - 8), hi = min(samples.count, center + 8)
        print("frame sem  appliedScale  posScale  hostIdx  reuseCount  frameY")
        for i in lo..<hi {
            let s = samples[i]
            print(String(format: "%4d  %2d   %8.4f    %7.4f   %4d      %4d     %7.2f",
                         i, s.sem, Double(s.applied), Double(s.posScale), s.host, s.reuse, Double(s.y)))
        }
        // GATE: once the previous line has demoted (applied scale below 0.97), its ON-SCREEN scale must
        // never pop back up to full size. Before the fix, AppKit resets the transform to identity and the
        // churn guard (trusting a stale ivar) refuses to re-apply 0.95 — the previous line pops to 1.0.
        XCTAssertTrue(pops.isEmpty,
            "previous-line SCALE POP: applied scale jumped back to ~1.0 at frames \(pops) while the model held 0.95")
    }
}
