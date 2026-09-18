import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 2026-09-18: coordinator-escalated founder report on stage bundle 3d — "每一次切行都出现一条
// 很模糊的行掉下来" (every line change drops in one very blurry row). This did NOT happen on 3c.
// The only render-affecting commits new in 3d are 59647e1 (revoke rasterization the same frame
// text phase activates + force-recapture the cached bitmap on a blur/geometry signature change)
// and 74507a7 (scale-transform X anchor). 74507a7 only moves TEXT sublayers horizontally by a
// fixed, deterministic ≤1.6pt on the SAME frame the row's own scale changes (no new capture/
// snapshot event, no vertical component) — analytically not a plausible source of a "falling
// blurry ghost"; not exercised further here.
//
// Root cause isolated for 59647e1: `NativeLyricsVisualMotionState.isSettled` (consumed by
// `applyRasterizationPolicy(isSettled:isActive:)`) covers ONLY opacity/scale/blur convergence —
// it has NEVER included the row's Y POSITION, which is a completely separate spring system
// (`LyricsPresentationEngine`/`rowStates`, driven by `presentationEngine.update`). In the
// shipping default (`NativeLyricsFeelParity.blurMode == .current`), blur is a STEPPED channel:
// `NativeLyricsVisualMotionState.setTarget` snaps `blur = nextTarget.blur` (with `blurVelocity =
// 0`) the INSTANT a row's target changes — it does not spring. On a natural line change, a
// distant row's blur target (a function of `abs(displayIndex - currentIndex)`) very often
// changes by exactly one bucket, and that new blur value is APPLIED IMMEDIATELY, so
// `visual.isSettled` can read true on the very same frame the line changes — while that same
// row's Y POSITION is still actively springing toward its new slot (a real, multi-frame motion,
// entirely decoupled from `isSettled`). 59647e1 added a force-recapture whenever the applied
// blur differs from the last-captured signature while `isSettled && !isActive` — so it can
// (and, per this test, does) force a FRESH rasterization capture of a row while that row is
// still visibly moving. The cached bitmap is correct content-wise but frozen mid-transit
// relative to any transient state; on screen this reads as a blurry snapshot "falling" into its
// final slot, matching the founder's report exactly. See research/repro-2026-09-18-lyrics-render-3d.md §1(prepend).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsRenderDefects20260918ReproTests: XCTestCase {
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
            lineInterval: 1.2, hasSyllableSync: true,
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

    /// 24 short syllable-synced lines, 1.2s apart — long enough that several distant rows cross
    /// a blur-bucket boundary on every natural line change (real playback shape, not a synthetic
    /// worst case).
    private func longRows() -> [LayerBackedLyricRow] {
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for i in 0..<24 {
            let words = ["la", "la", "la"]
            var t = start
            var lyricWords: [LyricWord] = []
            for w in words {
                lyricWords.append(LyricWord(word: w, startTime: t, endTime: t + 0.3))
                t += 0.3
            }
            let line = LyricLine(text: words.joined(separator: " "), startTime: start, endTime: t, words: lyricWords)
            rows.append(row(for: line, index: i))
            start = t + 0.3
        }
        return rows
    }

    @MainActor
    func test_naturalLineChange_neverForcesRasterizationCaptureWhileRowStillInFlight() {
        let rows = longRows()
        let panelWidth: CGFloat = 320
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 60
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        var lastY: [Int: CGFloat] = [:]
        var lastCaptureCount: [Int: Int] = [:]
        struct Anomaly { let rowIndex: Int; let t: TimeInterval; let dy: CGFloat; let blur: CGFloat }
        var anomalies: [Anomaly] = []

        func sample(_ t: TimeInterval) {
            for idx in 0..<rows.count {
                guard let v = surface.debugRowView(forIndex: idx) else { continue }
                let y = v.frame.origin.y
                let blur = v.debugAppliedBlurRadius
                let captureCount = v.debugRasterizationCaptureCount
                if let prevY = lastY[idx], let prevCapture = lastCaptureCount[idx] {
                    let dy = abs(y - prevY)
                    let capturedThisFrame = captureCount > prevCapture
                    // A fresh capture landing on a frame where the row is still visibly in
                    // flight (>3pt in one 1/60s tick — real spring-settle motion, not float
                    // noise) is exactly the "rasterized bitmap frozen mid-transit" defect.
                    if capturedThisFrame && blur > 0.01 && dy > 3.0 {
                        anomalies.append(Anomaly(rowIndex: idx, t: t, dy: dy, blur: blur))
                    }
                }
                lastY[idx] = y
                lastCaptureCount[idx] = captureCount
            }
        }

        func tick(_ t: TimeInterval) {
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
            surface.configure(config(rows: rows, current: current, mc: mc, width: panelWidth))
            surface.layoutSubtreeIfNeeded()
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            surface.debugTick(displayInterval: 1.0 / 60.0)
            sample(t)
        }

        // Play through several natural line changes at real 60Hz cadence.
        var t: TimeInterval = 0
        while t < 12.0 {
            tick(t)
            t += 1.0 / 60.0
        }

        XCTAssertTrue(
            anomalies.isEmpty,
            "A row's rasterized bitmap must never be force-recaptured while its own frame is "
                + "still moving (>3pt/frame) with nonzero blur — the frozen-snapshot-falls-into-"
                + "place defect. Anomalies: "
                + anomalies.map { "idx=\($0.rowIndex) t=\(String(format: "%.3f", $0.t)) dy=\(String(format: "%.2f", $0.dy)) blur=\(String(format: "%.2f", $0.blur))" }.joined(separator: "; ")
        )
    }
}
