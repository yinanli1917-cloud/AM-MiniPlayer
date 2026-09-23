import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Reproduction + regression guard for founder-reported defect A (2026-09-17, stage bundle 3c
// = main 4b159b9): playing a syllable-synced line to completion, continuing forward past it,
// then seeking BACKWARD into that same (already-swept) line's own span loses the karaoke
// highlight mask — the dim base text stays at inactive brightness while only the per-word
// float/emphasis glyphs keep moving ("整行保持未激活颜色，只剩逐字浮动").
//
// Headless, injected/pure-function state only — deterministic clock via debugNowOverride /
// debugTick / MusicController.debugPlaybackClockDateProvider. No computer use, no screen
// recording (founder rule 2026-08-21).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsRenderDefects20260917ReproTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

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
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    private func syllableLine(_ text: String, start: TimeInterval, wordDuration: TimeInterval) -> (LyricLine, TimeInterval) {
        let tokens = text.split(separator: " ").map(String.init)
        var words: [LyricWord] = []
        var t = start
        for (i, tok) in tokens.enumerated() {
            let w = i == tokens.count - 1 ? tok : tok + " "
            words.append(LyricWord(word: w, startTime: t, endTime: t + wordDuration))
            t += wordDuration
        }
        return (LyricLine(text: text, startTime: start, endTime: t, words: words), t)
    }

    @MainActor
    private func config(
        rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 1.5, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 60),
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

    /// 6 short syllable-synced lines: row0 = [0, 1.0), then a LONG 5s gap (row1 = [6.0, 7.0),
    /// row2 = [7.5, 8.5), ... spaced 0.5s apart from there). All 6 rows stay within
    /// nativeLyricAutoVisibleRowRadius (12) for the whole test, so row0's NSView is never
    /// recycled through prepareForReuse — the exact precondition for this bug (a stale per-row
    /// float pinned before the identity-reset points). The long gap after row0 matters: per
    /// `NativeLyricsTimelinePolicy.liveDisplayIndex`/`amllState`, a line with no successor yet
    /// started stays the "currently singing" (hot/active) row for its WHOLE gap — so row0 keeps
    /// receiving `updatePlaybackPhase` calls with a steadily shrinking `plan.mainPostLineFade`
    /// (`postLineFadeOut`, 1.5s decay) for the full 5s, long enough for the monotone floor to
    /// genuinely bottom out at 0 before row1 ever takes over.
    private func sixLineSong() -> [LayerBackedLyricRow] {
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for i in 0..<6 {
            let (line, end) = syllableLine("kimi to", start: start, wordDuration: 0.5)
            rows.append(row(for: line, index: i))
            start = end + (i == 0 ? 5.0 : 0.5)
        }
        return rows
    }

    /// THE deterministic path the founder reports (Meiko Nakahara "Private Beach", 336s,
    /// Japanese word-level; "any word-synced song reproduces it"): play a line to completion,
    /// keep playing forward well past its 1.5s post-line-fade window, then seek BACKWARD into
    /// that SAME line's own [start, end) span.
    ///
    /// Root cause: `NativeLyricsRowView.mainPostLineFadeFloor` is a MONOTONE floor
    /// (`mainPostLineFadeFloor = min(mainPostLineFadeFloor, plan.mainPostLineFade)`,
    /// NativeLyricsRowView.swift ~1758) that resets to 1 ONLY on a genuine row-identity change
    /// inside `configure()` (`self.row?.displayLine.id != row.displayLine.id`) or on
    /// `prepareForReuse()` pool recycling — never on an explicit seek that lands back inside the
    /// SAME row's own line. Once the floor decays to 0 as the line recedes past its 1.5s
    /// post-line-fade window (`NativeLyricsTextRenderPlan.postLineFadeOut`), a backward seek back
    /// into the line's own active span computes a FRESH `plan.mainPostLineFade == 1`
    /// (postLineFadeOut's guard: `timeSinceLineEnd > 0 else { return 1 }`), but
    /// `min(0, 1) == 0` — the bright/masked karaoke overlay layer
    /// (`mainBrightTextLayer.isHidden = ... || mainPostLineFadeFloor <= 0.001`) stays hidden for
    /// the rest of that row view's mounted lifetime. The dim base text layer (always visible,
    /// separate from the bright overlay) keeps showing the line at inactive brightness, and the
    /// per-word emphasis/float glyph layers (a SEPARATE CALayer tree, not gated by
    /// `mainBrightTextLayer.isHidden`) keep animating — exactly the founder's report: "整行保持
    /// 未激活颜色，只剩逐字浮动".
    @MainActor
    func test_seekBackIntoCompletedSweptLine_restoresKaraokeMask() {
        let rows = sixLineSong()
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
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

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

        // Play row 0's [0, 1.0) span through to completion, then keep ticking through its 5s
        // gap (row0 stays the "hot" row the whole time — see sixLineSong doc) so the monotone
        // floor genuinely decays via repeated ACTIVE min-clamp calls, then on into rows 1-4.
        for t: TimeInterval in [0.2, 0.6, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 5.9, 6.5, 7.5, 8.5] {
            tick(t, 6)
        }

        guard let row0ViewBeforeSeek = surface.debugRowView(forIndex: 0) else {
            XCTFail("row 0 view should still be mounted (within nativeLyricAutoVisibleRowRadius)")
            return
        }
        // Sanity: row 0 really has decayed to the inactive/hidden karaoke overlay before the
        // seek — this is the pre-existing resting state the seek-back lands INTO.
        XCTAssertEqual(row0ViewBeforeSeek.debugMainBrightOpacity, 0, accuracy: 0.001,
                        "row 0's karaoke overlay should have faded out after playing well past it")

        // Explicit backward seek into row 0's own [0, 1.0) span — the founder's repro.
        mc.registerSeek()
        tick(0.5, 6)
        for _ in 0..<20 { tick(0.5, 1) }

        guard let row0ViewAfterSeek = surface.debugRowView(forIndex: 0) else {
            XCTFail("row 0 view should still be mounted after the seek-back")
            return
        }
        XCTAssertTrue(row0ViewAfterSeek === row0ViewBeforeSeek,
                      "repro precondition: the SAME NSView instance must stay mounted across the seek — a freshly reused view would reset via prepareForReuse and would not show this bug")
        XCTAssertTrue(row0ViewAfterSeek.debugLastAppliedActivePerRunSweep,
                      "row 0 is syllable-synced and active after the seek-back; the per-word sweep should engage")
        XCTAssertGreaterThan(row0ViewAfterSeek.debugMainBrightOpacity, 0.5,
                              "FIX: seeking back into an already-swept line's own span must restore the karaoke highlight overlay, not leave it permanently hidden by the stale post-line-fade floor")
    }
}
