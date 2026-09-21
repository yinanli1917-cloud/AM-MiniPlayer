import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder real-machine 60fps recording, 2026-09-21 05:32, word-level song 下雨天,
// second line switch: the OUTGOING row (just-finished line, now the history row above
// the active one) reads too DARK while it recedes, then POPS back up in one frame once
// it settles.
//
// Root cause: while a row is the active single-pass text-phase row, its ON-SCREEN dim
// tier is `NativeLyricsActiveLineDrawLayer.dimContainer.opacity`, baked once per
// `applySinglePassActiveLine` call (== `NativeLyricsActiveLineDrawLayer.update(_:)`).
// `updatePlaybackPhase`/`applySinglePassActiveLine` only run for the row that is
// CURRENTLY the active text-phase row (`activeTextPhaseRow` in
// LyricsLayerRendererView). The instant a row loses that status (deferred
// deactivation: it keeps rendering through the SAME draw layer while the renderer
// springs its PARENT layer's opacity down over ~40 ticks, per
// `beginDeferredDeactivation`/`finalizeDeferredDeactivation`), that call stops — so
// `dimContainer.opacity` stays frozen at whatever it was on the last active tick.
// Meanwhile `applyDimBaseCompensation` keeps re-deriving the CORRECT value
// (`lastDimBaseTier / rowOpacity`) every single tick (`setRowOpacity` runs for every
// visible row every frame, deferred or not) — but only writes it to the HIDDEN
// `mainTextLayer`. So the VISIBLE dim tile decays as `rowOpacity(t) × frozenDim`
// (too dark, since frozenDim was baked for rowOpacity≈1) while the correct,
// continuously-compensated value sits unseen on the hidden layer; when
// `finalizeDeferredDeactivation` swaps the hidden layer back in, that correct (much
// brighter) value appears in a single frame — the pop.
//
// This test hosts the real surface with injected clocks (NativeLyricsHandoffClockTests /
// NativeLyricsSinglePassActiveLineTests pattern) and drives a genuine line switch through
// the production code path (`configure` → `debugTick` → `updatePlaybackPhase` →
// `beginDeferredDeactivation`/`finalizeDeferredDeactivation`), sampling the row's
// EFFECTIVE dim-channel brightness every tick: `debugRowLayerOpacity` (the row's own
// spring-animated layer opacity) × `debugVisibleDimChannel` (whichever of the two dim
// representations — the draw layer's dim tile, or the whole-line base — is ACTUALLY
// on screen at that tick). Reading `debugMainBaseLayerOpacity` alone (as the existing
// NativeLyricsDimBaseContinuityTests do) would miss this bug entirely: that channel is
// correctly compensated throughout, it's just invisible while single-pass rendering owns
// the row.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsDeferredDeactivationBrightnessTests: XCTestCase {
    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.testingActiveLine = nil
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

    private func wordLine(start: TimeInterval, duration: TimeInterval) -> LyricLine {
        let e = start + duration
        let w = duration / 4
        return LyricLine(
            text: "下雨天 我好想你",
            startTime: start, endTime: e,
            words: [
                LyricWord(word: "下雨天 ", startTime: start, endTime: start + w),
                LyricWord(word: "我 ", startTime: start + w, endTime: start + 2 * w),
                LyricWord(word: "好 ", startTime: start + 2 * w, endTime: start + 3 * w),
                LyricWord(word: "想你", startTime: start + 3 * w, endTime: e),
            ]
        )
    }

    private func row(_ line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
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

    /// Effective, ON-SCREEN dim-channel brightness: the row's own layer opacity (the spring)
    /// times whichever dim representation is actually visible this tick.
    private func effectiveDimBrightness(_ view: NativeLyricsRowView) -> CGFloat {
        CGFloat(view.debugRowLayerOpacity) * CGFloat(view.debugVisibleDimChannel)
    }

    @MainActor
    func test_outgoingRowDimBrightness_noPopAtDeferredDeactivationFinalize() {
        NativeLyricsFeelParity.testingActiveLine = .singlePass
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let lineDuration: TimeInterval = 3.0
        let rows = (0..<4).map { i in row(wordLine(start: TimeInterval(i) * lineDuration, duration: lineDuration), index: i) }
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }
        let step = 1.0 / 60.0
        func tick(_ playback: TimeInterval, current: Int) {
            wall += step
            date = date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: current, mc: mc))
            surface.debugTick(displayInterval: step)
            RunLoop.main.run(until: Date())
        }

        // Warm up: mount and settle on line 0, run it almost to its end so the outgoing row's
        // own karaoke sweep has genuinely completed (not a synthetic snapshot).
        mc.syncPlaybackClock(to: 0.2, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<24 { tick(0.2 + TimeInterval(i) * step, current: 0) }
        for i in 0..<40 { tick(lineDuration - 0.6 + TimeInterval(i) * step, current: 0) }

        guard let outgoing = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row 0 not mounted")
        }
        XCTAssertFalse(outgoing.activeLineDrawLayer.isHidden, "precondition: row 0 must be the live single-pass active line")
        // The reference brightness: what THIS same channel formula reads for a genuinely
        // inactive, never-activated row (row 2, still upcoming) — the target the outgoing
        // row's dim tier must land back on once it settles.
        guard let neverActivated = surface.debugRowView(forIndex: 2) else {
            return XCTFail("row 2 not mounted")
        }

        // The line switch: line 0 finishes, line 1 becomes active, row 0 enters deferred
        // deactivation and keeps rendering through the SAME single-pass draw layer while its
        // own layer opacity springs down.
        struct Sample {
            let tick: Int
            let brightness: CGFloat
            let drawLayerHidden: Bool
            let baseHidden: Bool
            let rowOpacity: Float
        }
        var series: [Sample] = []
        var finalizeTick: Int?
        let switchTime = lineDuration + 0.02
        for i in 0..<90 {
            tick(switchTime + TimeInterval(i) * step, current: 1)
            let drawHidden = outgoing.activeLineDrawLayer.isHidden
            let baseHidden = outgoing.debugMainTextLayerHidden
            series.append(Sample(
                tick: i,
                brightness: effectiveDimBrightness(outgoing),
                drawLayerHidden: drawHidden,
                baseHidden: baseHidden,
                rowOpacity: outgoing.debugRowLayerOpacity
            ))
            if finalizeTick == nil, !baseHidden {
                finalizeTick = i
            }
        }

        for s in series {
            print(String(format: "[DeferredDeactivationBrightness] tick=%3d brightness=%.4f drawHidden=%@ baseHidden=%@ rowOpacity=%.3f",
                          s.tick, s.brightness, s.drawLayerHidden ? "Y" : "N", s.baseHidden ? "Y" : "N", s.rowOpacity))
        }

        guard let finalizeIndex = finalizeTick, finalizeIndex > 0 else {
            return XCTFail("deferred deactivation never finalized within the census window; trace=\(series.map { String(format: "%.3f", $0.brightness) })")
        }

        // The whole trajectory must be smooth: no single-tick jump bigger than what genuine
        // opacity-spring motion can itself produce. Compute the largest per-tick delta OUTSIDE
        // the finalize tick as the "spring motion" scale, then assert the finalize tick's own
        // delta is not a multiple of that — i.e. finalize must not be a special, extra pop on
        // top of ordinary per-tick motion.
        let deltas = zip(series, series.dropFirst()).map { abs($1.brightness - $0.brightness) }
        let finalizeDelta = deltas[finalizeIndex - 1]
        let otherDeltas = deltas.enumerated().filter { $0.offset != finalizeIndex - 1 }.map(\.element)
        let maxOtherDelta = otherDeltas.max() ?? 0
        XCTAssertLessThanOrEqual(
            finalizeDelta, max(0.05, maxOtherDelta * 3),
            "finalize tick (\(finalizeIndex)) brightness jump (\(finalizeDelta)) must not exceed ordinary per-tick spring motion (\(maxOtherDelta)) by more than 3x / 0.05 absolute — this is the founder-reported 'pop'. trace=\(series.map { String(format: "%.3f", $0.brightness) })"
        )

        // Steady state: once the row settles (its own layer opacity stops moving), its dim
        // channel must equal what the SAME formula reads on a genuinely inactive row at that
        // same moment — finalize must be visually a no-op.
        let settled = series.suffix(10)
        let settledSpread = (settled.map(\.brightness).max() ?? 0) - (settled.map(\.brightness).min() ?? 0)
        XCTAssertLessThanOrEqual(settledSpread, 0.02, "post-finalize brightness must be flat once the row settles, not still drifting: \(settled.map { String(format: "%.3f", $0.brightness) })")

        let neverActivatedBrightness = effectiveDimBrightness(neverActivated)
        XCTAssertEqual(
            settled.last?.brightness ?? -1, neverActivatedBrightness, accuracy: 0.05,
            "the settled outgoing row must read at the same dim brightness as a row that was never activated"
        )
    }
}
