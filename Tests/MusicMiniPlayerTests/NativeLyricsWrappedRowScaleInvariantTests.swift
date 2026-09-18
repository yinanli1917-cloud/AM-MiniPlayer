import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder real-device rejection (2026-09-18, stage bundle 3f, item 1) of the first-line-baseline
// pivot fix (dcd7b6a): "每次切行 1-2px" was still visible on his actual test song, 范玮琪《啟程》
// — 38 lines, line-level LRC, ALMOST EVERY LINE wraps to two lines of Chinese text. The
// first-line-baseline pivot (dcd7b6a) only makes the FIRST wrap-line invariant; the SECOND
// wrap-line (the one below the pivot) still moves by `0.05 * lineHeight ≈ 1.7pt` on every
// active<->inactive scale toggle, because a single-point pivot cannot hold every line of a
// multi-line block still while the block visibly changes size — that is a structural property of
// uniform affine scale, not a tunable constant (see NativeLyricsRowView.mainTextWrapsToMultipleLines
// doc comment, research/repro-2026-09-18-lyrics-render-3g.md item 1).
//
// Fix: a row whose main text wraps to 2+ visual lines is pinned to scale 1.0 always (never
// springs to 0.95) — so EVERY line of that row, not just the first, is screen-Y invariant across
// activation. This test would have FAILED before the fix (positioningTransform.a would spring to
// 0.95 as the row recedes, moving line 2 by ~1.7pt even though line 1 stayed put) — verified by
// temporarily reverting the `effectiveScale` clamp in `LyricsLayerRendererView.applyFrame` and
// re-running: the assertion below failed with displacement ≈ 1.68pt for the CJK wrapped fixture.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsWrappedRowScaleInvariantTests: XCTestCase {
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

    /// Every wrap-line's baseline, measured by mapping candidate local Y offsets (0, one line
    /// height, two line heights below the pivot) through the row's OWN committed scale transform
    /// (`positioningTransform` — scale only, never translation, per `setPositioning`'s doc
    /// comment). Local space deliberately, same rationale as NativeLyricsBaselinePivotTests: the
    /// row's FRAME legitimately keeps scrolling for unrelated reasons; only the scale transform's
    /// own contribution is under test here.
    @MainActor
    private func lineOffsetsLocalY(_ view: NativeLyricsRowView, pivotY: CGFloat, lineHeight: CGFloat) -> [CGFloat] {
        [0, lineHeight, lineHeight * 2].map { offset in
            CGPoint(x: nativeLyricContentLeadingInset, y: pivotY + offset).applying(view.positioningTransform).y
        }
    }

    @MainActor
    func test_cjkWrappedRow_everyWrapLineIsScaleInvariant_notJustTheFirst() {
        NativeLyricsFeelParity.testingSweep = .v28
        defer { NativeLyricsFeelParity.resetTestingOverrides() }

        let panelWidth: CGFloat = 220 // narrow, like the founder's actual panel, forces 2-line wrap
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        // Mirrors 范玮琪《啟程》: short CJK lines that wrap to 2 lines at panel width.
        let texts = ["前奏", "想走出你控制的领域就从今晚开始", "第二句歌词内容测试文字", "第三句"]
        for (i, t) in texts.enumerated() {
            rows.append(row(for: LyricLine(text: t, startTime: start, endTime: start + 3), index: i))
            start += 3
        }

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

        tick(3.5, 20) // row 1 active
        guard let view = surface.debugRowView(forIndex: 1) else {
            XCTFail("row 1 not mounted while active"); return
        }
        XCTAssertTrue(view.mainTextWrapsToMultipleLines, "precondition: fixture must actually wrap so the bug is observable")
        let pivotY = view.verticalScalePivotY
        let lineHeight: CGFloat = 22 // approximate CJK line height at the fixture's font size
        let activeOffsets = lineOffsetsLocalY(view, pivotY: pivotY, lineHeight: lineHeight)

        tick(9.5, 60) // play forward well past row 1 so it fully recedes to its settled INACTIVE scale
        let inactiveOffsets = lineOffsetsLocalY(view, pivotY: pivotY, lineHeight: lineHeight)

        for (i, (active, inactive)) in zip(activeOffsets, inactiveOffsets).enumerated() {
            let displacement = active - inactive
            XCTAssertEqual(displacement, 0, accuracy: 0.001,
                "wrap-line \(i) (offset \(i) line-heights below the pivot) must be screen-Y invariant across active<->inactive, not just line 0; displacement=\(displacement)")
        }
        // The row must never have actually scaled at all (not merely happen to land near 1 for
        // OTHER reasons) — this is the direct assertion of the fix, the loop above is the
        // observable consequence.
        XCTAssertEqual(view.positioningTransform.a, 1.0, accuracy: 0.0001,
            "a wrapped row must render at a fixed scale of 1.0 in both active and inactive states")
    }

    @MainActor
    func test_singleLineCjkRow_stillScalesNormally_fixIsScopedToWrappedRows() {
        NativeLyricsFeelParity.testingSweep = .v28
        defer { NativeLyricsFeelParity.resetTestingOverrides() }

        let panelWidth: CGFloat = 320
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        let texts = ["前奏", "你好世界", "下一句", "再下一句"]
        for (i, t) in texts.enumerated() {
            rows.append(row(for: LyricLine(text: t, startTime: start, endTime: start + 3), index: i))
            start += 3
        }
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

        tick(9.5, 60) // row 1 fully inactive/settled
        guard let view = surface.debugRowView(forIndex: 1) else {
            XCTFail("row 1 not mounted"); return
        }
        XCTAssertFalse(view.mainTextWrapsToMultipleLines, "precondition: single-line fixture must not wrap")
        XCTAssertEqual(view.positioningTransform.a, 0.95, accuracy: 0.01,
            "single-line rows must keep the existing inactive shrink — the fix is scoped to wrapped rows only")
    }
}
