import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Real-device repro, 2026-09-19 (creator session, 《啟程》network-YRC word-level lyrics,
// display idx=5 "想爱 就不能害怕会有伤痕", 58.16-66.12s). Evidence in
// research/repro-2026-09-19-lyrics-render-3k.md. Captured via nanopod://debug/rowdump +
// NativeLyricsMaskTrace (/tmp/nanopod_mask_trace.jsonl):
//   - Natural playback sang row 5 through to completion, then continued (unpaused, no further
//     seek) another ~30s past it into row 14 — row 5's `mainPostLineFadeFloor` faded to 0 long
//     ago, as designed (the karaoke overlay recedes after a line finishes).
//   - An EXTERNAL seek (Music.app / a controller outside this app) landed at 45.3s — inside row
//     4, one line BEFORE row 5.
//   - Playback then advanced NATURALLY (no further seek) forward across the row 4→5 boundary.
//   - At that moment: mask_state trace showed row 5's word index climbing 0→10 with
//     expected==applied progress (the per-word sweep model was computing correctly), but
//     `mainBrightTextLayer` stayed **opacity=0, isHidden=true** the entire time — the karaoke
//     overlay never lit. debug.log: `[ActiveBrightness] idx=5 rowOp=0.999 bright=0.000
//     eff=0.000` (row 4, the seek-landing row, read `bright=0.789` at the same moment).
//
// Root cause: `nativeSeekDiscontinuityOccurred` is a ONE-FRAME transient signal, consumed only
// by rows `updatePlaybackPhase` actually runs on during that exact tick. Row 5 was not the
// active line at the moment of the seek (it had long receded past-active, off the rendered
// window), so it was never driven that tick — the transient reset never reached it, and its
// fade floor (pinned near 0 from its earlier natural completion) survived the seek and the
// subsequent natural re-entry into its own span, which never sets the transient flag either
// (nothing "discontinuous" happens from THIS row's point of view — it is simply promoted to
// active by the clock advancing normally).
//
// These are model-state tests (row-view `updatePlaybackPhase` driven directly, deterministic
// injected clock, no surface/windowing involved). The row view IS hosted in a real (invisible)
// window and forced through one AppKit layout pass — `applyActiveMainPhase` short-circuits to a
// zero-progress "not laid out yet" state while `mainBrightTextLayer.bounds` is `.zero`, which a
// never-laid-out bare view would never clear, masking the bug under test either way. Driving the
// bare row view directly (rather than the full NativeLyricsSurfaceView) is
// deliberate: it is the only way to reproduce the exact real-device gap — the surface's own
// render loop, in a synthetic harness with every index in `renderedIndices`, always ends up
// calling `updatePlaybackPhase` on every row every tick, which is NOT how the real windowed
// renderer behaves (only rows within the current render radius get ticked) and would silently
// hide this bug behind wall coverage the real renderer doesn't have.
//
// The fix under test (NativeLyricsRowView.updatePlaybackPhase) arms `mainPostLineFadeFloor` to 1
// on the row's own text-activation EDGE (not-active → active), tracked locally on the view via
// `mainWasTextActiveLastPhase` — independent of whether the transient seek flag ever reached
// this exact view.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsPostSeekReactivationMaskTests: XCTestCase {
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    /// `applyActiveMainPhase` short-circuits to a zero-progress "not laid out yet" state whenever
    /// `mainBrightTextLayer.bounds` is still `.zero` (`geometryReady`, guarding a genuinely
    /// fresh/pooled/offscreen row from painting a whole-line bright flash before its geometry is
    /// known) — see its own comment at the definition. A bare `NativeLyricsRowView` never gets a
    /// real AppKit layout pass unless it is hosted in a window and explicitly asked to lay out, so
    /// every test in this file must go through this helper (mirrors NativeLyricsSeekLandingMaskTests'
    /// own `host` + `layoutSubtreeIfNeeded`) or the row never reaches the code path under test at
    /// all — it would fail identically with or without the fix, for a reason unrelated to the bug.
    @MainActor
    private func hostAndLayout(_ view: NativeLyricsRowView) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 320, height: 80)),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        view.layoutSubtreeIfNeeded()
    }

    private func makeRow(index: Int, startTime: TimeInterval, duration: TimeInterval = 4.0) -> LayerBackedLyricRow {
        let s = startTime, e = s + duration
        let w = duration / 4
        let line = LyricLine(
            text: "line \(index) has four words", startTime: s, endTime: e,
            words: [
                LyricWord(word: "line ", startTime: s, endTime: s + w),
                LyricWord(word: "\(index) ", startTime: s + w, endTime: s + 2 * w),
                LyricWord(word: "has four ", startTime: s + 2 * w, endTime: s + 3 * w),
                LyricWord(word: "words", startTime: s + 3 * w, endTime: e),
            ]
        )
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                   isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func makeConfig(
        rows: [LayerBackedLyricRow], activeIndex: Int, renderTime: TimeInterval,
        seekDiscontinuity: Bool, mc: MusicController
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        var cfg = LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: activeIndex, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
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
        cfg.nativePhaseClock = { renderTime }
        cfg.nativeSeekDiscontinuityOccurred = seekDiscontinuity
        return cfg
    }

    /// Drives `view.updatePlaybackPhase` across a closed time range at a fixed step, with
    /// `activeIndex` recomputed each tick by the caller-supplied closure — models natural
    /// (non-seek) playback advancing the clock, with the render index tracking it exactly like
    /// the real renderer's role-promotion. `nativeSeekDiscontinuityOccurred` is ALWAYS false here
    /// — by construction, this helper can never simulate a seek; every tick is a normal forward
    /// playback step.
    @MainActor
    private func tickNaturally(
        view: NativeLyricsRowView, rows: [LayerBackedLyricRow], mc: MusicController,
        from: TimeInterval, to: TimeInterval, step: TimeInterval = 1.0 / 60.0,
        activeIndex: (TimeInterval) -> Int
    ) {
        var t = from
        while t < to {
            t = min(to, t + step)
            let cfg = makeConfig(rows: rows, activeIndex: activeIndex(t), renderTime: t, seekDiscontinuity: false, mc: mc)
            view.updatePlaybackPhase(configuration: cfg)
        }
    }

    // MARK: - Core repro

    @MainActor
    func test_naturalReentryAfterFarDwellAndUnseenSeek_brightOverlayReactivates() {
        let rows = (0..<20).map { makeRow(index: $0, startTime: TimeInterval($0) * 8.0, duration: 4.0) }
        let target = 5
        let targetLine = rows[target].displayLine.line
        let mc = MusicController(preview: true)

        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let mountConfig = makeConfig(rows: rows, activeIndex: target, renderTime: targetLine.startTime + 0.05,
                                     seekDiscontinuity: false, mc: mc)
        view.configure(row: rows[target], configuration: mountConfig)
        hostAndLayout(view)

        // 1) Natural playback sings row `target` fully (isActive continuously true across its
        //    span and the 1.5s post-line afterglow window), then keeps advancing far past it
        //    (another ~30s, never revisiting `target`) with `target` now the INACTIVE role —
        //    exactly the real session's "sang idx=5, dwelled 30s at idx=14" shape. The floor
        //    pins to 0 during the afterglow decay, as designed.
        tickNaturally(view: view, rows: rows, mc: mc,
                      from: targetLine.startTime + 0.05, to: targetLine.endTime + 2.0) { _ in target }
        XCTAssertEqual(view.debugMainBrightOpacity, 0, accuracy: 0.001,
            "precondition: the post-line afterglow must have fully decayed the floor to 0 by now")

        tickNaturally(view: view, rows: rows, mc: mc,
                      from: targetLine.endTime + 2.0, to: targetLine.endTime + 32.0) { _ in 14 }

        // 2) The external seek landing on an EARLIER row (idx 4, 45.3s in the real session) is
        //    deliberately never applied to THIS view at all — no `updatePlaybackPhase` call, no
        //    `nativeSeekDiscontinuityOccurred`, nothing. This models the row being outside the
        //    renderer's window at the exact tick the real seek landed (it was still receding
        //    off-window from having sung 30s ago), so the transient flag can never reach it.

        // 3) Natural playback resumes from the seek's landing time and crosses the row-4→row-5
        //    boundary purely through the clock advancing — no seek, no discontinuity flag, ever,
        //    on this view.
        let landingTime = rows[target - 1].displayLine.line.startTime + 0.5
        let sweepEnd = targetLine.startTime + (targetLine.endTime - targetLine.startTime) * 0.7
        tickNaturally(view: view, rows: rows, mc: mc, from: landingTime, to: sweepEnd) { t in
            rows.last(where: { $0.displayLine.line.startTime <= t })?.index ?? 0
        }

        let expected = view.debugLastMainExpectedProgress ?? -1
        XCTAssertGreaterThan(expected, 0.3,
            "precondition: by 70% through the line the per-word sweep should be well underway (got \(expected))")
        XCTAssertGreaterThan(view.debugMainBrightOpacity, 0.05,
            "karaoke overlay never lit on natural re-entry into row \(target) (expected progress=\(expected)) — "
            + "mainPostLineFadeFloor stayed pinned at 0 from the earlier natural completion, because the "
            + "transient seek-discontinuity flag never reached this specific view")
        XCTAssertTrue(view.debugLastAppliedActivePerRunSweep,
            "per-word sweep must be engaged on re-entry, not degraded to whole-line/absent")
    }

    // MARK: - Variant: seek lands 2 lines before the target (not immediately adjacent)

    @MainActor
    func test_naturalReentryTwoLinesAfterUnseenSeek_brightOverlayReactivates() {
        let rows = (0..<20).map { makeRow(index: $0, startTime: TimeInterval($0) * 8.0, duration: 4.0) }
        let target = 6
        let targetLine = rows[target].displayLine.line
        let mc = MusicController(preview: true)

        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        view.configure(row: rows[target], configuration: makeConfig(
            rows: rows, activeIndex: target, renderTime: targetLine.startTime + 0.05,
            seekDiscontinuity: false, mc: mc))
        hostAndLayout(view)

        tickNaturally(view: view, rows: rows, mc: mc,
                      from: targetLine.startTime + 0.05, to: targetLine.endTime + 2.0) { _ in target }
        tickNaturally(view: view, rows: rows, mc: mc,
                      from: targetLine.endTime + 2.0, to: targetLine.endTime + 40.0) { _ in 16 }

        // Landing 2 lines before the target (row target-2), still never touching this view.
        let landingTime = rows[target - 2].displayLine.line.startTime + 0.4
        let sweepEnd = targetLine.startTime + (targetLine.endTime - targetLine.startTime) * 0.75
        tickNaturally(view: view, rows: rows, mc: mc, from: landingTime, to: sweepEnd) { t in
            rows.last(where: { $0.displayLine.line.startTime <= t })?.index ?? 0
        }

        XCTAssertGreaterThan(view.debugMainBrightOpacity, 0.05,
            "karaoke overlay never lit on natural re-entry into row \(target), landing 2 lines earlier "
            + "(expected progress=\(view.debugLastMainExpectedProgress ?? -1))")
    }

    // MARK: - Two consecutive unseen "seeks" (index jumps this view never observes) before re-entry

    @MainActor
    func test_consecutiveUnseenSeeksThenNaturalReentry_brightOverlayReactivates() {
        let rows = (0..<20).map { makeRow(index: $0, startTime: TimeInterval($0) * 8.0, duration: 4.0) }
        let target = 7
        let targetLine = rows[target].displayLine.line
        let mc = MusicController(preview: true)

        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        view.configure(row: rows[target], configuration: makeConfig(
            rows: rows, activeIndex: target, renderTime: targetLine.startTime + 0.05,
            seekDiscontinuity: false, mc: mc))
        hostAndLayout(view)

        tickNaturally(view: view, rows: rows, mc: mc,
                      from: targetLine.startTime + 0.05, to: targetLine.endTime + 2.0) { _ in target }
        tickNaturally(view: view, rows: rows, mc: mc,
                      from: targetLine.endTime + 2.0, to: targetLine.endTime + 40.0) { _ in 17 }

        // Two jump-backs in a row, neither ever driving this view (both land far from `target`,
        // outside its render window in the real renderer).
        let firstLanding = rows[target - 3].displayLine.line.startTime + 0.3
        let secondLanding = rows[target - 2].displayLine.line.startTime + 0.3
        let sweepEnd = targetLine.startTime + (targetLine.endTime - targetLine.startTime) * 0.7
        // (No calls to `view` for the two landings themselves — that IS the point.)
        _ = firstLanding
        tickNaturally(view: view, rows: rows, mc: mc, from: secondLanding, to: sweepEnd) { t in
            rows.last(where: { $0.displayLine.line.startTime <= t })?.index ?? 0
        }

        XCTAssertGreaterThan(view.debugMainBrightOpacity, 0.05,
            "karaoke overlay never lit on natural re-entry into row \(target) after two consecutive "
            + "unseen index jumps to earlier lines")
    }

    // MARK: - Dim-base brightness must never read full-bright while the bright overlay is hidden
    //
    // Coordinator follow-up (02:21 real-device eyewitness: row read as fully bright/white on
    // screen at the same instant the rowdump's MODEL layer values read dim-base opacity=0.35,
    // bright hidden). Regardless of that specific model/presentation-timing question (addressed
    // separately by the rowdump upgrade printing `layer.presentation()?.opacity`), this pins the
    // MODEL-level invariant the fix must hold: whenever the bright overlay is hidden, the dim
    // base's effective brightness (rowOpacity × baseLayerOpacity) must sit at the dim tier
    // (~0.35), never at the uncompensated full-bright value a stale `mainDimCompensationActive`
    // flag would produce.
    @MainActor
    func test_dimBaseNeverReadsFullBrightWhileBrightOverlayHidden() {
        let rows = (0..<20).map { makeRow(index: $0, startTime: TimeInterval($0) * 8.0, duration: 4.0) }
        let target = 5
        let targetLine = rows[target].displayLine.line
        let mc = MusicController(preview: true)

        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        view.configure(row: rows[target], configuration: makeConfig(
            rows: rows, activeIndex: target, renderTime: targetLine.startTime + 0.05,
            seekDiscontinuity: false, mc: mc))
        hostAndLayout(view)
        view.setRowOpacity(1, dimBaseBrightness: 0.35)

        tickNaturally(view: view, rows: rows, mc: mc,
                      from: targetLine.startTime + 0.05, to: targetLine.endTime + 2.0) { _ in target }
        tickNaturally(view: view, rows: rows, mc: mc,
                      from: targetLine.endTime + 2.0, to: targetLine.endTime + 30.0) { _ in 14 }

        let landingTime = rows[target - 1].displayLine.line.startTime + 0.5
        let sweepEnd = targetLine.startTime + (targetLine.endTime - targetLine.startTime) * 0.7
        var sampledActiveFrame = false
        var t = landingTime
        let step: TimeInterval = 1.0 / 60.0
        while t < sweepEnd {
            t = min(sweepEnd, t + step)
            let idx = rows.last(where: { $0.displayLine.line.startTime <= t })?.index ?? 0
            let cfg = makeConfig(rows: rows, activeIndex: idx, renderTime: t, seekDiscontinuity: false, mc: mc)
            view.updatePlaybackPhase(configuration: cfg)
            view.setRowOpacity(1, dimBaseBrightness: 0.35)
            guard idx == target else { continue }
            sampledActiveFrame = true
            let effectiveBrightness = view.debugRowLayerOpacity * view.debugMainBaseLayerOpacity
            if view.debugMainBrightOpacity <= 0.001 {
                XCTAssertLessThanOrEqual(Double(effectiveBrightness), 0.40,
                    "row \(target) at t=\(t): bright overlay hidden but dim-base effective brightness "
                    + "\(effectiveBrightness) reads at/near full brightness — the dim tier is 0.35; the "
                    + "compensation flag must not have gone stale/uncompensated for this frame")
            }
        }
        XCTAssertTrue(sampledActiveFrame, "precondition: must have sampled at least one active frame for row \(target)")
    }
}
