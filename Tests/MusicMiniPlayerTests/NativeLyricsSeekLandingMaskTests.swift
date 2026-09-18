import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Stage bundle 3g item 2 (research/repro-2026-09-18-lyrics-render-3g.md): founder-reported
// "回跳后整行全亮无遮罩" (seek back, whole line lights up with no mask). 3f's random-seek fuzz (45
// seeds, 0 violations) and this file's own read-only code audit both failed to find the "whole
// line lit, mask missing" branch — but /tmp/nanopod_mask_trace.jsonl (real-device, 8825 records)
// showed 3 records where a line lands MID-WORD (word index 7/12/8 — from a seek or seek-back) with
// `perRunSweep=false, applied=0.0` on the LANDING frame, self-healing the next frame. That shape —
// a real Music.app ScriptingBridge-driven seek, landing exactly on the FIRST frame after the
// configuration/index change — is what the earlier exhaustive tests (NativeLyricsMaskExhaustiveHandoffTests)
// under-covered: they warm up to the target via many CONTINUOUS ticks before sampling, or drive the
// index change through a synthetic clock jump without ever bumping `MusicController.seekGeneration`
// (the real signal `.seek(to:)` sets). This file drives an EXPLICIT `mc.seek(to:)` (bumps
// seekGeneration, exactly like a real progress-bar drag or Music.app external seek) and samples
// ONLY the very first post-seek landing frame, across three scenarios the coordinator specified:
//   1. seek into the middle of a word
//   2. seek BACK into an already-fully-sung line
//   3. seek while paused
//
// The bad state under test (mirrors NativeLyricsMaskExhaustiveHandoffTests.isMaskLost): the bright
// (sung) overlay is VISIBLE, the per-word mask did NOT engage, and the model's own expected
// progress is not already ~done — i.e. "whole line lit, no mask, more singing still expected".
// Correct behavior per the coordinator's brief: the landing frame must be EITHER progress-correct
// (per-run sweep applied, matching expected) OR not shown at all (bright overlay hidden) — never
// bright-and-unmasked.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsSeekLandingMaskTests: XCTestCase {
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

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        if let surface = view as? NativeLyricsSurfaceView { hostedSurfaces.append(surface) }
    }

    /// Word-level rows, 4 words each, mirroring NativeLyricsMaskExhaustiveHandoffTests' fixture
    /// (this class deliberately does not import that file's private helpers — self-contained per
    /// this codebase's existing per-file-fixture convention).
    private func makeRows(_ n: Int, duration: TimeInterval = 3.2) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * duration, e = s + duration
            let w = (e - s) / 4
            let line = LyricLine(
                text: "line \(i) has four words", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "line ", startTime: s, endTime: s + w),
                    LyricWord(word: "\(i) ", startTime: s + w, endTime: s + 2 * w),
                    LyricWord(word: "has four ", startTime: s + 2 * w, endTime: s + 3 * w),
                    LyricWord(word: "words", startTime: s + 3 * w, endTime: e),
                ]
            )
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(_ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
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
    }

    private func isMaskLost(row: NativeLyricsRowView, expected: CGFloat) -> Bool {
        row.debugLastWholeLineHighlight || (
            row.debugLastMainBrightOverlayPresent
            && !row.debugLastAppliedActivePerRunSweep
            && expected < 0.9
            && row.debugMainBrightOpacity > 0.2
        )
    }

    /// Landing-frame correctness per the coordinator's brief: either the sweep is progress-correct,
    /// or nothing sung is shown at all. Never "bright and unmasked".
    private func isLandingFrameAcceptable(row: NativeLyricsRowView) -> Bool {
        guard let expected = row.debugLastMainExpectedProgress else { return true }
        if !isMaskLost(row: row, expected: expected) { return true }
        return false
    }

    /// Fixed step, deterministic wall/playback clocks driven entirely by the test — no real Date(),
    /// no RunLoop dependency on wall-clock timing. A class (not a struct) so `debugNowOverride`'s
    /// escaping closure can capture it by reference without an `inout` capture error.
    private final class Clocks {
        var wall: CFTimeInterval
        var date: Date
        init(wall: CFTimeInterval, date: Date) { self.wall = wall; self.date = date }
    }

    @MainActor
    private func makeHarness(rowCount: Int = 12) -> (surface: NativeLyricsSurfaceView, mc: MusicController, rows: [LayerBackedLyricRow], clocks: Clocks) {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(rowCount)
        surface.debugSkipDedupe = true
        let clocks = Clocks(wall: 6_000, date: Date(timeIntervalSinceReferenceDate: 950_000_000))
        return (surface, mc, rows, clocks)
    }

    @MainActor
    private func warmUp(
        surface: NativeLyricsSurfaceView, mc: MusicController, rows: [LayerBackedLyricRow],
        clocks: Clocks, toTime: TimeInterval, currentIndex: Int, ticks: Int
    ) {
        surface.debugNowOverride = { clocks.wall }
        mc.debugPlaybackClockDateProvider = { clocks.date }
        mc.syncPlaybackClock(to: toTime, playing: mc.isPlaying, at: clocks.date)
        surface.configure(config(rows, current: currentIndex, mc: mc))
        surface.layoutSubtreeIfNeeded()
        let step = 1.0 / 60.0
        for _ in 0..<ticks {
            clocks.wall += step
            clocks.date = clocks.date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: toTime, playing: mc.isPlaying, at: clocks.date)
            surface.debugTick(displayInterval: step)
        }
    }

    /// Performs a REAL seek (bumps `seekGeneration` via `mc.seek(to:)`, exactly like a progress-bar
    /// drag or an external Music.app seek) and captures ONLY the very first post-seek landing
    /// frame's row state — no warm-up ticks after the jump.
    @MainActor
    private func seekAndCaptureLandingFrame(
        surface: NativeLyricsSurfaceView, mc: MusicController, rows: [LayerBackedLyricRow],
        clocks: Clocks, seekTo: TimeInterval, expectedIndex: Int
    ) -> NativeLyricsRowView? {
        mc.seek(to: seekTo)
        // seek(to:) in preview mode already calls syncPlaybackClock; re-affirm the deterministic
        // date provider stays wired (seek's own internal syncPlaybackClock uses `Date()` by
        // default, so pin it explicitly to the harness clock right after).
        mc.syncPlaybackClock(to: seekTo, playing: mc.isPlaying, at: clocks.date)
        surface.configure(config(rows, current: expectedIndex, mc: mc))
        let step = 1.0 / 60.0
        clocks.wall += step
        clocks.date = clocks.date.addingTimeInterval(step)
        surface.debugTick(displayInterval: step)
        return surface.debugRowView(forIndex: expectedIndex)
    }

    // MARK: - Scenario 1: seek into the middle of a word

    @MainActor
    func test_seekIntoMidWord_landingFrameIsNeverBrightAndUnmasked() {
        let (surface, mc, rows, clocks) = makeHarness()
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        // Warm up on an earlier line first, like real playback leading into the seek.
        warmUp(surface: surface, mc: mc, rows: rows, clocks: clocks,
               toTime: rows[2].displayLine.line.startTime + 0.2, currentIndex: 2, ticks: 20)

        let target = 8
        let line = rows[target].displayLine.line
        // Mid-word: third word (index 2 of 4) — matches the mask-trace evidence's word index 7/8.
        let midWord = line.startTime + (line.endTime - line.startTime) * 0.6
        guard let landed = seekAndCaptureLandingFrame(
            surface: surface, mc: mc, rows: rows, clocks: clocks, seekTo: midWord, expectedIndex: target
        ) else {
            XCTFail("row \(target) not mounted on landing frame"); return
        }
        XCTAssertTrue(isLandingFrameAcceptable(row: landed),
            "seek into mid-word landing frame: bright overlay visible (opacity=\(landed.debugMainBrightOpacity)) "
            + "without an engaged per-word mask, while expected progress=\(landed.debugLastMainExpectedProgress ?? -1) "
            + "is still incomplete — this is the founder-reported whole-line-lit-no-mask state")
    }

    // MARK: - Scenario 2: seek BACK into an already fully-sung line

    @MainActor
    func test_seekBackIntoAlreadySungLine_landingFrameIsNeverBrightAndUnmasked() {
        let (surface, mc, rows, clocks) = makeHarness()
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        let sungLine = 3
        // Play well PAST the line so it is fully sung and has receded (mirrors 3d's postmortem:
        // seeking back into an already-sung line used to leave the highlight mask permanently
        // hidden — a different, already-fixed bug; this test is about the LANDING FRAME's mask
        // engagement, not the fade floor).
        warmUp(surface: surface, mc: mc, rows: rows, clocks: clocks,
               toTime: rows[7].displayLine.line.startTime + 0.5, currentIndex: 7, ticks: 40)

        let line = rows[sungLine].displayLine.line
        let midWord = line.startTime + (line.endTime - line.startTime) * 0.6
        guard let landed = seekAndCaptureLandingFrame(
            surface: surface, mc: mc, rows: rows, clocks: clocks, seekTo: midWord, expectedIndex: sungLine
        ) else {
            XCTFail("row \(sungLine) not mounted on landing frame"); return
        }
        XCTAssertTrue(isLandingFrameAcceptable(row: landed),
            "seek-back into an already-sung line's landing frame: bright overlay visible (opacity=\(landed.debugMainBrightOpacity)) "
            + "without an engaged per-word mask, expected progress=\(landed.debugLastMainExpectedProgress ?? -1)")
    }

    // MARK: - Scenario 3: seek while paused

    @MainActor
    func test_seekWhilePaused_landingFrameIsNeverBrightAndUnmasked() {
        let (surface, mc, rows, clocks) = makeHarness()
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        warmUp(surface: surface, mc: mc, rows: rows, clocks: clocks,
               toTime: rows[2].displayLine.line.startTime + 0.2, currentIndex: 2, ticks: 20)

        mc.isPlaying = false
        let target = 5
        let line = rows[target].displayLine.line
        let midWord = line.startTime + (line.endTime - line.startTime) * 0.6
        guard let landed = seekAndCaptureLandingFrame(
            surface: surface, mc: mc, rows: rows, clocks: clocks, seekTo: midWord, expectedIndex: target
        ) else {
            XCTFail("row \(target) not mounted on landing frame"); return
        }
        XCTAssertTrue(isLandingFrameAcceptable(row: landed),
            "seek while paused, landing frame: bright overlay visible (opacity=\(landed.debugMainBrightOpacity)) "
            + "without an engaged per-word mask, expected progress=\(landed.debugLastMainExpectedProgress ?? -1)")
    }

    // MARK: - Exhaustive sweep: many mid-word seek points across many lines, single landing frame each

    @MainActor
    func test_exhaustive_manySeekPointsAcrossManyLines_noLandingFrameIsBrightAndUnmasked() {
        var violations = 0
        var total = 0
        for lineIndex in stride(from: 1, to: 11, by: 1) {
            for frac in [0.05, 0.3, 0.5, 0.6, 0.75, 0.95] {
                let (surface, mc, rows, clocks) = makeHarness()
                defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }
                let warmIndex = max(0, lineIndex - 2)
                warmUp(surface: surface, mc: mc, rows: rows, clocks: clocks,
                       toTime: rows[warmIndex].displayLine.line.startTime + 0.2, currentIndex: warmIndex, ticks: 15)
                let line = rows[lineIndex].displayLine.line
                let seekTime = line.startTime + (line.endTime - line.startTime) * frac
                total += 1
                guard let landed = seekAndCaptureLandingFrame(
                    surface: surface, mc: mc, rows: rows, clocks: clocks, seekTo: seekTime, expectedIndex: lineIndex
                ) else { continue }
                if !isLandingFrameAcceptable(row: landed) {
                    violations += 1
                    print("[SeekLandingMask] VIOLATION line=\(lineIndex) frac=\(frac) "
                        + "expected=\(landed.debugLastMainExpectedProgress ?? -1) "
                        + "brightOpacity=\(landed.debugMainBrightOpacity) "
                        + "perRunSweep=\(landed.debugLastAppliedActivePerRunSweep)")
                }
            }
        }
        XCTAssertEqual(violations, 0, "\(violations)/\(total) seek landing frames were bright-and-unmasked")
    }
}
