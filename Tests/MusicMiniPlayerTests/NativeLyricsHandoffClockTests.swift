import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Deterministic-clock handoff gate.
//
// NativeLyricsRenderChurnTests.test_previousLineDoesNotFadeBeforeItStartsMovingAcrossHandoff drives
// the surface through the REAL run loop: the playback clock is stepped 1/60 s per iteration while the
// springs, the wave stagger and the 0.8 s appear (force-snap) window ride CACurrentMediaTime. Any
// iteration that costs more than 16.7 ms of host wall time changes how far that window extends into
// the census — so that test's verdict depended on host pacing. Here the same handoff runs with BOTH
// clocks injected and advanced in lockstep per frame (host pacing cannot leak in), then with the wall
// clock deliberately running faster/slower than playback, and once more in the red test's exact drive
// shape. Outcome (2026-08-21): the renderer's handoff is clean — position, opacity and bright overlay
// of the previous row all start receding on the SAME frame, one wave stagger after the boundary. The
// red verdict is reproduced only when the appear window is still open at the boundary: the drive feeds
// the surface's own semantic index back, snap mode cannot advance it, the handoff is deferred until the
// window expires, and meanwhile the still-active line's bright overlay follows the designed post-line
// afterglow (postLineFadeOut). "Faded before it moved" was the harness, not the handoff.
//
// Founder rule 2026-08-21: feel-class questions are answered with clock-stamped evidence from
// injected clocks, not screen recordings. The visual verdict itself stays with the founder.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsHandoffClockTests: XCTestCase {

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

    // Same fixture shape as NativeLyricsRenderChurnTests.makeRows: contiguous 1.2 s word-timed lines.
    private func makeRows(_ n: Int) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
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

    // ── Clock-stamped per-frame sample of the PREVIOUS row across the handoff ──────────────
    struct HandoffSample {
        let frame: Int
        let wall: TimeInterval          // injected wall clock, seconds since the census window opened
        let playback: TimeInterval      // injected playback clock (what the drive set)
        let renderClock: TimeInterval   // the surface's monotonic phase clock at its last paint
        let semantic: Int               // live nativeSemanticCurrentIndex after the frame
        let scrollTarget: Int
        let inAppearWindow: Bool
        let y: CGFloat
        let opacity: CGFloat
        let bright: CGFloat
        let fadeCurve: CGFloat          // NativeLyricsTextRenderPlan.postLineFadeOut(renderClock, lineEnd)
    }

    struct HandoffReport {
        let label: String
        let boundaryFrame: Int                      // first frame whose playback clock reached line 5's end
        let handoffFrame: Int                       // first frame with semantic index == 6
        let appearWindowOpenAtBoundary: Bool
        let appearWindowOpenAtHandoff: Bool
        let afterglowErrorDuringDeferral: CGFloat   // max |bright − postLineFadeOut| over [boundary, handoff)
        let firstMotionFrame: Int
        let firstBrightDropFrame: Int
        let firstOpacityDropFrame: Int
        let brightDropBeforeMotion: CGFloat
        let opacityDropBeforeMotion: CGFloat
        let motionOnsetSinceBoundary: TimeInterval  // playback seconds between the boundary frame and first motion
        let brightAtMotion: CGFloat
        let maxYStep: CGFloat
        let samples: [HandoffSample]

        /// The red test's verdict, evaluated on these deterministic samples.
        var redTestWouldPass: Bool {
            firstMotionFrame <= firstBrightDropFrame
                && brightDropBeforeMotion <= 0.02
                && firstMotionFrame <= firstOpacityDropFrame
                && opacityDropBeforeMotion <= 0.02
        }
    }

    /// Drive the real surface across the 5→6 handoff with injected clocks.
    /// - wallStepPerFrame: how much the presentation wall clock advances per 1/60 s of playback.
    ///   1/60 = lockstep (true 1x). 2/60 emulates a RunLoop harness whose iterations cost 33 ms.
    /// - redTestDriveShape: reproduce the red test's original warm-up (0.25 s from line start + 0.35)
    ///   and its forward clock jump into the census window, instead of a continuous 1.0 s run-up.
    @MainActor
    private func runHandoff(
        wallStepPerFrame: TimeInterval,
        redTestDriveShape: Bool = false,
        label: String
    ) -> HandoffReport? {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(20)
        surface.debugSkipDedupe = true

        let previousIndex = 5
        let nextIndex = previousIndex + 1
        let lineEnd = rows[previousIndex].displayLine.line.endTime
        let previousStart = rows[previousIndex].displayLine.line.startTime
        let handoffTime = rows[nextIndex].displayLine.line.startTime

        var wall: CFTimeInterval = 1_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let playbackStep = 1.0 / 60.0
        func step(playback: TimeInterval) {
            wall += wallStepPerFrame
            date = date.addingTimeInterval(playbackStep)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc))
            surface.debugTick(displayInterval: wallStepPerFrame)
            RunLoop.main.run(until: Date())
        }

        // Warm-up. Continuous: mount at line start + 0.1 and run 1.0 s of playback so the 0.8 s appear
        // window (snap mode) has expired before the boundary at every pacing ≥ 1x. Red-test shape: mount
        // at line start + 0.35, run 0.25 s, then jump the clock forward into the census window.
        let warmupStart = redTestDriveShape ? previousStart + 0.35 : previousStart + 0.1
        let warmupFrames = redTestDriveShape ? 15 : 60
        mc.syncPlaybackClock(to: warmupStart, playing: true, at: date)
        surface.configure(config(rows, current: previousIndex, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<warmupFrames {
            step(playback: warmupStart + TimeInterval(i) * playbackStep)
        }

        // Census window: from 0.08 s before the handoff (red test) or continuously from where the
        // warm-up left off, for 1.2 s of playback.
        let censusStart = redTestDriveShape
            ? handoffTime - 0.08
            : warmupStart + TimeInterval(warmupFrames) * playbackStep
        surface.debugResetCensus()
        surface.debugCensusEnabled = true
        let wallBase = wall
        var samples: [HandoffSample] = []
        let censusFrames = 72
        for i in 0..<censusFrames {
            let playback = censusStart + TimeInterval(i) * playbackStep
            step(playback: playback)
            guard let track = surface.debugCensusByIndex[previousIndex],
                  let y = track.y.last, let op = track.opacity.last, let br = track.bright.last else { continue }
            let rc = surface.debugClockTrace.last.flatMap { $0 >= 0 ? $0 : nil } ?? playback
            samples.append(HandoffSample(
                frame: i,
                wall: wall - wallBase,
                playback: playback,
                renderClock: rc,
                semantic: surface.debugNativeSemanticIndex ?? -1,
                scrollTarget: surface.debugNativeScrollTargetIndex ?? -1,
                inAppearWindow: wall < surface.debugForceSnapUntil,
                y: y, opacity: op, bright: br,
                fadeCurve: NativeLyricsTextRenderPlan.postLineFadeOut(currentTime: rc, lineEndTime: lineEnd)
            ))
        }
        surface.debugCensusEnabled = false

        guard samples.count > 8 else {
            XCTFail("\(label): previous row \(previousIndex) must stay mounted across the handoff (\(samples.count) samples)")
            return nil
        }
        guard let handoffFrame = samples.firstIndex(where: { $0.semantic == nextIndex }) else {
            XCTFail("\(label): semantic index never advanced to \(nextIndex); trace=\(samples.map(\.semantic))")
            return nil
        }
        let boundaryFrame = samples.firstIndex { $0.playback >= lineEnd - 0.001 } ?? handoffFrame
        let count = samples.count
        let y = samples.map(\.y)
        let opacity = samples.map(\.opacity)
        let bright = samples.map(\.bright)
        let visualBrightness = zip(opacity, bright).map { $0 * max($1, 0.2) }
        let pre = max(3, handoffFrame)
        let baselineY = y.prefix(pre).reduce(0, +) / CGFloat(pre)
        let baselineOpacity = opacity.prefix(pre).max() ?? opacity[handoffFrame]
        let baselineBrightness = visualBrightness.prefix(pre).max() ?? visualBrightness[handoffFrame]
        let firstMotion = y.firstIndex { abs($0 - baselineY) > 0.5 } ?? count - 1
        let firstOpacityDrop = opacity.firstIndex { baselineOpacity - $0 > 0.02 } ?? count - 1
        let firstBrightnessDrop = visualBrightness.firstIndex { baselineBrightness - $0 > 0.02 } ?? count - 1
        let preMotionRange = min(firstOpacityDrop, handoffFrame)...max(handoffFrame, firstMotion - 1)
        let opacityDropBeforeMotion = baselineOpacity - (preMotionRange.map { opacity[$0] }.min() ?? opacity[handoffFrame])
        let brightRange = min(firstBrightnessDrop, handoffFrame)...max(handoffFrame, firstMotion - 1)
        let brightnessDropBeforeMotion = baselineBrightness - (brightRange.map { visualBrightness[$0] }.min() ?? visualBrightness[handoffFrame])
        let maxYStep = zip(y, y.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        let deferral = boundaryFrame < handoffFrame ? Array(boundaryFrame..<handoffFrame) : []
        let afterglowError = deferral.map { abs(samples[$0].bright - samples[$0].fadeCurve) }.max() ?? 0

        let report = HandoffReport(
            label: label,
            boundaryFrame: boundaryFrame,
            handoffFrame: handoffFrame,
            appearWindowOpenAtBoundary: samples[boundaryFrame].inAppearWindow,
            appearWindowOpenAtHandoff: samples[handoffFrame].inAppearWindow,
            afterglowErrorDuringDeferral: afterglowError,
            firstMotionFrame: firstMotion,
            firstBrightDropFrame: firstBrightnessDrop,
            firstOpacityDropFrame: firstOpacityDrop,
            brightDropBeforeMotion: brightnessDropBeforeMotion,
            opacityDropBeforeMotion: opacityDropBeforeMotion,
            motionOnsetSinceBoundary: samples[firstMotion].playback - samples[boundaryFrame].playback,
            brightAtMotion: bright[firstMotion],
            maxYStep: maxYStep,
            samples: samples
        )
        dump(report)
        return report
    }

    private func dump(_ r: HandoffReport) {
        func f(_ v: CGFloat) -> String { String(format: "%.3f", v) }
        print(
            "[HandoffClock:\(r.label)] boundaryFrame=\(r.boundaryFrame) handoffFrame=\(r.handoffFrame) " +
            "appearOpen@boundary=\(r.appearWindowOpenAtBoundary) appearOpen@handoff=\(r.appearWindowOpenAtHandoff) " +
            "afterglowErrorDuringDeferral=\(f(r.afterglowErrorDuringDeferral)) " +
            "firstMotion=\(r.firstMotionFrame) firstBrightDrop=\(r.firstBrightDropFrame) firstOpacityDrop=\(r.firstOpacityDropFrame) " +
            "brightDropBeforeMotion=\(f(r.brightDropBeforeMotion)) opacityDropBeforeMotion=\(f(r.opacityDropBeforeMotion)) " +
            "motionOnset=+\(String(format: "%.3f", r.motionOnsetSinceBoundary))s after boundary " +
            "brightAtMotion=\(f(r.brightAtMotion)) maxYStep=\(String(format: "%.2f", r.maxYStep)) " +
            "redTestWouldPass=\(r.redTestWouldPass)"
        )
        let lo = max(0, min(r.boundaryFrame, r.handoffFrame) - 2)
        let hi = min(r.samples.count - 1, r.firstMotionFrame + 3)
        print("[HandoffClock:\(r.label)]  frame  wall_ms  playback  renderClk  sem scr appear      y     op  bright  curve")
        for s in r.samples[lo...hi] where s.frame <= r.boundaryFrame + 2 || s.frame >= r.handoffFrame - 2 {
            print(String(
                format: "[HandoffClock:%@]  %5d  %7.1f  %8.3f  %9.3f  %3d %3d %@  %7.2f  %.3f  %.3f  %.3f",
                r.label, s.frame, s.wall * 1000, s.playback, s.renderClock, s.semantic, s.scrollTarget,
                s.inAppearWindow ? "snap " : "natur", s.y, s.opacity, s.bright, s.fadeCurve
            ))
        }
    }

    // ── Gates ───────────────────────────────────────────────────────────────────────────────

    /// True 1x with the appear window expired before the boundary: the handoff lands on the boundary
    /// frame and the previous row's position, opacity and bright overlay all start receding on the
    /// SAME frame, one wave stagger (2 × 0.08 s) later. No fade-before-motion in the renderer.
    @MainActor
    func test_lockstepClock_previousRowRecedesInOneFrameOneWaveStaggerAfterTheBoundary() {
        guard let r = runHandoff(wallStepPerFrame: 1.0 / 60.0, label: "lockstep-1x") else { return }
        XCTAssertFalse(r.appearWindowOpenAtBoundary, "precondition: the appear window must have expired before the boundary")
        XCTAssertEqual(r.handoffFrame, r.boundaryFrame, "the semantic handoff lands on the boundary frame")
        XCTAssertEqual(r.firstMotionFrame, r.firstBrightDropFrame, "bright overlay recede starts on the motion frame")
        XCTAssertEqual(r.firstMotionFrame, r.firstOpacityDropFrame, "opacity recede starts on the motion frame")
        XCTAssertEqual(r.brightDropBeforeMotion, 0, accuracy: 0.001, "no brightness loss before the row moves")
        XCTAssertEqual(r.opacityDropBeforeMotion, 0, accuracy: 0.001, "no opacity loss before the row moves")
        XCTAssertEqual(r.motionOnsetSinceBoundary, 0.15, accuracy: 0.034,
                       "the previous row starts moving one wave stagger (2 × 0.08 s, ±2 frames) after the boundary")
        XCTAssertLessThanOrEqual(r.maxYStep, 12, "handoff motion stays within the smooth-motion budget")
        XCTAssertTrue(r.redTestWouldPass, "the churn test's own verdict passes under lockstep clocks")
    }

    /// The red test's original drive shape: a 0.25 s warm-up leaves the 0.8 s appear window open across
    /// the boundary. Snap mode cannot advance the line (the drive feeds the surface's own index back),
    /// so the handoff is deferred until the window expires while the still-active line's bright overlay
    /// follows the designed post-line afterglow — "faded before it moved" by construction of the drive.
    @MainActor
    func test_redTestDriveShape_handoffDeferredByOpenAppearWindowIsWhyItWentRed() {
        guard let r = runHandoff(wallStepPerFrame: 1.0 / 60.0, redTestDriveShape: true, label: "redshape-1x") else { return }
        XCTAssertTrue(r.appearWindowOpenAtBoundary, "the boundary falls inside the appear window")
        XCTAssertFalse(r.appearWindowOpenAtHandoff, "the handoff only lands once the window has expired")
        XCTAssertGreaterThanOrEqual(r.handoffFrame - r.boundaryFrame, 12, "the handoff is deferred ≥ 0.2 s past the boundary")
        XCTAssertLessThanOrEqual(r.afterglowErrorDuringDeferral, 0.015,
                                 "during the deferral the bright overlay IS postLineFadeOut(renderClock − lineEnd)")
        XCTAssertEqual(r.opacityDropBeforeMotion, 0, accuracy: 0.001, "the row's opacity never faded early — only the afterglow did")
        XCTAssertFalse(r.redTestWouldPass, "reproduces the red verdict deterministically")
    }

    /// Pacing sweep with the window expired: the verdict does not depend on how much wall time a
    /// playback frame costs. Only the appear-window overlap (wall slower than playback here, so the
    /// window outlives the warm-up) flips it — the same deferral artifact, renderer unchanged.
    @MainActor
    func test_pacingSweep_verdictFollowsAppearWindowOverlapNotHostPacing() {
        for (step, label) in [(1.0, "pace-1.0x"), (1.5, "pace-1.5x"), (2.0, "pace-2.0x")] {
            guard let r = runHandoff(wallStepPerFrame: step / 60.0, label: label) else { continue }
            XCTAssertFalse(r.appearWindowOpenAtBoundary, label)
            XCTAssertEqual(r.brightDropBeforeMotion, 0, accuracy: 0.001, label)
            XCTAssertTrue(r.redTestWouldPass, label)
        }
        guard let slow = runHandoff(wallStepPerFrame: 0.5 / 60.0, label: "pace-0.5x") else { return }
        XCTAssertTrue(slow.appearWindowOpenAtBoundary, "wall at half speed keeps the appear window open past the boundary")
        XCTAssertFalse(slow.redTestWouldPass, "…and that alone reproduces the red verdict")
    }
}
