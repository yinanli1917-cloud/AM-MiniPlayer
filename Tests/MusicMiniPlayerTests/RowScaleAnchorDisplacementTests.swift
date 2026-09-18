import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// C1 follow-up (coordinator 2026-09-17): the tile-vs-whole-line text-LAYOUT-engine hypothesis
// came back negative (GlyphLayoutAgreementTests: 0.000pt agreement, all 4 scenarios). Redirected
// suspicion: the inactive-row 0.95<->1.00 scale (`NativeLyricsRowScale.leadingTransform`) and
// WHERE it is anchored.
//
// Read directly: `leadingTransform(scale:height:)` pivots Y at `height/2` (row vertical centre)
// but pivots X at the ROW LAYER'S OWN LOCAL ORIGIN (x=0) — NOT at the text's own left edge. The
// text content itself starts at `nativeLyricContentLeadingInset` = 32pt inside that same local
// space (`NativeLyricsRowView.layout()`: `let textX = nativeLyricContentLeadingInset`). Since the
// transform is applied to the ROW'S OWN BACKING LAYER (`setPositioning` -> `layer.setAffineTransform`,
// parent of every text sublayer), every text sublayer's on-screen X is
// `32 * scale` (relative to the row's frame origin) — NOT constant across scale changes.
//
// Exact predicted displacement between the inactive (0.95) and active (1.00) resting states:
//   Δx = 32 * (1.00 - 0.95) = 1.6pt
// This is a REAL, deterministic, EVERY-TIME difference between a row's two resting scales — not
// spring jitter — which matches "每次切行都有 1-2px 位移" far better than the tile/whole-line
// layout-engine hypothesis (which measured 0.000pt).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class RowScaleAnchorDisplacementTests: XCTestCase {

    /// Pure-math confirmation of the transform's actual pivot, read directly off
    /// `NativeLyricsRowScale.leadingTransform` — no view/layer involved, just the formula.
    func test_leadingTransform_pivotsXAtRowOrigin_notTextLeftEdge() {
        let height: CGFloat = 40
        let textLeftEdgeLocalX: CGFloat = 32 // nativeLyricContentLeadingInset
        let inactive = NativeLyricsRowScale.leadingTransform(scale: 0.95, height: height)
        let active = NativeLyricsRowScale.leadingTransform(scale: 1.0, height: height) // identity (guarded)

        // apply(transform, to: point) mirrors what CALayer does: p' = p applied through the affine transform.
        func apply(_ t: CGAffineTransform, _ p: CGPoint) -> CGPoint { p.applying(t) }

        let xAtInactive = apply(inactive, CGPoint(x: textLeftEdgeLocalX, y: 0)).x
        let xAtActive = apply(active, CGPoint(x: textLeftEdgeLocalX, y: 0)).x
        let displacement = xAtActive - xAtInactive

        print(String(format: "[C1-SCALE-ANCHOR] text left edge (local x=%.0f): inactive(0.95)=%.3f active(1.00)=%.3f displacement=%.3fpt",
                     textLeftEdgeLocalX, xAtInactive, xAtActive, displacement))

        XCTAssertEqual(xAtInactive, textLeftEdgeLocalX * 0.95, accuracy: 0.001)
        XCTAssertEqual(xAtActive, textLeftEdgeLocalX, accuracy: 0.001)
        XCTAssertEqual(displacement, textLeftEdgeLocalX * 0.05, accuracy: 0.001,
                        "the row-scale transform pivots X at the row's own origin, not the text's left edge — every active<->inactive transition moves the text horizontally by leadingInset * |Δscale|")
    }

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

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                    isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 3, hasSyllableSync: false,
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

    /// Real surface, real spring settle: drive a row through active -> inactive (the moment a
    /// line just finished and recedes) and read its REAL, converted-to-surface-space text-layer
    /// left edge X before and after, confirming the analytical prediction against the actual
    /// committed layer tree (not just the formula in isolation).
    @MainActor
    func test_realRow_textLeftEdgeX_shiftsByPredictedAmount_acrossActiveInactiveTransition() {
        let rows = (0..<4).map { i in
            row(for: LyricLine(text: "line \(i) words here", startTime: TimeInterval(i) * 3, endTime: TimeInterval(i + 1) * 3), index: i)
        }
        let panelWidth: CGFloat = 360
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 40
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        func tick(_ t: TimeInterval, _ ticks: Int) {
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), rows.count - 1)
            surface.configure(config(rows: rows, current: current, mc: mc, width: panelWidth))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<ticks {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                mc.syncPlaybackClock(to: t, playing: true, at: date)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
        }

        /// Converts row 1's mainTextLayer frame-origin (local, pre-transform) into surface space
        /// through the row's REAL, currently-committed affine transform — this is exactly the
        /// on-screen X WindowServer would composite.
        func row1TextLeftEdgeSurfaceX() -> CGFloat? {
            guard let view = surface.debugRowView(forIndex: 1), let layer = view.layer else { return nil }
            let localPoint = CGPoint(x: 32, y: 0) // nativeLyricContentLeadingInset
            return layer.convert(localPoint, to: surface.layer).x
        }

        // Row 1 active (t=1.5, mid its own [3,6) span... use its own start).
        tick(3.5, 20)
        guard let xActive = row1TextLeftEdgeSurfaceX() else { XCTFail("row 1 not mounted while active"); return }

        // Play forward well past row 1 so it fully recedes to its settled INACTIVE scale.
        tick(9.5, 60)
        guard let xInactive = row1TextLeftEdgeSurfaceX() else { XCTFail("row 1 not mounted while inactive"); return }

        let displacement = xActive - xInactive
        print(String(format: "[C1-SCALE-ANCHOR] real row1 text-left-edge surface X: active=%.3f inactive=%.3f displacement=%.3fpt",
                     xActive, xInactive, displacement))
        XCTAssertEqual(displacement, 32 * 0.05, accuracy: 0.05,
                        "real committed layer tree must show the SAME ~1.6pt horizontal displacement the formula predicts")
    }
}
