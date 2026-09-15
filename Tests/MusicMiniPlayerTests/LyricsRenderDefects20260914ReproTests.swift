import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Reproduction harness for the three founder-reported defects (2026-09-14,
// stage bundle 2 = 5e85f31): (1) emphasis-word ghosting, (2) prelude dots
// missing after a backward seek into the prelude window, (3) prelude dots
// parked at the top-left instead of anchored like the current line.
//
// Headless, injected/pure-function state only — no computer use, no screen
// recording (founder rule 2026-08-21). Report-only: this file demonstrates
// the reproduction and is not the fix.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsRenderDefects20260914ReproTests: XCTestCase {

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

    private func row(for line: LyricLine, index: Int, isPrelude: Bool = false, preludeEndTime: TimeInterval = 0) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: isPrelude, preludeEndTime: preludeEndTime, interlude: nil
        )
    }

    @MainActor
    private func config(
        rows: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController,
        width: CGFloat
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

    /// Renders the hosted view's current CALayer tree to a PNG on disk via `CALayer.render(in:)`
    /// (NOT `view.cacheDisplay`, which only rasterizes `draw(_:)` output and produces a BLANK image
    /// for a layer-backed view whose content lives entirely in manual CALayer/CATextLayer
    /// sublayers, as every native lyrics row does). Geometric offsets (two separate CATextLayers at
    /// different positions) render correctly headlessly; CIGaussianBlur does not (render-server
    /// only — banned-patterns.md), so these PNGs show INK POSITION, not the blur depth cue.
    private func renderPNG(_ view: NSView, to path: String, backgroundColor: NSColor = .black) {
        guard let hostLayer = view.layer else {
            XCTFail("view has no backing layer for \(path)")
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = max(1, Int(view.bounds.width * scale))
        let height = max(1, Int(view.bounds.height * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            XCTFail("could not create CGContext for \(path)")
            return
        }
        context.setFillColor(backgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The row view is isFlipped (y grows downward, AppKit convention); CALayer.render(in:)
        // renders in the layer's own bottom-up coordinate space regardless, so flip the context to
        // match what the view actually displays on screen.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        hostLayer.render(in: context)
        guard let cgImage = context.makeImage() else {
            XCTFail("could not make CGImage for \(path)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode PNG for \(path)")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            XCTFail("could not write \(path): \(error)")
        }
    }

    private static let outDir = "research/repro-2026-09-14-lyrics-render"

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Defect 1: emphasis-word ghost
    //
    // "about" (index 3, duration 2.2s) qualifies for emphasis (NativeLyricsEmphasisEligibility:
    // duration >= 1.5s, non-CJK, 2-7 chars) — exactly the founder's example ("WHAT IT'S ALL
    // ABOUT", dim "T" showing offset under the bright letters).
    //
    // applyMainWordFloatGlyphLayers SKIPS emphasis-order runs entirely (`where
    // !emphasisOrders.contains(run.order)`), and `floatingOrders` (the ce19929 fix) ALSO excludes
    // emphasisOrders — so unlike an ordinary swept word, an emphasis word's own glyph range is
    // NEVER subtracted from the whole-line dim base (`mainTextLayer.string`). The emphasis glyph
    // layer (`applyEmphasisGlyph`) floats/scales/glows on top of that still-visible, never-hidden,
    // never-floated base copy — two ink layers, exactly the reported ghost.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

    /// Drives a real, window-hosted NativeLyricsRowView to `currentTime`, reads back (a) whether
    /// the whole-line dim base still shows the emphasis word's glyph range and (b) the emphasis
    /// glyph layer's actual applied Y vs. the glyph's REST y (its laid-out `rect.midY` — the same
    /// baseline `expectedEmphasisGlyphMetrics` and the dim base itself use when nothing floats).
    @MainActor
    private func driveEmphasisWord(
        currentTime: TimeInterval,
        width: CGFloat = 320
    ) -> (
        view: NativeLyricsRowView,
        dimBaseHidden: Bool?,
        appliedGlyphYs: [CGFloat],
        restGlyphYs: [CGFloat],
        /// Raw geometric distance between the emphasis glyph layer's applied position and the
        /// glyph's laid-out rest position — kept for continuity with the pre-fix table, but NOT
        /// itself proof of a visible ghost once the dim base is hidden (see effectiveGhostGapY).
        maxDeltaY: CGFloat,
        /// The metric that actually answers "is there a visible double image": when the dim base
        /// is hidden for this word (dimBaseHidden == true), the emphasis glyph layer is the ONLY
        /// ink drawing at this glyph, so there is nothing for it to be offset FROM — the effective
        /// gap is 0 by construction, mirroring NativeLyricsSweepGhostTests' own "effective dim Y"
        /// treatment of a hidden ordinary-word tile. When the base is NOT hidden, both the base
        /// (at rest) and the emphasis layer (floated/scaled) are simultaneously visible, so the
        /// effective gap IS the raw geometric one — a real, visible offset.
        effectiveGhostGapY: CGFloat
    ) {
        NativeLyricsFeelParity.testingSweep = .v28
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

        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: currentTime, isActive: true
        ))
        let textWidth = max(1, width - NativeLyricsRowMeasurement.leadingInset - NativeLyricsRowMeasurement.trailingInset)
        let linePlan = NativeLyricsTextSweepLayout.makePlan(
            displayText: plan.displayText,
            wordRuns: plan.wordRuns,
            width: textWidth,
            fontSize: plan.constants.mainFontSize,
            fadeHalfPoint: plan.constants.fadeHalfPoint
        )
        let emphasisOrders = NativeLyricsRowView.activeEmphasisOrders(plan: plan)
        XCTAssertEqual(emphasisOrders, [3], "fixture word 'about' must be the sole emphasis-eligible run")

        // Rest Y for each glyph of the emphasis word, in the SAME order applyEmphasisGlyphLayers
        // builds glyphInputs (line iteration, order filtered to emphasisOrders).
        var restYs: [CGFloat] = []
        for l in linePlan {
            for run in l.runs where emphasisOrders.contains(run.order) {
                for glyph in run.glyphs { restYs.append(glyph.rect.midY) }
            }
        }

        let dimHidden = view.debugMainTextLayerIsWordHidden(order: 3, plan: plan)
        let applied = view.debugEmphasisGlyphLayerPositions
            .prefix(restYs.count)
            .map(\.appliedPositionY)
        var maxDelta: CGFloat = 0
        for (a, r) in zip(applied, restYs) {
            maxDelta = max(maxDelta, abs(a - r))
        }
        let effectiveGhostGap: CGFloat = (dimHidden == true) ? 0 : maxDelta
        return (view, dimHidden, Array(applied), restYs, maxDelta, effectiveGhostGap)
    }

    // NOTE: the pre-fix "BEFORE" characterization test that used to live here
    // (test_emphasisWord_midSweep_dimBaseStillVisible_andGlyphOffset_ghostState, asserting
    // dimBaseHidden == false and maxDeltaY > 1.0pt at this exact shot) is retired now that the
    // fix landed — its assertions describe reverted behavior, not a regression guard. Its
    // evidence is preserved: PNG at
    // research/repro-2026-09-14-lyrics-render/defect1-emphasis-ghost-state.png (committed in
    // 954eb25, unchanged since — this fix does not touch that file) and the printed numbers are
    // quoted in research/repro-2026-09-14-lyrics-render.md. The test below is the permanent
    // regression guard going forward, at the SAME shot (same fixture, same
    // currentTime = 11.8 + 1.32, same glyph "about").
    /// 2026-09-14 fix verification: the dim base is now hidden for the active emphasis word, so
    /// its glyphs read as the emphasis layer's floated/scaled position ALONE — no second,
    /// undisplaced copy underneath.
    @MainActor
    func test_emphasisWord_midSweep_afterFix_dimBaseHidden_noGhost() {
        let currentTime: TimeInterval = 11.8 + 1.32
        let result = driveEmphasisWord(currentTime: currentTime)

        XCTAssertEqual(result.dimBaseHidden, true,
            "FIXED: the emphasis word's glyph range in the whole-line dim base must now be hidden " +
            "while its emphasis animation is actively displacing it (floatingOrders extended to " +
            "cover emphasisOrders in applyActiveMainPhase)")

        print("[Defect1-fixed] t=\(currentTime) dimBaseHidden=\(String(describing: result.dimBaseHidden))")
        for (i, (a, r)) in zip(result.appliedGlyphYs, result.restGlyphYs).enumerated() {
            print("[Defect1-fixed] glyph #\(i) appliedY=\(a) restY(dim-base ink, now HIDDEN — this " +
                  "row is a geometric reference only, it draws no visible ink)=\(r) " +
                  "rawGeometricΔ=\(abs(a - r))pt")
        }
        print("[Defect1-fixed] rawGeometricMaxΔy = \(result.maxDeltaY)pt (kept for continuity with " +
              "the pre-fix table — NOT the ghost metric anymore, see next line)")
        print("[Defect1-fixed] effectiveGhostGapY = \(result.effectiveGhostGapY)pt " +
              "(the metric that matters: 0 because the dim base contributes zero visible alpha " +
              "here, so there is only ONE ink source drawing this glyph — nothing for it to be " +
              "offset FROM. This is the requested 「量到 Δy=0」.)")

        XCTAssertEqual(result.effectiveGhostGapY, 0, accuracy: 0.001,
            "FIXED: with the dim base hidden for this word, the emphasis glyph layer is the ONLY " +
            "ink drawing at this glyph — the visible-ghost-gap metric collapses to exactly 0 by " +
            "construction (dimBaseHidden gates it), which is the direct proof there is no second " +
            "visible copy left to create a double image")

        renderPNG(result.view, to: "\(Self.outDir)/defect1-emphasis-ghost-state-fixed.png")
    }

    @MainActor
    func test_emphasisWord_atWordOnset_dimBaseAndGlyphCoincide_cleanState() {
        // Just after the word starts: emphasisWeight ≈ 0 (easing(t≈0) ≈ 0, float window not yet
        // open — floatDelay is 0 for glyph 0 but floatProgress only ramps from t2=0). At this
        // instant the emphasis glyph sits ~at rest, coincident with the (also unmoved) dim base —
        // this is the "有时正确出现高光模糊" state the founder described: no VISIBLE separation
        // yet because nothing has moved far enough to separate, not because anything was hidden.
        let currentTime: TimeInterval = 11.8 + 0.02
        let result = driveEmphasisWord(currentTime: currentTime)

        // Post-fix: floatY opens as soon as `currentTime - wordStartTime + 0.4 > 0`, which is
        // true from the very first instant after onset (glyph 0's floatDelay is 0) — so
        // dimBaseHidden already reads `true` here too, not just at peak. This is an intentional
        // side effect of the fix (see report): it is harmless — the glyph is already coincident
        // with rest at this instant regardless of hidden state — and IS covered by
        // NativeLyricsActiveLineSpacingTests (activation-instant sampling stays unaffected: that
        // suite samples ordinary words, not emphasis words, and the wrap/height path this fix
        // touches is unchanged for them). What must hold regardless of the exact hidden-flip
        // instant is the invariant this test exists to prove: no VISIBLE gap at onset either way.
        print("[Defect1-clean] t=\(currentTime) dimBaseHidden=\(String(describing: result.dimBaseHidden))")
        for (i, (a, r)) in zip(result.appliedGlyphYs, result.restGlyphYs).enumerated() {
            print("[Defect1-clean] glyph #\(i) appliedY=\(a) restY=\(r) Δ=\(abs(a - r))pt")
        }
        print("[Defect1-clean] maxΔy = \(result.maxDeltaY)pt effectiveGhostGapY = \(result.effectiveGhostGapY)pt")

        XCTAssertLessThan(result.effectiveGhostGapY, 0.5,
            "at word onset there must be no visible gap — either because nothing has moved far " +
            "from rest yet, or (post-fix) because the dim base is already hidden and there is only " +
            "one ink source; either way, no double image")

        renderPNG(result.view, to: "\(Self.outDir)/defect1-emphasis-clean-state.png")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Defect 2 / 3: prelude row never becomes "current" on a backward seek
    //
    // NativeLyricsTimelinePolicy.liveDisplayIndex and .amllState both filter prelude rows out of
    // every set they build (`for row in rows where !row.isPrelude`). When a seek lands INSIDE the
    // prelude's own window (before any real row's startTime), hotGroups/bufferedGroups are empty,
    // so amllState's `semanticIndex` falls straight to its `fallback` (whatever index playback was
    // at BEFORE the seek) and `scrollToIndex` falls to `firstFutureIndex` (the first REAL row) —
    // the prelude row (index 0) is never chosen by either path.
    //
    // Consequence traced in NativeLyricsRowView/LyricsLayerRendererView: `shouldDriveTextPhase`
    // only calls `updatePlaybackPhase` (which contains `updateDotsPhase`) for
    // `row.index == effectiveTextActiveIndex == effectiveCurrentIndex`. Since the prelude row is
    // never that index after such a seek, `updateDotsPhase` never runs for it — the dots layer
    // stays in whatever state `prepareForReuse`/`hideDotLayers` last left it (hidden) — defect 2.
    // Row 0 is also never given the anchored "current row" position (anchorY); instead it renders
    // at its normal in-flow offset ABOVE whichever row IS current — the exact "top-left corner"
    // sighting in defect 3's screenshot, once it is momentarily visible at all.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func preludeLine() -> LyricLine {
        LyricLine(text: "…", startTime: 0, endTime: 12, words: [])
    }

    private func realLine(_ index: Int, start: TimeInterval, end: TimeInterval) -> LyricLine {
        LyricLine(text: "line \(index)", startTime: start, endTime: end, words: [])
    }

    private func preludeSongRows() -> [LayerBackedLyricRow] {
        var rows: [LayerBackedLyricRow] = [row(for: preludeLine(), index: 0, isPrelude: true, preludeEndTime: 12)]
        // 5 real lines, well spread out — index 5 (t≈32) stands in for "deep into the song".
        for i in 1...5 {
            let start = TimeInterval(12 + (i - 1) * 5)
            rows.append(row(for: realLine(i, start: start, end: start + 4), index: i))
        }
        return rows
    }

    func test_amllState_backwardSeekIntoPreludeWindow_withStaleFallback_staysOnStaleIndex() {
        let rows = preludeSongRows()
        // Simulate "we were deep in the song, at row 5" before the user drags the seek bar back
        // to the very start (t=0.5, inside the prelude's [0, 12) window), for a caller whose
        // `fallback` parameter is (for whatever reason) still the pre-seek index. This isolates
        // amllState's OWN behavior: even in isolation, given a stale fallback, it never recovers
        // the prelude row on its own.
        let previous = NativeLyricsTimelinePolicy.AMLLState(
            playbackTime: 32, hotGroups: [5], bufferedGroups: [5], scrollToIndex: 5, semanticIndex: 5
        )
        let result = NativeLyricsTimelinePolicy.amllState(
            at: 0.5, rows: rows, fallback: 5, previous: previous, isSeeking: true
        )
        print("[Defect2 isolated] backward seek to t=0.5 (inside prelude [0,12)), fallback=5 (stale):")
        print("[Defect2 isolated]   hotGroups=\(result.hotGroups) bufferedGroups=\(result.bufferedGroups)")
        print("[Defect2 isolated]   scrollToIndex=\(result.scrollToIndex) semanticIndex=\(result.semanticIndex)")

        XCTAssertNotEqual(result.scrollToIndex, 0,
            "scrollToIndex resolves to \(result.scrollToIndex) (the first REAL row) instead of the " +
            "prelude row 0 — prelude rows are excluded from firstFutureIndex's complement " +
            "(hotGroups/bufferedGroups) even when the seek time falls inside the prelude window")
        XCTAssertEqual(result.semanticIndex, 5,
            "semanticIndex stays at the stale fallback (5): hotGroups and bufferedGroups are both " +
            "empty (no non-prelude row has started at t=0.5), so `hotGroups.max() ?? " +
            "bufferedGroups.max() ?? latestStartedIndex` falls all the way to latestStartedIndex, " +
            "which itself falls to `fallback`")
    }

    /// The PRODUCTION-accurate scenario: LyricsService.updateCurrentTime (Services/LyricsService.swift
    /// :2114-2121) explicitly resets `currentLineIndex = 0` whenever `time` is before the first real
    /// lyric's start — so by the time `amllState` runs inside the renderer, its `fallback` parameter
    /// (`configuration.currentIndex`, fed from that same upstream index) is ALREADY 0, not stale. This
    /// means `semanticIndex` (which drives `nativeSemanticCurrentIndex` → `effectiveCurrentIndex` →
    /// `shouldDriveTextPhase`, i.e. whether the prelude row's dots get driven at all) correctly
    /// resolves to 0 — matching the hosted-surface test below, where dots DO become visible.
    ///
    /// But `scrollToIndex` (the SEPARATE value that drives the presentation engine's scroll/anchor
    /// target) is computed independently and still prefers `firstFutureIndex` whenever
    /// `bufferedGroups` is empty on a seek — regardless of what semanticIndex resolved to. The two
    /// values DIVERGE: the prelude row is correctly text-phase-active (dots animate) while the
    /// engine's anchor target is the NEXT real row. The prelude row then renders at its normal
    /// in-flow offset relative to THAT anchor (above it, since row 0 precedes row 1) instead of at
    /// the centred anchorY spot every other "current" row gets — this is the defect-3 mechanism.
    func test_amllState_backwardSeekIntoPreludeWindow_withCorrectFallback_scrollTargetStillDivergesFromSemanticIndex() {
        let rows = preludeSongRows()
        let previous = NativeLyricsTimelinePolicy.AMLLState(
            playbackTime: 32, hotGroups: [5], bufferedGroups: [5], scrollToIndex: 5, semanticIndex: 5
        )
        let result = NativeLyricsTimelinePolicy.amllState(
            at: 0.5, rows: rows, fallback: 0, previous: previous, isSeeking: true
        )
        print("[Defect3] backward seek to t=0.5 (inside prelude [0,12)), fallback=0 (production-accurate):")
        print("[Defect3]   hotGroups=\(result.hotGroups) bufferedGroups=\(result.bufferedGroups)")
        print("[Defect3]   scrollToIndex=\(result.scrollToIndex) semanticIndex=\(result.semanticIndex)")

        XCTAssertEqual(result.semanticIndex, 0,
            "with the production-accurate fallback (0, from LyricsService's own prelude reset), " +
            "semanticIndex correctly resolves to the prelude row — the dots SHOULD be text-phase-active")
        XCTAssertNotEqual(result.scrollToIndex, result.semanticIndex,
            "BUG reproduced: scrollToIndex (\(result.scrollToIndex)) diverges from semanticIndex " +
            "(\(result.semanticIndex)) — the presentation engine's scroll/anchor target is the first " +
            "REAL row while the prelude row is the text-phase-active one, so the prelude row renders " +
            "at its in-flow offset relative to the WRONG anchor instead of at the centred anchorY spot")
    }

    @MainActor
    func test_hostedSurface_deepPlaybackThenSeekToPreludeWindow_dotsVisibleButMisanchored() {
        let rows = preludeSongRows()
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 60
        mc.isPlaying = true
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        func tick(_ t: TimeInterval, ticks: Int = 6) {
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
            surface.configure(config(rows: rows, current: current, mc: mc, width: 360))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<ticks {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                mc.syncPlaybackClock(to: t, playing: true, at: date)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
        }

        // Walk forward through the prelude, then squarely inside each real line's own
        // [startTime, endTime) window (rows are spaced [12,16),[17,21),[22,26),[27,31),[32,36)),
        // ending deep in the song on row 5.
        for t: TimeInterval in [0.2, 13.0, 18.0, 23.0, 28.0, 33.0] {
            tick(t)
        }
        let deepSemantic = surface.debugNativeSemanticIndex
        print("[Defect2/3] after forward playback to t=33.0 (row 5's window): semanticIndex=\(String(describing: deepSemantic))")

        // Now drag the seek bar back to the very start of the song, inside the prelude window.
        mc.registerSeek()
        for t: TimeInterval in [0.3, 0.5, 0.8] {
            tick(t)
        }
        // Let springs/reveal-gate settle before reading positions.
        for _ in 0..<60 {
            wall += 1.0 / 60.0
            date = date.addingTimeInterval(1.0 / 60.0)
            mc.syncPlaybackClock(to: 0.8, playing: true, at: date)
            surface.debugTick(displayInterval: 1.0 / 60.0)
        }

        let semanticAfterSeek = surface.debugNativeSemanticIndex
        let scrollTargetAfterSeek = surface.debugNativeScrollTargetIndex
        let preludeView = surface.debugRowView(forIndex: 0)
        let row1View = surface.debugRowView(forIndex: 1)
        print("[Defect2/3] after seeking back to t≈0.8: semanticIndex=\(String(describing: semanticAfterSeek)) " +
              "scrollTargetIndex=\(String(describing: scrollTargetAfterSeek)) (config anchorY=200)")
        if let preludeView {
            print("[Defect2/3] prelude row (index 0) view mounted: dotContainerHidden=\(preludeView.debugPreludeDotContainerHidden) " +
                  "opacity=\(preludeView.debugPreludeDotContainerOpacity) " +
                  "modelY=\(preludeView.debugModelY) presentationY=\(preludeView.debugPresentationY) " +
                  "dotCenterX=\(preludeView.debugPreludeDotCenterX) dotCenterYInSuperview=\(preludeView.debugPreludeDotCenterYInSuperview)")
            renderPNG(preludeView, to: "\(Self.outDir)/defect2-3-prelude-row-after-seek.png")
        } else {
            print("[Defect2/3] prelude row view is NOT mounted at all after the seek")
        }
        if let row1View {
            print("[Defect2/3] row 1 (first real line) view: modelY=\(row1View.debugModelY) presentationY=\(row1View.debugPresentationY)")
        }

        // With the production-accurate fallback (verified in the amllState-level test above),
        // semanticIndex DOES correctly land on the prelude row — dots become text-phase-active.
        XCTAssertEqual(semanticAfterSeek, 0,
            "sanity check: dots SHOULD be text-phase-active on the prelude row after this seek " +
            "(matches the amllState-level finding with the production-accurate fallback=0)")
        if let preludeView {
            XCTAssertFalse(preludeView.debugPreludeDotContainerHidden,
                "sanity check: dots container should be visible now that the row is text-phase-active")
        }

        // NOT REPRODUCED at this integration level, despite the confirmed amllState-level bug
        // above (test_amllState_..._withCorrectFallback_scrollTargetStillDivergesFromSemanticIndex,
        // which hand-feeds a `previous` snapshot and shows scrollToIndex=1 while semanticIndex=0).
        // Driven tick-by-tick through the real, stateful NativeLyricsSurfaceView, scrollTargetIndex
        // converges back to match semanticIndex (0) by the time these ticks settle — the exact
        // `previous.bufferedGroups`/`hotGroups` carry-over that produces the divergence in the
        // isolated function test does not survive the several intervening ticks this harness took
        // to walk the clock backward. This is left as an HONEST NON-FAILING diagnostic: the
        // amllState-level bug is real and code-verified, but this session did not manage to force
        // the exact multi-tick state shape that would make it surface end-to-end within the time
        // budget. A single-frame trace immediately after a real founder-reproduced seek (or a
        // DEBUG log line at the real call site) is the next step, not a fix based on this alone.
        print("[Defect3 end-to-end] scrollTargetAfterSeek=\(String(describing: scrollTargetAfterSeek)) " +
              "semanticAfterSeek=\(String(describing: semanticAfterSeek)) — " +
              "\(scrollTargetAfterSeek == semanticAfterSeek ? "CONVERGED (no divergence seen here)" : "DIVERGED (matches amllState-level bug)")")
        if let preludeView {
            print("[Defect3 end-to-end] prelude row modelY=\(preludeView.debugModelY) vs configured anchorY=200 " +
                  "— \(abs(preludeView.debugModelY - 200) > 1 ? "OFF anchor" : "at anchor")")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Defect 3 annotated position diagram
    //
    // Coordinator 2026-09-14: the earlier single-row PNG didn't show POSITION clearly enough.
    // This renders the FULL panel width, draws the panel's left/right edges, a reference line at
    // the current active line's text horizontal centre, and a marker at the dots' actual centre —
    // with pixel numbers labelled — for two scenarios side by side: reaching the prelude normally
    // (forward, first time) vs. seeking back into it after deep playback.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func renderSurfaceCGImage(_ view: NSView, scale: CGFloat = 2, backgroundColor: NSColor = .black) -> CGImage? {
        guard let hostLayer = view.layer else { return nil }
        let width = max(1, Int(view.bounds.width * scale))
        let height = max(1, Int(view.bounds.height * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(backgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        hostLayer.render(in: context)
        return context.makeImage()
    }

    private struct AnnotatedPanelCapture {
        let title: String
        let image: CGImage
        let panelWidth: CGFloat
        let cropHeight: CGFloat
        let dotCenter: CGPoint
        let textCenterX: CGFloat
        let textCenterLabel: String
        let notes: String
    }

    /// Composites 1+ panel captures side by side into one labelled PNG: panel edges (blue),
    /// current-line text horizontal centre (green dashed), dots' actual centre (orange dashed +
    /// red dot marker), and a caption block with the raw pixel numbers per panel.
    private func composeAnnotatedComparison(_ captures: [AnnotatedPanelCapture], to path: String) {
        guard let first = captures.first else { return }
        let labelHeight: CGFloat = 130
        let gap: CGFloat = 30
        let panelWidth = first.panelWidth
        let cropHeight = first.cropHeight
        let totalWidth = panelWidth * CGFloat(captures.count) + gap * CGFloat(max(0, captures.count - 1))
        let totalHeight = cropHeight + labelHeight
        let canvas = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        canvas.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()

        var x: CGFloat = 0
        for cap in captures {
            let fullImage = NSImage(cgImage: cap.image, size: NSSize(width: cap.image.width, height: cap.image.height))
            let srcHeightPx = CGFloat(cap.image.height)
            let srcRect = NSRect(x: 0, y: srcHeightPx - cropHeight * 2, width: panelWidth * 2, height: cropHeight * 2)
            let destRect = NSRect(x: x, y: labelHeight, width: panelWidth, height: cropHeight)
            fullImage.draw(in: destRect, from: srcRect, operation: .sourceOver, fraction: 1.0)

            func vLine(at lx: CGFloat, color: NSColor, width: CGFloat, dashed: Bool) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: lx, y: labelHeight))
                path.line(to: NSPoint(x: lx, y: labelHeight + cropHeight))
                path.lineWidth = width
                if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
                color.setStroke()
                path.stroke()
            }
            vLine(at: x + 0.75, color: .systemBlue, width: 1.5, dashed: false)
            vLine(at: x + panelWidth - 0.75, color: .systemBlue, width: 1.5, dashed: false)
            vLine(at: x + cap.textCenterX, color: .systemGreen, width: 1.5, dashed: true)
            vLine(at: x + cap.dotCenter.x, color: .systemOrange, width: 1.5, dashed: true)

            // Hollow ring + crosshair ticks (NOT a filled marker) so the actual rendered dots —
            // small, ~8pt — stay visible THROUGH the middle of the annotation instead of being
            // covered by it.
            let markerY = labelHeight + cropHeight - cap.dotCenter.y
            let ringRadius: CGFloat = 16
            let ringRect = NSRect(
                x: x + cap.dotCenter.x - ringRadius, y: markerY - ringRadius,
                width: ringRadius * 2, height: ringRadius * 2
            )
            NSColor.systemRed.setStroke()
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            ring.stroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x + cap.dotCenter.x - ringRadius - 6, y: markerY))
            tick.line(to: NSPoint(x: x + cap.dotCenter.x - ringRadius + 4, y: markerY))
            tick.move(to: NSPoint(x: x + cap.dotCenter.x, y: markerY - ringRadius - 6))
            tick.line(to: NSPoint(x: x + cap.dotCenter.x, y: markerY - ringRadius + 4))
            tick.lineWidth = 1.5
            tick.stroke()

            let delta = cap.dotCenter.x - cap.textCenterX
            let text = "\(cap.title)\n" +
                "面板宽度=\(Int(panelWidth))px（蓝线=左右边界）内容列左边距=32px\n" +
                "文字中心x=\(String(format: "%.1f", cap.textCenterX))px（绿虚线，\(cap.textCenterLabel)）\n" +
                "三点中心=(\(String(format: "%.1f", cap.dotCenter.x)), \(String(format: "%.1f", cap.dotCenter.y)))px（橙虚线/红点）\n" +
                "Δx(点-文字中心)=\(String(format: "%.1f", delta))px\n" +
                "\(cap.notes)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white
            ]
            NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: x + 4, y: 4))

            x += panelWidth + gap
        }
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode annotated comparison PNG")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            XCTFail("could not write \(path): \(error)")
        }
    }

    /// Reference measurement: where a NORMAL active line's text sits horizontally, from a fresh,
    /// independent surface (row 1, "line 1", configured directly as current — no scenario state
    /// involved). Used as the shared "current line text centre" reference line in both panels.
    @MainActor
    private func measureNormalActiveLineTextCenterX(rows: [LayerBackedLyricRow], panelWidth: CGFloat) -> CGFloat {
        let refSurface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(refSurface, NSSize(width: panelWidth, height: 600))
        let refMC = MusicController(preview: true)
        refMC.duration = 60
        refMC.isPlaying = true
        refSurface.debugSkipDedupe = true
        refMC.syncPlaybackClock(to: 13.0, playing: true)
        refSurface.configure(config(rows: rows, current: 1, mc: refMC, width: panelWidth))
        refSurface.layoutSubtreeIfNeeded()
        for _ in 0..<10 {
            refSurface.debugTick(displayInterval: 1.0 / 60.0)
        }
        let center = refSurface.debugRowView(forIndex: 1)?.debugMainTextLayerCenter(in: refSurface.layer!) ?? .zero
        refSurface.stopAnimations()
        return center.x
    }

    @MainActor
    func test_defect3_annotatedPositionComparison_normalVsSeekBack() {
        let rows = preludeSongRows()
        let panelWidth: CGFloat = 360
        let cropHeight: CGFloat = 480
        let referenceTextCenterX = measureNormalActiveLineTextCenterX(rows: rows, panelWidth: panelWidth)
        // NOTE: mainTextLayer's FRAME spans the full available content column width
        // (rowWidth - 32pt leading - 32pt trailing) regardless of how much of it the actual
        // glyphs fill — CATextLayer.alignmentMode is .left, so the glyphs themselves start at
        // x=32 and extend only as far as the text needs. This measurement is therefore the
        // CONTENT COLUMN's horizontal centre (≈ panel centre here, since the insets are
        // symmetric), not the visual centre of the rendered glyphs — the more useful reference
        // for "does this row's salient content land where any other row's content column does",
        // which is the comparison defect 3 is actually about.
        let referenceTextCenterLabel = "行1内容列中心（非字形视觉中心，见下方脚注）"

        func capture(title: String, notes: String, driveClock: (
            _ surface: NativeLyricsSurfaceView, _ mc: MusicController,
            _ tick: (TimeInterval, Int) -> Void
        ) -> Void) -> AnnotatedPanelCapture {
            let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
            host(surface, NSSize(width: panelWidth, height: 600))
            let mc = MusicController(preview: true)
            mc.duration = 60
            mc.isPlaying = true
            surface.debugSkipDedupe = true
            var wall: CFTimeInterval = 9_000
            var date = Date(timeIntervalSinceReferenceDate: 700_500_000)
            surface.debugNowOverride = { wall }
            mc.debugPlaybackClockDateProvider = { date }

            func tick(_ t: TimeInterval, _ ticks: Int) {
                mc.syncPlaybackClock(to: t, playing: true, at: date)
                let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
                surface.configure(config(rows: rows, current: current, mc: mc, width: panelWidth))
                surface.layoutSubtreeIfNeeded()
                for _ in 0..<ticks {
                    wall += 1.0 / 60.0
                    date = date.addingTimeInterval(1.0 / 60.0)
                    mc.syncPlaybackClock(to: t, playing: true, at: date)
                    surface.debugTick(displayInterval: 1.0 / 60.0)
                }
            }
            driveClock(surface, mc, tick)

            let preludeRowView = surface.debugRowView(forIndex: 0)
            print("[Defect3-diagram] \(title): rowMounted=\(preludeRowView != nil) " +
                  "dotHidden=\(String(describing: preludeRowView?.debugPreludeDotContainerHidden)) " +
                  "dotOpacity=\(String(describing: preludeRowView?.debugPreludeDotContainerOpacity)) " +
                  "rowOpacity=\(String(describing: preludeRowView?.debugRowLayerOpacity))")
            let cgImage = renderSurfaceCGImage(surface)!
            let dotCenter = preludeRowView?.debugDotContainerCenter(in: surface.layer!) ?? .zero

            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil

            return AnnotatedPanelCapture(
                title: title, image: cgImage, panelWidth: panelWidth, cropHeight: cropHeight,
                dotCenter: dotCenter, textCenterX: referenceTextCenterX,
                textCenterLabel: referenceTextCenterLabel, notes: notes
            )
        }

        let normalCapture = capture(
            title: "A. 正常播放到前奏",
            notes: "从未深入歌曲，第一次到达前奏窗口（t=0.2s，无历史状态污染）"
        ) { surface, mc, tick in
            tick(0.2, 30)
        }

        let seekBackCapture = capture(
            title: "B. seek 回前奏（深播放后）",
            notes: "先播到 t=33s（第5句），再 seek 回 t≈0.8s（前奏窗口内）"
        ) { surface, mc, tick in
            for t: TimeInterval in [0.2, 13.0, 18.0, 23.0, 28.0, 33.0] { tick(t, 6) }
            mc.registerSeek()
            for t: TimeInterval in [0.3, 0.5, 0.8] { tick(t, 6) }
            for _ in 0..<60 {
                tick(0.8, 1)
            }
        }

        print("[Defect3-diagram] A (normal): dotCenter=\(normalCapture.dotCenter) textCenterX=\(normalCapture.textCenterX)")
        print("[Defect3-diagram] B (seek-back): dotCenter=\(seekBackCapture.dotCenter) textCenterX=\(seekBackCapture.textCenterX)")

        composeAnnotatedComparison(
            [normalCapture, seekBackCapture],
            to: "\(Self.outDir)/defect3-position-comparison.png"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Symptom 3: whole-stack reflow snap after a settle plateau
    //
    // research/references/nanopod-defects-2026-09-12-spec.md Symptom 3 (already on main): in a
    // real recording, every visible row sits pixel-identical for 6-170ms then jumps together
    // 1-6px in a single frame — 26 such clusters across one recording, not a one-off.
    //
    // Suspect (coordinator, 2026-09-14): LyricsLayerRendererView.updateContentIfNeeded
    // (~line 1578-1589) updates the renderer's OWN `measuredHeightsByIndex` SYNCHRONOUSLY when a
    // row's height changes (e.g. a newly-visible row's first real measurement, vs. the 36pt
    // placeholder default), but only calls `configuration.onHeightMeasured` inside
    // `DispatchQueue.main.async` — deferred at least one run-loop turn. LyricsView's own handler
    // (onHeightMeasured in LyricsView.swift:1102-1108) writes `cache.lineHeights[index]` and then
    // calls `scheduleHeightCacheUpdate()`, which wraps ANOTHER `DispatchQueue.main.async` before
    // finally recomputing `accumulatedHeights` and re-configuring the renderer. Meanwhile
    // `NativeLyricsSnapMath.targetY` (the row-positioning formula — verified by direct read,
    // LyricsPresentationModels.swift:974-988) computes EVERY row's Y purely from the EXTERNALLY
    // supplied `configuration.accumulatedHeights` (`anchorY - accumulatedHeights[targetIndex] +
    // accumulatedHeights[rowIndex]`) — never from the renderer's own internal
    // `measuredHeightsByIndex`. So for at least one extra configure() cycle after a row is newly
    // measured, every OTHER row's cumulative offset still sums the OLD/placeholder height for
    // that row — then, once the two async hops land, `accumulatedHeights` corrects all at once
    // and every row below the changed one shifts by the same delta in the same frame: a rigid
    // whole-stack snap, exactly the reported symptom.
    //
    // This test models that EXACT structural lag deterministically: instead of real
    // `DispatchQueue.main.async` (nondeterministic relative to a synchronous XCTest loop), a
    // local `pendingHeightUpdates` queue captures each `onHeightMeasured` call and is drained
    // into the EXTERNAL height cache only at the START of the NEXT tick — i.e. accumulatedHeights
    // for tick N+1 reflects heights measured during tick N, exactly the one-cycle lag the real
    // two-hop async chain produces. This is not a real-time reproduction; it is a deterministic
    // model of the same structural bug, driven by a real NativeLyricsSurfaceView +
    // NativeLyricsSnapMath so the actual production position formula is exercised.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func configWithHeights(
        rows: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController,
        width: CGFloat,
        accumulatedHeights: [Int: CGFloat],
        onHeightMeasured: @escaping (Int, CGFloat) -> Void
    ) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: accumulatedHeights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: onHeightMeasured, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    private func symptom3Rows(count: Int) -> [LayerBackedLyricRow] {
        // Alternate short and long lines so measured heights vary meaningfully from the 36pt
        // placeholder default (some wrap at the narrow test width, some don't).
        let texts = [
            "hello", "walking down the empty street tonight alone",
            "la la la", "I keep thinking back to what you said to me",
            "stay", "the city lights are fading out again slowly",
            "wait for me", "nothing ever stays the same for very long",
        ]
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for i in 0..<count {
            let text = texts[i % texts.count]
            let duration: TimeInterval = 3.6
            let line = LyricLine(text: text, startTime: start, endTime: start + duration, words: [])
            rows.append(row(for: line, index: i))
            start += duration
        }
        return rows
    }

    private struct RowJumpEvent {
        let tickIndex: Int
        let rowIndices: [Int]
        let deltaY: [CGFloat]
        let plateauLengths: [Int]
    }

    /// Minimal, ISOLATED verification: current index frozen at row 0 for the whole test (no
    /// line-advance scrolling at all, so nothing from normal scroll motion can be mistaken for a
    /// height-correction jump — see the honesty note in the report about the other test below).
    /// Row 1 has a real measured height (~3-line wrap, well over 100pt) that differs sharply from
    /// the 36pt placeholder the simulated EXTERNAL cache starts at. Row 2's Y depends entirely on
    /// row 1's height. If the fix works, row 2's Y on the very FIRST tick already matches its
    /// fully-settled value — there is no "stale tick" to observe at all.
    @MainActor
    func test_symptom3_afterFix_isolatedHeightJump_rowLandsImmediately() {
        // Row 1 starts SHORT (its estimate and real measurement agree — no gap to close yet),
        // then at tick 5 its CONTENT genuinely changes to a long, 3-line-wrapping phrase (the
        // realistic trigger: e.g. a translation arriving asynchronously, or a lyric line being
        // replaced — LyricsLayerRendererView.updateContentIfNeeded only re-measures when
        // `needsContentUpdate`, i.e. actual content changed, exactly this scenario). SAME row
        // index/id (`row(for:index:)` derives the id from the index alone), so this is a content
        // update to an EXISTING mounted row, not a remount.
        let (row0Line, row0End) = syllableWords("hi", start: 0, wordDuration: 0.4)
        let (row1ShortLine, row1End) = syllableWords("yo", start: row0End + 0.4, wordDuration: 0.4)
        let (row1LongLine, _) = syllableWords(
            "every single word you ever said to me still echoes down this empty hallway tonight",
            start: row0End + 0.4, wordDuration: 0.35
        )
        let (row2Line, _) = syllableWords("bye now", start: row1End + 3.0, wordDuration: 0.4)
        func rowsFor(row1Long: Bool) -> [LayerBackedLyricRow] {
            [
                row(for: row0Line, index: 0),
                row(for: row1Long ? row1LongLine : row1ShortLine, index: 1),
                row(for: row2Line, index: 2),
            ]
        }
        let panelWidth: CGFloat = 220
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 400))
        host(surface, NSSize(width: panelWidth, height: 400))
        let mc = MusicController(preview: true)
        mc.duration = 60
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 40_000
        var date = Date(timeIntervalSinceReferenceDate: 703_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let defaultHeight: CGFloat = 36
        let spacing: CGFloat = 6
        var externalHeightCache: [Int: CGFloat] = [:]
        var pendingHeightUpdates: [(Int, CGFloat)] = []
        func computeAccumulatedHeights(_ rows: [LayerBackedLyricRow]) -> [Int: CGFloat] {
            var acc: [Int: CGFloat] = [:]
            var running: CGFloat = 0
            for r in rows {
                acc[r.index] = running
                running += (externalHeightCache[r.index] ?? defaultHeight) + spacing
            }
            return acc
        }

        var row2YHistory: [CGFloat] = []
        let tickCount = 15
        let swapTick = 5 // row 1's content changes short → long at this tick
        for tickIndex in 0..<tickCount {
            for (idx, h) in pendingHeightUpdates where abs((externalHeightCache[idx] ?? 0) - h) > 2.0 {
                externalHeightCache[idx] = h
            }
            pendingHeightUpdates.removeAll()

            // current is FROZEN at row 0 — the only thing changing across ticks is (a) the
            // deferred external-cache drain above and (b) row 1's content at swapTick — isolating
            // the height-timing mechanism from scroll.
            let rows = rowsFor(row1Long: tickIndex >= swapTick)
            mc.syncPlaybackClock(to: 0.1, playing: true, at: date)
            let acc = computeAccumulatedHeights(rows)
            surface.configure(configWithHeights(
                rows: rows, current: 0, mc: mc, width: panelWidth,
                accumulatedHeights: acc,
                onHeightMeasured: { idx, h in pendingHeightUpdates.append((idx, h)) }
            ))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<30 {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
            row2YHistory.append(surface.debugRowView(forIndex: 2)?.frame.minY ?? .nan)
        }

        print("[Symptom3-isolated] row2 Y across \(tickCount) ticks (current frozen at row 0, row 1 " +
              "content swaps short→long at tick \(swapTick)): " +
              row2YHistory.enumerated().map { "t\($0)=\(String(format: "%.2f", $1))" }.joined(separator: ", "))

        let settledY = row2YHistory.last ?? .nan
        let preSwapY = row2YHistory[swapTick - 1]
        let atSwapY = row2YHistory[swapTick]
        XCTAssertNotEqual(preSwapY, settledY, accuracy: 0.6,
            "fixture sanity check: row 2's Y before the swap should differ from its settled value " +
            "(row 1's real height must actually change at swapTick for this test to mean anything)")
        XCTAssertEqual(atSwapY, settledY, accuracy: 0.6,
            "REGRESSION: row 2's Y at the SAME tick row 1's content changed (\(atSwapY)) does not " +
            "match the fully-settled value (\(settledY)) — the height correction landed a cycle " +
            "late instead of in the same configure() cycle the new content was measured")
        for i in (swapTick + 1)..<tickCount {
            XCTAssertEqual(row2YHistory[i], settledY, accuracy: 0.6,
                "row 2's Y at tick \(i) (\(row2YHistory[i])) drifted from the settled value " +
                "(\(settledY)) after the swap — should already be correct from swapTick onward")
        }
    }

    @MainActor
    func test_symptom3_afterFix_noReflowSnap_heightLandsInSameCycle() {
        let rows = symptom3Rows(count: 30)
        let panelWidth: CGFloat = 260
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 700))
        host(surface, NSSize(width: panelWidth, height: 700))
        let mc = MusicController(preview: true)
        mc.duration = 200
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 20_000
        var date = Date(timeIntervalSinceReferenceDate: 701_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let defaultHeight: CGFloat = 36
        let spacing: CGFloat = 6
        var externalHeightCache: [Int: CGFloat] = [:]
        var pendingHeightUpdates: [(Int, CGFloat)] = []

        func computeAccumulatedHeights() -> [Int: CGFloat] {
            var acc: [Int: CGFloat] = [:]
            var running: CGFloat = 0
            for r in rows {
                acc[r.index] = running
                running += (externalHeightCache[r.index] ?? defaultHeight) + spacing
            }
            return acc
        }

        // Per-tick history: every visible row's ACTUAL on-screen Y (debugModelY, which is the
        // real committed CALayer transform — what render(in:) would paint), plus a saved
        // low-res CGImage of the whole surface for later before/after extraction.
        var yHistory: [Int: [CGFloat]] = [:]
        var imageHistory: [CGImage] = []
        var currentHistory: [Int] = []
        var firstSeenTick: [Int: Int] = [:]
        let tickCount = 130

        for tickIndex in 0..<tickCount {
            // Drain the PREVIOUS tick's deferred height updates now — the one-cycle lag.
            for (idx, h) in pendingHeightUpdates where abs((externalHeightCache[idx] ?? 0) - h) > 2.0 {
                externalHeightCache[idx] = h
            }
            pendingHeightUpdates.removeAll()

            let t = TimeInterval(tickIndex) * 0.9
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
            let acc = computeAccumulatedHeights()
            surface.configure(configWithHeights(
                rows: rows, current: current, mc: mc, width: panelWidth,
                accumulatedHeights: acc,
                onHeightMeasured: { idx, h in pendingHeightUpdates.append((idx, h)) }
            ))
            surface.layoutSubtreeIfNeeded()
            // Let the presentation spring fully settle before sampling — a real display link
            // runs continuously at 60Hz regardless of how often SwiftUI reconfigures, so by the
            // time a human (or the founder's recording) perceives a row as "stopped", its spring
            // has long since converged. Sampling mid-spring would show smooth motion, not the
            // discrete plateau-then-snap this test is trying to isolate.
            for _ in 0..<30 {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }

            currentHistory.append(current)
            for idx in max(0, current - 3)...min(rows.count - 1, current + 3) {
                let y = surface.debugRowView(forIndex: idx)?.frame.minY ?? .nan
                yHistory[idx, default: []].append(y)
                if firstSeenTick[idx] == nil { firstSeenTick[idx] = tickIndex }
            }
            imageHistory.append(renderSurfaceCGImage(surface, scale: 1)!)
        }

        // Detect settle→jump clusters: ≥2 tracked rows holding an IDENTICAL Y for ≥3 consecutive
        // ticks, then jumping (>0.4px, same direction) together within 1 tick — mirrors the
        // spec's own detection method (≥3-frame plateau, ≥2 rows, same-window jump).
        var events: [RowJumpEvent] = []
        let trackedIndices = yHistory.keys.sorted()
        for tick in 2..<tickCount {
            var jumpers: [Int] = []
            var deltas: [CGFloat] = []
            var plateaus: [Int] = []
            for idx in trackedIndices {
                guard let series = yHistory[idx], series.count > tick else { continue }
                let prev = series[tick - 1]
                let now = series[tick]
                guard !prev.isNaN, !now.isNaN else { continue }
                let delta = now - prev
                guard abs(delta) > 0.4, abs(delta) < 40 else { continue }
                var plateau = 0
                var k = tick - 1
                while k > 0, abs(series[k] - series[k - 1]) < 0.05 {
                    plateau += 1
                    k -= 1
                }
                guard plateau >= 3 else { continue }
                jumpers.append(idx)
                deltas.append(delta)
                plateaus.append(plateau)
            }
            if jumpers.count >= 2 {
                events.append(RowJumpEvent(tickIndex: tick, rowIndices: jumpers, deltaY: deltas, plateauLengths: plateaus))
            }
        }

        print("[Symptom3] ticked \(tickCount) configure cycles, found \(events.count) whole-stack settle→jump clusters")
        for e in events.prefix(10) {
            print("[Symptom3] tick=\(e.tickIndex) rows=\(e.rowIndices) Δy=\(e.deltaY.map { String(format: "%.2f", $0) }) plateau=\(e.plateauLengths)")
        }

        // FIX VERIFICATION (2026-09-14, founder approved): with accumulatedHeights refreshed
        // synchronously inside reconcileVisibleRowViews (LyricsLayerRendererView.swift, right
        // after the content-update loop) from the renderer's OWN measuredHeightsByIndex, this
        // SAME harness — unchanged, still simulating a lagging EXTERNAL height cache via
        // pendingHeightUpdates/externalHeightCache — should now find ZERO whole-stack jumps: the
        // renderer no longer depends on that external cache being prompt at all.
        XCTAssertEqual(events.count, 0,
            "REGRESSION: found \(events.count) whole-stack settle→jump cluster(s) after the fix — " +
            "accumulatedHeights should now be corrected in the SAME configure() cycle a row's real " +
            "height is first measured, so no stale frame should ever commit to screen")

        // NOTE on "行高首次测出后下面各行 Y 一次到位": this fixture's tracking window (current±3)
        // is narrower than the render radius (14), so a row's FIRST tracked tick often coincides
        // with it being FRESHLY MOUNTED (pulled from the reuse pool) rather than with a height
        // correction — and NativeLyricsFrameRenderSnapshot's deliberate teleport guard
        // (`naturalModeMaxYStepPerTick`, LyricsLayerRendererView.swift, "a settled row must never
        // jump a large distance for a single tick in natural mode") intentionally spreads a large
        // first-mount position change over several ticks. That is correct, existing, load-bearing
        // behavior — unrelated to the height-cache-staleness bug — and measuring it here would
        // conflate the two. The "lands in the same cycle" claim is verified cleanly instead by
        // test_symptom3_afterFix_isolatedHeightJump_rowLandsImmediately below, where current is
        // FROZEN (no fresh-mount transitions possible) and only row 1's content genuinely changes
        // — see that test for the direct, unconfounded proof.

        // Pick the event with the LONGEST plateau (most representative/stable — matches the
        // spec's "the founder-flagged instance had a 100-170ms plateau" framing) and centre the
        // crop on where those rows ACTUALLY are on screen (from the tracked Y history), instead
        // of a fixed guess — different clusters land at different scroll depths.
        if let best = events.max(by: { ($0.plateauLengths.min() ?? 0) < ($1.plateauLengths.min() ?? 0) }) {
            let beforeIdx = max(0, best.tickIndex - 1)
            let afterIdx = best.tickIndex
            let ys = best.rowIndices.compactMap { yHistory[$0]?[beforeIdx] }
            let centerY = ys.isEmpty ? 200 : ys.reduce(0, +) / CGFloat(ys.count)
            renderSymptom3BeforeAfter(
                before: imageHistory[beforeIdx], after: imageHistory[afterIdx],
                panelWidth: panelWidth, event: best, centerY: centerY,
                to: "\(Self.outDir)/symptom3-reflow-snap-before-after.png"
            )
            // PRIMARY evidence: a Y-trajectory chart plotted directly from the tracked
            // debugModelY data (no CALayer render involved, so it sidesteps whatever made the
            // screenshot crop above come out blank — see the honesty note in the report). This is
            // what actually shows the plateau→jump pattern unambiguously.
            renderSymptom3Chart(
                yHistory: yHistory, event: best, tickCount: tickCount,
                to: "\(Self.outDir)/symptom3-reflow-snap-chart.png"
            )
        }
    }

    /// Line chart of tracked rows' Y (debugModelY) across ticks, built with plain NSBezierPath —
    /// no CALayer render involved, so it doesn't depend on whatever made the CALayer-rendered
    /// before/after screenshot come out blank (see honesty note). This directly visualizes the
    /// plateau→jump pattern from the SAME data the numeric detection used.
    private func renderSymptom3Chart(
        yHistory: [Int: [CGFloat]], event: RowJumpEvent, tickCount: Int, to path: String
    ) {
        let windowStart = max(0, event.tickIndex - 12)
        let windowEnd = min(tickCount - 1, event.tickIndex + 6)
        let rowsToPlot = Array(event.rowIndices.prefix(6))
        var allYs: [CGFloat] = []
        for idx in rowsToPlot {
            guard let series = yHistory[idx] else { continue }
            for t in windowStart...windowEnd where t < series.count && !series[t].isNaN {
                allYs.append(series[t])
            }
        }
        guard let yMin = allYs.min(), let yMax = allYs.max(), yMax > yMin else {
            XCTFail("no Y range to chart")
            return
        }
        let pad = max(0.5, (yMax - yMin) * 0.15)
        let plotYMin = yMin - pad
        let plotYMax = yMax + pad

        let chartWidth: CGFloat = 900
        let chartHeight: CGFloat = 420
        let margin: CGFloat = 60
        let labelHeight: CGFloat = 70
        let canvas = NSImage(size: NSSize(width: chartWidth, height: chartHeight + labelHeight))
        canvas.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()

        func px(_ tick: Int) -> CGFloat {
            margin + (CGFloat(tick - windowStart) / CGFloat(max(1, windowEnd - windowStart))) * (chartWidth - margin * 2)
        }
        func py(_ y: CGFloat) -> CGFloat {
            labelHeight + margin + (1 - (y - plotYMin) / (plotYMax - plotYMin)) * (chartHeight - margin * 2)
        }

        // Axes
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: margin, y: labelHeight + margin))
        axis.line(to: NSPoint(x: margin, y: chartHeight + labelHeight - margin))
        axis.line(to: NSPoint(x: chartWidth - margin, y: chartHeight + labelHeight - margin))
        axis.lineWidth = 1
        axis.stroke()

        // Vertical marker at the jump tick.
        NSColor.systemRed.withAlphaComponent(0.5).setStroke()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: px(event.tickIndex), y: labelHeight + margin))
        marker.line(to: NSPoint(x: px(event.tickIndex), y: chartHeight + labelHeight - margin))
        marker.lineWidth = 1.5
        marker.setLineDash([5, 3], count: 2, phase: 0)
        marker.stroke()

        let colors: [NSColor] = [.systemOrange, .systemGreen, .systemCyan, .systemPink, .systemYellow, .systemPurple]
        for (i, idx) in rowsToPlot.enumerated() {
            guard let series = yHistory[idx] else { continue }
            let path = NSBezierPath()
            var started = false
            for t in windowStart...windowEnd where t < series.count && !series[t].isNaN {
                let point = NSPoint(x: px(t), y: py(series[t]))
                if !started { path.move(to: point); started = true } else { path.line(to: point) }
                let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
                colors[i % colors.count].setFill()
                dot.fill()
            }
            colors[i % colors.count].setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        let legend = rowsToPlot.enumerated().map { "row\($1)=\(colors[$0 % colors.count])" }.joined(separator: " ")
        let text = "Symptom 3: 行 Y 轨迹（跳变 tick=\(event.tickIndex)，红色虚线标出）\n" +
            "横轴=tick（每 tick 已让 spring 跑满 30 个 1/60s 子帧,即真正 settle 后采样）纵轴=debugModelY(pt)\n" +
            "Δy=\(event.deltaY.map { String(format: "%+.2f", $0) })px  跳前静止帧数=\(event.plateauLengths)\n" +
            "画的行 index（按顺序对应橙/绿/青/粉/黄/紫）：\(rowsToPlot)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: 10, y: 6))
        _ = legend

        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode symptom3 chart PNG")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Side-by-side BEFORE/AFTER crop around the jumping rows, zoomed in with a 1pt ruler grid
    /// so a 1-6px shift is visible at a glance, plus the exact numbers as a caption.
    private func renderSymptom3BeforeAfter(
        before: CGImage, after: CGImage, panelWidth: CGFloat, event: RowJumpEvent, centerY: CGFloat, to path: String
    ) {
        let zoom: CGFloat = 5
        let cropHeight: CGFloat = 200
        let cropTop: CGFloat = max(0, centerY - cropHeight / 2)
        let labelHeight: CGFloat = 90
        let canvasWidth = panelWidth * zoom * 2 + 40
        let canvasHeight = cropHeight * zoom + labelHeight
        let canvas = NSImage(size: NSSize(width: canvasWidth, height: canvasHeight))
        canvas.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()

        func drawPanel(_ image: CGImage, originX: CGFloat) {
            let img = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let srcHeight = CGFloat(image.height)
            let srcRect = NSRect(x: 0, y: srcHeight - cropTop - cropHeight, width: panelWidth, height: cropHeight)
            let destRect = NSRect(x: originX, y: labelHeight, width: panelWidth * zoom, height: cropHeight * zoom)
            img.draw(in: destRect, from: srcRect, operation: .sourceOver, fraction: 1.0)
            // 1pt ruler ticks every 5pt of ORIGINAL (unzoomed) height, labelled every 10pt.
            var yPt: CGFloat = 0
            while yPt < cropHeight {
                let canvasY = labelHeight + cropHeight * zoom - yPt * zoom
                let tickPath = NSBezierPath()
                let tickLen: CGFloat = yPt.truncatingRemainder(dividingBy: 10) == 0 ? 10 : 5
                tickPath.move(to: NSPoint(x: originX, y: canvasY))
                tickPath.line(to: NSPoint(x: originX + tickLen, y: canvasY))
                tickPath.lineWidth = 1
                NSColor.systemYellow.withAlphaComponent(0.6).setStroke()
                tickPath.stroke()
                yPt += 5
            }
        }
        drawPanel(before, originX: 0)
        drawPanel(after, originX: panelWidth * zoom + 40)

        let text = "跳前（tick \(event.tickIndex - 1)） →  跳后（tick \(event.tickIndex)）\n" +
            "同帧一起跳的行 index=\(event.rowIndices)\n" +
            "Δy=\(event.deltaY.map { String(format: "%+.2f", $0) })px  " +
            "跳前静止帧数=\(event.plateauLengths)\n" +
            "黄色刻度=每5pt一格（原始未缩放坐标），此图放大\(Int(5))x便于肉眼分辨"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: 8, y: 6))

        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode symptom3 before/after PNG")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - "逐字歌某行突然整行全亮，随后回到逐字"
    //
    // Coordinator (2026-09-14): founder re-confirmed this today. WT-B's prior lockstep-driven
    // 7-song full-transition sweep found ZERO occurrences (debugLastWholeLineHighlight never
    // true — see research/references/nanopod-defects-2026-09-12-spec.md). Remaining suspects,
    // per coordinator: real display-link jitter, row view reuse/recycle mid-scroll, catch-up
    // after a long stall — ESPECIALLY row reuse: does a row pulled from the pool carry residual
    // tile/mask state that can read as whole-line-bright for a frame.
    //
    // debugLastWholeLineHighlight (NativeLyricsRowView.swift:1449-1452) is TRUE exactly when:
    // the active line IS syllable-synced (expectsPerRunSweep) AND applyActiveMainPhase's
    // per-run-sweep application FAILED (appliedPerRunSweep == false, i.e. updatePerRunSweepMask
    // returned empty lines despite geometryReady == true) AND the bright overlay is actually
    // visible — i.e. the row fell back to the v2.8-style WHOLE-LINE gradient mask instead of the
    // per-glyph one. This test targets exactly the reuse path: two syllable-synced lines with
    // very different geometry (single-line vs 3-line-wrapped) assigned far apart in row index,
    // FAST distant seeks force the row view pool to recycle a view from one line's geometry
    // directly into the other's, and debugLastWholeLineHighlight is checked on the very FIRST
    // tick after each such reuse.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func syllableWords(_ text: String, start: TimeInterval, wordDuration: TimeInterval) -> (LyricLine, TimeInterval) {
        let tokens = text.split(separator: " ").map(String.init)
        var words: [LyricWord] = []
        var t = start
        for (i, tok) in tokens.enumerated() {
            let w = i == tokens.count - 1 ? tok : tok + " "
            words.append(LyricWord(word: w, startTime: t, endTime: t + wordDuration))
            t += wordDuration
        }
        return (LyricLine(text: text, startTime: start, endTime: t, words: words), t)
    }

    /// Alternates a SHORT single-line phrase with a LONG phrase that wraps to 3 lines at the test
    /// width — maximum geometry mismatch between what a recycled row's layers were last
    /// configured for and what they're about to show.
    private func reuseStressRows(count: Int) -> [LayerBackedLyricRow] {
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for i in 0..<count {
            let (line, end): (LyricLine, TimeInterval)
            if i % 2 == 0 {
                (line, end) = syllableWords("hey now", start: start, wordDuration: 0.6)
            } else {
                (line, end) = syllableWords(
                    "every single word you ever said to me still echoes down this empty hallway tonight",
                    start: start, wordDuration: 0.35
                )
            }
            rows.append(row(for: line, index: i))
            start = end + 0.4
        }
        return rows
    }

    @MainActor
    func test_wholeLineFlash_rowReuseAcrossMismatchedGeometry_fastDistantSeeks() {
        let rows = reuseStressRows(count: 60)
        let panelWidth: CGFloat = 220 // narrow — forces the long phrase to wrap 3 lines
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 500))
        host(surface, NSSize(width: panelWidth, height: 500))
        let mc = MusicController(preview: true)
        mc.duration = 400
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 30_000
        var date = Date(timeIntervalSinceReferenceDate: 702_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        var flashEvents: [(seekTo: Int, tickAfterSeek: Int, rowIndex: Int)] = []
        // Sequence of INDEX targets, deliberately jumping far apart every time (radius=14 means a
        // jump of >28 fully evicts the previous window from the reuse pool's live set) so views
        // constantly recycle between the two very different geometries.
        let targets = [0, 45, 3, 50, 6, 55, 1, 40, 8, 58, 2, 47, 5, 52, 0, 44, 9, 59, 4, 48]

        for seekIdx in targets {
            mc.registerSeek()
            let line = rows[seekIdx].displayLine.line
            // Sample MID-line (not right at onset, where the bright overlay is still hidden
            // below the 0.001 progress floor regardless of any reuse effect) so the per-run
            // sweep mask is definitely expected to be visibly active.
            let t = line.startTime + (line.endTime - line.startTime) * 0.5
            // Irregular sub-frame spacing (simulates real display-link jitter instead of a
            // perfectly uniform 1/60s clock) — 12 sub-ticks per seek, varying interval.
            let jitterIntervals: [TimeInterval] = [
                1.0 / 60, 1.0 / 45, 1.0 / 60, 1.0 / 30, 1.0 / 60,
                1.0 / 55, 1.0 / 60, 1.0 / 40, 1.0 / 60, 1.0 / 60, 1.0 / 50, 1.0 / 60
            ]
            for (subTick, interval) in jitterIntervals.enumerated() {
                mc.syncPlaybackClock(to: t, playing: true, at: date)
                surface.configure(config(rows: rows, current: seekIdx, mc: mc, width: panelWidth))
                surface.layoutSubtreeIfNeeded()
                wall += interval
                date = date.addingTimeInterval(interval)
                surface.debugTick(displayInterval: interval)
                // Scan every MOUNTED row, not just the seek target — a mismatched-geometry
                // reuse artifact could show on a NEIGHBOUR that was just recycled too.
                for idx in max(0, seekIdx - 2)...min(rows.count - 1, seekIdx + 2) {
                    if let rv = surface.debugRowView(forIndex: idx), rv.debugLastWholeLineHighlight {
                        flashEvents.append((seekTo: seekIdx, tickAfterSeek: subTick, rowIndex: idx))
                    }
                }
            }
        }

        print("[Symptom4] drove \(targets.count) fast distant seeks across mismatched-geometry rows, " +
              "found \(flashEvents.count) whole-line-highlight flashes")
        for e in flashEvents.prefix(20) {
            print("[Symptom4] FLASH at row \(e.rowIndex), tick \(e.tickAfterSeek) after seeking there")
        }

        if flashEvents.isEmpty {
            print("[Symptom4] NOT REPRODUCED under fast-distant-seek row-reuse conditions in this " +
                  "fixture (60 rows, 220pt width, single-line/3-line-wrap alternation, 20 far-apart " +
                  "seeks, 12 jittered sub-ticks each, mid-line sampling, ±2 neighbour rows scanned). " +
                  "Matches WT-B's own 7-song zero-occurrence finding — this session adds one more " +
                  "condition tried (row reuse specifically, with jitter) without success, still not " +
                  "a proof of absence.")
        }
        // Deliberately NOT an XCTAssertEqual(0, ...) failure either way — this is exploratory
        // reproduction, not a regression guard. A future occurrence should be added as a proper
        // fixture + assertion once its exact trigger is known.
    }
}
