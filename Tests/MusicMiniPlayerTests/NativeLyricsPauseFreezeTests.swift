import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder 2026-08-27: 逐字播放中一暂停，高光立刻变成整行全亮。
//
// Mechanism (reproduced, not guessed):
// NativeLyricsTextRenderPlan sets mainSweepProgress = 1 whenever isActive is
// false. Text-active used to be `current && isPlaying`, so pause flipped the
// singing line to inactive, hid the per-word mask, and dropped dim-base
// compensation — the whole line read at row opacity 1.0.
//
// Invariant: pause freezes the current word-level progress in place. It must
// not promote the line to a fully-bright whole-line reveal.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsPauseFreezeTests: XCTestCase {

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

    private func wordLine(start: TimeInterval = 0, duration: TimeInterval = 4) -> LyricLine {
        let e = start + duration
        let w = duration / 4
        return LyricLine(
            text: "hello brave new world",
            startTime: start, endTime: e,
            words: [
                LyricWord(word: "hello ", startTime: start, endTime: start + w),
                LyricWord(word: "brave ", startTime: start + w, endTime: start + 2 * w),
                LyricWord(word: "new ", startTime: start + 2 * w, endTime: start + 3 * w),
                LyricWord(word: "world", startTime: start + 3 * w, endTime: e),
            ]
        )
    }

    private func row(_ line: LyricLine, index: Int = 0) -> LayerBackedLyricRow {
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

    func test_inactivePlan_snapsSweepProgressToOne_soPauseMustKeepActive() {
        let line = wordLine()
        let mid = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: 1.5, isActive: true
        ))
        let inactive = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: 1.5, isActive: false
        ))
        XCTAssertLessThan(mid.mainSweepProgress, 0.9, "precondition: mid-line is a partial reveal")
        XCTAssertGreaterThan(mid.mainSweepProgress, 0.1)
        XCTAssertEqual(inactive.mainSweepProgress, 1, accuracy: 0.0001,
                       "the plan treats inactive as fully revealed — pause must not flip isActive")
        XCTAssertTrue(NativeLyricsTextActivation.isLineTextActive(rowIndex: 3, textActiveIndex: 3))
        XCTAssertFalse(NativeLyricsTextActivation.isLineTextActive(rowIndex: 3, textActiveIndex: 4))
    }

    @MainActor
    func test_pauseMidWord_freezesPartialSweep_doesNotPromoteWholeLine() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = (0..<4).map { i in row(wordLine(start: TimeInterval(i) * 4), index: i) }
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        let step = 1.0 / 60.0
        func tick(_ playback: TimeInterval, playing: Bool, current: Int) {
            wall += step
            date = date.addingTimeInterval(step)
            mc.isPlaying = playing
            mc.syncPlaybackClock(to: playback, playing: playing, at: date)
            surface.configure(config(rows, current: current, mc: mc))
            surface.debugTick(displayInterval: step)
            RunLoop.main.run(until: Date())
        }

        let mid = rows[0].displayLine.line.startTime + 1.5
        mc.syncPlaybackClock(to: mid - 0.3, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<24 {
            tick(mid - 0.3 + TimeInterval(i) * step, playing: true, current: 0)
        }

        guard let playingRow = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row 0 must be mounted while playing")
        }
        let progressBefore = playingRow.debugLastMainAppliedProgress ?? 0
        let compensationBefore = playingRow.debugDimCompensationActive
        XCTAssertGreaterThan(progressBefore, 0.15, "precondition: pause injects into a partial reveal")
        XCTAssertLessThan(progressBefore, 0.9, "precondition: not yet a finished line")
        XCTAssertTrue(compensationBefore, "precondition: karaoke dim-base compensation is on")
        XCTAssertFalse(playingRow.debugLastWholeLineHighlight)
        let baseOpacityBefore = playingRow.debugMainBaseLayerOpacity

        let frozen = mid - 0.3 + 23 * step
        for _ in 0..<30 {
            tick(frozen, playing: false, current: 0)
        }

        guard let pausedRow = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row 0 must stay mounted after pause")
        }
        let progressAfter = pausedRow.debugLastMainAppliedProgress ?? -1
        XCTAssertEqual(progressAfter, progressBefore, accuracy: 0.08,
                       "pause must freeze the word-level sweep, not jump it to 1")
        XCTAssertLessThan(progressAfter, 0.9, "pause must not promote a partial reveal to a full line")
        XCTAssertFalse(pausedRow.debugLastWholeLineHighlight,
                       "pause must not paint whole-line highlight")
        XCTAssertTrue(pausedRow.debugDimCompensationActive,
                       "dim-base compensation must stay armed so the unswept remainder does not jump to full bright")
        XCTAssertEqual(pausedRow.debugMainBaseLayerOpacity, baseOpacityBefore, accuracy: 0.08,
                       "unswept dim brightness must hold; jumping to 1.0 is 暂停变全行")
        XCTAssertTrue(NativeLyricsTextActivation.isLineTextActive(rowIndex: 0, textActiveIndex: 0),
                       "the singing line stays text-active while paused")
    }
}
