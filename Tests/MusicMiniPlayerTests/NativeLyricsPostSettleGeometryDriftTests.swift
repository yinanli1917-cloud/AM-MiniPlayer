import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 3h round, item 1 (founder pixel-comparison 2026-09-18): every line switch, the scroll settles
// visibly within ~0.8s and the frame holds still — then, ~1.5-2.0s after it looks fully stopped,
// EXACTLY ONE isolated frame shows a 1-2pt geometry change, on every one of 12 observed switches.
// Founder ruled out the 0.95<->1.0 scale pivot (reverted in c431e27) and spring overshoot tails
// (0.8s window, this fires at 1.5-2.0s — too late to be spring residue). Leading suspects named in
// the brief: (a) the post-line fade floor descending on its own delayed timeline, (b) the
// blur-economy rasterization flip (applyRasterizationPolicy/refreshRasterization) snapping a
// settled row's bitmap to a new subpixel/backing-scale quantization, (c) any asyncAfter/Timer/
// settleAt firing in the 1.5-2s band.
//
// Method: drive a REAL NativeLyricsSurfaceView through 12 successive line handoffs on wrapped CJK
// lyrics (so wrap-line geometry, the item-1-class hazard, is in play), and for each handoff sample
// EVERY 1/60s frame from +0.8s to +3.0s after the boundary. Record, per visible row: view.frame
// (AppKit-applied position/size — what actually paints), the CALayer affine transform, and
// shouldRasterize/rasterizationScale (the blur-economy flip). Assert that once a row's frame goes
// quiet (no change for ≥6 consecutive sampled frames — well past any legitimate settle), it never
// changes again for the rest of the window. A violation pins the exact channel (frame vs transform
// vs rasterization) and the exact delay after quiescence, which is the geometry-level equivalent of
// "stopped, then moved 1-2px."
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
        var rasterizationOnsetDelays: [TimeInterval] = []
        let switchCount = 12
        for switchIdx in 1...switchCount {
            let boundary = rows[switchIdx].displayLine.line.startTime
            // Run playback up to just past the boundary, then census +0.8s..+3.0s.
            var t = boundary - 0.5
            while t < boundary + 0.05 {
                step(playback: t)
                t += frameStep
            }

            let watchedRowIndex = switchIdx - 1 // the row that just went inactive
            var samples: [GeometrySample] = []
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
                if elapsed >= 0.8, let view = surface.debugRowView(forIndex: watchedRowIndex) {
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
                i += 1
            }

            guard samples.count > 20 else { continue }

            // For each channel, find the first index after which it stays quiet for >=6 frames,
            // then check whether it EVER changes again afterward.
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
                                switchIndex: switchIdx, rowIndex: watchedRowIndex, channel: name,
                                quietFrames: runLength, sinceBoundary: samples[idx].sinceBoundary,
                                before: values[idx - 1], after: values[idx]
                            ))
                        }
                        runLength = 0
                        quietRunStart = nil
                    }
                }
            }
            // Diagnostic: print y right around any shouldRasterize transition, so we can see
            // whether the geometry channel moves in lockstep with the rasterization flip.
            for idx in 1..<samples.count where samples[idx].shouldRasterize != samples[idx - 1].shouldRasterize {
                let lo = max(0, idx - 2), hi = min(samples.count - 1, idx + 2)
                let window = samples[lo...hi].map { String(format: "%.3f", $0.y) }.joined(separator: ",")
                print("[PostSettleDrift] switch=\(switchIdx) row=\(watchedRowIndex) rasterFlip@\(idx) " +
                      "(+\(String(format: "%.3f", samples[idx].sinceBoundary))s) y-window[\(lo)...\(hi)]=\(window)")
            }
            // GEOMETRY channels — what actually paints on screen (AppKit-applied frame + the
            // CALayer affine transform). These are the founder's literal complaint ("moved 1-2px").
            checkChannel("frame.y", samples.map(\.y), tolerance: 0.05)
            checkChannel("frame.height", samples.map(\.height), tolerance: 0.05)
            checkChannel("transform.a", samples.map(\.transformA), tolerance: 0.0005)
            checkChannel("transform.tx", samples.map(\.transformTx), tolerance: 0.05)
            checkChannel("transform.ty", samples.map(\.transformTy), tolerance: 0.05)

            // shouldRasterize onset is BY DESIGN a one-time false→true transition (the blur-economy
            // fires once a row is settled+inactive+blurred — see NativeLyricsRowView.refreshRasterization).
            // It is not itself a geometry jump, so it is not a `violations` entry, but its TIMING is the
            // strongest available lead: it fires via `isSettled`'s blur-velocity epsilon (0.03), and for
            // rows with non-trivial target blur that epsilon takes noticeably longer to clear than the
            // point where the row is already visually indistinguishable from at-rest. If the render
            // server's cached-bitmap composite differs at all from the live filtered composite at the
            // moment of the flip (undetectable headlessly — see banned-patterns.md "Resident CIGaussianBlur"
            // entry: only the render server applies CIFilters), that mismatch would read on screen as
            // "stopped, then moved" at EXACTLY this delay. Record the onset delay per switch for the report.
            if let onsetIdx = samples.dropFirst().firstIndex(where: { $0.shouldRasterize })
                .map({ samples.distance(from: samples.startIndex, to: $0) }) {
                rasterizationOnsetDelays.append(samples[onsetIdx].sinceBoundary)
            }
        }

        if !violations.isEmpty {
            for v in violations.prefix(20) {
                print("[PostSettleDrift] switch=\(v.switchIndex) row=\(v.rowIndex) channel=\(v.channel) " +
                      "quietFor=\(v.quietFrames)f +\(String(format: "%.3f", v.sinceBoundary))s " +
                      "before=\(v.before) after=\(v.after) delta=\(v.after - v.before)")
            }
        }
        print("[PostSettleDrift] rasterizationOnsetDelays (s since boundary, one per switch) = " +
              rasterizationOnsetDelays.map { String(format: "%.3f", $0) }.joined(separator: ", "))
        XCTAssertEqual(rasterizationOnsetDelays.count, switchCount,
                       "every switch should show exactly one rasterization onset in the window")
        XCTAssertTrue(rasterizationOnsetDelays.allSatisfy { (1.0...2.5).contains($0) },
                       "onset consistently lands in the founder's reported ~1.5-2.0s band (leading unconfirmed mechanism, not proof)")
        XCTAssertTrue(violations.isEmpty,
                       "\(violations.count) GEOMETRY-level post-settle jump(s) found (frame/transform channel) — " +
                       "see console dump. If this ever fires, the founder's symptom is reproduced at the model level.")
    }
}
