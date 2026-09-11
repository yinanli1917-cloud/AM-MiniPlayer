import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Per-row onset table for a natural line handoff, under injected clocks.
//
// Drive shape is copied from NativeLyricsHandoffClockTests.runHandoff (lockstep 1x, continuous
// 1.0 s warm-up so the 0.8 s appear window has expired before the boundary). For rows i-3..i+4
// around the outgoing active line i=5 (incoming i+1=6), this records the FIRST census frame at
// which each row's y / opacity / blur starts moving away from its pre-boundary baseline, and
// compares the POSITION onset to LyricWaveTiming.staggerSchedule's own delay table (computed
// live, not hardcoded) for the same renderedIndices/newIndex/lineInterval the engine actually used.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsWaveOnsetTableTests: XCTestCase {

    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        hostedSurfaces.forEach { $0.stopAnimations() }
        hostedSurfaces.removeAll()
        hostWindow?.orderOut(nil)
        hostWindow = nil
        NativeLyricsFeelParity.resetTestingOverrides()
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
        if let surface = view as? NativeLyricsSurfaceView {
            hostedSurfaces.append(surface)
        }
    }

    // Same fixture shape as NativeLyricsHandoffClockTests.makeRows: contiguous 1.2 s word-timed lines.
    private func makeRows(_ n: Int) -> [LayerBackedLyricRow] {
        (0..<n).map { i in
            let s = TimeInterval(i) * 1.2, e = TimeInterval(i) * 1.2 + 1.2
            let d = (e - s) / 3
            let line = LyricLine(
                text: "line \(i) words here", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "line ", startTime: s, endTime: s + d),
                    LyricWord(word: "\(i) ", startTime: s + d, endTime: s + 2 * d),
                    LyricWord(word: "words here", startTime: s + 2 * d, endTime: e),
                ]
            )
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(
        _ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController
    ) -> LyricsLayerRendererConfiguration {
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

    private struct RowOnset {
        let index: Int
        let deltaFromI: Int
        let mounted: Bool
        let posOnsetMs: Double?
        let opacityOnsetMs: Double?
        let blurOnsetMs: Double?
        let expectedMs: Double?
    }

    /// First frame (>= boundaryFrame) at which `values[idx]` departs from the pre-boundary baseline
    /// by more than `tol`. Baseline is the max/avg over the pre-boundary window (matches
    /// NativeLyricsHandoffClockTests' own baseline convention). Returns nil if it never moves within
    /// the recorded window (row not participating / stayed put).
    private func firstOnset(_ values: [CGFloat], baseline: CGFloat, boundaryFrame: Int, tol: CGFloat) -> Int? {
        guard boundaryFrame < values.count else { return nil }
        for f in boundaryFrame..<values.count where abs(values[f] - baseline) > tol {
            return f
        }
        return nil
    }

    @MainActor
    func test_naturalHandoff_perRowOnsetMatchesStaggerSchedule() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rowCount = 20
        let rows = makeRows(rowCount)
        surface.debugSkipDedupe = true

        let i = 5              // outgoing active line
        let iPlus1 = i + 1     // incoming active line
        let lineEnd = rows[i].displayLine.line.endTime
        let previousStart = rows[i].displayLine.line.startTime

        var wall: CFTimeInterval = 1_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let wallStepPerFrame: TimeInterval = 1.0 / 60.0
        let playbackStep = 1.0 / 60.0
        func step(playback: TimeInterval) {
            wall += wallStepPerFrame
            date = date.addingTimeInterval(playbackStep)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc))
            surface.debugTick(displayInterval: wallStepPerFrame)
            RunLoop.main.run(until: Date())
        }

        // Warm-up: mount at line start + 0.1 s and run 1.0 s so the 0.8 s appear (force-snap) window
        // has expired well before the boundary (same convention as NativeLyricsHandoffClockTests).
        let warmupStart = previousStart + 0.1
        let warmupFrames = 60
        mc.syncPlaybackClock(to: warmupStart, playing: true, at: date)
        surface.configure(config(rows, current: i, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for f in 0..<warmupFrames {
            step(playback: warmupStart + TimeInterval(f) * playbackStep)
        }

        // Rows tracked for the table: i-3..i+4, clipped to the fixture.
        let trackedIndices = (-3...4).map { i + $0 }.filter { $0 >= 0 && $0 < rowCount }

        let censusStart = warmupStart + TimeInterval(warmupFrames) * playbackStep
        surface.debugResetCensus()
        surface.debugCensusEnabled = true
        let censusFrames = 72
        var semanticTrace: [Int] = []
        // Per-step (not per-paint) samples: applyFrame can paint more than once per step() call, so
        // the raw census arrays are NOT indexed 1:1 with our step loop. Sample `.last` after each
        // step(), exactly as NativeLyricsHandoffClockTests does for the single row it tracks.
        var yByIndex: [Int: [CGFloat]] = [:]
        var opacityByIndex: [Int: [CGFloat]] = [:]
        var blurByIndex: [Int: [CGFloat]] = [:]
        for f in 0..<censusFrames {
            let playback = censusStart + TimeInterval(f) * playbackStep
            step(playback: playback)
            semanticTrace.append(surface.debugNativeSemanticIndex ?? -1)
            for idx in trackedIndices {
                let track = surface.debugCensusByIndex[idx]
                yByIndex[idx, default: []].append(track?.y.last ?? (yByIndex[idx]?.last ?? 0))
                opacityByIndex[idx, default: []].append(track?.opacity.last ?? (opacityByIndex[idx]?.last ?? 0))
                blurByIndex[idx, default: []].append(track?.blur.last ?? (blurByIndex[idx]?.last ?? 0))
            }
        }
        surface.debugCensusEnabled = false

        // Boundary frame: first frame whose playback clock reached line i's end (same convention as
        // NativeLyricsHandoffClockTests). Handoff frame: first frame the semantic index reads i+1.
        var boundaryFrame: Int?
        for f in 0..<censusFrames {
            let playback = censusStart + TimeInterval(f) * playbackStep
            if playback >= lineEnd - 0.001 { boundaryFrame = f; break }
        }
        guard let boundaryFrame else {
            XCTFail("boundary frame (line \(i) end) never entered the census window")
            return
        }
        guard let handoffFrame = semanticTrace.firstIndex(where: { $0 == iPlus1 }) else {
            XCTFail("semantic index never advanced to \(iPlus1); trace=\(semanticTrace)")
            return
        }

        // Expected onset table: ask the wave-timing code itself, using the same renderedIndices /
        // lineInterval it was actually configured with (config() above uses lineInterval: 4).
        let renderedIndices = rows.map(\.index)
        let schedule = LyricWaveTiming.staggerSchedule(
            for: renderedIndices, newIndex: iPlus1, lineInterval: 4
        )
        let expectedDelayByIndex: [Int: TimeInterval] = Dictionary(
            uniqueKeysWithValues: schedule.map { ($0.lineIndex, $0.delay) }
        )

        let frameSeconds = 1.0 / 60.0
        let tolFrames: Double = 1.0
        let tolMs = tolFrames * frameSeconds * 1000

        var rowsOut: [RowOnset] = []
        for delta in -3...4 {
            let idx = i + delta
            guard idx >= 0 && idx < rowCount,
                  let y = yByIndex[idx], let op = opacityByIndex[idx], let blur = blurByIndex[idx],
                  y.count == censusFrames, op.count == censusFrames else {
                rowsOut.append(RowOnset(index: idx, deltaFromI: delta, mounted: false,
                                         posOnsetMs: nil, opacityOnsetMs: nil, blurOnsetMs: nil, expectedMs: nil))
                continue
            }
            let pre = max(3, boundaryFrame)
            let baselineY = y.prefix(pre).reduce(0, +) / CGFloat(pre)
            let baselineOp = op.prefix(pre).max() ?? op[boundaryFrame]
            let baselineBlur = blur.isEmpty ? nil : (blur.prefix(pre).max() ?? blur[min(boundaryFrame, blur.count - 1)])

            let posOnset = firstOnset(y, baseline: baselineY, boundaryFrame: boundaryFrame, tol: 0.5)
            let opOnset = firstOnset(op, baseline: baselineOp, boundaryFrame: boundaryFrame, tol: 0.02)
            let blurOnset = baselineBlur.flatMap {
                firstOnset(blur, baseline: $0, boundaryFrame: boundaryFrame, tol: 0.05)
            }

            let expected = expectedDelayByIndex[idx].map { $0 * 1000 }
            rowsOut.append(RowOnset(
                index: idx, deltaFromI: delta, mounted: true,
                posOnsetMs: posOnset.map { Double($0 - boundaryFrame) * frameSeconds * 1000 },
                opacityOnsetMs: opOnset.map { Double($0 - boundaryFrame) * frameSeconds * 1000 },
                blurOnsetMs: blurOnset.map { Double($0 - boundaryFrame) * frameSeconds * 1000 },
                expectedMs: expected
            ))
        }

        func fmt(_ v: Double?) -> String { v.map { String(format: "%7.1f", $0) } ?? "    n/a" }
        print("[WaveOnset] boundaryFrame=\(boundaryFrame) handoffFrame=\(handoffFrame) frameMs=\(String(format: "%.2f", frameSeconds * 1000))")
        print("[WaveOnset] row | Δidx | posOnset(ms) | opacityOnset(ms) | blurOnset(ms) | expected(ms)")
        for r in rowsOut {
            print("[WaveOnset] \(String(format: "%3d", r.index)) | \(String(format: "%+2d", r.deltaFromI))   | \(fmt(r.posOnsetMs))      | \(fmt(r.opacityOnsetMs))         | \(fmt(r.blurOnsetMs))       | \(fmt(r.expectedMs))")
        }

        // Assert position onset == schedule delay (±1 frame) for rows i-1..i+4 that are mounted with
        // a defined expectation. Rows outside the visible window / not carrying an onset are reported
        // n/a per the row table above, not asserted.
        for r in rowsOut where r.deltaFromI >= -1 && r.deltaFromI <= 4 {
            guard r.mounted, let expected = r.expectedMs else {
                XCTFail("row \(r.index) (Δ\(r.deltaFromI)) missing from census or has no schedule entry — cannot verify onset")
                continue
            }
            guard let actual = r.posOnsetMs else {
                XCTFail("row \(r.index) (Δ\(r.deltaFromI)): position never departed baseline within the census window (expected onset \(expected) ms)")
                continue
            }
            XCTAssertEqual(actual, expected, accuracy: tolMs,
                            "row \(r.index) (Δ\(r.deltaFromI)) position onset should match LyricWaveTiming.staggerSchedule's delay (±1 frame = \(String(format: "%.1f", tolMs)) ms)")
        }

        // Report-only: does the incoming row's (i+1) opacity/blur onset coincide with its position
        // onset, or fire at the boundary (0 ms)? No assertion — just print the finding.
        if let incoming = rowsOut.first(where: { $0.deltaFromI == 1 }) {
            let pos = incoming.posOnsetMs, opv = incoming.opacityOnsetMs, blv = incoming.blurOnsetMs
            var opacityVerdict = "n/a"
            if let o = opv {
                if let p = pos, abs(o - p) <= tolMs { opacityVerdict = "coincides with position" }
                else if abs(o) <= tolMs { opacityVerdict = "fires at boundary" }
                else { opacityVerdict = "fires independently" }
            }
            print("[WaveOnset] incoming row i+1=\(incoming.index): posOnset=\(fmt(pos)) opacityOnset=\(fmt(opv)) blurOnset=\(fmt(blv)) — opacity \(opacityVerdict)")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Same lockstep drive as the topdown test above, but with the `sync` feel arm
    // active (nanopod://debug/feel/wave/sync): the outgoing row i and incoming
    // row i+1 must depart their baseline on the SAME frame (±1 frame), and rows
    // i+2.. must follow LyricWaveTiming.staggerSchedule's live `.syncPair` table.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    @MainActor
    func test_syncArm_outgoingAndIncomingRowsShareOnsetFrame() {
        NativeLyricsFeelParity.testingWave = .sync
        defer { NativeLyricsFeelParity.testingWave = nil }

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rowCount = 20
        let rows = makeRows(rowCount)
        surface.debugSkipDedupe = true

        let i = 5
        let iPlus1 = i + 1
        let lineEnd = rows[i].displayLine.line.endTime
        let previousStart = rows[i].displayLine.line.startTime

        var wall: CFTimeInterval = 1_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let wallStepPerFrame: TimeInterval = 1.0 / 60.0
        let playbackStep = 1.0 / 60.0
        func step(playback: TimeInterval) {
            wall += wallStepPerFrame
            date = date.addingTimeInterval(playbackStep)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc))
            surface.debugTick(displayInterval: wallStepPerFrame)
            RunLoop.main.run(until: Date())
        }

        let warmupStart = previousStart + 0.1
        let warmupFrames = 60
        mc.syncPlaybackClock(to: warmupStart, playing: true, at: date)
        surface.configure(config(rows, current: i, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for f in 0..<warmupFrames {
            step(playback: warmupStart + TimeInterval(f) * playbackStep)
        }

        let trackedIndices = (-3...4).map { i + $0 }.filter { $0 >= 0 && $0 < rowCount }
        let censusStart = warmupStart + TimeInterval(warmupFrames) * playbackStep
        surface.debugResetCensus()
        surface.debugCensusEnabled = true
        let censusFrames = 72
        var semanticTrace: [Int] = []
        var yByIndex: [Int: [CGFloat]] = [:]
        for f in 0..<censusFrames {
            let playback = censusStart + TimeInterval(f) * playbackStep
            step(playback: playback)
            semanticTrace.append(surface.debugNativeSemanticIndex ?? -1)
            for idx in trackedIndices {
                let track = surface.debugCensusByIndex[idx]
                yByIndex[idx, default: []].append(track?.y.last ?? (yByIndex[idx]?.last ?? 0))
            }
        }
        surface.debugCensusEnabled = false

        var boundaryFrame: Int?
        for f in 0..<censusFrames {
            let playback = censusStart + TimeInterval(f) * playbackStep
            if playback >= lineEnd - 0.001 { boundaryFrame = f; break }
        }
        guard let boundaryFrame else {
            XCTFail("boundary frame (line \(i) end) never entered the census window")
            return
        }
        guard semanticTrace.firstIndex(where: { $0 == iPlus1 }) != nil else {
            XCTFail("semantic index never advanced to \(iPlus1); trace=\(semanticTrace)")
            return
        }

        let renderedIndices = rows.map(\.index)
        let schedule = LyricWaveTiming.staggerSchedule(
            for: renderedIndices, newIndex: iPlus1, lineInterval: 4, shape: .syncPair
        )
        let expectedDelayByIndex: [Int: TimeInterval] = Dictionary(
            uniqueKeysWithValues: schedule.map { ($0.lineIndex, $0.delay) }
        )
        XCTAssertEqual(expectedDelayByIndex[i] ?? -1, 0, accuracy: 0.0001, "sync schedule: outgoing row fires at the boundary")
        XCTAssertEqual(expectedDelayByIndex[iPlus1] ?? -1, 0, accuracy: 0.0001, "sync schedule: incoming row fires at the boundary")

        let frameSeconds = 1.0 / 60.0
        let tolFrames: Double = 1.0
        let tolMs = tolFrames * frameSeconds * 1000

        func posOnsetMs(_ idx: Int) -> Double? {
            guard let y = yByIndex[idx], y.count == censusFrames else { return nil }
            let pre = max(3, boundaryFrame)
            let baseline = y.prefix(pre).reduce(0, +) / CGFloat(pre)
            guard let onset = firstOnset(y, baseline: baseline, boundaryFrame: boundaryFrame, tol: 0.5) else {
                return nil
            }
            return Double(onset - boundaryFrame) * frameSeconds * 1000
        }

        var rowsOut: [(index: Int, posOnsetMs: Double?, expectedMs: Double?)] = []
        for delta in -3...4 {
            let idx = i + delta
            guard idx >= 0 && idx < rowCount else { continue }
            rowsOut.append((idx, posOnsetMs(idx), expectedDelayByIndex[idx].map { $0 * 1000 }))
        }
        print("[WaveOnsetSync] boundaryFrame=\(boundaryFrame) frameMs=\(String(format: "%.2f", frameSeconds * 1000))")
        print("[WaveOnsetSync] row | posOnset(ms) | expected(ms)")
        for r in rowsOut {
            let pos = r.posOnsetMs.map { String(format: "%7.1f", $0) } ?? "    n/a"
            let exp = r.expectedMs.map { String(format: "%7.1f", $0) } ?? "    n/a"
            print("[WaveOnsetSync] \(String(format: "%3d", r.index)) | \(pos)      | \(exp)")
        }

        // Outgoing (i) and incoming (i+1) must share the same onset frame — both are
        // scheduled at delay 0, so both should already be moving by the boundary frame
        // (or within ±1 frame either side of it).
        guard let outgoingPos = posOnsetMs(i), let incomingPos = posOnsetMs(iPlus1) else {
            XCTFail("outgoing (\(i)) or incoming (\(iPlus1)) row position never departed baseline")
            return
        }
        XCTAssertEqual(outgoingPos, incomingPos, accuracy: tolMs,
                       "sync arm: outgoing row \(i) and incoming row \(iPlus1) must start on the same frame")
        XCTAssertEqual(outgoingPos, 0, accuracy: tolMs, "sync arm: boundary pair fires at the boundary frame, not staggered")

        // Rows i+2.. must follow the live sync schedule (±1 frame).
        for delta in 2...4 {
            let idx = i + delta
            guard idx < rowCount, let expected = expectedDelayByIndex[idx].map({ $0 * 1000 }) else { continue }
            guard let actual = posOnsetMs(idx) else {
                XCTFail("row \(idx) (i+\(delta)) position never departed baseline (expected onset \(expected) ms)")
                continue
            }
            XCTAssertEqual(actual, expected, accuracy: tolMs,
                            "row \(idx) (i+\(delta)) position onset should match the live .syncPair schedule (±1 frame)")
        }
    }
}
