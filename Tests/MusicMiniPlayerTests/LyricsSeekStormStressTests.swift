import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Seek STORM — large forward/back jumps × N.
//
// Natural playback only ever advances the semantic index by 0 or +1.
// A progress-bar storm is the opposite: explicit discontinuities that
// must SNAP (not wave), keep the active index inside the row array,
// keep sweep progress in [0, 1], and not leave the visible/warmup
// window hanging on a stale index.
//
// Headless, injected clocks. Founder rule 2026-08-21.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsSeekStormStressTests: XCTestCase {

    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        hostedSurfaces.forEach { $0.stopAnimations() }
        hostedSurfaces.removeAll()
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    private func wordRows(_ count: Int, span: TimeInterval = 2.0) -> [LayerBackedLyricRow] {
        (0..<count).map { i in
            let s = TimeInterval(i) * span
            let e = s + span
            let d = (e - s) / 3
            let lyric = LyricLine(
                text: "storm line \(i) words here",
                startTime: s, endTime: e,
                words: [
                    LyricWord(word: "storm ", startTime: s, endTime: s + d),
                    LyricWord(word: "line ", startTime: s + d, endTime: s + 2 * d),
                    LyricWord(word: "\(i)", startTime: s + 2 * d, endTime: e)
                ]
            )
            let dl = DisplayLyricLine(id: "s\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: lyric)
            return LayerBackedLyricRow(
                id: dl.id, index: i, displayLine: dl, sourceLine: lyric,
                isPrelude: false, preludeEndTime: e, interlude: nil
            )
        }
    }

    // ── Classifier + timeline stay in bounds across a storm ─────────────

    func test_explicitLargeSeeks_areClassifiedAsSeek_andNeverResyncHolds() {
        let jumps: [(from: TimeInterval, to: TimeInterval)] = [
            (2, 80), (80, 4), (4, 120), (120, 0.5), (0.5, 95), (95, 12)
        ]
        for jump in jumps {
            XCTAssertFalse(
                NativeLyricsSeekClassifier.isResyncRewind(
                    previousPlaybackTime: jump.from, playbackTime: jump.to,
                    explicitSeek: true, tolerance: 0.5
                ),
                "an explicit seek must never be held as jitter (\(jump.from)→\(jump.to))"
            )
            let step = NativeLyricsSeekClassifier.monotonicTime(
                previous: jump.from, rawTime: jump.to, explicitSeek: true, seekThreshold: 0.5
            )
            XCTAssertEqual(step.step, .seek)
            XCTAssertEqual(step.value, jump.to, accuracy: 0.0001)
        }
    }

    func test_timeline_afterHundredsOfSeeks_indexAndSweepStayInBounds() {
        let rows = wordRows(40)
        let lastStart = rows.last!.displayLine.line.startTime
        var previous: NativeLyricsTimelinePolicy.AMLLState?
        // Storm: 80 large jumps, mixing past-the-end, before-first, and mid-word.
        let targets: [TimeInterval] = (0..<80).map { n in
            switch n % 8 {
            case 0: return 0
            case 1: return lastStart + 8
            case 2: return lastStart / 2
            case 3: return 0.4
            case 4: return lastStart - 0.1
            case 5: return TimeInterval(n) * 1.7
            case 6: return -1
            default: return lastStart + TimeInterval(n)
            }
        }
        for (n, t) in targets.enumerated() {
            let live = NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)
            XCTAssertTrue(rows.indices.contains(live), "live \(live) out of \(rows.count) at t=\(t) n=\(n)")
            if let prev = previous {
                let isSeek = NativeLyricsSeekClassifier.isSeek(
                    previousIndex: prev.semanticIndex, liveIndex: live, explicitSeek: true
                )
                XCTAssertTrue(isSeek, "explicit storm jump must classify as seek (n=\(n))")
            }
            let state = NativeLyricsTimelinePolicy.amllState(
                at: t, rows: rows, fallback: 0, previous: previous, isSeeking: true
            )
            XCTAssertTrue(rows.indices.contains(state.semanticIndex), "semantic \(state.semanticIndex) n=\(n)")
            XCTAssertTrue(rows.indices.contains(state.scrollToIndex), "scroll \(state.scrollToIndex) n=\(n)")
            XCTAssertTrue(state.hotGroups.isSubset(of: Set(rows.map(\.index))))
            XCTAssertTrue(state.bufferedGroups.isSubset(of: Set(rows.map(\.index))))

            let active = rows[state.semanticIndex].sourceLine
            let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
                line: active, currentTime: t, isActive: true, showTranslation: false
            ))
            XCTAssertGreaterThanOrEqual(plan.mainSweepProgress, 0)
            XCTAssertLessThanOrEqual(plan.mainSweepProgress, 1)
            previous = state
        }
    }

    func test_visibleSelector_afterSeekToTailThenHead_doesNotDanglePastArray() {
        let all = Array(0..<40)
        let tail = NativeLyricsVisibleRowSelector.visibleIndices(
            allIndices: all, currentIndex: 39, activeTargetIndices: [39], radius: 12
        )
        XCTAssertFalse(tail.isEmpty)
        XCTAssertTrue(tail.allSatisfy { all.contains($0) })
        XCTAssertFalse(tail.contains(where: { $0 < 0 || $0 >= 40 }))

        let head = NativeLyricsVisibleRowSelector.visibleIndices(
            allIndices: all, currentIndex: 0, activeTargetIndices: [0], radius: 12
        )
        XCTAssertTrue(head.allSatisfy { all.contains($0) })
        XCTAssertLessThanOrEqual(head.count, 13)

        // A seek target past the last index must still only yield in-range rows.
        let pastEnd = NativeLyricsVisibleRowSelector.visibleIndices(
            allIndices: all, currentIndex: 80, activeTargetIndices: [39], radius: 12
        )
        XCTAssertTrue(pastEnd.allSatisfy { all.contains($0) }, "warmup window must not invent out-of-range indices")
    }

    // ── Hosted surface: clock jumps, no hang, no OOB ────────────────────

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        if let surface = view as? NativeLyricsSurfaceView {
            hostedSurfaces.append(surface)
        }
    }

    @MainActor
    private func config(
        _ rows: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "Seek Storm", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: true, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil,
            directSnapRequest: NativeLyricsDirectSnapRequest(displayIndex: current, reason: .seek),
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    @MainActor
    func test_hostedSurface_forwardAndBackSeekStorm_indexSweepWarmupStayBounded() {
        let rows = wordRows(24)
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 3_000
        var date = Date(timeIntervalSinceReferenceDate: 710_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let lastStart = rows.last!.displayLine.line.startTime
        let storm: [TimeInterval] = (0..<60).map { n in
            n % 2 == 0 ? (n % 4 == 0 ? lastStart + 1 : lastStart * 0.8) : (n % 6 == 1 ? 0.3 : 2.0)
        }
        for (n, t) in storm.enumerated() {
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let live = NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)
            XCTAssertTrue(rows.indices.contains(live), "n=\(n) t=\(t)")
            surface.configure(config(rows, current: live, mc: mc))
            surface.layoutSubtreeIfNeeded()
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            surface.debugTick(displayInterval: 1.0 / 60.0)

            if let sem = surface.debugNativeSemanticIndex {
                XCTAssertTrue(rows.indices.contains(sem), "semantic \(sem) n=\(n)")
            }
            if let rowView = surface.debugRowView(forIndex: live) {
                if let applied = rowView.debugLastMainAppliedProgress {
                    XCTAssertGreaterThanOrEqual(applied, -0.01, "n=\(n)")
                    XCTAssertLessThanOrEqual(applied, 1.01, "n=\(n)")
                }
            }
            XCTAssertLessThanOrEqual(surface.debugMountedRowCount, 40,
                                     "visible+warmup window must not mount the whole storm set (n=\(n))")
            XCTAssertLessThanOrEqual(surface.debugReusePoolCount, 80)
        }
    }
}
