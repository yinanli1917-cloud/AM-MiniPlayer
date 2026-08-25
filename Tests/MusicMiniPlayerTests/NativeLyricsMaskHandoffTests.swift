import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// T2 bug #1 — "遮罩丢失" repro harness (founder report 2026-08-25):
//   after a handoff the incoming line shows its whole text ALREADY highlighted (per-word mask
//   gone), then "recovers" partway through the line.
//
// Founder rule: feel-class bugs are reproduced at the CODE level with injected deterministic
// clocks, never screen recordings. This drives the real surface across a 5→6 handoff on a
// WORD-LEVEL fixture (playback + wall clocks injected in lockstep, T0 seams) and reads, per frame,
// the incoming row's MAIN sweep truth:
//   - debugLastMainBrightOverlayPresent : true ⇒ the whole-line bright layer is showing (the
//     geometry-not-ready / line-level fallback path). On a word-level active line this IS the
//     "整行已高亮 / mask lost" state — the per-glyph path sets the whole-line string to nil.
//   - debugLastMainAppliedProgress vs debugLastMainExpectedProgress : how much of the line the
//     renderer actually revealed vs what the model wanted. applied ≫ expected = revealed too much.
//   - debugLastAppliedActivePerRunSweep : per-word mask engaged (true) vs whole-line fallback.
//
// The gate asserts the incoming word-level line NEVER renders its whole bright text while the
// model wants only a partial reveal, and — if it does — measures the window's duration in ms so
// "why do I occasionally see it" can be answered with a number.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsMaskHandoffTests: XCTestCase {

    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        hostedSurfaces.forEach { $0.stopAnimations() }
        hostedSurfaces.removeAll()
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        if let surface = view as? NativeLyricsSurfaceView { hostedSurfaces.append(surface) }
    }

    // Multi-word, ~3.2 s lines so the per-word sweep spans many frames and layout matters.
    private func makeRows(_ n: Int) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * 3.2, e = s + 3.2
            let w = (e - s) / 4
            let line = LyricLine(
                text: "line \(i) has four words", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "line ", startTime: s, endTime: s + w),
                    LyricWord(word: "\(i) ", startTime: s + w, endTime: s + 2 * w),
                    LyricWord(word: "has four ", startTime: s + 2 * w, endTime: s + 3 * w),
                    LyricWord(word: "words", startTime: s + 3 * w, endTime: e),
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

    struct MaskSample {
        let frame: Int
        let playback: TimeInterval
        let semantic: Int
        let rowActive: Bool
        let brightOverlayPresent: Bool   // whole-line bright layer showing (= mask-lost signature)
        let perRunSweep: Bool            // per-word mask engaged
        let expected: CGFloat            // model sweep progress
        let applied: CGFloat             // renderer-clipped sweep progress
        let brightOpacity: Float
    }

    @MainActor
    func test_wordLevelHandoff_incomingLineNeverShowsWholeLineHighlightWhileModelWantsPartial() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(20)
        surface.debugSkipDedupe = true

        let previousIndex = 5
        let incoming = previousIndex + 1
        let previousStart = rows[previousIndex].displayLine.line.startTime
        let handoffTime = rows[incoming].displayLine.line.startTime

        var wall: CFTimeInterval = 2_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        let step = 1.0 / 60.0
        func tick(_ playback: TimeInterval) {
            wall += step
            date = date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc))
            surface.debugTick(displayInterval: step)
            RunLoop.main.run(until: Date())
        }

        // Warm up on line 5 for >0.8 s (appear window) so the handoff runs in natural mode, and so
        // line 5's per-word sweep is fully engaged (geometry laid out) before we cross.
        let warmStart = previousStart + 0.1
        mc.syncPlaybackClock(to: warmStart, playing: true, at: date)
        surface.configure(config(rows, current: previousIndex, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<90 { tick(warmStart + TimeInterval(i) * step) }

        // Precondition: line 5 is rendering as a real per-word sweep (NOT whole-line fallback).
        if let r5 = surface.debugRowView(forIndex: previousIndex) {
            XCTAssertTrue(r5.debugLastAppliedActivePerRunSweep,
                          "precondition: the outgoing line must be in per-word sweep mode before the handoff")
        }

        // Census across the handoff: continue from ~0.13 s before the boundary for 3.2 s (a full line).
        let censusStart = handoffTime - 0.13
        var samples: [MaskSample] = []
        for i in 0..<200 {
            let playback = censusStart + TimeInterval(i) * step
            tick(playback)
            let sem = surface.debugNativeSemanticIndex ?? -1
            guard let row = surface.debugRowView(forIndex: incoming) else { continue }
            let active = sem == incoming
            samples.append(MaskSample(
                frame: i, playback: playback, semantic: sem, rowActive: active,
                brightOverlayPresent: row.debugLastMainBrightOverlayPresent,
                perRunSweep: row.debugLastAppliedActivePerRunSweep,
                expected: row.debugLastMainExpectedProgress ?? -1,
                applied: row.debugLastMainAppliedProgress ?? -1,
                brightOpacity: row.debugMainBrightOpacity
            ))
        }

        let active = samples.filter { $0.rowActive }
        XCTAssertGreaterThan(active.count, 30, "precondition: incoming line must be active for a good chunk of the census")

        // "mask lost" frame = incoming line active, whole-line bright layer showing (per-word mask NOT
        // engaged) while the model wants a partial reveal (expected < 0.9). That is exactly "整行已高亮".
        let maskLost = active.filter { $0.brightOverlayPresent && !$0.perRunSweep && $0.expected < 0.9 }
        // "over-reveal" frame = per-word path engaged but it clipped to far more than the model wanted.
        let overReveal = active.filter { $0.perRunSweep && ($0.applied - $0.expected) > 0.15 }

        if let first = active.first {
            let windowMs = Double(maskLost.count) * step * 1000
            print(String(format:
                "[MaskHandoff] incoming=%d activeFrames=%d firstActive@playback=%.3f (line starts %.3f) " +
                "maskLostFrames=%d (%.0f ms) overRevealFrames=%d",
                incoming, active.count, first.playback, handoffTime, maskLost.count, windowMs, overReveal.count))
            let lo = 0, hi = min(active.count - 1, 12)
            print("[MaskHandoff]  f  playback  sem act brightOverlay perRun  expect  applied  brOp")
            for s in active[lo...hi] {
                print(String(format: "[MaskHandoff] %2d  %8.3f  %3d  %@   %@         %@    %.3f   %.3f   %.2f",
                             s.frame, s.playback, s.semantic, s.rowActive ? "Y":"n",
                             s.brightOverlayPresent ? "WHOLE":"  -  ", s.perRunSweep ? "Y":"n",
                             s.expected, s.applied, s.brightOpacity))
            }
        }

        XCTAssertEqual(maskLost.count, 0,
            "incoming word-level line rendered its WHOLE bright text (per-word mask lost) on \(maskLost.count) active frames " +
            "while the model wanted a partial reveal — this is the '整行已高亮/遮罩丢失' bug")
        XCTAssertEqual(overReveal.count, 0,
            "incoming line's sweep revealed far more than the model wanted on \(overReveal.count) frames (stale/over-open mask)")
    }
}
