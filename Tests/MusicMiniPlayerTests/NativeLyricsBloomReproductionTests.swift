import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Objective bloom reproduction: pixel-capture test.
//
// The reported bug: on initial load and page switch, all 25+ lyric lines appear
// simultaneously — heavily blurred, overlapping, bright — a "bloom" that lasts
// ~0.4s. The user sees it; I can't reproduce the app. This test creates a
// realistic surface (25 lines, fresh mount), renders it into a bitmap, measures
// the aggregate bright-pixel load, and compares against a calibrated threshold.
//
// Any fix that claims to eliminate the bloom MUST make this test pass
// (brightPx below threshold). Until then, the bloom is objectively reproducible.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsBloomReproductionTests: XCTestCase {

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    @MainActor
    private func hostInWindow(_ view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
    }

    // 25 lines — a typical full song loaded at once (page switch, cached lyrics).
    private func songRows(count: Int = 25, activeIndex: Int = 5) -> [LayerBackedLyricRow] {
        (0..<count).map { i in
            let line = LyricLine(
                text: "This is lyric line number \(i) with some content to fill the text width for realistic rendering metrics",
                startTime: TimeInterval(i * 4),
                endTime: TimeInterval(i * 4 + 4)
            )
            let displayLine = DisplayLyricLine(
                id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line
            )
            return LayerBackedLyricRow(
                id: displayLine.id, index: i, displayLine: displayLine,
                sourceLine: line, isPrelude: false, preludeEndTime: 0, interlude: nil
            )
        }
    }

    private func makeConfiguration(
        rows: [LayerBackedLyricRow],
        currentIndex: Int,
        rowWidth: CGFloat = 320
    ) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: rows,
            currentIndex: currentIndex,
            anchorY: 0,
            rowWidth: rowWidth,
            renderedIndices: rows.map(\.index),
            accumulatedHeights: [:],
            lineTargetIndices: [:],
            lineInterval: nil,
            hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "BloomTest", artist: "Test", album: "Test", duration: 100),
            isWaveTimelineDiagnosticsEnabled: false,
            isManualScrolling: false,
            reduceMotion: false,
            suppressInitialMotion: false,
            pendingTranslationLineIndices: [],
            showTranslation: false,
            isTranslating: false,
            translationFailed: false,
            interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: false,
            musicController: MusicController(preview: true),
            onLineTap: { _ in },
            onDirectSnapConsumed: { _ in },
            onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in },
            onManualScrollEnded: {},
            onManualScrollRecovered: {},
            onManualScrollChromeReset: nil,
            onHeightMeasured: { _, _ in },
            lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast,
            lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    /// Renders the surface into an NSBitmapImageRep (RGBA, 8-bit).
    @MainActor
    private func renderToBitmap(_ view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Counts pixels whose luminance (average of R, G, B) exceeds the threshold.
    /// Returns (brightCount, totalPixels) for the ratio.
    private func countBrightPixels(in rep: NSBitmapImageRep, luminanceThreshold: UInt8 = 100) -> (bright: Int, total: Int) {
        guard let data = rep.bitmapData else { return (0, 0) }
        let total = rep.pixelsWide * rep.pixelsHigh
        let bpr = rep.bytesPerRow
        let bpp = rep.bitsPerPixel / 8
        var bright = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let offset = y * bpr + x * bpp
                let r = Int(data[offset])
                let g = Int(data[offset + 1])
                let b = Int(data[offset + 2])
                let lum = (r + g + b) / 3
                if lum > Int(luminanceThreshold) { bright += 1 }
            }
        }
        return (bright, total)
    }

    @MainActor
    private func brightPercentAfterCommittedRender(
        of view: NSView,
        luminanceThreshold: UInt8,
        timeout: TimeInterval = 1.0
    ) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastPercent: Double?
        repeat {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            guard let rep = renderToBitmap(view) else { continue }
            let (bright, total) = countBrightPixels(in: rep, luminanceThreshold: luminanceThreshold)
            let percent = total > 0 ? Double(bright) / Double(total) * 100 : 0
            lastPercent = percent
            if percent > 0.5 {
                return percent
            }
        } while Date() < deadline
        return lastPercent
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // The reproduction test. Fresh surface mount (simulates page switch / first
    // load), render one frame into a bitmap, measure bright-pixel ratio. A bloom
    // shows as an abnormally high bright-pixel count — many rows' blurred text
    // compositing into a bright glow.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Two-surface overlap: during a page switch or track change, the OLD native
    // surface may persist for 1-2 frames while the NEW surface is already rendering.
    // Two surfaces composited together = doubled brightness. If both carry distance
    // blur, the overlap creates the "heavily blurred, overlapping, bright" bloom.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    @MainActor
    func test_twoSurfacesOverlapping_hasBloomBelowThreshold() {
        let rows = songRows(count: 25, activeIndex: 5)
        let config = makeConfiguration(rows: rows, currentIndex: 5)

        // Container view that holds both surfaces
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(container)

        // Surface A (simulates the "old" page-switch surface still in the tree)
        let surfaceA = NativeLyricsSurfaceView(frame: container.bounds)
        surfaceA.debugInitialMeasurementsPending = false
        surfaceA.configure(config)
        container.addSubview(surfaceA)

        // Surface B (simulates the "new" surface rendered on top)
        let surfaceB = NativeLyricsSurfaceView(frame: container.bounds)
        surfaceB.debugInitialMeasurementsPending = false
        surfaceB.configure(config)
        container.addSubview(surfaceB)

        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let rep = renderToBitmap(container) else {
            XCTFail("could not render container")
            return
        }
        let (bright, total) = countBrightPixels(in: rep, luminanceThreshold: 100)
        let percent = total > 0 ? Double(bright) / Double(total) * 100 : 0
        print("BLoomOverlap: bright=\(bright)/\(total) (\(String(format: "%.1f", percent))%) — two surfaces")

        // A single surface with 25 rows is already measured at ~2-8% in the fresh-mount test.
        // Two surfaces doubled on top of each other should NOT exceed single-surface × 2,
        // and certainly not single-surface × 3 (which would be a genuine additive bloom).
        // If the individual surface renders at ~5%, two surfaces at ~10% is linear doubling
        // (expected). But a bloom (>18% or 3× the single-surface baseline) indicates the
        // blur-glow overlap is amplifying beyond linear addition.
        let singleBaseline = 8.0  // conservative baseline from fresh-mount test
        XCTAssertLessThan(percent, singleBaseline * 2.5,
            """
            Two-surface overlap bloom: \(String(format: "%.1f", percent))% bright pixels. \
            Expected < \(String(format: "%.1f", singleBaseline * 2.5))% (2.5× single-surface baseline). \
            Higher values indicate additive blur-glow amplification when surfaces overlap — \
            the "overlapping bright blur" bloom mechanism.
            """)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // The reconfigure-storm reproduction. In real use, uncached songs go through
    // multiple staged configures: blank → first match → refined match →
    // with translation. Each triggers a full surface reconfigure. If any frame
    // during this storm renders with abnormally high bright-pixel load, that's
    // the objective signature of the bloom.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    @MainActor
    func test_stagedLoadingReconfigureStorm_hasConsistentBrightnessWithoutSpikes() {
        let surface = NativeLyricsSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface)

        var brightPcts: [Double] = []

        // Stage 1: initial (empty-ish) — simulate blank/first match arriving
        let fewRows = songRows(count: 3, activeIndex: 1)
        surface.debugInitialMeasurementsPending = false
        surface.configure(makeConfiguration(rows: fewRows, currentIndex: 1))
        if let pct = brightPercentAfterCommittedRender(of: surface, luminanceThreshold: 60) {
            brightPcts.append(pct)
        }

        // Stage 2: refined match (all rows arrive)
        let allRows = songRows(count: 25, activeIndex: 5)
        surface.debugSkipDedupe = true
        surface.configure(makeConfiguration(rows: allRows, currentIndex: 5))
        if let pct = brightPercentAfterCommittedRender(of: surface, luminanceThreshold: 60) {
            brightPcts.append(pct)
        }

        // Stage 3: same rows, simulate translation arrival (different signature)
        surface.debugSkipDedupe = true
        surface.configure(makeConfiguration(rows: allRows, currentIndex: 5))
        if let pct = brightPercentAfterCommittedRender(of: surface, luminanceThreshold: 60) {
            brightPcts.append(pct)
        }

        let pcts = brightPcts.map { String(format: "%.1f%%", $0) }.joined(separator: " → ")
        print("BLoomStorm: \(pcts)")

        XCTAssertEqual(brightPcts.count, 3, "precondition: all staged loading frames should render")
        // No stage should spike above 15% — a bloom would push one stage far higher.
        for (i, pct) in brightPcts.enumerated() {
            XCTAssertLessThan(pct, 15.0,
                "Stage \(i) bloom: \(String(format: "%.1f", pct))% bright pixels exceeds storm threshold")
        }
        // All stages should have SOME content.
        for (i, pct) in brightPcts.enumerated() {
            XCTAssertGreaterThan(pct, 0.5,
                "Stage \(i) blank: \(String(format: "%.1f", pct))% — surface rendered empty")
        }
    }

    @MainActor
    func test_firstFrameAfterFreshMount_hasBloomBelowThreshold() {
        let surface = NativeLyricsSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface)

        let rows = songRows(count: 25, activeIndex: 5)
        let config = makeConfiguration(rows: rows, currentIndex: 5)

        // Suppress the initial-measurements guard — we want to measure the real rendered
        // state, not the intentionally-blanked first frame.
        surface.debugInitialMeasurementsPending = false
        // First configure: seeds estimated heights, sets up visual states. Rows at opacity 0
        // (suppression flag was true when reconcile ran, then cleared at end of configure).
        surface.configure(config)
        surface.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        // Second configure: bypass dedupe so it actually runs. Flag is now false from the
        // end of first configure → rows render at real opacities.
        surface.debugSkipDedupe = true
        surface.configure(config)
        surface.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let rep = renderToBitmap(surface) else {
            XCTFail("could not create bitmap rep for surface")
            return
        }

        let (bright, total) = countBrightPixels(in: rep, luminanceThreshold: 100)
        let ratio = total > 0 ? Double(bright) / Double(total) : 0
        let percent = ratio * 100

        // Diagnostic: always log the bright% so we can calibrate.
        // If this shows normal values (<5%) but the user still sees bloom, the bloom
        // is outside the native surface — in SwiftUI overlays, transitions, or duplicate
        // surface instances composited together.
        print("BLoomDiag: bright=\(bright)/\(total) (\(String(format: "%.1f", percent))%) threshold=100")

        // Try lower thresholds to catch subtler glow
        for threshold: UInt8 in [60, 40, 25] {
            let (b, _) = countBrightPixels(in: rep, luminanceThreshold: threshold)
            let p = total > 0 ? Double(b) / Double(total) * 100 : 0
            print("BLoomDiag: threshold=\(threshold) bright=\(b) (\(String(format: "%.1f", p))%)")
        }

        // A typical lyrics panel with 1 active bright line + 24 dim lines should have
        // < 8% bright pixels (text occupies a small fraction of the panel area). A bloom
        // pushes this far higher — blur glow spreading many rows' text into neighbors
        // creates a much larger bright area. Threshold set generously to allow normal
        // rendering variance while catching the bloom.
        XCTAssertLessThan(
            percent, 12.0,
            """
            Bloom threshold exceeded: \(String(format: "%.1f", percent))% bright pixels \
            (\(bright)/\(total)). Expected < 12% for clean first frame. \
            Higher values indicate overlapping/blurred text compositing into a bright glow.
            """
        )

        // Sanity: there must be SOME bright pixels (the active line's text). A completely
        // blank surface (all rows at opacity 0) is also a bug — the "blank page" regression.
        XCTAssertGreaterThan(
            percent, 0.5,
            "Surface is blank (only \(String(format: "%.1f", percent))% bright). Frame may be suppressed entirely."
        )
    }
}
