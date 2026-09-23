import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// C1 (coordinator 2026-09-17): the tile-vs-whole-line text-LAYOUT-engine hypothesis came back
// negative (GlyphLayoutAgreementTests: 0.000pt agreement, all 4 scenarios). Redirected suspicion
// to the inactive-row 0.95<->1.00 scale (`NativeLyricsRowScale.leadingTransform`) and WHERE it is
// anchored — CONFIRMED: it pivoted X at the ROW LAYER'S OWN LOCAL ORIGIN (x=0), not the text's own
// left edge (`nativeLyricContentLeadingInset` = 32pt inside that same local space). Since the
// transform applies to the ROW'S OWN BACKING LAYER (parent of every text sublayer), the text's
// on-screen X used to be `32 * scale` — a REAL, deterministic 1.6pt (32 * 0.05) difference between
// the two resting scales, not spring jitter, confirmed both analytically and against a real
// committed layer tree.
//
// FIX LANDED (research/repro-2026-09-17-lyrics-render-3c.md §C1): `leadingTransform` now pivots X
// at `nativeLyricContentLeadingInset` (the text's own left edge) instead of 0 — the Y pivot (row
// vertical centre, solving a separate CJK-wrap-spacing problem) is unchanged. These tests now
// assert the FIXED invariant (0.000pt) as the permanent regression guard, both CJK and English.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class RowScaleAnchorDisplacementTests: XCTestCase {

    /// Pure-math confirmation of the transform's actual (now-fixed) pivot — no view/layer
    /// involved, just the formula.
    func test_leadingTransform_afterFix_pivotsXAtTextLeftEdge_zeroDisplacement() {
        let height: CGFloat = 40
        let textLeftEdgeLocalX: CGFloat = nativeLyricContentLeadingInset
        // pivotY is irrelevant to this test (it only ever reads `.x`, and X/Y scale
        // independently in an affine transform) — 2026-09-18: leadingTransform now takes the
        // real vertical pivot as an explicit parameter (NativeLyricsRowView.verticalScalePivotY
        // in production, the first line's text baseline) instead of deriving height/2 itself;
        // any fixed value here exercises the exact same X-axis code path.
        let pivotY: CGFloat = height / 2
        let inactive = NativeLyricsRowScale.leadingTransform(scale: 0.95, height: height, pivotY: pivotY)
        let active = NativeLyricsRowScale.leadingTransform(scale: 1.0, height: height, pivotY: pivotY) // identity (guarded)

        // apply(transform, to: point) mirrors what CALayer does: p' = p applied through the affine transform.
        func apply(_ t: CGAffineTransform, _ p: CGPoint) -> CGPoint { p.applying(t) }

        let xAtInactive = apply(inactive, CGPoint(x: textLeftEdgeLocalX, y: 0)).x
        let xAtActive = apply(active, CGPoint(x: textLeftEdgeLocalX, y: 0)).x
        let displacement = xAtActive - xAtInactive

        print(String(format: "[C1-SCALE-ANCHOR] text left edge (local x=%.0f): inactive(0.95)=%.3f active(1.00)=%.3f displacement=%.3fpt",
                     textLeftEdgeLocalX, xAtInactive, xAtActive, displacement))

        XCTAssertEqual(xAtInactive, textLeftEdgeLocalX, accuracy: 0.001,
                        "FIX: the text's left edge must be invariant under the scale change, not just the row's bare x=0 origin")
        XCTAssertEqual(xAtActive, textLeftEdgeLocalX, accuracy: 0.001)
        XCTAssertEqual(displacement, 0, accuracy: 0.001,
                        "FIX: the row-scale transform now pivots X at the text's own left edge — active<->inactive must not move it")
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
    /// left edge X before and after, confirming the fix against the actual committed layer tree
    /// (not just the formula in isolation). CJK and English each get their own row so a
    /// script-specific regression can't hide behind the other.
    @MainActor
    private func assertTextLeftEdgeInvariant(chars: [String], label: String) {
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for (i, text) in chars.enumerated() {
            rows.append(row(for: LyricLine(text: text, startTime: start, endTime: start + 3), index: i))
            start += 3
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
            let localPoint = CGPoint(x: nativeLyricContentLeadingInset, y: 0)
            return layer.convert(localPoint, to: surface.layer).x
        }

        tick(3.5, 20) // row 1 active
        guard let xActive = row1TextLeftEdgeSurfaceX() else { XCTFail("\(label): row 1 not mounted while active"); return }

        tick(9.5, 60) // play forward well past row 1 so it fully recedes to its settled INACTIVE scale
        guard let xInactive = row1TextLeftEdgeSurfaceX() else { XCTFail("\(label): row 1 not mounted while inactive"); return }

        let displacement = xActive - xInactive
        print(String(format: "[C1-SCALE-ANCHOR] \(label) real row1 text-left-edge surface X: active=%.3f inactive=%.3f displacement=%.3fpt",
                     xActive, xInactive, displacement))
        XCTAssertEqual(displacement, 0, accuracy: 0.05,
                        "\(label): FIX: the real committed layer tree's text left edge must not move across the active<->inactive transition")
    }

    @MainActor
    func test_realRow_afterFix_englishLine_textLeftEdgeInvariantAcrossActiveInactiveTransition() {
        assertTextLeftEdgeInvariant(chars: ["intro line", "line one words here", "line two", "line three"], label: "EN")
    }

    @MainActor
    func test_realRow_afterFix_cjkLine_textLeftEdgeInvariantAcrossActiveInactiveTransition() {
        assertTextLeftEdgeInvariant(chars: ["前奏行", "这是第一句歌词内容", "第二句歌词", "第三句歌词"], label: "CJK")
    }
}
