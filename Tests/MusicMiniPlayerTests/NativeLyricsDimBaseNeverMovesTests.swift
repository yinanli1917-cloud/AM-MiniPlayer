import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SUPERSEDED 2026-09-19 (3o, founder-dictated v2.8 restore — "dim 与 bright 一起浮"). The 3n
// design this file originally pinned (dim base NEVER hollows/floats for an ordinary word; only the
// bright per-glyph tile moves) turned out to be the wrong fix for the real defect: it made the two
// channels disagree on geometry while a word is actively floating (bright at −2pt, dim frozen at
// 0), and on deactivation the bright tile's own opacity fade finished FIRST while still floated —
// visually reading as "the word's ink drops" once the vanishing bright reveals the always-static
// dim underneath. The founder's real v2.8 reference (`v28_LyricLineView.swift`'s
// `LyricsTextRenderer.draw`) floats dim WITH bright, always, at one shared geometry — this file's
// assertions below are updated to pin THAT contract instead. See
// `research/repro-2026-09-19-lyrics-render-3o.md` and `.claude/rules/banned-patterns.md`.
//
// Original defect this file exists to guard (still true, still fixed, just via a different
// mechanism): a swept word's ink must never jump/snap in a single frame on deactivation. The fix
// is now: `mainWordFloatReturnFloor` eases the held float (dim AND bright together) back to 0 over
// a short window AFTER the bright opacity fade has already bottomed out, and the whole-line dim
// base only un-hollows the same frame that eased float reaches (near) 0 — never before, never
// instantly.
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

    /// `debugActiveUnifiedBlankedSignature` is `"<text>|float|<comma-separated orders>"` (or nil
    /// before layout). The suffix after the LAST `|float|` is empty when nothing is hollowed and
    /// non-empty (one or more order indices) when at least one word is — generic across scripts,
    /// unlike hardcoding a specific order index.
    private static func signatureHasFloatingOrders(_ signature: String?) -> Bool {
        guard let signature, let range = signature.range(of: "|float|") else { return false }
        return !signature[range.upperBound...].isEmpty
    }

    private func englishPhraseLine(start: TimeInterval) -> LyricLine {
        let phraseEnd = start + 1.6
        let end = phraseEnd + 0.6
        return LyricLine(
            text: "carry me home",
            startTime: start, endTime: end,
            words: [
                LyricWord(word: "carry me", startTime: start, endTime: phraseEnd),
                LyricWord(word: "home", startTime: phraseEnd, endTime: end),
            ]
        )
    }

    /// 3o English-line variant of the CJK test below (same assertions, same helpers) — the founder
    /// asked for both a CJK and an English case; dim/bright unification and the eased float-return
    /// must hold regardless of script.
    @MainActor
    func test_deactivation_englishLine_dimAndBrightStayUnifiedAndEaseToRest() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        surface.debugSkipDedupe = true
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true

        let lineA = englishPhraseLine(start: 0)
        let lineB = englishPhraseLine(start: lineA.endTime + 0.05)
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

        var t: TimeInterval = 0.02
        while t < 1.4 {
            tick(t, current: 0)
            t += 1.0 / 60.0
        }
        guard let activeRow = surface.debugRowView(forIndex: 0) else {
            return XCTFail("row 0 must be mounted while active")
        }
        let pairWhileActive = activeRow.debugMainWordGlyphPairs.first
        XCTAssertEqual(
            pairWhileActive?.dimPositionY, pairWhileActive?.brightPositionY,
            "dim and bright tiles must share the exact same floated Y while active (English line)"
        )

        var pairYSequence: [(dim: CGFloat, bright: CGFloat)] = []
        var hollowedSequence: [Bool] = []
        var tileVisibleSequence: [Bool] = []
        var sawDesync = false

        var boundaryTime = lineA.endTime + 0.02
        let endTime = boundaryTime + 2.5
        while boundaryTime < endTime {
            tick(boundaryTime, current: 1)
            guard let stillRow = surface.debugRowView(forIndex: 0) else { break }
            let pair = stillRow.debugMainWordGlyphPairs.first
            let dimY = pair?.dimPositionY ?? .nan
            let brightY = pair?.brightPositionY ?? .nan
            if !dimY.isNaN, !brightY.isNaN, abs(dimY - brightY) > 0.01 { sawDesync = true }
            pairYSequence.append((dimY, brightY))
            hollowedSequence.append(Self.signatureHasFloatingOrders(stillRow.debugActiveUnifiedBlankedSignature))
            tileVisibleSequence.append(!(pair?.dimHidden ?? true))
            boundaryTime += 1.0 / 60.0
        }

        XCTAssertFalse(sawDesync, "dim and bright must never disagree on Y (English line)")
        guard let restY = pairYSequence.last?.dim else {
            return XCTFail("expected at least one sampled frame")
        }
        guard let lastVisibleIndex = tileVisibleSequence.lastIndex(of: true) else {
            return XCTFail("the tile must be visible for at least one frame after deactivation begins")
        }
        XCTAssertEqual(
            pairYSequence[lastVisibleIndex].dim, restY, accuracy: 0.1,
            "the tile must already be at (near) rest the last frame it is visible (English line)"
        )
        for i in 0..<hollowedSequence.count {
            XCTAssertEqual(
                hollowedSequence[i], tileVisibleSequence[i],
                "frame \(i): un-hollow and tile-hide must land in the same frame (English line)"
            )
        }
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
        let floatedBrightY = activeRow.debugMainWordGlyphPairs.first?.brightPositionY
        XCTAssertNotNil(floatedBrightY)

        // Precondition (3o): the word has actually floated, and the whole-line dim base IS
        // hollowed for it — dim and bright share one geometry, so the ordinary word's order (0)
        // appears in the signature's floating-orders suffix.
        let signatureWhileActive = activeRow.debugActiveUnifiedBlankedSignature
        XCTAssertEqual(
            signatureWhileActive, "\(lineA.text)|float|0",
            "a floating ordinary word must be hollowed out of the whole-line dim base (dim floats with bright)"
        )
        let pairWhileActive = activeRow.debugMainWordGlyphPairs.first
        XCTAssertEqual(
            pairWhileActive?.dimPositionY, pairWhileActive?.brightPositionY,
            "dim and bright tiles must share the exact same floated Y while active"
        )
        XCTAssertNotEqual(pairWhileActive?.dimPositionY, 0, "the word must genuinely be floating for this assertion to be meaningful")

        // Cross the boundary into line B — line A's row (index 0) deactivates. Sample every frame
        // for 2.5 seconds (comfortably past the 1.5s bright fade + the ~0.35s float-return window)
        // and assert the 3o contract:
        //  (a) dim and bright stay Y-locked to each other every single frame (never desync);
        //  (b) the float (both tiles) only ever eases MONOTONICALLY toward rest — no jump, no
        //      overshoot, no re-rise;
        //  (c) the tiles hide and the whole-line dim base un-hollows in the SAME frame — never a
        //      frame with tiles gone but the base still hollowed, or the base restored but a tile
        //      still visible.
        var pairYSequence: [(dim: CGFloat, bright: CGFloat)] = []
        var hollowedSequence: [Bool] = []
        var tileVisibleSequence: [Bool] = []
        var sawDesync = false

        var boundaryTime = lineA.endTime + 0.02
        let endTime = boundaryTime + 2.5
        while boundaryTime < endTime {
            tick(boundaryTime, current: 1)
            guard let stillRow = surface.debugRowView(forIndex: 0) else { break }
            let pair = stillRow.debugMainWordGlyphPairs.first
            let dimY = pair?.dimPositionY ?? .nan
            let brightY = pair?.brightPositionY ?? .nan
            if !dimY.isNaN, !brightY.isNaN, abs(dimY - brightY) > 0.01 { sawDesync = true }
            pairYSequence.append((dimY, brightY))
            hollowedSequence.append(Self.signatureHasFloatingOrders(stillRow.debugActiveUnifiedBlankedSignature))
            tileVisibleSequence.append(!(pair?.dimHidden ?? true))
            boundaryTime += 1.0 / 60.0
        }

        XCTAssertFalse(sawDesync, "dim and bright must never disagree on Y — they are one geometry")

        // Ground truth for "rest" is read empirically from the tail of the sample window (well
        // past both the bright fade and the float-return window, where `isFloatingWord` is
        // definitely false and `dimCenterY` is computed with no float term at all) rather than
        // assumed from the −2pt contract constant — `dimLayer.position` is written every frame
        // regardless of `isHidden`, so this is a faithful read even though the tile is hidden by
        // then.
        guard let restY = pairYSequence.last?.dim else {
            return XCTFail("expected at least one sampled frame")
        }
        let lastVisibleIndex = tileVisibleSequence.lastIndex(of: true)
        guard let lastVisibleIndex else {
            return XCTFail("the tile must be visible for at least one frame after deactivation begins")
        }
        XCTAssertEqual(
            pairYSequence[lastVisibleIndex].dim, restY, accuracy: 0.1,
            "the tile must already be at (near) rest the last frame it is visible — never hidden while still displaced"
        )

        // Monotonic return: once past the bright-opacity fade, the float's DISTANCE FROM REST only
        // ever shrinks — never grows (no re-rise/overshoot).
        var worstRise: CGFloat = 0
        for i in 1..<pairYSequence.count {
            let prevDist = abs(pairYSequence[i - 1].bright - restY)
            let curDist = abs(pairYSequence[i].bright - restY)
            if curDist > prevDist { worstRise = max(worstRise, curDist - prevDist) }
        }
        XCTAssertLessThanOrEqual(worstRise, 0.01, "float distance-from-rest grew by \(worstRise)pt in a single frame — must be strictly monotonic toward rest")

        // Hollowed state and tile visibility must change in lockstep, same frame — the exact
        // "字块已隐藏但暗底仍 blank" / "暗底已恢复但字块仍可见" defect this restore must not
        // reintroduce.
        for i in 0..<hollowedSequence.count {
            XCTAssertEqual(
                hollowedSequence[i], tileVisibleSequence[i],
                "frame \(i): hollowed=\(hollowedSequence[i]) but tileVisible=\(tileVisibleSequence[i]) — un-hollow and tile-hide must land in the same frame"
            )
        }

        // The un-hollow must not happen instantly on the deactivation edge — there must be at
        // least a few frames where the row is inactive but still hollowed/floated (the eased
        // return window actually ran, not collapsed to 0 frames).
        let stillHollowedWhileInactiveCount = hollowedSequence.filter { $0 }.count
        XCTAssertGreaterThanOrEqual(
            stillHollowedWhileInactiveCount, 3,
            "the float-return window collapsed to too few frames (\(stillHollowedWhileInactiveCount)) — this is the instant-unhollow shape, not an eased return"
        )
    }
}
