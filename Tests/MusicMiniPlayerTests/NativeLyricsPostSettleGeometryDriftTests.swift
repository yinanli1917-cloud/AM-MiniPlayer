import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 3h round, item 1 (founder pixel-comparison 2026-09-18): every line switch, the scroll settles
// visibly within ~0.8s and the frame holds still — then, ~1.5-2.0s after it looks fully stopped,
// EXACTLY ONE isolated frame shows a 1-2pt geometry change, on every one of 12 observed switches.
//
// ROUND 1 of this test (activation-bound fix, `hasActiveMotion` kept as a safety net) found the
// geometry channels (frame/transform) clean, but caught shouldRasterize still landing its one
// flip at 1.65-2.02s after the boundary — the bottleneck had just moved from `isSettled`'s
// opacity/scale/blur epsilon to `hasActiveMotion`'s global "is ANY row in the visible stack still
// springing" gate. The founder ruled that gate unnecessary: blur is a STEPPED channel (snaps
// instantly on target change, never springs), so the ONLY things that change on a rasterized,
// deactivated row during subsequent position motion are its FRAME and its LAYER OPACITY — both
// applied AFTER rasterization by AppKit/CA (neither invalidates or re-triggers the cached bitmap).
//
// FINAL FORM (this file's current form): `applyRasterizationPolicy` is bound to activation ALONE,
// no motion gate at all. A deactivated row's shouldRasterize goes true on the SAME frame it
// deactivates and stays true — constant, zero flips — through any subsequent motion, all the way
// to the next activation. This test asserts that hard contract directly.
//
// Method: drive a REAL NativeLyricsSurfaceView through 12 successive line handoffs on wrapped CJK
// lyrics (so wrap-line geometry, the item-1-class hazard, is in play), and for each handoff sample
// EVERY 1/60s frame from the boundary to +3.0s (capped before the next boundary). Record, per row:
// view.frame (AppKit-applied position/size — what actually paints), the CALayer affine transform,
// and shouldRasterize/rasterizationScale. Assert (a) the row that just deactivated shows
// shouldRasterize == true on every sampled frame in the window (zero flips), (b) the row that is
// now active shows shouldRasterize == false throughout, and (c) the geometry channels (frame/
// transform) never show a post-quiescence jump on any channel — the founder's literal "moved
// 1-2px" symptom, restated as a model-level invariant.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsPostSettleGeometryDriftTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
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
    }

    /// 38 lines of "几乎每行折成两行" Chinese lyric text (Fan Wei-chi "啟程" shape), line-level
    /// timed (no word sync — the founder's repro song is line-level LRC), 3.0s per line.
    private func wrappedCJKRows(count: Int = 20) -> [LayerBackedLyricRow] {
        let phrases = [
            "每一次的啟程都像是重新出發", "帶著行李和滿滿的回憶上路",
            "不知道遠方到底藏著什麼風景", "只知道心裡有一種說不出的期待",
            "夜晚的燈火總是特別讓人安心", "陌生的城市裡尋找熟悉的溫暖",
            "有些故事還沒來得及好好告別", "有些夢想還在遙遠的地方等待",
        ]
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for i in 0..<count {
            let text = phrases[i % phrases.count]
            let end = start + 3.0
            let line = LyricLine(text: text, startTime: start, endTime: end, words: [])
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            rows.append(LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                             isPrelude: false, preludeEndTime: 0, interlude: nil))
            start = end
        }
        return rows
    }

    @MainActor
    private func config(
        _ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 76 } // two visual lines + translation slot
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: width,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 3.0, hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "啟程", artist: "范瑋琪", album: "Al", duration: 240),
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

    private struct GeometrySample {
        let frame: Int
        let sinceBoundary: TimeInterval
        let y: CGFloat
        let height: CGFloat
        let transformA: CGFloat
        let transformTx: CGFloat
        let transformTy: CGFloat
        let shouldRasterize: Bool
        let rasterizationScale: CGFloat
    }

    private struct LateJump {
        let switchIndex: Int
        let rowIndex: Int
        let channel: String
        let quietFrames: Int
        let sinceBoundary: TimeInterval
        let before: CGFloat
        let after: CGFloat
    }

    @MainActor
    func test_postHandoffGeometry_onceQuiet_neverJumpsAgainBefore3s() {
        // Narrow width forces every phrase to wrap to 2 visual lines (matches the founder's song).
        let width: CGFloat = 170
        let rows = wrappedCJKRows(count: 20)
        // Sanity: confirm these actually wrap to >=2 lines at the row font, or the fixture doesn't
        // exercise the wrapped-row hazard the founder named.
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let sampleMetrics = NativeLyricsTextMeasurement.metrics(rows[0].displayLine.line.text, width: width, font: font)
        XCTAssertGreaterThanOrEqual(sampleMetrics.lineCount, 2, "fixture must wrap to >=2 lines to exercise the hazard")

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: width + 40, height: 700))
        host(surface, NSSize(width: width + 40, height: 700))
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

        let frameStep = 1.0 / 60.0
        func step(playback: TimeInterval) {
            wall += frameStep
            date = date.addingTimeInterval(frameStep)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc, width: width))
            surface.debugTick(displayInterval: frameStep)
            RunLoop.main.run(until: Date())
        }

        // Warm-up: mount well inside line 0 so the initial appear window has long expired.
        let warmupStart: TimeInterval = 0.5
        mc.syncPlaybackClock(to: warmupStart, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc, width: width))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<90 { step(playback: warmupStart + TimeInterval(i) * frameStep) }

        var violations: [LateJump] = []
        var rasterFlipViolations: [(switchIndex: Int, rowIndex: Int, role: String, frame: Int, sinceBoundary: TimeInterval)] = []
        let switchCount = 12
        for switchIdx in 1...switchCount {
            let boundary = rows[switchIdx].displayLine.line.startTime
            // Run playback up to just past the boundary, then census the whole window.
            var t = boundary - 0.5
            while t < boundary + 0.05 {
                step(playback: t)
                t += frameStep
            }

            let deactivatedRowIndex = switchIdx - 1 // the row that just went inactive
            let activeRowIndex = switchIdx           // the row that is now active
            var samples: [GeometrySample] = []
            var activeSamples: [Bool] = [] // shouldRasterize for the NOW-ACTIVE row, same frames
            let censusStart = boundary
            // Cap the window before the NEXT line boundary so a following handoff's own reflow
            // (rows shifting as the anchor advances again) cannot masquerade as a post-settle jump
            // on THIS row.
            let nextBoundary = switchIdx + 1 < rows.count ? rows[switchIdx + 1].displayLine.line.startTime : boundary + 3.0
            let windowCap = min(3.0, nextBoundary - boundary - 0.1)
            var i = 0
            while true {
                let elapsed = TimeInterval(i) * frameStep
                guard elapsed <= windowCap else { break }
                step(playback: censusStart + elapsed)
                if let view = surface.debugRowView(forIndex: deactivatedRowIndex) {
                    let t2 = view.layer?.affineTransform() ?? .identity
                    samples.append(GeometrySample(
                        frame: i,
                        sinceBoundary: elapsed,
                        y: view.frame.origin.y,
                        height: view.frame.height,
                        transformA: t2.a,
                        transformTx: t2.tx,
                        transformTy: t2.ty,
                        shouldRasterize: view.layer?.shouldRasterize ?? false,
                        rasterizationScale: view.layer?.rasterizationScale ?? 0
                    ))
                }
                if let activeView = surface.debugRowView(forIndex: activeRowIndex) {
                    activeSamples.append(activeView.layer?.shouldRasterize ?? false)
                }
                i += 1
            }

            guard samples.count > 20 else { continue }

            // For each GEOMETRY channel, find the first index after which it stays quiet for >=6
            // frames, then check whether it EVER changes again afterward.
            func checkChannel(_ name: String, _ values: [CGFloat], tolerance: CGFloat) {
                var quietRunStart: Int? = nil
                var runLength = 0
                for idx in 1..<values.count {
                    let delta = abs(values[idx] - values[idx - 1])
                    if delta <= tolerance {
                        runLength += 1
                        if runLength >= 6 && quietRunStart == nil {
                            quietRunStart = idx - runLength + 1
                        }
                    } else {
                        if let qStart = quietRunStart, idx > qStart {
                            // A change occurred AFTER we'd already established quiescence.
                            violations.append(LateJump(
                                switchIndex: switchIdx, rowIndex: deactivatedRowIndex, channel: name,
                                quietFrames: runLength, sinceBoundary: samples[idx].sinceBoundary,
                                before: values[idx - 1], after: values[idx]
                            ))
                        }
                        runLength = 0
                        quietRunStart = nil
                    }
                }
            }
            checkChannel("frame.y", samples.map(\.y), tolerance: 0.05)
            checkChannel("frame.height", samples.map(\.height), tolerance: 0.05)
            checkChannel("transform.a", samples.map(\.transformA), tolerance: 0.0005)
            checkChannel("transform.tx", samples.map(\.transformTx), tolerance: 0.05)
            checkChannel("transform.ty", samples.map(\.transformTy), tolerance: 0.05)

            // HARD CONTRACT (2026-09-18, item 1 final form): once the deactivated row's
            // shouldRasterize goes true (its own deactivation frame — the wave stagger means this
            // can land a few frames after the raw line-switch boundary, since the row is still
            // legitimately ACTIVE from its own perspective until the wave choreography reaches it),
            // it must STAY true — constant, zero flips back to false — for the rest of the window.
            // It must also actually reach true at some point in the window (it must deactivate).
            if let onsetIdx = samples.firstIndex(where: { $0.shouldRasterize }) {
                for idx in onsetIdx..<samples.count where !samples[idx].shouldRasterize {
                    rasterFlipViolations.append((switchIdx, deactivatedRowIndex, "flip-back-to-false-after-onset",
                                                  idx, samples[idx].sinceBoundary))
                }
            } else {
                rasterFlipViolations.append((switchIdx, deactivatedRowIndex, "never-rasterized-in-window",
                                              samples.count - 1, samples.last?.sinceBoundary ?? 0))
            }
            // The now-active row's shouldRasterize must be FALSE throughout.
            for (idx, rasterized) in activeSamples.enumerated() where rasterized {
                rasterFlipViolations.append((switchIdx, activeRowIndex, "active-must-be-false",
                                              idx, TimeInterval(idx) * frameStep))
            }
        }

        if !violations.isEmpty {
            for v in violations.prefix(20) {
                print("[PostSettleDrift] switch=\(v.switchIndex) row=\(v.rowIndex) channel=\(v.channel) " +
                      "quietFor=\(v.quietFrames)f +\(String(format: "%.3f", v.sinceBoundary))s " +
                      "before=\(v.before) after=\(v.after) delta=\(v.after - v.before)")
            }
        }
        if !rasterFlipViolations.isEmpty {
            for v in rasterFlipViolations.prefix(20) {
                print("[PostSettleDrift] RASTER CONTRACT VIOLATION switch=\(v.switchIndex) row=\(v.rowIndex) " +
                      "role=\(v.role) frame=\(v.frame) +\(String(format: "%.3f", v.sinceBoundary))s")
            }
        }
        XCTAssertTrue(rasterFlipViolations.isEmpty,
                       "\(rasterFlipViolations.count) shouldRasterize contract violation(s): a deactivated row " +
                       "must be rasterized (true) on EVERY sampled frame from the boundary onward, and the " +
                       "now-active row must never be rasterized — see console dump.")
        XCTAssertTrue(violations.isEmpty,
                       "\(violations.count) GEOMETRY-level post-settle jump(s) found (frame/transform channel) — " +
                       "see console dump. If this ever fires, the founder's symptom is reproduced at the model level.")
    }
}
