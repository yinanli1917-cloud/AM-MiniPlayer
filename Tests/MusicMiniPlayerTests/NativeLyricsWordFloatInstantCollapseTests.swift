import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// research/repro-2026-09-20-lyrics-render-3p.md — founder real-device report on top of 3o
// (research/repro-2026-09-19-lyrics-render-3o.md): "完完全全都是下沉的" — every sung line
// visibly sank TWICE on deactivation: once as the karaoke bright overlay's own 1.5s
// `mainPostLineFadeFloor` fade ran, then AGAIN roughly half a second later as 3o's own
// independent `mainWordFloatReturnFloor` 0.35s ease-out let the float go, with nothing else
// moving on screen at that point to mask the ~2pt drop.
//
// The real v2.8 reference has no independent float-release clock at all: a line leaves
// "current" and switches to static rendering (float snapped to 0, per-glyph tiles hidden,
// whole-line dim base un-hollowed) in the EXACT SAME FRAME its own scale (1→0.95) / blur /
// opacity spring RETARGETS toward the receded state — that much larger, already-moving spring
// is what covers the small geometry snap, so nothing "sinks" independently afterward.
//
// This file pins two invariants:
//  1. Row level: `mainWordFloatReturnFloor` (via `debugMainWordFloatReturnFloor`) is NEVER an
//     eased intermediate value strictly between 0 and 1 at any sampled frame — it is exactly 1
//     while the row is genuinely current (active or still fading out) and drops straight to 0
//     the instant `collapseWordFloatForDeactivation()` runs, never ticking through a fractional
//     value on the way down (the exact defect the deleted 3o timer produced).
//  2. Renderer level: `LyricsLayerRendererView.syncVisualTargets` calls that collapse in the
//     SAME tick the row's own `NativeLyricsVisualMotionState` target flips inactive (the
//     `quickRetarget` edge) — not on some later tick once an independent fade has drained.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsWordFloatInstantCollapseTests: XCTestCase {
    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.resetTestingOverrides()
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

    private func syllableLine(text: String, start: TimeInterval, wordDuration: TimeInterval) -> LyricLine {
        let chars = Array(text)
        var words: [LyricWord] = []
        var t = start
        for ch in chars {
            words.append(LyricWord(word: String(ch), startTime: t, endTime: t + wordDuration))
            t += wordDuration
        }
        return LyricLine(text: text, startTime: start, endTime: t, words: words)
    }

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                    isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "3p", artist: "A", album: "Al", duration: 240),
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

    /// Invariant 1: the row-level floor never carries an eased intermediate value, and the
    /// explicit collapse call zeroes it in the exact call that runs it — never a subsequent tick.
    @MainActor
    func test_collapseWordFloatForDeactivation_zeroesFloorInstantly_neverEased() {
        let panelWidth: CGFloat = 250
        let line = syllableLine(text: "只有你能带我走向未来", start: 0, wordDuration: 0.5)
        let rows = [row(for: line, index: 0)]
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 200))
        host(surface, NSSize(width: panelWidth, height: 200))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        let date = Date(timeIntervalSinceReferenceDate: 990_000_000)
        mc.debugPlaybackClockDateProvider = { date }
        defer { mc.debugPlaybackClockDateProvider = nil }

        // Mid-line: some word is actively floating.
        mc.syncPlaybackClock(to: 1.2, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc, width: panelWidth))
        surface.layoutSubtreeIfNeeded()
        CATransaction.flush()
        surface.debugTick(displayInterval: 1.0 / 60.0)

        guard let view = surface.debugRowView(forIndex: 0) else {
            XCTFail("row 0 must be mounted while genuinely current")
            return
        }
        XCTAssertEqual(view.debugMainWordFloatReturnFloor, 1, accuracy: 0.0001,
                        "floor must be pinned at 1 (fully floated) while the row is current")

        // The instant deactivation collapse — this is what LyricsLayerRendererView now calls in
        // lockstep with the row's own visual-target retarget, never on a delay.
        view.collapseWordFloatForDeactivation()

        XCTAssertEqual(view.debugMainWordFloatReturnFloor, 0, accuracy: 0.0001,
                        "the SAME call that collapses deactivation must zero the floor immediately")

        // Sampling several more frames afterward must never reveal an eased value creeping back
        // up or hovering between 0 and 1 — the deleted 3o timer is gone, there is nothing left to
        // ease.
        for _ in 0..<30 {
            surface.debugTick(displayInterval: 1.0 / 60.0)
            let f = view.debugMainWordFloatReturnFloor
            XCTAssertTrue(f == 0 || f == 1, "floor must only ever be exactly 0 or 1, got \(f)")
        }
    }

    /// Invariant 2: at the renderer level, the collapse happens in the SAME sync pass that flips
    /// the row's visual target inactive — not lagging behind an independent fade window.
    @MainActor
    func test_rendererCollapsesFloat_sameTickAsVisualTargetDeactivation() {
        let panelWidth: CGFloat = 250
        let line0 = syllableLine(text: "只有你能带我走向未来", start: 0, wordDuration: 0.5)
        let line1 = LyricLine(text: "下一句歌词内容", startTime: line0.endTime, endTime: line0.endTime + 3)
        let rows = [row(for: line0, index: 0), row(for: line1, index: 1)]
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 400))
        host(surface, NSSize(width: panelWidth, height: 400))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var date = Date(timeIntervalSinceReferenceDate: 990_000_000)
        mc.debugPlaybackClockDateProvider = { date }
        defer { mc.debugPlaybackClockDateProvider = nil }

        mc.syncPlaybackClock(to: 1.2, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc, width: panelWidth))
        surface.layoutSubtreeIfNeeded()
        CATransaction.flush()
        surface.debugTick(displayInterval: 1.0 / 60.0)

        guard let view0 = surface.debugRowView(forIndex: 0) else {
            XCTFail("row 0 must be mounted while genuinely current")
            return
        }
        XCTAssertEqual(view0.debugMainWordFloatReturnFloor, 1, accuracy: 0.0001)

        // Advance the clock past line 0's own end AND past line 1's start, so on the very next
        // sync pass line 1 becomes the current/visually-active row and line 0's visual target
        // flips inactive in ONE step (matching a normal line-advance tick, not a gradual fade
        // window artificially held open by the test).
        date = date.addingTimeInterval(4)
        mc.syncPlaybackClock(to: line0.endTime + 2, playing: true, at: date)
        surface.configure(config(rows, current: 1, mc: mc, width: panelWidth))
        surface.layoutSubtreeIfNeeded()
        CATransaction.flush()

        // Same tick: the floor must already be 0, not still 1 waiting on a subsequent fade tick.
        XCTAssertEqual(view0.debugMainWordFloatReturnFloor, 0, accuracy: 0.0001,
                        "row 0's float must collapse the SAME sync pass its visual target deactivates")
    }
}
