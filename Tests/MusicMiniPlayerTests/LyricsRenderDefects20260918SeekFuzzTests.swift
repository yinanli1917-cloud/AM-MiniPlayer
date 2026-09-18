import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 2026-09-18: founder defect #1 (highest priority, research/repro-2026-09-18-lyrics-render-3d.md
// §1) — repeatedly seeking back and forth on stage bundle 3d occasionally shows either the
// active row's whole line lit at once, or no highlight mask at all, for a syllable-synced line.
// Real-machine trace evidence (mask_trace_2026-09-17.jsonl, founder session, 「啟程」277.8s):
// `wholeLineHighlight` never fired even once across the whole session (the existing instrumented
// flag does not correspond to what the founder sees), but ONE genuine `expected/applied`
// mismatch WAS captured (row 10-0, word 8, expected=0.777 applied=0.0, immediately following a
// backward seek that jumped straight from row 0 to row 10) — self-corrected one mask_state
// sample later. `applyActiveMainPhase`'s `geometryReady` fallback (NativeLyricsRowView.swift
// ~1812) is DESIGNED to avoid a false "whole line lit" reading when a freshly-reused row's
// `mainBrightTextLayer` bounds are still zero, but its side effect is exactly a NO-mask frame
// (progress 0, bright layer hidden) for a row that legitimately expects a mid-word sweep. This
// is provably real but was observed to self-correct within one frame in the captured session —
// this fuzz test exists to find out whether it (or any other invariant violation) can persist
// for LONGER than a couple of frames under sustained random seeking, which the founder's
// real-world report describes.
//
// Deterministic, seeded random seeks (reproducible — same seed always produces the same
// sequence) on a real `NativeLyricsSurfaceView` + real (lockstep-injected) clock. Per-frame
// invariant, checked on the semantically active row whenever it is mid-word (comfortably away
// from a word boundary, avoiding legitimate edge ambiguity):
//   - the per-run (syllable) sweep must be engaged (not degraded to the whole-line fallback)
//   - applied progress must track expected progress within tolerance
//   - the bright/highlight overlay layer must actually be present
// A short grace window (a few ticks) after each seek absorbs the ALREADY-KNOWN, ALREADY-
// TOLERATED one-frame geometry-catch-up transient; anything that persists past the grace window
// is a real, reportable violation.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsRenderDefects20260918SeekFuzzTests: XCTestCase {
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

    /// A long CJK word-level song — real-shaped content (real lyric row count/word density) that
    /// covers enough duration for many minutes of random seeking to always land inside bounds.
    private func longCJKSong(lineCount: Int) -> [LayerBackedLyricRow] {
        let syllables = "啟程風景遠方回頭路上光影散落腳步聲裡藏著一整個夏天的故事還沒說完就已經"
        let chars = Array(syllables)
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for i in 0..<lineCount {
            var lyricWords: [LyricWord] = []
            var t = start
            let wordCount = 5 + (i % 4)
            for w in 0..<wordCount {
                let c = String(chars[(i * 7 + w) % chars.count])
                lyricWords.append(LyricWord(word: c, startTime: t, endTime: t + 0.35))
                t += 0.35
            }
            let text = lyricWords.map(\.word).joined()
            let line = LyricLine(text: text, startTime: start, endTime: t, words: lyricWords)
            rows.append(row(for: line, index: i))
            start = t + 0.3
        }
        return rows
    }

    /// Small deterministic xorshift PRNG — reproducible across runs (Swift's SystemRandomNumberGenerator
    /// is not seedable), so a failure here always reproduces with the same seed.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    @MainActor
    func test_sustainedRandomSeeking_maskNeverDesyncsBeyondAShortGeometryGrace() {
        let rows = longCJKSong(lineCount: 90) // ~90 * ~2.15s ≈ 190s of content
        let songDuration = rows.last!.displayLine.line.endTime
        let panelWidth: CGFloat = 360
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = songDuration
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        var rng = SeededRNG(state: 0x9E3779B97F4A7C15)

        struct Violation {
            let t: TimeInterval
            let rowIndex: Int
            let ticksSinceSeek: Int
            let expected: CGFloat
            let applied: CGFloat
            let perRunSweep: Bool
            let brightPresent: Bool
        }
        var violations: [Violation] = []
        let graceTicks = 3 // ~50ms at 60Hz — absorbs the known one-frame geometry-catch-up case
        var ticksSinceLastSeek = graceTicks + 1 // already past grace before the first seek

        func tick(_ t: TimeInterval) {
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
            surface.configure(config(rows: rows, current: current, mc: mc, width: panelWidth))
            surface.layoutSubtreeIfNeeded()
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            surface.debugTick(displayInterval: 1.0 / 60.0)

            ticksSinceLastSeek += 1
            guard ticksSinceLastSeek > graceTicks,
                  let idx = surface.debugNativeSemanticIndex,
                  rows.indices.contains(idx),
                  let view = surface.debugRowView(forIndex: idx),
                  rows[idx].displayLine.line.hasSyllableSync,
                  let expected = view.debugLastMainExpectedProgress,
                  expected > 0.05, expected < 0.95
            else { return }

            let applied = view.debugLastMainAppliedProgress ?? -1
            let perRunSweep = view.debugLastAppliedActivePerRunSweep
            let mismatch = abs(applied - expected) > 0.08
            // `debugLastMainBrightOverlayPresent` (mainBrightTextLayer.string != nil) is
            // deliberately NOT checked here: it only applies to the whole-line fallback sweep.
            // A per-run/tile-based sweep row (the normal case for syllable-synced content once
            // geometry is ready) legitimately keeps mainBrightTextLayer.string == nil the whole
            // time — its actual karaoke highlight lives in the separate per-glyph tile layers
            // (applyMainWordFloatGlyphLayers / mainBrightWordGlyphLayers), which is exactly what
            // `perRunSweep == true` already attests to. `!perRunSweep` for a syllable-synced row
            // with real word content mid-word IS the "no highlight mask at all" defect class
            // (the geometryReady==false fallback in applyActiveMainPhase); a progress mismatch
            // while perRunSweep IS true is a distinct tracking bug. (An earlier version of this
            // test also gated on brightPresent and flagged ~9300 FALSE positives — every normal
            // per-run row, including the very first tick of the very first line, before any seek
            // had even happened — because that flag is definitionally false for this whole class
            // of row; corrected here.)
            if !perRunSweep || mismatch {
                violations.append(Violation(
                    t: t, rowIndex: idx, ticksSinceSeek: ticksSinceLastSeek,
                    expected: expected, applied: applied,
                    perRunSweep: perRunSweep, brightPresent: view.debugLastMainBrightOverlayPresent
                ))
            }
        }

        // Warm up / mount before the fuzz loop starts.
        var t: TimeInterval = 0.05
        for _ in 0..<10 { tick(t); t += 1.0 / 60.0 }

        var nextSeekAt: TimeInterval = TimeInterval.random(in: 2...5, using: &rng)
        var elapsedSinceLastSeek: TimeInterval = 0
        let totalSimulatedSeconds: TimeInterval = 200 // ~3.3 simulated minutes of playback
        var simulated: TimeInterval = 0

        while simulated < totalSimulatedSeconds {
            tick(t)
            t += 1.0 / 60.0
            simulated += 1.0 / 60.0
            elapsedSinceLastSeek += 1.0 / 60.0

            if elapsedSinceLastSeek >= nextSeekAt {
                elapsedSinceLastSeek = 0
                nextSeekAt = TimeInterval.random(in: 2...5, using: &rng)
                let target = TimeInterval.random(in: 0...(songDuration - 1), using: &rng)
                mc.registerSeek()
                t = target
                ticksSinceLastSeek = 0
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Mask desync persisted beyond the \(graceTicks)-tick geometry-catch-up grace window "
                + "under sustained random seeking (\(violations.count) violation(s)). First few: "
                + violations.prefix(10).map {
                    "t=\(String(format: "%.3f", $0.t)) row=\($0.rowIndex) ticksSinceSeek=\($0.ticksSinceSeek) "
                        + "expected=\(String(format: "%.3f", $0.expected)) applied=\(String(format: "%.3f", $0.applied)) "
                        + "perRunSweep=\($0.perRunSweep) brightPresent=\($0.brightPresent)"
                }.joined(separator: " | ")
        )
    }
}
