import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Real-device evidence (coordinator relay, 2026-09-19): /tmp/nanopod_debug.log 18:10:55 logs a
// "position jump 215.4s→83.7s" during a pause/play mash; 18:11:36 logs `[ActiveBrightness] idx=17
// … bright=0.000 eff=0.000` — the karaoke overlay reads permanently invisible on a row whose line
// is STILL genuinely active, long after the mash. /tmp/nanopod_mask_trace.jsonl shows row 17's
// word 0–7 all `brightHiddenWhileSweeping=true, brightOpacity=0`.
//
// Root cause (reproduced below, not guessed): `mainPostLineFadeFloor` is a one-way monotone
// (`min`) — correct for its ORIGINAL purpose (a backward clock step during the post-line GAP must
// never re-light an already-faded overlay). But `48863d5`/`4bb9bed`'s fix moved the pin to run
// EVERY active frame, unconditionally feeding `plan.mainPostLineFade` through that same one-way
// `min` — including frames where the render clock transiently reads a time WELL PAST this line's
// own end (a pause/resume mash's position-correction landing on a stale sample is exactly such a
// transient). That one bad frame computes `mainPostLineFade` as fully decayed, `min` crushes the
// floor toward 0, and — because this row never crosses a line-change/seek/activation-edge trigger
// (the clock recovers a frame later and the SAME line is still genuinely active) — nothing ever
// re-arms it: the overlay stays invisible for the rest of that line's natural life.
//
// Fix: the floor's monotone guarantee only applies to time genuinely AFTER the line has ended.
// Whenever `currentTime <= lineEnd`, force the floor back to 1 unconditionally instead of `min`-
// ing a possibly-bad reading into it.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsPostLineFadeFloorRearmTests: XCTestCase {

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
        if let surface = view as? NativeLyricsSurfaceView { hostedSurfaces.append(surface) }
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

    // Long-running line (mirrors row 17 in the real trace, minutes into playback) so a "jump 30s
    // past its end, then back" fixture is unambiguous.
    private func longLine(start: TimeInterval) -> LyricLine {
        let end = start + 8.0
        let words: [LyricWord] = (0..<8).map { i in
            LyricWord(word: "word\(i) ", startTime: start + TimeInterval(i), endTime: start + TimeInterval(i) + 1)
        }
        return LyricLine(text: words.map(\.word).joined(), startTime: start, endTime: end, words: words)
    }

    @MainActor
    func test_transientClockJumpPastLineEnd_doesNotPermanentlyCrushBrightOverlay() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        surface.debugSkipDedupe = true
        let mc = MusicController(preview: true)
        mc.duration = 999
        mc.isPlaying = true

        let line = longLine(start: 200)
        let rows = [row(line, index: 0)]

        var wall: CFTimeInterval = 50_000
        surface.debugNowOverride = { wall }
        defer { surface.debugNowOverride = nil }

        func tick(_ playback: TimeInterval) {
            wall += 1.0 / 60.0
            mc.syncPlaybackClock(to: playback, playing: true, at: Date())
            surface.configure(config(rows, current: 0, mc: mc))
            surface.debugTick(displayInterval: 1.0 / 60.0)
            RunLoop.main.run(until: Date())
        }

        // Warm into the middle of the line, well within its sung window.
        var t: TimeInterval = line.startTime + 0.2
        while t < line.startTime + 3.0 {
            tick(t)
            t += 1.0 / 60.0
        }
        guard let warmRow = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row must be mounted while active")
        }
        XCTAssertGreaterThan(
            warmRow.debugMainBrightWordGlyphOpacities.first ?? 0, 0.9,
            "precondition: bright overlay must be lit mid-line before the injected glitch"
        )

        // Inject the exact real-device shape: ONE frame reads a time 30s past the line's own end
        // (line.endTime + 30 == a "position jump 215.4s→83.7s"-class stale sample), then the very
        // next frame recovers back to mid-line — the line never actually ended, never handed off,
        // this row's activation state never changed.
        tick(line.endTime + 30)
        tick(line.startTime + 3.0 + (1.0 / 60.0))

        guard let recoveredRow = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row must stay mounted across the glitch")
        }
        XCTAssertGreaterThan(
            recoveredRow.debugMainBrightWordGlyphOpacities.first ?? 0, 0.9,
            "bright overlay must recover once the clock is back inside the line — must not stay permanently crushed"
        )

        // Drive several more frames still inside the line to confirm it's not just a one-frame
        // fluke recovery but a genuinely re-armed, sustained floor.
        for _ in 0..<10 {
            t += 1.0 / 60.0
            tick(t)
        }
        guard let sustainedRow = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row must stay mounted")
        }
        XCTAssertGreaterThan(
            sustainedRow.debugMainBrightWordGlyphOpacities.first ?? 0, 0.9,
            "bright overlay must stay lit for the rest of the line's natural life after recovery"
        )
    }

    /// Companion variant driving the actual `MusicController` pause/play mash path
    /// (`syncPlaybackClock` toggling `playing` rapidly around the same stale-position jump) rather
    /// than a synthetic single-frame clock override — closer to how the real device produced the
    /// trace (velocity-pause induced position correction).
    @MainActor
    func test_pausePlayMashWithPositionCorrection_doesNotPermanentlyCrushBrightOverlay() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        surface.debugSkipDedupe = true
        let mc = MusicController(preview: true)
        mc.duration = 999

        let line = longLine(start: 200)
        let rows = [row(line, index: 0)]

        var wall: CFTimeInterval = 60_000
        surface.debugNowOverride = { wall }
        defer { surface.debugNowOverride = nil }

        func tick(_ playback: TimeInterval, playing: Bool) {
            wall += 1.0 / 60.0
            mc.isPlaying = playing
            mc.syncPlaybackClock(to: playback, playing: playing, at: Date())
            surface.configure(config(rows, current: 0, mc: mc))
            surface.debugTick(displayInterval: 1.0 / 60.0)
            RunLoop.main.run(until: Date())
        }

        var t: TimeInterval = line.startTime + 0.2
        while t < line.startTime + 3.0 {
            tick(t, playing: true)
            t += 1.0 / 60.0
        }

        // Pause/play mash: several rapid toggles, one of which carries a stale far-future position
        // (the class of bug the real trace shows — a velocity-pause correction landing on an old
        // sample before the poll catches up).
        tick(t, playing: false)
        tick(line.endTime + 45, playing: false)
        tick(line.endTime + 45, playing: true)
        tick(t + (1.0 / 60.0), playing: true)
        tick(t + (2.0 / 60.0), playing: true)

        guard let row0 = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row must stay mounted across the mash")
        }
        XCTAssertGreaterThan(
            row0.debugMainBrightWordGlyphOpacities.first ?? 0, 0.9,
            "bright overlay must recover after a pause/play mash with a stale position reading — must not stay permanently crushed"
        )
    }
}
