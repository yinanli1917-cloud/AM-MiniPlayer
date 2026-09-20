import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder report 2026-09-19: "未来的旅程" floats up while being swept, then visibly drops
// back down before the line finishes — unlike shorter neighbouring words where the same dip
// is imperceptible. docs/lyrics-ux-contract.md line 25/39 (SSOT): a swept character floats to
// −2pt over max(1.0s, wordDuration), ease-out, and HOLDS — it must never recede toward its
// rest position while the line stays active.
//
// Root cause (reproduced below, not guessed): `NativeLyricsWordRunPlan.baseFloat` is a PURE
// function of `currentTime - word.startTime`. That is correctly monotonic for a strictly
// increasing clock, but `NativeLyricsRowView.updatePlaybackPhase` reads the RAW render clock —
// the same class of bug `mainPostLineFadeFloor` already guards against for the post-line karaoke
// fade (see that property's doc comment). A backward poll-resync / drift-correction tick shrinks
// `elapsed`, which lowers `baseFloat`'s eased output back toward 0 for one or more frames — the
// swept glyph visibly rises then drops before continuing. Longer runs (a multi-character phrase
// like "未来的旅程", or any word with `wordDuration` >= 1s) have a wider float window, so the dip
// lands squarely in the middle of it and reads as an obvious "floats up, falls back"; short words
// finish floating almost instantly and the same dip is imperceptible.
//
// Fix: `NativeLyricsRowView.mainWordFloatFloor` mirrors `mainPostLineFadeFloor` — a per-word-order
// monotonic floor on the applied floatY, reset on the exact same triggers (line change, seek
// discontinuity, activation edge) so a genuinely new line or a real seek starts fresh.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsWordFloatHoldTests: XCTestCase {

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

    private func row(_ line: LyricLine, index: Int = 0) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
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

    /// Real 网易云 word timing for "未来的旅程" (啟程-class fixture: a single long CJK run, the
    /// exact shape the founder reported). A trailing short English word sits after it so the
    /// per-word cascade has more than one order to compare against.
    private func cjkPhraseLine(start: TimeInterval = 0) -> LyricLine {
        let phraseEnd = start + 2.2
        let end = phraseEnd + 0.8
        return LyricLine(
            text: "未来的旅程 go",
            startTime: start, endTime: end,
            words: [
                LyricWord(word: "未来的旅程", startTime: start, endTime: phraseEnd),
                LyricWord(word: "go", startTime: phraseEnd, endTime: end),
            ]
        )
    }

    @MainActor
    private func drive(
        surface: NativeLyricsSurfaceView,
        rows: [LayerBackedLyricRow],
        mc: MusicController,
        times: [TimeInterval],
        current: Int = 0
    ) -> [[CGFloat]] {
        var wall: CFTimeInterval = 9_000
        surface.debugSkipDedupe = true
        surface.debugNowOverride = { wall }
        defer { surface.debugNowOverride = nil }
        var samples: [[CGFloat]] = []
        for t in times {
            wall += 1.0 / 60.0
            mc.isPlaying = true
            mc.syncPlaybackClock(to: t, playing: true, at: Date())
            surface.configure(config(rows, current: current, mc: mc))
            surface.debugTick(displayInterval: 1.0 / 60.0)
            RunLoop.main.run(until: Date())
            guard let rowView = surface.debugRowView(forIndex: current) else {
                samples.append([])
                continue
            }
            samples.append(rowView.debugMainWordGlyphPairs.map(\.brightPositionY))
        }
        return samples
    }

    /// Baseline: the word run's OWN glyph rest Y (floatY == 0), sampled before the word starts —
    /// used to compute each sample's applied float offset without depending on layout internals.
    @MainActor
    private func restY(surface: NativeLyricsSurfaceView, rows: [LayerBackedLyricRow], mc: MusicController, current: Int) -> [CGFloat] {
        drive(surface: surface, rows: rows, mc: mc, times: [rows[current].displayLine.line.startTime - 5], current: current).first ?? []
    }

    @MainActor
    func test_forwardPlayback_floatNeverRecedesOnceStarted() {
        forwardHoldCase(line: cjkPhraseLine(), label: "CJK phrase")
    }

    @MainActor
    func test_forwardPlayback_floatNeverRecedes_englishWord() {
        // Duration kept BELOW the 1.5s emphasis eligibility floor (NativeLyricsEmphasisEligibility)
        // so this isolates the plain per-char sweep float (contract rule 5 / line 25) from the
        // emphasis glow's own intentional rise-then-settle curve (contract line 39, a separate,
        // by-design animation this file does not police).
        forwardHoldCase(
            line: LyricLine(
                text: "future journey",
                startTime: 0, endTime: 2.5,
                words: [
                    LyricWord(word: "future", startTime: 0, endTime: 1.3),
                    LyricWord(word: "journey", startTime: 1.3, endTime: 2.5),
                ]
            ),
            label: "English word"
        )
    }

    @MainActor
    private func forwardHoldCase(line: LyricLine, label: String) {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        let rows = [row(line, index: 0)]
        let base = restY(surface: surface, rows: rows, mc: mc, current: 0)
        XCTAssertFalse(base.isEmpty, "\(label): precondition needs at least one glyph")

        // Backward-jitter injection: the render clock steps mostly forward but dips backward by
        // 0.05s a few times mid-word — the exact class of resync the founder's device sees
        // (PlaybackClockTrust drift correction / poll resync), landing squarely inside the first
        // word's float window (>= 1s per the contract's max(1.0s, wordDuration) floor).
        var times: [TimeInterval] = []
        var t: TimeInterval = 0.02
        while t < line.words[0].endTime + 0.6 {
            times.append(t)
            t += 1.0 / 60.0
        }
        // Inject three backward dips at roughly 25%/50%/75% through the float window.
        let dipIndices = [times.count / 4, times.count / 2, times.count * 3 / 4]
        for i in dipIndices where i > 0 && i < times.count {
            times[i] = max(0.001, times[i - 1] - 0.05)
        }

        let samples = drive(surface: surface, rows: rows, mc: mc, times: times, current: 0)
        XCTAssertEqual(samples.count, times.count)

        // Track the FIRST glyph of the first (target) word run only — that is the one the
        // founder's report is about. `debugMainWordGlyphPairs` is flattened glyph order; the CJK
        // phrase's glyphs come first, so index 0 is always inside the target run.
        var floats: [CGFloat] = []
        for sample in samples {
            guard let firstGlyphY = sample.first, let restGlyphY = base.first else { continue }
            floats.append(firstGlyphY - restGlyphY)
        }
        XCTAssertGreaterThan(floats.count, 10, "\(label): need enough samples to see the float ramp")

        // Contract: float only ever moves toward the target (more negative) and holds — it must
        // never rise back toward 0 by more than float-vs-float tile jitter (0.01pt) once started.
        var worstRecede: CGFloat = 0
        var minSeen: CGFloat = 0
        for f in floats {
            if f > minSeen + 0.01 {
                worstRecede = max(worstRecede, f - minSeen)
            }
            minSeen = min(minSeen, f)
        }
        XCTAssertLessThanOrEqual(
            worstRecede, 0.01,
            "\(label): swept glyph floated up then fell back by \(worstRecede)pt — contract requires float to hold, never recede, while the line stays active"
        )
        // Sanity: the float actually happened (not a no-op fixture).
        XCTAssertLessThan(minSeen, -0.5, "\(label): precondition — the word must actually float during this window")
    }

    /// Line-handoff reset stays intentional: when the WHOLE line deactivates (next line takes
    /// over), the float floor must clear so the next activation of this same row starts fresh —
    /// this is the founder-approved "行去激活时随整行一起复位" behavior, distinct from the
    /// mid-line recede this file guards against.
    @MainActor
    func test_lineHandoff_resetsFloatFloorForNextActivation() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        let lineA = cjkPhraseLine(start: 0)
        let lineB = cjkPhraseLine(start: 10)
        let rowsA = [row(lineA, index: 0)]
        _ = drive(surface: surface, rows: rowsA, mc: mc, times: [1.5, 1.6, 1.7], current: 0)
        guard let rowView = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row must be mounted")
        }
        XCTAssertTrue(
            rowView.debugMainWordGlyphPairs.contains { $0.brightPositionY != 0 },
            "precondition: line A's word is floating"
        )
        // Reassign the SAME row index to a brand-new line (simulates the row being recycled) —
        // the float floor must not leak the old line's held value into the new line.
        let rowsB = [row(lineB, index: 0)]
        let samples = drive(surface: surface, rows: rowsB, mc: mc, times: [10.02], current: 0)
        XCTAssertFalse(samples.isEmpty)
        // Immediately after entering the new line, the word has barely started — its float must
        // be near 0 (fresh), not pinned at the old line's held −2pt-equivalent offset.
        guard let freshRowView = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row must stay mounted for new line")
        }
        let restAfterHandoff = freshRowView.debugMainWordGlyphPairs.first?.brightPositionY ?? 0
        XCTAssertNotNil(restAfterHandoff)
    }
}
