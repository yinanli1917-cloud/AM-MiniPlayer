import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// research/repro-2026-09-19-lyrics-render-3l.md — 《啟程》real-device rowdump (founder: a blurred
// duplicate of "未来的旅程" sitting a few pt below the real text, worst on the LAST character of
// the wrapped line). The rowdump (rowdump_ghost3.txt) samples ~1s apart — far too coarse to catch
// a transient — so this test drives the REAL per-frame invariant the rowdump's own two channels
// must satisfy every tick:
//
//   For word `order`, `applyFloatingHiddenBase`'s `floatingOrders` gate (built from
//   `run.baseFloatY != 0`, `NativeLyricsRowView.swift` ~2025-2040) decides whether the whole-line
//   dim-base CATextLayer hollows that word's characters out (alpha 0, "the per-glyph tile is now
//   the only visible copy") or leaves them at full alpha ("the whole-line base IS the visible
//   copy, at REST — nothing must be drawn floated on top of it").
//
//   `applyMainWordFloatGlyphLayers` draws BOTH a dim and a bright per-glyph tile for EVERY word,
//   every frame, regardless of the gate; only `dimLayer.isHidden` and (for the bright tile) the Y
//   offset it applies are conditioned on that same-frame float state. So the exact frame-level
//   invariant a ghost-free render must hold, for every glyph, every frame, is:
//
//     dimHidden == true  ⇔  the word is floating this frame (its rendered Y differs from rest)
//
//   A violation either shows an un-hollowed dim-base character with a floated tile drawn on top of
//   it (visible duplicate, alpha 0.35 "shadow" under a moving bright/dim copy — the reported
//   ghost), or a hollowed character with NO floated tile compensating (a gap/flash — the sibling
//   defect this same gate was built to prevent, per the file's own comments).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsDimBaseFloatGateConsistencyTests: XCTestCase {
    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.resetTestingOverrides()
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

    /// The founder's actual line from 《啟程》, wrapped to the same 186pt content width the
    /// real rowdump shows ("只有你能带我走向" / "未来的旅程", an 8+5 character wrap) — one word
    /// per character (the class of source, NetEase YRC, that carries real per-character timing
    /// for CJK). Word durations mirror the real dump's ~0.5-0.6s per-character cadence.
    private func qichengLine() -> LyricLine {
        let chars = Array("只有你能带我走向未来的旅程")
        var words: [LyricWord] = []
        var t: TimeInterval = 0
        for ch in chars {
            let dur: TimeInterval = 0.55
            words.append(LyricWord(word: String(ch), startTime: t, endTime: t + dur))
            t += dur
        }
        return LyricLine(text: String(chars), startTime: 0, endTime: t, words: words)
    }

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                    isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "启程", artist: "A", album: "Al", duration: 240),
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

    private struct Violation {
        let t: TimeInterval
        let glyphIndex: Int
        let dimHidden: Bool
        let dimY: CGFloat
        let brightY: CGFloat
    }

    /// Runs the exact per-frame invariant across every 1/60s tick from the line's start through
    /// 1s past its end (covering the whole wrap, the tail character "程", and the deactivation
    /// boundary), under shipping production defaults (no testingSweep/testingEmphasis override —
    /// `NativeLyricsFeelParity` already resolves to the shipping arms under `isRunningTests`).
    @MainActor
    private func runExhaustiveGateInvariant(stepSeconds: TimeInterval) -> (violations: [Violation], sampledFrames: Int) {
        let panelWidth: CGFloat = 250 // matches the real rowdump's ROOT frame width
        let line = qichengLine()
        var rows: [LayerBackedLyricRow] = [row(for: line, index: 0)]
        rows.append(row(for: LyricLine(text: "下一句歌词内容", startTime: line.endTime, endTime: line.endTime + 3), index: 1))

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 20_000
        var date = Date(timeIntervalSinceReferenceDate: 990_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        mc.syncPlaybackClock(to: 0.02, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc, width: panelWidth))
        surface.layoutSubtreeIfNeeded()
        CATransaction.flush()

        var violations: [Violation] = []
        var sampledFrames = 0
        var t: TimeInterval = 0.02
        let tailWindow = line.endTime + 1.0
        while t < tailWindow {
            wall += stepSeconds
            date = date.addingTimeInterval(stepSeconds)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), rows.count - 1)
            surface.configure(config(rows, current: current, mc: mc, width: panelWidth))
            surface.debugTick(displayInterval: stepSeconds)
            guard current == 0, let view = surface.debugRowView(forIndex: 0) else { t += stepSeconds; continue }
            sampledFrames += 1
            for (index, pair) in view.debugMainWordGlyphPairs.enumerated() {
                // `dimLayer.isHidden` (`dimHidden == true`) means the whole-line dim-base
                // CATextLayer is trusted as the sole visible copy of this glyph — the per-glyph
                // dim tile stands down. That trust is only valid if the glyph's BRIGHT tile
                // (which is ALWAYS drawn — `applyMainWordFloatGlyphLayers` never hides it) is
                // ALSO sitting at the same, unfloated rest position as the base. If the bright
                // tile has drifted away (`brightPositionY != dimPositionY`) while `dimHidden` is
                // still true, the whole-line base is showing the glyph at rest AND the bright
                // tile is showing a second, displaced copy at the same time — the reported ghost.
                // This is precisely the desync `applyMainWordFloatGlyphLayers` already
                // instruments (`NativeLyricsMaskTrace.recordWordFloatDesync`, `!isFloatingWord &&
                // input.floatY != 0`), made into a hard per-frame assertion instead of an
                // opt-in production trace.
                if pair.dimHidden, abs(pair.brightPositionY - pair.dimPositionY) > 0.25 {
                    violations.append(Violation(
                        t: t, glyphIndex: index, dimHidden: pair.dimHidden,
                        dimY: pair.dimPositionY, brightY: pair.brightPositionY
                    ))
                }
            }
            t += stepSeconds
        }
        return (violations, sampledFrames)
    }

    @MainActor
    func test_everyGlyph_everyFrame_60Hz_dimHollowGateMatchesActualFloat() {
        let (violations, sampledFrames) = runExhaustiveGateInvariant(stepSeconds: 1.0 / 60.0)
        XCTAssertGreaterThan(sampledFrames, 100, "precondition: must actually sample the full line + tail window")
        XCTAssertTrue(violations.isEmpty, describe(violations))
    }

    @MainActor
    func test_everyGlyph_everyFrame_100ms_dimHollowGateMatchesActualFloat() {
        let (violations, sampledFrames) = runExhaustiveGateInvariant(stepSeconds: 0.1)
        XCTAssertGreaterThan(sampledFrames, 10, "precondition: must actually sample the full line + tail window")
        XCTAssertTrue(violations.isEmpty, describe(violations))
    }

    @MainActor
    func test_everyGlyph_everyFrame_250ms_dimHollowGateMatchesActualFloat() {
        let (violations, sampledFrames) = runExhaustiveGateInvariant(stepSeconds: 0.25)
        XCTAssertGreaterThan(sampledFrames, 4, "precondition: must actually sample the full line + tail window")
        XCTAssertTrue(violations.isEmpty, describe(violations))
    }

    /// Step 3 (research/repro-2026-09-19-lyrics-render-3l.md): the model-level invariant above is
    /// clean — `run.baseFloatY` is a single, pre-computed value shared verbatim by both the
    /// hollow-gate and the tile-position formula, so they cannot algebraically disagree. The
    /// remaining candidate is a CA-level lag: the compositor's PRESENTATION layer (what is actually
    /// on screen) trailing the MODEL layer (what this frame just assigned) because some layer in
    /// the chain isn't `.lyricsInert()`, or an explicit spring survives from a superseded code
    /// path. Assert presentation()==model position for every dim/bright glyph tile, every frame.
    @MainActor
    func test_everyGlyph_everyFrame_60Hz_presentationLayerNeverDriftsFromModel() {
        let panelWidth: CGFloat = 250
        let line = qichengLine()
        var rows: [LayerBackedLyricRow] = [row(for: line, index: 0)]
        rows.append(row(for: LyricLine(text: "下一句歌词内容", startTime: line.endTime, endTime: line.endTime + 3), index: 1))

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 30_000
        var date = Date(timeIntervalSinceReferenceDate: 991_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        mc.syncPlaybackClock(to: 0.02, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc, width: panelWidth))
        surface.layoutSubtreeIfNeeded()
        CATransaction.flush()

        var driftViolations: [(t: TimeInterval, index: Int, dimDelta: CGFloat, brightDelta: CGFloat)] = []
        var sampledFrames = 0
        let step = 1.0 / 60.0
        var t: TimeInterval = 0.02
        let tailWindow = line.endTime + 1.0
        while t < tailWindow {
            wall += step
            date = date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), rows.count - 1)
            surface.configure(config(rows, current: current, mc: mc, width: panelWidth))
            surface.debugTick(displayInterval: step)
            // The presentation tree only exists once the layer is committed inside a real
            // transaction — flush after every tick so `presentation()` reflects THIS frame's
            // committed model instead of the previous one.
            CATransaction.flush()
            guard current == 0, let view = surface.debugRowView(forIndex: 0) else { t += step; continue }
            sampledFrames += 1
            for (index, deltas) in view.debugMainWordGlyphPresentationDeltas.enumerated() {
                if deltas.dimDeltaY > 0.25 || deltas.brightDeltaY > 0.25 {
                    driftViolations.append((t, index, deltas.dimDeltaY, deltas.brightDeltaY))
                }
            }
            t += step
        }
        XCTAssertGreaterThan(sampledFrames, 100, "precondition: must actually sample the full line + tail window")
        XCTAssertTrue(driftViolations.isEmpty,
            "\(driftViolations.count) presentation/model drift(s), e.g. t=\(driftViolations.first?.t ?? -1) "
            + "glyphIndex=\(driftViolations.first?.index ?? -1) dimDelta=\(driftViolations.first?.dimDelta ?? -1) "
            + "brightDelta=\(driftViolations.first?.brightDelta ?? -1) — the compositor is still drawing a stale "
            + "position while the model has already moved on (a leftover implicit/explicit animation)")
    }

    private func describe(_ violations: [Violation]) -> String {
        guard let first = violations.first else { return "" }
        return "\(violations.count) dim/float gate violation(s), e.g. t=\(first.t) glyphIndex=\(first.glyphIndex) "
            + "dimHidden=\(first.dimHidden) dimY=\(first.dimY) brightY=\(first.brightY) "
            + "(dimHidden must equal |bright-dim|>0.25pt — otherwise a second, offset copy of the "
            + "glyph renders alongside the whole-line base's own copy)"
    }
}
