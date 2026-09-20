import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Coordinator correction 2026-09-19, backed by REAL on-device rowdump evidence (0.2s cadence,
// /private/tmp/.../scratchpad/live/rowdump_floatseq.txt): NativeLyricsWordFloatHoldTests (48863d5)
// fixed a genuine but SMALLER clock-jitter recede (~0.06pt) — not the bug the founder actually saw.
// The real defect, from the rowdump timeline:
//   - row 9 active, swept words' dim AND bright glyph tiles float together to y=22.0 (rest 24.0)
//   - one frame after deactivation (d05): tiles still at 22.0, whole-line dim base still blanked
//   - next frame (d06): tiles hidden entirely, whole-line dim base repainted UNBLANKED at 24.0
//   → every previously-swept word's ink jumps 2pt in ONE frame — a hard drop, not clock jitter.
//
// Root cause (reproduced below): `applyInactivePlaybackLayerState` (called the instant
// `NativeLyricsTextActivation.isLineTextActive` flips this row off) unconditionally restores the
// whole-line rest string and hides every float-driven glyph tile, with NO regard for
// `mainPostLineFadeFloor` (which is still mid-fade at that exact moment) — banned-patterns.md's
// v2.8 model ("dim 整行保留、只让亮层 float") was being violated on the FLOAT axis (dim tiles
// floated as a "single visual unit" partner to bright) and on the TEARDOWN axis (no fade-then-hide
// ordering) at once.
//
// Fix (on top of 48863d5's monotonic float floor):
//  1. The whole-line dim base is NEVER hollowed for an ordinary (non-emphasis) word any more — it
//     always paints the FULL line, unconditionally. Only the bright per-glyph tile floats.
//  2. `updatePlaybackPhase` keeps routing through the active word-cascade (`forceActive`) for as
//     long as `mainPostLineFadeFloor > 0` after this row's own deactivation edge — the bright
//     overlay's OWN opacity fade removes it from the screen; only once fully faded does the row
//     switch to `applyInactivePlaybackLayerState()`'s instant (but by-then invisible) reset.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsDimBaseNeverMovesTests: XCTestCase {

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

    private func row(_ line: LyricLine, index: Int) -> LayerBackedLyricRow {
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

    // 网易云真实词时长格式，两行连续（第 9/10 行的位置由 currentIndex 决定，不依赖具体行号）：
    // 一个长 CJK 语块 + 短尾词，contiguous with the next line so deactivation happens naturally.
    private func cjkPhraseLine(start: TimeInterval) -> LyricLine {
        let phraseEnd = start + 1.6
        let end = phraseEnd + 0.6
        return LyricLine(
            text: "未来的旅程 啊",
            startTime: start, endTime: end,
            words: [
                LyricWord(word: "未来的旅程", startTime: start, endTime: phraseEnd),
                LyricWord(word: "啊", startTime: phraseEnd, endTime: end),
            ]
        )
    }

    @MainActor
    func test_deactivation_dimBaseNeverBlanksOrMoves_brightOnlyFadesOpacity() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        surface.debugSkipDedupe = true
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true

        let lineA = cjkPhraseLine(start: 0)
        let lineB = cjkPhraseLine(start: lineA.endTime + 0.05)
        let rows = [row(lineA, index: 0), row(lineB, index: 1)]

        var wall: CFTimeInterval = 20_000
        surface.debugNowOverride = { wall }
        defer { surface.debugNowOverride = nil }

        func tick(_ playback: TimeInterval, current: Int) {
            wall += 1.0 / 60.0
            mc.syncPlaybackClock(to: playback, playing: true, at: Date())
            surface.configure(config(rows, current: current, mc: mc))
            surface.debugTick(displayInterval: 1.0 / 60.0)
            RunLoop.main.run(until: Date())
        }

        // Drive line A well into its float window while still the active row.
        var t: TimeInterval = 0.02
        while t < 1.4 {
            tick(t, current: 0)
            t += 1.0 / 60.0
        }
        guard let activeRow = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row 0 must be mounted while active")
        }
        let restY = activeRow.debugMainWordGlyphPairs.first?.brightPositionY
        XCTAssertNotNil(restY)

        // Precondition: the word has actually floated (bright tile visibly above rest), and per
        // the fix the whole-line dim base is NOT hollowed for this ordinary word.
        let signatureWhileActive = activeRow.debugActiveUnifiedBlankedSignature
        XCTAssertEqual(
            signatureWhileActive, "\(lineA.text)|float|",
            "ordinary words must never be hollowed out of the whole-line dim base"
        )
        let dimYWhileActive = activeRow.debugMainWordGlyphPairs.first?.dimPositionY

        // Cross the boundary into line B — line A's row (index 0) deactivates. Sample every frame
        // for 2 seconds (comfortably past the 1.5s postLineFadeOut window) and assert:
        //  (a) the dim-base blank signature stays exactly the never-hollowed value the whole time;
        //  (b) the dim tile's own Y (when present at all) never changes from its rest value;
        //  (c) the bright tile's Y only ever holds or fades via opacity — it must not jump/receded
        //      in POSITION at any single frame by more than a sub-pixel amount.
        var brightYSequence: [CGFloat] = []
        var brightOpacitySequence: [Float] = []
        var sawAnyHollowForOrdinaryWord = false
        var sawDimYDrift = false

        var boundaryTime = lineA.endTime + 0.02
        let endTime = boundaryTime + 2.0
        while boundaryTime < endTime {
            tick(boundaryTime, current: 1)
            guard let stillRow = surface.debugRowView(forIndex: 0) else { break }
            if let sig = stillRow.debugActiveUnifiedBlankedSignature, sig != "\(lineA.text)|float|" {
                sawAnyHollowForOrdinaryWord = true
            }
            if let dimY = stillRow.debugMainWordGlyphPairs.first?.dimPositionY,
               let baseline = dimYWhileActive, abs(dimY - baseline) > 0.01 {
                sawDimYDrift = true
            }
            brightYSequence.append(stillRow.debugMainWordGlyphPairs.first?.brightPositionY ?? .nan)
            brightOpacitySequence.append(stillRow.debugMainBrightWordGlyphOpacities.first ?? 0)
            boundaryTime += 1.0 / 60.0
        }

        XCTAssertFalse(sawAnyHollowForOrdinaryWord, "an ordinary word's whole-line dim ink must never be blanked")
        XCTAssertFalse(sawDimYDrift, "the dim tile must never move — only the bright overlay floats")

        // The bright overlay's opacity must reach (approximately) 0 within the sample window —
        // confirms the fade actually ran, not that we sampled too briefly.
        XCTAssertLessThan(brightOpacitySequence.last ?? 1, 0.05, "post-line fade must complete within 2s")

        // No single-frame Y jump greater than sub-pixel jitter while the bright tile is still
        // meaningfully visible (opacity > 0.02) — this is the exact "2pt drop in one frame" shape
        // from the rowdump. Once opacity has dropped below that, position no longer matters (the
        // glyph reads as invisible) so a subsequent hide is not a "drop".
        var worstJump: CGFloat = 0
        for i in 1..<brightYSequence.count {
            guard brightOpacitySequence[i - 1] > 0.02, !brightYSequence[i].isNaN, !brightYSequence[i - 1].isNaN else { continue }
            let jump = abs(brightYSequence[i] - brightYSequence[i - 1])
            worstJump = max(worstJump, jump)
        }
        XCTAssertLessThanOrEqual(
            worstJump, 0.05,
            "bright overlay position jumped \(worstJump)pt in a single frame while still visible — must fade via opacity only, never snap position/visibility"
        )

        // Opacity must ease down over MULTIPLE frames, riding the row's own opacity-recede spring
        // (`updateDeactivationFade`, keyed off `visualStates[idx].opacity` — a faster curve than
        // the old 1.5s `mainPostLineFadeFloor` window, so the per-frame step is legitimately
        // larger than a linear 1.5s decay implies) — but an instant `isHidden = true` snap (the
        // pre-fix teardown, reproduced above as a same-frame drop of ~0.999) must never happen:
        // no single frame may drop MORE than half the remaining opacity in one step.
        var worstOpacityDrop: Float = 0
        for i in 1..<brightOpacitySequence.count {
            let drop = brightOpacitySequence[i - 1] - brightOpacitySequence[i]
            if drop > 0 { worstOpacityDrop = max(worstOpacityDrop, drop) }
        }
        XCTAssertLessThanOrEqual(
            worstOpacityDrop, 0.3,
            "bright overlay opacity dropped \(worstOpacityDrop) in a single frame — must ease out via the deactivation-fade spring, never snap to hidden"
        )
        // The fade must actually span several frames (not collapse to a 2-frame full-to-zero) —
        // count frames where opacity sits strictly between 0.05 and 0.95 (genuinely "fading",
        // neither fully lit nor fully gone).
        let midFadeFrameCount = brightOpacitySequence.filter { $0 > 0.05 && $0 < 0.95 }.count
        XCTAssertGreaterThanOrEqual(
            midFadeFrameCount, 3,
            "the fade collapsed to too few frames (\(midFadeFrameCount)) — this is the instant-snap shape, not a fade"
        )
    }
}
