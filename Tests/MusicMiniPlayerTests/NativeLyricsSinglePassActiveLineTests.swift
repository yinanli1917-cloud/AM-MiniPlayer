import XCTest
import AppKit
@testable import MusicMiniPlayerCore

/// 2026-09-20: the v2.8-model single-pass active line (NativeLyricsActiveLineDrawLayer).
final class NativeLyricsSinglePassActiveLineTests: XCTestCase {
    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.testingActiveLine = nil
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

    private func wordLine(start: TimeInterval = 0, duration: TimeInterval = 4) -> LyricLine {
        let e = start + duration
        let w = duration / 4
        return LyricLine(
            text: "hello brave new world",
            startTime: start, endTime: e,
            words: [
                LyricWord(word: "hello ", startTime: start, endTime: start + w),
                LyricWord(word: "brave ", startTime: start + w, endTime: start + 2 * w),
                LyricWord(word: "new ", startTime: start + 2 * w, endTime: start + 3 * w),
                LyricWord(word: "world", startTime: start + 3 * w, endTime: e),
            ]
        )
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

    /// Renders a layer into a grayscale luminance grid (top-left origin).
    private func luminance(of layer: CALayer) -> [[CGFloat]] {
        let w = Int(layer.bounds.width.rounded(.up)), h = Int(layer.bounds.height.rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        layer.render(in: ctx)
        guard let data = ctx.data else { return [] }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var rows: [[CGFloat]] = []
        for y in 0..<h {
            var row: [CGFloat] = []
            for x in 0..<w {
                // CG bitmap rows are bottom-up; flip so index 0 is the top.
                let i = ((h - 1 - y) * w + x) * 4
                row.append(CGFloat(px[i + 3]) / 255) // premultiplied alpha == white ink coverage
            }
            rows.append(row)
        }
        return rows
    }

    @MainActor
    func test_midLine_singlePassLayerOwnsActiveLine_tilesAndBaseHidden_inkUprightAndSwept() throws {
        NativeLyricsFeelParity.testingActiveLine = .singlePass
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = (0..<4).map { i in row(wordLine(start: TimeInterval(i) * 4), index: i) }
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }
        let step = 1.0 / 60.0
        func tick(_ playback: TimeInterval, current: Int) {
            wall += step
            date = date.addingTimeInterval(step)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: current, mc: mc))
            surface.debugTick(displayInterval: step)
            RunLoop.main.run(until: Date())
        }
        mc.syncPlaybackClock(to: 1.5, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<24 { tick(1.5 + TimeInterval(i) * step, current: 0) }
        guard let active = surface.debugRowView(forIndex: 0) else { return XCTFail("row 0 not mounted") }

        // Ownership: one layer draws the active line; everything tile-era is off.
        XCTAssertFalse(active.activeLineDrawLayer.isHidden)
        XCTAssertTrue(active.debugMainTextLayerHidden, "whole-line CATextLayer base must be hidden while single-pass draws")
        XCTAssertEqual(active.debugMainBrightOpacity, 0, "line-level bright layer must be off")
        XCTAssertTrue(active.debugMainBrightWordGlyphOpacities.allSatisfy { $0 == 0 }, "no visible bright tiles")
        let input = try XCTUnwrap(active.activeLineDrawLayer.frameInput)
        XCTAssertEqual(input.runs.count, 4)
        XCTAssertEqual(input.lines.count, 1)
        XCTAssertGreaterThan(input.lines[0].wavefrontX, 0)

        // Pixels: upright, left-aligned, and brighter left of the wavefront than right of it.
        active.activeLineDrawLayer.displayIfNeeded()
        let lum = luminance(of: active.activeLineDrawLayer)
        XCTAssertFalse(lum.isEmpty)
        let h = lum.count, w = lum[0].count
        let inkRows = (0..<h).filter { y in lum[y].contains { $0 > 0.2 } }
        XCTAssertFalse(inkRows.isEmpty, "single-pass layer drew nothing")
        XCTAssertLessThan(inkRows.min() ?? h, h / 2, "ink must start in the top half (upright text)")
        let wave = Int(input.lines[0].wavefrontX)
        func mean(_ x0: Int, _ x1: Int) -> CGFloat {
            var s: CGFloat = 0; var n: CGFloat = 0
            for y in inkRows { for x in max(0, x0)..<min(w, x1) { s += lum[y][x]; n += 1 } }
            return n > 0 ? s / n : 0
        }
        let left = mean(0, max(1, wave - 14)), right = mean(min(w - 1, wave + 14), w)
        XCTAssertGreaterThan(left, right * 1.3, "swept region (left of wavefront) must read brighter than unswept")

        // Deactivation: the base comes back, the draw layer goes away, same frame.
        for i in 0..<6 { tick(4.2 + TimeInterval(i) * step, current: 1) }
        XCTAssertTrue(active.activeLineDrawLayer.isHidden)
        XCTAssertFalse(active.debugMainTextLayerHidden)
    }
}
