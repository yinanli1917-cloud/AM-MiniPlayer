import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Prelude EDGE — full chain of a leading-ellipsis song, including the
// 2026-08-25 crash class (display-space length ≠ source-space length).
//
// Round 1 churn already hammered `LyricLayerRowBuilder` in isolation.
// This file drives the WHOLE chain the crash lived on:
//   processLyrics (injects ⋯) → display rows (may segment) → makeRows
//   → timeline at t=0 through first-real start → hosted surface ticks.
// Adversarial windows (stale 29-row display vs 3-line source, segmented
// CJK, firstReal past count) are reconfigured mid-prelude, the exact
// onChange shrink the SIGTRAP required.
//
// Headless, injected clocks. Founder rule 2026-08-21. Report-only on bugs.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsPreludeEdgeStressTests: XCTestCase {

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

    private func line(_ text: String, _ start: TimeInterval, _ end: TimeInterval, words: [LyricWord] = []) -> LyricLine {
        LyricLine(text: text, startTime: start, endTime: end, words: words)
    }

    private func display(_ sourceIndex: Int, segment: Int = 0, of count: Int = 1, line: LyricLine) -> DisplayLyricLine {
        DisplayLyricLine(
            id: "\(sourceIndex)-\(segment)",
            sourceIndex: sourceIndex,
            segmentIndex: segment,
            segmentCount: count,
            line: line
        )
    }

    // 君は1000% / 1986オメガトライブ shape: long prelude then Japanese verses.
    private func kimiWaRaw() -> [LyricLine] {
        [
            line("週末の夜はパーティ", 14.2, 18.0),
            line("君は1000%", 18.0, 22.4),
            line("輝く瞳で", 22.4, 26.0)
        ]
    }

    // ── 1. Parser → builder → prelude end-time (the full chain, not the scan alone)

    func test_processLyrics_injectsLeadingPrelude_andBuilderEndsItAtFirstRealStart() {
        let processed = LyricsParser.shared.processLyrics(kimiWaRaw())
        XCTAssertEqual(processed.firstRealLyricIndex, 1)
        XCTAssertGreaterThanOrEqual(processed.lyrics.count, 2)
        XCTAssertTrue(LyricPreludeGlyph.isEllipsis(processed.lyrics[0].text), "processLyrics must inject a leading ⋯")
        XCTAssertEqual(processed.lyrics[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(processed.lyrics[0].endTime, 14.2, accuracy: 0.001)

        let displayLines = processed.lyrics.enumerated().map { display($0.offset, line: $0.element) }
        let rows = LyricLayerRowBuilder.makeRows(
            from: displayLines,
            sourceLines: processed.lyrics,
            firstRealLyricIndex: processed.firstRealLyricIndex
        )
        XCTAssertEqual(rows.count, displayLines.count)
        XCTAssertTrue(rows[0].isPrelude)
        XCTAssertEqual(rows[0].preludeEndTime, 14.2, accuracy: 0.001,
                       "prelude must end when the first real source line starts, not at a guessed fallback")
        XCTAssertFalse(rows[1].isPrelude)
        XCTAssertEqual(rows[1].sourceLine.text, "週末の夜はパーティ")
    }

    func test_adversarialDisplayVsSource_midPrelude_neverTrapsAndKeepsInvariants() {
        // Crash window: applied 29 display rows while published source has already
        // shrunk to the 3-line 君は1000% payload. Drive that pair through the
        // builder hundreds of times with firstReal flipped past the source count.
        let source = [
            line("…", 0, 12),
            line("君は1000%", 12, 16),
            line("夢の中で", 16, 20)
        ]
        let staleDisplay: [DisplayLyricLine] = (0..<29).map { i in
            display(i, line: line(i == 0 ? "…" : "stale \(i)", TimeInterval(i), TimeInterval(i) + 1))
        }
        for n in 0..<200 {
            let firstReal = n % 5 == 0 ? source.count + 4 : 1
            let rows = LyricLayerRowBuilder.makeRows(
                from: staleDisplay,
                sourceLines: source,
                firstRealLyricIndex: firstReal
            )
            XCTAssertEqual(rows.count, 29, "iter \(n)")
            XCTAssertTrue(rows[0].isPrelude)
            XCTAssertFalse(rows[0].preludeEndTime.isNaN)
            XCTAssertFalse(rows[0].preludeEndTime.isInfinite)
            for (i, row) in rows.enumerated() {
                XCTAssertEqual(row.index, i)
                XCTAssertGreaterThanOrEqual(row.displayLine.sourceIndex, 0)
                if source.indices.contains(row.displayLine.sourceIndex) {
                    XCTAssertEqual(row.sourceLine.text, source[row.displayLine.sourceIndex].text)
                } else {
                    XCTAssertEqual(row.sourceLine.text, row.displayLine.line.text,
                                   "past-the-end display row must fall back, never trap")
                }
            }
        }
    }

    func test_segmentedCJKPrelude_displayLongerThanSource_preludeEndStaysFirstRealStart() {
        let source = [
            line("…", 0, 5),
            line("長い日本語の行を分割してディスプレイ行がソースより多くなる", 5, 20)
        ]
        var displayLines: [DisplayLyricLine] = [display(0, line: source[0])]
        for seg in 0..<6 {
            displayLines.append(display(1, segment: seg, of: 6, line: line("分段\(seg)", 5 + TimeInterval(seg) * 2.5, 7.5 + TimeInterval(seg) * 2.5)))
        }
        let rows = LyricLayerRowBuilder.makeRows(
            from: displayLines,
            sourceLines: source,
            firstRealLyricIndex: 1
        )
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows[0].isPrelude)
        XCTAssertEqual(rows[0].preludeEndTime, 5, accuracy: 0.001)
        XCTAssertEqual(rows.last?.displayLine.sourceIndex, 1)
        XCTAssertTrue(source.indices.contains(rows.last!.displayLine.sourceIndex))
    }

    func test_timeline_staysOnPreludeUntilFirstRealStart() {
        let processed = LyricsParser.shared.processLyrics(kimiWaRaw())
        let displayLines = processed.lyrics.enumerated().map { display($0.offset, line: $0.element) }
        let rows = LyricLayerRowBuilder.makeRows(
            from: displayLines,
            sourceLines: processed.lyrics,
            firstRealLyricIndex: processed.firstRealLyricIndex
        )
        // During the 14.2s prelude, liveDisplayIndex must not claim a real verse.
        let atPrelude = NativeLyricsTimelinePolicy.liveDisplayIndex(at: 3.0, rows: rows, fallback: 0)
        XCTAssertEqual(atPrelude, 0, "no real line has started — fallback (prelude row) is the only legal index")

        let justBefore = NativeLyricsTimelinePolicy.amllState(
            at: 14.19, rows: rows, fallback: 0, previous: nil, isSeeking: false
        )
        XCTAssertTrue(rows.indices.contains(justBefore.semanticIndex))
        XCTAssertTrue(rows.indices.contains(justBefore.scrollToIndex))

        let atFirstReal = NativeLyricsTimelinePolicy.amllState(
            at: 14.25, rows: rows, fallback: 0, previous: justBefore, isSeeking: false
        )
        XCTAssertEqual(atFirstReal.semanticIndex, 1, "crossing first-real start must promote the verse row")
        XCTAssertTrue(rows.indices.contains(atFirstReal.semanticIndex))
        XCTAssertFalse(rows[atFirstReal.semanticIndex].isPrelude)
    }

    // ── 2. Hosted surface: clock through the prelude, then a shrink reconfigure

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
        mc: MusicController,
        title: String
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: rows.contains { $0.sourceLine.hasSyllableSync },
            trackContext: DiagnosticTrackContext(title: title, artist: "1986オメガトライブ", album: "Another Summer", duration: 241),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: true, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 1,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    @MainActor
    func test_hostedSurface_clockThroughPreludeThenShrinkWindow_neverTraps() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 241
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 2_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let processed = LyricsParser.shared.processLyrics(kimiWaRaw())
        let alignedDisplay = processed.lyrics.enumerated().map { display($0.offset, line: $0.element) }
        let alignedRows = LyricLayerRowBuilder.makeRows(
            from: alignedDisplay,
            sourceLines: processed.lyrics,
            firstRealLyricIndex: processed.firstRealLyricIndex
        )

        // Stale 29-row display vs 3-line source — the crash-shaped shrink.
        let shrinkSource = [
            line("…", 0, 12),
            line("君は1000%", 12, 16),
            line("夢の中で", 16, 20)
        ]
        let staleDisplay: [DisplayLyricLine] = (0..<29).map { i in
            display(i, line: line(i == 0 ? "…" : "stale \(i)", TimeInterval(i), TimeInterval(i) + 1))
        }
        let staleRows = LyricLayerRowBuilder.makeRows(
            from: staleDisplay,
            sourceLines: shrinkSource,
            firstRealLyricIndex: 1
        )

        // Play through the prelude, then slam the shrink window, then land on aligned rows.
        let playbackTimes: [TimeInterval] = [0.2, 4.0, 10.0, 14.0, 14.3, 18.1]
        for (n, t) in playbackTimes.enumerated() {
            let useShrink = n == 3
            let rows = useShrink ? staleRows : alignedRows
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
            surface.configure(config(rows, current: current, mc: mc, title: "prelude-edge-\(n)"))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<4 {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                mc.syncPlaybackClock(to: t, playing: true, at: date)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
            if let sem = surface.debugNativeSemanticIndex {
                XCTAssertTrue(rows.indices.contains(sem), "semantic \(sem) out of \(rows.count) at t=\(t)")
            }
            XCTAssertLessThanOrEqual(surface.debugMountedRowCount, max(rows.count, 1) + 4)
            XCTAssertLessThanOrEqual(surface.debugReusePoolCount, 80)
        }
    }
}
