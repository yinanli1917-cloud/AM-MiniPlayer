//
//  NativeLyricsFramePositioningTests.swift
//
//  Pins the fix for the seek/scroll bloom. Row Y is carried by the view FRAME, not a layer
//  transform: AppKit's commit-time layout resets a layer-backed view's transform to the identity
//  (dropping the row to the origin for a frame), but it preserves the view's frame. Before the fix,
//  the instant `configure` returned after a seek every mounted row sat at ty=0 (stacked at the top
//  = the bloom); the display loop only corrected it a tick later, and under SwiftUI's reconfigure
//  storm it persisted. This test seeks far and asserts that the rows are already spread to their
//  frame positions the moment `configure` returns — no display tick, no loop, no origin pile.
//

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

final class NativeLyricsFramePositioningTests: XCTestCase {

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    @MainActor
    private func hostInWindow(_ view: NSView, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
    }

    @MainActor
    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
    }

    private func songRows(count: Int) -> [LayerBackedLyricRow] {
        (0..<count).map { i in
            let line = LyricLine(text: "Lyric line number \(i) for positioning",
                                 startTime: TimeInterval(i * 4), endTime: TimeInterval(i * 4 + 4))
            let displayLine = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: displayLine.id, index: i, displayLine: displayLine,
                                       sourceLine: line, isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(
        rows: [LayerBackedLyricRow],
        currentIndex: Int,
        musicController: MusicController? = nil
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = CGFloat(r.index) * 56 }
        let controller = musicController ?? MusicController(preview: true)
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: currentIndex, anchorY: 250, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: controller,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    @MainActor
    func test_seekPositionsRowsByFrameImmediately_noOriginPile() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let rows = songRows(count: 40)
        surface.configure(config(rows: rows, currentIndex: 5))
        surface.layoutSubtreeIfNeeded()
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0)) }

        // Seek far. Read frame positions the INSTANT configure returns — no runloop, no display tick.
        surface.configure(config(rows: rows, currentIndex: 30))

        var frameYs: [CGFloat] = []
        for idx in 0..<40 {
            if let v = surface.debugRowView(forIndex: idx) { frameYs.append(v.frame.origin.y) }
        }
        XCTAssertGreaterThan(frameYs.count, 10, "rows mounted around the seek target")

        let spread = (frameYs.max() ?? 0) - (frameYs.min() ?? 0)
        XCTAssertGreaterThan(spread, 300, "rows are spread to their frame positions, not piled at the origin")

        let nearOrigin = frameYs.filter { abs($0) < 20 }.count
        XCTAssertLessThan(nearOrigin, 3, "rows are not stacked at ty≈0 (the bloom signature)")

        if let active = surface.debugRowView(forIndex: 30) {
            XCTAssertEqual(active.frame.origin.y, 250, accuracy: 40, "the seeked-to active line sits at the anchor")
        }
    }

    @MainActor
    func test_reenteringNaturalRowKeepsYHistoryAcrossUnmount() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface, size: NSSize(width: 360, height: 600))
        let rows = songRows(count: 60)
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true

        mc.syncPlaybackClock(to: rows[10].displayLine.line.startTime + 0.5, playing: true)
        surface.configure(config(rows: rows, currentIndex: 10, musicController: mc))
        surface.layoutSubtreeIfNeeded()
        spin(0.9)
        guard let initial = surface.debugRowView(forIndex: 0)?.frame.origin.y else {
            return XCTFail("row 0 should mount near the first viewport")
        }

        mc.syncPlaybackClock(to: rows[40].displayLine.line.startTime + 0.5, playing: true)
        surface.configure(config(rows: rows, currentIndex: 40, musicController: mc))
        surface.layoutSubtreeIfNeeded()
        XCTAssertNil(surface.debugRowView(forIndex: 0), "row 0 should be culled before the re-entry check")

        mc.syncPlaybackClock(to: rows[12].displayLine.line.startTime + 0.5, playing: true)
        surface.configure(config(rows: rows, currentIndex: 12, musicController: mc))
        surface.layoutSubtreeIfNeeded()
        guard let reentered = surface.debugRowView(forIndex: 0)?.frame.origin.y else {
            return XCTFail("row 0 should re-enter near current index 12")
        }

        let targetWithoutHistory = CGFloat(250 - 12 * 56)
        XCTAssertLessThan(
            abs(reentered - initial),
            abs(targetWithoutHistory - initial),
            "a re-entering natural row should step from its last applied Y, not jump directly to the new snapped target"
        )
    }
}
