import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Stage bundle 3g item 5 (research/repro-2026-09-18-lyrics-render-3g.md), NEW regression: founder
// reports "切歌后又出现以前那种 bloom glitch" (the old bloom is back on TRACK CHANGE) — lines
// collapse from/burst into the wrong position at the instant of switching songs.
//
// NativeLyricsBloomReproductionTests already covers fresh mount, two overlapping surfaces, and a
// staged-loading reconfigure storm — but NOT the specific case of an ALREADY-SETTLED, already-
// playing surface being reconfigured with a DIFFERENT SONG's rows (different row identities, not
// just a line-index change within the same song). That is structurally different from the existing
// coverage: pooled row views are being handed brand-new identities while the surface itself has
// accumulated real settled state (positions, blur, opacity) from the PREVIOUS song. If ANY commit
// between 5e85f31..HEAD (suspects: e9ed7b4, f1b8d8f, 59647e1, dcd7b6a, d8f45e8) broke the row-
// identity-vs-pooled-view reconciliation for this specific transition, this is where it would show.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsTrackChangeBloomTests: XCTestCase {
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
        if let contentView = hostWindow?.contentView {
            stopHostedSurfaces(in: contentView)
        }
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    @MainActor
    private func hostInWindow(_ view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
    }

    @MainActor
    private func stopHostedSurfaces(in view: NSView) {
        if let surface = view as? NativeLyricsSurfaceView { surface.stopAnimations() }
        view.subviews.forEach { stopHostedSurfaces(in: $0) }
    }

    /// Distinct `idPrefix` per song so row IDENTITIES genuinely differ across the switch (a real
    /// track change never reuses row ids — pooled VIEWS get reused, but the row MODEL objects and
    /// their ids are always fresh for a new song).
    private func songRows(idPrefix: String, count: Int = 25, startOffset: TimeInterval = 0) -> [LayerBackedLyricRow] {
        (0..<count).map { i in
            let line = LyricLine(
                text: "\(idPrefix) lyric line \(i) with enough content to fill the row width",
                startTime: startOffset + TimeInterval(i * 4),
                endTime: startOffset + TimeInterval(i * 4 + 4)
            )
            let displayLine = DisplayLyricLine(
                id: "\(idPrefix)-r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line
            )
            return LayerBackedLyricRow(
                id: displayLine.id, index: i, displayLine: displayLine,
                sourceLine: line, isPrelude: false, preludeEndTime: 0, interlude: nil
            )
        }
    }

    private func makeConfiguration(rows: [LayerBackedLyricRow], currentIndex: Int, rowWidth: CGFloat = 320) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: currentIndex, anchorY: 0, rowWidth: rowWidth,
            renderedIndices: rows.map(\.index), accumulatedHeights: [:], lineTargetIndices: [:],
            lineInterval: nil, hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "BloomTest", artist: "Test", album: "Test", duration: 100),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: MusicController(preview: true),
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    @MainActor
    private func renderToBitmap(_ view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private func countBrightPixels(in rep: NSBitmapImageRep, luminanceThreshold: UInt8 = 100) -> (bright: Int, total: Int) {
        guard let data = rep.bitmapData else { return (0, 0) }
        let total = rep.pixelsWide * rep.pixelsHigh
        let bpr = rep.bytesPerRow
        let bpp = rep.bitsPerPixel / 8
        var bright = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let offset = y * bpr + x * bpp
                let r = Int(data[offset]), g = Int(data[offset + 1]), b = Int(data[offset + 2])
                if (r + g + b) / 3 > Int(luminanceThreshold) { bright += 1 }
            }
        }
        return (bright, total)
    }

    /// Row Y-position spread: a "collapse" (many rows landing at/near the same Y, e.g. all at 0)
    /// shows as an abnormally SMALL standard deviation of Y across mounted rows relative to a
    /// settled baseline — the geometric signature the founder's "行从错误位置坍缩" describes,
    /// independent of the pixel-brightness metric (which catches blur/opacity overlap, not
    /// position collapse specifically).
    @MainActor
    private func rowYStandardDeviation(_ surface: NativeLyricsSurfaceView, indices: Range<Int>) -> CGFloat? {
        let ys = indices.compactMap { surface.debugRowView(forIndex: $0)?.frame.origin.y }
        guard ys.count > 2 else { return nil }
        let mean = ys.reduce(0, +) / CGFloat(ys.count)
        let variance = ys.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(ys.count)
        return variance.squareRoot()
    }

    @MainActor
    func test_trackChange_onAlreadySettledSurface_firstFrameHasNoBloomOrPositionCollapse() {
        let surface = NativeLyricsSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface)
        surface.debugInitialMeasurementsPending = false

        // Settle on song A first — mirrors a real session where a song has been playing for a
        // while (real settled positions/blur/opacity), not a fresh mount.
        let songA = songRows(idPrefix: "songA", count: 25)
        surface.configure(makeConfiguration(rows: songA, currentIndex: 5))
        surface.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        surface.debugSkipDedupe = true
        surface.configure(makeConfiguration(rows: songA, currentIndex: 5))
        surface.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let settledSpread = rowYStandardDeviation(surface, indices: 0..<25)
        XCTAssertNotNil(settledSpread, "precondition: song A must be settled with multiple mounted rows")
        guard let settledSpread else { return }
        XCTAssertGreaterThan(settledSpread, 20, "precondition: settled rows must actually be spread out (sanity check on the fixture)")

        // TRACK CHANGE: brand-new song, brand-new row identities, active index resets to near the
        // top (index 0) — exactly what happens when a new track starts playing.
        let songB = songRows(idPrefix: "songB", count: 25)
        surface.debugSkipDedupe = true
        surface.configure(makeConfiguration(rows: songB, currentIndex: 0))
        surface.layoutSubtreeIfNeeded()

        // FIRST FRAME after the switch — this is where a collapse/bloom would show.
        guard let firstFrameRep = renderToBitmap(surface) else {
            XCTFail("could not render first frame after track change"); return
        }
        let (bright, total) = countBrightPixels(in: firstFrameRep, luminanceThreshold: 100)
        let percent = total > 0 ? Double(bright) / Double(total) * 100 : 0
        let firstFrameSpread = rowYStandardDeviation(surface, indices: 0..<25)
        print("[TrackChangeBloom] first frame after switch: bright=\(bright)/\(total) (\(String(format: "%.1f", percent))%) "
            + "rowYSpread=\(String(describing: firstFrameSpread))")

        XCTAssertLessThan(percent, 12.0,
            "track-change first frame: \(String(format: "%.1f", percent))% bright pixels — bloom threshold exceeded")

        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        surface.debugTick(displayInterval: 1.0 / 60.0)
        let secondFrameSpread = rowYStandardDeviation(surface, indices: 0..<25)
        print("[TrackChangeBloom] second frame after switch: rowYSpread=\(String(describing: secondFrameSpread))")

        // A genuine "collapse then burst" would show up as an abnormally tight Y spread on the
        // first frame(s) after the switch relative to the pre-switch settled baseline, since rows
        // that haven't yet received their real per-row target Y default toward a shared origin.
        if let firstFrameSpread {
            XCTAssertGreaterThan(firstFrameSpread, settledSpread * 0.5,
                "track-change first frame row-Y spread (\(firstFrameSpread)) collapsed to less than half "
                + "the pre-switch settled spread (\(settledSpread)) — rows bunched near a shared origin")
        }
    }
}
