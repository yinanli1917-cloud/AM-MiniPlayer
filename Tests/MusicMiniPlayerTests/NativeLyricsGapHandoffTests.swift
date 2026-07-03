import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// The "previous line pops bright at the gap → next-line handoff" glitch (measured live on 眼淚).
//
// Measured per-frame luminance of the just-finished line: FLAT through the ~gap, then a +0.025
// spike (the single largest frame jump) the instant the next line starts, decaying over ~0.15s.
// The pure-model opacity spring is already monotonic (NativeLyricsOpacityDemotionTests), so the
// pop is a RENDERER-layer effect (the karaoke bright overlay, the row opacity tier, or scale)
// that the model test can't see. This drives the REAL surface through sung → gap → next-line and
// captures the previous line's channels per clock-step so the popping channel is named, not guessed.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsGapHandoffTests: XCTestCase {

    private var hostWindow: NSWindow?
    override func tearDown() { hostWindow?.orderOut(nil); hostWindow = nil; super.tearDown() }

    @MainActor
    private func hostInWindow(_ view: NSView, size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
    }

    // Five lines with a ~0.95s GAP after line 2 (matching the measured clip): line 2 ends at 7,
    // line 3 starts at 7.95, so the post-line overlay fade (1.5s) is only ~0.6 — NOT 0 — at the
    // handoff. Line 2 is the "previous line" we watch as playback crosses the gap into line 3.
    private func gappedRows(syllable: Bool, line3Start: TimeInterval = 7.95) -> [LayerBackedLyricRow] {
        let spans: [(TimeInterval, TimeInterval)] = [(0,2),(2,4),(4,7),(line3Start, line3Start+3),(line3Start+3.05, line3Start+6)]
        return spans.enumerated().map { i, s in
            var line = LyricLine(text: "line \(i) words here", startTime: s.0, endTime: s.1)
            if syllable {
                // minimal per-word syllable timing so the line is treated as 逐字 (word-level)
                let dur = (s.1 - s.0) / 3
                line = LyricLine(
                    text: "line \(i) words here", startTime: s.0, endTime: s.1,
                    words: [
                        LyricWord(word: "line ", startTime: s.0, endTime: s.0 + dur),
                        LyricWord(word: "\(i) ", startTime: s.0 + dur, endTime: s.0 + 2*dur),
                        LyricWord(word: "words here", startTime: s.0 + 2*dur, endTime: s.1),
                    ]
                )
            }
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], currentIndex: Int,
                        mc: MusicController, syllable: Bool) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = CGFloat(r.index) * 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: currentIndex, anchorY: 250, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 3, hasSyllableSync: syllable,
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

    private struct Sample {
        let t: TimeInterval, semantic: Int
        let bright2: Float, opac2: Float, scale2: CGFloat, y2: CGFloat
        let bright3: Float, opac3: Float, scale3: CGFloat, y3: CGFloat
    }

    @MainActor
    private func driveAcrossGap(syllable: Bool) -> [Sample] {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = gappedRows(syllable: syllable)

        // settle on line 2 while it is singing
        mc.syncPlaybackClock(to: 5.0, playing: true)
        surface.configure(config(rows: rows, currentIndex: 2, mc: mc, syllable: syllable))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(1.0/60.0)) }

        var samples: [Sample] = []
        var t = 6.6
        while t <= 8.8 {
            mc.syncPlaybackClock(to: t, playing: true)
            surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? 2, mc: mc, syllable: syllable))
            for _ in 0..<2 { RunLoop.main.run(until: Date().addingTimeInterval(1.0/60.0)) }
            let v2 = surface.debugRowView(forIndex: 2)
            let v3 = surface.debugRowView(forIndex: 3)
            samples.append(Sample(
                t: t, semantic: surface.debugNativeSemanticIndex ?? -1,
                bright2: v2?.debugMainBrightOpacity ?? -1, opac2: v2?.debugPresentationOpacity ?? -1,
                scale2: v2?.debugPresentationScale ?? -1, y2: v2?.frame.origin.y ?? -1,
                bright3: v3?.debugMainBrightOpacity ?? -1, opac3: v3?.debugPresentationOpacity ?? -1,
                scale3: v3?.debugPresentationScale ?? -1, y3: v3?.frame.origin.y ?? -1))
            t += 0.03
        }
        return samples
    }

    // Reproduce the OVERLAY re-light: during a gap the just-finished line's karaoke overlay fades out
    // via postLineFadeOut(rawClock - lineEndTime). updatePlaybackPhase reads the RAW lyricRenderTime,
    // so a drift-driven backward poll resync (clock steps back toward the line end) RAISES the overlay
    // back up — the previous line re-brightens. The index-hold (isResyncRewind) never covers this.
    @MainActor
    func test_overlayRelightsWhenClockStepsBackwardInGap() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = gappedRows(syllable: true)   // line 2 = [4,7), gap, line 3 = [7.95,...)

        func tick(_ t: TimeInterval, frames: Int = 3) {
            mc.syncPlaybackClock(to: t, playing: true)
            surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? 2, mc: mc, syllable: true))
            for _ in 0..<frames { RunLoop.main.run(until: Date().addingTimeInterval(1.0/60.0)) }
        }
        func overlay2() -> Float { surface.debugRowView(forIndex: 2)?.debugMainBrightOpacity ?? -1 }

        tick(5.0, frames: 10)                       // line 2 singing
        tick(7.0)                                   // line 2 ends -> overlay full
        tick(7.7)                                   // 0.7s into gap -> overlay fading
        let faded = overlay2()
        tick(7.85)                                  // deeper into the gap -> overlay fades further
        let deeper = overlay2()
        XCTAssertLessThan(deeper, faded + 0.001, "precondition: overlay is fading DOWN during the gap")

        // A drift-driven poll resync steps the clock BACKWARD toward the line end (still index 2, no seek).
        tick(7.05)
        let afterBackstep = overlay2()
        print(String(format: "overlay: faded(t7.7)=%.3f deeper(t7.85)=%.3f afterBackstep(t7.05)=%.3f",
                     faded, deeper, afterBackstep))

        XCTAssertLessThanOrEqual(
            afterBackstep, deeper + 0.02,
            "the previous line's karaoke overlay RE-LIT on a backward clock step (\(deeper) -> \(afterBackstep)) — the gap re-light"
        )
    }

    // The HOLE in the floor: a backward jitter that lands at/before the line's end makes postLineFade
    // read ~1.0, which (wrongly) looks like "re-entered the sung window" and reset the floor → the
    // faded overlay snapped back to full. A NON-explicit backward jitter must never re-light, even
    // across the line boundary. Only an explicit seek (or a new line) may re-activate the overlay.
    @MainActor
    func test_overlayDoesNotRelightOnBackwardJitterAcrossLineEnd() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = gappedRows(syllable: true, line3Start: 10.0)   // line 2 = [4,7), 3s gap, line 3 = [10,13)

        func tick(_ t: TimeInterval, frames: Int = 3) {
            mc.syncPlaybackClock(to: t, playing: true)
            surface.configure(config(rows: rows, currentIndex: surface.debugNativeSemanticIndex ?? 2, mc: mc, syllable: true))
            for _ in 0..<frames { RunLoop.main.run(until: Date().addingTimeInterval(1.0/60.0)) }
        }
        func overlay2() -> Float { surface.debugRowView(forIndex: 2)?.debugMainBrightOpacity ?? -1 }

        tick(5.0, frames: 10)         // line 2 singing
        tick(7.0)                     // line 2 ends (line 2 still active: gap runs to 10)
        tick(8.6)                     // 1.6s past end -> overlay fully faded to ~0
        let faded = overlay2()
        XCTAssertLessThan(faded, 0.05, "precondition: overlay fully faded out during the gap")

        // Non-explicit backward jitter that lands BEFORE the line end (no registerSeek call).
        tick(6.5)
        let afterCross = overlay2()
        print(String(format: "acrossLineEnd: faded(t8.6)=%.3f afterBackJitter(t6.5)=%.3f", faded, afterCross))

        XCTAssertLessThanOrEqual(
            afterCross, faded + 0.05,
            "overlay RE-LIT (\(faded) -> \(afterCross)) on a non-explicit backward jitter across the line end — the floor reset hole"
        )
    }

    @MainActor
    func test_diagnose_previousLineChannelsAcrossGapHandoff() {
        for syllable in [false, true] {
            let s = driveAcrossGap(syllable: syllable)
            print("=== syllable=\(syllable) — line2(prev) vs line3(next), ~0.95s gap, next starts t=7.95 ===")
            for x in s {
                print(String(format: "t=%.2f sem=%d | L2 br=%.3f op=%.3f sc=%.3f y=%.0f | L3 br=%.3f op=%.3f sc=%.3f y=%.0f",
                             x.t, x.semantic, x.bright2, x.opac2, x.scale2, x.y2, x.bright3, x.opac3, x.scale3, x.y3))
            }
            // line-2 (previous) brightness proxy: overlay if word-level, else row opacity
            let b2 = s.map { Float($0.opac2) * max($0.bright2, 0.2) }
            var maxUp: Float = 0; var upT = 0.0
            for i in 1..<b2.count where b2[i] - b2[i-1] > maxUp { maxUp = b2[i] - b2[i-1]; upT = s[i].t }
            print(String(format: "syllable=%@ L2 maxUpwardBrightStep=%.3f at t=%.2f", "\(syllable)", maxUp, upT))
            // On a clean forward gap→handoff the previous line must only fade — never pop up.
            XCTAssertLessThanOrEqual(maxUp, 0.02,
                "previous line brightened by \(maxUp) at t=\(upT) on a forward handoff (syllable=\(syllable))")
        }
    }

}
