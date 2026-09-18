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
// Root cause isolated for 59647e1 (ORIGINAL, pre-3h-round form): `NativeLyricsVisualMotionState.
// isSettled` covered ONLY opacity/scale/blur convergence — never the row's Y POSITION, a separate
// spring system (`LyricsPresentationEngine`/`rowStates`). Blur is a STEPPED channel (snaps
// instantly on target change), so `isSettled` could read true on the very same frame a distant
// row's blur bucket changed, while that row's Y POSITION was still actively springing — and the
// OLD manual force-recapture (toggle shouldRasterize off then on whenever the applied blur
// differed from a cached signature) would force a fresh bitmap capture mid-flight, reading on
// screen as a blurry snapshot "falling" into its final slot.
//
// 2026-09-18 (3h round, item 1 FINAL FORM, founder-dictated): the fix for THIS class of bug is no
// longer "gate the manual recapture on isSettled" — there IS no manual recapture anymore
// (NativeLyricsRowView.refreshRasterization just sets `shouldRasterize` directly; CA re-derives
// the cached bitmap on its own whenever a rasterized layer's content genuinely changes). The new
// contract this test enforces: once a row deactivates, `shouldRasterize` must never FLIP again
// while that row is still visibly moving (position motion, tracked the same way as before via
// frame-to-frame Y delta) — a flip mid-flight would mean the activation/deactivation edge itself
// landed awkwardly relative to the row's own motion, which the renderer's activation bookkeeping
// (`textActiveByRowIndex`) should never produce on an ordinary natural line change. This is a
// WEAKER but still meaningful invariant than "never rasterize during motion" (the old contract) —
// rasterizing WHILE a row moves is now by design (blur is stepped, so the bitmap is never stale
// relative to blur; only frame/opacity change during motion, and both apply AFTER rasterization).
// See research/repro-2026-09-18-lyrics-render-3d.md §1(prepend) for the original defect history.
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
        var lastRasterized: [Int: Bool] = [:]
        struct Anomaly { let rowIndex: Int; let t: TimeInterval; let dy: CGFloat; let blur: CGFloat }
        var anomalies: [Anomaly] = []

        func sample(_ t: TimeInterval) {
            for idx in 0..<rows.count {
                guard let v = surface.debugRowView(forIndex: idx) else { continue }
                let y = v.frame.origin.y
                let blur = v.debugAppliedBlurRadius
                let rasterized = v.layer?.shouldRasterize ?? false
                if let prevY = lastY[idx], let prevRasterized = lastRasterized[idx] {
                    let dy = abs(y - prevY)
                    let flippedThisFrame = rasterized != prevRasterized
                    // NEW CONTRACT (2026-09-18, item 1 final form): shouldRasterize must not FLIP
                    // on a frame where the row is still visibly in flight (>3pt in one 1/60s
                    // tick — real spring-settle motion, not float noise). Rasterizing (or staying
                    // rasterized) WHILE the row moves is fine by design; only a mid-flight FLIP
                    // would indicate the activation bookkeeping landed awkwardly.
                    if flippedThisFrame && blur > 0.01 && dy > 3.0 {
                        anomalies.append(Anomaly(rowIndex: idx, t: t, dy: dy, blur: blur))
                    }
                }
                lastY[idx] = y
                lastRasterized[idx] = rasterized
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
            "A row's shouldRasterize must never FLIP while its own frame is still moving "
                + "(>3pt/frame) with nonzero blur — the frozen-snapshot-falls-into-place defect "
                + "class, under the new (2026-09-18) contract. Anomalies: "
                + anomalies.map { "idx=\($0.rowIndex) t=\(String(format: "%.3f", $0.t)) dy=\(String(format: "%.2f", $0.dy)) blur=\(String(format: "%.2f", $0.blur))" }.joined(separator: "; ")
        )
    }
}
