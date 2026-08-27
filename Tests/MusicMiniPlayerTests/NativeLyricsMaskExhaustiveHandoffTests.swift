import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder 2026-08-27 诊断批 #3: 逐字切行后偶发整行高亮（mask 全亮）。
//
// Exhausts handoff timing with injected clocks + state injection:
//   - first phase before text geometry is laid out (the zero-bounds fallback)
//   - appear-window (0.8s force-snap) handoff
//   - far jump onto a previously unmounted row
//   - mid-line seek into the incoming line
// A "mask lost" frame is: active word-level line, whole-line bright overlay,
// per-word mask NOT engaged, model still wants a partial reveal.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsMaskExhaustiveHandoffTests: XCTestCase {

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

    private func makeRows(_ n: Int, duration: TimeInterval = 3.2) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * duration, e = s + duration
            let w = (e - s) / 4
            let line = LyricLine(
                text: "line \(i) has four words", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "line ", startTime: s, endTime: s + w),
                    LyricWord(word: "\(i) ", startTime: s + w, endTime: s + 2 * w),
                    LyricWord(word: "has four ", startTime: s + 2 * w, endTime: s + 3 * w),
                    LyricWord(word: "words", startTime: s + 3 * w, endTime: e),
                ]
            )
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(_ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
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

    private func isMaskLost(row: NativeLyricsRowView, expected: CGFloat) -> Bool {
        row.debugLastWholeLineHighlight || (
            row.debugLastMainBrightOverlayPresent
            && !row.debugLastAppliedActivePerRunSweep
            && expected < 0.9
            && row.debugMainBrightOpacity > 0.2
        )
    }

    @MainActor
    func test_zeroBoundsFirstPhase_doesNotShowWholeLineHighlight() {
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        host(view, NSSize(width: 320, height: 56))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240
        let rows = makeRows(1)
        let cfg = config(rows, current: 0, mc: mc)
        // First phase during configure, before layout — the historic fallback path.
        view.configure(row: rows[0], configuration: cfg)
        XCTAssertFalse(
            view.debugLastWholeLineHighlight,
            "first phase before geometry is ready must not paint whole-line bright"
        )
        XCTAssertFalse(
            view.debugLastMainBrightOverlayPresent && !view.debugLastAppliedActivePerRunSweep,
            "zero-bounds fallback must hide the sung overlay, not unmask it"
        )
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: cfg)
        if view.debugLastAppliedActivePerRunSweep {
            XCTAssertFalse(view.debugLastWholeLineHighlight)
        }
    }

    @MainActor
    func test_appearWindowHandoff_incomingLineNeverWholeLineHighlights() {
        assertHandoffNeverWholeLineHighlights(warmFrames: 6, from: 0, to: 1)
    }

    @MainActor
    func test_naturalModeHandoff_incomingLineNeverWholeLineHighlights() {
        assertHandoffNeverWholeLineHighlights(warmFrames: 90, from: 5, to: 6)
    }

    @MainActor
    func test_farJumpOntoUnmountedRow_incomingLineNeverWholeLineHighlights() {
        assertHandoffNeverWholeLineHighlights(warmFrames: 30, from: 0, to: 14)
    }

    @MainActor
    func test_midLineSeekIntoIncoming_doesNotWholeLineHighlight() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(12)
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 4_000
        var date = Date(timeIntervalSinceReferenceDate: 900_000_000)
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
        let start = rows[2].displayLine.line.startTime + 0.2
        mc.syncPlaybackClock(to: start, playing: true, at: date)
        surface.configure(config(rows, current: 2, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<20 { tick(start + TimeInterval(i) * step, current: 2) }

        let incoming = 8
        let mid = rows[incoming].displayLine.line.startTime
            + (rows[incoming].displayLine.line.endTime - rows[incoming].displayLine.line.startTime) * 0.5
        var lost = 0
        for i in 0..<45 {
            tick(mid + TimeInterval(i) * step, current: incoming)
            guard let row = surface.debugRowView(forIndex: incoming) else { continue }
            let expected = row.debugLastMainExpectedProgress ?? 0
            if isMaskLost(row: row, expected: expected) { lost += 1 }
        }
        XCTAssertEqual(lost, 0, "mid-line seek into a word-level line painted whole-line highlight on \(lost) frames")
    }

    @MainActor
    private func assertHandoffNeverWholeLineHighlights(warmFrames: Int, from: Int, to: Int) {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(20)
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 3_000
        var date = Date(timeIntervalSinceReferenceDate: 850_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }
        let step = 1.0 / 60.0
        func tick(_ playback: TimeInterval) {
            wall += step
            date = date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? from, mc: mc))
            surface.debugTick(displayInterval: step)
            RunLoop.main.run(until: Date())
        }
        let warmStart = rows[from].displayLine.line.startTime + 0.05
        mc.syncPlaybackClock(to: warmStart, playing: true, at: date)
        surface.configure(config(rows, current: from, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<warmFrames { tick(warmStart + TimeInterval(i) * step) }

        let handoff = rows[to].displayLine.line.startTime
        var lost = 0
        for i in 0..<90 {
            tick(handoff - 0.05 + TimeInterval(i) * step)
            guard let row = surface.debugRowView(forIndex: to) else { continue }
            let sem = surface.debugNativeSemanticIndex ?? -1
            guard sem == to else { continue }
            let expected = row.debugLastMainExpectedProgress ?? 0
            if isMaskLost(row: row, expected: expected) { lost += 1 }
        }
        XCTAssertEqual(
            lost, 0,
            "handoff \(from)→\(to) warm=\(warmFrames) painted whole-line highlight on \(lost) active frames"
        )
    }

    func test_v28VisualSpringDampingIsTwenty() {
        XCTAssertEqual(LyricsPresentationSpringParameters.amllNatural.damping, 16.5, accuracy: 0.0001)
        XCTAssertEqual(LyricsPresentationSpringParameters.amllVisual.damping, 20, accuracy: 0.0001)
        XCTAssertEqual(LyricsPresentationSpringParameters.amllVisual.mass, 1.0, accuracy: 0.0001)
        XCTAssertEqual(LyricsPresentationSpringParameters.amllVisual.stiffness, 100, accuracy: 0.0001)
    }
}
