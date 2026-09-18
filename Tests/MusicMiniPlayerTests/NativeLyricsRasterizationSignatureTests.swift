import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder-approved generalized fix (2026-09-17, on top of the CJK trailing-word ghost repro
// in research/repro-2026-09-17-lyrics-render-3c.md §CJK): a row's rasterized bitmap snapshot
// must be revoked the SAME frame its text phase becomes active (or its deferred-deactivation
// fade engages) — not only when the visual wave/spring target catches up — and must never be
// reused across a blur-radius or geometry change while the row stays settled+inactive.
//
// Two invariants under test:
// (a) a frame where the row's text phase is active must never ALSO show shouldRasterize==true
//     (LyricsLayerRendererView.applyFrame folds textActiveByRowIndex/deferredDeactivationIndex
//     into the isActive input it passes to applyRasterizationPolicy).
// (b) a settled+inactive+blurred row's cached bitmap is force-recaptured on a genuine blur
//     change, but NOT re-captured every frame when nothing changed — Gate4 semantics (settled
//     non-active rows stay rasterized, cheap to recomposite) must not regress.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsRasterizationSignatureTests: XCTestCase {

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
            lineInterval: 1.5, hasSyllableSync: true,
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

    /// Same 8-row CJK fixture as the original repro: row 6 ends with the trailing word "滋味".
    private func cjkRows() -> [LayerBackedLyricRow] {
        let texts: [[String]] = [
            ["这", "是", "第", "一", "句"], ["这", "是", "第", "二", "句"], ["这", "是", "第", "三", "句"],
            ["这", "是", "第", "四", "句"], ["这", "是", "第", "五", "句"], ["这", "是", "第", "六", "句"],
            ["爱", "愁", "思", "心", "碎", "滋", "味"], ["这", "是", "第", "八", "句"],
        ]
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for (i, chars) in texts.enumerated() {
            var words: [LyricWord] = []
            var t = start
            let charDur: TimeInterval = 0.4
            for c in chars {
                words.append(LyricWord(word: c, startTime: t, endTime: t + charDur))
                t += charDur
            }
            let line = LyricLine(text: chars.joined(), startTime: start, endTime: t, words: words)
            rows.append(row(for: line, index: i))
            start = t + 0.3
        }
        return rows
    }

    // (a) Real surface, real deterministic clock: drive a settled/rasterized/blurred CJK row
    // through its own activation and assert NO frame ever shows shouldRasterize==true
    // simultaneously with an already-applying live per-run sweep — the exact precondition that
    // used to hold for 6 consecutive frames before this fix.
    @MainActor
    func test_cjkTrailingWordGhost_rasterizationNeverOverlapsLiveSweep() {
        let rows = cjkRows()
        let panelWidth: CGFloat = 360
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 60
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        func tick(_ t: TimeInterval, _ ticks: Int) {
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
            surface.configure(config(rows: rows, current: current, mc: mc, width: panelWidth))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<ticks {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                mc.syncPlaybackClock(to: t, playing: true, at: date)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
        }

        for r in 0..<3 {
            tick(rows[r].displayLine.line.startTime + 0.5, 6)
        }
        tick(rows[2].displayLine.line.startTime + 0.5, 60)

        guard let farView = surface.debugRowView(forIndex: 6) else {
            XCTFail("row 6 should be mounted (within visible radius)")
            return
        }
        XCTAssertTrue(farView.layer?.shouldRasterize ?? false, "precondition: row 6 should have settled into rasterized+blurred while far from active")

        var overlapFrames = 0
        for r in 3...6 {
            let lineStart = rows[r].displayLine.line.startTime
            let lineEnd = rows[r].displayLine.line.endTime
            var t = lineStart - 0.3
            while t <= lineEnd {
                tick(t, 2)
                if let v = surface.debugRowView(forIndex: 6) {
                    let rasterized = v.layer?.shouldRasterize ?? false
                    let sweepApplied = v.debugLastAppliedActivePerRunSweep
                    let brightOpacity = v.debugMainBrightOpacity
                    if rasterized && sweepApplied && brightOpacity > 0.01 {
                        overlapFrames += 1
                    }
                }
                t += 0.05
            }
        }
        XCTAssertEqual(overlapFrames, 0,
            "FIX: a stale rasterized snapshot must never composite alongside an already-live per-run sweep — this is the CJK '滋味' ghost precondition")
    }

    // (b) settled+inactive+blurred row: a genuine blur-radius change forces a fresh rasterization
    // capture; repeated frames at the SAME blur/geometry do not re-capture (Gate4 semantics —
    // settled non-active rows stay cheap, no per-frame re-rasterize cost).
    @MainActor
    func test_rasterizationSignature_recapturesOnBlurChange_notOnRepeatedFrames() {
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        host(view, NSSize(width: 320, height: 40))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()

        _ = view.applyBlurRadius(3.0)
        view.applyRasterizationPolicy(isSettled: true, isActive: false)
        XCTAssertTrue(view.layer?.shouldRasterize ?? false)
        XCTAssertEqual(view.debugRasterizationCaptureCount, 1, "first engagement must capture once")

        // Repeated frames, same blur, still settled+inactive — must NOT re-capture.
        for _ in 0..<5 {
            _ = view.applyBlurRadius(3.0)
            view.applyRasterizationPolicy(isSettled: true, isActive: false)
        }
        XCTAssertEqual(view.debugRasterizationCaptureCount, 1, "unchanged blur/geometry across repeated frames must not re-capture")

        // A genuine blur-target change while still settled+inactive must force a fresh capture.
        _ = view.applyBlurRadius(6.0)
        view.applyRasterizationPolicy(isSettled: true, isActive: false)
        XCTAssertEqual(view.debugRasterizationCaptureCount, 2, "a real blur-radius change must force a fresh rasterization capture, not reuse the stale one")
        XCTAssertTrue(view.layer?.shouldRasterize ?? false)

        // Becoming active revokes rasterization immediately (no capture on disengagement).
        view.applyRasterizationPolicy(isSettled: true, isActive: true)
        XCTAssertFalse(view.layer?.shouldRasterize ?? true, "an active row must never stay rasterized")
        XCTAssertEqual(view.debugRasterizationCaptureCount, 2, "disengaging must not count as a capture")
    }
}
