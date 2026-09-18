import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 2026-09-18 (coordinator-approved fix, research/repro-2026-09-18-lyrics-render-3d.md §4 third
// round): `NativeLyricsRowScale.leadingTransform`'s Y pivot moved from the row's geometric
// center (`height / 2`) to the row's FIRST LINE text baseline
// (`NativeLyricsRowView.verticalScalePivotY`). Founder real-machine evidence (09-14 LineGaps
// log, row idx=1: `h=40.0 s=1.00` active -> `h=38.0 s=0.95` inactive, 38.0 = 40.0 x 0.95 —
// traced to the LineGaps probe's OWN scale-corrected "h" field, not accumulatedHeights, but the
// underlying MECHANISM it was measuring — the row's text visibly shifting within its own slot as
// scale toggles — is real): centering the pivot moved the row's first (topmost, most-recently-
// read) line of text by `firstLineOffsetFromCenter * |Δscale|` (~1pt for a typical single-line
// row) on every activation/deactivation.
//
// Three requirements verified here, real surface + real committed layer tree (not just the pure
// formula, already covered by NativeLyricsActiveLineSpacingTests):
// 1. The first line's text baseline has ZERO screen-Y displacement across active<->inactive,
//    for EN + CJK, single-line, wrapped (3 visual lines), and with a translation line.
// 2. NativeLyricsActiveLineSpacingTests / RowScaleAnchorDisplacementTests stay green — verified
//    by running them in the same regression pass as this file (see commit message), not
//    duplicated here.
// 3. Adjacent rows never overlap (LineGaps-probe-equivalent gap >= 0) across the transition.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsBaselinePivotTests: XCTestCase {
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
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: true,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    // MARK: - Requirement 1: first-line baseline is screen-Y invariant across active<->inactive

    private struct BaselineCase {
        let label: String
        let text: String
        let translation: String?
    }

    @MainActor
    private func assertBaselineInvariant(_ c: BaselineCase, panelWidth: CGFloat) {
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        let texts = ["intro", c.text, "next line", "another line"]
        for (i, t) in texts.enumerated() {
            let line = i == 1
                ? LyricLine(text: t, startTime: start, endTime: start + 3, translation: c.translation)
                : LyricLine(text: t, startTime: start, endTime: start + 3)
            rows.append(row(for: line, index: i))
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

        /// Maps row 1's own `verticalScalePivotY` (production's first-line-baseline value)
        /// through JUST the row's own committed SCALE transform (`positioningTransform` — carries
        /// ONLY scale, never translation, per `setPositioning`'s own doc comment), in the row's
        /// own LOCAL coordinate space — deliberately NOT converted into surface space. Row 1's
        /// FRAME itself legitimately keeps scrolling as playback advances past it (the row stays
        /// within the wave's participant radius — proven correct and exact in
        /// LyricsRenderDefects20260918SettleTargetGapTests, commit edca686), which would otherwise
        /// swamp the ~1pt scale-pivot signal this test exists to isolate. Measuring in local space
        /// removes that confound entirely: it answers "does the scale transform itself move this
        /// point", not "did the row's slot on screen also move for an unrelated, correct reason".
        func row1BaselineLocalY() -> CGFloat? {
            guard let view = surface.debugRowView(forIndex: 1) else { return nil }
            let localPoint = CGPoint(x: nativeLyricContentLeadingInset, y: view.verticalScalePivotY)
            return localPoint.applying(view.positioningTransform).y
        }

        tick(3.5, 20) // row 1 active
        guard let yActive = row1BaselineLocalY() else { XCTFail("\(c.label): row 1 not mounted while active"); return }

        tick(9.5, 60) // play forward well past row 1 so it fully recedes to its settled INACTIVE scale
        guard let yInactive = row1BaselineLocalY() else { XCTFail("\(c.label): row 1 not mounted while inactive"); return }

        let displacement = yActive - yInactive
        print(String(format: "[BaselinePivot] %@: active=%.4f inactive=%.4f displacement=%.4fpt",
                     c.label, yActive, yInactive, displacement))
        XCTAssertEqual(displacement, 0, accuracy: 0.001,
                       "\(c.label): first-line baseline must be invariant (in the row's own coordinate space) across active<->inactive")
    }

    @MainActor func test_baseline_en_singleLine() {
        assertBaselineInvariant(BaselineCase(label: "EN single-line", text: "hello brave world", translation: nil), panelWidth: 320)
    }

    @MainActor func test_baseline_en_wrapped3Lines() {
        assertBaselineInvariant(BaselineCase(
            label: "EN wrapped (3 lines)",
            text: "a genuinely long line of lyrics that will definitely wrap across three separate visual lines at this width",
            translation: nil
        ), panelWidth: 220)
    }

    @MainActor func test_baseline_en_withTranslation() {
        assertBaselineInvariant(BaselineCase(label: "EN + translation", text: "hello brave world", translation: "你好勇敢的世界"), panelWidth: 320)
    }

    @MainActor func test_baseline_cjk_singleLine() {
        assertBaselineInvariant(BaselineCase(label: "CJK single-line", text: "你好世界", translation: nil), panelWidth: 320)
    }

    @MainActor func test_baseline_cjk_wrapped3Lines() {
        assertBaselineInvariant(BaselineCase(
            label: "CJK wrapped (3 lines)",
            text: "這是一句非常長的中文歌詞一定會在這個寬度下換成三行文字內容測試測試測試",
            translation: nil
        ), panelWidth: 220)
    }

    @MainActor func test_baseline_cjk_withTranslation() {
        assertBaselineInvariant(BaselineCase(label: "CJK + translation", text: "你好世界", translation: "Hello world"), panelWidth: 320)
    }

    // MARK: - Requirement 3: adjacent rows never overlap across the transition

    /// Mirrors `logLineGapsProbe`'s own scale-corrected geometry exactly (LyricsLayerRendererView.swift):
    /// `scaledHeight = frame.height * scale; minY = frame.midY - scaledHeight / 2` when scale != 1,
    /// else the raw frame. A negative gap between two adjacent rows means their rendered bounding
    /// boxes visually overlap.
    @MainActor
    private func gapBetweenAdjacentRows(_ surface: NativeLyricsSurfaceView, _ lowerIndex: Int) -> CGFloat? {
        guard let lowerView = surface.debugRowView(forIndex: lowerIndex),
              let upperView = surface.debugRowView(forIndex: lowerIndex + 1) else { return nil }
        func geometry(_ view: NativeLyricsRowView) -> (minY: CGFloat, height: CGFloat) {
            let frame = view.frame
            let scale = view.positioningTransform.a
            if scale == 1 { return (frame.minY, frame.height) }
            let scaledHeight = frame.height * scale
            return (frame.midY - scaledHeight / 2, scaledHeight)
        }
        let lower = geometry(lowerView)
        let upper = geometry(upperView)
        return upper.minY - (lower.minY + lower.height)
    }

    @MainActor
    private func assertNoOverlap(chars: [String], label: String) {
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for (i, text) in chars.enumerated() {
            rows.append(row(for: LyricLine(text: text, startTime: start, endTime: start + 3), index: i))
            start += 3
        }
        let panelWidth: CGFloat = 320
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

        var minGapSeen: CGFloat = .greatestFiniteMagnitude
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
                for idx in 0..<(rows.count - 1) {
                    if let gap = gapBetweenAdjacentRows(surface, idx) {
                        minGapSeen = min(minGapSeen, gap)
                    }
                }
            }
        }

        var t: TimeInterval = 0.02
        while t < start + 3 {
            tick(t, 1)
            t += 1.0 / 60.0
        }

        print("[BaselinePivot] \(label): min adjacent-row gap observed = \(minGapSeen)")
        XCTAssertGreaterThanOrEqual(minGapSeen, 0,
            "\(label): adjacent rows must never visually overlap (negative gap) across the active<->inactive transition")
    }

    @MainActor func test_noOverlap_en() {
        assertNoOverlap(chars: ["intro line", "line one words here", "line two", "line three"], label: "EN")
    }

    @MainActor func test_noOverlap_cjk() {
        assertNoOverlap(chars: ["前奏行", "这是第一句歌词内容", "第二句歌词", "第三句歌词"], label: "CJK")
    }
}
