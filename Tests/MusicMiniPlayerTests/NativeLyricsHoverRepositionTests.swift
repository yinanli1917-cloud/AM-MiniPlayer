import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Headless HOVER gate — the "hover background stuck after the row moved away" bug.
//
// The surface is meant to be the SINGLE hover authority: it hit-tests the cursor against each row's
// real on-screen frame and drives that row's hover background. Two failures hide here:
//   1) The hit-test read the layer's transform ty for a row's Y — but rows are positioned by FRAME
//      origin (transform carries scale only), so ty ≈ 0 and every row resolved at y≈0 → the geometry
//      hover path was dead; only the per-row tracking area highlighted anything.
//   2) A per-row tracking area can fire mouseEntered but NOT mouseExited when the row slides out from
//      under a stationary cursor (line-advance / scroll move the frame, the mouse does not) → the
//      hover background sticks on a line the cursor no longer covers.
//
// This drives the REAL surface headlessly: hover a row, then ADVANCE lines so that row moves out from
// under the (stationary) cursor, and assert the hover follows the geometry — the vacated row clears,
// the row now under the cursor lights up.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsHoverRepositionTests: XCTestCase {

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
            let d = (e - s) / 3
            let line = LyricLine(
                text: "line \(i) words here", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "line ", startTime: s, endTime: s + d),
                    LyricWord(word: "\(i) ", startTime: s + d, endTime: s + 2 * d),
                    LyricWord(word: "words here", startTime: s + 2 * d, endTime: e),
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

    @MainActor
    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
    }

    /// Mounted rows (index → frame) after a settle — the real on-screen geometry the cursor sees.
    @MainActor
    private func mountedFrames(_ surface: NativeLyricsSurfaceView, count: Int) -> [(Int, CGRect)] {
        (0..<count).compactMap { i in surface.debugRowView(forIndex: i).map { (i, $0.frame) } }
    }

    @MainActor
    func test_hoverFollowsGeometry_whenRowSlidesOutFromUnderStationaryCursor() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(20)

        mc.syncPlaybackClock(to: 0.6, playing: true)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        spin(0.8) // settle: rows come to rest, no residual motion

        let before = mountedFrames(surface, count: rows.count)
        XCTAssertFalse(before.isEmpty, "precondition: rows must mount")
        // Pick a row near the vertical middle of the viewport as the hover target.
        let mid = surface.bounds.midY
        guard let target = before.min(by: { abs($0.1.midY - mid) < abs($1.1.midY - mid) }) else {
            return XCTFail("no mounted row")
        }
        let k = target.0
        let cursor = CGPoint(x: target.1.midX, y: target.1.midY)
        print("HOVER before: mounted=\(before.map { "\($0.0)@\(Int($0.1.midY))" }.joined(separator: " "))")
        print("HOVER target k=\(k) cursor=\(cursor)")

        surface.debugMoveCursor(to: cursor)
        print("HOVER resolved index=\(String(describing: surface.debugHoveredRowIndex))")
        XCTAssertEqual(surface.debugHoveredRowIndex, k, "geometry hit-test must resolve the row under the cursor")
        XCTAssertTrue(surface.debugRowView(forIndex: k)?.debugHoverBackgroundVisible ?? false,
                      "row under the cursor must show its hover background")

        // Advance the active line so the list scrolls: row k slides out from under the stationary cursor.
        mc.syncPlaybackClock(to: 4 * 1.2 + 0.6, playing: true)
        surface.configure(config(rows, current: 4, mc: mc))
        spin(1.2) // let the spring settle at the new positions

        // Precondition: row k must still be MOUNTED (else unmount trivially clears it — not the bug).
        guard let kView = surface.debugRowView(forIndex: k) else {
            return XCTFail("row \(k) unmounted after advance; choose a target that stays on-screen")
        }
        let after = mountedFrames(surface, count: rows.count)
        let kMoved = after.first(where: { $0.0 == k }).map { abs($0.1.midY - target.1.midY) > 4 } ?? false
        XCTAssertTrue(kMoved, "precondition: row \(k) must have moved under the stationary cursor")
        let nowUnderCursor = after.first { $0.1.contains(cursor) }?.0
        print("HOVER after: mounted=\(after.map { "\($0.0)@\(Int($0.1.midY))" }.joined(separator: " "))")
        print("HOVER after resolvedIndex=\(String(describing: surface.debugHoveredRowIndex)) nowUnderCursor=\(String(describing: nowUnderCursor)) kBg=\(kView.debugHoverBackgroundVisible)")

        // The vacated row must have released its hover background...
        XCTAssertFalse(kView.debugHoverBackgroundVisible,
                       "hover background stuck on row \(k) after it slid out from under the cursor")
        // ...and hover must have followed the geometry to whatever row is under the cursor now.
        XCTAssertEqual(surface.debugHoveredRowIndex, nowUnderCursor,
                       "hover did not follow the cursor to the row now beneath it")
    }
}
