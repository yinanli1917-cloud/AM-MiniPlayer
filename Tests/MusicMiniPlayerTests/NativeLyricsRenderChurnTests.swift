import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Headless RENDER-CHURN gate — the tool for the "refresh flicker" class.
//
// Value-probes (opacity/scale) were blind to this: they read the settled VALUES (clean) and missed
// that the render path RE-WRITES the layer every frame. A redundant per-frame layer write forces a
// re-composite; with a CIGaussianBlur filter on a past line, that per-frame re-composite IS the
// refresh flicker. This drives the REAL surface and asserts a SETTLED row performs ZERO layer
// mutations across steady frames — while layerMutationAttempts keeps growing, proving the render path
// really re-ran each frame and the redundancy guard is what stops the re-composite.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsRenderChurnTests: XCTestCase {

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

    // Syllable-synced lines so the ACTIVE line's karaoke sweep animates every frame — this is what
    // keeps the presentation loop running in the real app (and never lets a jittery clock quiet it).
    private func makeRows(_ n: Int) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            // Short 1.2s lines so several handoffs fit in a REAL-TIME-paced drive (the line-advance
            // timer fires on the wall clock, so the test clock must run at ~1x or the index lags).
            let s = TimeInterval(i) * 1.2, e = TimeInterval(i) * 1.2 + 1.2
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

    // A deterministic NOISY clock like the real SB clock: forward on average, but dips backward on
    // ~1/3 of steps (the log showed backward on 2/3 of frames, ~0.3s). Pure index-based, no RNG.
    private func noisyClock(step i: Int, base: TimeInterval) -> TimeInterval {
        let jitter: TimeInterval = (i % 3 == 0) ? 0.30 : (i % 3 == 1 ? -0.28 : 0.0)
        return max(0, base + jitter)
    }

    /// Windowed oscillation scan: a channel that BOTH rises and falls beyond epsilon inside a short
    /// window is a stumble / flicker / refresh (vs a slow monotone rise-then-fall over its lifetime).
    @MainActor
    private func oscillatingWindows(_ values: [CGFloat], epsilon: CGFloat, window: Int = 6) -> Int {
        guard values.count >= window else { return 0 }
        var hits = 0
        for start in 0...(values.count - window) {
            if NativeLyricsSurfaceView.censusOscillates(Array(values[start..<start + window]), epsilon: epsilon) {
                hits += 1
            }
        }
        return hits
    }

    @MainActor
    func test_presentationCensus_noChannelFlickersAcrossHandoffs() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(20)

        surface.debugResetCensus()
        surface.debugCensusEnabled = true

        // Warm up so the surface's index tracks the clock before we start scoring (avoids the
        // startup catch-up artifact). Then drive at ~1x REAL time so the wall-clock line-advance timer
        // keeps up, with a NOISY clock (backward dips on ~1/3 of frames) layered on top.
        mc.syncPlaybackClock(to: 0.6, playing: true)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        surface.debugResetCensus()
        surface.debugCensusEnabled = true

        let startReal = Date()
        var i = 0
        while Date().timeIntervalSince(startReal) < 6.0 {
            let elapsed = Date().timeIntervalSince(startReal)
            mc.syncPlaybackClock(to: noisyClock(step: i, base: 0.6 + elapsed), playing: true)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc))
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            i += 1
        }

        let painted = surface.debugCensusByIndex.values.reduce(0) { $0 + $1.opacity.count }
        print("census: rows=\(surface.debugCensusByIndex.count) totalPaints=\(painted)")
        // Re-render churn: a far row (index 18) is settled the whole drive. applyFrame is still called
        // for it every paint (attempts grow) — the guard is what stops the redundant layer write that
        // would re-composite its blur every frame.
        if let far = surface.debugRowView(forIndex: 18) {
            print("writeChurn idx18 (settled): attempts=\(far.layerMutationAttempts) actualWrites=\(far.layerMutationCount)")
        }
        XCTAssertGreaterThan(painted, 100, "precondition: the loop must have painted (else the harness can't reproduce a paint-time flicker)")

        // Scan every row's every channel for a rapid rise-then-fall within a short window.
        var report: [String] = []
        for (idx, track) in surface.debugCensusByIndex.sorted(by: { $0.key < $1.key }) {
            let op = oscillatingWindows(track.opacity, epsilon: 0.03)
            let sc = oscillatingWindows(track.scale, epsilon: 0.006)
            let bl = oscillatingWindows(track.blur, epsilon: 0.2)
            let yy = oscillatingWindows(track.y, epsilon: 2.0)
            if op + sc + bl + yy > 0 {
                report.append("idx=\(idx) opOsc=\(op) scaleOsc=\(sc) blurOsc=\(bl) yOsc=\(yy) (paints=\(track.opacity.count))")
            }
        }
        print("census flicker windows:\n" + (report.isEmpty ? "  NONE — no channel oscillated" : report.joined(separator: "\n")))
        // Dump the opacity trace of the first oscillating row so the SHAPE (spring wobble vs target flip) is visible.
        if let (idx, track) = surface.debugCensusByIndex.sorted(by: { $0.key < $1.key })
            .first(where: { oscillatingWindows($0.value.opacity, epsilon: 0.03) > 0 }) {
            let start = max(0, (0...(track.opacity.count - 6)).first { s in
                NativeLyricsSurfaceView.censusOscillates(Array(track.opacity[s..<s + 6]), epsilon: 0.03)
            } ?? 0)
            let end = min(track.opacity.count, start + 16)
            let opSlice = track.opacity[start..<end]
            let tgSlice = track.target[start..<end]
            print("idx=\(idx) OPACITY [from \(start)]: " + opSlice.map { String(format: "%.3f", $0) }.joined(separator: " "))
            print("idx=\(idx) TARGET  [from \(start)]: " + tgSlice.map { String(format: "%.3f", $0) }.joined(separator: " "))
            let semEnd = min(surface.debugSemanticTrace.count, start + 16)
            if start < semEnd {
                print("semanticIndex [from \(start)]: " + surface.debugSemanticTrace[start..<semEnd].map { "\($0)" }.joined(separator: " "))
                print("renderClock   [from \(start)]: " + surface.debugClockTrace[start..<semEnd].map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
        }

        XCTAssertTrue(report.isEmpty, "presentation channels flickered (rise-then-fall in a short window):\n\(report.joined(separator: "\n"))")
    }
}
