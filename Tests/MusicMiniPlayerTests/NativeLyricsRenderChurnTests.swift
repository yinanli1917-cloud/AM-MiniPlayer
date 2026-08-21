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
        if let surface = view as? NativeLyricsSurfaceView {
            hostedSurfaces.append(surface)
        }
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
    private func config(
        _ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController,
        hasSyllableSync: Bool = true, isManualScrolling: Bool = false
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: hasSyllableSync,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: isManualScrolling, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    // Line-level (no per-word timing) counterpart of makeRows — same text/timing shape, so any
    // measured-height difference between the two variants comes from hasSyllableSync alone.
    private func makeLineLevelRows(_ n: Int) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * 1.2, e = TimeInterval(i) * 1.2 + 1.2
            let line = LyricLine(text: "line \(i) words here", startTime: s, endTime: e)
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
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
    private func drive(
        surface: NativeLyricsSurfaceView,
        musicController: MusicController,
        rows: [LayerBackedLyricRow],
        from startPlaybackTime: TimeInterval,
        duration: TimeInterval,
        noisy: Bool = true
    ) {
        let frameInterval = 1.0 / 60.0
        let frameCount = max(1, Int((duration / frameInterval).rounded(.up)))
        for i in 0..<frameCount {
            let elapsed = TimeInterval(i) * frameInterval
            let playbackTime = noisy
                ? noisyClock(step: i, base: startPlaybackTime + elapsed)
                : startPlaybackTime + elapsed
            musicController.syncPlaybackClock(to: playbackTime, playing: true)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: musicController))
            RunLoop.main.run(until: Date().addingTimeInterval(frameInterval))
        }
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
        surface.debugSkipDedupe = true

        // Warm up so the surface's index tracks the clock before we start scoring (avoids the
        // startup catch-up artifact). Then drive at ~1x REAL time so the wall-clock line-advance timer
        // keeps up, with a NOISY clock (backward dips on ~1/3 of frames) layered on top.
        mc.syncPlaybackClock(to: 0.6, playing: true)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }
        surface.debugResetCensus()
        surface.debugCensusEnabled = true

        drive(surface: surface, musicController: mc, rows: rows, from: 0.6, duration: 6.0, noisy: true)

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

    @MainActor
    func test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(20)
        surface.debugSkipDedupe = true

        let previousIndex = 5
        let nextIndex = previousIndex + 1
        let previousStart = rows[previousIndex].displayLine.line.startTime

        // Warm up for LONGER than the surface's 0.8 s appear (force-snap) window. While that window is
        // open the surface runs in directSnap mode and — because this drive feeds the surface's own
        // semantic index back as `current` — cannot advance the line, so a boundary that falls inside
        // the window defers the handoff until the window expires (~0.5 s) while the still-active line's
        // bright overlay follows the designed post-line afterglow. That reads as "faded before it
        // moved" and is a harness artifact, not a handoff desync: the 0.25 s warm-up this test used to
        // have went red 3/3 on a ~20 ms/iteration host for exactly that reason.
        // NativeLyricsHandoffClockTests reproduces both outcomes under injected lockstep clocks.
        mc.syncPlaybackClock(to: previousStart + 0.1, playing: true)
        surface.configure(config(rows, current: previousIndex, mc: mc))
        surface.layoutSubtreeIfNeeded()
        drive(surface: surface, musicController: mc, rows: rows, from: previousStart + 0.1, duration: 0.9, noisy: false)

        surface.debugResetCensus()
        surface.debugCensusEnabled = true
        // Continue from where the warm-up stopped (0.2 s before the boundary) rather than jumping the
        // clock, so the census holds a pre-handoff baseline of the previous row.
        drive(surface: surface, musicController: mc, rows: rows, from: previousStart + 1.0, duration: 1.4, noisy: false)

        guard let track = surface.debugCensusByIndex[previousIndex] else {
            return XCTFail("previous row \(previousIndex) must stay mounted across the handoff")
        }
        let count = min(track.opacity.count, track.y.count, track.bright.count, surface.debugSemanticTrace.count)
        XCTAssertGreaterThan(count, 8, "precondition: handoff drive must paint enough frames")
        let semantics = Array(surface.debugSemanticTrace.prefix(count))
        let opacity = Array(track.opacity.prefix(count))
        let bright = Array(track.bright.prefix(count))
        let visualBrightness = zip(opacity, bright).map { $0 * max($1, 0.2) }
        let y = Array(track.y.prefix(count))
        guard let handoffFrame = semantics.firstIndex(of: nextIndex) else {
            return XCTFail("semantic index never advanced to \(nextIndex); trace=\(semantics)")
        }

        let baselineY = y.prefix(max(3, handoffFrame)).reduce(0, +) / CGFloat(max(3, handoffFrame))
        let baselineOpacity = opacity.prefix(max(3, handoffFrame)).max() ?? opacity[handoffFrame]
        let baselineBrightness = visualBrightness.prefix(max(3, handoffFrame)).max() ?? visualBrightness[handoffFrame]
        let motionThreshold: CGFloat = 0.5
        let firstMotionFrame = y[0..<count].firstIndex {
            abs($0 - baselineY) > motionThreshold
        } ?? count - 1
        let firstOpacityDropFrame = opacity[0..<count].firstIndex {
            baselineOpacity - $0 > 0.02
        } ?? count - 1
        let firstBrightnessDropFrame = visualBrightness[0..<count].firstIndex {
            baselineBrightness - $0 > 0.02
        } ?? count - 1
        let preMotionRange = min(firstOpacityDropFrame, handoffFrame)...max(handoffFrame, firstMotionFrame - 1)
        let minPreMotionOpacity = preMotionRange.map { opacity[$0] }.min() ?? opacity[handoffFrame]
        let opacityDropBeforeMotion = baselineOpacity - minPreMotionOpacity
        let brightnessPreMotionRange = min(firstBrightnessDropFrame, handoffFrame)...max(handoffFrame, firstMotionFrame - 1)
        let minPreMotionBrightness = brightnessPreMotionRange.map { visualBrightness[$0] }.min() ?? visualBrightness[handoffFrame]
        let brightnessDropBeforeMotion = baselineBrightness - minPreMotionBrightness
        let maxYStep = zip(y, y.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        let maxScaleStep = zip(track.scale.prefix(count), track.scale.dropFirst().prefix(count - 1))
            .map { abs($1 - $0) }
            .max() ?? 0

        print(
            "handoff previous=\(previousIndex) next=\(nextIndex) frame=\(handoffFrame) firstMotion=\(firstMotionFrame) firstOpacityDrop=\(firstOpacityDropFrame) firstBrightnessDrop=\(firstBrightnessDropFrame) " +
            "opDropBeforeMotion=\(String(format: "%.3f", opacityDropBeforeMotion)) brightnessDropBeforeMotion=\(String(format: "%.3f", brightnessDropBeforeMotion)) maxYStep=\(String(format: "%.2f", maxYStep)) maxScaleStep=\(String(format: "%.3f", maxScaleStep)) baselineY=\(String(format: "%.1f", baselineY)) " +
            "semantics=\(semantics[handoffFrame..<min(count, handoffFrame + 16)].map(String.init).joined(separator: ",")) " +
            "op=\(opacity[handoffFrame..<min(count, handoffFrame + 16)].map { String(format: "%.3f", $0) }.joined(separator: ",")) " +
            "bright=\(bright[handoffFrame..<min(count, handoffFrame + 16)].map { String(format: "%.3f", $0) }.joined(separator: ",")) " +
            "visB=\(visualBrightness[handoffFrame..<min(count, handoffFrame + 16)].map { String(format: "%.3f", $0) }.joined(separator: ",")) " +
            "y=\(y[handoffFrame..<min(count, handoffFrame + 16)].map { String(format: "%.1f", $0) }.joined(separator: ","))"
        )

        XCTAssertLessThanOrEqual(
            firstMotionFrame,
            firstBrightnessDropFrame,
            "previous row brightness started dropping before its Y started moving"
        )
        XCTAssertLessThanOrEqual(
            brightnessDropBeforeMotion,
            0.02,
            "previous row visually faded before its Y started moving; bright overlay and position are desynced"
        )
        XCTAssertLessThanOrEqual(
            firstMotionFrame,
            firstOpacityDropFrame,
            "previous row opacity started dropping before its Y started moving"
        )
        XCTAssertLessThanOrEqual(
            opacityDropBeforeMotion,
            0.02,
            "previous row faded before its Y started moving; opacity and position are desynced"
        )
        XCTAssertLessThanOrEqual(
            maxYStep,
            12,
            "previous row took a single-frame handoff step larger than the smooth-motion budget"
        )
        XCTAssertLessThanOrEqual(
            maxScaleStep,
            0.03,
            "previous row took a single-frame scale step larger than the smooth-motion budget"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Layout-stability gate (founder report: "歌词在滚动前后/active 前后，行间距会变" —
    // line spacing changes around the active-line handoff and around manual scroll).
    //
    // A row's `view.frame` alone is NOT what the eye sees: applyFrame also applies a scale
    // transform (view.setPositioning) around the layer's default CENTER anchor point, and that
    // transform never touches `.frame` — so a scale != 1 on the active row makes it visually
    // grow/shrink from its own middle without the layout's bookkeeping (frame, next row's Y)
    // changing at all. Reading raw `.frame` would be blind to exactly the effect the founder is
    // describing. This computes the EFFECTIVE on-screen rect (frame re-centered at the applied
    // scale) so the gap check matches what a human eye perceives, not just the layout ledger.
    // The GAP between two consecutive rows' effective rects (not their absolute Y) is what must
    // stay constant: a uniform shift of every row below a height change is invisible to a
    // relative-gap check and IS legitimate (normal scroll), so this only fires on a genuine
    // spacing change.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @MainActor
    private func rowFrames(_ surface: NativeLyricsSurfaceView, count: Int) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for i in 0..<count {
            guard let view = surface.debugRowView(forIndex: i), view.frame.height > 1 else { continue }
            let frame = view.frame
            let scale = view.positioningTransform.a
            if scale == 1 {
                frames[i] = frame
            } else {
                let scaledHeight = frame.height * scale
                frames[i] = CGRect(x: frame.minX, y: frame.midY - scaledHeight / 2, width: frame.width, height: scaledHeight)
            }
        }
        return frames
    }

    // isFlipped == true on NativeLyricsRowView (Y increases downward), so a healthy stack has
    // row[i+1].minY at row[i].maxY plus whatever intentional gap the layout wants.
    private func lineGaps(_ frames: [Int: CGRect]) -> [Int: CGFloat] {
        var gaps: [Int: CGFloat] = [:]
        for i in frames.keys {
            guard let a = frames[i], let b = frames[i + 1] else { continue }
            gaps[i] = b.minY - a.maxY
        }
        return gaps
    }

    private func assertGapsStable(
        before: [Int: CGFloat], after: [Int: CGFloat],
        excludingRowIndices activeIndices: Set<Int>, tolerance: CGFloat = 1.0,
        context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        var drifted: [String] = []
        for (idx, beforeGap) in before.sorted(by: { $0.key < $1.key }) {
            // A gap touching an active row (idx or idx+1) may move — that's the active line's
            // own intended motion. Every OTHER gap is between two non-active lines and must not.
            if activeIndices.contains(idx) || activeIndices.contains(idx + 1) { continue }
            guard let afterGap = after[idx] else { continue }
            if abs(afterGap - beforeGap) > tolerance {
                drifted.append("gap[\(idx)/\(idx + 1)]: \(String(format: "%.2f", beforeGap)) -> \(String(format: "%.2f", afterGap)) (Δ\(String(format: "%.2f", afterGap - beforeGap)))")
            }
        }
        XCTAssertTrue(drifted.isEmpty, "\(context) — non-active line gaps drifted:\n" + drifted.joined(separator: "\n"), file: file, line: line)
    }

    /// Re-configures at a FROZEN playback time for `ticks` frames — lets the position/visual
    /// springs run as long as needed to fully converge without the wall-clock line-advance timer
    /// pushing the semantic index into the NEXT line (which a long `drive()` window would do).
    @MainActor
    private func settleInPlace(surface: NativeLyricsSurfaceView, musicController: MusicController, rows: [LayerBackedLyricRow], at playbackTime: TimeInterval, hasSyllableSync: Bool, ticks: Int) {
        musicController.syncPlaybackClock(to: playbackTime, playing: true)
        for _ in 0..<ticks {
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: musicController, hasSyllableSync: hasSyllableSync))
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
    }

    @MainActor
    private func runHandoffGapStabilityCheck(rows: [LayerBackedLyricRow], hasSyllableSync: Bool, label: String) {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        let previousIndex = 5
        let nextIndex = previousIndex + 1
        let previousStart = rows[previousIndex].displayLine.line.startTime
        let handoffTime = rows[nextIndex].displayLine.line.startTime

        mc.syncPlaybackClock(to: previousStart + 0.35, playing: true)
        surface.configure(config(rows, current: previousIndex, mc: mc, hasSyllableSync: hasSyllableSync))
        surface.layoutSubtreeIfNeeded()
        // Settle windows on BOTH sides (springs are critically-damped, mass 1/stiffness
        // 100/damping 20 — converges within a few hundred ms): the gate must compare two FULLY
        // SETTLED states, not two different amounts of spring lag, or it would flag normal
        // transition animation as a bug. Windows are sized to stay inside the 1.2s test line so
        // driving to "settle" doesn't itself cross into the next handoff.
        drive(surface: surface, musicController: mc, rows: rows, from: previousStart + 0.35, duration: 0.8, noisy: false)
        settleInPlace(surface: surface, musicController: mc, rows: rows, at: previousStart + 1.15, hasSyllableSync: hasSyllableSync, ticks: 180)

        let beforeGaps = lineGaps(rowFrames(surface, count: rows.count))

        drive(surface: surface, musicController: mc, rows: rows, from: handoffTime + 0.35, duration: 0.8, noisy: false)
        settleInPlace(surface: surface, musicController: mc, rows: rows, at: handoffTime + 1.15, hasSyllableSync: hasSyllableSync, ticks: 180)

        let afterGaps = lineGaps(rowFrames(surface, count: rows.count))

        assertGapsStable(
            before: beforeGaps, after: afterGaps,
            excludingRowIndices: [previousIndex, nextIndex],
            context: "\(label) handoff \(previousIndex)->\(nextIndex)"
        )
    }

    // DIAGNOSED, NOT YET FIXED (founder report: "歌词在滚动前后/active 前后，行间距会变").
    // Root cause (see LyricsPresentationModels.swift:388-408, NativeLyricsVisualTarget.amllTarget):
    // non-active rows' blur grows with `dist = |displayIndex - currentIndex|`
    // (`renderedBlur`), and that blur renders OUTSIDE the row's `.frame` bounds
    // (`layer.masksToBounds = false`, NativeLyricsRowView.swift:916 and sublayers) — a real
    // CIGaussianBlur visually expands a layer's apparent footprint. So every non-active row's
    // visual footprint is a function of its CURRENT distance from the active line; the instant
    // the active line moves by one, EVERY row's distance — and so its blur, and so its visually
    // perceived edges — shifts by one step, simultaneously, network-wide. That is very likely
    // the felt "spacing changed" effect. Confirmed NOT explained by measured text height, font
    // size, or scale (all verified distance/active-state-independent for non-active rows).
    // A second, less-isolated contributor remains: the SPECIFIC set of drifted gaps was not
    // stable across different settle-window lengths in this test's own iteration (see git history
    // of this method), suggesting an additional position-settling interaction near the
    // `nativeLyricAutoVisibleRowRadius` visible-window edge that was not pinned to one line
    // within this diagnosis pass.
    // This lands squarely inside the depth-blur / wave-motion cluster that postmortems 004 and
    // the lyrics-ux-contract.md defect log required repeated ON-DEVICE visual confirmation to
    // touch safely (a purely offline fix risks the same "passed tests, still looked wrong"
    // failure mode documented there). Per plan, stopping here: XCTExpectFailure keeps this
    // reproduction green in CI (and will itself fail — loudly — the day someone's fix makes the
    // assertion pass, forcing a conscious removal of this wrapper) instead of leaving a
    // permanently-red test in the suite.
    @MainActor
    func test_lineGapsStableAcrossHandoff_wordLevel() {
        XCTExpectFailure("Diagnosed, not fixed — see comment above. Founder/product decision needed on the blur-footprint tradeoff before an on-device-verified fix.")
        runHandoffGapStabilityCheck(rows: makeRows(20), hasSyllableSync: true, label: "word-level")
    }

    @MainActor
    func test_lineGapsStableAcrossHandoff_lineLevel() {
        XCTExpectFailure("Diagnosed, not fixed — see comment above test_lineGapsStableAcrossHandoff_wordLevel. Founder/product decision needed on the blur-footprint tradeoff before an on-device-verified fix.")
        runHandoffGapStabilityCheck(rows: makeLineLevelRows(20), hasSyllableSync: false, label: "line-level")
    }

    @MainActor
    private func runManualScrollGapStabilityCheck(rows: [LayerBackedLyricRow], hasSyllableSync: Bool, label: String) {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        let currentIndex = 5
        mc.syncPlaybackClock(to: rows[currentIndex].displayLine.line.startTime + 0.35, playing: true)
        surface.configure(config(rows, current: currentIndex, mc: mc, hasSyllableSync: hasSyllableSync))
        surface.layoutSubtreeIfNeeded()
        drive(surface: surface, musicController: mc, rows: rows, from: rows[currentIndex].displayLine.line.startTime + 0.35, duration: 0.3, noisy: false)

        let beforeGaps = lineGaps(rowFrames(surface, count: rows.count))

        surface.debugBeginManualScroll()
        XCTAssertTrue(surface.debugManualScrollActive, "precondition: manual scroll engaged")
        surface.configure(config(rows, current: currentIndex, mc: mc, hasSyllableSync: hasSyllableSync, isManualScrolling: true))
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }

        let duringGaps = lineGaps(rowFrames(surface, count: rows.count))

        assertGapsStable(
            before: beforeGaps, after: duringGaps,
            excludingRowIndices: [currentIndex],
            context: "\(label) manual-scroll enter (current=\(currentIndex))"
        )
    }

    @MainActor
    func test_lineGapsStableEnteringManualScroll_wordLevel() {
        runManualScrollGapStabilityCheck(rows: makeRows(20), hasSyllableSync: true, label: "word-level")
    }

    @MainActor
    func test_lineGapsStableEnteringManualScroll_lineLevel() {
        runManualScrollGapStabilityCheck(rows: makeLineLevelRows(20), hasSyllableSync: false, label: "line-level")
    }
}
