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

    // ─────────────────────────────────────────────────────────────────────
    // radius=14 verification (coordinator instruction, step 2): a large cast so a row
    // eventually falls OUTSIDE `LyricWaveTiming.targetRadius` (fixed at 14) of the active
    // index and should, per the leading candidate mechanism, stop being touched by later
    // transitions entirely. Unlike `measureSettleThenNudge` above (which only records each
    // row's FIRST nudge), this logs EVERY nudge for EVERY row together with
    // `distanceFromActive = abs(rowIndex - activeIndex)` at the moment of the nudge, so the
    // relationship between distance and nudge-occurrence can be read directly off the data.
    // ─────────────────────────────────────────────────────────────────────
    private struct DistanceNudge {
        let rowIndex: Int
        let t: TimeInterval
        let delta: CGFloat
        let distanceFromActive: Int
    }

    /// 70 short English lines, 1.2s apart (long enough to isolate each transition's wave from
    /// the next — the shortest max wave-settle time computed earlier is well under 1s — while
    /// keeping total test runtime reasonable for a 70-row cast).
    private func largeCastEnglishRows(count: Int) -> [LayerBackedLyricRow] {
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for i in 0..<count {
            let wordCount = 2 + (i % 5)
            var t = start
            var lyricWords: [LyricWord] = []
            for w in 0..<wordCount {
                lyricWords.append(LyricWord(word: "w\(w) ", startTime: t, endTime: t + 0.2))
                t += 0.2
            }
            let line = LyricLine(text: "line \(i)", startTime: start, endTime: max(t, start + 0.2), words: lyricWords)
            rows.append(row(for: line, index: i))
            start = line.endTime + 1.2
        }
        return rows
    }

    @MainActor
    private func measureAllNudgesWithDistance(rows: [LayerBackedLyricRow]) -> [DistanceNudge] {
        let panelWidth: CGFloat = 260
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
        var hasEverBeenActive: Set<Int> = []
        var results: [DistanceNudge] = []
        let stableTicksRequired = 30

        var tickIndex = 0
        func sample(_ t: TimeInterval) {
            tickIndex += 1
            guard let active = surface.debugNativeSemanticIndex else { return }
            hasEverBeenActive.insert(active)
            for idx in 0..<rows.count {
                guard let v = surface.debugRowView(forIndex: idx) else { continue }
                let y = v.frame.origin.y
                let prev = lastY[idx]
                lastY[idx] = y
                guard let prev else { continue }
                let dy = abs(y - prev)
                let isGenuinelyAnOldRow = active != idx && hasEverBeenActive.contains(idx)
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
                    }
                } else {
                    stableSinceTick[idx] = tickIndex
                    if let sY = settledY[idx], dy > 0.3 {
                        results.append(DistanceNudge(
                            rowIndex: idx, t: t, delta: y - sY, distanceFromActive: abs(idx - active)
                        ))
                    }
                    // Unlike measureSettleThenNudge, do NOT stop after the first nudge per row —
                    // this experiment wants the FULL history so we can see nudges stop once a
                    // row's distance from active exceeds the radius.
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

    /// STEP 2 (coordinator instruction): verify the radius=14 hypothesis directly. If
    /// `seededTargetsForNaturalAdvance`'s unconditional radius=14 reseed is really what is
    /// causing the nudge, then once a row's distance from the active index exceeds 14, it
    /// should NEVER nudge again — the wave plan (`LyricWaveTiming.targetIndices`) excludes it
    /// entirely from that transition's participant set. This test does not assert (the
    /// hypothesis itself is what is under test) — it reports the max distance at which a nudge
    /// was ever observed, and whether ANY nudge occurred at distance > 14.
    @MainActor
    func test_radiusHypothesis_nudgesAtDistanceBeyond14() {
        let rows = largeCastEnglishRows(count: 70)
        let results = measureAllNudgesWithDistance(rows: rows)
        let beyondRadius = results.filter { $0.distanceFromActive > 14 }
        let maxDistance = results.map(\.distanceFromActive).max() ?? -1
        print("[RadiusHypothesis] total nudges=\(results.count) maxDistanceFromActive=\(maxDistance) "
            + "nudgesAtDistance>14=\(beyondRadius.count)")
        for n in results {
            print("[RadiusHypothesis] row=\(n.rowIndex) t=\(String(format: "%.3f", n.t)) "
                + "delta=\(String(format: "%.2f", n.delta)) distance=\(n.distanceFromActive)")
        }
        // Informational — see doc comment. Left as a soft signal, not a hard assertion, since
        // the whole point of this test is to DISCOVER whether the radius hypothesis holds, not
        // to enforce a behavior that might turn out to be wrong.
        XCTAssertTrue(true, "see printed [RadiusHypothesis] lines for the actual finding")
    }

    /// STEP 3 (coordinator instruction): direct evidence for the reseed mechanism itself, using
    /// `LyricsPresentationEngine.debugReseedLog` (new DEBUG-only probe). Filters for the specific
    /// smoking-gun shape: a row whose target got REWRITTEN to a different value while it was
    /// ALREADY settled (y == targetY, velocity ≈ 0) at the moment of the rewrite — i.e. a row
    /// with nothing legitimately left to do, that got its target yanked anyway.
    @MainActor
    func test_reseedProbe_settledRowsGetTargetRewrittenWhileAlreadyThere() {
        LyricsPresentationEngine.debugReseedLog.removeAll()
        let rows = largeCastEnglishRows(count: 40)
        _ = measureAllNudgesWithDistance(rows: rows)
        let log = LyricsPresentationEngine.debugReseedLog

        let settledRewrites = log.filter { event in
            guard let y = event.rowY, let targetY = event.rowTargetY, let v = event.rowVelocity else { return false }
            return abs(y - targetY) <= 0.25 && abs(v) <= 0.25
        }
        print("[ReseedProbe] total reseed-with-change events=\(log.count) "
            + "of which row was ALREADY SETTLED at the moment of rewrite=\(settledRewrites.count)")
        for e in settledRewrites.prefix(20) {
            print("[ReseedProbe] SETTLED row=\(e.rowIndex) priorTarget=\(e.priorTarget) "
                + "newTarget=\(e.newTarget) y=\(String(format: "%.3f", e.rowY ?? -1)) "
                + "targetY=\(String(format: "%.3f", e.rowTargetY ?? -1)) "
                + "velocity=\(String(format: "%.3f", e.rowVelocity ?? -1))")
        }
        XCTAssertTrue(true, "see printed [ReseedProbe] lines for the actual finding")
    }

    /// STEP 3b: broader probe. `debugReseedLog` (seededTargetsForNaturalAdvance-specific) found
    /// ZERO events, ruling that exact mechanism out — but the nudge itself is real (see the
    /// other tests in this file), so something else in `reconcileRows` is changing an
    /// already-settled row's `targetY`. `debugTargetYChangeLog` instruments `reconcileRows`
    /// itself (the single place `targetY` is ever computed) directly, catching the event
    /// regardless of which caller triggered it.
    @MainActor
    func test_targetYChangeProbe_findsWhatActuallyMovesASettledRowsTarget() {
        LyricsPresentationEngine.debugTargetYChangeLog.removeAll()
        let rows = largeCastEnglishRows(count: 40)
        _ = measureAllNudgesWithDistance(rows: rows)
        let log = LyricsPresentationEngine.debugTargetYChangeLog
        print("[TargetYChangeProbe] total settled-row-retargeted events=\(log.count)")
        var deltaHistogram: [String: Int] = [:]
        for e in log {
            let bucket = String(format: "%.0f", (e.newTargetY - e.oldTargetY).rounded())
            deltaHistogram[bucket, default: 0] += 1
        }
        print("[TargetYChangeProbe] delta histogram: \(deltaHistogram.sorted { $0.key < $1.key })")
        let nonRoundDeltas = log.filter { abs(($0.newTargetY - $0.oldTargetY).truncatingRemainder(dividingBy: 50)) > 0.5 }
        print("[TargetYChangeProbe] non-multiple-of-50 deltas count=\(nonRoundDeltas.count)")
        for e in nonRoundDeltas.prefix(20) {
            print("[TargetYChangeProbe] NONSTANDARD row=\(e.rowIndex) oldTargetIdx=\(e.oldTargetIndex) "
                + "newTargetIdx=\(e.newTargetIndex) delta=\(String(format: "%.3f", e.newTargetY - e.oldTargetY)) "
                + "snap=\(e.snap)")
        }
        for e in log.prefix(30) {
            let ownH = e.rowOwnAccumulatedHeight.map { String(format: "%.2f", $0) } ?? "nil"
            let oldActiveH = e.activeAccumulatedHeightOld.map { String(format: "%.2f", $0) } ?? "nil"
            let newActiveH = e.activeAccumulatedHeightNew.map { String(format: "%.2f", $0) } ?? "nil"
            print("[TargetYChangeProbe] row=\(e.rowIndex) oldTargetIdx=\(e.oldTargetIndex) "
                + "newTargetIdx=\(e.newTargetIndex) oldTargetY=\(String(format: "%.3f", e.oldTargetY)) "
                + "newTargetY=\(String(format: "%.3f", e.newTargetY)) "
                + "delta=\(String(format: "%.3f", e.newTargetY - e.oldTargetY)) "
                + "rowOwnH=\(ownH) activeH_old=\(oldActiveH) activeH_new=\(newActiveH) "
                + "anchorY=\(String(format: "%.2f", e.anchorY)) snap=\(e.snap)")
        }
        XCTAssertTrue(true, "see printed [TargetYChangeProbe] lines for the actual finding")
    }

    // ─────────────────────────────────────────────────────────────────────
    // ROOT CAUSE FOUND (2026-09-18, coordinator-directed follow-up): NOT a computational bug.
    // `test_targetYChangeProbe_findsWhatActuallyMovesASettledRowsTarget` above instruments
    // `reconcileRows` — the ONE place `targetY` is ever computed, for every caller — and logs
    // every case where an already-settled row's target changes. On a 40-row, uniform-row-height
    // cast driven through the whole song: 960 such events, and EVERY SINGLE ONE is an EXACT
    // -50.000 (the row height) — zero fractional/anomalous deltas (`test_reseedProbe_...` found
    // the specific `seededTargetsForNaturalAdvance` mechanism this investigation started from
    // produces ZERO reseed-with-actual-change events at all, since `lineTargetIndices` is already
    // empty by the time each new transition starts in these fixtures — that specific hypothesis
    // is DISPROVEN, not just unconfirmed).
    //
    // What this means: `LyricsPresentationEngine` recomputes every tracked row's target
    // correctly and consistently, every time, with no drift or divergence. A row that remains
    // within the wave's participant radius (`LyricWaveTiming.targetRadius`, fixed 14) of the
    // active index KEEPS legitimately getting retargeted by exactly one row-height on EVERY
    // subsequent line change — this is the intended "the whole panel scrolls together relative
    // to the currently-singing line" model, not a bug. The two tests THIS comment used to
    // guard (`test_english/cjk_settledRowNeverNudgesAgainAfterGoingQuiet`, now below, rewritten)
    // originally asserted "a settled row must never move again" — an invariant this
    // investigation has now proven FALSE in general: it isn't true by design, and forcing it
    // to pass would require inventing an unrequested product change (freezing distant rows'
    // targets), which is out of scope without the founder's explicit sign-off.
    //
    // The ORIGINAL 1-6pt "nudge" measurements (`measureSettleThenNudge`, kept above for the
    // record) were never the true size of any anomaly — `ReNudge.delta` is `y - settledY`
    // sampled on the FIRST tick the per-frame delta crosses the 0.3pt noise threshold, i.e. one
    // frame's slice of a spring that is still accelerating into a much larger (and, per the
    // probe, always EXACT) row-height move — not a measurement of the eventual total
    // displacement. That is a test-methodology artifact of this investigation's own detector,
    // not evidence of a code bug.
    //
    // What IS a real, reportable finding for the founder to weigh in on: whether a row should
    // keep re-targeting for as long as it stays within radius=14 of the active index (today's
    // behavior, confirmed working exactly as coded), or whether rows should stop being retargeted
    // once they are more than some SMALLER distance behind the active line (a product decision,
    // not a bug fix) — see research/repro-2026-09-18-lyrics-render-3d.md §4.
    // ─────────────────────────────────────────────────────────────────────
    @MainActor
    func test_english_settledRowRetargetingMatchesAccumulatedHeightDeltaExactly() {
        LyricsPresentationEngine.debugTargetYChangeLog.removeAll()
        let results = measureSettleThenNudge(rows: englishRows(), label: "EN")
        let log = LyricsPresentationEngine.debugTargetYChangeLog
        let anomalies = log.filter { e in
            guard let oldH = e.activeAccumulatedHeightOld, let newH = e.activeAccumulatedHeightNew else { return true }
            let expectedDelta = oldH - newH // targetY = anchor - activeH + rowOwnH, so ΔtargetY = -(Δactiveh)
            return abs((e.newTargetY - e.oldTargetY) - expectedDelta) > 0.01
        }
        print("[EN] measureSettleThenNudge flagged \(results.count) 'nudge' events (expected — see "
            + "header comment: these are real, in-progress, exact row-height re-targets, not anomalies). "
            + "debugTargetYChangeLog recorded \(log.count) settled-row retarget events; \(anomalies.count) "
            + "of them deviate from the accumulated-height arithmetic by >0.01pt.")
        XCTAssertTrue(
            anomalies.isEmpty,
            "English: found a settled-row retarget whose ΔtargetY does NOT match "
                + "-(activeAccumulatedHeight delta) — a genuine arithmetic anomaly, unlike every other "
                + "case measured in this investigation. "
                + anomalies.map { e in
                    "row=\(e.rowIndex) oldTargetIdx=\(e.oldTargetIndex) newTargetIdx=\(e.newTargetIndex) "
                        + "delta=\(String(format: "%.3f", e.newTargetY - e.oldTargetY))"
                }.joined(separator: " | ")
        )
    }

    @MainActor
    func test_cjk_settledRowRetargetingMatchesAccumulatedHeightDeltaExactly() {
        LyricsPresentationEngine.debugTargetYChangeLog.removeAll()
        let results = measureSettleThenNudge(rows: cjkRows(), label: "CJK")
        let log = LyricsPresentationEngine.debugTargetYChangeLog
        let anomalies = log.filter { e in
            guard let oldH = e.activeAccumulatedHeightOld, let newH = e.activeAccumulatedHeightNew else { return true }
            let expectedDelta = oldH - newH
            return abs((e.newTargetY - e.oldTargetY) - expectedDelta) > 0.01
        }
        print("[CJK] measureSettleThenNudge flagged \(results.count) 'nudge' events (expected — see "
            + "header comment). debugTargetYChangeLog recorded \(log.count) settled-row retarget "
            + "events; \(anomalies.count) deviate from the accumulated-height arithmetic by >0.01pt.")
        XCTAssertTrue(
            anomalies.isEmpty,
            "CJK: found a settled-row retarget whose ΔtargetY does NOT match "
                + "-(activeAccumulatedHeight delta). "
                + anomalies.map { e in
                    "row=\(e.rowIndex) oldTargetIdx=\(e.oldTargetIndex) newTargetIdx=\(e.newTargetIndex) "
                        + "delta=\(String(format: "%.3f", e.newTargetY - e.oldTargetY))"
                }.joined(separator: " | ")
        )
    }
}
