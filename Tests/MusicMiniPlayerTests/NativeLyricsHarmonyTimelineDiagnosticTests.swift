//
//  NativeLyricsHarmonyTimelineDiagnosticTests.swift
//
//  DIAGNOSTIC drive for the user report (2026-07-12): "harmony lyrics stutter up and
//  down" on Puzzle — Meiko Nakahara. The real NetEase timeline (from the app's disk
//  cache) contains a ZERO-DURATION backing-vocal line sharing its instant with the next
//  line — the flattened remnant of a simultaneous harmony part:
//
//    23  156.10-157.98  助けて
//    24  157.98-157.98  （I want you）      <- zero duration, same instant as 25
//    25  157.98-163.28  恋は
//    26  163.36-165.93  切ないラビリンス
//
//  This drives the REAL surface over that window at 1x and asserts the scroll motion is
//  monotone: each row's Y must never reverse direction beyond jitter while playback moves
//  strictly forward. A reversal = the "stutters up AND down" the user sees.
//

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

final class NativeLyricsHarmonyTimelineDiagnosticTests: XCTestCase {

    private var hostWindow: NSWindow?
    override func tearDown() { hostWindow?.orderOut(nil); hostWindow = nil; super.tearDown() }

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

    /// The verbatim Puzzle window (shifted -150s so the drive starts near t=0):
    /// real line index, start, end, text. Word timings synthesized as an even split —
    /// the stutter mechanism is line-window driven, not word driven.
    private func puzzleRows() -> [LayerBackedLyricRow] {
        let spec: [(TimeInterval, TimeInterval, String)] = [
            (1.42, 5.26, "迷路で立ちすくむわ"),      // real 151.42-155.26
            (6.10, 7.98, "助けて"),                  // real 156.10-157.98
            (7.98, 7.98, "（I want you）"),          // real 157.98-157.98 ZERO DURATION
            (7.98, 13.28, "恋は"),                   // real 157.98-163.28
            (13.36, 15.93, "切ないラビリンス"),      // real 163.36-165.93
            (16.08, 18.41, "You are not so hot to me"),
            (18.64, 21.30, "I can't wait for you"),
        ]
        return spec.enumerated().map { index, item in
            let (s, e, text) = item
            let effectiveEnd = max(e, s + 0.01)
            let chars = Array(text)
            let per = max(0.01, (effectiveEnd - s) / Double(max(1, chars.count)))
            let words = chars.enumerated().map { i, ch in
                LyricWord(word: String(ch), startTime: s + Double(i) * per, endTime: min(effectiveEnd, s + Double(i + 1) * per))
            }
            let line = LyricLine(text: text, startTime: s, endTime: e, words: words)
            let dl = DisplayLyricLine(id: "pz\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(_ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 250, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 3, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "Puzzle", artist: "Meiko Nakahara", album: "Puzzle", duration: 246),
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

    @MainActor
    private func drive(
        surface: NativeLyricsSurfaceView,
        musicController: MusicController,
        rows: [LayerBackedLyricRow],
        from startPlaybackTime: TimeInterval,
        duration: TimeInterval
    ) {
        let frameInterval = 1.0 / 60.0
        let frameCount = max(1, Int((duration / frameInterval).rounded(.up)))
        for i in 0..<frameCount {
            let playbackTime = startPlaybackTime + TimeInterval(i) * frameInterval
            musicController.syncPlaybackClock(to: playbackTime, playing: true)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: musicController))
            RunLoop.main.run(until: Date().addingTimeInterval(frameInterval))
        }
    }

    /// Pure policy level: inside the hole between the sibling's real end (13.28) and the
    /// next line's start (13.36), the zero-duration harmony line must NOT be the only
    /// surviving hot row — its window rides its co-starting sibling, so the hole has no
    /// hot rows and semanticIndex stays on the latest-started line (no regression).
    func test_zeroDurationHarmonyLine_windowRidesItsSibling() {
        let rows = puzzleRows()
        let state = NativeLyricsTimelinePolicy.amllState(
            at: 13.31, rows: rows, fallback: 3, previous: nil, isSeeking: false
        )
        XCTAssertFalse(state.hotGroups.contains(2),
                       "zero-duration harmony line must expire with its co-starting sibling (13.28)")
        XCTAssertEqual(state.semanticIndex, 3,
                       "the hole between sibling end and next start keeps the latest-started line")
        // While BOTH parts are live, the pair is hot together and the REAL line leads.
        let live = NativeLyricsTimelinePolicy.amllState(
            at: 10.0, rows: rows, fallback: 3, previous: nil, isSeeking: false
        )
        XCTAssertTrue(live.hotGroups.isSuperset(of: [2, 3]), "harmony pair is hot together while live")
        XCTAssertEqual(live.semanticIndex, 3, "the real (co-starting) line stays the primary")
    }

    /// User 2026-07-13: 和声应该同时播放 — a backing-vocal line (fully bracket-wrapped,
    /// the convention every source uses for background parts) must LIGHT UP alongside the
    /// melody but never CLAIM the primary slot: the scroll and the sweep stay on the
    /// melody line, so a 0.4s "（I want you）" no longer yanks the anchor down and back.
    func test_backingVocalLine_lightsSimultaneously_neverClaimsPrimary() {
        // Call-response pattern from Puzzle (shifted): melody A, bracketed backing, melody B.
        let spec: [(TimeInterval, TimeInterval, String)] = [
            (0.0, 3.0, "眠れないの"),
            (3.0, 3.44, "（I want you）"),
            (3.44, 8.0, "愛してるよと言って"),
        ]
        let rows = spec.enumerated().map { index, item -> LayerBackedLyricRow in
            let (s, e, text) = item
            let line = LyricLine(text: text, startTime: s, endTime: e)
            let dl = DisplayLyricLine(id: "bv\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }

        // Inside the backing window: it is HOT (lights up as harmony) but the primary
        // slot stays on the latest melody line — no anchor jump onto the 0.4s part.
        let during = NativeLyricsTimelinePolicy.amllState(
            at: 3.2, rows: rows, fallback: 0, previous: nil, isSeeking: false
        )
        XCTAssertTrue(during.hotGroups.contains(1), "backing part lights up while it is live")
        XCTAssertEqual(during.semanticIndex, 0, "the melody line keeps the primary slot")
        XCTAssertNotEqual(during.scrollToIndex, 1, "the scroll never targets the backing part")

        // After the backing window: primary advances to melody B directly.
        let after = NativeLyricsTimelinePolicy.amllState(
            at: 3.6, rows: rows, fallback: 0, previous: during, isSeeking: false
        )
        XCTAssertEqual(after.semanticIndex, 2, "primary hands off melody-to-melody")

        // ASCII brackets are the same convention.
        XCTAssertTrue(NativeLyricsTimelinePolicy.isBackingVocalText("(ooh ooh)"))
        XCTAssertTrue(NativeLyricsTimelinePolicy.isBackingVocalText(" （I want you） "))
        XCTAssertFalse(NativeLyricsTimelinePolicy.isBackingVocalText("普通歌词 (with aside)"))
        XCTAssertFalse(NativeLyricsTimelinePolicy.isBackingVocalText("()"))
    }

    @MainActor
    func test_zeroDurationHarmonyLine_scrollStaysMonotone() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        surface.debugSkipDedupe = true
        let mc = MusicController(preview: true)
        mc.duration = 246
        mc.isPlaying = true
        let rows = puzzleRows()

        // Settle on the line BEFORE the harmony pair.
        mc.syncPlaybackClock(to: 6.3, playing: true)
        surface.configure(config(rows, current: 1, mc: mc))
        surface.layoutSubtreeIfNeeded()
        drive(surface: surface, musicController: mc, rows: rows, from: 6.3, duration: 0.8)

        surface.debugResetCensus()
        surface.debugCensusEnabled = true
        // Cross the zero-duration harmony instant (7.98) and the following handoff (13.36).
        drive(surface: surface, musicController: mc, rows: rows, from: 7.5, duration: 7.0)

        // Playback moved strictly forward, so every row's Y may only move UP (decreasing
        // in flipped coords the rows scroll upward) — count direction reversals beyond a
        // 1pt jitter allowance, and semantic-index regressions.
        let semantics = surface.debugSemanticTrace
        var semanticRegressions = 0
        for pair in zip(semantics, semantics.dropFirst()) where pair.1 < pair.0 {
            semanticRegressions += 1
        }

        var reversalReport: [String] = []
        for (index, track) in surface.debugCensusByIndex.sorted(by: { $0.key < $1.key }) {
            let y = track.y
            guard y.count > 8 else { continue }
            var reversals = 0
            var maxReversalMagnitude: CGFloat = 0
            var direction: CGFloat = 0
            for pair in zip(y, y.dropFirst()) {
                let step = pair.1 - pair.0
                guard abs(step) > 1.0 else { continue }
                let sign: CGFloat = step > 0 ? 1 : -1
                if direction != 0 && sign != direction {
                    reversals += 1
                    maxReversalMagnitude = max(maxReversalMagnitude, abs(step))
                }
                direction = sign
            }
            if reversals > 0 {
                reversalReport.append("row \(index): \(reversals) reversal(s), max step \(String(format: "%.1f", maxReversalMagnitude))pt")
            }
        }

        print("HARMONY DIAG semanticTrace=\(semantics.map(String.init).joined(separator: ","))")
        print("HARMONY DIAG reversals=\(reversalReport.joined(separator: " | "))")

        XCTAssertEqual(semanticRegressions, 0,
                       "semantic index must never regress while playback moves forward")
        XCTAssertTrue(reversalReport.isEmpty,
                      "rows bounced (up-down stutter) across the zero-duration harmony line:\n\(reversalReport.joined(separator: "\n"))")
    }
}
