import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// T2 bug #1 — "遮罩丢失" root-cause repro (granularity upgrade).
//
// The clean word-level handoff is proven race-free (NativeLyricsMaskHandoffTests). This exercises
// the OTHER path: LyricsService shows an initial LINE-LEVEL result immediately, then a granularity
// refetch (`shouldRefreshCachedLyricsForGranularity` = "cached, not no-lyrics, not unsynced, and NO
// line has syllable sync") returns WORD-LEVEL and re-publishes the whole lyrics array via
// applyLyrics → SwiftUI → surface.configure(newRows). This test reproduces that at the render level
// by configuring the surface with line-level rows, driving to mid-line, then reconfiguring with
// word-level rows of the SAME identity — and captures what the active line looks like before vs
// after the upgrade.
//
// Expected demonstration of the bug:
//   BEFORE upgrade (line-level active) : per-word mask absent (perRunSweep=false, bright overlay
//     hidden) — the whole line reads uniform, no karaoke wavefront. This IS "逐字遮罩完全没了".
//   AFTER upgrade (word-level active)  : per-word sweep engages, and because the upgrade lands
//     mid-line the wavefront jumps straight to the current position — "行进到一半又突然恢复正常".
// The window the user sees = granularity-refetch latency (network-bound, capped 9s), NOT a fixed
// frame count.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsGranularityUpgradeTests: XCTestCase {

    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        hostedSurfaces.forEach { $0.stopAnimations() }
        hostedSurfaces.removeAll()
        hostWindow?.orderOut(nil); hostWindow = nil
        super.tearDown()
    }

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.alphaValue = 0; w.contentView = view; w.orderFrontRegardless()
        hostWindow = w
        if let s = view as? NativeLyricsSurfaceView { hostedSurfaces.append(s) }
    }

    private func rows(_ n: Int, wordLevel: Bool) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * 3.2, e = s + 3.2
            let text = "line \(i) has four words"
            let words: [LyricWord]
            if wordLevel {
                let w = (e - s) / 4
                words = [
                    LyricWord(word: "line ", startTime: s, endTime: s + w),
                    LyricWord(word: "\(i) ", startTime: s + w, endTime: s + 2 * w),
                    LyricWord(word: "has four ", startTime: s + 2 * w, endTime: s + 3 * w),
                    LyricWord(word: "words", startTime: s + 3 * w, endTime: e),
                ]
            } else {
                words = []
            }
            let line = LyricLine(text: text, startTime: s, endTime: e, words: words)
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(_ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController, wordLevel: Bool) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: wordLevel,
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

    @MainActor
    func test_lineLevelThenWordLevelUpgrade_activeLineFlipsFromNoMaskToMidLineSweep() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240; mc.isPlaying = true
        surface.debugSkipDedupe = true

        let lineLevel = rows(20, wordLevel: false)
        let wordLevel = rows(20, wordLevel: true)
        let activeIndex = 5
        let lineStart = lineLevel[activeIndex].displayLine.line.startTime

        var wall: CFTimeInterval = 3_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        let step = 1.0 / 60.0
        func tick(_ playback: TimeInterval, _ rowsArg: [LayerBackedLyricRow], _ wl: Bool) {
            wall += step; date = date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rowsArg, current: surface.debugNativeSemanticIndex ?? 0, mc: mc, wordLevel: wl))
            surface.debugTick(displayInterval: step)
            RunLoop.main.run(until: Date())
        }

        // Phase 1: LINE-LEVEL lyrics shown. Drive to ~1.6 s into line 5 (mid-line).
        let start = lineStart + 0.1
        mc.syncPlaybackClock(to: start, playing: true, at: date)
        surface.configure(config(lineLevel, current: activeIndex, mc: mc, wordLevel: false))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<96 { tick(start + TimeInterval(i) * step, lineLevel, false) }

        let beforeRow = surface.debugRowView(forIndex: activeIndex)
        let beforePerRun = beforeRow?.debugLastAppliedActivePerRunSweep ?? true
        let beforeBrightOverlay = beforeRow?.debugMainBrightOverlayActive ?? false
        let beforeExpected = beforeRow?.debugLastMainExpectedProgress ?? -1
        let beforeApplied = beforeRow?.debugLastMainAppliedProgress ?? -1
        let midLinePlayback = start + 96 * step  // ~1.7 s into the 3.2 s line

        // Phase 2: WORD-LEVEL upgrade re-published (applyLyrics → configure with new rows), SAME
        // identity, WHILE line 5 is active mid-line. Drive a few frames to let it engage.
        var afterPerRun = false
        var afterApplied: CGFloat = -1
        var afterExpected: CGFloat = -1
        var firstEngageFrame = -1
        for i in 0..<12 {
            tick(midLinePlayback + TimeInterval(i) * step, wordLevel, true)
            if let r = surface.debugRowView(forIndex: activeIndex) {
                if r.debugLastAppliedActivePerRunSweep && firstEngageFrame < 0 { firstEngageFrame = i }
                afterPerRun = r.debugLastAppliedActivePerRunSweep
                afterApplied = r.debugLastMainAppliedProgress ?? -1
                afterExpected = r.debugLastMainExpectedProgress ?? -1
            }
        }

        print(String(format:
            "[GranularityUpgrade] active=%d lineStart=%.2f midLinePlayback=%.2f\n" +
            "  BEFORE (line-level): perRunSweep=%@ brightOverlayActive=%@ expected=%.3f applied=%.3f\n" +
            "  AFTER  (word-level): perRunSweep=%@ expected=%.3f applied=%.3f firstEngageFrame=%d",
            activeIndex, lineStart, midLinePlayback,
            beforePerRun ? "Y":"n", beforeBrightOverlay ? "Y":"n", beforeExpected, beforeApplied,
            afterPerRun ? "Y":"n", afterExpected, afterApplied, firstEngageFrame))

        // The bug demonstrated: BEFORE the upgrade, a word-timed song's line was showing with NO
        // per-word mask (line-level path) — the "遮罩丢失" state.
        XCTAssertFalse(beforePerRun, "line-level phase must render WITHOUT the per-word sweep (mask absent)")
        XCTAssertFalse(beforeBrightOverlay, "line-level active line shows no karaoke bright overlay (uniform, no wavefront)")
        // AFTER the upgrade, per-word sweep engages, and because it landed mid-line the wavefront is
        // already ~mid-line (a jump from the uniform look) — "行进到一半又恢复".
        XCTAssertTrue(afterPerRun, "word-level upgrade must engage the per-word sweep")
        XCTAssertGreaterThan(afterExpected, 0.35,
            "the upgrade landed mid-line, so the sweep engages at a mid-line wavefront (the visible 'jump to half')")
        XCTAssertEqual(afterApplied, afterExpected, accuracy: 0.05,
            "once engaged, the word-level sweep tracks the model (the recovered, correct state)")
    }
}
