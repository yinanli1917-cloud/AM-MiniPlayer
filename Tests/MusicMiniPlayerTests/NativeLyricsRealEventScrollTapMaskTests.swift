import XCTest
import AppKit
import CoreGraphics
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Stage bundle 3j (research/repro-2026-09-18-lyrics-render-3j.md): founder's real operating
// path is HIS OWN lyrics page — manual trackpad scroll back to an already-sung line, then a
// click on some row to jump there, repeated rapidly, more often under load. Every earlier
// repro (3f fuzz, 3i item 4 (a)-(d)) drove this through TEST SEAMS
// (`debugBeginManualScroll`/`debugTapLine`) because the codebase's own comments assert real
// phase-tagged NSScrollWheel events "cannot be fabricated headlessly". That premise is false:
// CGEvent(scrollWheelEvent2Source:) exposes `.scrollWheelEventScrollPhase` /
// `.scrollWheelEventMomentumPhase` as ordinary integer fields (99 / 123), and
// `NSEvent(cgEvent:)` decodes them into `.phase` / `.momentumPhase` correctly (verified with a
// standalone script before writing this file). This test file drives the PRODUCTION
// `scrollWheel(with:)` / `mouseDown(with:)` overrides on `NativeLyricsSurfaceView` with events
// built this way — no seam, no debug-only entry point — closing the gap the founder flagged.
//
// Real-machine evidence (/tmp/nanopod_debug.log, 14:57:14): a manual-scroll START frame showed
// `anchor=-26.0` instead of the steady-state 42, right before a tap-to-line landing. The
// candidate mechanism: `interludeAnchorAdvance` (LyricsLayerRendererView.swift ~1213) shifts
// `anchorY` whenever an interlude is active AND the real playback clock is inside its window —
// it reads the LIVE clock, not the manual-scroll-frozen index, so it can keep moving anchorY
// while the user is mid-gesture. `test_interludeAnchorAdvance_doesNotJumpAcrossManualScrollStart`
// below pins that the transition into manual-scroll must not itself introduce a discontinuity
// beyond what the interlude's own continuous ramp already explains.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsRealEventScrollTapMaskTests: XCTestCase {
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
    private func host(_ view: NSView, _ size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        if let surface = view as? NativeLyricsSurfaceView { hostedSurfaces.append(surface) }
        return w
    }

    // MARK: - Fixtures

    /// Word-level (逐字) rows, 4 words each. Row `interludeAt` (if given) carries a
    /// `LayerBackedLyricInterlude` spanning [end of that row, start of next row + 6s] so the
    /// warm-up clock can land inside a real interlude window.
    private func makeWordLevelRows(_ n: Int, duration: TimeInterval = 3.2, interludeAt: Int? = nil) -> [LayerBackedLyricRow] {
        var gapAfter: Set<Int> = []
        if let interludeAt { gapAfter.insert(interludeAt) }
        var rows: [LayerBackedLyricRow] = []
        var cursor: TimeInterval = 0
        for i in 0..<n {
            let s = cursor, e = s + duration
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
            let interlude: LayerBackedLyricInterlude? = gapAfter.contains(i)
                ? LayerBackedLyricInterlude(startTime: e, endTime: e + 6.0) : nil
            rows.append(LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                             isPrelude: false, preludeEndTime: 0, interlude: interlude))
            cursor = e + (gapAfter.contains(i) ? 6.0 : 0)
        }
        return rows
    }

    /// Line-level (整行/unsynced-style single run) CJK rows — no word timestamps beyond the
    /// single run, folding tested via a long line so it wraps at the configured `rowWidth`.
    private func makeCJKLineLevelRows(_ n: Int, duration: TimeInterval = 3.2) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * duration, e = s + duration
            let text = "第\(i)行歌词很长会自动换行测试折行场景不截断"
            let line = LyricLine(
                text: text, startTime: s, endTime: e,
                words: [LyricWord(word: text, startTime: s, endTime: e)]
            )
            let dl = DisplayLyricLine(id: "c\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                        isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(
        _ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController,
        interludeAfterIndex: Int? = nil, rowWidth: CGFloat = 320
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: rowWidth,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: interludeAfterIndex,
            directSnapRequest: nil,
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

    private func isLandingFrameAcceptable(row: NativeLyricsRowView) -> Bool {
        guard let expected = row.debugLastMainExpectedProgress else { return true }
        if !isMaskLost(row: row, expected: expected) { return true }
        return false
    }

    private final class Clocks {
        var wall: CFTimeInterval
        var date: Date
        init(wall: CFTimeInterval, date: Date) { self.wall = wall; self.date = date }
    }

    @MainActor
    private func makeHarness(
        rowCount: Int = 12, interludeAt: Int? = nil, cjk: Bool = false, width: CGFloat = 320
    ) -> (surface: NativeLyricsSurfaceView, window: NSWindow, mc: MusicController, rows: [LayerBackedLyricRow], clocks: Clocks) {
        let size = NSSize(width: width, height: 600)
        let surface = NativeLyricsSurfaceView(frame: NSRect(origin: .zero, size: size))
        let window = host(surface, size)
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = cjk ? makeCJKLineLevelRows(rowCount) : makeWordLevelRows(rowCount, interludeAt: interludeAt)
        surface.debugSkipDedupe = true
        let clocks = Clocks(wall: 6_000, date: Date(timeIntervalSinceReferenceDate: 950_000_000))
        return (surface, window, mc, rows, clocks)
    }

    @MainActor
    private func warmUp(
        surface: NativeLyricsSurfaceView, mc: MusicController, rows: [LayerBackedLyricRow],
        clocks: Clocks, toTime: TimeInterval, currentIndex: Int, ticks: Int, step: TimeInterval = 1.0 / 60.0,
        interludeAfterIndex: Int? = nil, width: CGFloat = 320
    ) {
        surface.debugNowOverride = { clocks.wall }
        mc.debugPlaybackClockDateProvider = { clocks.date }
        mc.syncPlaybackClock(to: toTime, playing: mc.isPlaying, at: clocks.date)
        surface.configure(config(rows, current: currentIndex, mc: mc, interludeAfterIndex: interludeAfterIndex, rowWidth: width))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<ticks {
            clocks.wall += step
            clocks.date = clocks.date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: toTime, playing: mc.isPlaying, at: clocks.date)
            surface.debugTick(displayInterval: step)
        }
    }

    // MARK: - Real-event senders

    /// Builds a real, phase-tagged scroll-wheel `NSEvent` via `CGEvent(scrollWheelEvent2Source:)`
    /// and delivers it straight into the production `scrollWheel(with:)` override — the same
    /// entry point AppKit itself calls for a genuine trackpad gesture.
    @MainActor
    private func sendRealScroll(
        surface: NativeLyricsSurfaceView, window: NSWindow, deltaY: CGFloat,
        phase: NSEvent.Phase, momentumPhase: NSEvent.Phase = []
    ) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                                wheel1: Int32(deltaY), wheel2: 0, wheel3: 0) else {
            XCTFail("failed to synthesize CGEvent scroll wheel event"); return
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))
        // Sub-pixel precision so scrollingDeltaY is not rounded away for small deltas.
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(deltaY))
        // CGEvent.location is a QUARTZ GLOBAL DISPLAY point (origin top-left, y down). Convert the
        // surface's own center through window-space (Cocoa, bottom-left origin) → the window's
        // screen frame (Cocoa global, bottom-left origin) → flip to Quartz.
        let centerInSurface = NSPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        let centerInWindow = surface.convert(centerInSurface, to: nil)
        let centerOnScreenCocoa = window.convertPoint(toScreen: centerInWindow)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? centerOnScreenCocoa.y
        cg.location = CGPoint(x: centerOnScreenCocoa.x, y: mainScreenHeight - centerOnScreenCocoa.y)
        guard let nsEvent = NSEvent(cgEvent: cg) else {
            XCTFail("CGEvent did not decode into an NSEvent"); return
        }
        surface.scrollWheel(with: nsEvent)
    }

    /// Real left-mouse-down/up pair at the CENTER of the given row's currently-mounted frame,
    /// delivered into the production `mouseDown(with:)` override — exercises the real hit-test
    /// path (`handleNativeMouseDown` → `rowHitFrame` → `rowTapHandlers`), not the `debugTapLine`
    /// seam.
    @MainActor
    private func sendRealClick(surface: NativeLyricsSurfaceView, window: NSWindow, rowIndex: Int) -> Bool {
        guard let row = surface.debugRowView(forIndex: rowIndex) else { return false }
        let centerInSurface = NSPoint(x: row.frame.midX, y: row.frame.midY)
        let centerInWindow = surface.convert(centerInSurface, to: nil)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: centerInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
        ) else { return false }
        surface.mouseDown(with: down)
        guard let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: centerInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ) else { return false }
        surface.mouseUp(with: up)
        return true
    }

    /// Drives a real multi-tick scroll-back gesture (began, then N changed ticks, each a real
    /// CGEvent) moving `lines` rows' worth of content, returns after the gesture has established
    /// manual-scroll ownership. Caller decides what happens next (tap now / after ended / during
    /// momentum).
    @MainActor
    private func performRealScrollBackGesture(
        surface: NativeLyricsSurfaceView, window: NSWindow, clocks: Clocks,
        rowHeight: CGFloat = 56, lines: Int = 5, step: TimeInterval = 1.0 / 60.0
    ) {
        let totalDelta = rowHeight * CGFloat(lines)
        let ticks = 10
        let perTick = totalDelta / CGFloat(ticks)
        for i in 0..<ticks {
            let phase: NSEvent.Phase = i == 0 ? .began : .changed
            sendRealScroll(surface: surface, window: window, deltaY: perTick, phase: phase)
            clocks.wall += step
            clocks.date = clocks.date.addingTimeInterval(step)
            surface.debugTick(displayInterval: step)
        }
    }

    // MARK: - Scenario matrix: real scroll-back + real tap, 3 landing timings

    private enum TapTiming: String, CaseIterable {
        case duringGestureChanged
        case afterEndedWithinGrace
        case duringMomentum
    }

    @MainActor
    @discardableResult
    private func runScrollThenTapScenario(
        cjk: Bool, timing: TapTiming, step: TimeInterval, lineIndex: Int, frac: Double,
        label: String
    ) -> (ran: Bool, violation: Bool) {
        let (surface, window, mc, rows, clocks) = makeHarness(rowCount: 14, cjk: cjk)
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }
        let warmIndex = max(0, lineIndex - 2)
        warmUp(surface: surface, mc: mc, rows: rows, clocks: clocks,
               toTime: rows[warmIndex].displayLine.line.startTime + 0.2, currentIndex: warmIndex,
               ticks: 15, step: step)

        performRealScrollBackGesture(surface: surface, window: window, clocks: clocks, lines: 4, step: step)
        guard surface.debugManualScrollActive else {
            XCTFail("[\(label)] real scroll gesture never established manual-scroll ownership")
            return (false, false)
        }

        switch timing {
        case .duringGestureChanged:
            // Tap mid-gesture: one more `changed` delta lands right before the click, mirroring
            // a user who taps without lifting the scroll fully.
            sendRealScroll(surface: surface, window: window, deltaY: 4, phase: .changed)
        case .afterEndedWithinGrace:
            sendRealScroll(surface: surface, window: window, deltaY: 0, phase: .ended)
            // Inside the 2s scheduleNativeScrollEnd grace window (real Timer-driven; we do not
            // let the RunLoop actually fire it — the founder's path is a tap that lands BEFORE
            // the 2s/0.1s recovery timers elapse).
            clocks.wall += 0.3
            clocks.date = clocks.date.addingTimeInterval(0.3)
        case .duringMomentum:
            sendRealScroll(surface: surface, window: window, deltaY: 0, phase: .ended)
            sendRealScroll(surface: surface, window: window, deltaY: 3, phase: [], momentumPhase: .began)
            sendRealScroll(surface: surface, window: window, deltaY: 2, phase: [], momentumPhase: .changed)
        }

        let line = rows[lineIndex].displayLine.line
        let tapTime = line.startTime + (line.endTime - line.startTime) * frac
        mc.syncPlaybackClock(to: tapTime, playing: mc.isPlaying, at: clocks.date)
        // The row must be mounted (reconciled into view) before a real click can hit it —
        // reconcile happens as part of the scroll gesture's own tick loop above, but the target
        // row may sit outside the manually-scrolled viewport; nudge one more real tick so the
        // renderer has a chance to mount rows near the (still frozen) manual-scroll viewport.
        guard sendRealClick(surface: surface, window: window, rowIndex: lineIndex) else {
            // Row not mounted / not hit — record as a coverage gap, not a pass, and report it in
            // the matrix rather than silently skipping.
            return (false, false)
        }

        let step2 = 1.0 / 60.0
        clocks.wall += step2
        clocks.date = clocks.date.addingTimeInterval(step2)
        surface.debugTick(displayInterval: step2)

        guard let landed = surface.debugRowView(forIndex: lineIndex) else {
            return (false, false)
        }
        let acceptable = isLandingFrameAcceptable(row: landed)
        if !acceptable {
            print("[RealEventMask] VIOLATION \(label) timing=\(timing.rawValue) step=\(step) line=\(lineIndex) frac=\(frac) "
                + "cjk=\(cjk) expected=\(landed.debugLastMainExpectedProgress ?? -1) "
                + "brightOpacity=\(landed.debugMainBrightOpacity) "
                + "perRunSweep=\(landed.debugLastAppliedActivePerRunSweep) "
                + "wholeLineHighlight=\(landed.debugLastWholeLineHighlight)")
        }
        return (true, !acceptable)
    }

    @MainActor
    func test_realScrollBackThenRealTap_matrix_noLandingFrameIsBrightAndUnmasked() {
        var violations = 0
        var ran = 0
        var skipped = 0
        var total = 0
        let steps: [TimeInterval] = [1.0 / 60.0, 0.1, 0.25, 0.5]
        for cjk in [false, true] {
            for timing in TapTiming.allCases {
                for step in steps {
                    for lineIndex in [4, 7, 10] {
                        for frac in [0.3, 0.6, 0.9] {
                            total += 1
                            let label = "cjk=\(cjk)"
                            let (didRun, violated) = runScrollThenTapScenario(
                                cjk: cjk, timing: timing, step: step, lineIndex: lineIndex, frac: frac, label: label
                            )
                            if didRun { ran += 1 } else { skipped += 1 }
                            if violated { violations += 1 }
                        }
                    }
                }
            }
        }
        print("[RealEventMask] matrix total=\(total) ran=\(ran) skipped=\(skipped) violations=\(violations)")
        XCTAssertGreaterThan(ran, 0, "real-event matrix never produced a single landed, hit-testable frame — harness broken")
        XCTAssertEqual(violations, 0, "\(violations)/\(ran) real scroll-back-then-tap landing frames were bright-and-unmasked (\(skipped) skipped: row not mounted/hit)")
    }

    // MARK: - Repeated rapid scroll-back + tap, 5x within <1s (founder: "高频重复这个动作")

    @MainActor
    func test_repeatedRealScrollBackThenTap_fiveTimesUnderOneSecond_noLandingFrameIsBrightAndUnmasked() {
        let (surface, window, mc, rows, clocks) = makeHarness(rowCount: 20)
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }
        warmUp(surface: surface, mc: mc, rows: rows, clocks: clocks,
               toTime: rows[2].displayLine.line.startTime + 0.2, currentIndex: 2, ticks: 15)

        var violations = 0
        var ran = 0
        let targets: [(line: Int, frac: Double)] = [(6, 0.5), (9, 0.7), (4, 0.4), (11, 0.6), (7, 0.3)]
        for (lineIndex, frac) in targets {
            performRealScrollBackGesture(surface: surface, window: window, clocks: clocks, lines: 3)
            sendRealScroll(surface: surface, window: window, deltaY: 0, phase: .ended)
            let line = rows[lineIndex].displayLine.line
            let tapTime = line.startTime + (line.endTime - line.startTime) * frac
            mc.syncPlaybackClock(to: tapTime, playing: mc.isPlaying, at: clocks.date)
            if sendRealClick(surface: surface, window: window, rowIndex: lineIndex) {
                ran += 1
                let step = 1.0 / 60.0
                clocks.wall += step
                clocks.date = clocks.date.addingTimeInterval(step)
                surface.debugTick(displayInterval: step)
                if let landed = surface.debugRowView(forIndex: lineIndex), !isLandingFrameAcceptable(row: landed) {
                    violations += 1
                    print("[RealEventMask] RAPID-REPEAT VIOLATION line=\(lineIndex) frac=\(frac) "
                        + "expected=\(landed.debugLastMainExpectedProgress ?? -1) "
                        + "brightOpacity=\(landed.debugMainBrightOpacity)")
                }
            }
            // < 1s between repeats total (well under, matching the founder's "高频重复").
            clocks.wall += 0.12
            clocks.date = clocks.date.addingTimeInterval(0.12)
        }
        XCTAssertGreaterThan(ran, 0, "rapid-repeat harness never landed a hit-testable frame")
        XCTAssertEqual(violations, 0, "\(violations)/\(ran) rapid repeated scroll-back-then-tap landings were bright-and-unmasked")
    }

    // MARK: - Scroll far, then tap a row never mounted before the gesture (closest analog to the
    // founder's real path: scroll back several lines, tap somewhere the renderer hasn't drawn in
    // a while, forcing a first-mount-under-real-events dequeue+configure+tap all in one window).

    @MainActor
    func test_realScrollFarThenTapNeverMountedRow_noLandingFrameIsBrightAndUnmasked() {
        var violations = 0
        var ran = 0
        var skipped = 0
        var firstMountCases = 0
        let targets: [Int] = [0, 1, 2, 16, 17, 18]
        for lineIndex in targets {
            let (surface, window, mc, rows, clocks) = makeHarness(rowCount: 20)
            defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }
            // Warm up deep in the middle so both ends of the row list are far outside the
            // natural render radius and have never been mounted.
            warmUp(surface: surface, mc: mc, rows: rows, clocks: clocks,
                   toTime: rows[9].displayLine.line.startTime + 0.2, currentIndex: 9, ticks: 20)
            let wasMountedBeforeGesture = surface.debugRowView(forIndex: lineIndex) != nil
            if !wasMountedBeforeGesture { firstMountCases += 1 }

            // A long real scroll-back gesture — many changed ticks — walking toward the target.
            let direction: CGFloat = lineIndex < 9 ? 1 : -1
            let ticks = 40
            for i in 0..<ticks {
                let phase: NSEvent.Phase = i == 0 ? .began : .changed
                sendRealScroll(surface: surface, window: window, deltaY: direction * 14, phase: phase)
                clocks.wall += 1.0 / 60.0
                clocks.date = clocks.date.addingTimeInterval(1.0 / 60.0)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
            sendRealScroll(surface: surface, window: window, deltaY: 0, phase: .ended)

            let line = rows[lineIndex].displayLine.line
            let tapTime = line.startTime + (line.endTime - line.startTime) * 0.6
            mc.syncPlaybackClock(to: tapTime, playing: mc.isPlaying, at: clocks.date)
            guard sendRealClick(surface: surface, window: window, rowIndex: lineIndex) else {
                skipped += 1
                continue
            }
            ran += 1
            let step = 1.0 / 60.0
            clocks.wall += step
            clocks.date = clocks.date.addingTimeInterval(step)
            surface.debugTick(displayInterval: step)
            if let landed = surface.debugRowView(forIndex: lineIndex), !isLandingFrameAcceptable(row: landed) {
                violations += 1
                print("[RealEventMask] FAR-SCROLL-NEVER-MOUNTED VIOLATION line=\(lineIndex) "
                    + "wasMountedBeforeGesture=\(wasMountedBeforeGesture) "
                    + "expected=\(landed.debugLastMainExpectedProgress ?? -1) "
                    + "brightOpacity=\(landed.debugMainBrightOpacity)")
            }
        }
        print("[RealEventMask] far-scroll never-mounted-before-gesture cases: \(firstMountCases)/\(targets.count), ran=\(ran) skipped=\(skipped)")
        XCTAssertGreaterThan(ran, 0, "far-scroll-then-tap harness never landed a hit-testable frame")
        XCTAssertEqual(violations, 0, "\(violations)/\(ran) far-scroll-then-tap-on-never-mounted-row landings were bright-and-unmasked")
    }

    // MARK: - Anchor discontinuity at manual-scroll start while an interlude is live
    //
    // Real-machine evidence: manualStart frame showed anchor=-26 instead of the steady-state 42.
    // `interludeAnchorAdvance` reads the LIVE playback clock, independent of manual-scroll state,
    // so it can keep ramping while a gesture starts. This pins that the row Y the viewer actually
    // sees does not jump discontinuously at the instant manual-scroll begins — the interlude's
    // own continuous ramp is allowed to keep moving, but manual-scroll's OWN transition must not
    // add a second, separate jump on top of it.

    @MainActor
    func test_interludeAnchorAdvance_doesNotJumpAcrossManualScrollStart() {
        let (surface, window, mc, rows, clocks) = makeHarness(rowCount: 10, interludeAt: 4)
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        // Land the playback clock inside the interlude window (row 4 ends, interlude runs 6s),
        // partway through the ramp so `interludeBlend` is neither 0 nor 1.
        let interludeStart = rows[4].displayLine.line.endTime
        let midInterlude = interludeStart + 2.0 // interludeBlendDelay/duration make ~2s comfortably mid-ramp
        warmUp(surface: surface, mc: mc, rows: rows, clocks: clocks,
               toTime: midInterlude, currentIndex: 4, ticks: 30, interludeAfterIndex: 4)

        guard let steadyStateRow = surface.debugRowView(forIndex: 4) else {
            XCTFail("row 4 not mounted before manual scroll"); return
        }
        let steadyY = steadyStateRow.frame.midY

        // Begin a REAL scroll gesture with a TINY first delta (the actual manual-scroll-start
        // frame, before any meaningful scroll offset has accumulated) — isolates the anchor
        // transition from the scroll offset itself.
        sendRealScroll(surface: surface, window: window, deltaY: 1, phase: .began)
        clocks.wall += 1.0 / 60.0
        clocks.date = clocks.date.addingTimeInterval(1.0 / 60.0)
        surface.debugTick(displayInterval: 1.0 / 60.0)

        XCTAssertTrue(surface.debugManualScrollActive, "precondition: real scroll must have started manual-scroll ownership")
        guard let manualStartRow = surface.debugRowView(forIndex: 4) else {
            XCTFail("row 4 not mounted at manual-scroll start"); return
        }
        let manualStartY = manualStartRow.frame.midY

        // The playback clock advanced by exactly one tick (1/60s) between the two samples, so
        // the interlude ramp itself can only have moved a small, continuous amount — plus the 1pt
        // scroll delta we injected. A jump anywhere near the 26pt scale of the founder's evidence
        // (or larger) is the discontinuity under test; a few points of continuous ramp + the 1pt
        // scroll delta is expected and NOT a violation.
        let delta = abs(manualStartY - steadyY)
        XCTAssertLessThan(delta, 6.0,
            "row 4's Y jumped \(delta)pt across manual-scroll start while an interlude was live "
            + "(steadyY=\(steadyY), manualStartY=\(manualStartY)) — matches the founder's anchor=-26 vs 42 evidence shape")
    }
}
