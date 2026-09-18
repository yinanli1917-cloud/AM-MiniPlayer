import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Defect C2 investigation (founder correction, 2026-09-17): "切行跳变" is a SEPARATE,
// occasional, larger jump/dislocation from C1's every-time 1-2px glyph-layout disagreement.
// Founder's own hypothesis: a clock-correction event landing near a line boundary makes the
// semantic index flip forward-then-back (or the reverse) within a short window, producing a
// double snap that reads as a jump.
//
// research/nanopod_debug_2026-09-17.log correlation (see the session report): of 11 accepted
// (non-suppressed) DRIFT CORRECTION events with 0.2s<=|drift|<5s in this real session, only 1
// has ANY LineGaps sample within a 4s window — the LineGaps probe (armed once per
// activeTextLineChanged, sampling ~1.0-1.2s later) is too sparse to correlate against clock
// events at the needed granularity from the EXISTING log. This test instead INJECTS the same
// shape of correction (a real MusicController.syncPlaybackClock backward step, matching the
// magnitude class recorded in the founder's log: 0.35-0.85s) on a real, deterministically-
// clocked NativeLyricsSurfaceView, timed to land within a line's own boundary-crossing window,
// and watches the semantic index / row Y every frame for a transient double-flip.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LineJumpClockCorrelationTests: XCTestCase {

    private var hostWindow: NSWindow?
    @MainActor override func tearDown() { hostWindow?.orderOut(nil); hostWindow = nil; super.tearDown() }

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

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                    isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 3, hasSyllableSync: false,
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

    private func rows(count: Int, span: TimeInterval = 3) -> [LayerBackedLyricRow] {
        (0..<count).map { i in
            row(for: LyricLine(text: "line \(i) words here", startTime: TimeInterval(i) * span, endTime: TimeInterval(i + 1) * span), index: i)
        }
    }

    /// Drives the surface across a line boundary (rows[2] -> rows[3] at t=9), injecting a
    /// backward clock correction of `driftMagnitude` seconds at `correctionLandsAt` (real wall-
    /// clock ticks continue normally otherwise — this mimics a genuine `syncPlaybackClock` call
    /// from a real ScriptingBridge poll landing, not a synthetic index override). Returns the
    /// per-frame semantic-index trace so the caller can check for a transient double-flip.
    @MainActor
    private func driveAcrossBoundary(driftMagnitude: TimeInterval, correctionLandsAt: TimeInterval) -> [Int] {
        let rowsData = rows(count: 6)
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 60
        mc.isPlaying = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        var trace: [Int] = []
        var playbackTime: TimeInterval = 7.0 // start just before the row2->row3 boundary at t=9
        var correctionApplied = false
        let frameInterval: TimeInterval = 1.0 / 60.0
        while playbackTime < 11.0 {
            // Inject the correction exactly once, when real playback time crosses the requested point.
            if !correctionApplied, playbackTime >= correctionLandsAt {
                playbackTime -= driftMagnitude
                correctionApplied = true
            }
            mc.syncPlaybackClock(to: playbackTime, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: playbackTime, rows: rowsData, fallback: 0)), rowsData.count - 1)
            surface.configure(config(rows: rowsData, current: current, mc: mc, width: 360))
            surface.layoutSubtreeIfNeeded()
            wall += frameInterval
            date = date.addingTimeInterval(frameInterval)
            surface.debugTick(displayInterval: frameInterval)
            trace.append(surface.debugNativeSemanticIndex ?? -1)
            playbackTime += frameInterval
        }
        return trace
    }

    /// Baseline: clean forward crossing, no correction — the index trace must monotonically
    /// step 2 -> 3 exactly once, never revisiting 2 after first reaching 3.
    @MainActor
    func test_baseline_cleanBoundaryCrossing_neverDoubleFlips() {
        let trace = driveAcrossBoundary(driftMagnitude: 0, correctionLandsAt: 999)
        assertNoDoubleFlip(trace, label: "baseline")
    }

    /// Founder's log magnitude class (0.35-0.85s backward correction), landing exactly at the
    /// moment the raw clock is within the line boundary's own crossing window.
    @MainActor
    func test_backwardCorrection_0_5s_landingAtBoundary_checksForDoubleFlip() {
        let trace = driveAcrossBoundary(driftMagnitude: 0.5, correctionLandsAt: 9.02)
        assertNoDoubleFlip(trace, label: "0.5s correction at boundary+0.02")
    }

    @MainActor
    func test_backwardCorrection_0_85s_landingJustBeforeBoundary_checksForDoubleFlip() {
        let trace = driveAcrossBoundary(driftMagnitude: 0.85, correctionLandsAt: 8.95)
        assertNoDoubleFlip(trace, label: "0.85s correction at boundary-0.05")
    }

    @MainActor
    func test_backwardCorrection_0_35s_landingJustAfterBoundary_checksForDoubleFlip() {
        let trace = driveAcrossBoundary(driftMagnitude: 0.35, correctionLandsAt: 9.10)
        assertNoDoubleFlip(trace, label: "0.35s correction at boundary+0.10")
    }

    private func assertNoDoubleFlip(_ trace: [Int], label: String) {
        // A "double flip" = the index reaches a HIGHER value, then drops back to a LOWER value,
        // then rises again — i.e. it is not monotonically non-decreasing once index 0 ticks are
        // discounted. Print the compressed transition sequence for evidence either way.
        var transitions: [Int] = []
        for v in trace where v != -1 {
            if transitions.last != v { transitions.append(v) }
        }
        print("[C2-CLOCK] \(label): transition sequence = \(transitions)")
        var isMonotonic = true
        for i in 1..<max(1, transitions.count) where i < transitions.count {
            if transitions[i] < transitions[i - 1] { isMonotonic = false }
        }
        XCTAssertTrue(isMonotonic, "\(label): semantic index was NOT monotonic across the boundary — transitions=\(transitions) (a double-flip / snap-back was observed)")
    }
}
