import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 3h round, item 6 fix (founder-dictated, after NativeLyricsEmphasisHollowOverlapTests confirmed
// the root cause at the model level): the hollow cut for an emphasis word must grow with its own
// rendered scale, using the SAME `run.emphasis.scale` value the bright layer applies (no separate
// calculation) — implemented by widening `NativeLyricsRowView`'s `floatingOrders` set (which feeds
// `applyFloatingHiddenBase`) to also include the immediately adjacent word whenever this word's
// scale exceeds 1. Since `applyMainWordFloatGlyphLayers` already builds a per-glyph dim tile for
// EVERY word (floating or not), widening the hollow makes the neighbour's own tile visible at its
// REST position — a clean ink replacement, not a new gap.
//
// This test verifies CONTAINMENT directly against the real render pipeline: whenever the
// emphasis word's applied scale is > 1, BOTH its own dim-base range AND its immediate neighbour's
// dim-base range must be hollowed (blanked) — i.e. there is no character-granularity region left
// un-hollowed that the enlarged tile could bleed onto with full-opacity ink underneath. When the
// scale is exactly 1 (not currently animating), the neighbour must NOT be hollowed (no
// over-blanking of ordinary, undisplaced text).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsEmphasisHollowContainmentTests: XCTestCase {

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

    /// Same fixture as the founder's own 2026-09-14 report: "about" (word order 3, duration 2.2s)
    /// is the sole emphasis-eligible run, with a real preceding neighbour (order 2, "all ").
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
    private func driveAtTime(_ currentTime: TimeInterval, width: CGFloat = 320) -> (view: NativeLyricsRowView, plan: NativeLyricsTextRenderPlan) {
        NativeLyricsFeelParity.testingSweep = .v28
        NativeLyricsFeelParity.testingEmphasis = .amll
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
        let plan = NativeLyricsTextRenderPlan.make(
            configuration: .init(line: line, currentTime: currentTime, isActive: true)
        )
        return (view, plan)
    }

    @MainActor
    func test_wheneverEmphasisScaleExceedsOne_bothOwnAndNeighbourHollowAreCut() {
        let emphasisOrder = 3 // "about"
        let neighbourOrder = 2 // "all " — the only real neighbour (order 4 does not exist)
        var sampledScaleAboveOne = false
        var sampledScaleAtRest = false

        var t: TimeInterval = 10.0
        while t <= 14.4 {
            defer { t += 0.05 }
            let (view, plan) = driveAtTime(t)
            defer { hostWindow?.orderOut(nil); hostWindow = nil }
            guard plan.wordRuns.indices.contains(emphasisOrder) else { continue }
            let scale = plan.wordRuns[emphasisOrder].emphasis.scale
            let ownHidden = view.debugMainTextLayerIsWordHidden(order: emphasisOrder, plan: plan)
            let neighbourHidden = view.debugMainTextLayerIsWordHidden(order: neighbourOrder, plan: plan)

            if scale > 1.001 {
                sampledScaleAboveOne = true
                XCTAssertEqual(ownHidden, true,
                    "t=\(t): emphasis word's own dim-base range must be hollowed while scale=\(scale) > 1")
                XCTAssertEqual(neighbourHidden, true,
                    "t=\(t): scale=\(scale) > 1 must ALSO hollow the neighbour's dim-base range " +
                    "(containment for the enlarged tile's overflow) — got neighbourHidden=\(String(describing: neighbourHidden))")
            } else if scale <= 1.0001,
                      !(plan.wordRuns[emphasisOrder].emphasis.liftY != 0 || plan.wordRuns[emphasisOrder].emphasis.floatY != 0),
                      plan.wordRuns[neighbourOrder].baseFloatY == 0 {
                // Fully at rest (emphasis word has no lift/float/scale, AND the neighbour is not
                // independently floating on its OWN account as an ordinary word) — the neighbour
                // must NOT be over-hollowed by the new item-6 logic; only genuinely displaced words
                // lose their whole-line ink.
                sampledScaleAtRest = true
                XCTAssertEqual(neighbourHidden, false,
                    "t=\(t): scale=\(scale) (at rest) must NOT hollow the neighbour — no over-blanking of undisplaced text")
            }
        }

        XCTAssertTrue(sampledScaleAboveOne, "fixture must actually sample a scale > 1 window, or this test proves nothing")
        XCTAssertTrue(sampledScaleAtRest, "fixture must actually sample an at-rest window, or the negative case is untested")
    }
}
