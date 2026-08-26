import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Track-switch CHURN — the 2026-08-25 crash class, as an integration stress.
//
// The SIGTRAP (`Range requires lowerBound <= upperBound`) lived on
// `LyricsView.onChange → refreshDisplayLineCache → makeLayerBackedRows`:
// DISPLAY-space indices mixed with a SOURCE-space array, including the
// window where published `lyrics` had already shrunk. Pure-function tests
// of `LyricPreludeResolution` cover the scan; this file drives the WHOLE
// builder (and a hosted native surface) through adversarial fixtures ×
// hundreds of rapid switches — prelude / none / word-level / line-level /
// segmented display>source / CJK prelude / empty — and asserts: no trap,
// display/source indices never used out of bounds without the fallback,
// display-state machine never left hanging in a search phase after a
// terminal or a content apply.
//
// Headless, injected clocks, no computer-use / no recording.
// Founder rule 2026-08-21 + stress-gap plan 2026-08-25.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsTrackChurnStressTests: XCTestCase {

    private let iterationsPerKind = 200

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

    // ── Fixtures ────────────────────────────────────────────────────────────

    private func line(_ text: String, _ start: TimeInterval, _ end: TimeInterval, words: [LyricWord] = []) -> LyricLine {
        LyricLine(text: text, startTime: start, endTime: end, words: words)
    }

    private func wordTimed(_ text: String, start: TimeInterval, end: TimeInterval) -> LyricLine {
        let tokens = text.split(separator: " ").map(String.init)
        let dur = max(0.01, end - start)
        let slice = dur / Double(max(tokens.count, 1))
        let words = tokens.enumerated().map { i, token in
            let s = start + slice * Double(i)
            return LyricWord(word: i == tokens.count - 1 ? token : token + " ", startTime: s, endTime: s + slice)
        }
        return line(text, start, end, words: words)
    }

    private func display(
        _ sourceIndex: Int,
        segment: Int = 0,
        of count: Int = 1,
        line: LyricLine
    ) -> DisplayLyricLine {
        DisplayLyricLine(
            id: "\(sourceIndex)-\(segment)",
            sourceIndex: sourceIndex,
            segmentIndex: segment,
            segmentCount: count,
            line: line
        )
    }

    /// Adversarial fixture kinds from the stress-gap plan. Each is a
    /// (source, display, firstReal) triple that historically mixed spaces.
    private enum Kind: String, CaseIterable {
        case displayLongerThanSource
        case preludeAtTail
        case sourceShrinksMidUpdate
        case empty
        case preludeOnly
        case cjkPrelude
        case segmentedCJK
        case wordAndLineMix
    }

    private func fixture(_ kind: Kind, seed: Int) -> (source: [LyricLine], display: [DisplayLyricLine], firstReal: Int) {
        switch kind {
        case .displayLongerThanSource:
            // 2 source lines, 8 display rows (segmented) — display index 7 past source count 2.
            let source = [
                line("real one", 1, 3),
                line("real two", 3, 5)
            ]
            let displayLines = (0..<8).map { i in
                display(min(i, 1), segment: i % 4, of: 4, line: line("seg \(i) seed \(seed)", TimeInterval(i), TimeInterval(i) + 1))
            }
            return (source, displayLines, 0)

        case .preludeAtTail:
            let source = [
                line("verse", 0, 2),
                line("chorus", 2, 4),
                line("…", 4, 10)
            ]
            let displayLines = source.enumerated().map { display($0.offset, line: $0.element) }
            return (source, displayLines, 0)

        case .sourceShrinksMidUpdate:
            // Crash window: display cache still has 29 rows (君は1000% applied 29L)
            // while published source has already shrunk to 3.
            let source = [
                line("…", 0, 12),
                line("君は1000%", 12, 16),
                line("夢の中で", 16, 20)
            ]
            let staleDisplay: [DisplayLyricLine] = (0..<29).map { i in
                let text = i == 0 ? "…" : "stale \(i)"
                return display(i, line: line(text, TimeInterval(i), TimeInterval(i) + 1))
            }
            return (source, staleDisplay, 1)

        case .empty:
            return ([], [], 0)

        case .preludeOnly:
            let source = [line("…", 0, 8)]
            return (source, [display(0, line: source[0])], 1)

        case .cjkPrelude:
            // 君は1000% / 1986オメガトライブ shape: leading ellipsis + Japanese lines.
            let source = [
                line("…", 0, 14.2),
                line("週末の夜はパーティ", 14.2, 18.0),
                line("君は1000%", 18.0, 22.4),
                line("輝く瞳で", 22.4, 26.0)
            ]
            let displayLines = source.enumerated().map { display($0.offset, line: $0.element) }
            return (source, displayLines, 1)

        case .segmentedCJK:
            let source = [
                line("…", 0, 5),
                line("長い日本語の行を分割してディスプレイ行がソースより多くなる", 5, 20)
            ]
            var displayLines: [DisplayLyricLine] = [display(0, line: source[0])]
            for seg in 0..<6 {
                displayLines.append(display(1, segment: seg, of: 6, line: line("分段\(seg)", 5 + TimeInterval(seg) * 2.5, 7.5 + TimeInterval(seg) * 2.5)))
            }
            return (source, displayLines, 1)

        case .wordAndLineMix:
            let source = [
                line("…", 0, 6),
                wordTimed("word timed karaoke line", start: 6, end: 10),
                line("plain line level row", 10, 14),
                line("…", 14, 20),
                wordTimed("after interlude words", start: 20, end: 24)
            ]
            let displayLines = source.enumerated().map { display($0.offset, line: $0.element) }
            return (source, displayLines, 1)
        }
    }

    private func assertIndexInvariants(
        rows: [LayerBackedLyricRow],
        source: [LyricLine],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(row.index, i, "row.index must be the display-space ordinal", file: file, line: line)
            XCTAssertGreaterThanOrEqual(row.displayLine.sourceIndex, 0, file: file, line: line)
            XCTAssertFalse(row.preludeEndTime.isNaN, file: file, line: line)
            XCTAssertFalse(row.preludeEndTime.isInfinite, file: file, line: line)
            if source.indices.contains(row.displayLine.sourceIndex) {
                XCTAssertEqual(
                    row.sourceLine.text,
                    source[row.displayLine.sourceIndex].text,
                    "in-bounds sourceIndex must read the source line, not a stale display copy",
                    file: file, line: line
                )
            }
            // Out-of-bounds sourceIndex is the shrink window: builder must fall back to the
            // display line rather than trap. Completing this assertion is the no-trap proof.
        }
    }

    // ── 1. Builder churn ────────────────────────────────────────────────────

    func test_adversarialFixtures_hundredsOfSwitches_neverTrapAndKeepIndexInvariants() {
        for kind in Kind.allCases {
            for n in 0..<iterationsPerKind {
                let (source, displayLines, firstReal) = fixture(kind, seed: n)
                // Flip firstReal around / past the source count on some iterations —
                // the shrink/desync window the crash lived in.
                let firstRealFlipped = n % 7 == 0 ? source.count + 3 : firstReal
                let rows = LyricLayerRowBuilder.makeRows(
                    from: displayLines,
                    sourceLines: source,
                    firstRealLyricIndex: firstRealFlipped
                )
                XCTAssertEqual(rows.count, displayLines.count, "kind=\(kind.rawValue) iter=\(n)")
                assertIndexInvariants(rows: rows, source: source)
            }
        }
    }

    func test_rapidKindRotation_preservesFallbackWhenDisplayRunsPastSource() {
        // Rotate kinds in one tight loop so source/display lengths keep jumping
        // (empty ↔ 29 stale rows ↔ CJK prelude), the exact onChange race shape.
        let kinds = Kind.allCases
        for n in 0..<(iterationsPerKind * kinds.count) {
            let kind = kinds[n % kinds.count]
            let (source, displayLines, firstReal) = fixture(kind, seed: n)
            let rows = LyricLayerRowBuilder.makeRows(
                from: displayLines,
                sourceLines: source,
                firstRealLyricIndex: firstReal
            )
            XCTAssertEqual(rows.count, displayLines.count)
            if let last = rows.last, last.displayLine.sourceIndex >= source.count {
                XCTAssertEqual(last.sourceLine.text, last.displayLine.line.text,
                               "past-the-end display row must fall back to its own line")
            }
            assertIndexInvariants(rows: rows, source: source)
        }
    }

    // ── 2. Display-state machine must not hang across mixed terminals ────────

    func test_mixedTrackOutcomes_displayStateNeverLeftHangingInSearch() {
        // Playlist of crash-class outcomes: content, confirmed miss, instrumental,
        // offline, then content again. After every terminal/content apply the
        // machine is NOT in a search phase — the spinner cannot be left spinning.
        var state = LyricsDisplayState.noLyrics
        let outcomes: [(apply: LyricsDisplayState, expectSearch: Bool)] = [
            (.searching, true),
            (.content, false),
            (.searching, true),
            (.deepSearching, true),
            (.noLyrics, false),
            (.searching, true),
            (.networkUnreachable, false),
            (LyricsDisplayState.dispatchingFetch(showingProvisionalContent: true), false),
            (.content, false),
            (LyricsDisplayState.dispatchingFetch(showingProvisionalContent: false), true),
            (.deepSearching, true),
            (.content, false),
        ]
        for (i, step) in outcomes.enumerated() {
            state = step.apply
            // Deep-search may only replace the plain spinner — never demote content
            // or a terminal. Simulate a backfill launch after every apply.
            let afterBackfill = state.enteringDeepSearch()
            if step.apply == .searching {
                XCTAssertEqual(afterBackfill, .deepSearching, "step \(i)")
            } else {
                XCTAssertEqual(afterBackfill, step.apply, "step \(i) must not demote")
            }
            XCTAssertEqual(afterBackfill.isSearchPhase, step.expectSearch, "step \(i) hanging?")
            state = afterBackfill
        }
        XCTAssertEqual(state, .content)
        XCTAssertFalse(state.isSearchPhase)
    }

    // ── 3. Hosted surface: rapid track-identity swaps with injected clocks ───

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
        title: String,
        hasSyllableSync: Bool,
        interludeAfterIndex: Int? = nil
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: hasSyllableSync,
            trackContext: DiagnosticTrackContext(title: title, artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: true, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: interludeAfterIndex,
            directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    @MainActor
    func test_hostedSurface_rapidTrackSwitches_neverTrapAndStayBounded() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 1_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let switches = 80
        let kinds = Kind.allCases
        for n in 0..<switches {
            let kind = kinds[n % kinds.count]
            let (source, displayLines, firstReal) = fixture(kind, seed: n)
            let rows = LyricLayerRowBuilder.makeRows(
                from: displayLines,
                sourceLines: source,
                firstRealLyricIndex: firstReal
            )
            let hasSyllable = source.contains { $0.hasSyllableSync }
            mc.syncPlaybackClock(to: 0.4, playing: true, at: date)
            surface.configure(config(
                rows, current: min(1, max(0, rows.count - 1)), mc: mc,
                title: "churn-\(n)-\(kind.rawValue)",
                hasSyllableSync: hasSyllable
            ))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<6 {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                mc.syncPlaybackClock(to: 0.4 + wall.truncatingRemainder(dividingBy: 8), playing: true, at: date)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
            XCTAssertLessThanOrEqual(surface.debugMountedRowCount, max(rows.count, 1) + 4,
                                     "mounted rows must not leak across track \(n)")
            XCTAssertLessThanOrEqual(surface.debugReusePoolCount, 80,
                                     "reuse pool is hard-capped at 80")
        }
    }
}
