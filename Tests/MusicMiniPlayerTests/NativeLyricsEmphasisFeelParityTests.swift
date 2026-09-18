import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Contrast-arm guard for the emphasis-word ghost (founder-approved 2026-09-17,
// research/repro-2026-09-17-lyrics-render-3c.md §B). `current` keeps the historical
// two-object split (`emphasisGlyphLayers`, positioned independently of the ordinary
// per-word tiles) — structurally ghost-prone, but left unchanged here as the control arm.
// `v28`/`amll` fold emphasis words into the SAME per-glyph tile pipeline every other word
// uses (`applyMainWordFloatGlyphLayers`) — one positioned object per glyph, never two.
//
// (a) v28/amll must never populate the legacy `emphasisGlyphLayers` pool (no second
//     independently-positioned object).
// (b) amll's glow-bitmap sibling's position/transform must equal its sharp tile's, every
//     sampled frame, zero tolerance (they are copied from the same write, not computed
//     independently — this pins that they can never drift apart).
// (c) current is unchanged (still populates the legacy pool, exactly as before this arm
//     existed).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsEmphasisFeelParityTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.resetTestingOverrides()
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
    }

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(
        rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
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

    /// Same fixture as `LyricsRenderDefects20260914ReproTests.emphasisLine()` — "about" (index 3,
    /// duration 2.2s) is the sole emphasis-eligible run.
    private func emphasisLine() -> LyricLine {
        LyricLine(
            text: "what it's all about",
            startTime: 10, endTime: 16.2,
            words: [
                LyricWord(word: "what ", startTime: 10.0, endTime: 10.6),
                LyricWord(word: "it's ", startTime: 10.6, endTime: 11.2),
                LyricWord(word: "all ", startTime: 11.2, endTime: 11.8),
                LyricWord(word: "about", startTime: 11.8, endTime: 14.0),
            ]
        )
    }

    @MainActor
    private func driveEmphasisWord(
        mode: NativeLyricsFeelParity.EmphasisMode,
        currentTime: TimeInterval,
        width: CGFloat = 320
    ) -> NativeLyricsRowView {
        NativeLyricsFeelParity.testingSweep = .v28
        NativeLyricsFeelParity.testingEmphasis = mode
        let line = emphasisLine()
        let target = row(for: line, index: 0)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        host(view, NSSize(width: width, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240
        mc.syncPlaybackClock(to: currentTime, playing: true)
        let cfg = config(rows: [target], current: 0, mc: mc, width: width)
        view.configure(row: target, configuration: cfg)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: cfg)
        return view
    }

    // Mid-sweep of "about" — the same shot LyricsRenderDefects20260914ReproTests uses to
    // characterize the emphasis peak (emphasisWeight near its max).
    private static let midEmphasisTime: TimeInterval = 11.8 + 1.32

    // (c) current: unchanged — still populates the legacy independently-positioned pool.
    @MainActor
    func test_current_stillPopulatesLegacyEmphasisGlyphLayerPool() {
        let view = driveEmphasisWord(mode: .current, currentTime: Self.midEmphasisTime)
        XCTAssertFalse(
            view.debugEmphasisGlyphLayerPoolAllHidden,
            "current arm must be unchanged: it still renders emphasis words through the separate emphasisGlyphLayers pool"
        )
    }

    // (a) v28/amll: never a second independently-positioned object.
    @MainActor
    func test_v28_neverPopulatesLegacyEmphasisGlyphLayerPool() {
        let view = driveEmphasisWord(mode: .v28, currentTime: Self.midEmphasisTime)
        XCTAssertTrue(
            view.debugEmphasisGlyphLayerPoolAllHidden,
            "v28 arm must fold emphasis words into the ordinary per-word tile pipeline — the legacy pool must stay empty"
        )
    }

    @MainActor
    func test_amll_neverPopulatesLegacyEmphasisGlyphLayerPool() {
        let view = driveEmphasisWord(mode: .amll, currentTime: Self.midEmphasisTime)
        XCTAssertTrue(
            view.debugEmphasisGlyphLayerPoolAllHidden,
            "amll arm must fold emphasis words into the ordinary per-word tile pipeline — the legacy pool must stay empty"
        )
    }

    // (b) amll: the glow-bitmap sibling can never be independently wrong — its position/transform
    // are copied from the sharp tile at the same call site, so equality must hold at zero
    // tolerance for every glyph whose glow is currently visible.
    @MainActor
    func test_amll_glowLayerPositionMatchesBrightTile_zeroTolerance() {
        var sawVisibleGlow = false
        // Sample across the emphasis window (not just the peak) — the glow mounts/unmounts as
        // emphasisWeight crosses the threshold, so scan several ticks to catch it mounted.
        for t in stride(from: 11.85, through: 13.9, by: 0.05) {
            let view = driveEmphasisWord(mode: .amll, currentTime: t)
            for pair in view.debugEmphasisGlowTilePairs where pair.glowVisible {
                sawVisibleGlow = true
                XCTAssertEqual(pair.brightPosition.x, pair.glowPosition.x, accuracy: 0,
                                "glow sibling x must be BYTE-IDENTICAL to its bright tile at t=\(t) — it is copied, never computed independently")
                XCTAssertEqual(pair.brightPosition.y, pair.glowPosition.y, accuracy: 0,
                                "glow sibling y must be BYTE-IDENTICAL to its bright tile at t=\(t) — it is copied, never computed independently")
                XCTAssertEqual(pair.brightScale, pair.glowScale, accuracy: 0,
                                "glow sibling scale must be BYTE-IDENTICAL to its bright tile at t=\(t) — it is copied, never computed independently")
            }
        }
        XCTAssertTrue(sawVisibleGlow, "fixture/scan window must actually hit the glow-visible part of the emphasis window at least once, or this test proves nothing")
    }

    // v28: the glow is a real CALayer shadow on the SAME tile object — cannot desync from itself
    // by construction. Sanity check that it actually engages (shadowOpacity > 0) somewhere in the
    // emphasis window, so a future regression that silently drops the shadow assignment is caught.
    @MainActor
    func test_v28_glowShadowEngagesOnTheSharedTile() {
        var maxShadowOpacity: Float = 0
        for t in stride(from: 11.85, through: 13.9, by: 0.05) {
            let view = driveEmphasisWord(mode: .v28, currentTime: t)
            maxShadowOpacity = max(maxShadowOpacity, view.debugMainBrightWordGlyphShadowOpacities.max() ?? 0)
        }
        XCTAssertGreaterThan(maxShadowOpacity, 0, "v28's shadow-on-shared-tile glow must engage somewhere in the emphasis window")
    }

    // amll: no live CIFilter is ever attached to `layer.filters` (the banned-patterns.md trap —
    // a stored CIFilter's mutated inputRadius is silently ignored by the render server). The glow
    // is `layer.contents` set once from a cached, offline-rendered CGImage.
    @MainActor
    func test_amll_glowLayerNeverUsesLiveCIFilter() {
        for t in stride(from: 11.85, through: 13.9, by: 0.05) {
            let view = driveEmphasisWord(mode: .amll, currentTime: t)
            XCTAssertTrue(
                view.debugEmphasisGlowLayersHaveNoLiveFilters,
                "amll's glow sibling layers must never carry a live CIFilter at t=\(t) — the bitmap is pre-rendered offline and assigned to layer.contents"
            )
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Stage bundle 3g item 6 (research/repro-2026-09-18-lyrics-render-3g.md): founder says the old
    // "glow-blur highlight" look was good and doesn't know when ghosting was introduced; default
    // arm is `amll`. `test_amll_glowLayerPositionMatchesBrightTile_zeroTolerance` above already
    // covers this at 0.05s steps via the single-configure `driveEmphasisWord` helper (which
    // re-derives a FRESH plan/layout per call, not a continuously-ticked real surface). This test
    // strengthens that coverage two ways: (1) real 1/60s frame-by-frame granularity (matching an
    // actual display link, not a coarser sample grid), and (2) drives a REAL, continuously-ticked
    // `NativeLyricsSurfaceView` (deterministic clock) so per-frame state carries over exactly like
    // production, instead of each sample being an independent one-shot reconfigure. Covers all
    // three contrast arms uniformly in one loop, as the coordinator asked, even though `current`
    // is the historical control arm and is not expected to hold this invariant (it deliberately
    // uses a second, independently-positioned object — see the (c) test above).
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    @MainActor
    private func hostRealSurfaceOnEmphasisLine(mode: NativeLyricsFeelParity.EmphasisMode) -> (NativeLyricsSurfaceView, MusicController, (CFTimeInterval) -> Void) {
        NativeLyricsFeelParity.testingSweep = .v28
        NativeLyricsFeelParity.testingEmphasis = mode
        let panelWidth: CGFloat = 320
        // Reuses this file's own emphasisLine() fixture ("about" is the sole emphasis-eligible
        // run, same shot LyricsRenderDefects20260914ReproTests characterizes the peak with).
        let row0 = row(for: emphasisLine(), index: 0)
        let rows = [row0]
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 200))
        host(surface, NSSize(width: panelWidth, height: 200))
        let mc = MusicController(preview: true)
        mc.duration = 40
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 11_000
        var date = Date(timeIntervalSinceReferenceDate: 960_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        func advanceTo(_ t: TimeInterval) {
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            surface.configure(config(rows: rows, current: 0, mc: mc, width: panelWidth))
            surface.debugTick(displayInterval: 1.0 / 60.0)
        }
        mc.syncPlaybackClock(to: 10.02, playing: true, at: date)
        surface.configure(config(rows: rows, current: 0, mc: mc, width: panelWidth))
        surface.layoutSubtreeIfNeeded()
        return (surface, mc, advanceTo)
    }

    @MainActor
    func test_allThreeArms_glowSharpTileZeroPositionalDifference_realSurfaceEveryFrame() {
        defer { NativeLyricsFeelParity.resetTestingOverrides() }
        for mode in [NativeLyricsFeelParity.EmphasisMode.current, .v28, .amll] {
            let (surface, _, advanceTo) = hostRealSurfaceOnEmphasisLine(mode: mode)
            var sawVisibleGlow = false
            var t: TimeInterval = 10.02
            while t < 14.5 {
                advanceTo(t)
                guard let view = surface.debugRowView(forIndex: 0) else { t += 1.0 / 60.0; continue }
                for pair in view.debugEmphasisGlowTilePairs where pair.glowVisible {
                    sawVisibleGlow = true
                    XCTAssertEqual(pair.brightPosition.x, pair.glowPosition.x, accuracy: 0,
                        "\(mode): glow sibling x must be identical to its bright tile at t=\(t)")
                    XCTAssertEqual(pair.brightPosition.y, pair.glowPosition.y, accuracy: 0,
                        "\(mode): glow sibling y must be identical to its bright tile at t=\(t)")
                    XCTAssertEqual(pair.brightScale, pair.glowScale, accuracy: 0,
                        "\(mode): glow sibling scale must be identical to its bright tile at t=\(t)")
                }
                t += 1.0 / 60.0
            }
            surface.debugNowOverride = nil
            // Only `amll` uses the `mainEmphasisGlowLayers` SIBLING layer this accessor pairs
            // against — `current` routes through the separate legacy `emphasisGlyphLayers` pool
            // (see the (c) test above), and `v28`'s glow is a real CALayer shadow on the bright
            // tile ITSELF (`applyEmphasisGlowOnSharedTile`'s `.v28` case explicitly keeps the
            // sibling glow layer hidden — see `test_v28_glowShadowEngagesOnTheSharedTile` for that
            // arm's own, structurally-can't-desync check). So only amll is expected to ever report
            // `glowVisible` via THIS accessor; requiring it for v28 would be asserting the wrong
            // mechanism.
            if mode == .amll {
                XCTAssertTrue(sawVisibleGlow, "\(mode): real-surface per-frame scan must hit the glow-visible window at least once")
            }
        }
    }
}
