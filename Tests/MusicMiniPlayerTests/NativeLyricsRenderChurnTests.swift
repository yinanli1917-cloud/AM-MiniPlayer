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

    // Lockstep-clock gap-stability check (retires the wall-clock `runHandoffGapStabilityCheck`).
    // The original red result on this method was a harness artifact: `drive`/`settleInPlace` ran on
    // the real wall clock, and the surface's own wall-clock line-advance Timer
    // (LyricsLayerRendererView.swift, `scheduleNativeLineAdvanceTimerIfNeeded`) fired independently of
    // the test's `RunLoop.main.run(until:)` budget, moving the active pair from 8->9 while the
    // exclusion set stayed {5,6}. This class boxes the clock (rather than a local var + `inout`) so
    // `surface.debugNowOverride`'s captured closure and the helper functions below can both touch it
    // without tripping Swift's exclusivity checker.

    private final class LockstepClock {
        var wall: CFTimeInterval = 1_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    /// Drives the injected wall + playback clocks together by `playbackStep` per tick and runs one
    /// presentation tick (mirrors NativeLyricsHandoffClockTests.runHandoff's `step`).
    @MainActor
    private func lockstepStep(
        surface: NativeLyricsSurfaceView, mc: MusicController, rows: [LayerBackedLyricRow],
        hasSyllableSync: Bool, playback: TimeInterval, clock: LockstepClock, playbackStep: TimeInterval
    ) {
        clock.wall += playbackStep
        clock.date = clock.date.addingTimeInterval(playbackStep)
        mc.syncPlaybackClock(to: playback, playing: true, at: clock.date)
        surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc, hasSyllableSync: hasSyllableSync))
        surface.debugTick(displayInterval: playbackStep)
        RunLoop.main.run(until: Date())
    }

    /// Ticks the lockstep clock at a FROZEN playback time until every mounted row's y/scale
    /// changes by < 0.01 for 30 consecutive ticks (true steady state), or a fixed 3s (180 ticks @60fps)
    /// elapses — whichever comes first.
    @MainActor
    private func settleLockstep(
        surface: NativeLyricsSurfaceView, mc: MusicController, rows: [LayerBackedLyricRow],
        hasSyllableSync: Bool, at playbackTime: TimeInterval, clock: LockstepClock, playbackStep: TimeInterval
    ) {
        var stableRun = 0
        var previous = rowFrames(surface, count: rows.count)
        var previousScales: [Int: CGFloat] = [:]
        for i in 0..<rows.count {
            previousScales[i] = surface.debugRowView(forIndex: i)?.positioningTransform.a
        }
        let maxTicks = 180
        for _ in 0..<maxTicks {
            lockstepStep(surface: surface, mc: mc, rows: rows, hasSyllableSync: hasSyllableSync,
                         playback: playbackTime, clock: clock, playbackStep: playbackStep)
            let current = rowFrames(surface, count: rows.count)
            var currentScales: [Int: CGFloat] = [:]
            for i in 0..<rows.count {
                currentScales[i] = surface.debugRowView(forIndex: i)?.positioningTransform.a
            }
            var maxDelta: CGFloat = 0
            for i in 0..<rows.count {
                if let a = previous[i], let b = current[i] {
                    maxDelta = max(maxDelta, abs(a.minY - b.minY))
                }
                if let a = previousScales[i], let b = currentScales[i] {
                    maxDelta = max(maxDelta, abs(a - b))
                }
            }
            previous = current
            previousScales = currentScales
            if maxDelta < 0.01 {
                stableRun += 1
                if stableRun >= 30 { break }
            } else {
                stableRun = 0
            }
        }
    }

    @MainActor
    private func runHandoffGapStabilityCheckLockstep(rows: [LayerBackedLyricRow], hasSyllableSync: Bool, label: String) {
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

        let clock = LockstepClock()
        surface.debugNowOverride = { [weak clock] in clock?.wall ?? 0 }
        mc.debugPlaybackClockDateProvider = { [weak clock] in clock?.date ?? Date() }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }
        let playbackStep = 1.0 / 60.0

        // Warm-up: mount at line start + 0.1 and run continuously to +1.15 (1.05 s), well past the
        // 0.8 s appear (force-snap) window so it has expired before we start settling/measuring.
        let warmupStart = previousStart + 0.1
        mc.syncPlaybackClock(to: warmupStart, playing: true, at: clock.date)
        surface.configure(config(rows, current: previousIndex, mc: mc, hasSyllableSync: hasSyllableSync))
        surface.layoutSubtreeIfNeeded()
        let warmupEnd = previousStart + 1.15
        var t = warmupStart
        while t < warmupEnd {
            t += playbackStep
            lockstepStep(surface: surface, mc: mc, rows: rows, hasSyllableSync: hasSyllableSync,
                         playback: t, clock: clock, playbackStep: playbackStep)
        }
        XCTAssertEqual(surface.debugNativeSemanticIndex, previousIndex,
                       "\(label): must still be on the previous line \(previousIndex) after warm-up (was \(String(describing: surface.debugNativeSemanticIndex)))")

        // Settle to true steady state at a frozen playback time, then measure.
        settleLockstep(surface: surface, mc: mc, rows: rows, hasSyllableSync: hasSyllableSync,
                      at: warmupEnd, clock: clock, playbackStep: playbackStep)
        XCTAssertEqual(surface.debugNativeSemanticIndex, previousIndex,
                       "\(label): settling before the handoff must not itself advance the line")
        let beforeGaps = lineGaps(rowFrames(surface, count: rows.count))

        // Drive lockstep across the boundary into the next line, then settle again at a frozen time.
        var p = warmupEnd
        let afterHandoffTarget = handoffTime + 1.15
        while p < afterHandoffTarget {
            p += playbackStep
            lockstepStep(surface: surface, mc: mc, rows: rows, hasSyllableSync: hasSyllableSync,
                         playback: p, clock: clock, playbackStep: playbackStep)
        }
        XCTAssertEqual(surface.debugNativeSemanticIndex, nextIndex,
                       "\(label): must have handed off to line \(nextIndex) by now (was \(String(describing: surface.debugNativeSemanticIndex)))")

        settleLockstep(surface: surface, mc: mc, rows: rows, hasSyllableSync: hasSyllableSync,
                      at: afterHandoffTarget, clock: clock, playbackStep: playbackStep)
        XCTAssertEqual(surface.debugNativeSemanticIndex, nextIndex,
                       "\(label): settling after the handoff must not advance past \(nextIndex)")
        let afterGaps = lineGaps(rowFrames(surface, count: rows.count))

        assertGapsStable(
            before: beforeGaps, after: afterGaps,
            excludingRowIndices: [previousIndex, nextIndex],
            context: "\(label) lockstep handoff \(previousIndex)->\(nextIndex)"
        )
    }

    // Non-active line gaps stay constant across a 5->6 handoff under a lockstep (injected) clock,
    // driven to true steady state on both sides. The 80c5a7e-era red result on this method was a
    // harness artifact: the wall-clock line-advance Timer (see comment block above) moved the ACTIVE
    // pair from 8->9 while the exclusion set stayed {5,6}, so the assertion measured the wrong rows.
    // Blur (`NativeLyricsVisualTarget.amllTarget`'s renderedBlur) renders outside `.frame` bounds and
    // cannot move `view.frame` itself, so it cannot be the cause of a `.frame`-based gap drift either.
    @MainActor
    func test_lineGapsStableAcrossHandoff_wordLevel() {
        runHandoffGapStabilityCheckLockstep(rows: makeRows(20), hasSyllableSync: true, label: "word-level")
    }

    @MainActor
    func test_lineGapsStableAcrossHandoff_lineLevel() {
        runHandoffGapStabilityCheckLockstep(rows: makeLineLevelRows(20), hasSyllableSync: false, label: "line-level")
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

    @MainActor
    func test_wordGlyphColorIsNotReassignedEveryFrame() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(8)
        surface.debugSkipDedupe = true
        let start = rows[0].displayLine.line.startTime + 0.15
        mc.syncPlaybackClock(to: start, playing: true)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        drive(surface: surface, musicController: mc, rows: rows, from: start, duration: 0.35, noisy: false)

        let index = surface.debugNativeSemanticIndex ?? 0
        guard let view = surface.debugRowView(forIndex: index) else {
            XCTFail("expected a mounted row at \(index)")
            return
        }
        let afterWarm = view.debugWordGlyphColorAssignCount
        XCTAssertGreaterThan(afterWarm, 0, "warmup must paint per-glyph colors once")

        drive(surface: surface, musicController: mc, rows: rows, from: start + 0.35, duration: 0.35, noisy: false)
        XCTAssertEqual(
            view.debugWordGlyphColorAssignCount,
            afterWarm,
            "steady karaoke frames must not re-assign CATextLayer.foregroundColor"
        )
    }
}
