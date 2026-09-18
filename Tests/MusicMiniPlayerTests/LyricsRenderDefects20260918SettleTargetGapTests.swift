import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 2026-09-18 founder defect #4: "老的行波浪动画结束后所在的位置，和它成为上一行后被赋予的
// 位置对不上" — a row's OWN wave/spring settle endpoint (frame.origin.y once it has stopped
// visibly moving) does not match the target y a LATER reconcile cycle assigns to it.
//
// STATUS: measured, real, reproducible on a real surface + real lockstep clock — but NOT fully
// root-caused, and deliberately NOT fixed (research/repro-2026-09-18-lyrics-render-3d.md §4 has
// the full writeup). Two test-methodology traps were found and corrected while building this
// (see the two guard comments below) before a clean signal emerged: every row that has genuinely
// been active at least once, then left the active slot, later gets a SINGLE small (~1-6pt)
// further nudge, isolated from later, otherwise-unrelated line changes — `reFeed@settle` /
// `reFeed@nudge` never differ, ruling OUT the b12db38/Symptom-3 async-height-cache correction as
// the cause (that was this test's original hypothesis, disproven by its own instrumentation).
//
// Leading candidate mechanism (read, not proven): `LyricWaveTiming.seededTargetsForNaturalAdvance`
// (LyricsView.swift) unconditionally seeds `targets[index] = oldIndex` for EVERY row within
// `targetRadius` (a FIXED 14, regardless of song/panel — `LyricWaveTiming.targetRadius`) of
// EITHER the old or new active index on EVERY natural line change — including rows that already
// have a correct, settled target from a much earlier transition and are not otherwise involved.
// If that already-correct target differs from this transition's `oldIndex`, the row's spring
// gets a real, if usually tiny, backward-then-forward detour before the row's own (possibly
// zero-delay, possibly staggered) wave-schedule entry restores the true target. Reasoning through
// the arithmetic for a simple sequential single-step advance suggests this mostly cancels to a
// no-op, which does NOT match the nonzero deltas this test measures — so something is NOT fully
// accounted for in that reasoning; this is flagged as the most promising lead, not a confirmed
// root cause. A real 60+ row cast (so a row eventually falls OUTSIDE the fixed radius=14 and
// genuinely stops being touched by later transitions) is the recommended next experiment to
// separate "legitimate but currently-unbounded cross-transition wave reseeding" from a genuine,
// single-transition settle-vs-target divergence.
//
// This test drives a real NativeLyricsSurfaceView + real 60Hz lockstep clock through natural
// forward playback (English AND CJK, narrow panel width so some lines wrap to 2-3 visual lines
// while others stay single-line — real height variability, not a synthetic worst case; 2.5s
// gaps between lines to isolate transitions from each other in time), tracks every mounted row's
// frame.origin.y continuously, and flags a row that goes quiet (unchanged within 0.05pt for at
// least 0.5s) after genuinely having left the active slot at least once, then moves again by
// more than 0.3pt.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsRenderDefects20260918SettleTargetGapTests: XCTestCase {
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

    /// A DELIBERATELY naive, never-updated external height estimate (constant single-line
    /// height for every row, regardless of actual wrap) — worst-case stand-in for the real app's
    /// two-hop-async SwiftUI height cache, maximizing the chance of exercising the internal
    /// height-correction re-feed path this test is probing.
    private let naiveRowHeight: CGFloat = 42

    @MainActor
    private func config(rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = naiveRowHeight }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 3.0, hasSyllableSync: true,
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

    /// English lines with real length variability at a narrow panel — some wrap 1 line, some 2-3.
    private func englishRows() -> [LayerBackedLyricRow] {
        let texts = [
            "hi", "a short line here", "this one is considerably longer and should wrap to two lines",
            "ok", "another medium length line for good measure", "short",
            "a genuinely long line of lyrics that will definitely wrap across three separate visual lines at this width",
            "fin", "mid length text goes here too", "y",
        ]
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for (i, text) in texts.enumerated() {
            let words = text.split(separator: " ").map(String.init)
            var t = start
            var lyricWords: [LyricWord] = []
            for w in words {
                lyricWords.append(LyricWord(word: w + " ", startTime: t, endTime: t + 0.3))
                t += 0.3
            }
            let line = LyricLine(text: text, startTime: start, endTime: max(t, start + 0.3), words: lyricWords)
            rows.append(row(for: line, index: i))
            // A large, realistic gap (real songs run several seconds between lines) so each
            // natural line-change's wave has time to fully propagate and settle before the
            // NEXT transition starts — otherwise overlapping wave ripples from back-to-back
            // transitions would be indistinguishable from a genuine post-settle re-nudge.
            start = line.endTime + 2.5
        }
        return rows
    }

    /// CJK lines, same length-variability idea.
    private func cjkRows() -> [LayerBackedLyricRow] {
        let texts = [
            "你好", "今天天氣真好", "這是一句會換行的比較長的中文歌詞內容測試文字",
            "嗯", "又一句普通長度的歌詞", "短句",
            "這是一句非常長的中文歌詞一定會在這個寬度下換成三行文字內容測試測試測試",
            "完", "中等長度的歌詞句子", "喔",
        ]
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for (i, text) in texts.enumerated() {
            var t = start
            var lyricWords: [LyricWord] = []
            for c in text {
                lyricWords.append(LyricWord(word: String(c), startTime: t, endTime: t + 0.25))
                t += 0.25
            }
            let line = LyricLine(text: text, startTime: start, endTime: max(t, start + 0.25), words: lyricWords)
            rows.append(row(for: line, index: i))
            start = line.endTime + 2.5
        }
        return rows
    }

    private struct ReNudge {
        let rowIndex: Int
        let t: TimeInterval
        let settledY: CGFloat
        let nudgedY: CGFloat
        let delta: CGFloat
        let reFeedCountAtSettle: Int
        let reFeedCountAtNudge: Int
    }

    @MainActor
    private func measureSettleThenNudge(rows: [LayerBackedLyricRow], label: String) -> [ReNudge] {
        let panelWidth: CGFloat = 220 // narrow — forces real wrap variability
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 700))
        host(surface, NSSize(width: panelWidth, height: 700))
        let mc = MusicController(preview: true)
        mc.duration = rows.last!.displayLine.line.endTime + 5
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        var lastY: [Int: CGFloat] = [:]
        var stableSinceTick: [Int: Int] = [:]
        var settledY: [Int: CGFloat] = [:]
        var settledReFeedCount: [Int: Int] = [:]
        var alreadyFlagged: Set<Int> = []
        var hasEverBeenActive: Set<Int> = []
        var results: [ReNudge] = []
        let stableTicksRequired = 30 // 0.5s at 60Hz

        var tickIndex = 0
        func sample(_ t: TimeInterval) {
            tickIndex += 1
            if let active = surface.debugNativeSemanticIndex { hasEverBeenActive.insert(active) }
            for idx in 0..<rows.count {
                guard let v = surface.debugRowView(forIndex: idx) else { continue }
                let y = v.frame.origin.y
                let prev = lastY[idx]
                lastY[idx] = y
                guard let prev else { continue }
                let dy = abs(y - prev)
                // Only arm settle-tracking once this row has GENUINELY left the active slot —
                // `debugNativeSemanticIndex != idx` — not merely once its own words finished
                // playing. `NativeLyricsTimelinePolicy.liveDisplayIndex` keeps the last-started
                // line "current" for the whole gap until the NEXT line's own start time (so a
                // wide inter-line gap, needed to isolate transitions from each other — see the
                // 2.5s spacing in englishRows/cjkRows — otherwise reads as an early false
                // "settled at the anchor" while the row is still legitimately active there).
                // AND only once it has actually BEEN active at least once — a row far ahead in
                // the content is "not current" from tick 1 purely because playback hasn't
                // reached it yet, and its cold-mount-to-first-real-position settle (a separate,
                // already-documented one-time appear-window effect, not this defect) must not be
                // confused with "was active, demoted, and re-nudged". Both gates were added after
                // this test's own first two iterations produced exactly these two false-positive
                // shapes — left in as a record of what was ruled out, not speculation.
                let isGenuinelyAnOldRow = surface.debugNativeSemanticIndex != idx && hasEverBeenActive.contains(idx)
                guard isGenuinelyAnOldRow else {
                    stableSinceTick[idx] = tickIndex
                    settledY[idx] = nil
                    continue
                }
                if dy <= 0.05 {
                    let since = stableSinceTick[idx] ?? tickIndex
                    stableSinceTick[idx] = since
                    if tickIndex - since >= stableTicksRequired, settledY[idx] == nil {
                        settledY[idx] = y
                        settledReFeedCount[idx] = surface.debugHeightCorrectionReFeedCount
                    }
                } else {
                    stableSinceTick[idx] = tickIndex
                    if let sY = settledY[idx], !alreadyFlagged.contains(idx), dy > 0.3 {
                        alreadyFlagged.insert(idx)
                        results.append(ReNudge(
                            rowIndex: idx, t: t, settledY: sY, nudgedY: y, delta: y - sY,
                            reFeedCountAtSettle: settledReFeedCount[idx] ?? -1,
                            reFeedCountAtNudge: surface.debugHeightCorrectionReFeedCount
                        ))
                    }
                    // A row that moves again after settling starts a fresh settle window —
                    // clear its recorded settle point so a THIRD nudge can also be caught.
                    settledY[idx] = nil
                }
            }
        }

        func tick(_ t: TimeInterval) {
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
            surface.configure(config(rows: rows, current: current, mc: mc, width: panelWidth))
            surface.layoutSubtreeIfNeeded()
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            surface.debugTick(displayInterval: 1.0 / 60.0)
            sample(t)
        }

        var t: TimeInterval = 0.02
        let end = rows.last!.displayLine.line.endTime + 3
        while t < end {
            tick(t)
            t += 1.0 / 60.0
        }

        return results
    }

    // 2026-09-18 (coordinator instruction): known-red until the root cause is fixed. Gated with
    // XCTExpectFailure so this stays green in ordinary CI/main-line runs (no permanently-red
    // test blocking the branch) while STILL keeping the real assertion — XCTExpectFailure fails
    // the test if the wrapped block unexpectedly PASSES, so this cannot silently rot into a
    // no-op once the underlying bug is fixed. Remove the wrapper (leaving the bare assertion)
    // the moment the fix lands.
    @MainActor
    func test_english_settledRowNeverNudgesAgainAfterGoingQuiet() {
        XCTExpectFailure("Defect #4: known post-settle nudge, not yet root-caused — see research/repro-2026-09-18-lyrics-render-3d.md §4") {
            let results = measureSettleThenNudge(rows: englishRows(), label: "EN")
            XCTAssertTrue(
                results.isEmpty,
                "English: a row's frame.origin.y moved again after settling for ≥0.5s. "
                    + results.map {
                        "row=\($0.rowIndex) t=\(String(format: "%.3f", $0.t)) settledY=\(String(format: "%.2f", $0.settledY)) "
                            + "nudgedY=\(String(format: "%.2f", $0.nudgedY)) delta=\(String(format: "%.2f", $0.delta)) "
                            + "reFeed@settle=\($0.reFeedCountAtSettle) reFeed@nudge=\($0.reFeedCountAtNudge)"
                    }.joined(separator: " | ")
            )
        }
    }

    @MainActor
    func test_cjk_settledRowNeverNudgesAgainAfterGoingQuiet() {
        XCTExpectFailure("Defect #4: known post-settle nudge, not yet root-caused — see research/repro-2026-09-18-lyrics-render-3d.md §4") {
            let results = measureSettleThenNudge(rows: cjkRows(), label: "CJK")
            XCTAssertTrue(
                results.isEmpty,
                "CJK: a row's frame.origin.y moved again after settling for ≥0.5s. "
                    + results.map {
                        "row=\($0.rowIndex) t=\(String(format: "%.3f", $0.t)) settledY=\(String(format: "%.2f", $0.settledY)) "
                            + "nudgedY=\(String(format: "%.2f", $0.nudgedY)) delta=\(String(format: "%.2f", $0.delta)) "
                            + "reFeed@settle=\($0.reFeedCountAtSettle) reFeed@nudge=\($0.reFeedCountAtNudge)"
                    }.joined(separator: " | ")
            )
        }
    }
}
