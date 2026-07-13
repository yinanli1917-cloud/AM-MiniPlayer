//
//  NativeLyricsTapHitTests.swift
//
//  Repro net for the user report (2026-07-12): during manual scrolling, with the shared
//  controls faded OUT, clicking a lyric row in the bottom region (where the controls used
//  to be) does nothing. Row views return nil from hitTest, so ALL clicks funnel through
//  the surface's mouseDown — the single tap path, fully drivable headless.
//
//  Contract under test:
//    - controls HIDDEN → every mounted row is tappable, including rows inside the bottom
//      controls region (the reserved-zone guard is gated on controlsVisible).
//    - controls VISIBLE → clicks inside the bottom reserved zone pass through to the
//      controls (no row tap); clicks on rows OUTSIDE the zone still tap.
//    - both hold with manual-scroll state active (the user's failing scenario).
//

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

final class NativeLyricsTapHitTests: XCTestCase {

    private var hostWindow: NSWindow?
    override func tearDown() { hostWindow?.orderOut(nil); hostWindow = nil; super.tearDown() }

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

    private func makeRows(_ n: Int) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * 1.2, e = TimeInterval(i) * 1.2 + 1.2
            let line = LyricLine(text: "line \(i) words here", startTime: s, endTime: e)
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(
        _ rowList: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController,
        controlsVisible: Bool,
        onLineTap: @escaping (LyricLine) -> Void
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 150, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: controlsVisible, musicController: mc,
            onLineTap: onLineTap, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    @MainActor
    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
    }

    @MainActor
    private func click(_ surface: NativeLyricsSurfaceView, at point: CGPoint) {
        let windowPoint = surface.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hostWindow?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return XCTFail("could not synthesize mouse event") }
        surface.mouseDown(with: event)
        // onLineTap is dispatched via deferParentCallback (RunLoop.main.perform) — spin so
        // the deferred callback lands before the assertion.
        spin(0.1)
    }

    /// A mounted row whose frame lies (at least partly) inside the bottom controls region,
    /// plus a click point on it, derived from real on-screen geometry.
    @MainActor
    private func rowInsideBottomRegion(_ surface: NativeLyricsSurfaceView, rows: Int) -> (index: Int, point: CGPoint)? {
        let bottomTop = surface.bounds.height - 120
        for i in 0..<rows {
            guard let view = surface.debugRowView(forIndex: i), view.frame.height > 1 else { continue }
            let mid = CGPoint(x: view.frame.midX, y: view.frame.midY)
            if mid.y > bottomTop && mid.y < surface.bounds.height {
                return (i, mid)
            }
        }
        return nil
    }

    @MainActor
    private func makeSurface(controlsVisible: Bool, taps: @escaping (LyricLine) -> Void) -> NativeLyricsSurfaceView {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        mc.syncPlaybackClock(to: 2.0, playing: true)
        let rows = makeRows(20)
        surface.configure(config(rows, current: 1, mc: mc, controlsVisible: controlsVisible, onLineTap: taps))
        surface.layoutSubtreeIfNeeded()
        spin(0.2)
        return surface
    }

    // ── Controls hidden: every mounted row is tappable, bottom region included ──

    @MainActor
    func test_controlsHidden_rowInBottomRegion_taps() {
        var tapped: [String] = []
        let surface = makeSurface(controlsVisible: false) { tapped.append($0.text) }
        guard let target = rowInsideBottomRegion(surface, rows: 20) else {
            return XCTFail("no mounted row landed in the bottom controls region — fixture geometry broke")
        }
        click(surface, at: target.point)
        XCTAssertEqual(tapped.count, 1, "controls are hidden — a row in the old controls region must tap")
    }

    @MainActor
    func test_controlsHidden_manualScrollActive_rowInBottomRegion_taps() {
        var tapped: [String] = []
        let surface = makeSurface(controlsVisible: false) { tapped.append($0.text) }
        surface.debugBeginManualScroll()
        XCTAssertTrue(surface.debugManualScrollActive, "precondition: manual scroll engaged")
        guard let target = rowInsideBottomRegion(surface, rows: 20) else {
            return XCTFail("no mounted row landed in the bottom controls region — fixture geometry broke")
        }
        click(surface, at: target.point)
        XCTAssertEqual(tapped.count, 1,
                       "manual scroll + hidden controls — the user's failing scenario must tap")
    }

    // ── The user's ACTUAL failure: controls fade out, nothing else changes ─────

    /// Root cause of the live report: configureSignature omitted controlsVisible, so the
    /// reconfigure that carried "controls are now hidden" was deduped as a structural
    /// duplicate — the surface kept controlsVisible=true and the bottom reserved zone kept
    /// eating taps long after the controls visually faded (exactly the manual-scroll case,
    /// where no other signature field changes to flush the stale value through).
    @MainActor
    func test_controlsFadeOut_aloneReachesTheSurface_bottomRowTapsAgain() {
        var tapped: [String] = []
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        mc.syncPlaybackClock(to: 2.0, playing: true)
        let rows = makeRows(20)

        // Controls visible first (the state before the user scrolls the chrome away).
        surface.configure(config(rows, current: 1, mc: mc, controlsVisible: true) { tapped.append($0.text) })
        surface.layoutSubtreeIfNeeded()
        spin(0.2)
        // The ONLY change: controls fade out. Everything the old signature hashed is identical.
        surface.configure(config(rows, current: 1, mc: mc, controlsVisible: false) { tapped.append($0.text) })
        spin(0.05)

        guard let target = rowInsideBottomRegion(surface, rows: 20) else {
            return XCTFail("no mounted row landed in the bottom controls region — fixture geometry broke")
        }
        click(surface, at: target.point)
        XCTAssertEqual(tapped.count, 1,
                       "a controls-only fade-out must reach the surface — the bottom zone stops eating taps")
    }

    // ── Controls visible: the bottom zone belongs to the controls ──────────────

    @MainActor
    func test_controlsVisible_bottomZoneClick_passesThroughToControls() {
        var tapped: [String] = []
        let surface = makeSurface(controlsVisible: true) { tapped.append($0.text) }
        guard let target = rowInsideBottomRegion(surface, rows: 20) else {
            return XCTFail("no mounted row landed in the bottom controls region — fixture geometry broke")
        }
        click(surface, at: target.point)
        XCTAssertTrue(tapped.isEmpty, "visible controls own the bottom zone — no row tap underneath")
    }

    @MainActor
    func test_controlsVisible_rowAboveZone_stillTaps() {
        var tapped: [String] = []
        let surface = makeSurface(controlsVisible: true) { tapped.append($0.text) }
        let bottomTop = surface.bounds.height - 120
        var target: CGPoint?
        for i in 0..<20 {
            guard let view = surface.debugRowView(forIndex: i), view.frame.height > 1 else { continue }
            let mid = CGPoint(x: view.frame.midX, y: view.frame.midY)
            if mid.y > 60, mid.y < bottomTop - 20 {
                target = mid
                break
            }
        }
        guard let point = target else { return XCTFail("no mounted row above the controls zone") }
        click(surface, at: point)
        XCTAssertEqual(tapped.count, 1, "rows above the controls zone stay tappable while controls show")
    }
}
