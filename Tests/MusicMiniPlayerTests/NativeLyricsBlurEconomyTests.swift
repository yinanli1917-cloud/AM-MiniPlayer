import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Blur economy — the WindowServer-cost gate for the depth-of-field blur.
//
// Measured on M1 (2026-07-09): the word-synced sweep costs +38 points of WindowServer
// CPU because every mounted non-active row carries a resident CIGaussianBlur in
// layer.filters that the compositor re-evaluates on every recomposite of the surface,
// even though those rows are completely static in the model.
//
// The economy contract these tests pin:
//   1. A settled, non-active, blurred row is RASTERIZED (shouldRasterize + backing-scale
//      rasterizationScale) so the compositor caches the blurred bitmap and recomposites
//      a texture instead of re-evaluating the filter.
//   2. The active row is never rasterized and carries no filters — its karaoke sweep
//      must stay live.
//   3. A row hosting a repeating dot animation (translation-loading) is never rasterized
//      while the dots run: an animating sublayer would invalidate the raster cache every
//      frame, which is more expensive than the live filter.
//   4. Toggling rasterization must not leak implicit animations (same hygiene invariant
//      as NativeLyricsImplicitAnimationTests).
//   5. prepareForReuse clears rasterization state alongside the filters it already clears.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsBlurEconomyTests: XCTestCase {

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
        if let surface = view as? NativeLyricsSurfaceView {
            hostedSurfaces.append(surface)
        }
    }

    /// Commit the implicit transaction so layer state materializes as the previous committed
    /// value — required for CA to attach implicit actions on the NEXT mutation (the hygiene
    /// test is meaningless without it). Same pattern as NativeLyricsImplicitAnimationTests.
    private func commitTransactions() {
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private var expectedRasterizationScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: - Fixtures

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

    private func plainRow(_ text: String, translation: String? = nil, index: Int = 0) -> LayerBackedLyricRow {
        let line = LyricLine(
            text: text,
            startTime: TimeInterval(index * 10),
            endTime: TimeInterval(index * 10 + 10),
            translation: translation
        )
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                   isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(
        _ rowList: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController,
        showTranslation: Bool = false,
        pendingTranslationLineIndices: Set<Int> = [],
        isTranslating: Bool = false
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: pendingTranslationLineIndices,
            showTranslation: showTranslation,
            isTranslating: isTranslating, translationFailed: false, interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    /// Drive the real surface at ~1x so visual targets sync, applyFrames runs, and the
    /// motion states settle (fresh mounts construct AT target, so a short drive suffices).
    /// Stays INSIDE line 0's window (0.1..0.77 of a 1.2s line) — crossing a line boundary
    /// makes "which row is active at read time" racy on a loaded machine.
    @MainActor
    private func driveSettled(surface: NativeLyricsSurfaceView, mc: MusicController, rows: [LayerBackedLyricRow]) {
        mc.syncPlaybackClock(to: 0.1, playing: true)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        for i in 0..<40 {
            let t = 0.1 + TimeInterval(i) / 60.0
            mc.syncPlaybackClock(to: t, playing: true)
            surface.configure(config(rows, current: 0, mc: mc))
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
    }

    // MARK: - 1+2: surface-level rasterization state

    @MainActor
    func test_settledBlurredRow_isRasterizedAtBackingScale() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(12)

        driveSettled(surface: surface, mc: mc, rows: rows)

        guard let far = surface.debugRowView(forIndex: 8) else {
            return XCTFail("far row 8 must be mounted")
        }
        XCTAssertNotNil(far.layer?.filters, "precondition: a distance-8 row must carry the DoF blur filter")
        XCTAssertFalse(far.layer?.filters?.isEmpty ?? true, "precondition: filter array must be non-empty")
        XCTAssertEqual(far.layer?.shouldRasterize, true,
                       "a settled, non-active, blurred row must be rasterized so the compositor caches the blurred bitmap")
        XCTAssertEqual(far.layer?.rasterizationScale ?? 0, expectedRasterizationScale, accuracy: 0.01,
                       "rasterization must happen at the backing scale or text goes soft")
    }

    @MainActor
    func test_activeRow_isNotRasterizedAndCarriesNoFilters() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows(12)

        driveSettled(surface: surface, mc: mc, rows: rows)

        let activeIndex = surface.debugNativeSemanticIndex ?? 0
        guard let active = surface.debugRowView(forIndex: activeIndex) else {
            return XCTFail("active row \(activeIndex) must be mounted")
        }
        XCTAssertNil(active.layer?.filters, "the active row must carry no DoF filter")
        XCTAssertEqual(active.layer?.shouldRasterize, false,
                       "the active row must never be rasterized — its karaoke sweep must stay live")
    }

    // MARK: - 3: dot-animation veto (row-level)

    @MainActor
    func test_rowAwaitingTranslation_isNotRasterizedWhileLoadingDotsAnimate() {
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        host(view, NSSize(width: 320, height: 56))
        let mc = MusicController(preview: true)

        // Awaiting translation: showTranslation on, this line pending, no translation text yet
        // → updateTextLayers starts the repeating loading-dot animation.
        let awaitingRow = plainRow("hello world", translation: nil, index: 0)
        view.configure(
            row: awaitingRow,
            configuration: config([awaitingRow], current: 0, mc: mc,
                                  showTranslation: true,
                                  pendingTranslationLineIndices: [0],
                                  isTranslating: true)
        )
        view.layoutSubtreeIfNeeded()

        view.applyBlurRadius(4)
        view.applyRasterizationPolicy(isSettled: true, isActive: false)
        XCTAssertEqual(view.layer?.shouldRasterize, false,
                       "a row with running loading-dot animations must not be rasterized (each animation frame would invalidate the cache)")

        // Translation arrives → dots hide (in layout) → the veto lifts without another policy call.
        let translatedRow = plainRow("hello world", translation: "你好世界", index: 0)
        view.configure(
            row: translatedRow,
            configuration: config([translatedRow], current: 0, mc: mc, showTranslation: true)
        )
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.layer?.shouldRasterize, true,
                       "once the dots stop, a settled blurred row must return to the rasterization cache")
    }

    // MARK: - 4: implicit-animation hygiene across the toggle

    @MainActor
    func test_rasterizationToggle_leavesNoStrayAnimations() {
        let allowedKeys: Set<String> = ["translationLoadingOpacity", "translationGrowIn"]
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        host(view, NSSize(width: 320, height: 56))
        let mc = MusicController(preview: true)
        let row = plainRow("hello world", index: 0)
        view.configure(row: row, configuration: config([row], current: 5, mc: mc))
        view.layoutSubtreeIfNeeded()
        commitTransactions()

        view.applyBlurRadius(4)
        view.applyRasterizationPolicy(isSettled: true, isActive: false)
        commitTransactions()
        view.applyRasterizationPolicy(isSettled: false, isActive: false)
        commitTransactions()
        view.applyBlurRadius(0)
        commitTransactions()

        var stray: [String] = []
        func walk(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] where !allowedKeys.contains(key) {
                stray.append("\(type(of: layer)) key=\(key)")
            }
            if let mask = layer.mask { walk(mask) }
            for sub in layer.sublayers ?? [] { walk(sub) }
        }
        if let rootLayer = view.layer { walk(rootLayer) }
        XCTAssertTrue(stray.isEmpty, "rasterization toggling leaked implicit animations:\n\(stray.joined(separator: "\n"))")
    }

    // MARK: - 5: reuse hygiene

    @MainActor
    func test_prepareForReuse_clearsRasterization() {
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        host(view, NSSize(width: 320, height: 56))
        let mc = MusicController(preview: true)
        let row = plainRow("hello world", index: 0)
        view.configure(row: row, configuration: config([row], current: 5, mc: mc))
        view.layoutSubtreeIfNeeded()

        view.applyBlurRadius(4)
        view.applyRasterizationPolicy(isSettled: true, isActive: false)
        XCTAssertEqual(view.layer?.shouldRasterize, true, "precondition: the row must be rasterized before reuse")

        view.prepareForReuse()
        XCTAssertEqual(view.layer?.shouldRasterize, false,
                       "a pooled row must not drag rasterization state into its next mount")
    }

    // MARK: - CA filter-immutability contract

    /// Core Animation treats a filter attached to a layer as immutable: mutating the attached
    /// instance and reassigning the SAME object can be silently ignored by the render server,
    /// so every row keeps its mount-time blur forever (user-visible: blur measured from the
    /// first line, deepening as the song scrolls until the centered lyrics are unreadable —
    /// caught by the user 2026-07-10, invisible to headless tests because only the render
    /// server applies filters). Pin the contract: every radius change attaches a FRESH instance.
    @MainActor
    func test_blurRadiusChange_attachesFreshFilterInstance() {
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        view.applyBlurRadius(9)
        let first = view.layer?.filters?.first as AnyObject?
        XCTAssertNotNil(first, "precondition: first radius must attach a filter")
        view.applyBlurRadius(2)
        let second = view.layer?.filters?.first as AnyObject?
        XCTAssertNotNil(second, "precondition: second radius must attach a filter")
        XCTAssertFalse(first === second,
                       "a radius change must attach a FRESH CIFilter — mutating the attached instance is ignored by the render server")
    }

    // MARK: - Stage 2: blur is a stepped depth cue, not a springed channel
    //
    // Springing blur during a line change holds every blur-only row unsettled for the whole
    // scroll — which disengages rasterization on exactly the frames the compositor is busiest.
    // Snapping blur at retarget makes rows whose target changed ONLY in the blur tier settle
    // instantly, so they stay rasterized through the handoff and translate as cached bitmaps.

    private func dimTarget(blur: CGFloat) -> NativeLyricsVisualTarget {
        NativeLyricsVisualTarget(opacity: 0.35, scale: 0.95, blur: blur, isActive: false)
    }

    func test_setTarget_snapsBlur_andPureBlurTierRetargetSettlesInstantly() {
        var state = NativeLyricsVisualMotionState(target: dimTarget(blur: 0.5))
        XCTAssertTrue(state.isSettled, "precondition: fresh state constructs at target")

        let changed = state.setTarget(dimTarget(blur: 2.5))
        XCTAssertTrue(changed, "the tier change must still report a change so a frame apply runs")
        XCTAssertEqual(state.blur, 2.5, accuracy: 0.0001,
                       "blur must snap to the new tier at retarget, not spring toward it")
        XCTAssertTrue(state.isSettled,
                      "a retarget that changed only the blur tier must settle instantly — that is what keeps the row rasterized through the handoff")

        for _ in 0..<40 {
            state.advance(delta: 1.0 / 60.0)
            XCTAssertEqual(state.blur, 2.5, accuracy: 0.0001, "snapped blur must not move afterwards")
        }
    }

    func test_quickRetarget_snapsBlur_whileOpacityScaleStillSpring() {
        let active = NativeLyricsVisualTarget(opacity: 1.0, scale: 1.0, blur: 0, isActive: true)
        var state = NativeLyricsVisualMotionState(target: active)
        XCTAssertTrue(state.isSettled)

        state.quickRetarget(to: dimTarget(blur: 0.5))
        XCTAssertEqual(state.blur, 0.5, accuracy: 0.0001,
                       "quickRetarget must snap blur to the new tier immediately")
        XCTAssertEqual(state.opacity, 1.0, accuracy: 0.0001,
                       "opacity keeps its spring — only blur is stepped")

        var settledFrame: Int?
        for frame in 0..<240 {
            state.advance(delta: 1.0 / 60.0)
            XCTAssertEqual(state.blur, 0.5, accuracy: 0.0001,
                           "blur must hold its snapped value while opacity/scale spring")
            if state.isSettled { settledFrame = frame; break }
        }
        XCTAssertNotNil(settledFrame, "opacity/scale must still settle via the spring")
        XCTAssertEqual(state.opacity, 0.35, accuracy: 0.01, "opacity must reach the dim target")
    }
}
