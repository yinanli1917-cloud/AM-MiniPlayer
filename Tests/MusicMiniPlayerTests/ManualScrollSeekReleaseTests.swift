import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Defect D fix (founder 2026-09-17, screenshot 3: progress bar 0:00/-5:03, ▶ paused, first REAL
// lyric line held the active slot/capsule while the prelude dots sat unstyled above it). Root
// cause: an EXTERNAL seek (progress bar) only bumps `MusicController.seekGeneration` — it never
// touches `NativeLyricsSurfaceView.manualScrollState`. If the seek lands while a manual-scroll
// gesture is still active, `playbackMode` computes `.directSnap(.manualScroll)` regardless (that
// check runs before `.natural` in `LyricsLayerRendererConfiguration.playbackMode`), and that
// branch anchors to `frozenDisplayIndex` (whichever row was playing when the gesture BEGAN) —
// the seek's real target time never gets a chance to resolve the active row.
//
// Fix: `synchronizeNativeSemanticIndex` now releases a still-active `manualScrollState` the
// instant it observes a NEW `seekGeneration`, before `playbackMode` is evaluated — so a real seek
// always wins and resolves through the same semantic path (amllState from real playback time)
// every other entry point uses.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class ManualScrollSeekReleaseTests: XCTestCase {

    private var hostWindow: NSWindow?
    @MainActor override func tearDown() { hostWindow?.orderOut(nil); hostWindow = nil; super.tearDown() }

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
    }

    private func row(for line: LyricLine, index: Int, isPrelude: Bool = false, preludeEndTime: TimeInterval = 0) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: isPrelude, preludeEndTime: preludeEndTime, interlude: nil
        )
    }

    /// Prelude [0, 12), then 3 real lines: row1 [12,16), row2 [17,26) (spans t=20 — "played to
    /// 20s"), row3 [27,31).
    private func preludeSongRows() -> [LayerBackedLyricRow] {
        let prelude = LyricLine(text: "…", startTime: 0, endTime: 12, words: [])
        var rows = [row(for: prelude, index: 0, isPrelude: true, preludeEndTime: 12)]
        let spans: [(TimeInterval, TimeInterval)] = [(12, 16), (17, 26), (27, 31)]
        for (i, s) in spans.enumerated() {
            rows.append(row(for: LyricLine(text: "line \(i + 1)", startTime: s.0, endTime: s.1), index: i + 1))
        }
        return rows
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat, anchorY: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: anchorY, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 40),
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

    /// Exact founder repro: play to 20s (row 2 is "current") -> manual-scroll freeze (simulating
    /// "scrolled back to the top") -> explicit seek to 0 + pause -> assert the prelude row is the
    /// real active row (semantic index 0, anchored at anchorY), not the frozen row.
    @MainActor
    func test_explicitSeekWhileManualScrollActive_releasesFrozenIndex_resolvesPreludeAsActive() {
        let rows = preludeSongRows()
        let panelWidth: CGFloat = 360
        let anchorY: CGFloat = 200
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 40
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 9_000
        var date = Date(timeIntervalSinceReferenceDate: 700_500_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        func tick(_ t: TimeInterval, playing: Bool, ticks: Int) {
            mc.syncPlaybackClock(to: t, playing: playing, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), rows.count - 1)
            surface.configure(config(rows: rows, current: current, mc: mc, width: panelWidth, anchorY: anchorY))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<ticks {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                mc.syncPlaybackClock(to: t, playing: playing, at: date)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
        }

        // Played to 20s (row 2's own [17,26) span — "played to 20s" per the founder's repro).
        tick(20.0, playing: true, ticks: 30)
        XCTAssertEqual(surface.debugNativeSemanticIndex, 2, "precondition: row 2 should be the real active row at t=20")

        // "Manually scrolled back to the top" — freeze at row 2 (the row that WAS playing),
        // matching what a real scroll gesture's begin() captures (effectiveScrollTargetIndex at
        // gesture start), and matches the founder's screenshot showing row 1 (not row 2) as
        // active — his repro likely started the gesture nearer row 1; either way the frozen row
        // must NOT survive the seek below, so the specific frozen value is not the point.
        surface.debugBeginManualScroll(frozenAt: 2)
        XCTAssertTrue(surface.debugManualScrollActive, "precondition: manual scroll must be active before the seek lands")
        tick(20.0, playing: true, ticks: 6)
        XCTAssertEqual(surface.debugNativeSemanticIndex, 2, "precondition: still frozen on row 2 while manual scroll is active, before the seek")

        // Explicit seek to 0 (progress bar) + pause — the founder's exact repro. This does NOT
        // go through handleNativeLineTap (that's only for taps inside the lyrics view), so it has
        // no built-in knowledge of manualScrollState — exactly the gap this fix closes.
        mc.registerSeek()
        tick(0.0, playing: false, ticks: 10)
        // Let the presentation spring fully settle to the snapped position (semantic-index
        // resolution is instant; the ROW GEOMETRY still springs into place).
        for _ in 0..<40 { tick(0.0, playing: false, ticks: 1) }

        XCTAssertFalse(surface.debugManualScrollActive, "an explicit seek must release a lingering manual-scroll freeze")
        XCTAssertEqual(surface.debugNativeSemanticIndex, 0,
                        "FIX: seeking to 0 (the prelude window) must resolve the prelude row as active, not the stale frozen row")

        guard let preludeView = surface.debugRowView(forIndex: 0) else {
            XCTFail("prelude row view should be mounted")
            return
        }
        XCTAssertEqual(preludeView.frame.origin.y, anchorY, accuracy: 1.0,
                        "FIX: the active prelude row must sit at the anchor slot, like any other active row")
        XCTAssertFalse(preludeView.debugPreludeDotContainerHidden, "the prelude dots must be visible once it is the real active row")

        guard let firstRealLineView = surface.debugRowView(forIndex: 1) else {
            XCTFail("row 1 view should be mounted")
            return
        }
        XCTAssertNotEqual(firstRealLineView.frame.origin.y, anchorY, accuracy: 1.0,
                           "row 1 (not currently singing) must NOT be sitting at the anchor slot")
    }
}
