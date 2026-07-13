//
//  NativeLyricsDimBaseContinuityTests.swift
//
//  Defect 3, second root cause (user's live observation, 2026-07-12): the dim-base
//  brightness of a karaoke row is the PRODUCT of two channels that change at different
//  speeds during a handoff:
//
//    - attributed-text alpha: switched INSTANTLY on activation (1.0 → dimAlpha 0.25)
//    - row layer opacity:     spring-animated (0.35 → 1.0 over ~300ms)
//
//  At the activation frame the product collapses to 0.25 × 0.35 ≈ 0.09 — the incoming
//  line visibly dips dark, then brightens along the spring. The receding line steps the
//  other way. On top of the transient, the steady states never matched either: active
//  unswept text read 0.25 while inactive rows read 0.35.
//
//  Contract (user decision 2026-07-12): the unswept dim base of the active line reads at
//  the SAME effective brightness as an inactive row (the 0.35 tier; 0.6 in manual scroll),
//  and that effective brightness is CONTINUOUS through the handoff — the only visual event
//  on the incoming line is the bright sweep itself.
//
//  Mechanism under test: attributed alphas stay state-independent; the dim tier rides
//  mainTextLayer/translationTextLayer opacity, compensated per frame against the row
//  opacity spring (tier / rowOpacity, clamped to 1) so the product never steps.
//
//  These are model-state tests (layer model values, no presentation timing), so no window
//  host or CATransaction flush is needed.
//

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

final class NativeLyricsDimBaseContinuityTests: XCTestCase {

    private static let inactiveTier: CGFloat = 0.35
    private static let manualTier: CGFloat = 0.6
    private static let translationBaseFactor: CGFloat = 0.85

    // ── Fixtures ─────────────────────────────────────────────────────────────

    private func row(index: Int) -> LayerBackedLyricRow {
        let start = TimeInterval(index * 4)
        let line = LyricLine(
            text: "line \(index) words here",
            startTime: start,
            endTime: start + 3,
            words: [
                LyricWord(word: "line ", startTime: start, endTime: start + 1),
                LyricWord(word: "\(index) ", startTime: start + 1, endTime: start + 2),
                LyricWord(word: "words here", startTime: start + 2, endTime: start + 3),
            ],
            translation: "第 \(index) 行翻译"
        )
        let displayLine = DisplayLyricLine(
            id: "dimbase-\(index)",
            sourceIndex: index,
            segmentIndex: 0,
            segmentCount: 1,
            line: line
        )
        return LayerBackedLyricRow(
            id: displayLine.id,
            index: index,
            displayLine: displayLine,
            sourceLine: line,
            isPrelude: false,
            preludeEndTime: 0,
            interlude: nil
        )
    }

    @MainActor
    private func config(
        rows: [LayerBackedLyricRow],
        currentIndex: Int,
        musicController: MusicController,
        showTranslation: Bool = false,
        isManualScrolling: Bool = false
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for row in rows {
            heights[row.index] = CGFloat(row.index) * 56
        }
        return LyricsLayerRendererConfiguration(
            rows: rows,
            currentIndex: currentIndex,
            anchorY: 250,
            rowWidth: 320,
            renderedIndices: rows.map(\.index),
            accumulatedHeights: heights,
            lineTargetIndices: [:],
            lineInterval: 3,
            hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 60),
            isWaveTimelineDiagnosticsEnabled: false,
            isManualScrolling: isManualScrolling,
            reduceMotion: false,
            suppressInitialMotion: false,
            pendingTranslationLineIndices: [],
            showTranslation: showTranslation,
            isTranslating: false,
            translationFailed: false,
            interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: false,
            musicController: musicController,
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

    @MainActor
    private func makeController(time: TimeInterval) -> MusicController {
        let mc = MusicController(preview: true)
        mc.duration = 60
        mc.isPlaying = true
        mc.syncPlaybackClock(to: time, playing: true)
        return mc
    }

    /// Effective on-screen brightness of the MAIN dim base: the product of every
    /// contributing channel (row layer opacity × base layer opacity × attributed alpha).
    @MainActor
    private func mainEffective(_ view: NativeLyricsRowView) -> CGFloat {
        CGFloat(view.debugRowLayerOpacity)
            * CGFloat(view.debugMainBaseLayerOpacity)
            * view.debugMainBaseAttrAlpha
    }

    @MainActor
    private func translationEffective(_ view: NativeLyricsRowView) -> CGFloat {
        CGFloat(view.debugRowLayerOpacity)
            * CGFloat(view.debugTranslationBaseLayerOpacity)
            * view.debugTranslationBaseAttrAlpha
    }

    // ── Pure target model ────────────────────────────────────────────────────

    func test_amllTarget_dimBaseBrightness_matchesInactiveTier() {
        let hot = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5, currentIndex: 5, scrollTargetIndex: 5,
            hotActiveIndices: [], isManualScrolling: false
        )
        let inactive = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 4, currentIndex: 5, scrollTargetIndex: 5,
            hotActiveIndices: [], isManualScrolling: false
        )
        XCTAssertEqual(hot.dimBaseBrightness, Self.inactiveTier, accuracy: 0.001,
                       "hot row dim base must read at the inactive tier")
        XCTAssertEqual(hot.dimBaseBrightness, inactive.opacity, accuracy: 0.001,
                       "equalized: active unswept text == inactive row brightness")
        let manual = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5, currentIndex: 5, scrollTargetIndex: 5,
            hotActiveIndices: [], isManualScrolling: true
        )
        XCTAssertEqual(manual.dimBaseBrightness, Self.manualTier, accuracy: 0.001,
                       "manual scroll: dim base matches the all-clear 0.6 tier")
    }

    // ── Activation: the incoming line ────────────────────────────────────────

    @MainActor
    func test_activation_effectiveDimBrightness_isContinuous() {
        let mc = makeController(time: 4.5)
        let rows = [row(index: 0), row(index: 1), row(index: 2)]
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))

        // Resting inactive (current line is row 0).
        view.configure(row: rows[1], configuration: config(rows: rows, currentIndex: 0, musicController: mc),
                       updatesPlaybackPhase: false)
        view.setRowOpacity(0.35, dimBaseBrightness: Float(Self.inactiveTier))
        let before = mainEffective(view)
        XCTAssertEqual(before, Self.inactiveTier, accuracy: 0.01, "precondition: inactive tier")

        // The activation frame: row 1 becomes the hot karaoke line while the row
        // opacity spring is still at its inactive value. This is where the old
        // two-channel product collapsed to 0.25 × 0.35 ≈ 0.09.
        view.configure(row: rows[1], configuration: config(rows: rows, currentIndex: 1, musicController: mc),
                       updatesPlaybackPhase: false)
        view.setRowOpacity(0.35, dimBaseBrightness: Float(Self.inactiveTier))
        XCTAssertEqual(mainEffective(view), before, accuracy: 0.01,
                       "activation frame must not step the dim base brightness")

        // Spring frames toward full row opacity: effective brightness stays pinned.
        for op: Float in [0.45, 0.6, 0.8, 0.95, 1.0] {
            view.setRowOpacity(op, dimBaseBrightness: Float(Self.inactiveTier))
            XCTAssertEqual(mainEffective(view), Self.inactiveTier, accuracy: 0.01,
                           "spring frame at row opacity \(op)")
        }
    }

    // ── Deactivation: the receding line (deferred, still rendered hot) ──────

    @MainActor
    func test_deactivationRecede_effectiveDimBrightness_isContinuous() {
        let mc = makeController(time: 4.5)
        let rows = [row(index: 0), row(index: 1), row(index: 2)]
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))

        view.configure(row: rows[1], configuration: config(rows: rows, currentIndex: 1, musicController: mc),
                       updatesPlaybackPhase: false)
        // The deferred-deactivation window keeps the hot rendering while the row
        // opacity spring descends; the dim base must hold the tier the whole way.
        for op: Float in [1.0, 0.85, 0.65, 0.45, 0.38] {
            view.setRowOpacity(op, dimBaseBrightness: Float(Self.inactiveTier))
            XCTAssertEqual(mainEffective(view), Self.inactiveTier, accuracy: 0.01,
                           "recede frame at row opacity \(op)")
        }

        // Finalize: the row re-renders as inactive near the 0.38 threshold. The
        // hand-back may step at most to the row opacity itself (0.38 vs 0.35).
        view.configure(row: rows[1], configuration: config(rows: rows, currentIndex: 2, musicController: mc),
                       updatesPlaybackPhase: false)
        view.setRowOpacity(0.38, dimBaseBrightness: Float(Self.inactiveTier))
        XCTAssertEqual(mainEffective(view), Self.inactiveTier, accuracy: 0.04,
                       "finalize hand-back stays within one perceptual step of the tier")
    }

    // ── Translation base rides the same compensation ─────────────────────────

    @MainActor
    func test_translationBase_effectiveBrightness_isContinuous() {
        let mc = makeController(time: 4.5)
        let rows = [row(index: 0), row(index: 1), row(index: 2)]
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        let expected = Self.translationBaseFactor * Self.inactiveTier

        view.configure(row: rows[1],
                       configuration: config(rows: rows, currentIndex: 0, musicController: mc, showTranslation: true),
                       updatesPlaybackPhase: false)
        view.setRowOpacity(0.35, dimBaseBrightness: Float(Self.inactiveTier))
        XCTAssertEqual(translationEffective(view), expected, accuracy: 0.01,
                       "precondition: inactive translation tier")

        view.configure(row: rows[1],
                       configuration: config(rows: rows, currentIndex: 1, musicController: mc, showTranslation: true),
                       updatesPlaybackPhase: false)
        for op: Float in [0.35, 0.5, 0.75, 1.0] {
            view.setRowOpacity(op, dimBaseBrightness: Float(Self.inactiveTier))
            XCTAssertEqual(translationEffective(view), expected, accuracy: 0.01,
                           "translation base at row opacity \(op)")
        }
    }

    // ── Manual scroll uses the all-clear tier ────────────────────────────────

    @MainActor
    func test_manualScroll_hotRowDimBase_matchesNeighbourTier() {
        let mc = makeController(time: 4.5)
        let rows = [row(index: 0), row(index: 1), row(index: 2)]
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))

        view.configure(row: rows[1],
                       configuration: config(rows: rows, currentIndex: 1, musicController: mc, isManualScrolling: true),
                       updatesPlaybackPhase: false)
        view.setRowOpacity(Float(Self.manualTier), dimBaseBrightness: Float(Self.manualTier))
        XCTAssertEqual(mainEffective(view), Self.manualTier, accuracy: 0.01,
                       "manual scroll: hot row dim base reads like every other row (all-clear)")
    }

    // ── Reuse + churn guards ─────────────────────────────────────────────────

    @MainActor
    func test_prepareForReuse_resetsDimBaseCompensation() {
        let mc = makeController(time: 4.5)
        let rows = [row(index: 0), row(index: 1), row(index: 2)]
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))

        view.configure(row: rows[1], configuration: config(rows: rows, currentIndex: 1, musicController: mc),
                       updatesPlaybackPhase: false)
        view.setRowOpacity(1.0, dimBaseBrightness: Float(Self.inactiveTier))
        XCTAssertEqual(view.debugMainBaseLayerOpacity, Float(Self.inactiveTier), accuracy: 0.01,
                       "precondition: hot row carries compensation")

        view.prepareForReuse()
        XCTAssertEqual(view.debugMainBaseLayerOpacity, 1, accuracy: 0.001,
                       "recycled row must not carry the previous row's dim compensation")
    }

    @MainActor
    func test_settledRow_repeatedApply_causesNoLayerChurn() {
        let mc = makeController(time: 4.5)
        let rows = [row(index: 0), row(index: 1), row(index: 2)]
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))

        view.configure(row: rows[1], configuration: config(rows: rows, currentIndex: 1, musicController: mc),
                       updatesPlaybackPhase: false)
        view.setRowOpacity(1.0, dimBaseBrightness: Float(Self.inactiveTier))
        let settledMutations = view.layerMutationCount
        for _ in 0..<3 {
            view.setRowOpacity(1.0, dimBaseBrightness: Float(Self.inactiveTier))
        }
        XCTAssertEqual(view.layerMutationCount, settledMutations,
                       "settled row: repeated identical applies must write nothing (churn iron law)")
    }
}
