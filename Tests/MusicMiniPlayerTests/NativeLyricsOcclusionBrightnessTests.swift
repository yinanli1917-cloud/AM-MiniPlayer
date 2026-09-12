import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Defect B3 repro attempt (2026-07-27 recording): one active line stayed at ≈65% effective
// brightness (162/250) for its whole 4.9 s active dwell, right after a macOS system overlay had
// covered the player window for ~6 s. Same lockstep-clock methodology as
// NativeLyricsHandoffClockTests: both the wall clock (`debugNowOverride`) and the playback clock
// (`debugPlaybackClockDateProvider`) are injected and stepped in lockstep, real NSWindow host,
// > 0.8 s warm-up so the appear window has expired before any scenario's boundary.
//
// Occlusion seam: LyricsLayerRendererView.isHostWindowOccluded() checks `!window.isVisible` BEFORE
// `window.alphaValue < 0.01` — so `window.orderOut(nil)` / `window.orderFrontRegardless()` toggles
// real occlusion regardless of the alpha=0 hosting trick used to keep the test window invisible.
// presentationTick() itself re-checks isHostWindowOccluded() on every call — including
// debug-driven ticks — and returns immediately when occluded, before any census sample is
// recorded and before any spring/opacity integration runs. So occluding freezes the driver's
// samples exactly where they were; nothing about the occlusion path is bypassed by the debug seam.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsOcclusionBrightnessTests: XCTestCase {

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
    private func host(_ view: NSView, _ size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        if let surface = view as? NativeLyricsSurfaceView {
            hostedSurfaces.append(surface)
        }
        return w
    }

    /// Same fixture shape as NativeLyricsHandoffClockTests.makeRows: contiguous 1.2 s word-timed
    /// lines. `longTextAt` swaps in a long string (forces word-wrap to 2 screen rows at 320pt
    /// rowWidth) for the given indices — used by the S5 wrapped-line scenario.
    // 5 s per line (not the churn-test fixture's 1.2 s) — the B3 recording describes a 4.9 s
    // active dwell, and asserting "stays >= 0.95 for a 3 s hold" needs a dwell that long or the
    // NEXT line's own (expected, by-design) deactivation would masquerade as a dip.
    private func makeRows(_ n: Int, longTextAt: Set<Int> = [], lineDuration: TimeInterval = 5.0) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * lineDuration, e = TimeInterval(i) * lineDuration + lineDuration
            let d = (e - s) / 3
            let text = longTextAt.contains(i)
                ? "line \(i) has a great many words here so that it must wrap across two full screen rows at this width"
                : "line \(i) words here"
            let words: [LyricWord]
            if longTextAt.contains(i) {
                let parts = text.split(separator: " ").map(String.init)
                let per = (e - s) / TimeInterval(parts.count)
                words = parts.enumerated().map { idx, w in
                    LyricWord(word: w + " ", startTime: s + TimeInterval(idx) * per, endTime: s + TimeInterval(idx + 1) * per)
                }
            } else {
                words = [
                    LyricWord(word: "line ", startTime: s, endTime: s + d),
                    LyricWord(word: "\(i) ", startTime: s + d, endTime: s + 2 * d),
                    LyricWord(word: "words here", startTime: s + 2 * d, endTime: e),
                ]
            }
            let line = LyricLine(text: text, startTime: s, endTime: e, words: words)
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(
        _ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController
    ) -> LyricsLayerRendererConfiguration {
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

    struct OcclusionSample {
        let frame: Int
        let wall: TimeInterval
        let playback: TimeInterval
        let semantic: Int
        let occluded: Bool
        let loopRunning: Bool
        // per watched row index
        let byIndex: [Int: (y: CGFloat, opacity: CGFloat, bright: CGFloat)]
        func effective(_ idx: Int) -> CGFloat? {
            guard let v = byIndex[idx] else { return nil }
            return v.opacity * v.bright
        }
    }

    /// Drives `rows` with a lockstep injected clock, toggling real window occlusion
    /// (`orderOut`/`orderFrontRegardless`) during the `occlusionWindows` (playback-time ranges),
    /// and returns a per-frame census for `watchIndices` from `censusStart` for `censusFrames`.
    @MainActor
    private func drive(
        label: String,
        rows: [LayerBackedLyricRow],
        warmupStart: TimeInterval,
        warmupFrames: Int,
        censusStart: TimeInterval,
        censusFrames: Int,
        watchIndices: [Int],
        occlusionWindows: [(start: TimeInterval, end: TimeInterval)]
    ) -> [OcclusionSample] {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        let window = host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 1_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let playbackStep = 1.0 / 60.0
        let wallStepPerFrame = 1.0 / 60.0
        var occludedNow = false

        func applyOcclusion(for playback: TimeInterval) {
            let shouldOcclude = occlusionWindows.contains { playback >= $0.start && playback < $0.end }
            guard shouldOcclude != occludedNow else { return }
            occludedNow = shouldOcclude
            if shouldOcclude {
                window.orderOut(nil)
            } else {
                window.orderFrontRegardless()
            }
            RunLoop.main.run(until: Date())
        }

        func step(playback: TimeInterval) {
            applyOcclusion(for: playback)
            wall += wallStepPerFrame
            date = date.addingTimeInterval(playbackStep)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc))
            surface.debugTick(displayInterval: wallStepPerFrame)
            RunLoop.main.run(until: Date())
        }

        mc.syncPlaybackClock(to: warmupStart, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        // Drive CONTINUOUSLY from warmupStart through censusStart (no clock discontinuity):
        // warmupFrames covers >= 0.8s so the appear window has expired, then bridge frames fill
        // any remaining gap up to censusStart.
        let bridgeFrames = max(0, Int(((censusStart - warmupStart) / playbackStep).rounded()) - warmupFrames)
        for i in 0..<(warmupFrames + bridgeFrames) {
            step(playback: warmupStart + TimeInterval(i) * playbackStep)
        }

        surface.debugResetCensus()
        surface.debugCensusEnabled = true
        var samples: [OcclusionSample] = []
        for i in 0..<censusFrames {
            let playback = censusStart + TimeInterval(i) * playbackStep
            step(playback: playback)
            var byIndex: [Int: (y: CGFloat, opacity: CGFloat, bright: CGFloat)] = [:]
            for idx in watchIndices {
                guard let track = surface.debugCensusByIndex[idx],
                      let y = track.y.last, let op = track.opacity.last, let br = track.bright.last else { continue }
                byIndex[idx] = (y, op, br)
            }
            samples.append(OcclusionSample(
                frame: i, wall: wall, playback: playback,
                semantic: surface.debugNativeSemanticIndex ?? -1,
                occluded: occludedNow,
                loopRunning: surface.debugIsPresentationLoopRunning,
                byIndex: byIndex
            ))
        }
        surface.debugCensusEnabled = false
        // Make sure we end unoccluded so tearDown's orderOut doesn't double-fire oddly.
        if occludedNow { window.orderFrontRegardless() }
        dumpTrace(label: label, samples: samples, watchIndices: watchIndices)
        return samples
    }

    private func dumpTrace(label: String, samples: [OcclusionSample], watchIndices: [Int]) {
        print("[OcclusionBrightness:\(label)] frame playback sem occl loop " + watchIndices.map { "idx\($0)(y,op,br,eff)" }.joined(separator: " "))
        for s in samples {
            var line = String(format: "[OcclusionBrightness:%@] %4d %7.3f %3d %@ %@",
                               label, s.frame, s.playback, s.semantic, s.occluded ? "OCC" : "vis", s.loopRunning ? "run" : "stop")
            for idx in watchIndices {
                if let v = s.byIndex[idx] {
                    line += String(format: "  [%.2f,%.3f,%.3f,%.3f]", v.y, v.opacity, v.bright, v.opacity * v.bright)
                } else {
                    line += "  [--]"
                }
            }
            print(line)
        }
    }

    /// Effective brightness reaches >= 0.95 within 1.0 s after `boundaryPlayback` and stays there
    /// for the remainder of `after` seconds of playback. Fails with a diagnostic if not.
    private func assertReachesAndHoldsFullBrightness(
        _ samples: [OcclusionSample], index: Int, boundaryPlayback: TimeInterval,
        holdSeconds: TimeInterval = 3.0, label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let inWindow = samples.filter { $0.playback >= boundaryPlayback && $0.playback <= boundaryPlayback + 1.0 }
        guard let reach = inWindow.first(where: { ($0.effective(index) ?? 0) >= 0.95 }) else {
            let steady = samples.last(where: { $0.playback <= boundaryPlayback + holdSeconds + 1.0 })?.effective(index) ?? -1
            XCTFail("\(label): row \(index) never reached effective brightness >= 0.95 within 1.0s of boundary \(boundaryPlayback); last effective=\(steady)", file: file, line: line)
            return
        }
        let holdWindow = samples.filter { $0.playback >= reach.playback && $0.playback <= reach.playback + holdSeconds }
        let dips = holdWindow.filter { ($0.effective(index) ?? 0) < 0.95 }
        if !dips.isEmpty {
            let minVal = dips.compactMap { $0.effective(index) }.min() ?? -1
            XCTFail("\(label): row \(index) dipped back below 0.95 effective brightness during the \(holdSeconds)s hold (min=\(minVal))", file: file, line: line)
        }
    }

    // ── S1: baseline, no occlusion ──────────────────────────────────────────────────────────
    @MainActor
    func test_S1_baseline_noOcclusion_reachesFullBrightness() {
        let rows = makeRows(20)
        let boundary = rows[6].displayLine.line.startTime // 5→6 boundary
        let samples = drive(
            label: "S1", rows: rows,
            warmupStart: rows[5].displayLine.line.startTime + 0.1, warmupFrames: 60,
            censusStart: boundary - 0.5, censusFrames: 420,
            watchIndices: [5, 6], occlusionWindows: []
        )
        assertReachesAndHoldsFullBrightness(samples, index: 6, boundaryPlayback: boundary, label: "S1")
    }

    // ── S2: occlusion entirely during the PREVIOUS line, well before the boundary ───────────
    @MainActor
    func test_S2_occlusionDuringPreviousLine_thenBoundary_reachesFullBrightness() {
        let rows = makeRows(20)
        let boundary = rows[6].displayLine.line.startTime
        let occStart = rows[5].displayLine.line.startTime + 0.2
        let occEnd = occStart + 1.0
        let samples = drive(
            label: "S2", rows: rows,
            warmupStart: rows[5].displayLine.line.startTime + 0.1, warmupFrames: 60,
            censusStart: occStart - 0.5, censusFrames: 420,
            watchIndices: [5, 6], occlusionWindows: [(occStart, occEnd)]
        )
        assertReachesAndHoldsFullBrightness(samples, index: 6, boundaryPlayback: boundary, label: "S2")
    }

    // ── S3: occlusion spans the boundary itself ─────────────────────────────────────────────
    @MainActor
    func test_S3_occlusionSpanningBoundary_reachesFullBrightness() {
        let rows = makeRows(20)
        let boundary = rows[6].displayLine.line.startTime
        let occStart = boundary - 0.3
        let occEnd = boundary + 0.5
        let samples = drive(
            label: "S3", rows: rows,
            warmupStart: rows[5].displayLine.line.startTime + 0.1, warmupFrames: 60,
            censusStart: occStart - 0.3, censusFrames: 420,
            watchIndices: [5, 6], occlusionWindows: [(occStart, occEnd)]
        )
        assertReachesAndHoldsFullBrightness(samples, index: 6, boundaryPlayback: boundary, label: "S3")
    }

    // ── S4: occlusion right at a deferred-deactivation moment (100ms after the PRIOR boundary,
    //        4→5), spanning ~1s, then continue across the 5→6 boundary. Check both row 5 and 6. ──
    @MainActor
    func test_S4_occlusionAtDeferredDeactivation_row5And6ReachFullBrightness() {
        let rows = makeRows(20)
        let priorBoundary = rows[5].displayLine.line.startTime // 4→5
        let boundary = rows[6].displayLine.line.startTime // 5→6
        let occStart = priorBoundary + 0.1
        // NOTE: kept < priorBoundary's own 1.0s check window (occEnd must land before
        // priorBoundary + 1.0) — un-occlusion is what triggers the snap, so the row cannot
        // read as bright while the window is still literally occluded. 0.8s (ending at
        // priorBoundary + 0.9) still covers the deferred-deactivation moment and leaves
        // margin for the post-resume snap to land inside the row5 assertion's window.
        let occEnd = occStart + 0.8
        let samples = drive(
            label: "S4", rows: rows,
            warmupStart: rows[4].displayLine.line.startTime + 0.1, warmupFrames: 60,
            censusStart: priorBoundary - 0.3, censusFrames: 420,
            watchIndices: [4, 5, 6], occlusionWindows: [(occStart, occEnd)]
        )
        assertReachesAndHoldsFullBrightness(samples, index: 5, boundaryPlayback: priorBoundary, label: "S4-row5")
        assertReachesAndHoldsFullBrightness(samples, index: 6, boundaryPlayback: boundary, label: "S4-row6")
    }

    // ── S5: incoming line wraps to two screen rows, repeat S1 and S3 shapes ────────────────
    @MainActor
    func test_S5_wrappedLine_noOcclusion_reachesFullBrightness() {
        let rows = makeRows(20, longTextAt: [6])
        let boundary = rows[6].displayLine.line.startTime
        let samples = drive(
            label: "S5a", rows: rows,
            warmupStart: rows[5].displayLine.line.startTime + 0.1, warmupFrames: 60,
            censusStart: boundary - 0.5, censusFrames: 420,
            watchIndices: [5, 6], occlusionWindows: []
        )
        assertReachesAndHoldsFullBrightness(samples, index: 6, boundaryPlayback: boundary, label: "S5a")
    }

    @MainActor
    func test_S5_wrappedLine_occlusionSpanningBoundary_reachesFullBrightness() {
        let rows = makeRows(20, longTextAt: [6])
        let boundary = rows[6].displayLine.line.startTime
        let occStart = boundary - 0.3
        let occEnd = boundary + 0.5
        let samples = drive(
            label: "S5b", rows: rows,
            warmupStart: rows[5].displayLine.line.startTime + 0.1, warmupFrames: 60,
            censusStart: occStart - 0.3, censusFrames: 420,
            watchIndices: [5, 6], occlusionWindows: [(occStart, occEnd)]
        )
        assertReachesAndHoldsFullBrightness(samples, index: 6, boundaryPlayback: boundary, label: "S5b")
    }

    // ── S6: a LONG occlusion (6.0s) spanning the 5→6 boundary — the un-occlusion snap must land
    //        row 6 at full brightness AND at its resting anchor y (not mid-spring) almost
    //        immediately, since resuming mid-spring after a multi-second freeze is exactly the
    //        defect (B3) this file guards against. ──────────────────────────────────────────────
    @MainActor
    func test_S6_longOcclusionSpanningBoundary_snapsToFullBrightnessAndAnchorY() {
        // The default 5s/line fixture is shorter than this 6.0s occlusion, which would let
        // playback cross an ENTIRE extra line while occluded and skip row 6 outright (a real but
        // different scenario, not what S6 is checking). Use a longer per-line dwell (10s) so row
        // 6 is still the semantically current line for the whole occlusion + assertion window.
        let rows = makeRows(20, lineDuration: 10.0)
        let boundary = rows[6].displayLine.line.startTime
        let occStart = boundary - 0.3
        let occEnd = occStart + 6.0
        let samples = drive(
            label: "S6", rows: rows,
            warmupStart: rows[5].displayLine.line.startTime + 0.1, warmupFrames: 60,
            censusStart: occStart - 0.3, censusFrames: 480,
            watchIndices: [5, 6], occlusionWindows: [(occStart, occEnd)]
        )
        guard let resumeIndex = samples.firstIndex(where: { $0.playback >= occEnd }) else {
            XCTFail("S6: never reached the un-occlusion playback time \(occEnd)")
            return
        }
        let resume = samples[resumeIndex]
        XCTAssertFalse(resume.occluded, "S6: sample at/after occEnd should already read un-occluded")
        let withinAssertWindow = samples.filter {
            $0.playback >= resume.playback && $0.playback <= resume.playback + 0.3
        }
        guard let anchorY = withinAssertWindow.compactMap({ $0.byIndex[6]?.y }).first else {
            XCTFail("S6: row 6 has no sample within 0.3s of un-occlusion")
            return
        }
        for sample in withinAssertWindow {
            guard let row6 = sample.byIndex[6] else { continue }
            XCTAssertEqual(row6.y, anchorY, accuracy: 0.5,
                            "S6: row 6 should SNAP to its resting y, not re-animate, after a long occlusion (frame \(sample.frame))")
        }
        guard let reach = withinAssertWindow.first(where: { ($0.effective(6) ?? 0) >= 0.95 }) else {
            let last = withinAssertWindow.last?.effective(6) ?? -1
            XCTFail("S6: row 6 never reached effective brightness >= 0.95 within 0.3s of un-occlusion; last effective=\(last)")
            return
        }
        _ = reach
    }
}
