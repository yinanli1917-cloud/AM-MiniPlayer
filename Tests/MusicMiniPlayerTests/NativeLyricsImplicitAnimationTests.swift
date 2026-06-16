import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Implicit-animation hygiene for the native lyrics renderer.
//
// The renderer's motion contract: ALL motion comes from per-tick property sets driven by
// the presentation engine, or from explicit named CAAnimations (loading dots). Manual
// sublayers of layer-backed NSViews otherwise receive Core Animation's default 0.25s
// implicit action on EVERY animatable property change (frame, position, opacity, filters,
// contents/string, ...). Those stray animations are the root cause of the on-screen
// glitch family: translation text drifting in from the top-left corner when it first
// loads (frame .zero → real frame animates from origin), one-frame ghost rows during
// reflow, and interlude-dot smear (per-tick position sets each spawning an interrupted
// 0.25s animation).
//
// These tests assert the hygiene invariant at the BEHAVIOR level: after driving the real
// configure → layout pipeline, no layer in the tree may carry any animation that the
// renderer did not explicitly add by name.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsImplicitAnimationTests: XCTestCase {

    /// Animation keys the renderer adds explicitly, by name. Anything else in the tree
    /// is an implicit-action leak.
    private static let explicitAnimationKeys: Set<String> = ["translationLoadingOpacity", "translationGrowIn"]

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    /// Commits the current implicit transaction so the layers' state materializes as the
    /// "previous committed value". Implicit animations only attach when a property changes
    /// AFTER its old value was committed — exactly how the live glitches occur (translation
    /// arrives seconds after the row first rendered). Without this, both phases share one
    /// transaction and CA never animates, masking the bug.
    private func commitTransactions() {
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    /// Core Animation only attaches implicit actions to layer trees realized in a window's
    /// render context — a detached NSView never reproduces the on-screen drift. Host the
    /// view in an invisible (alpha 0) window so the test exercises the same CA machinery
    /// as the live app.
    @MainActor
    private func hostInWindow(_ view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
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

    // MARK: - Fixtures

    private func line(_ text: String, translation: String? = nil, index: Int = 0) -> LyricLine {
        LyricLine(text: text, startTime: TimeInterval(index * 10), endTime: TimeInterval(index * 10 + 10), translation: translation)
    }

    private func row(_ line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let displayLine = DisplayLyricLine(
            id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line
        )
        return LayerBackedLyricRow(
            id: displayLine.id, index: index, displayLine: displayLine,
            sourceLine: line, isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func makeConfiguration(
        rows: [LayerBackedLyricRow],
        rowWidth: CGFloat = 320,
        currentIndex: Int = 0,
        showTranslation: Bool = false,
        pendingTranslationLineIndices: Set<Int> = [],
        isTranslating: Bool = false,
        hasSyllableSync: Bool = false,
        musicController: MusicController? = nil
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
            hasSyllableSync: hasSyllableSync,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 100),
            isWaveTimelineDiagnosticsEnabled: false,
            isManualScrolling: false,
            reduceMotion: false,
            suppressInitialMotion: false,
            pendingTranslationLineIndices: pendingTranslationLineIndices,
            showTranslation: showTranslation,
            isTranslating: isTranslating,
            translationFailed: false,
            interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: true,
            musicController: musicController ?? MusicController(preview: true),
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

    /// Recursively collects every (layerPath, animationKeys) pair in a layer tree,
    /// including mask layers, filtering out the renderer's explicit named animations.
    private func strayAnimations(in root: CALayer, path: String = "root") -> [(path: String, keys: [String])] {
        var found: [(String, [String])] = []
        let stray = (root.animationKeys() ?? []).filter { !Self.explicitAnimationKeys.contains($0) }
        if !stray.isEmpty {
            found.append((path + "<\(type(of: root))>", stray))
        }
        if let mask = root.mask {
            found += strayAnimations(in: mask, path: path + ".mask")
        }
        for (i, sub) in (root.sublayers ?? []).enumerated() {
            found += strayAnimations(in: sub, path: path + ".\(i)")
        }
        return found
    }

    // MARK: - The reported bug: translation drifts in from the top-left on first load

    /// A row is on screen WITHOUT translation (translation still loading → its layer is
    /// parked at frame .zero). The translation then arrives and configure/layout assigns
    /// the real frame. That frame change must apply INSTANTLY: any implicit animation
    /// here renders as the translation text flying in from the top-left corner.
    @MainActor
    func test_translationArrival_doesNotAnimateFrameFromOrigin() {
        let width: CGFloat = 320
        let bare = row(line("Now that I have found you"), index: 0)
        let view = NativeLyricsRowView(frame: .zero)
        hostInWindow(view)
        view.configure(row: bare, configuration: makeConfiguration(rows: [bare], showTranslation: true, pendingTranslationLineIndices: [0], isTranslating: true))
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.debugForceLayout()
        XCTAssertEqual(view.debugTranslationTextLayerFrame, .zero, "precondition: translation layer parked at .zero while loading")
        commitTransactions()

        // Translation arrives for the same row.
        let translated = row(line("Now that I have found you", translation: "既然我找到了你"), index: 0)
        view.configure(row: translated, configuration: makeConfiguration(rows: [translated], showTranslation: true))
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.debugForceLayout()

        XCTAssertNotEqual(view.debugTranslationTextLayerFrame, .zero, "precondition: translation layer received its real frame")
        // The frame must be set instantly (no implicit drift-from-origin). The ONLY animation
        // permitted is the deliberate "向下生长" grow-in (opacity + a small settle offset, not a
        // frame animation) — filter it out and assert nothing else (implicit) remains.
        let strayKeys = view.debugTranslationTextLayerAnimationKeys.filter { !Self.explicitAnimationKeys.contains($0) }
        XCTAssertEqual(
            strayKeys, [],
            "translation layer must not implicitly animate its frame (drifts in from top-left on screen)"
        )
        // And the async-arrival grow-in MUST have fired (this is the reveal the user asked for).
        XCTAssertTrue(
            view.debugTranslationTextLayerAnimationKeys.contains("translationGrowIn"),
            "async translation arrival should play the explicit grow-in reveal"
        )
    }

    // MARK: - Tree-wide invariant: the full configure→layout pipeline leaves no stray animations

    /// Drives the REAL surface pipeline twice (initial mount, then a typical update where the
    /// active line advances and a translation appears) and asserts no layer anywhere in the
    /// tree — rows, text layers, sweep masks, interlude dots — carries an implicit animation.
    @MainActor
    func test_surfaceConfigureCycle_leavesNoStrayAnimationsInLayerTree() {
        let surface = NativeLyricsSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface)
        let r0 = row(line("Now that I have found you"), index: 0)
        let r1 = row(line("I must hang around you", translation: nil), index: 1)
        surface.configure(makeConfiguration(rows: [r0, r1], currentIndex: 0, showTranslation: true, pendingTranslationLineIndices: [0, 1]))
        surface.layoutSubtreeIfNeeded()
        XCTAssertFalse(surface.subviews.isEmpty, "precondition: reconcile must mount row views")
        commitTransactions()

        // Typical update: translations arrive and the active line advances.
        let t0 = row(line("Now that I have found you", translation: "既然我找到了你"), index: 0)
        let t1 = row(line("I must hang around you", translation: "我必须在你身边闲逛"), index: 1)
        surface.configure(makeConfiguration(rows: [t0, t1], currentIndex: 1, showTranslation: true))
        surface.layoutSubtreeIfNeeded()

        guard let rootLayer = surface.layer else {
            return XCTFail("surface must be layer-backed")
        }
        let stray = strayAnimations(in: rootLayer)
        XCTAssertTrue(
            stray.isEmpty,
            "no layer in the renderer tree may carry an implicit animation; found: \(stray.map { "\($0.path): \($0.keys)" }.joined(separator: " | "))"
        )
    }

    // MARK: - The reported bug: word-level lyrics render as line-level on a fresh active mount

    /// A row WITH per-word (syllable) timing must render the per-word karaoke sweep the very
    /// first time it becomes active. In the live app the active row's `updatePlaybackPhase`
    /// ran during reconcile BEFORE the row's frame + text-sublayer layout, so its text-layer
    /// bounds were `.zero` → `geometryReady == false` → `applyActiveMainPhase` fell back to the
    /// whole-line (line-level) sweep. The line then stayed line-level until a later tick — the
    /// "word-level lyrics inexplicably become line-level" symptom. Drive ONE real configure()
    /// (the first-mount path) and assert the active row applied the per-word sweep.
    @MainActor
    func test_freshActiveRowWithSyllableSync_appliesPerWordSweep_notLineLevel() {
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 100
        // Land the render clock mid-line (words span 0–2s) so the active sweep is genuinely running.
        mc.syncPlaybackClock(to: 1.0, playing: true)

        let surface = NativeLyricsSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        hostInWindow(surface)

        let words = [
            LyricWord(word: "Hello ", startTime: 0.0, endTime: 1.0),
            LyricWord(word: "world", startTime: 1.0, endTime: 2.0)
        ]
        let active = row(LyricLine(text: "Hello world", startTime: 0, endTime: 2, words: words), index: 0)
        let next = row(line("second line that follows", index: 1), index: 1)

        // Single configure() = the live first-mount path. No extra layout / tick.
        surface.configure(makeConfiguration(
            rows: [active, next], currentIndex: 0, hasSyllableSync: true, musicController: mc
        ))

        guard let activeView = surface.debugRowView(forIndex: 0) else {
            return XCTFail("active row must be mounted by reconcile")
        }
        XCTAssertTrue(
            activeView.debugLastAppliedActivePerRunSweep,
            "a freshly-mounted active row WITH word timings must render per-word sweep, not line-level"
        )
    }
}
